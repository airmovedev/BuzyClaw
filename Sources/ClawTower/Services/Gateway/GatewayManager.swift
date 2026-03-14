import Foundation
import Darwin

enum GatewayMode: String, Sendable, CaseIterable {
    case existingInstall
    case freshInstall
}

@MainActor
@Observable
final class GatewayManager {
    enum State: Sendable, Equatable {
        case stopped
        case starting
        case running
        case reconnecting(since: Date)
        case disconnected
        case error(String)
    }

    // MARK: - Public State

    var mode: GatewayMode = .freshInstall
    private(set) var state: State = .stopped
    private(set) var port: Int = 0
    private(set) var authToken: String = ""
    private(set) var pid: Int32? = nil

    var isRunning: Bool { state == .running }

    var statusText: String {
        switch state {
        case .stopped: return "已停止"
        case .starting: return "启动中..."
        case .running: return "运行中 (端口 \(port))"
        case .reconnecting: return "重连中..."
        case .disconnected: return "连接断开"
        case .error(let msg): return "错误: \(msg)"
        }
    }

    var isConnectionWarning: Bool {
        switch state {
        case .reconnecting, .disconnected:
            return true
        default:
            return false
        }
    }

    var isReconnecting: Bool {
        if case .reconnecting = state { return true }
        return false
    }

    // MARK: - Private

    private var process: Process?
    private var healthCheckTask: Task<Void, Never>?
    private var restartCount = 0
    private let maxRestarts = 1
    private var usingExternalGateway = false
    private var startingAt: Date?
    private var recentStderr: String = ""
    private var recentStdout: String = ""
    private var connectionLostAt: Date?

    // MARK: - Start / Stop

    func startGateway() async {
        guard state == .stopped || isError else { return }
        restartCount = 0

        switch mode {
        case .existingInstall:
            // Only try connecting to an existing gateway — never launch our own process
            if await tryConnectExisting() {
                return
            }
            state = .error("未找到运行中的 Gateway，请先启动 OpenClaw 服务")

        case .freshInstall:
            // Fresh install always launches its own isolated process
            await launchProcess()
        }
    }

