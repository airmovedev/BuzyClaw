import Foundation

@MainActor
@Observable
final class AuthService {

    // MARK: - Types

    enum AuthState: Equatable, Sendable {
        case idle
        case verifying
        case verified
        case error(String)
    }

    enum Provider: String, Sendable {
        case anthropic
        case openai
    }

    // MARK: - State

    var state: AuthState = .idle

    private var currentTask: Task<Void, Never>?

    var isAuthenticated: Bool {
        if case .verified = state { return true }
        return false
    }

    // MARK: - Stored Keys

    var storedProvider: Provider? {
        guard let raw = UserDefaults.standard.string(forKey: "selectedProvider"),
              let provider = Provider(rawValue: raw) else { return nil }
        return provider
    }

    var storedAPIKey: String? {
        UserDefaults.standard.string(forKey: "apiKey")
    }

    func saveKey(provider: Provider, apiKey: String) {
        UserDefaults.standard.set(provider.rawValue, forKey: "selectedProvider")
        UserDefaults.standard.set(apiKey, forKey: "apiKey")
    }

    func clearKey() {
        UserDefaults.standard.removeObject(forKey: "selectedProvider")
        UserDefaults.standard.removeObject(forKey: "apiKey")
    }

    // MARK: - Public API

    func verifyKey(provider: Provider, apiKey: String) {
        currentTask?.cancel()
        state = .verifying

        currentTask = Task {
            do {
                let valid: Bool
                switch provider {
                case .anthropic:
                    valid = try await verifyAnthropicKey(apiKey: apiKey)
                case .openai:
                    valid = try await verifyOpenAIKey(apiKey: apiKey)
                }

                guard !Task.isCancelled else { return }

                if valid {
                    saveKey(provider: provider, apiKey: apiKey)
                    state = .verified
                } else {
                    state = .error("API Key 无效，请检查后重试")
                }
            } catch is CancellationError {
                // Cancelled — no state change
            } catch {
                guard !Task.isCancelled else { return }
                state = .error(error.localizedDescription)
            }
        }
    }

    func reset() {
        currentTask?.cancel()
        state = .idle
    }

    // MARK: - Anthropic Verification

    nonisolated private func verifyAnthropicKey(apiKey: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 1,
            "messages": [
                ["role": "user", "content": "hi"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }

        // 200 = success, anything else = bad key / error
        return http.statusCode == 200
    }

    // MARK: - OpenAI Verification

    nonisolated private func verifyOpenAIKey(apiKey: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }

        return http.statusCode == 200
    }
}
