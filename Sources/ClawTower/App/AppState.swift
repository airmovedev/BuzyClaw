import SwiftUI

@MainActor
@Observable
final class AppState {
    var gatewayManager: GatewayManager
    var gatewayClient: GatewayClient
    var selectedAgent: Agent?
    var agents: [Agent] = []
    var isOnboardingComplete: Bool

    init() {
        let port = UserDefaults.standard.integer(forKey: "gatewayPort")
        let effectivePort = port > 0 ? port : 18789
        self.gatewayManager = GatewayManager(port: effectivePort)
        self.gatewayClient = GatewayClient(baseURL: URL(string: "http://localhost:\(effectivePort)")!)
        self.isOnboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
    }

    func completeOnboarding() {
        isOnboardingComplete = true
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
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
