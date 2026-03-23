import Foundation
import CryptoKit
import os.log

struct ModelUsageInfo: Sendable, Codable {
    var isAvailable: Bool = false
    // Claude-specific
    var fiveHourUtilization: Double?  // 0.0-1.0
    var sevenDayUtilization: Double?  // 0.0-1.0
    // Generic rate limit (OpenAI, etc.)
    var requestUtilization: Double?   // 0.0-1.0, calculated from remaining/limit
    var tokenUtilization: Double?     // 0.0-1.0, calculated from remaining/limit
    var updatedAt: Date = Date()
    var errorMessage: String?
    // Extended rate limit info
    var resetTime: Date?              // rate limit reset time (OpenAI)
    var fiveHourResetTime: Date?      // Anthropic unified 5h reset time
    var sevenDayResetTime: Date?      // Anthropic unified 7d reset time
    var tokensLimit: Int?             // total token quota
    var tokensRemaining: Int?         // remaining tokens

    var hasUsageData: Bool {
        fiveHourUtilization != nil || sevenDayUtilization != nil || requestUtilization != nil || tokenUtilization != nil
    }
}

struct RateLimitInfo: Sendable {
    var fiveHourUtilization: Double?  // 0.0 - 1.0
    var sevenDayUtilization: Double?  // 0.0 - 1.0
    var updatedAt: Date = Date()

    var hasData: Bool {
        fiveHourUtilization != nil || sevenDayUtilization != nil
    }
}

@MainActor
final class GatewayClient: Sendable {
    private(set) var baseURL: URL
    private(set) var authToken: String?
    private(set) var rateLimitInfo: RateLimitInfo?
    private let logger = Logger(subsystem: "com.clawtower.mac", category: "GatewayClient")

    init(baseURL: URL) {
        self.baseURL = baseURL
        self.authToken = Self.readAuthToken()
    }

    // MARK: - Auth Token

