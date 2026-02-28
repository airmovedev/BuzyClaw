import SwiftUI

@MainActor
@Observable
final class AppState {
    var gatewayManager: GatewayManager
    var gatewayClient: GatewayClient
    var selectedAgent: Agent?
    var agents: [Agent] = []
    var isOnboardingComplete: Bool

    /// The selected AI provider and API key (stored in UserDefaults for now).
    var selectedProvider: AuthService.Provider? {
        guard let raw = UserDefaults.standard.string(forKey: "selectedProvider"),
              let provider = AuthService.Provider(rawValue: raw) else { return nil }
        return provider
    }

    var apiKey: String? {
        UserDefaults.standard.string(forKey: "apiKey")
    }

    init() {
        self.gatewayManager = GatewayManager()
        self.gatewayClient = GatewayClient(baseURL: URL(string: "http://localhost:0")!)
        self.isOnboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
    }

    func completeOnboarding() {
        isOnboardingComplete = true
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
    }

    /// Start the gateway subprocess and update the client with the new port/token.
    func startGateway() async {
        await gatewayManager.startGateway()

        // Update client to point at the gateway's actual port and token
        let url = URL(string: "http://localhost:\(gatewayManager.port)")!
        gatewayClient.updateBaseURL(url)
        gatewayClient.setAuthToken(gatewayManager.authToken)

        // Wait for gateway to become healthy (up to 30s)
        for _ in 0..<30 {
            if gatewayManager.isRunning { break }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func stopGateway() {
        gatewayManager.stopGateway()
    }

    func restartGateway() async {
        await gatewayManager.restartGateway()

        let url = URL(string: "http://localhost:\(gatewayManager.port)")!
        gatewayClient.updateBaseURL(url)
        gatewayClient.setAuthToken(gatewayManager.authToken)
    }

    func loadAgents() async {
        do {
            agents = try await gatewayClient.listAgents()
            if selectedAgent == nil, let first = agents.first {
                selectedAgent = first
            }
        } catch {
            // Gateway not reachable yet
        }
    }

    var sessionKey: String {
        guard let agent = selectedAgent else { return "agent:main:main" }
        return "agent:\(agent.id):\(agent.id)"
    }
}
