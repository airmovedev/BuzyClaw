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

    private struct RuntimeCommand {
        let executable: URL
        let arguments: [String]
        let bundled: Bool
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

    func authenticateOpenAIOAuth(homeDir: String? = nil) {
        currentTask?.cancel()
        state = .launching

        let events = Self.oauthEventStream(homeDir: homeDir)

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

    func verifyAnthropicSetupToken(token: String, homeDir: String? = nil) {
        currentTask?.cancel()
        state = .verifying

        currentTask = Task {
            do {
                let resolvedHome = homeDir ?? FileManager.default.homeDirectoryForCurrentUser.path
                try Self.persistAnthropicSetupTokenProfile(token: token, homeDir: resolvedHome)

                guard !Task.isCancelled else { return }
                UserDefaults.standard.set(token, forKey: "setupToken")
                saveKey(provider: .anthropic, apiKey: "setup-token")
                state = .verified
            } catch {
                guard !Task.isCancelled else { return }
                state = .error("Setup Token 保存失败：\(error.localizedDescription)")
            }
        }
    }

    func reset() {
        currentTask?.cancel()
        state = .idle
    }

    // MARK: - Runtime Resolution

    nonisolated private static func resolveAuthRuntimeCommand(subcommand: [String]) -> RuntimeCommand {
        if let resourceURL = Bundle.main.resourceURL {
            let bundledNode = resourceURL.appendingPathComponent("Resources/runtime/node")
            let bundledOpenclaw = resourceURL.appendingPathComponent("Resources/runtime/openclaw/openclaw.mjs")

            if FileManager.default.fileExists(atPath: bundledNode.path)
                && FileManager.default.fileExists(atPath: bundledOpenclaw.path)
            {
                return RuntimeCommand(
                    executable: bundledNode,
                    arguments: [bundledOpenclaw.path] + subcommand,
                    bundled: true
                )
            }
        }

        // Dev fallback: system-installed CLI
        return RuntimeCommand(
            executable: URL(fileURLWithPath: "/usr/local/bin/openclaw"),
            arguments: subcommand,
            bundled: false
        )
    }

    nonisolated private static func baseEnvironment(homeDir: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:" + existingPath
        if let homeDir {
            env["HOME"] = homeDir
        }
        env["NODE_NO_WARNINGS"] = "1"
        return env
    }

    nonisolated private static func persistAnthropicSetupTokenProfile(token: String, homeDir: String) throws {
        let fm = FileManager.default
        let homeURL = URL(fileURLWithPath: homeDir, isDirectory: true)

        let agentDir = homeURL
            .appendingPathComponent(".openclaw", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("main", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)

        try fm.createDirectory(at: agentDir, withIntermediateDirectories: true)

        let authProfilesURL = agentDir.appendingPathComponent("auth-profiles.json")
        var authRoot: [String: Any] = [:]

        if let data = try? Data(contentsOf: authProfilesURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            authRoot = json
        }

        authRoot["version"] = 1
        var profiles = authRoot["profiles"] as? [String: Any] ?? [:]
        profiles["anthropic:default"] = [
            "type": "token",
            "provider": "anthropic",
            "token": token
        ]
        authRoot["profiles"] = profiles

        let authData = try JSONSerialization.data(withJSONObject: authRoot, options: [.prettyPrinted, .sortedKeys])
        try authData.write(to: authProfilesURL, options: .atomic)

        let configDir = homeURL.appendingPathComponent(".openclaw", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)

        let openclawConfigURL = configDir.appendingPathComponent("openclaw.json")
        var configRoot: [String: Any] = [:]
        if let data = try? Data(contentsOf: openclawConfigURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            configRoot = json
        }

        var auth = configRoot["auth"] as? [String: Any] ?? [:]
        var authProfiles = auth["profiles"] as? [String: Any] ?? [:]
        authProfiles["anthropic:default"] = [
            "provider": "anthropic",
            "mode": "token"
        ]
        auth["profiles"] = authProfiles
        configRoot["auth"] = auth

        let configData = try JSONSerialization.data(withJSONObject: configRoot, options: [.prettyPrinted, .sortedKeys])
        try configData.write(to: openclawConfigURL, options: .atomic)
    }

    // MARK: - OpenAI OAuth Process

    nonisolated private static func oauthEventStream(homeDir: String? = nil) -> AsyncStream<OAuthEvent> {
        AsyncStream { continuation in
            let command = resolveAuthRuntimeCommand(subcommand: ["models", "auth", "login", "--provider", "openai"])

            let process = Process()
            process.executableURL = command.executable
            process.arguments = command.arguments

            process.environment = baseEnvironment(homeDir: homeDir)
            if let homeDir {
                process.currentDirectoryURL = URL(fileURLWithPath: homeDir)
            } else {
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stdoutHandle.readabilityHandler = nil
                    return
                }
                if let str = String(data: data, encoding: .utf8) {
                    continuation.yield(.output(str))
                }
            }

            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stderrHandle.readabilityHandler = nil
                    return
                }
                if let str = String(data: data, encoding: .utf8) {
                    continuation.yield(.output(str))
                }
            }

            process.terminationHandler = { proc in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
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
