import Foundation

@MainActor
@Observable
final class GatewayManager {
    enum State: Sendable {
        case idle
        case connecting
        case connected
        case error(String)
    }

    var state: State = .idle
    var baseURL: URL

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var statusText: String {
        switch state {
        case .idle: return "未连接"
        case .connecting: return "连接中..."
        case .connected: return "已连接"
        case .error(let msg): return "错误: \(msg)"
        }
    }

    private var healthCheckTask: Task<Void, Never>?

    init(port: Int = 18789) {
        self.baseURL = URL(string: "http://localhost:\(port)")!
    }

    func connect() {
        state = .connecting
        startHealthCheck()
    }

    func disconnect() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        state = .idle
    }

    private func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkHealth()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func checkHealth() async {
        let url = baseURL.appendingPathComponent("api/v1/status")
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                if !isConnected {
                    state = .connected
                }
            } else {
                state = .error("Gateway 无响应")
            }
        } catch {
            if isConnected {
                state = .error("连接断开")
            } else {
                state = .connecting
            }
        }
    }
}