    /// Try connecting to an existing gateway on the default port (18789).
    /// Returns true if successful (reuses existing gateway).
    private func tryConnectExisting() async -> Bool {
        let existingPort = 18789
        let existingToken = GatewayClient.readAuthToken()

        let url = URL(string: "http://localhost:\(existingPort)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        if let token = existingToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                port = existingPort
                authToken = existingToken ?? ""
                state = .running
                connectionLostAt = nil
                usingExternalGateway = true
                print("[Gateway] Connected to existing gateway on port \(existingPort)")
                startHealthCheck()
                return true
            }
        } catch {
            // No existing gateway — will start our own
        }
        return false
    }

    func stopGateway() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        if !usingExternalGateway {
            terminateProcess()
        }
        usingExternalGateway = false
        connectionLostAt = nil
        state = .stopped
    }

    /// Call before writing config changes to openclaw.json.
    /// Resets crash counters so the expected restart from config file watching
    /// doesn't exhaust the auto-restart limit.
    func prepareForConfigChange() {
        restartCount = 0
    }

    func restartGateway() async {
        if mode == .existingInstall {
            // Send restart signal to existing gateway via API
            let url = URL(string: "http://localhost:\(port)/api/gateway/restart")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 5

            _ = try? await URLSession.shared.data(for: request)

            // Wait for gateway to restart
            state = .starting
            try? await Task.sleep(for: .seconds(3))

            // Reconnect
            if await tryConnectExisting() {
                return
            }
            state = .error("Gateway 重启后无法重新连接")
        } else {
            stopGateway()
            try? await Task.sleep(for: .milliseconds(500))
            restartCount = 0
            await launchProcess()
        }
    }

    // MARK: - Process Lifecycle

    /// Resolve node + openclaw paths.
    /// - freshInstall: requires bundled runtime (never falls back to system)
    /// - existingInstall: prefers bundled runtime, allows system fallback for dev mode
    private static func resolveRuntimePaths(for mode: GatewayMode) -> (node: URL, openclaw: URL, bundled: Bool)? {
        if let resourceURL = Bundle.main.resourceURL {
            let bundledNode = resourceURL.appendingPathComponent("Resources/runtime/node")
            let bundledOpenclaw = resourceURL.appendingPathComponent("Resources/runtime/openclaw/openclaw.mjs")
            if FileManager.default.fileExists(atPath: bundledNode.path)
                && FileManager.default.fileExists(atPath: bundledOpenclaw.path)
            {
                return (bundledNode, bundledOpenclaw, true)
            }
            print("[Gateway] Bundled runtime NOT found. Tried: \(bundledNode.path) and \(bundledOpenclaw.path)")
        }

        if mode == .freshInstall {
            return nil
        }

        // Dev fallback (existing install mode only)
        return (
            URL(fileURLWithPath: "/usr/local/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/openclaw"),
            false
        )
    }

    /// Ensure the node binary has execute permission.
    private static func ensureExecutable(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let perms = attrs[.posixPermissions] as? Int
        else { return }
        if perms & 0o111 == 0 {
            try? fm.setAttributes([.posixPermissions: perms | 0o755], ofItemAtPath: url.path)
        }
    }

    /// Create or update HOME/.openclaw/openclaw.json for fresh install mode.
    /// This guarantees gateway.auth.token matches the runtime token used by the client.
    private static func upsertGatewayConfig(at configFile: URL, authToken: String, port: Int) {
        var root: [String: Any] = [:]

        if let data = try? Data(contentsOf: configFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        }

        // Cleanup invalid keys written by older builds (causes "Config invalid" -> exit code 1)
        if var agents = root["agents"] as? [String: Any],
           var defaults = agents["defaults"] as? [String: Any] {
            if defaults["sessionMemory"] != nil {
                defaults.removeValue(forKey: "sessionMemory")
            }
            if defaults["memorySearch"] is Bool {
                defaults.removeValue(forKey: "memorySearch")
            }
            if var compaction = defaults["compaction"] as? [String: Any], compaction["memoryFlush"] is Bool {
                compaction.removeValue(forKey: "memoryFlush")
                defaults["compaction"] = compaction
            }
            agents["defaults"] = defaults
            root["agents"] = agents
        }

        var gateway = root["gateway"] as? [String: Any] ?? [:]
        gateway["mode"] = gateway["mode"] ?? "local"
        gateway["port"] = port

        var auth = gateway["auth"] as? [String: Any] ?? [:]
        auth["mode"] = "token"
        auth["token"] = authToken
        gateway["auth"] = auth

        var http = gateway["http"] as? [String: Any] ?? [:]
        var endpoints = http["endpoints"] as? [String: Any] ?? [:]
        var chatCompletions = endpoints["chatCompletions"] as? [String: Any] ?? [:]
        chatCompletions["enabled"] = true
        endpoints["chatCompletions"] = chatCompletions
        http["endpoints"] = endpoints
        gateway["http"] = http

        root["gateway"] = gateway

        // tools.agentToAgent — Agent 间消息互发
        var tools = root["tools"] as? [String: Any] ?? [:]
        var agentToAgent = tools["agentToAgent"] as? [String: Any] ?? [:]
        agentToAgent["enabled"] = agentToAgent["enabled"] ?? true
        agentToAgent["allow"] = agentToAgent["allow"] ?? ["*"]
        tools["agentToAgent"] = agentToAgent

        // Ensure tools.profile is set (3.2 defaults to "messaging" which breaks cron/exec)
        if tools["profile"] == nil {
            tools["profile"] = "full"
        }

        // IMPORTANT: Do NOT set tools.allow — it's a whitelist that blocks all other tools.
        // If a previous build wrote tools.allow: ["cron"], remove it so all tools are available.
        if let existingAllow = tools["allow"] as? [String], existingAllow == ["cron"] {
            tools.removeValue(forKey: "allow")
        }

        root["tools"] = tools

        // Enable cron at the Gateway HTTP API level (cron is denied by default there)
        var gatewayTools = gateway["tools"] as? [String: Any] ?? [:]
        var gatewayAllow = gatewayTools["allow"] as? [String] ?? []
        if !gatewayAllow.contains("cron") {
            gatewayAllow.append("cron")
        }
        gatewayTools["allow"] = gatewayAllow
        gateway["tools"] = gatewayTools
        root["gateway"] = gateway

        // Ensure agents.list includes at least the "main" agent so the sidebar always shows it
        var agentsConfig = root["agents"] as? [String: Any] ?? [:]
        var agentsList = agentsConfig["list"] as? [[String: Any]] ?? []
        let hasMain = agentsList.contains { ($0["id"] as? String)?.lowercased() == "main" }
        if !hasMain {
            agentsList.insert(["id": "main"] as [String: Any], at: 0)
        }
        agentsConfig["list"] = agentsList
        root["agents"] = agentsConfig

        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configFile, options: .atomic)
        }

        // Validate config after writing
        let openclawPath: String? = {
            // Prefer bundled runtime
            if let resourceURL = Bundle.main.resourceURL {
                let bundledNode = resourceURL.appendingPathComponent("Resources/runtime/node")
                let bundledOpenclaw = resourceURL.appendingPathComponent("Resources/runtime/openclaw/openclaw.mjs")
                if FileManager.default.fileExists(atPath: bundledNode.path)
                    && FileManager.default.fileExists(atPath: bundledOpenclaw.path) {
                    return bundledNode.path  // Will run: node openclaw.mjs config validate
                }
            }
            // Fall back to system openclaw
            for candidate in ["/usr/local/bin/openclaw", "/opt/homebrew/bin/openclaw"] {
                if FileManager.default.fileExists(atPath: candidate) {
                    return candidate
                }
            }
            return nil
        }()

        if let openclawPath {
            let validateProcess = Process()
            let validatePipe = Pipe()
            validateProcess.standardError = validatePipe

            // Determine if we're using bundled node+mjs or system CLI
            if openclawPath.hasSuffix("/node"), let resourceURL = Bundle.main.resourceURL {
                let mjsPath = resourceURL.appendingPathComponent("Resources/runtime/openclaw/openclaw.mjs").path
                validateProcess.executableURL = URL(fileURLWithPath: openclawPath)
                validateProcess.arguments = [mjsPath, "config", "validate"]
            } else {
                validateProcess.executableURL = URL(fileURLWithPath: openclawPath)
                validateProcess.arguments = ["config", "validate"]
            }

            validateProcess.environment = [
                "HOME": configFile.deletingLastPathComponent().deletingLastPathComponent().path,
                "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
            ]

            do {
                try validateProcess.run()
                validateProcess.waitUntilExit()
                if validateProcess.terminationStatus != 0 {
                    let stderr = String(data: validatePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    print("[Gateway] ⚠️ Config validation failed: \(stderr)")
                }
            } catch {
                print("[Gateway] ⚠️ Config validation skipped: \(error.localizedDescription)")
            }
        }
    }

    private func launchProcess() async {
        recentStderr = ""
        recentStdout = ""
        state = .starting
        startingAt = Date()

        // Reuse saved port if available and free; otherwise allocate a new one
        let resolvedPort: Int
        if let savedPort = UserDefaults.standard.object(forKey: "gateway.port") as? Int,
           savedPort > 0, Self.isPortAvailable(savedPort) {
            resolvedPort = savedPort
        } else {
            resolvedPort = Self.findFreePort()
        }
        guard resolvedPort > 0 else {
            state = .error("无法分配可用端口")
            return
        }
        port = resolvedPort
        UserDefaults.standard.set(resolvedPort, forKey: "gateway.port")

        // Reuse persisted token if available (stable across launches), otherwise generate new
        if let savedToken = UserDefaults.standard.string(forKey: "gateway.authToken"), !savedToken.isEmpty {
            authToken = savedToken
        } else {
            authToken = UUID().uuidString
            UserDefaults.standard.set(authToken, forKey: "gateway.authToken")
        }

        // Data directory: use existing ~/.openclaw/ for now (shared with CLI)
        // Future: migrate to ~/Library/Application Support/ClawTower/

        // Resolve runtime paths
        guard let paths = Self.resolveRuntimePaths(for: mode) else {
            state = .error("Gateway 启动失败：fresh install 模式要求使用应用内置 OpenClaw runtime，但未找到 bundled runtime")
            return
        }
        Self.ensureExecutable(paths.node)

        if paths.bundled {
            print("[Gateway] Using bundled runtime: \(paths.node.path)")
        } else {
            print("[Gateway] Using system runtime (dev mode): \(paths.node.path)")
        }

        // Set up the process
        let proc = Process()
        proc.executableURL = paths.node

        if paths.bundled {
            proc.arguments = [
                paths.openclaw.path, "gateway",
                "--port", "\(port)",
                "--allow-unconfigured",
                "--bind", "loopback"
            ]
        } else {
            // System openclaw is a standalone CLI, not an .mjs file
            proc.arguments = [
                paths.openclaw.path, "gateway",
                "--port", "\(port)",
                "--allow-unconfigured",
                "--bind", "loopback"
            ]
        }

        // Both freshInstall and existingInstall use ~/.openclaw as data directory
        let homeDir = NSHomeDirectory()
        let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let configFile = configDir.appendingPathComponent("openclaw.json")
        Self.upsertGatewayConfig(at: configFile, authToken: authToken, port: port)
        print("[Gateway] Ensured gateway config at \(configFile.path)")

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        env["OPENCLAW_GATEWAY_TOKEN"] = authToken
        env["HOME"] = homeDir
        env["NODE_NO_WARNINGS"] = "1"
        env["OPENCLAW_ALLOW_MULTI_GATEWAY"] = "1"
        proc.environment = env

        // Capture stdout/stderr
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                print("[Gateway stdout] \(str)", terminator: "")
                Task { @MainActor in
                    self?.recentStdout += str
                    if self?.recentStdout.count ?? 0 > 2000 {
                        self?.recentStdout = String(self?.recentStdout.suffix(2000) ?? "")
                    }
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                print("[Gateway stderr] \(str)", terminator: "")
                Task { @MainActor in
                    self?.recentStderr += str
                    if self?.recentStderr.count ?? 0 > 2000 {
                        self?.recentStderr = String(self?.recentStderr.suffix(2000) ?? "")
                    }
                }
            }
        }

        // Handle unexpected termination
        proc.terminationHandler = { [weak self] terminatedProc in
            let exitCode = terminatedProc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.process === terminatedProc else { return }
                self.pid = nil
                self.process = nil

                if self.state == .running || self.state == .starting {
                    // Unexpected crash — attempt restart
                    self.handleCrash(exitCode: exitCode)
                }
            }
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: paths.node.path) {
            state = .error("Gateway 启动失败：找不到 Node.js\n路径: \(paths.node.path)\nBundled: \(paths.bundled)")
            return
        }
        if !fm.isExecutableFile(atPath: paths.node.path) {
            state = .error("Gateway 启动失败：Node.js 没有执行权限\n路径: \(paths.node.path)")
            return
        }
        if !fm.fileExists(atPath: paths.openclaw.path) {
            state = .error("Gateway 启动失败：找不到 OpenClaw\n路径: \(paths.openclaw.path)\nBundled: \(paths.bundled)")
            return
        }

        do {
            try proc.run()
        } catch {
            state = .error("无法启动 Gateway: \(error.localizedDescription)\nNode: \(paths.node.path)\nBundled: \(paths.bundled)")
            return
        }

        process = proc
        pid = proc.processIdentifier

        // Wait for gateway to become ready before starting periodic health checks
        let ready = await waitForGatewayReady(port: port, token: authToken, timeout: 30)
        if ready {
            state = .running
            connectionLostAt = nil
            restartCount = 0
        }

        // Start periodic health check loop (handles ongoing monitoring + crash recovery)
        startHealthCheck()
    }

    /// Polls the /health endpoint until the gateway responds with 200 or timeout is reached.
    private func waitForGatewayReady(port: Int, token: String, timeout: TimeInterval = 30) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            guard state == .starting else { return false } // Process may have crashed
            if let url = URL(string: "http://127.0.0.1:\(port)/health") {
                var request = URLRequest(url: url, timeoutInterval: 2)
                request.httpMethod = "GET"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
        return false
    }

    private func terminateProcess() {
        guard let proc = process, proc.isRunning else {
            process = nil
            pid = nil
            return
        }

        // SIGTERM first
        proc.terminate()

        // Wait up to 3 seconds, then SIGKILL
        Task.detached {
            try? await Task.sleep(for: .seconds(3))
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }

        process = nil
        pid = nil
    }

    private func handleCrash(exitCode: Int32 = -1) {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        let detail = recentStderr.isEmpty ? "" : "\n\n日志:\n\(recentStderr.suffix(500))"

        guard restartCount < maxRestarts else {
            state = .error("Gateway 多次崩溃，已停止重试 (exit code: \(exitCode))\(detail)")
            return
        }

        restartCount += 1
        let delay = Double(min(restartCount * 2, 10)) // 2s, 4s, 6s, 8s, 10s

        state = .error("Gateway 崩溃 (exit code: \(exitCode))，\(Int(delay))秒后重试 (\(restartCount)/\(maxRestarts))\(detail)")

        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard self.state != .stopped else { return }
            await self.launchProcess()
        }
    }

    // MARK: - Health Check

    private func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            guard let self else { return }
            // Initial delay to let the process start
            try? await Task.sleep(for: .seconds(1))

            while !Task.isCancelled {
                await self.checkHealth()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func checkHealth() async {
        let url = URL(string: "http://localhost:\(port)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                connectionLostAt = nil
                if state != .running {
                    state = .running
                    restartCount = 0
                }
                return
            }

            handleUnhealthyConnection()
        } catch {
            if state == .starting {
                if let startedAt = startingAt, Date().timeIntervalSince(startedAt) > 15 {
                    state = .error("Gateway 启动超时（15秒无响应）\nPort: \(port)\nNode: \(process?.executableURL?.path ?? "nil")\nPID: \(pid?.description ?? "nil")")
                }
                return
            }

            handleUnhealthyConnection()
        }
    }

    private func handleUnhealthyConnection(now: Date = Date()) {
        if connectionLostAt == nil {
            connectionLostAt = now
        }

        let lostAt = connectionLostAt ?? now
        let outageDuration = now.timeIntervalSince(lostAt)

        if outageDuration >= 10 {
            state = .disconnected
        } else {
            state = .reconnecting(since: lostAt)
        }
    }

    // MARK: - Port Allocation

    /// Check whether a specific port is available for binding on loopback.
    private static func isPortAvailable(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func findFreePort() -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return 0 }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // Let OS pick
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else { return 0 }

        let getsockResult = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(sock, sockPtr, &addrLen)
            }
        }
        guard getsockResult == 0 else { return 0 }

        return Int(UInt16(bigEndian: addr.sin_port))
    }

    // MARK: - Helpers

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }
}
