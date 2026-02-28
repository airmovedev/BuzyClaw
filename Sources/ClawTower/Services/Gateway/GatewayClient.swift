import Foundation

enum GatewayError: LocalizedError, Sendable {
    case notConfigured
    case notRunning
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Gateway 未配置"
        case .notRunning: "Gateway 未运行"
        case .requestFailed(let msg): msg
        }
    }
}

@MainActor
final class GatewayClient {
    private var baseURL: URL?

    func configure(port: Int) {
        baseURL = URL(string: "http://localhost:\(port)")
    }

    // MARK: - Chat

    func sendChatMessage(_ content: String) async throws -> String {
        let url = try apiURL("v1/chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatCompletionRequest(
            messages: [.init(role: "user", content: content)]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        return response.choices.first?.message.content ?? ""
    }

    // MARK: - Sessions

    func listSessions() async throws -> [[String: Any]] {
        let url = try apiURL("v1/sessions")
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        return json ?? []
    }

    func createSession() async throws -> String {
        let url = try apiURL("v1/sessions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["id"] as? String ?? ""
    }

    // MARK: - Agents

    func listAgents() async throws -> [[String: Any]] {
        let url = try apiURL("v1/agents")
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        return json ?? []
    }

    // MARK: - Cron Jobs

    func listCronJobs() async throws -> [[String: Any]] {
        let url = try apiURL("v1/cron")
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        return json ?? []
    }

    // MARK: - Health

    func healthCheck() async throws -> Bool {
        let url = try apiURL("health")
        let (_, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse {
            return http.statusCode == 200
        }
        return false
    }

    // MARK: - Private

    private func apiURL(_ path: String) throws -> URL {
        guard let baseURL else {
            throw GatewayError.notConfigured
        }
        return baseURL.appendingPathComponent(path)
    }
}

// MARK: - OpenAI-Compatible Request/Response Models

struct ChatCompletionRequest: Codable, Sendable {
    let model: String
    let messages: [ChatCompletionMessage]
    let stream: Bool

    init(model: String = "default", messages: [ChatCompletionMessage], stream: Bool = false) {
        self.model = model
        self.messages = messages
        self.stream = stream
    }
}

struct ChatCompletionMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct ChatCompletionResponse: Codable, Sendable {
    let choices: [Choice]

    struct Choice: Codable, Sendable {
        let message: ChatCompletionMessage
    }
}
