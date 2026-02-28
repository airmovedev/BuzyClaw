import Foundation
import SwiftUI

enum GatewayStatus: Sendable, Equatable {
    case idle
    case starting
    case running(port: Int)
    case error(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .idle: "离线"
        case .starting: "正在启动..."
        case .running: "在线"
        case .error(let msg): "错误: \(msg)"
        }
    }

    var statusColor: Color {
        switch self {
        case .idle: .gray
        case .starting: .yellow
        case .running: .green
        case .error: .red
        }
    }
}

@Observable
@MainActor
final class GatewayManager {
    var status: GatewayStatus = .idle
    private(set) var port: Int = 0
    private var process: Process?
    private var restartCount = 0
    private let maxRestarts = 3

    func start() async {
        guard !status.isRunning else { return }
        status = .starting
        restartCount = 0

        do {
            let assignedPort = Self.findAvailablePort()
            port = assignedPort

            // Phase 0 stub: simulate Gateway startup
            // In production: launch Node.js subprocess from app bundle
            // let nodePath = Bundle.main.path(forResource: "node", ofType: nil, inDirectory: "Resources")
            // process = Process()
            // process?.executableURL = URL(fileURLWithPath: nodePath!)
            // process?.arguments = ["openclaw/index.js", "--port", "\(assignedPort)", "--data-dir", dataDir]
            // try process?.run()

            try await Task.sleep(for: .seconds(1))
            status = .running(port: assignedPort)
        } catch {
            status = .error("启动失败")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        port = 0
        status = .idle
    }

    func restart() async {
        stop()
        try? await Task.sleep(for: .milliseconds(500))
        await start()
    }

    func healthCheck() async -> Bool {
        guard case .running(let port) = status else { return false }

        // Phase 0 stub: check if Gateway is responding
        let url = URL(string: "http://localhost:\(port)/health")!
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }

    private static func findAvailablePort() -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return 18080 }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return 18080 }

        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &addrLen)
            }
        }
        guard result == 0 else { return 18080 }

        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
