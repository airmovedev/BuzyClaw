import SwiftUI

@MainActor
@Observable
final class AppState {
    var gatewayManager: GatewayManager
    var gatewayClient: GatewayClient
    var selectedAgent: Agent?
    var agents: [Agent] = []
    var isOnboardingComplete: Bool

    /// Path to the openclaw binary.
    /// In production, this resolves to the bundled binary inside Resources/.
    /// For development, falls back to the system-installed openclaw.
    var openclawPath: String

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
        let port = UserDefaults.standard.integer(forKey: "gatewayPort")
        let effectivePort = port > 0 ? port : 18789
        self.gatewayManager = GatewayManager(port: effectivePort)
        self.gatewayClient = GatewayClient(baseURL: URL(string: "http://localhost:\(effectivePort)")!)
        self.isOnboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")

        if let bundled = Bundle.main.path(forResource: "openclaw", ofType: nil) {
            self.openclawPath = bundled
        } else {
            self.openclawPath = "/usr/local/bin/openclaw"
        }
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
