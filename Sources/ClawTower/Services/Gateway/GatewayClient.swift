import Foundation

@MainActor
final class GatewayClient: Sendable {
    let baseURL: URL
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

    // MARK: - Agents

    func listAgents() async throws -> [Agent] {
        let url = baseURL.appendingPathComponent("api/v1/agents")
        let request = authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return json.map { dict in
            Agent(
                id: dict["id"] as? String ?? "",
                displayName: dict["name"] as? String ?? dict["id"] as? String ?? "",
                emoji: dict["emoji"] as? String ?? "🤖",
                status: .online,
                model: dict["model"] as? String
            )
        }
    }

    // MARK: - Sessions

    func listSessions() async throws -> [Session] {
        let url = baseURL.appendingPathComponent("api/v1/sessions")
        let request = authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return json.compactMap { dict in
            guard let key = dict["key"] as? String else { return nil }
            let agentId = dict["agentId"] as? String ?? ""
            let updatedAt: Date? = (dict["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return Session(
                key: key,
                agentId: agentId,
                kind: dict["kind"] as? String,
                label: dict["label"] as? String,
                updatedAt: updatedAt,
                messageCount: dict["messageCount"] as? Int
            )
        }
    }

    // MARK: - Chat History

    func getHistory(sessionKey: String, limit: Int = 50) async throws -> [ChatMessage] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/sessions/\(sessionKey)/history"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        let request = authorizedRequest(url: components.url!)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return json.compactMap { dict in
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
        let url = baseURL.appendingPathComponent("api/v1/cron")
        let request = authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let jobs = json["jobs"] as? [[String: Any]] ?? []
        return jobs.map { dict in
            let schedule = dict["schedule"] as? [String: Any]
            let scheduleStr = schedule?["expr"] as? String ?? schedule?["kind"] as? String ?? "unknown"
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
        let url = baseURL.appendingPathComponent("api/v1/cron/\(jobId)/run")
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        let (_, _) = try await URLSession.shared.data(for: request)
    }

    func updateCron(jobId: String, enabled: Bool) async throws {
        let url = baseURL.appendingPathComponent("api/v1/cron/\(jobId)")
        var request = authorizedJSONRequest(url: url, method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        let (_, _) = try await URLSession.shared.data(for: request)
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
