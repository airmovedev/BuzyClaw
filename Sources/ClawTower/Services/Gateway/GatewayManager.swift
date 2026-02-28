import Foundation
import Darwin

@MainActor
@Observable
final class GatewayManager {
    enum State: Sendable, Equatable {
        case stopped
        case starting
        case running
        case error(String)
    }

    // MARK: - Public State

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
        case .error(let msg): return "错误: \(msg)"
        }
    }

    // MARK: - Private

    private var process: Process?
    private var healthCheckTask: Task<Void, Never>?
    private var restartCount = 0
    private let maxRestarts = 5

    // MARK: - Start / Stop

    func startGateway() async {
        guard state == .stopped || isError else { return }
        restartCount = 0
        await launchProcess()
    }

    func stopGateway() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        terminateProcess()
        state = .stopped
    }

    func restartGateway() async {
        stopGateway()
        try? await Task.sleep(for: .milliseconds(500))
        restartCount = 0
        await launchProcess()
    }

    // MARK: - Process Lifecycle

    /// Data directory for OpenClaw: ~/Library/Application Support/ClawTower/
    private static var dataDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ClawTower")
    }

    /// Resolve node + openclaw paths. Prefers bundled runtime, falls back to system-installed (dev mode).
    private static func resolveRuntimePaths() -> (node: URL, openclaw: URL, bundled: Bool) {
        if let resourceURL = Bundle.main.resourceURL {
            let bundledNode = resourceURL.appendingPathComponent("Resources/runtime/node")
            let bundledOpenclaw = resourceURL.appendingPathComponent("Resources/runtime/openclaw/openclaw.mjs")
            if FileManager.default.fileExists(atPath: bundledNode.path)
                && FileManager.default.fileExists(atPath: bundledOpenclaw.path)
            {
                return (bundledNode, bundledOpenclaw, true)
            }
        }
        // Dev fallback
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

    private func launchProcess() async {
        state = .starting

        // Find a free port
        let freePort = Self.findFreePort()
        guard freePort > 0 else {
            state = .error("无法分配可用端口")
            return
        }
        port = freePort

        // Generate auth token
        authToken = UUID().uuidString

        // Ensure data directory exists
        let dataDir = Self.dataDirectory
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // Resolve runtime paths
        let paths = Self.resolveRuntimePaths()
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

        proc.environment = [
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "OPENCLAW_GATEWAY_TOKEN": authToken,
            "OPENCLAW_HOME": dataDir.path,
            "HOME": NSHomeDirectory()
        ]

        // Capture stdout/stderr
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                print("[Gateway stdout] \(str)", terminator: "")
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                print("[Gateway stderr] \(str)", terminator: "")
            }
        }

        // Handle unexpected termination
        proc.terminationHandler = { [weak self] terminatedProc in
            Task { @MainActor [weak self] in
                guard let self, self.process === terminatedProc else { return }
                self.pid = nil
                self.process = nil

                if self.state == .running || self.state == .starting {
                    // Unexpected crash — attempt restart
                    self.handleCrash()
                }
            }
        }

        do {
            try proc.run()
        } catch {
            state = .error("无法启动 Gateway: \(error.localizedDescription)")
            return
        }

        process = proc
        pid = proc.processIdentifier

        // Start health check loop
        startHealthCheck()
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

    private func handleCrash() {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        guard restartCount < maxRestarts else {
            state = .error("Gateway 多次崩溃，已停止重试")
            return
        }

        restartCount += 1
        let delay = Double(min(restartCount * 2, 10)) // 2s, 4s, 6s, 8s, 10s

        state = .error("Gateway 崩溃，\(Int(delay))秒后重试 (\(restartCount)/\(maxRestarts))")

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
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func checkHealth() async {
        let url = URL(string: "http://localhost:\(port)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                if state != .running {
                    state = .running
                    restartCount = 0
                }
            }
        } catch {
            if state == .starting {
                // Still waiting for process to start — don't change state
            }
        }
    }

    // MARK: - Port Allocation

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
