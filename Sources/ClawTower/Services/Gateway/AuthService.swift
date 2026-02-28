import Foundation

@MainActor
@Observable
final class AuthService {

    // MARK: - Types

    enum AuthState: Equatable, Sendable {
        case idle
        case launching
        case verifying
        case waitingForBrowser(String)
        case verified
        case error(String)
    }

    enum Provider: String, Sendable {
        case anthropic
        case openai
    }

    private enum OAuthEvent: Sendable {
        case output(String)
        case exited(Int32)
        case error(String)
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

    func authenticateOpenAIOAuth() {
        currentTask?.cancel()
        state = .launching

        let events = Self.oauthEventStream()

        currentTask = Task {
            for await event in events {
                guard !Task.isCancelled else { break }
                switch event {
                case .output(let text):
                    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                        if line.hasPrefix("Open:") {
                            let url = line.replacingOccurrences(of: "Open:", with: "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !url.isEmpty {
                                state = .waitingForBrowser(url)
                            }
                        }
                        let lowered = line.lowercased()
                        if lowered.contains("success") || lowered.contains("authenticated") || lowered.contains("logged in") {
                            saveKey(provider: .openai, apiKey: "oauth")
                            state = .verified
                        }
                    }
                case .exited(let status):
                    if status == 0 && !isAuthenticated {
                        saveKey(provider: .openai, apiKey: "oauth")
                        state = .verified
                    } else if status != 0 && !isAuthenticated {
                        state = .error("授权失败，请重试")
                    }
                case .error(let message):
                    state = .error("启动授权失败：\(message)")
                }
            }
        }
    }

    func verifyAnthropicSetupToken(token: String) {
        currentTask?.cancel()
        state = .verifying

        let tokenCopy = token
        let events = Self.pasteTokenEventStream(token: tokenCopy)

        currentTask = Task {
            var succeeded = false
            for await event in events {
                guard !Task.isCancelled else { break }
                switch event {
                case .output(let text):
                    let lowered = text.lowercased()
                    if lowered.contains("success") || lowered.contains("authenticated") || lowered.contains("saved") {
                        succeeded = true
                    }
                case .exited(let status):
                    if status == 0 || succeeded {
                        UserDefaults.standard.set(tokenCopy, forKey: "setupToken")
                        saveKey(provider: .anthropic, apiKey: "setup-token")
                        state = .verified
                    } else if !succeeded {
                        state = .error("Setup Token 验证失败，请检查后重试")
                    }
                case .error(let message):
                    state = .error("启动验证失败：\(message)")
                }
            }
        }
    }

    func reset() {
        currentTask?.cancel()
        state = .idle
    }

    // MARK: - OpenAI OAuth Process

    nonisolated private static func oauthEventStream() -> AsyncStream<OAuthEvent> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/openclaw")
            process.arguments = ["models", "auth", "login", "--provider", "openai"]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

            var env = ProcessInfo.processInfo.environment
            let existingPath = env["PATH"] ?? ""
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:" + existingPath
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            let readHandle = pipe.fileHandleForReading

            readHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    readHandle.readabilityHandler = nil
                    return
                }
                if let str = String(data: data, encoding: .utf8) {
                    continuation.yield(.output(str))
                }
            }

            process.terminationHandler = { proc in
                readHandle.readabilityHandler = nil
                continuation.yield(.exited(proc.terminationStatus))
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.yield(.error(error.localizedDescription))
                continuation.finish()
            }
        }
    }

    // MARK: - Anthropic Setup Token Process

    nonisolated private static func pasteTokenEventStream(token: String) -> AsyncStream<OAuthEvent> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/openclaw")
            process.arguments = ["models", "auth", "paste-token", "--provider", "anthropic"]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

            var env = ProcessInfo.processInfo.environment
            let existingPath = env["PATH"] ?? ""
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:" + existingPath
            process.environment = env

            let stdinPipe = Pipe()
            process.standardInput = stdinPipe

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()

            let readHandle = stdoutPipe.fileHandleForReading

            readHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    readHandle.readabilityHandler = nil
                    return
                }
                if let str = String(data: data, encoding: .utf8) {
                    continuation.yield(.output(str))
                }
            }

            process.terminationHandler = { proc in
                readHandle.readabilityHandler = nil
                continuation.yield(.exited(proc.terminationStatus))
                continuation.finish()
            }

            do {
                try process.run()
                // Write the token to stdin then close
                if let tokenData = (token + "\n").data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(tokenData)
                }
                try stdinPipe.fileHandleForWriting.close()
            } catch {
                continuation.yield(.error(error.localizedDescription))
                continuation.finish()
            }
        }
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
