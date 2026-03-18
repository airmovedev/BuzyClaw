import Foundation

// MARK: - ToolsInvokeRequest (self-contained for CloudKit relay)

private struct ToolsInvokeRequest: Encodable, Sendable {
    let tool: String
    let args: [String: AnyCodableValue]
    let action: String

    init(tool: String, args: [String: AnyCodableValue], action: String = "json") {
        self.tool = tool
        self.args = args
        self.action = action
    }
}

private enum AnyCodableValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case object([String: AnyCodableValue])
}

extension AnyCodableValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .object(let value): try container.encode(value)
        }
    }
}

/// Lightweight HTTP client for relaying CloudKit messages to the local Gateway.
actor GatewayRelayClient {
    struct SessionHistoryMessage: Sendable {
        let id: String
        let role: String
        let content: String
        let timestampMs: Double
    }

    struct CronJob: Codable, Sendable {
        let id: String
        let agentId: String
        let name: String
        let enabled: Bool
        let delivery: CronDelivery?
    }

    struct CronDelivery: Codable, Sendable {
        let mode: String?
    }

    struct CronRun: Codable, Sendable {
        let status: String
        let summary: String?
        let runAtMs: Double
        let sessionId: String?
        let durationMs: Double?
    }

    private let baseURL: URL
    private let authToken: String
    private let session: URLSession

    /// Tracks consecutive tool_error failures per tool name for backoff.
    private var toolErrorCounts: [String: Int] = [:]

    /// True when tools are in persistent backoff, indicating a likely token mismatch.
    private(set) var hasToolErrorBackoff = false

    /// Returns true if the given tool is currently in backoff due to repeated tool_error failures.
    func isToolInBackoff(_ tool: String) -> Bool {
        return (toolErrorCounts[tool] ?? 0) >= 3
    }

    /// Resets tool error count (e.g. when gateway restarts).
    func resetToolErrors() {
        toolErrorCounts.removeAll()
        hasToolErrorBackoff = false
    }

    init(baseURL: URL, authToken: String) {
        self.baseURL = baseURL
        self.authToken = authToken
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Session history

    func fetchSessionHistory(sessionKey: String, limit: Int = 50) async throws -> [SessionHistoryMessage] {
        let toolName = "sessions_history"

        // Skip if tool is in backoff from repeated failures
        if isToolInBackoff(toolName) { return [] }

        let url = baseURL.appendingPathComponent("tools/invoke")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ToolsInvokeRequest(
            tool: toolName,
            args: [
                "sessionKey": .string(sessionKey),
                "limit": .int(limit),
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RelayError.invalidResponse
        }

        // Handle tool_error 500s gracefully — the Gateway's internal WebSocket RPC can fail
        // when there's an auth/pairing issue. Return empty instead of spamming errors.
        if httpResponse.statusCode == 500, isToolErrorResponse(data) {
            trackToolError(toolName)
            return []
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw RelayError.httpError(statusCode: httpResponse.statusCode, body: String(errorBody.prefix(500)))
        }

        // Success — reset error count
        toolErrorCounts[toolName] = 0

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let details = result["details"] as? [String: Any],
              let messages = details["messages"] as? [[String: Any]] else {
            return []
        }

        return messages.compactMap { raw in
            guard let role = raw["role"] as? String,
                  role == "assistant" || role == "user" else {
                return nil
            }
            let text = Self.extractText(from: raw["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let id = (raw["id"] as? String)
                ?? (raw["messageId"] as? String)
                ?? "\(role)-\(raw["timestamp"] as? Double ?? 0)-\(abs(text.hashValue))"

            let ts = (raw["timestamp"] as? Double) ?? 0
            return SessionHistoryMessage(id: id, role: role, content: text, timestampMs: ts)
        }
    }

    private static func extractText(from content: Any?) -> String {
        if let str = content as? String { return str }
        guard let blocks = content as? [[String: Any]] else { return "" }

        var textParts: [String] = []
        var toolMessageParts: [String] = []

        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            if type == "text", let text = block["text"] as? String {
                textParts.append(text)
            } else if type == "toolCall" || type == "tool_use" {
                let name = block["name"] as? String ?? ""
                if let args = block["arguments"] as? [String: Any] {
                    if name == "message", let msg = args["message"] as? String {
                        toolMessageParts.append(msg)
                    } else if name == "sessions_spawn", let msg = args["message"] as? String {
                        toolMessageParts.append(msg)
                    }
                }
            }
        }

        if !textParts.isEmpty { return textParts.joined(separator: "\n") }
        return toolMessageParts.joined(separator: "\n")
    }

    // MARK: - Cron jobs / runs

    func fetchCronJobs() async throws -> [CronJob] {
        let response = try await invokeTool(tool: "cron", args: [
            "action": .string("list"),
        ])

        guard let jobsRaw = response["jobs"] as? [[String: Any]] else {
            return []
        }

        let data = try JSONSerialization.data(withJSONObject: jobsRaw)
        return try JSONDecoder().decode([CronJob].self, from: data)
    }

    func fetchCronRuns(jobId: String) async throws -> [CronRun] {
        let response = try await invokeTool(tool: "cron", args: [
            "action": .string("runs"),
            "jobId": .string(jobId),
        ])

        guard let runsRaw = response["entries"] as? [[String: Any]] else {
            return []
        }

        let data = try JSONSerialization.data(withJSONObject: runsRaw)
        return try JSONDecoder().decode([CronRun].self, from: data)
    }

    private func invokeTool(tool: String, args: [String: AnyCodableValue]) async throws -> [String: Any] {
        // Skip if tool is in backoff from repeated failures
        if isToolInBackoff(tool) { return [:] }

        let url = baseURL.appendingPathComponent("tools/invoke")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ToolsInvokeRequest(tool: tool, args: args)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RelayError.invalidResponse
        }

        // Handle tool_error 500s gracefully
        if httpResponse.statusCode == 500, isToolErrorResponse(data) {
            trackToolError(tool)
            return [:]
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw RelayError.httpError(statusCode: httpResponse.statusCode, body: String(errorBody.prefix(500)))
        }

        // Success — reset error count
        toolErrorCounts[tool] = 0

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let details = result["details"] as? [String: Any] else {
            throw RelayError.invalidResponse
        }

        return details
    }

    // MARK: - Send message to Gateway

    func sendMessageWithAttachments(sessionKey: String, message: String, attachments: [[String: String]]) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/chat/completions")

        let parts = sessionKey.split(separator: ":")
        let agentId = parts.count >= 2 ? String(parts[1]) : "main"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(agentId, forHTTPHeaderField: "x-openclaw-agent-id")
        request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")

        // Build multi-part content array
        var contentParts: [[String: Any]] = [
            ["type": "text", "text": message]
        ]
        for attachment in attachments {
            if attachment["type"] == "image_url", let imageURL = attachment["url"] {
                contentParts.append([
                    "type": "image_url",
                    "image_url": ["url": imageURL]
                ])
            }
        }

        let body: [String: Any] = [
            "model": "default",
            "stream": true,
            "sessionKey": sessionKey,
            "messages": [
                ["role": "user", "content": contentParts]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        NSLog("[CloudKitRelay] HTTP request body size: %d bytes, contentParts count: %d", request.httpBody?.count ?? 0, contentParts.count)

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RelayError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 500 { break }
            }
            throw RelayError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        var fullResponse = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if jsonString.isEmpty || jsonString == "[DONE]" { break }

            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else {
                continue
            }
            fullResponse += content

            if let finishReason = choices.first?["finish_reason"] as? String, !finishReason.isEmpty {
                break
            }
        }

        return fullResponse
    }

    func sendMessage(sessionKey: String, message: String) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/chat/completions")

        let parts = sessionKey.split(separator: ":")
        let agentId = parts.count >= 2 ? String(parts[1]) : "main"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(agentId, forHTTPHeaderField: "x-openclaw-agent-id")
        request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")

        let body: [String: Any] = [
            "model": "default",
            "stream": true,
            "sessionKey": sessionKey,
            "messages": [
                ["role": "user", "content": message]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RelayError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 500 { break }
            }
            throw RelayError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        var fullResponse = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if jsonString.isEmpty || jsonString == "[DONE]" { break }

            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else {
                continue
            }
            fullResponse += content

            if let finishReason = choices.first?["finish_reason"] as? String, !finishReason.isEmpty {
                break
            }
        }

        return fullResponse
    }

    // MARK: - Tool error detection

    /// Check if a 500 response body is a tool_error (Gateway internal WebSocket RPC failure).
    private func isToolErrorResponse(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let type = error["type"] as? String else {
            return false
        }
        return type == "tool_error"
    }

    /// Track a tool_error failure. Logs only on first failure and when entering backoff.
    private func trackToolError(_ tool: String) {
        let count = (toolErrorCounts[tool] ?? 0) + 1
        toolErrorCounts[tool] = count
        if count == 1 {
            NSLog("[GatewayRelayClient] Tool '%@' returned tool_error (Gateway 内部 RPC 失败), will retry", tool)
        } else if count == 3 {
            NSLog("[GatewayRelayClient] Tool '%@' failed %d times, entering backoff — Gateway 可能需要重启", tool, count)
            hasToolErrorBackoff = true
        }
    }
}

enum RelayError: LocalizedError, Sendable {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case gatewayUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Gateway 返回了无效的响应"
        case .httpError(let code, let body):
            return "Gateway 错误 (\(code)): \(body)"
        case .gatewayUnavailable:
            return "Gateway 不可用，请确认 macOS 端正在运行"
        }
    }
}
