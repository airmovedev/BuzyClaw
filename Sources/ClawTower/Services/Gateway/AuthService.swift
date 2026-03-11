import AppKit
import CryptoKit
import Foundation
import Network

@MainActor
@Observable
final class AuthService {

    // MARK: - Types

    enum AuthState: Equatable, Sendable {
        case idle
        case launching
        case verifying
        case waitingForBrowser(String)
        case waitingForCode(String, String) // (verification_uri, user_code)
        case verified
        case modelSelection  // Key verified, waiting for user to select a model
        case error(String)
    }

    enum Provider: String, Sendable {
        case anthropic
        case openai
        case minimax
        case kimi
        case zai
        case qwen
        case google
        case xai
        case openrouter
    }

    private struct RuntimeCommand {
        let executable: URL
        let arguments: [String]
        let bundled: Bool
    }

    struct AvailableModel: Identifiable, Sendable {
        let id: String
        let ownedBy: String
        var displayName: String { id }
    }

    // MARK: - State

    var state: AuthState = .idle
    var availableModels: [AvailableModel] = []
    var selectedModelId: String?

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
                case .minimax:
                    valid = try await verifyMinimaxKey(apiKey: apiKey)
                case .kimi:
                    valid = try await verifyMoonshotKey(apiKey: apiKey)
                case .zai:
                    valid = try await verifyZaiKey(apiKey: apiKey)
                case .qwen:
                    valid = try await !fetchQwenModels(apiKey: apiKey).isEmpty
                case .google:
                    valid = try await verifyGoogleKey(apiKey: apiKey)
                case .xai:
                    valid = try await verifyXaiKey(apiKey: apiKey)
                case .openrouter:
                    valid = try await verifyOpenRouterKey(apiKey: apiKey)
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

        currentTask = Task {
            do {
                let resolvedHome = homeDir ?? FileManager.default.homeDirectoryForCurrentUser.path

                // 1. Generate PKCE
                let verifierData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                let verifier = verifierData.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")

                let challengeHash = SHA256.hash(data: Data(verifier.utf8))
                let challenge = Data(challengeHash).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")

                // 2. Generate state
                let stateData = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
                let oauthState = stateData.map { String(format: "%02x", $0) }.joined()

                // 3. Build authorize URL
                var components = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
                components.queryItems = [
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "client_id", value: "app_EMoamEEZ73f0CkXaXp7hrann"),
                    URLQueryItem(name: "redirect_uri", value: "http://localhost:1455/auth/callback"),
                    URLQueryItem(name: "scope", value: "openid profile email offline_access"),
                    URLQueryItem(name: "code_challenge", value: challenge),
                    URLQueryItem(name: "code_challenge_method", value: "S256"),
                    URLQueryItem(name: "state", value: oauthState),
                    URLQueryItem(name: "id_token_add_organizations", value: "true"),
                    URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
                    URLQueryItem(name: "originator", value: "pi"),
                ]
                let authorizeURL = components.url!

                // 4. Start local HTTP server + 5. Open browser + 6. Wait for callback
                state = .waitingForBrowser(authorizeURL.absoluteString)
                let code = try await Self.waitForOAuthCallback(
                    expectedState: oauthState,
                    authorizeURL: authorizeURL
                )

                guard !Task.isCancelled else { return }

                // 7. Exchange code for token
                var tokenRequest = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
                tokenRequest.httpMethod = "POST"
                tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

                let tokenBody = [
                    "grant_type=authorization_code",
                    "client_id=app_EMoamEEZ73f0CkXaXp7hrann",
                    "code=\(code)",
                    "code_verifier=\(verifier)",
                    "redirect_uri=http://localhost:1455/auth/callback"
                ].joined(separator: "&")
                tokenRequest.httpBody = tokenBody.data(using: .utf8)

                let (tokenData, tokenResponse) = try await URLSession.shared.data(for: tokenRequest)
                guard let tokenHttp = tokenResponse as? HTTPURLResponse, tokenHttp.statusCode == 200 else {
                    let statusCode = (tokenResponse as? HTTPURLResponse)?.statusCode ?? -1
                    state = .error("Token 交换失败 (HTTP \(statusCode))")
                    return
                }

                guard let tokenJson = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
                      let accessToken = tokenJson["access_token"] as? String else {
                    state = .error("Token 响应解析失败")
                    return
                }

                let refreshToken = tokenJson["refresh_token"] as? String ?? ""
                let expiresIn = tokenJson["expires_in"] as? Int ?? 3600

                // 8. Extract accountId from JWT
                let accountId = Self.extractAccountId(from: accessToken)

                // 9. Persist credentials
                try Self.persistOpenAIOAuthProfile(
                    access: accessToken,
                    refresh: refreshToken,
                    expiresIn: expiresIn,
                    accountId: accountId,
                    homeDir: resolvedHome
                )

                saveKey(provider: .openai, apiKey: "oauth")
                state = .verified
            } catch is CancellationError {
                // Cancelled
            } catch {
                guard !Task.isCancelled else { return }
                state = .error("授权失败：\(error.localizedDescription)")
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
        availableModels = []
        selectedModelId = nil
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

    // MARK: - OpenAI OAuth Callback Server

    private final class OAuthContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private let continuation: CheckedContinuation<String, Error>

        init(_ continuation: CheckedContinuation<String, Error>) {
            self.continuation = continuation
        }

        func resume(with result: Result<String, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(with: result)
        }
    }

