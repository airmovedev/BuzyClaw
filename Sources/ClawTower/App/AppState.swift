import SwiftUI

@Observable
@MainActor
final class AppState {
    var showOnboarding: Bool
    var selectedNavigation: NavigationItem? = .dashboard
    var gatewayManager = GatewayManager()
    var gatewayClient = GatewayClient()

    init() {
        self.showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingCompleted")
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        showOnboarding = false
        Task {
            await startGateway()
        }
    }

    func startGateway() async {
        await gatewayManager.start()
        if case .running(let port) = gatewayManager.status {
            gatewayClient.configure(port: port)
        }
    }

    func stopGateway() {
        gatewayManager.stop()
    }

    func saveAPIKey(_ key: String) {
        // Phase 0: UserDefaults stub. Production: store in Keychain.
        UserDefaults.standard.set(key, forKey: "apiKey")
    }

    func loadAPIKey() -> String {
        UserDefaults.standard.string(forKey: "apiKey") ?? ""
    }
}
