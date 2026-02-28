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
    private var authToken: String?

    init(port: Int = 18789) {
        self.baseURL = URL(string: "http://localhost:\(port)")!
        self.authToken = GatewayClient.readAuthToken()
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
        // Use the base URL for health check
        var request = URLRequest(url: baseURL)
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
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