    nonisolated private static func sendHTMLResponse(
        on connection: NWConnection,
        status: String,
        title: String,
        message: String,
        completion: @escaping @Sendable (NWError?) -> Void
    ) {
        let html = """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>\(title)</title></head>
        <body><p>\(message)</p></body>
        </html>
        """
        let response =
            "HTTP/1.1 \(status)\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(html.utf8.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n" +
            html

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed(completion))
    }

    nonisolated private static func waitForOAuthCallback(
        expectedState: String,
        authorizeURL: URL
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let box = OAuthContinuationBox(continuation)
            let queue = DispatchQueue(label: "openai-oauth-callback")

            let listener: NWListener
            do {
                let params = NWParameters.tcp
                guard let port = NWEndpoint.Port(rawValue: 1455) else {
                    box.resume(with: .failure(NSError(
                        domain: "AuthService", code: -6,
                        userInfo: [NSLocalizedDescriptionKey: "无效的本地回调端口"]
                    )))
                    return
                }
                listener = try NWListener(using: params, on: port)
            } catch {
                box.resume(with: .failure(error))
                return
            }

            // Timeout after 120 seconds
            queue.asyncAfter(deadline: .now() + .seconds(120)) {
                listener.cancel()
                box.resume(with: .failure(NSError(
                    domain: "AuthService", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "等待授权超时"]
                )))
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    guard let data, let requestStr = String(data: data, encoding: .utf8) else {
                        box.resume(with: .failure(NSError(
                            domain: "AuthService", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "无法读取回调请求"]
                        )))
                        listener.cancel()
                        connection.cancel()
                        return
                    }

                    // Parse GET /auth/callback?code=xxx&state=xxx
                    guard let firstLine = requestStr.components(separatedBy: "\r\n").first,
                          let urlPart = firstLine.split(separator: " ").dropFirst().first,
                          let urlComponents = URLComponents(string: String(urlPart)) else {
                        box.resume(with: .failure(NSError(
                            domain: "AuthService", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "无法解析回调 URL"]
                        )))
                        listener.cancel()
                        connection.cancel()
                        return
                    }

                    let queryItems = urlComponents.queryItems ?? []
                    let callbackCode = queryItems.first(where: { $0.name == "code" })?.value
                    let callbackState = queryItems.first(where: { $0.name == "state" })?.value

                    // Check for error
                    if let errorParam = queryItems.first(where: { $0.name == "error" })?.value {
                        let errorDesc = queryItems.first(where: { $0.name == "error_description" })?.value ?? errorParam
                        Self.sendHTMLResponse(
                            on: connection,
                            status: "200 OK",
                            title: "授权失败",
                            message: "授权失败：\(errorDesc)"
                        ) { _ in
                            listener.cancel()
                            connection.cancel()
                            box.resume(with: .failure(NSError(
                                domain: "AuthService", code: -5,
                                userInfo: [NSLocalizedDescriptionKey: errorDesc]
                            )))
                        }
                        return
                    }

                    guard let authCode = callbackCode, let returnedState = callbackState else {
                        Self.sendHTMLResponse(
                            on: connection,
                            status: "400 Bad Request",
                            title: "授权失败",
                            message: "回调参数缺失"
                        ) { _ in
                            listener.cancel()
                            connection.cancel()
                            box.resume(with: .failure(NSError(
                                domain: "AuthService", code: -4,
                                userInfo: [NSLocalizedDescriptionKey: "回调缺少 code 或 state 参数"]
                            )))
                        }
                        return
                    }

                    guard returnedState == expectedState else {
                        Self.sendHTMLResponse(
                            on: connection,
                            status: "400 Bad Request",
                            title: "授权失败",
                            message: "State 验证失败"
                        ) { _ in
                            listener.cancel()
                            connection.cancel()
                            box.resume(with: .failure(NSError(
                                domain: "AuthService", code: -5,
                                userInfo: [NSLocalizedDescriptionKey: "State 验证失败"]
                            )))
                        }
                        return
                    }

                    // Success
                    Self.sendHTMLResponse(
                        on: connection,
                        status: "200 OK",
                        title: "授权成功",
                        message: "授权成功！请返回 ClawTower 继续。"
                    ) { _ in
                        listener.cancel()
                        connection.cancel()
                        box.resume(with: .success(authCode))
                    }
                }
            }

            listener.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(authorizeURL)
                    }
                case .failed(let error):
                    box.resume(with: .failure(error))
                default:
                    break
                }
            }

            listener.start(queue: queue)
        }
    }

    // MARK: - OpenAI JWT Decoding

    nonisolated private static func extractAccountId(from accessToken: String) -> String? {
        let parts = accessToken.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // accountId is at payload["https://api.openai.com/auth"]["chatgpt_account_id"]
        if let authClaim = payload["https://api.openai.com/auth"] as? [String: Any],
           let accountId = authClaim["chatgpt_account_id"] as? String {
            return accountId
        }
        return nil
    }

    // MARK: - Persist OpenAI OAuth Profile

    nonisolated private static func persistOpenAIOAuthProfile(
        access: String,
        refresh: String,
        expiresIn: Int,
        accountId: String?,
        homeDir: String
    ) throws {
        let fm = FileManager.default
        let homeURL = URL(fileURLWithPath: homeDir, isDirectory: true)

        // Write auth-profiles.json
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
        let expiresMs = Int(Date().timeIntervalSince1970 * 1000) + expiresIn * 1000
        var profileEntry: [String: Any] = [
            "type": "oauth",
            "provider": "openai-codex",
            "access": access,
            "refresh": refresh,
            "expires": expiresMs
        ]
        if let accountId {
            profileEntry["accountId"] = accountId
        }
        profiles["openai-codex:default"] = profileEntry
        authRoot["profiles"] = profiles

        let authData = try JSONSerialization.data(withJSONObject: authRoot, options: [.prettyPrinted, .sortedKeys])
        try authData.write(to: authProfilesURL, options: .atomic)

        // Write openclaw.json (deep merge)
        let configDir = homeURL.appendingPathComponent(".openclaw", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)

        let openclawConfigURL = configDir.appendingPathComponent("openclaw.json")
        var configRoot: [String: Any] = [:]
        if let data = try? Data(contentsOf: openclawConfigURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            configRoot = json
        }

        // agents.defaults.model.primary
        var agents = configRoot["agents"] as? [String: Any] ?? [:]
        var defaults = agents["defaults"] as? [String: Any] ?? [:]
        var model = defaults["model"] as? [String: Any] ?? [:]
        model["primary"] = "openai-codex/o4-mini"
        defaults["model"] = model
        agents["defaults"] = defaults
        configRoot["agents"] = agents

        // auth.profiles
        var auth = configRoot["auth"] as? [String: Any] ?? [:]
        var authProfiles = auth["profiles"] as? [String: Any] ?? [:]
        authProfiles["openai-codex:default"] = [
            "provider": "openai-codex",
            "mode": "oauth"
        ]
        auth["profiles"] = authProfiles
        configRoot["auth"] = auth

        let configData = try JSONSerialization.data(withJSONObject: configRoot, options: [.prettyPrinted, .sortedKeys])
        try configData.write(to: openclawConfigURL, options: .atomic)
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

    // MARK: - MiniMax Verification

    nonisolated private func verifyMinimaxKey(apiKey: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://api.minimax.io/anthropic/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": "MiniMax-M2.5",
            "max_tokens": 1,
            "messages": [
                ["role": "user", "content": "hi"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }

        return http.statusCode == 200
    }

    // MARK: - Moonshot Verification

    nonisolated private func verifyMoonshotKey(apiKey: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://api.moonshot.cn/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }

        return http.statusCode == 200
    }

    // MARK: - MiniMax OAuth (Native Device Code Flow)

    nonisolated private static let minimaxClientId = "78257093-7e40-4613-99e0-527b14b39113"
    nonisolated private static let minimaxBaseURL = "https://api.minimax.io"

    func authenticateMinimaxOAuth(homeDir: String? = nil) {
        currentTask?.cancel()
        state = .launching

        currentTask = Task {
            do {
                let resolvedHome = homeDir ?? FileManager.default.homeDirectoryForCurrentUser.path

                // 1. Generate PKCE
                let verifierData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                let verifier = verifierData.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")

                let challengeHash = SHA256.hash(data: Data(verifier.utf8))
                let challenge = Data(challengeHash).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")

                let stateParam = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")

                // 2. Request device code
                var codeRequest = URLRequest(url: URL(string: "\(Self.minimaxBaseURL)/oauth/code")!)
                codeRequest.httpMethod = "POST"
                codeRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                codeRequest.setValue(UUID().uuidString, forHTTPHeaderField: "x-request-id")

                let codeBody = [
                    "response_type=code",
                    "client_id=\(Self.minimaxClientId)",
                    "scope=group_id%20profile%20model.completion",
                    "code_challenge=\(challenge)",
                    "code_challenge_method=S256",
                    "state=\(stateParam)"
                ].joined(separator: "&")
                codeRequest.httpBody = codeBody.data(using: .utf8)

                let (codeData, codeResponse) = try await URLSession.shared.data(for: codeRequest)
                guard let codeHttp = codeResponse as? HTTPURLResponse, codeHttp.statusCode == 200 else {
                    let statusCode = (codeResponse as? HTTPURLResponse)?.statusCode ?? -1
                    state = .error("请求设备码失败 (HTTP \(statusCode))")
                    return
                }

                guard let codeJson = try? JSONSerialization.jsonObject(with: codeData) as? [String: Any],
                      let userCode = codeJson["user_code"] as? String,
                      let verificationUri = codeJson["verification_uri"] as? String else {
                    state = .error("解析设备码响应失败")
                    return
                }

                let expiredIn = codeJson["expired_in"] as? TimeInterval ?? 600

                guard !Task.isCancelled else { return }

                // 3. Open browser & show code
                if let browserURL = URL(string: verificationUri) {
                    NSWorkspace.shared.open(browserURL)
                }
                state = .waitingForCode(verificationUri, userCode)

                // 4. Poll for token
                var pollIntervalMs: Double = 2000
                let deadline = Date().addingTimeInterval(expiredIn)

                while !Task.isCancelled && Date() < deadline {
                    try await Task.sleep(nanoseconds: UInt64(pollIntervalMs * 1_000_000))
                    guard !Task.isCancelled else { return }

                    var tokenRequest = URLRequest(url: URL(string: "\(Self.minimaxBaseURL)/oauth/token")!)
                    tokenRequest.httpMethod = "POST"
                    tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

                    let tokenBody = [
                        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Auser_code",
                        "client_id=\(Self.minimaxClientId)",
                        "user_code=\(userCode)",
                        "code_verifier=\(verifier)"
                    ].joined(separator: "&")
                    tokenRequest.httpBody = tokenBody.data(using: .utf8)

                    let (tokenData, _) = try await URLSession.shared.data(for: tokenRequest)

                    guard let tokenJson = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
                          let status = tokenJson["status"] as? String else {
                        continue
                    }

                    if status == "success" {
                        guard let accessToken = tokenJson["access_token"] as? String,
                              let refreshToken = tokenJson["refresh_token"] as? String else {
                            state = .error("Token 响应缺少必要字段")
                            return
                        }
                        let tokenExpiredIn = tokenJson["expired_in"] as? Int ?? 3600
                        let resourceUrl = tokenJson["resource_url"] as? String

                        // 5. Persist credentials
                        try Self.persistMinimaxOAuthProfile(
                            access: accessToken,
                            refresh: refreshToken,
                            expiresIn: tokenExpiredIn,
                            resourceUrl: resourceUrl,
                            homeDir: resolvedHome
                        )
                        saveKey(provider: .minimax, apiKey: "oauth")
                        state = .verified
                        return
                    } else if status == "error" {
                        state = .error("授权失败，请重试")
                        return
                    }
                    // status == "pending" → continue polling
                    pollIntervalMs = min(pollIntervalMs * 1.5, 10000)
                }

                if !Task.isCancelled {
                    state = .error("授权超时，请重试")
                }
            } catch is CancellationError {
                // Cancelled
            } catch {
                guard !Task.isCancelled else { return }
                state = .error("授权失败：\(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func persistMinimaxOAuthProfile(
        access: String,
        refresh: String,
        expiresIn: Int,
        resourceUrl: String?,
        homeDir: String
    ) throws {
        let fm = FileManager.default
        let homeURL = URL(fileURLWithPath: homeDir, isDirectory: true)

        // Write auth-profiles.json
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
        let expiresMs = Int(Date().timeIntervalSince1970 * 1000) + expiresIn * 1000
        profiles["minimax-portal:default"] = [
            "type": "oauth",
            "provider": "minimax-portal",
            "access": access,
            "refresh": refresh,
            "expires": expiresMs
        ] as [String: Any]
        authRoot["profiles"] = profiles

        let authData = try JSONSerialization.data(withJSONObject: authRoot, options: [.prettyPrinted, .sortedKeys])
        try authData.write(to: authProfilesURL, options: .atomic)

        // Write openclaw.json (deep merge)
        let configDir = homeURL.appendingPathComponent(".openclaw", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)

        let openclawConfigURL = configDir.appendingPathComponent("openclaw.json")
        var configRoot: [String: Any] = [:]
        if let data = try? Data(contentsOf: openclawConfigURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            configRoot = json
        }

        let baseUrl = resourceUrl ?? "\(minimaxBaseURL)/anthropic"

        // models.providers.minimax-portal
        var models = configRoot["models"] as? [String: Any] ?? [:]
        var providers = models["providers"] as? [String: Any] ?? [:]
        providers["minimax-portal"] = [
            "baseUrl": baseUrl,
            "apiKey": "minimax-oauth",
            "api": "anthropic-messages",
            "models": [
                [
                    "id": "MiniMax-M2.5",
                    "name": "MiniMax M2.5",
                    "reasoning": false,
                    "input": ["text"],
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                    "contextWindow": 200000,
                    "maxTokens": 8192
                ] as [String: Any],
                [
                    "id": "MiniMax-M2.5-highspeed",
                    "name": "MiniMax M2.5 Highspeed",
                    "reasoning": true,
                    "input": ["text"],
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                    "contextWindow": 200000,
                    "maxTokens": 8192
                ] as [String: Any],
                [
                    "id": "MiniMax-M2.5-Lightning",
                    "name": "MiniMax M2.5 Lightning",
                    "reasoning": true,
                    "input": ["text"],
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                    "contextWindow": 200000,
                    "maxTokens": 8192
                ] as [String: Any]
            ]
        ] as [String: Any]
        models["providers"] = providers
        configRoot["models"] = models

        // agents.defaults.model.primary
        var agents = configRoot["agents"] as? [String: Any] ?? [:]
        var defaults = agents["defaults"] as? [String: Any] ?? [:]
        var model = defaults["model"] as? [String: Any] ?? [:]
        model["primary"] = "minimax-portal/MiniMax-M2.5"
        defaults["model"] = model
        agents["defaults"] = defaults
        configRoot["agents"] = agents

        // auth.profiles
        var auth = configRoot["auth"] as? [String: Any] ?? [:]
        var authProfiles = auth["profiles"] as? [String: Any] ?? [:]
        authProfiles["minimax-portal:default"] = [
            "provider": "minimax-portal",
            "mode": "oauth"
        ]
        auth["profiles"] = authProfiles
        configRoot["auth"] = auth

        let configData = try JSONSerialization.data(withJSONObject: configRoot, options: [.prettyPrinted, .sortedKeys])
        try configData.write(to: openclawConfigURL, options: .atomic)
    }

    // MARK: - Persist MiniMax API Key Profile

    func persistMinimaxApiKey(apiKey: String, homeDir: String? = nil) {
        currentTask?.cancel()
        state = .verifying

        currentTask = Task {
            do {
                let valid = try await verifyMinimaxKey(apiKey: apiKey)
                guard !Task.isCancelled else { return }

                if valid {
                    let resolvedHome = homeDir ?? FileManager.default.homeDirectoryForCurrentUser.path
                    try Self.persistMinimaxApiKeyProfile(apiKey: apiKey, homeDir: resolvedHome)
                    saveKey(provider: .minimax, apiKey: apiKey)
                    state = .verified
                } else {
                    state = .error("API Key 无效，请检查后重试")
                }
            } catch is CancellationError {
                // Cancelled
            } catch {
                guard !Task.isCancelled else { return }
                state = .error(error.localizedDescription)
            }
        }
    }

    nonisolated private static func persistMinimaxApiKeyProfile(apiKey: String, homeDir: String) throws {
        let fm = FileManager.default
        let homeURL = URL(fileURLWithPath: homeDir, isDirectory: true)

        // Write auth-profiles.json
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
        profiles["minimax:default"] = [
            "type": "api_key",
            "provider": "minimax",
            "key": apiKey
        ]
        authRoot["profiles"] = profiles

        let authData = try JSONSerialization.data(withJSONObject: authRoot, options: [.prettyPrinted, .sortedKeys])
        try authData.write(to: authProfilesURL, options: .atomic)

        // Write openclaw.json (merge)
        let configDir = homeURL.appendingPathComponent(".openclaw", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)

        let openclawConfigURL = configDir.appendingPathComponent("openclaw.json")
        var configRoot: [String: Any] = [:]
        if let data = try? Data(contentsOf: openclawConfigURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            configRoot = json
        }

        // models.providers.minimax
        var models = configRoot["models"] as? [String: Any] ?? [:]
        var providers = models["providers"] as? [String: Any] ?? [:]
        providers["minimax"] = [
            "baseUrl": "https://api.minimax.io/anthropic",
            "api": "anthropic-messages",
            "models": [[
                "id": "MiniMax-M2.5",
                "name": "MiniMax M2.5",
                "reasoning": false,
                "input": ["text"],
                "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                "contextWindow": 200000,
                "maxTokens": 8192
            ]]
        ] as [String: Any]
        models["providers"] = providers
        configRoot["models"] = models

        // agents.defaults.model.primary
        var agents = configRoot["agents"] as? [String: Any] ?? [:]
        var defaults = agents["defaults"] as? [String: Any] ?? [:]
        var model = defaults["model"] as? [String: Any] ?? [:]
        model["primary"] = "minimax/MiniMax-M2.5"
        defaults["model"] = model
        agents["defaults"] = defaults
        configRoot["agents"] = agents

        // auth.profiles
        var auth = configRoot["auth"] as? [String: Any] ?? [:]
        var authProfiles = auth["profiles"] as? [String: Any] ?? [:]
        authProfiles["minimax:default"] = [
            "provider": "minimax",
            "mode": "api_key"
        ]
        auth["profiles"] = authProfiles
        configRoot["auth"] = auth

        let configData = try JSONSerialization.data(withJSONObject: configRoot, options: [.prettyPrinted, .sortedKeys])
        try configData.write(to: openclawConfigURL, options: .atomic)
    }

    // MARK: - Persist Moonshot API Key Profile

    func persistMoonshotApiKey(apiKey: String, homeDir: String? = nil) {
        currentTask?.cancel()
        state = .verifying

        currentTask = Task {
            do {
                let valid = try await verifyMoonshotKey(apiKey: apiKey)
                guard !Task.isCancelled else { return }

                if valid {
                    let resolvedHome = homeDir ?? FileManager.default.homeDirectoryForCurrentUser.path
                    try Self.persistMoonshotApiKeyProfile(apiKey: apiKey, homeDir: resolvedHome)
                    saveKey(provider: .kimi, apiKey: apiKey)
                    state = .verified
                } else {
                    state = .error("API Key 无效，请检查后重试")
                }
            } catch is CancellationError {
                // Cancelled
            } catch {
                guard !Task.isCancelled else { return }
                state = .error(error.localizedDescription)
            }
        }
    }

    nonisolated private static func persistMoonshotApiKeyProfile(apiKey: String, homeDir: String) throws {
        let fm = FileManager.default
        let homeURL = URL(fileURLWithPath: homeDir, isDirectory: true)

        // Write auth-profiles.json
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
        profiles["moonshot:default"] = [
            "type": "api_key",
            "provider": "moonshot",
            "key": apiKey
        ]
        authRoot["profiles"] = profiles

        let authData = try JSONSerialization.data(withJSONObject: authRoot, options: [.prettyPrinted, .sortedKeys])
        try authData.write(to: authProfilesURL, options: .atomic)

        // Write openclaw.json (merge)
        let configDir = homeURL.appendingPathComponent(".openclaw", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)

        let openclawConfigURL = configDir.appendingPathComponent("openclaw.json")
        var configRoot: [String: Any] = [:]
        if let data = try? Data(contentsOf: openclawConfigURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            configRoot = json
        }

        // models.providers.moonshot
        var models = configRoot["models"] as? [String: Any] ?? [:]
        var providers = models["providers"] as? [String: Any] ?? [:]
        providers["moonshot"] = [
            "baseUrl": "https://api.moonshot.cn/v1",
            "api": "openai-completions",
            "models": [[
                "id": "kimi-k2.5",
                "name": "Kimi K2.5",
                "reasoning": false,
                "input": ["text", "image"],
                "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                "contextWindow": 256000,
                "maxTokens": 8192
            ]]
        ] as [String: Any]
        models["providers"] = providers
        configRoot["models"] = models

        // agents.defaults.model.primary
        var agents = configRoot["agents"] as? [String: Any] ?? [:]
        var defaults = agents["defaults"] as? [String: Any] ?? [:]
        var model = defaults["model"] as? [String: Any] ?? [:]
        model["primary"] = "moonshot/kimi-k2.5"
        defaults["model"] = model
        agents["defaults"] = defaults
        configRoot["agents"] = agents

        // auth.profiles
        var auth = configRoot["auth"] as? [String: Any] ?? [:]
        var authProfiles = auth["profiles"] as? [String: Any] ?? [:]
        authProfiles["moonshot:default"] = [
            "provider": "moonshot",
            "mode": "api_key"
        ]
        auth["profiles"] = authProfiles
        configRoot["auth"] = auth

        let configData = try JSONSerialization.data(withJSONObject: configRoot, options: [.prettyPrinted, .sortedKeys])
        try configData.write(to: openclawConfigURL, options: .atomic)
    }

    // MARK: - Z.AI Verification

    nonisolated private func verifyZaiKey(apiKey: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://open.bigmodel.cn/api/paas/v4/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    // MARK: - Qwen Verification & Model Fetch

    nonisolated private func fetchQwenModels(apiKey: String) async throws -> [AvailableModel] {
        var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else { return [] }

        return dataArray.compactMap { item in
            guard let id = item["id"] as? String,
                  id.hasPrefix("qwen") else { return nil }
            let ownedBy = item["owned_by"] as? String ?? "unknown"
            return AvailableModel(id: id, ownedBy: ownedBy)
        }.sorted { $0.id < $1.id }
    }

    // MARK: - Google Gemini Verification

    nonisolated private func verifyGoogleKey(apiKey: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)")!)
        request.httpMethod = "GET"

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    // MARK: - xAI Verification

    nonisolated private func verifyXaiKey(apiKey: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    // MARK: - OpenRouter Verification

    nonisolated private func verifyOpenRouterKey(apiKey: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    // MARK: - Generic API Key Persist (shared by new providers)

    func persistGenericApiKey(provider: Provider, apiKey: String, homeDir: String? = nil) {
        currentTask?.cancel()
        state = .verifying

        currentTask = Task {
            do {
                // Qwen: fetch models and go to model selection
                if provider == .qwen {
                    let models = try await fetchQwenModels(apiKey: apiKey)
                    guard !Task.isCancelled else { return }
                    if models.isEmpty {
                        state = .error("API Key 无效或未找到可用模型，请检查后重试")
                        return
                    }
                    availableModels = models
                    selectedModelId = models.first?.id
                    state = .modelSelection
                    return
                }

                let valid: Bool
                switch provider {
                case .zai: valid = try await verifyZaiKey(apiKey: apiKey)
                case .google: valid = try await verifyGoogleKey(apiKey: apiKey)
                case .xai: valid = try await verifyXaiKey(apiKey: apiKey)
                case .openrouter: valid = try await verifyOpenRouterKey(apiKey: apiKey)
                default: valid = false
                }
                guard !Task.isCancelled else { return }

                if valid {
                    let resolvedHome = homeDir ?? FileManager.default.homeDirectoryForCurrentUser.path
                    try Self.persistGenericApiKeyProfile(provider: provider, apiKey: apiKey, homeDir: resolvedHome)
                    saveKey(provider: provider, apiKey: apiKey)
                    state = .verified
                } else {
                    state = .error("API Key 无效，请检查后重试")
                }
            } catch is CancellationError {
                // Cancelled
            } catch {
                guard !Task.isCancelled else { return }
                state = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Generic API Key Profile Persistence

    private struct GenericProviderConfig {
        let profileKey: String
        let providerKey: String
        let baseUrl: String
        let api: String
        let models: [[String: Any]]
        let primaryModel: String
    }

    nonisolated private static func genericProviderConfig(for provider: Provider) -> GenericProviderConfig? {
        switch provider {
        case .zai:
            return GenericProviderConfig(
                profileKey: "zai:default",
                providerKey: "zai",
                baseUrl: "https://open.bigmodel.cn/api/paas/v4",
                api: "openai-completions",
                models: [[
                    "id": "glm-5",
                    "name": "GLM-5",
                    "reasoning": false,
                    "input": ["text"],
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                    "contextWindow": 128000,
                    "maxTokens": 4096
                ] as [String: Any]],
                primaryModel: "zai/glm-5"
            )
        case .qwen:
            return GenericProviderConfig(
                profileKey: "qwen:default",
                providerKey: "qwen",
                baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                api: "openai-completions",
                models: [[
                    "id": "qwen3-coder",
                    "name": "Qwen3 Coder",
                    "reasoning": false,
                    "input": ["text"],
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                    "contextWindow": 131072,
                    "maxTokens": 8192
                ] as [String: Any]],
                primaryModel: "qwen/qwen3-coder"
            )
        case .google:
            return GenericProviderConfig(
                profileKey: "google:default",
                providerKey: "google",
                baseUrl: "https://generativelanguage.googleapis.com/v1beta",
                api: "gemini",
                models: [[
                    "id": "gemini-3-pro",
                    "name": "Gemini 3 Pro",
                    "reasoning": false,
                    "input": ["text", "image"],
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                    "contextWindow": 1048576,
                    "maxTokens": 8192
                ] as [String: Any]],
                primaryModel: "google/gemini-3-pro"
            )
        case .xai:
            return GenericProviderConfig(
                profileKey: "xai:default",
                providerKey: "xai",
                baseUrl: "https://api.x.ai/v1",
                api: "openai-completions",
                models: [[
                    "id": "grok-4",
                    "name": "Grok 4",
                    "reasoning": true,
                    "input": ["text", "image"],
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                    "contextWindow": 131072,
                    "maxTokens": 16384
                ] as [String: Any]],
                primaryModel: "xai/grok-4"
            )
        case .openrouter:
            return GenericProviderConfig(
                profileKey: "openrouter:default",
                providerKey: "openrouter",
                baseUrl: "https://openrouter.ai/api/v1",
                api: "openai-completions",
                models: [[
                    "id": "anthropic/claude-sonnet-4-5",
                    "name": "Claude Sonnet 4.5 (via OpenRouter)",
                    "reasoning": false,
                    "input": ["text", "image"],
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                    "contextWindow": 200000,
                    "maxTokens": 8192
                ] as [String: Any]],
                primaryModel: "openrouter/anthropic/claude-sonnet-4-5"
            )
        default:
            return nil
        }
    }

    nonisolated private static func persistGenericApiKeyProfile(provider: Provider, apiKey: String, homeDir: String) throws {
        guard let config = genericProviderConfig(for: provider) else { return }

        let fm = FileManager.default
        let homeURL = URL(fileURLWithPath: homeDir, isDirectory: true)

        // Write auth-profiles.json
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
        profiles[config.profileKey] = [
            "type": "api_key",
            "provider": config.providerKey,
            "key": apiKey
        ]
        authRoot["profiles"] = profiles

        let authData = try JSONSerialization.data(withJSONObject: authRoot, options: [.prettyPrinted, .sortedKeys])
        try authData.write(to: authProfilesURL, options: .atomic)

        // Write openclaw.json (deep merge)
        let configDir = homeURL.appendingPathComponent(".openclaw", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)

        let openclawConfigURL = configDir.appendingPathComponent("openclaw.json")
        var configRoot: [String: Any] = [:]
        if let data = try? Data(contentsOf: openclawConfigURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            configRoot = json
        }

        // models.providers
        var models = configRoot["models"] as? [String: Any] ?? [:]
        var providers = models["providers"] as? [String: Any] ?? [:]
        providers[config.providerKey] = [
            "baseUrl": config.baseUrl,
            "api": config.api,
            "models": config.models
        ] as [String: Any]
        models["providers"] = providers
        configRoot["models"] = models

        // agents.defaults.model.primary
        var agents = configRoot["agents"] as? [String: Any] ?? [:]
        var defaults = agents["defaults"] as? [String: Any] ?? [:]
        var model = defaults["model"] as? [String: Any] ?? [:]
        model["primary"] = config.primaryModel
        defaults["model"] = model
        agents["defaults"] = defaults
        configRoot["agents"] = agents

        // auth.profiles
        var auth = configRoot["auth"] as? [String: Any] ?? [:]
        var authProfiles = auth["profiles"] as? [String: Any] ?? [:]
        authProfiles[config.profileKey] = [
            "provider": config.providerKey,
            "mode": "api_key"
        ]
        auth["profiles"] = authProfiles
        configRoot["auth"] = auth

        let configData2 = try JSONSerialization.data(withJSONObject: configRoot, options: [.prettyPrinted, .sortedKeys])
        try configData2.write(to: openclawConfigURL, options: .atomic)
    }

    // MARK: - Qwen Model Selection Persist

    func persistQwenWithSelectedModel(apiKey: String, modelId: String, homeDir: String? = nil) {
        let resolvedHome = homeDir ?? FileManager.default.homeDirectoryForCurrentUser.path
        do {
            try Self.persistQwenProfile(apiKey: apiKey, modelId: modelId, homeDir: resolvedHome)
            saveKey(provider: .qwen, apiKey: apiKey)
            state = .verified
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    nonisolated private static func persistQwenProfile(apiKey: String, modelId: String, homeDir: String) throws {
        let profileKey = "qwen:default"
        let providerKey = "qwen"
        let baseUrl = "https://dashscope.aliyuncs.com/compatible-mode/v1"

        let fm = FileManager.default
        let homeURL = URL(fileURLWithPath: homeDir, isDirectory: true)

        // Write auth-profiles.json
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
        profiles[profileKey] = [
            "type": "api_key",
            "provider": providerKey,
            "key": apiKey
        ]
        authRoot["profiles"] = profiles
        let authData = try JSONSerialization.data(withJSONObject: authRoot, options: [.prettyPrinted, .sortedKeys])
        try authData.write(to: authProfilesURL, options: .atomic)

        // Write openclaw.json
        let configDir = homeURL.appendingPathComponent(".openclaw", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        let openclawConfigURL = configDir.appendingPathComponent("openclaw.json")
        var configRoot: [String: Any] = [:]
        if let data = try? Data(contentsOf: openclawConfigURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            configRoot = json
        }

        var models = configRoot["models"] as? [String: Any] ?? [:]
        var providers = models["providers"] as? [String: Any] ?? [:]
        providers[providerKey] = [
            "baseUrl": baseUrl,
            "api": "openai-completions",
            "models": [[
                "id": modelId,
                "name": modelId,
                "reasoning": false,
                "input": ["text"],
                "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                "contextWindow": 131072,
                "maxTokens": 8192
            ] as [String: Any]]
        ] as [String: Any]
        models["providers"] = providers
        configRoot["models"] = models

        var agents = configRoot["agents"] as? [String: Any] ?? [:]
        var defaults = agents["defaults"] as? [String: Any] ?? [:]
        var model = defaults["model"] as? [String: Any] ?? [:]
        model["primary"] = "qwen/\(modelId)"
        defaults["model"] = model
        agents["defaults"] = defaults
        configRoot["agents"] = agents

        var auth = configRoot["auth"] as? [String: Any] ?? [:]
        var authProfiles = auth["profiles"] as? [String: Any] ?? [:]
        authProfiles[profileKey] = [
            "provider": providerKey,
            "mode": "api_key"
        ]
        auth["profiles"] = authProfiles
        configRoot["auth"] = auth

        // Disable qwen-portal-auth plugin to prevent alias conflict
        // (the plugin maps "qwen" → "qwen-portal" which hijacks DashScope API key auth)
        var pluginsConfig = configRoot["plugins"] as? [String: Any] ?? [:]
        var pluginEntries = pluginsConfig["entries"] as? [String: Any] ?? [:]
        pluginEntries["qwen-portal-auth"] = ["enabled": false] as [String: Any]
        pluginsConfig["entries"] = pluginEntries
        configRoot["plugins"] = pluginsConfig

        let configData = try JSONSerialization.data(withJSONObject: configRoot, options: [.prettyPrinted, .sortedKeys])
        try configData.write(to: openclawConfigURL, options: .atomic)
    }
}
