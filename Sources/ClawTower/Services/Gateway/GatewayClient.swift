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
        return agents.map { dict in
            let id = dict["id"] as? String ?? ""
            let name = dict["name"] as? String
            return Agent(
                id: id,
                displayName: name ?? id,
                emoji: "🤖",
                status: .online,
                model: dict["model"] as? String
            )
        }
    }

    // MARK: - Sessions

    func listSessions(limit: Int = 50) async throws -> [Session] {
        let json = try await toolsInvoke(tool: "sessions_list", args: ["limit": limit])
        let result = json["result"] as? [String: Any] ?? json
        let details = result["details"] as? [String: Any] ?? result
        let sessions = details["sessions"] as? [[String: Any]]
            ?? result["sessions"] as? [[String: Any]]
            ?? []
        return sessions.compactMap { dict in
            guard let key = dict["key"] as? String else { return nil }
            let updatedAt: Date? = (dict["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return Session(
                key: key,
                kind: dict["kind"] as? String,
                channel: dict["channel"] as? String,
                label: dict["label"] as? String,
                displayName: dict["displayName"] as? String,
                updatedAt: updatedAt,
                model: dict["model"] as? String
            )
        }
    }

    // MARK: - Chat History

    func getHistory(sessionKey: String, limit: Int = 50) async throws -> [ChatMessage] {
        let json = try await toolsInvoke(tool: "sessions_history", args: ["sessionKey": sessionKey, "limit": limit])
        let result = json["result"] as? [String: Any] ?? json
        let details = result["details"] as? [String: Any] ?? result
        // Messages may be at result.content, result.details.messages, or result.messages
        let messagesArray: [[String: Any]]
        if let content = result["content"] as? [[String: Any]] {
            messagesArray = content
        } else if let msgs = details["messages"] as? [[String: Any]] {
            messagesArray = msgs
        } else if let msgs = result["messages"] as? [[String: Any]] {
            messagesArray = msgs
        } else {
            messagesArray = []
        }
        return messagesArray.compactMap { dict in
            guard let role = dict["role"] as? String,
                  let content = dict["content"] as? String else { return nil }
            let ts = (dict["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            return ChatMessage(
                id: dict["id"] as? String ?? UUID().uuidString,
                role: ChatMessage.Role(rawValue: role) ?? .assistant,
                content: content,
                timestamp: ts
            )
        }
    }

    // MARK: - Send Message (SSE Streaming)

    func sendMessage(sessionKey: String, content: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = baseURL.appendingPathComponent("v1/chat/completions")
                    var request = authorizedJSONRequest(url: url, method: "POST")

                    let body: [String: Any] = [
                        "model": "default",
                        "stream": true,
                        "sessionKey": sessionKey,
                        "messages": [["role": "user", "content": content]]
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.finish(throwing: GatewayError.badResponse)
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
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let choices = json["choices"] as? [[String: Any]],
                               let delta = choices.first?["delta"] as? [String: Any],
                               let text = delta["content"] as? String {
                                continuation.yield(text)
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

    // MARK: - Cron Jobs

    func listCronJobs() async throws -> [CronJob] {
        let json = try await toolsInvoke(tool: "cron", args: ["action": "list"])
        let result = json["result"] as? [String: Any] ?? json
        let details = result["details"] as? [String: Any] ?? result
        let jobs = details["jobs"] as? [[String: Any]]
            ?? result["jobs"] as? [[String: Any]]
            ?? []
        return jobs.map { dict in
            let schedule = dict["schedule"] as? [String: Any]
            let scheduleStr = schedule?["expr"] as? String ?? schedule?["kind"] as? String
                ?? dict["schedule"] as? String ?? "unknown"
            return CronJob(
                id: dict["id"] as? String ?? dict["jobId"] as? String ?? "",
                name: dict["name"] as? String,
                enabled: dict["enabled"] as? Bool ?? true,
                schedule: scheduleStr,
                sessionTarget: dict["sessionTarget"] as? String
            )
        }
    }

    func triggerCron(jobId: String) async throws {
        _ = try await toolsInvoke(tool: "cron", args: ["action": "run", "jobId": jobId])
    }

    func updateCron(jobId: String, enabled: Bool) async throws {
        _ = try await toolsInvoke(tool: "cron", args: ["action": "update", "jobId": jobId, "enabled": enabled])
    }

    enum GatewayError: Error, LocalizedError {
        case badResponse
        var errorDescription: String? {
            switch self {
            case .badResponse: return "Gateway 返回了异常响应"
            }
        }
    }
}
