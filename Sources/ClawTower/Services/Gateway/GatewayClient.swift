import Foundation

@MainActor
final class GatewayClient: Sendable {
    private(set) var baseURL: URL
    private(set) var authToken: String?

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
        let json = try await toolsInvoke(tool: "agents_list")
        let result = json["result"] as? [String: Any] ?? json
        let details = result["details"] as? [String: Any] ?? result
        let agents = details["agents"] as? [[String: Any]]
            ?? result["agents"] as? [[String: Any]]
            ?? []
        // 从 openclaw.json 补全 identity 信息
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".openclaw/openclaw.json")
        var identityMap: [String: (name: String?, emoji: String?)] = [:]
        if let configData = try? Data(contentsOf: configURL),
           let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
           let agentsConfig = config["agents"] as? [String: Any],
           let agentsList = agentsConfig["list"] as? [[String: Any]] {
            for agentConf in agentsList {
                guard let agentId = agentConf["id"] as? String else { continue }
                if let identity = agentConf["identity"] as? [String: Any] {
                    identityMap[agentId.lowercased()] = (
                        name: identity["name"] as? String,
                        emoji: identity["emoji"] as? String
                    )
                }
            }
        }

        // Read config once for workspace lookups
        let configForWorkspace: [String: Any]? = {
            if let data = try? Data(contentsOf: configURL),
               let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return config
            }
            return nil
        }()

        let defaultModel: String = {
            if let agentsConfig = configForWorkspace?["agents"] as? [String: Any],
               let defaults = agentsConfig["defaults"] as? [String: Any],
               let modelConfig = defaults["model"] as? [String: Any],
               let primary = modelConfig["primary"] as? String {
                return primary
            }
            return "anthropic/claude-sonnet-4-20250514"
        }()

        return agents.map { dict in
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

                let workspacePath = agentWorkspace ?? home.appendingPathComponent(".openclaw/workspace").path
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

            let agentModel: String = {
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

                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonStr = String(line.dropFirst(6))
                            if jsonStr == "[DONE]" {
                                continuation.finish()
                                return
                            }
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
            throw GatewayError.badResponse
        }
        return data
    }

    func triggerCron(jobId: String) async throws {
        _ = try await toolsInvoke(tool: "cron", args: ["action": "run", "jobId": jobId])
    }

    func updateCron(jobId: String, enabled: Bool) async throws {
        _ = try await toolsInvoke(tool: "cron", args: ["action": "update", "jobId": jobId, "patch": ["enabled": enabled]])
    }

    func cronDeleteJob(jobId: String) async throws {
        _ = try await toolsInvoke(tool: "cron", args: ["action": "remove", "jobId": jobId])
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

    private func runCLI(arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/local/bin/openclaw")
                    process.arguments = arguments

                    // Ensure PATH includes common node/bin paths
                    var env = ProcessInfo.processInfo.environment
                    let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]
                    let currentPath = env["PATH"] ?? "/usr/bin:/bin"
                    var seen = Set<String>()
                    let allPaths = (extraPaths + currentPath.components(separatedBy: ":")).filter { seen.insert($0).inserted }
                    env["PATH"] = allPaths.joined(separator: ":")
                    process.environment = env

                    NSLog("[ClawTower] runCLI: openclaw %@", arguments.joined(separator: " "))

                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    NSLog("[ClawTower] runCLI exit=%d output=%@", process.terminationStatus, String(output.prefix(500)))

                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: GatewayError.httpError(statusCode: Int(process.terminationStatus), detail: output))
                    } else {
                        continuation.resume(returning: output)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
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

        let agents = """
        # AGENTS.md - \(draft.name)'s Workspace

        Created by ClawTower.
        """
        let agentsPath = "\(workspaceDir)/AGENTS.md"
        if !fm.fileExists(atPath: agentsPath) {
            try agents.write(toFile: agentsPath, atomically: true, encoding: .utf8)
        }

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

    // MARK: - Config File Update

    func updateAgentModel(agentId: String, model: String) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.openclaw/openclaw.json"
        let url = URL(fileURLWithPath: configPath)
        let data = try Data(contentsOf: url)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var agents = json["agents"] as? [String: Any],
              var list = agents["list"] as? [[String: Any]] else {
            throw GatewayError.badResponse
        }

        if let idx = list.firstIndex(where: { ($0["id"] as? String) == agentId }) {
            list[idx]["model"] = model
            agents["list"] = list
            json["agents"] = agents
            let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try newData.write(to: url)
            NSLog("[ClawTower] Updated model for agent %@ to %@", agentId, model)
        }
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