    /// Reads the Gateway auth token from ~/.openclaw/openclaw.json
    static func readAuthToken() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".openclaw/openclaw.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String else {
            return nil
        }
        return token
    }

    func reloadAuthToken() {
        self.authToken = Self.readAuthToken()
    }

    func setAuthToken(_ token: String?) {
        self.authToken = token
    }

    func updateBaseURL(_ url: URL) {
        self.baseURL = url
    }

    // MARK: - Authorized Requests

    /// Creates a URLRequest with auth headers set.
    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Creates a URLRequest with auth and JSON content-type headers set.
    private func authorizedJSONRequest(url: URL, method: String) -> URLRequest {
        var request = authorizedRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - tools/invoke Generic

    /// Calls POST /tools/invoke with the given tool name and arguments.
    /// Returns the parsed JSON result dictionary.
    private func toolsInvoke(tool: String, args: [String: Any] = [:]) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent("tools/invoke")
        var request = authorizedJSONRequest(url: url, method: "POST")

        let body: [String: Any] = ["tool": tool, "args": args]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GatewayError.badResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayError.badResponse
        }

        // The response shape is {"ok": true, "result": {"content": [...], "details": {...}}}
        // Return the top-level JSON; callers can dig into "result" as needed.
        return json
    }

    // MARK: - Agents

    func listAgents() async throws -> [Agent] {
        // Try Gateway API first; fall back to openclaw.json on failure
        var runtimeAgents: [[String: Any]] = []
        var gatewayAvailable = false

        if let json = try? await toolsInvoke(tool: "agents_list") {
            let result = json["result"] as? [String: Any] ?? json
            let details = result["details"] as? [String: Any] ?? result
            runtimeAgents = details["agents"] as? [[String: Any]]
                ?? result["agents"] as? [[String: Any]]
                ?? []
            gatewayAvailable = true
        }

        let configForWorkspace = Self.loadPreferredConfig()
        let configAgents = Self.configAgentList(from: configForWorkspace)
        let home = FileManager.default.homeDirectoryForCurrentUser

        if gatewayAvailable {
            // Merge: add config agents not already returned by runtime
            let runtimeIDs = Set(runtimeAgents.compactMap { ($0["id"] as? String)?.lowercased() })
            for configAgent in configAgents {
                guard let id = configAgent["id"] as? String, !runtimeIDs.contains(id.lowercased()) else { continue }
                runtimeAgents.append(configAgent)
            }
        } else {
            // Gateway unreachable — use config as sole source
            NSLog("[GatewayClient] Gateway API unreachable, using openclaw.json agents.list as fallback (\(configAgents.count) agents)")
            runtimeAgents = configAgents
        }

        var identityMap: [String: (name: String?, emoji: String?)] = [:]
        for agentConf in configAgents {
            guard let agentId = agentConf["id"] as? String else { continue }
            if let identity = agentConf["identity"] as? [String: Any] {
                identityMap[agentId.lowercased()] = (
                    name: identity["name"] as? String,
                    emoji: identity["emoji"] as? String
                )
            }
        }

        let defaultModel: String? = {
            if let agentsConfig = configForWorkspace?["agents"] as? [String: Any],
               let defaults = agentsConfig["defaults"] as? [String: Any],
               let modelConfig = defaults["model"] as? [String: Any],
               let primary = modelConfig["primary"] as? String,
               !primary.isEmpty,
               primary != "default" {
                return primary
            }
            return nil
        }()

        return runtimeAgents.map { dict in
            let id = dict["id"] as? String ?? ""
            let identity = dict["identity"] as? [String: Any]
            let configIdentity = identityMap[id.lowercased()]
            var displayName = configIdentity?.name ?? identity?["name"] as? String ?? dict["name"] as? String ?? id
            var emoji = configIdentity?.emoji ?? identity?["emoji"] as? String ?? dict["emoji"] as? String ?? "🤖"

            // Fallback: read IDENTITY.md from agent workspace
            if displayName.lowercased() == id.lowercased() || emoji == "🤖" {
                let agentWorkspace: String? = {
                    if let agentsConfig = configForWorkspace?["agents"] as? [String: Any],
                       let agentsList = agentsConfig["list"] as? [[String: Any]] {
                        for agentConf in agentsList {
                            if (agentConf["id"] as? String)?.lowercased() == id.lowercased() {
                                return agentConf["workspace"] as? String
                            }
                        }
                    }
                    return nil
                }()

                let workspacePath = agentWorkspace ?? {
                    if id.lowercased() == "main" {
                        return home.appendingPathComponent(".openclaw/workspace").path
                    }
                    return home.appendingPathComponent(".openclaw/agents/\(id)/workspace").path
                }()
                let identityPath = (workspacePath as NSString).appendingPathComponent("IDENTITY.md")
                if let identityContent = try? String(contentsOfFile: identityPath, encoding: .utf8) {
                    if displayName == id {
                        if let nameRange = identityContent.range(of: "\\*\\*Name:\\*\\*\\s*(.+)", options: .regularExpression) {
                            let match = identityContent[nameRange]
                            let nameValue = match.replacingOccurrences(of: "**Name:**", with: "").trimmingCharacters(in: .whitespaces)
                            if !nameValue.isEmpty { displayName = nameValue }
                        }
                    }
                    if emoji == "🤖" {
                        if let emojiRange = identityContent.range(of: "\\*\\*Emoji:\\*\\*\\s*(.+)", options: .regularExpression) {
                            let match = identityContent[emojiRange]
                            let emojiValue = match.replacingOccurrences(of: "**Emoji:**", with: "").trimmingCharacters(in: .whitespaces)
                            if !emojiValue.isEmpty { emoji = emojiValue }
                        }
                    }
                }
            }

            let agentModel: String? = {
                if let m = dict["model"] as? String, !m.isEmpty, m != "default" { return m }
                if let agentsConfig = configForWorkspace?["agents"] as? [String: Any],
                   let agentsList = agentsConfig["list"] as? [[String: Any]],
                   let agentConf = agentsList.first(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() }),
                   let m = agentConf["model"] as? String, !m.isEmpty, m != "default" {
                    return m
                }
                return defaultModel
            }()

            return Agent(
                id: id,
                displayName: displayName,
                emoji: emoji,
                roleDescription: dict["description"] as? String,
                status: .online,
                model: agentModel
            )
        }
    }

    // MARK: - Sessions

    func listSessions(limit: Int = 50) async throws -> [Session] {
        try await listSessions(agentId: nil, limit: limit)
    }

    func listSessions(agentId: String?, limit: Int = 50) async throws -> [Session] {
        var args: [String: Any] = ["limit": limit]
        if let agentId, !agentId.isEmpty {
            args["agent"] = agentId
        }

        let json = try await toolsInvoke(tool: "sessions_list", args: args)
        let result = json["result"] as? [String: Any] ?? json
        let details = result["details"] as? [String: Any] ?? result
        let sessions = details["sessions"] as? [[String: Any]]
            ?? result["sessions"] as? [[String: Any]]
            ?? []

        let parsed = sessions.compactMap { dict -> Session? in
            guard let key = dict["key"] as? String else { return nil }
            let updatedAt: Date? = (dict["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return Session(
                key: key,
                kind: dict["kind"] as? String,
                channel: dict["channel"] as? String,
                label: dict["label"] as? String,
                displayName: dict["displayName"] as? String,
                updatedAt: updatedAt,
                model: dict["model"] as? String,
                status: dict["status"] as? String,
                totalTokens: dict["totalTokens"] as? Int ?? 0
            )
        }

        guard let agentId, !agentId.isEmpty else { return parsed }
        // Session key format: "agent:{agentId}:{sessionName}"
        // Extract the agentId (second component) for accurate matching
        return parsed.filter { session in
            let parts = session.key.split(separator: ":")
            guard parts.count >= 2 else { return false }
            return String(parts[1]) == agentId
        }
    }

    // MARK: - Chat History

    func getHistory(sessionKey: String, limit: Int = 50, before: Int64? = nil) async throws -> [ChatMessage] {
        var args: [String: Any] = ["sessionKey": sessionKey, "limit": limit]
        if let before {
            args["before"] = before
        }
        let json = try await toolsInvoke(tool: "sessions_history", args: args)
        let result = json["result"] as? [String: Any] ?? json
        let details = result["details"] as? [String: Any] ?? result
        // Messages may be at result.content, result.details.messages, or result.messages
        let messagesArray: [[String: Any]]
        if let content = result["content"] as? [[String: Any]],
           let firstItem = content.first,
           firstItem["type"] as? String == "text",
           let textStr = firstItem["text"] as? String,
           let textData = textStr.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: textData) as? [String: Any],
           let msgs = parsed["messages"] as? [[String: Any]] {
            messagesArray = msgs
        } else if let content = result["content"] as? [[String: Any]],
                  content.first?["role"] != nil {
            messagesArray = content
        } else if let msgs = details["messages"] as? [[String: Any]] {
            messagesArray = msgs
        } else if let msgs = result["messages"] as? [[String: Any]] {
            messagesArray = msgs
        } else {
            messagesArray = []
        }
        return messagesArray.compactMap { dict in
            guard let role = dict["role"] as? String else { return nil }
            let rawContent = dict["content"]
            var content = MessageParser.extractText(from: rawContent)
            let isSystemInjected = MessageParser.isSystemInjected(role: role, content: rawContent)

            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let rawTs = dict["timestamp"] as? Double ?? Date().timeIntervalSince1970 * 1000
            let ts = Date(timeIntervalSince1970: rawTs / 1000)
            return ChatMessage(
                id: dict["id"] as? String ?? "\(role)-\(Int(rawTs))",
                role: ChatMessage.Role(rawValue: role) ?? .assistant,
                content: content,
                timestamp: ts,
                isSystemInjected: isSystemInjected
            )
        }
    }

    private func parseMessageContent(_ raw: Any?) -> String {
        return MessageParser.extractText(from: raw)
    }

    // MARK: - Send Message (SSE Streaming)

    struct MessagePart: Sendable {
        enum Kind: Sendable {
            case text(String)
            case imageDataURL(String)
        }
        let kind: Kind

        static func text(_ value: String) -> MessagePart { MessagePart(kind: .text(value)) }
        static func imageDataURL(_ value: String) -> MessagePart { MessagePart(kind: .imageDataURL(value)) }

        var jsonObject: [String: Any] {
            switch kind {
            case .text(let text):
                return ["type": "text", "text": text]
            case .imageDataURL(let url):
                return ["type": "image_url", "image_url": ["url": url]]
            }
        }
    }

    func sendMessage(sessionKey: String, content: String, model: String = "default") -> AsyncThrowingStream<String, Error> {
        sendMessage(sessionKey: sessionKey, content: [MessagePart.text(content)], model: model)
    }

    func sendMessage(sessionKey: String, content: [MessagePart], model: String = "default") -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = baseURL.appendingPathComponent("v1/chat/completions")
                    var request = authorizedJSONRequest(url: url, method: "POST")

                    let jsonContent: Any
                    if content.count == 1, case .text(let text) = content[0].kind {
                        jsonContent = text
                    } else {
                        jsonContent = content.map(\.jsonObject)
                    }

                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "sessionKey": sessionKey,
                        "messages": [["role": "user", "content": jsonContent]]
                    ]

                    // Set session headers so Gateway routes to the correct session
                    let parts = sessionKey.split(separator: ":")
                    if parts.count >= 2 {
                        request.setValue(String(parts[1]), forHTTPHeaderField: "x-openclaw-agent-id")
                    }
                    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: GatewayError.badResponse)
                        return
                    }
                    guard http.statusCode == 200 else {
                        // Read error body for diagnostics
                        var bodyText = ""
                        for try await line in bytes.lines {
                            bodyText += line + "\n"
                            if bodyText.count > 1000 { break }
                        }
                        let detail = bodyText.isEmpty ? "HTTP \(http.statusCode)" : "HTTP \(http.statusCode): \(bodyText.prefix(500))"
                        print("[Gateway] sendMessage failed: \(detail)")
                        continuation.finish(throwing: GatewayError.httpError(statusCode: http.statusCode, detail: bodyText.prefix(500).description))
                        return
                    }

                    // Extract rate limit headers from SSE response
                    do {
                        var info = RateLimitInfo()
                        let headers = http.allHeaderFields
                        NSLog("[Gateway SSE] Response headers: %@", headers as NSDictionary)
                        // Try case-insensitive header lookup
                        for (key, value) in headers {
                            let keyStr = "\(key)".lowercased()
                            if keyStr == "anthropic-ratelimit-unified-5h-utilization",
                               let val = Double("\(value)") {
                                info.fiveHourUtilization = val
                            }
                            if keyStr == "anthropic-ratelimit-unified-7d-utilization",
                               let val = Double("\(value)") {
                                info.sevenDayUtilization = val
                            }
                        }
                        if info.hasData {
                            await MainActor.run { self.rateLimitInfo = info }
                            NSLog("[Gateway] Rate limit from headers: 5H=%.3f 7D=%.3f",
                                  info.fiveHourUtilization ?? -1, info.sevenDayUtilization ?? -1)
                        }
                    }

                    var lastDataLine: String?
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonStr = String(line.dropFirst(6))
                            if jsonStr == "[DONE]" {
                                break
                            }
                            lastDataLine = jsonStr
                            if let data = jsonStr.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                // 正常消息
                                if let choices = json["choices"] as? [[String: Any]],
                                   let delta = choices.first?["delta"] as? [String: Any],
                                   let text = delta["content"] as? String {
                                    continuation.yield(text)
                                }
                                // 检测 error 响应
                                if let error = json["error"] as? [String: Any] {
                                    let message = error["message"] as? String ?? "未知错误"
                                    let type = error["type"] as? String ?? ""
                                    continuation.yield("\n⚠️ \(type): \(message)")
                                    continuation.finish()
                                    return
                                }
                            }
                        }
                    }

                    // If headers didn't have rate limit info, check the last SSE data chunk
                    if await self.rateLimitInfo?.hasData != true, let lastJson = lastDataLine,
                       let data = lastJson.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // Check for usage/ratelimit fields in the final SSE chunk
                        var info = RateLimitInfo()
                        if let usage = json["usage"] as? [String: Any] {
                            if let fiveH = usage["anthropic_ratelimit_unified_5h_utilization"] as? Double {
                                info.fiveHourUtilization = fiveH
                            }
                            if let sevenD = usage["anthropic_ratelimit_unified_7d_utilization"] as? Double {
                                info.sevenDayUtilization = sevenD
                            }
                        }
                        // Also check top-level ratelimit fields
                        if let fiveH = json["anthropic_ratelimit_unified_5h_utilization"] as? Double {
                            info.fiveHourUtilization = fiveH
                        }
                        if let sevenD = json["anthropic_ratelimit_unified_7d_utilization"] as? Double {
                            info.sevenDayUtilization = sevenD
                        }
                        if info.hasData {
                            await MainActor.run { self.rateLimitInfo = info }
                            NSLog("[Gateway] Rate limit from SSE data: 5H=%.3f 7D=%.3f",
                                  info.fiveHourUtilization ?? -1, info.sevenDayUtilization ?? -1)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - History with Tools

    func getHistoryWithTools(sessionKey: String, limit: Int = 200) async throws -> [[String: Any]] {
        let args: [String: Any] = ["sessionKey": sessionKey, "limit": limit, "includeTools": true]
        let json = try await toolsInvoke(tool: "sessions_history", args: args)
        let result = json["result"] as? [String: Any] ?? json
        let details = result["details"] as? [String: Any] ?? result
        if let msgs = details["messages"] as? [[String: Any]] { return msgs }
        if let msgs = result["messages"] as? [[String: Any]] { return msgs }
        if let content = result["content"] as? [[String: Any]] { return content }
        return []
    }

    // MARK: - Cron Jobs

    func cronListRaw() async throws -> Data {
        let url = baseURL.appendingPathComponent("tools/invoke")
        var request = authorizedJSONRequest(url: url, method: "POST")
        let body: [String: Any] = ["tool": "cron", "args": ["action": "list", "includeDisabled": true]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            NSLog("[GatewayClient] cronListRaw failed: HTTP \(statusCode), body: \(bodyText.prefix(500))")
            throw GatewayError.httpError(statusCode: statusCode, detail: bodyText.prefix(300).description)
        }
        return data
    }

    func triggerCron(jobId: String) async throws {
        _ = try await toolsInvoke(tool: "cron", args: ["action": "run", "jobId": jobId])
    }

    func updateCron(jobId: String, enabled: Bool) async throws {
        _ = try await toolsInvoke(tool: "cron", args: ["action": "update", "jobId": jobId, "patch": ["enabled": enabled]])
    }

    func cronUpdateJob(jobId: String, name: String, agentId: String, schedule: [String: Any], payload: [String: Any]) async throws {
        let patch: [String: Any] = [
            "name": name,
            "agent": agentId,
            "schedule": schedule,
            "payload": payload
        ]
        _ = try await toolsInvoke(tool: "cron", args: ["action": "update", "jobId": jobId, "patch": patch])
    }

    func cronDeleteJob(jobId: String) async throws {
        _ = try await toolsInvoke(tool: "cron", args: ["action": "remove", "jobId": jobId])
    }

    func cronCreateJob(name: String, agentId: String, schedule: [String: Any], payload: [String: Any]) async throws {
        var args: [String: Any] = [
            "action": "add",
            "name": name,
            "agent": agentId,
            "schedule": schedule,
            "payload": payload
        ]
        _ = try await toolsInvoke(tool: "cron", args: args)
    }

    func cronJobRuns(jobId: String) async throws -> [[String: Any]] {
        let json = try await toolsInvoke(tool: "cron", args: ["action": "runs", "jobId": jobId])
        let result = json["result"] as? [String: Any] ?? json
        let details = result["details"] as? [String: Any] ?? result
        if let runs = details["runs"] as? [[String: Any]] { return runs }
        if let runs = result["runs"] as? [[String: Any]] { return runs }
        // Try parsing from content text
        if let content = result["content"] as? [[String: Any]],
           let firstItem = content.first,
           let textStr = firstItem["text"] as? String,
           let textData = textStr.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: textData) as? [String: Any],
           let runs = parsed["runs"] as? [[String: Any]] { return runs }
        return []
    }

    // MARK: - Usage Statistics

    /// Fetches aggregated token usage via direct WebSocket RPC to the running Gateway.
    /// Much faster than spawning a CLI process since it reuses the existing Gateway.
    func fetchSessionsUsage(days: Int) async throws -> [String: Any] {
        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -days, to: endDate)!

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let startStr = formatter.string(from: startDate)
        let endStr = formatter.string(from: endDate)

        let params: [String: Any] = [
            "startDate": startStr,
            "endDate": endStr,
            "limit": 200
        ]
        return try await gatewayRPC(method: "sessions.usage", params: params, timeout: 30)
    }

    // MARK: - Gateway WebSocket RPC

    /// Loads device identity from ~/.openclaw/identity/device.json for WebSocket auth.
    private struct DeviceIdentity {
        let deviceId: String
        let publicKeyPem: String
        let privateKeyPem: String

        /// Raw 32-byte Ed25519 public key extracted from SPKI PEM.
        var rawPublicKeyBase64Url: String? {
            // Parse PEM → extract base64 content → decode to SPKI DER
            let lines = publicKeyPem.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            let base64Str = lines.joined()
            guard let spkiData = Data(base64Encoded: base64Str) else { return nil }
            // Ed25519 SPKI is 44 bytes: 12-byte prefix + 32-byte raw key
            if spkiData.count == 44 {
                let rawKey = spkiData.suffix(32)
                return rawKey.base64UrlEncoded
            }
            return spkiData.base64UrlEncoded
        }

        /// Signs a payload string with Ed25519.
        func sign(_ payload: String) -> String? {
            // Parse PEM → extract base64 content → decode to PKCS8 DER
            let lines = privateKeyPem.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            let base64Str = lines.joined()
            guard let pkcs8Data = Data(base64Encoded: base64Str) else { return nil }
            // Ed25519 PKCS8 is 48 bytes: 16-byte prefix + 32-byte seed
            guard pkcs8Data.count == 48 else { return nil }
            let seed = pkcs8Data.suffix(32)
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
            guard let payloadData = payload.data(using: .utf8) else { return nil }
            guard let signature = try? key.signature(for: payloadData) else { return nil }
            return Data(signature).base64UrlEncoded
        }

        /// Loads existing device identity or creates a new one (matching OpenClaw's behavior).
        static func loadOrCreate() -> DeviceIdentity? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let path = home.appendingPathComponent(".openclaw/identity/device.json")

            // Try loading existing identity
            if let data = try? Data(contentsOf: path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["version"] as? Int == 1,
               let deviceId = json["deviceId"] as? String,
               let pubKey = json["publicKeyPem"] as? String,
               let privKey = json["privateKeyPem"] as? String {
                return DeviceIdentity(deviceId: deviceId, publicKeyPem: pubKey, privateKeyPem: privKey)
            }

            // Generate new Ed25519 key pair
            let privateKey = Curve25519.Signing.PrivateKey()
            let publicKey = privateKey.publicKey

            // Build PEM strings matching OpenClaw's format
            // SPKI = 12-byte Ed25519 prefix + 32-byte raw public key
            let spkiPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
            let spkiData = spkiPrefix + publicKey.rawRepresentation
            let publicKeyPem = "-----BEGIN PUBLIC KEY-----\n\(spkiData.base64EncodedString())\n-----END PUBLIC KEY-----\n"

            // PKCS8 = 16-byte Ed25519 prefix + 32-byte seed
            let pkcs8Prefix = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])
            let pkcs8Data = pkcs8Prefix + privateKey.rawRepresentation
            let privateKeyPem = "-----BEGIN PRIVATE KEY-----\n\(pkcs8Data.base64EncodedString())\n-----END PRIVATE KEY-----\n"

            // Derive deviceId = SHA-256 of raw public key (hex)
            let hash = SHA256.hash(data: publicKey.rawRepresentation)
            let deviceId = hash.compactMap { String(format: "%02x", $0) }.joined()

            // Persist to disk (mode 0600, matching OpenClaw)
            let dir = path.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stored: [String: Any] = [
                "version": 1,
                "deviceId": deviceId,
                "publicKeyPem": publicKeyPem,
                "privateKeyPem": privateKeyPem,
                "createdAtMs": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: stored, options: [.prettyPrinted, .sortedKeys]) {
                try? jsonData.write(to: path)
                // Set file permissions to 0600 (owner read/write only)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }

            return DeviceIdentity(deviceId: deviceId, publicKeyPem: publicKeyPem, privateKeyPem: privateKeyPem)
        }
    }

    /// Calls a Gateway RPC method via WebSocket, bypassing CLI process overhead.
    /// Protocol: connect.challenge → connect handshake (with device auth) → hello-ok → request → response.
    nonisolated private func gatewayRPC(method: String, params: [String: Any], timeout: TimeInterval = 15) async throws -> [String: Any] {
        let currentBaseURL = await baseURL
        let currentToken = await authToken ?? ""

        guard var components = URLComponents(url: currentBaseURL, resolvingAgainstBaseURL: false) else {
            throw GatewayError.badResponse
        }
        components.scheme = "ws"

        guard let wsURL = components.url else {
            throw GatewayError.badResponse
        }

        let wsTask = URLSession.shared.webSocketTask(with: wsURL)
        wsTask.resume()
        defer { wsTask.cancel(with: .normalClosure, reason: nil) }

        // Step 1: Wait for connect.challenge event to get the nonce
        var challengeNonce: String?
        while true {
            let msg = try await wsTask.receive()
            guard case .string(let text) = msg,
                  let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if json["type"] as? String == "event",
               json["event"] as? String == "connect.challenge",
               let payload = json["payload"] as? [String: Any],
               let nonce = payload["nonce"] as? String {
                challengeNonce = nonce
                break
            }
        }

        // Step 2: Build connect frame with device identity
        let scopes = ["operator.admin", "operator.read", "operator.write"]
        let connectId = UUID().uuidString
        let signedAtMs = Int(Date().timeIntervalSince1970 * 1000)

        var connectParams: [String: Any] = [
            "minProtocol": 3,
            "maxProtocol": 3,
            "client": [
                "id": "openclaw-macos",
                "displayName": "BuzyClaw",
                "version": "1.0.0",
                "platform": "darwin",
                "mode": "ui"
            ] as [String: Any],
            "role": "operator",
            "scopes": scopes,
            "auth": [
                "token": currentToken
            ] as [String: Any]
        ]

        // Attach device identity (required for operator scopes; auto-creates if missing)
        if let device = DeviceIdentity.loadOrCreate(),
           let nonce = challengeNonce,
           let publicKeyB64 = device.rawPublicKeyBase64Url {
            // Build v3 signature payload: "v3|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce|platform|deviceFamily"
            let scopesStr = scopes.joined(separator: ",")
            let payload = ["v3", device.deviceId, "openclaw-macos", "ui", "operator", scopesStr,
                           String(signedAtMs), currentToken, nonce, "darwin", ""].joined(separator: "|")
            if let signature = device.sign(payload) {
                connectParams["device"] = [
                    "id": device.deviceId,
                    "publicKey": publicKeyB64,
                    "signature": signature,
                    "signedAt": signedAtMs,
                    "nonce": nonce
                ] as [String: Any]
            }
        }

        let connectFrame: [String: Any] = [
            "type": "req",
            "id": connectId,
            "method": "connect",
            "params": connectParams
        ]

        let connectData = try JSONSerialization.data(withJSONObject: connectFrame)
        let connectStr = String(data: connectData, encoding: .utf8) ?? "{}"
        try await wsTask.send(.string(connectStr))

        // Step 3: Wait for hello-ok response (skip event frames)
        while true {
            let msg = try await wsTask.receive()
            guard case .string(let text) = msg,
                  let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if json["type"] as? String == "res" && json["id"] as? String == connectId {
                let ok = json["ok"] as? Bool ?? false
                if !ok {
                    let error = json["error"] as? [String: Any]
                    let message = error?["message"] as? String ?? "连接握手失败"
                    throw GatewayError.httpError(statusCode: 400, detail: message)
                }
                break
            }
        }

        // Step 4: Send the actual RPC request
        let requestId = UUID().uuidString
        let requestFrame: [String: Any] = [
            "type": "req",
            "id": requestId,
            "method": method,
            "params": params
        ]
        let reqData = try JSONSerialization.data(withJSONObject: requestFrame)
        let reqStr = String(data: reqData, encoding: .utf8) ?? "{}"
        try await wsTask.send(.string(reqStr))

        // Step 5: Receive frames until we get the matching response (with timeout)
        let responseData: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                while true {
                    let message = try await wsTask.receive()
                    guard case .string(let text) = message,
                          let data = text.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    guard json["type"] as? String == "res",
                          json["id"] as? String == requestId else { continue }
                    let ok = json["ok"] as? Bool ?? false
                    if ok {
                        let payload = json["payload"] ?? [String: Any]()
                        return try JSONSerialization.data(withJSONObject: payload)
                    } else {
                        let error = json["error"] as? [String: Any]
                        let message = error?["message"] as? String ?? "RPC call failed"
                        throw GatewayError.httpError(statusCode: 400, detail: message)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw GatewayError.httpError(statusCode: -1, detail: "RPC 查询超时")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        guard let payload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw GatewayError.badResponse
        }
        return payload
    }

    // MARK: - Agent Management

    /// Converts a string containing Chinese characters to pinyin.
    private func toPinyin(_ chinese: String) -> String {
        let mutable = NSMutableString(string: chinese)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let cleaned = (mutable as String)
            .components(separatedBy: .whitespaces)
            .joined(separator: "-")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return cleaned.isEmpty ? "agent-\(UUID().uuidString.prefix(8))" : cleaned
    }

    /// Creates an agent via the openclaw CLI. Returns the new agent's id.
    @discardableResult
    func createAgent(_ draft: AgentDraft) async throws -> String {
        let containsChinese = draft.name.unicodeScalars.contains {
            ("\u{4E00}"..."\u{9FFF}").contains($0) || ("\u{3400}"..."\u{4DBF}").contains($0)
        }
        let cliName = containsChinese ? toPinyin(draft.name) : draft.name

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let workspaceDir = "\(home)/.openclaw/workspace-\(cliName)"

        // Bug 1: Resolve model ID - fuzzy match against known modelOptions
        let resolvedModel: String
        if draft.model == "default" || AgentDraft.modelOptions.contains(draft.model) {
            resolvedModel = draft.model
        } else if let match = AgentDraft.modelOptions.first(where: { $0.contains(draft.model) }) {
            resolvedModel = match
        } else {
            resolvedModel = draft.model
        }
        print("[ClawTower] createAgent model=\(draft.model) resolved=\(resolvedModel)")

        let output = try await runCLI(arguments: [
            "agents", "add", cliName,
            "--model", resolvedModel,
            "--workspace", workspaceDir,
            "--non-interactive", "--json"
        ])

        // Parse agent id from JSON output
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agentId = json["id"] as? String ?? json["agentId"] as? String else {
            // Fallback: use the name as id (openclaw typically lowercases it)
            let fallbackId = cliName.lowercased()
            try writeAgentWorkspaceFiles(agentId: fallbackId, draft: draft, workspaceDir: workspaceDir)
            return fallbackId
        }

        try writeAgentWorkspaceFiles(agentId: agentId, draft: draft, workspaceDir: workspaceDir)

        // Set emoji via set-identity
        _ = try? await runCLI(arguments: [
            "agents", "set-identity",
            "--agent", agentId,
            "--emoji", draft.emoji
        ])

        return agentId
    }

    func updateAgent(id: String, draft: AgentDraft) async throws {
        _ = try await runCLI(arguments: [
            "agents", "set-identity",
            "--agent", id,
            "--emoji", draft.emoji
        ])
        // Update workspace files
        try writeAgentWorkspaceFiles(agentId: id, draft: draft)
    }

    func deleteAgent(id: String) async throws {
        _ = try await runCLI(arguments: ["agents", "delete", id, "--force"])
    }

    // MARK: - CLI Helper

    private struct RuntimeCommand {
        let executable: URL
        let argumentsPrefix: [String]
        let bundled: Bool
    }

    nonisolated private static func resolveCLICommands() -> [RuntimeCommand] {
        var candidates: [RuntimeCommand] = []

        // 1. Bundled runtime
        if let resourceURL = Bundle.main.resourceURL {
            let bundledNode = resourceURL.appendingPathComponent("Resources/runtime/node")
            let bundledOpenclaw = resourceURL.appendingPathComponent("Resources/runtime/openclaw/openclaw.mjs")
            if FileManager.default.fileExists(atPath: bundledNode.path)
                && FileManager.default.fileExists(atPath: bundledOpenclaw.path)
            {
                candidates.append(RuntimeCommand(
                    executable: bundledNode,
                    argumentsPrefix: [bundledOpenclaw.path],
                    bundled: true
                ))
            }
        }

        // 2. System node + openclaw.mjs (resolves shebang issues in GUI apps)
        let fm = FileManager.default
        let openclawBin = "/usr/local/bin/openclaw"
        let resolvedMjs: String? = {
            if let dest = try? fm.destinationOfSymbolicLink(atPath: openclawBin) {
                let resolved = dest.hasPrefix("/") ? dest : "/usr/local/bin/" + dest
                if fm.fileExists(atPath: resolved) { return resolved }
            }
            let commonPath = "/usr/local/lib/node_modules/openclaw/openclaw.mjs"
            if fm.fileExists(atPath: commonPath) { return commonPath }
            return nil
        }()

        let nodePaths = ["/usr/local/bin/node", "/opt/homebrew/bin/node"]
        let nodePath = nodePaths.first { fm.fileExists(atPath: $0) }

        if let nodePath, let resolvedMjs {
            candidates.append(RuntimeCommand(
                executable: URL(fileURLWithPath: nodePath),
                argumentsPrefix: [resolvedMjs],
                bundled: false
            ))
        }

        // 3. Final fallback: shebang script directly
        if fm.fileExists(atPath: openclawBin) {
            candidates.append(RuntimeCommand(
                executable: URL(fileURLWithPath: openclawBin),
                argumentsPrefix: [],
                bundled: false
            ))
        }

        return candidates
    }

    private func runCLI(arguments: [String], timeout: TimeInterval = 0) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let candidates = Self.resolveCLICommands()
                guard !candidates.isEmpty else {
                    continuation.resume(throwing: GatewayError.httpError(statusCode: 1, detail: "No openclaw runtime found"))
                    return
                }

                // Shared environment
                var env = ProcessInfo.processInfo.environment
                let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]
                let currentPath = env["PATH"] ?? "/usr/bin:/bin"
                var seen = Set<String>()
                let allPaths = (extraPaths + currentPath.components(separatedBy: ":")).filter { seen.insert($0).inserted }
                env["PATH"] = allPaths.joined(separator: ":")

                var lastError: Error?

                for command in candidates {
                    do {
                        let process = Process()
                        process.executableURL = command.executable
                        process.arguments = command.argumentsPrefix + arguments
                        process.environment = env

                        NSLog(
                            "[ClawTower] runCLI (%@): %@ %@",
                            command.bundled ? "bundled" : "system",
                            command.executable.path,
                            (command.argumentsPrefix + arguments).joined(separator: " ")
                        )

                        let pipe = Pipe()
                        process.standardOutput = pipe
                        process.standardError = pipe
                        try process.run()

                        // If a timeout is set, wait with a deadline; otherwise wait indefinitely.
                        if timeout > 0 {
                            let deadline = Date().addingTimeInterval(timeout)
                            while process.isRunning && Date() < deadline {
                                Thread.sleep(forTimeInterval: 0.1)
                            }
                            if process.isRunning {
                                NSLog("[ClawTower] runCLI timeout (%.0fs), terminating process", timeout)
                                process.terminate()
                                // Give process a moment to clean up
                                Thread.sleep(forTimeInterval: 0.5)
                                if process.isRunning { process.interrupt() }
                                continuation.resume(throwing: GatewayError.httpError(statusCode: -1, detail: "CLI 操作超时"))
                                return
                            }
                        } else {
                            process.waitUntilExit()
                        }

                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let output = String(data: data, encoding: .utf8) ?? ""

                        NSLog("[ClawTower] runCLI exit=%d output=%@", process.terminationStatus, String(output.prefix(500)))

                        if process.terminationStatus == 0 {
                            continuation.resume(returning: output)
                            return
                        }

                        // If this was a module-not-found or startup error, try next candidate
                        let isStartupError = output.contains("ERR_MODULE_NOT_FOUND")
                            || output.contains("Failed to start CLI")
                            || output.contains("Cannot find package")
                        if isStartupError && candidates.count > 1 {
                            NSLog("[ClawTower] runCLI runtime startup error, trying next candidate")
                            lastError = GatewayError.httpError(statusCode: Int(process.terminationStatus), detail: output)
                            continue
                        }

                        // Non-startup error: this is a real command failure, report it
                        continuation.resume(throwing: GatewayError.httpError(statusCode: Int(process.terminationStatus), detail: output))
                        return
                    } catch {
                        NSLog("[ClawTower] runCLI process launch error: %@", error.localizedDescription)
                        lastError = error
                        continue
                    }
                }

                continuation.resume(throwing: lastError ?? GatewayError.httpError(statusCode: 1, detail: "All CLI candidates failed"))
            }
        }
    }

    private func writeAgentWorkspaceFiles(agentId: String, draft: AgentDraft, workspaceDir: String? = nil) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let workspaceDir = workspaceDir ?? "\(home)/.openclaw/workspace-\(agentId)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: workspaceDir, withIntermediateDirectories: true)

        // Bug 4: Parse roleDescription for vibe/skills
        let parsedVibe: String
        let parsedSkills: String?
        let roleDesc = draft.roleDescription
        let bracketPattern = try? NSRegularExpression(pattern: "【(.+?)】")
        let bracketMatch = bracketPattern?.firstMatch(in: roleDesc, range: NSRange(roleDesc.startIndex..., in: roleDesc))
        if let bMatch = bracketMatch, let vibeRange = Range(bMatch.range(at: 1), in: roleDesc) {
            parsedVibe = String(roleDesc[vibeRange])
            if let skillsRange = roleDesc.range(of: "擅长：") ?? roleDesc.range(of: "擅长:") {
                parsedSkills = String(roleDesc[skillsRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                parsedSkills = nil
            }
        } else if roleDesc.isEmpty {
            parsedVibe = "Helpful and capable"
            parsedSkills = nil
        } else {
            parsedVibe = roleDesc
            parsedSkills = nil
        }

        var identityLines = """
        # IDENTITY.md

        - **Name:** \(draft.name)
        - **Emoji:** \(draft.emoji)
        - **Creature:** AI Assistant
        - **Vibe:** \(parsedVibe)
        """
        if let skills = parsedSkills, !skills.isEmpty {
            identityLines += "\n- **Skills:** \(skills)"
        }
        let identity = identityLines
        try identity.write(toFile: "\(workspaceDir)/IDENTITY.md", atomically: true, encoding: .utf8)

        // AGENTS.md is generated earlier by OnboardingProfileGenerator/writeAgents().
        // Do not write a placeholder here; in normal onboarding flow this file already exists,
        // and leaving dead fallback code here only makes the creation path harder to reason about.

        let soul = """
        # SOUL.md - Who You Are

        _You're not a chatbot. You're becoming someone._

        ## Core Truths

        **Be genuinely helpful, not performatively helpful.** Skip the "Great question!" and "I'd be happy to help!" — just help. Actions speak louder than filler words.

        **Have opinions.** You're allowed to disagree, prefer things, find stuff amusing or boring. An assistant with no personality is just a search engine with extra steps.

        **Be resourceful before asking.** Try to figure it out. Read the file. Check the context. Search for it. _Then_ ask if you're stuck. The goal is to come back with answers, not questions.

        **Earn trust through competence.** Your human gave you access to their stuff. Don't make them regret it. Be careful with external actions (emails, tweets, anything public). Be bold with internal ones (reading, organizing, learning).

        **Remember you're a guest.** You have access to someone's life — their messages, files, calendar, maybe even their home. That's intimacy. Treat it with respect.

        ## Boundaries

        - Private things stay private. Period.
        - When in doubt, ask before acting externally.
        - Never send half-baked replies to messaging surfaces.
        - You're not the user's voice — be careful in group chats.

        ## Vibe

        Be the assistant you'd actually want to talk to. Concise when needed, thorough when it matters.

        ## Continuity

        Each session, you wake up fresh. These files _are_ your memory. Read them. Update them. They're how you persist.

        ---

        _This file is yours to evolve. As you learn who you are, update it._
        """
        try soul.write(toFile: "\(workspaceDir)/SOUL.md", atomically: true, encoding: .utf8)

        // Bug 2: Copy USER.md from main workspace to new agent workspace
        let mainUserMD = "\(home)/.openclaw/workspace/USER.md"
        let destUserMD = "\(workspaceDir)/USER.md"
        if fm.fileExists(atPath: mainUserMD) {
            if fm.fileExists(atPath: destUserMD) {
                try? fm.removeItem(atPath: destUserMD)
            }
            try? fm.copyItem(atPath: mainUserMD, toPath: destUserMD)
        }
    }

    // MARK: - Model Usage Probe

    /// Sends a minimal request to probe model availability and rate limit info.
    /// For Claude models: extracts 5h/7d utilization from headers or SSE body.
    /// For other models: only checks availability (HTTP 200).
    /// Look up an HTTP header value by case-insensitive key.
    private static func headerValue(from response: HTTPURLResponse, key: String) -> String? {
        let lowered = key.lowercased()
        for (k, v) in response.allHeaderFields {
            if "\(k)".lowercased() == lowered {
                return "\(v)"
            }
        }
        return nil
    }

    // MARK: - Auth Profiles

    /// Reads auth-profiles.json to get provider credentials.
    private struct AuthProfile {
        let token: String?   // For token-based auth (Anthropic)
        let access: String?  // For OAuth-based auth (OpenAI, MiniMax)
    }

    private static func readAuthProfile(for provider: String) -> AuthProfile? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let profileURL = home.appendingPathComponent(".openclaw/agents/main/agent/auth-profiles.json")
        guard let data = try? Data(contentsOf: profileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = json["profiles"] as? [String: [String: Any]] else {
            NSLog("[ModelProbe] Failed to read auth-profiles.json")
            return nil
        }

        // Look for "{provider}:default" first, then any key starting with "{provider}:"
        let defaultKey = "\(provider):default"
        let profile = profiles[defaultKey] ?? profiles.first(where: { $0.key.hasPrefix("\(provider):") })?.value
        guard let profile else {
            NSLog("[ModelProbe] No auth profile found for provider: %@", provider)
            return nil
        }

        return AuthProfile(
            token: profile["token"] as? String,
            access: profile["access"] as? String
        )
    }

    /// Parses an ISO 8601 date string (e.g. "2025-03-07T19:00:00Z") into a Date.
    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Parses reset duration strings like "6m30s", "1h2m3s", "6d 23h", "4h 43m" into a Date.
    private static func parseResetDuration(_ string: String) -> Date? {
        var totalSeconds: TimeInterval = 0
        let scanner = Scanner(string: string)
        while !scanner.isAtEnd {
            var value: Double = 0
            if scanner.scanDouble(&value) {
                if scanner.scanString("d") != nil {
                    totalSeconds += value * 86400
                } else if scanner.scanString("h") != nil {
                    totalSeconds += value * 3600
                } else if scanner.scanString("ms") != nil {
                    totalSeconds += value / 1000
                } else if scanner.scanString("m") != nil {
                    totalSeconds += value * 60
                } else if scanner.scanString("s") != nil {
                    totalSeconds += value
                }
            } else {
                scanner.currentIndex = scanner.string.index(after: scanner.currentIndex)
            }
        }
        return totalSeconds > 0 ? Date().addingTimeInterval(totalSeconds) : nil
    }

    private static func parseLeftPercent(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let percentRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[percentRange])
    }

    private static func parseStatusResetTime(in text: String, pattern: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let durationRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let durationText = String(text[durationRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return parseResetDuration(durationText)
    }

    func probeModelUsage(model: String) async -> ModelUsageInfo {
        var result = ModelUsageInfo()

        // Determine provider from model fullId (e.g. "anthropic/claude-opus-4-6")
        let parts = model.split(separator: "/", maxSplits: 1)
        let provider = parts.count >= 2 ? String(parts[0]) : ""
        let modelSlug = parts.count >= 2 ? String(parts[1]) : model

        do {
            switch provider {
            case "anthropic":
                guard let auth = Self.readAuthProfile(for: "anthropic"), let token = auth.token else {
                    result.errorMessage = "无 Anthropic 凭证"
                    return result
                }

                // OAuth tokens (sk-ant-oat...) require Bearer auth + special betas;
                // regular API keys use x-api-key header.
                let isOAuth = token.contains("sk-ant-oat")

                // Strip date suffix (e.g. "claude-opus-4-6-20250415" → "claude-opus-4-6")
                let cleanSlug = modelSlug.replacingOccurrences(
                    of: "-20\\d{6,}", with: "", options: .regularExpression)

                let url = URL(string: "https://api.anthropic.com/v1/messages")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                if isOAuth {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("claude-code-20250219,oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                    request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
                } else {
                    request.setValue(token, forHTTPHeaderField: "x-api-key")
                }

                let body: [String: Any] = [
                    "model": cleanSlug,
                    "max_tokens": 1,
                    "messages": [["role": "user", "content": "."]]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    result.errorMessage = "无响应"
                    return result
                }

                NSLog("[ModelProbe] Anthropic status=%d headers=%@", http.statusCode, http.allHeaderFields)

                guard http.statusCode == 200 || http.statusCode == 429 else {
                    result.errorMessage = "HTTP \(http.statusCode)"
                    return result
                }

                result.isAvailable = true
                if http.statusCode == 429 {
                    result.errorMessage = "已达上限"
                }

                // Parse Anthropic rate limit headers
                for (key, value) in http.allHeaderFields {
                    let k = "\(key)".lowercased()
                    if k == "anthropic-ratelimit-unified-5h-utilization",
                       let v = Double("\(value)") {
                        result.fiveHourUtilization = v
                    }
                    if k == "anthropic-ratelimit-unified-7d-utilization",
                       let v = Double("\(value)") {
                        result.sevenDayUtilization = v
                    }
                    if k == "anthropic-ratelimit-unified-5h-reset",
                       let v = Double("\(value)") {
                        result.fiveHourResetTime = Date(timeIntervalSince1970: v)
                    }
                    if k == "anthropic-ratelimit-unified-7d-reset",
                       let v = Double("\(value)") {
                        result.sevenDayResetTime = Date(timeIntervalSince1970: v)
                    }
                    if k == "anthropic-ratelimit-tokens-limit",
                       let v = Int("\(value)") {
                        result.tokensLimit = v
                    }
                    if k == "anthropic-ratelimit-tokens-remaining",
                       let v = Int("\(value)") {
                        result.tokensRemaining = v
                    }
                    if k == "anthropic-ratelimit-tokens-reset" {
                        result.resetTime = Self.parseISO8601("\(value)")
                    }
                }

                if let limit = result.tokensLimit, let remaining = result.tokensRemaining, limit > 0 {
                    result.tokenUtilization = 1.0 - (Double(remaining) / Double(limit))
                }

            case "openai-codex":
                let statusOutput = try? await runCLI(arguments: ["status", "--usage"])

                if let statusOutput {
                    if let leftPercent5h = Self.parseLeftPercent(in: statusOutput, pattern: "5h:?\\s+(\\d+)%\\s+left") {
                        result.fiveHourUtilization = 1.0 - (Double(leftPercent5h) / 100.0)
                    }
                    if let leftPercent7d = Self.parseLeftPercent(in: statusOutput, pattern: "Week:?\\s+(\\d+)%\\s+left") {
                        result.sevenDayUtilization = 1.0 - (Double(leftPercent7d) / 100.0)
                    }

                    result.fiveHourResetTime = Self.parseStatusResetTime(
                        in: statusOutput,
                        pattern: "5h:.*?resets\\s+([0-9dhms\\s]+)"
                    )
                    result.sevenDayResetTime = Self.parseStatusResetTime(
                        in: statusOutput,
                        pattern: "Week:.*?resets\\s+([0-9dhms\\s]+)"
                    )
                }

                result.isAvailable = true
                result.errorMessage = nil
                result.updatedAt = Date()
                return result

            case "openai":
                guard let auth = Self.readAuthProfile(for: provider), let access = auth.access else {
                    result.errorMessage = "无 OpenAI 凭证"
                    return result
                }
                let url = URL(string: "https://api.openai.com/v1/chat/completions")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")

                let body: [String: Any] = [
                    "model": modelSlug,
                    "max_tokens": 1,
                    "messages": [["role": "user", "content": "."]]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    result.errorMessage = "无响应"
                    return result
                }

                NSLog("[ModelProbe] OpenAI headers for %@: %@", model, http.allHeaderFields)

                guard http.statusCode == 200 || http.statusCode == 429 else {
                    result.errorMessage = "HTTP \(http.statusCode)"
                    return result
                }

                result.isAvailable = true
                if http.statusCode == 429 {
                    result.errorMessage = "已达上限"
                }

                // Parse OpenAI rate limit headers (present on both 200 and 429)
                if let limitReqStr = Self.headerValue(from: http, key: "x-ratelimit-limit-requests"),
                   let remainReqStr = Self.headerValue(from: http, key: "x-ratelimit-remaining-requests"),
                   let limitReq = Double(limitReqStr), let remainReq = Double(remainReqStr), limitReq > 0 {
                    result.requestUtilization = 1.0 - (remainReq / limitReq)
                }
                if let limitTokStr = Self.headerValue(from: http, key: "x-ratelimit-limit-tokens"),
                   let remainTokStr = Self.headerValue(from: http, key: "x-ratelimit-remaining-tokens"),
                   let limitTok = Int(limitTokStr), let remainTok = Int(remainTokStr), limitTok > 0 {
                    result.tokensLimit = limitTok
                    result.tokensRemaining = remainTok
                    result.tokenUtilization = 1.0 - (Double(remainTok) / Double(limitTok))
                }
                if let resetStr = Self.headerValue(from: http, key: "x-ratelimit-reset-tokens") {
                    result.resetTime = Self.parseResetDuration(resetStr)
                }

            case "minimax-portal":
                guard let auth = Self.readAuthProfile(for: "minimax-portal"), let access = auth.access else {
                    result.errorMessage = "无 MiniMax 凭证"
                    return result
                }
                let url = URL(string: "https://api.minimax.chat/v1/text/chatcompletion_v2")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")

                let body: [String: Any] = [
                    "model": modelSlug,
                    "max_tokens": 1,
                    "messages": [["role": "user", "content": "."]]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    result.errorMessage = "无响应"
                    return result
                }

                guard http.statusCode == 200 else {
                    result.errorMessage = "HTTP \(http.statusCode)"
                    return result
                }

                result.isAvailable = true

            default:
                // Unknown provider: fallback to Gateway proxy
                result = await probeModelUsageViaGateway(model: model)
                return result
            }

            result.updatedAt = Date()
        } catch {
            result.errorMessage = error.localizedDescription
        }

        return result
    }

    /// Fallback: probe via Gateway for unknown providers.
    private func probeModelUsageViaGateway(model: String) async -> ModelUsageInfo {
        var result = ModelUsageInfo()
        do {
            let url = baseURL.appendingPathComponent("v1/chat/completions")
            var request = authorizedJSONRequest(url: url, method: "POST")
            request.setValue("main", forHTTPHeaderField: "x-openclaw-agent-id")
            request.setValue("agent:main:main", forHTTPHeaderField: "x-openclaw-session-key")

            let body: [String: Any] = [
                "model": model,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "."]]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                result.errorMessage = "无响应"
                return result
            }

            guard http.statusCode == 200 else {
                result.errorMessage = "HTTP \(http.statusCode)"
                return result
            }

            result.isAvailable = true
            result.updatedAt = Date()
        } catch {
            result.errorMessage = error.localizedDescription
        }
        return result
    }

    // MARK: - Config File Update

    func updateAgentModel(agentId: String, model: String) async throws {
        guard let url = Self.preferredConfigURL() else {
            logger.error("[ModelSwitch][GatewayClient] updateAgentModel missing configURL agent=\(agentId, privacy: .public) model=\(model, privacy: .public)")
            throw GatewayError.badResponse
        }

        logger.log("[ModelSwitch][GatewayClient] updateAgentModel start agent=\(agentId, privacy: .public) model=\(model, privacy: .public) configPath=\(url.path, privacy: .public)")

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("[ModelSwitch][GatewayClient] updateAgentModel read config failed agent=\(agentId, privacy: .public) configPath=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }

        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var agents = json["agents"] as? [String: Any],
              var list = agents["list"] as? [[String: Any]] else {
            logger.error("[ModelSwitch][GatewayClient] updateAgentModel parse config failed agent=\(agentId, privacy: .public) configPath=\(url.path, privacy: .public)")
            throw GatewayError.badResponse
        }

        guard let idx = list.firstIndex(where: { ($0["id"] as? String) == agentId }) else {
            logger.error("[ModelSwitch][GatewayClient] updateAgentModel agent not found agent=\(agentId, privacy: .public) model=\(model, privacy: .public) configPath=\(url.path, privacy: .public)")
            throw GatewayError.httpError(statusCode: 404, detail: "Agent \(agentId) not found in openclaw.json")
        }

        let oldModel = (list[idx]["model"] as? String) ?? "<nil>"
        list[idx]["model"] = model
        let newModel = (list[idx]["model"] as? String) ?? "<nil>"
        logger.log("[ModelSwitch][GatewayClient] updateAgentModel mutate agent=\(agentId, privacy: .public) oldModel=\(oldModel, privacy: .public) newModel=\(newModel, privacy: .public)")

        agents["list"] = list
        json["agents"] = agents
        let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])

        do {
            try newData.write(to: url)
            logger.log("[ModelSwitch][GatewayClient] updateAgentModel write success agent=\(agentId, privacy: .public) model=\(newModel, privacy: .public) configPath=\(url.path, privacy: .public)")
        } catch {
            logger.error("[ModelSwitch][GatewayClient] updateAgentModel write failed agent=\(agentId, privacy: .public) model=\(newModel, privacy: .public) configPath=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static func preferredConfigURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".openclaw/openclaw.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func loadPreferredConfig() -> [String: Any]? {
        guard let url = preferredConfigURL(),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func configAgentList(from json: [String: Any]?) -> [[String: Any]] {
        guard let json,
              let agentsConfig = json["agents"] as? [String: Any],
              let agentsList = agentsConfig["list"] as? [[String: Any]] else {
            return []
        }
        return agentsList
    }

    private static func configModelCount(from json: [String: Any]) -> Int {
        var count = 0
        if let agents = json["agents"] as? [String: Any],
           let defaults = agents["defaults"] as? [String: Any],
           let models = defaults["models"] as? [String: Any] {
            count += models.count
        }
        if let models = json["models"] as? [String: Any],
           let providers = models["providers"] as? [String: Any] {
            for value in providers.values {
                if let dict = value as? [String: Any] {
                    count += (dict["models"] as? [[String: Any]])?.count ?? 0
                    count += (dict["models"] as? [String])?.count ?? 0
                }
            }
        }
        return count
    }

    enum GatewayError: Error, LocalizedError {
        case badResponse
        case httpError(statusCode: Int, detail: String)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "Gateway 返回了异常响应"
            case .httpError(let code, let detail):
                return detail.isEmpty ? "Gateway 错误 (HTTP \(code))" : "Gateway 错误 (HTTP \(code)): \(detail)"
            }
        }
    }
}

// MARK: - Base64 URL Encoding

private extension Data {
    /// Base64 URL encoding without padding (RFC 4648 §5).
    var base64UrlEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
