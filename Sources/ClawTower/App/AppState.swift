import Security
import SwiftUI

@MainActor
@Observable
final class AppState {
    var gatewayManager: GatewayManager
    var gatewayClient: GatewayClient
    var cloudKitRelay: CloudKitRelayService?
    var dashboardSync: DashboardSyncService?
    var selectedAgent: Agent?
    var agents: [Agent] = []
    var unreadAgentIDs: Set<String> = []
    var chatDrafts: [String: ChatDraft] = [:]
    var subagentRefreshTrigger: Int = 0
    var trackedSubagentKeys: Set<String> = []
    var isOnboardingComplete: Bool
    var gatewayMode: GatewayMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "gatewayMode"),
                  let mode = GatewayMode(rawValue: raw) else { return .freshInstall }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "gatewayMode")
            gatewayManager.mode = newValue
        }
    }

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
        let manager = GatewayManager()
        if let raw = UserDefaults.standard.string(forKey: "gatewayMode"),
           let mode = GatewayMode(rawValue: raw) {
            manager.mode = mode
        }
        self.gatewayManager = manager
        self.gatewayClient = GatewayClient(baseURL: URL(string: "http://localhost:0")!)
        let flaggedComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
        if flaggedComplete {
            // Validate that the data directory actually exists; if the user wiped
            // ~/.openclaw the flag is stale.
            let openclawDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw")
            let configExists = FileManager.default.fileExists(atPath: openclawDir.appendingPathComponent("openclaw.json").path)
            if configExists {
                self.isOnboardingComplete = true
            } else {
                self.isOnboardingComplete = false
                UserDefaults.standard.set(false, forKey: "onboardingComplete")
                UserDefaults.standard.removeObject(forKey: "gateway.authToken")
            }
        } else {
            self.isOnboardingComplete = false
        }
    }

    func triggerSubagentRefresh() {
        subagentRefreshTrigger += 1
    }

    func addTrackedSubagent(_ key: String) {
        trackedSubagentKeys.insert(key)
    }

    func removeTrackedSubagents(_ keys: Set<String>) {
        trackedSubagentKeys.subtract(keys)
    }

    func clearAllTrackedSubagents() {
        trackedSubagentKeys.removeAll()
    }

    func completeOnboarding() {
        isOnboardingComplete = true
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
    }

    func resetOnboarding() {
        isOnboardingComplete = false
        UserDefaults.standard.set(false, forKey: "onboardingComplete")
        // 清理相关状态
        UserDefaults.standard.removeObject(forKey: "gatewayMode")
        UserDefaults.standard.removeObject(forKey: "selectedProvider")
        UserDefaults.standard.removeObject(forKey: "apiKey")
        UserDefaults.standard.removeObject(forKey: "gateway.authToken")
        UserDefaults.standard.removeObject(forKey: "gateway.port")
        // 停止当前 Gateway
        stopGateway()
    }

    /// Start the gateway subprocess and update the client with the new port/token.
    func startGateway() async {
        await gatewayManager.startGateway()

        // Update client to point at the gateway's actual port and token
        let url = URL(string: "http://localhost:\(gatewayManager.port)")!
        gatewayClient.updateBaseURL(url)
        gatewayClient.setAuthToken(gatewayManager.authToken)
        NSLog("[AppState] Gateway client updated: baseURL=\(url), tokenPresent=\(gatewayManager.authToken.isEmpty ? "NO" : "YES"), mode=\(gatewayManager.mode)")

        // Wait for gateway to become healthy (up to 30s)
        for _ in 0..<30 {
            if gatewayManager.isRunning { break }
            try? await Task.sleep(for: .seconds(1))
        }

        // Start CloudKit Relay once gateway is running (non-critical, failure won't affect app)
        if gatewayManager.isRunning {
            guard isCloudKitRelayAvailable else {
                NSLog("[AppState] CloudKit relay skipped: missing CloudKit entitlement or container configuration")
                return
            }

            let relayURL = URL(string: "http://localhost:\(gatewayManager.port)")!
            let relayToken = gatewayManager.authToken
            let relay = CloudKitRelayService()
            self.cloudKitRelay = relay

            Task {
                await relay.ensureZoneExists()
                if let error = relay.lastError {
                    NSLog("[AppState] CloudKit relay ensureZoneExists issue (non-fatal): %@", error)
                }
            }

            relay.start(gatewayBaseURL: relayURL, authToken: relayToken)
            if let error = relay.lastError {
                NSLog("[AppState] CloudKit relay startup issue (non-fatal): %@", error)
            }

            // Start Dashboard sync for iOS
            let sync = DashboardSyncService()
            self.dashboardSync = sync
            sync.start(appState: self)
        }
    }

    private var isCloudKitRelayAvailable: Bool {
        hasEntitlement("com.apple.developer.icloud-container-identifiers") ||
        hasEntitlement("com.apple.developer.ubiquity-container-identifiers") ||
        hasCloudKitServicesEntitlement
    }

    private var hasCloudKitServicesEntitlement: Bool {
        guard let services = entitlementValue(forKey: "com.apple.developer.icloud-services") as? [String] else {
            return false
        }
        return services.contains("CloudKit")
    }

    private func hasEntitlement(_ key: String) -> Bool {
        guard let value = entitlementValue(forKey: key) else { return false }

        if let stringValue = value as? String {
            return !stringValue.isEmpty
        }

        if let arrayValue = value as? [String] {
            return !arrayValue.isEmpty
        }

        return true
    }

    private func entitlementValue(forKey key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        return value as Any?
    }

    func stopGateway() {
        dashboardSync?.stop()
        cloudKitRelay?.stop()
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
            let previousSelectedAgentID = selectedAgent?.id
            var fetched = try await gatewayClient.listAgents()
            for i in fetched.indices {
                enrichAgentFromIdentity(&fetched[i])
            }
            if agents.isEmpty && !fetched.isEmpty {
                NSLog("[AppState] Agents loaded: \(fetched.map { $0.id }.joined(separator: ", "))")
            }
            agents = fetched

            if let previousSelectedAgentID,
               let refreshedSelection = agents.first(where: { $0.id == previousSelectedAgentID }) {
                selectedAgent = refreshedSelection
            } else if let mainAgent = agents.first(where: { $0.id == "main" }) {
                selectedAgent = mainAgent
            } else {
                selectedAgent = agents.first
            }

            await refreshUnreadState()
        } catch {
            NSLog("[AppState] loadAgents failed: \(error)")
        }
    }

    func enrichAgentFromIdentity(_ agent: inout Agent) {
        let identityURL: URL
        if agent.id == "main" {
            identityURL = openclawBasePath.appendingPathComponent("workspace/IDENTITY.md")
        } else {
            identityURL = openclawBasePath.appendingPathComponent("agents/\(agent.id)/workspace/IDENTITY.md")
        }

        guard let content = try? String(contentsOf: identityURL, encoding: .utf8) else { return }

        for line in content.components(separatedBy: .newlines) {
            if line.contains("**Name:**") {
                let value = line.components(separatedBy: "**Name:**").last?.trimmingCharacters(in: .whitespaces) ?? ""
                if !value.isEmpty { agent.displayName = value }
            }
            if line.contains("**Emoji:**") {
                let value = line.components(separatedBy: "**Emoji:**").last?.trimmingCharacters(in: .whitespaces) ?? ""
                if !value.isEmpty { agent.emoji = value }
            }
        }
    }

    func refreshUnreadState() async {
        var unread = Set<String>()
        for agent in agents {
            guard let sessions = try? await gatewayClient.listSessions(agentId: agent.id, limit: 20) else { continue }
            let lastRead = UserDefaults.standard.double(forKey: "lastRead.\(agent.id)")
            let hasUnread = sessions.contains { session in
                if let latest = session.updatedAt?.timeIntervalSince1970, latest > lastRead {
                    return true
                }
                return false
            }
            if hasUnread {
                unread.insert(agent.id)
            }
        }
        unreadAgentIDs = unread
    }

    func removeAgentLocally(_ agentID: String) {
        agents.removeAll { $0.id == agentID }
        if selectedAgent?.id == agentID {
            selectedAgent = agents.first(where: { $0.id == "main" }) ?? agents.first
        }
    }

    func markAgentAsRead(_ agentID: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastRead.\(agentID)")
        unreadAgentIDs.remove(agentID)
    }

    // MARK: - Path Properties

    /// The base .openclaw directory path — always ~/.openclaw regardless of gateway mode
    var openclawBasePath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw")
    }

    var workspacePath: URL { openclawBasePath.appendingPathComponent("workspace") }
    var projectsPath: URL { openclawBasePath.appendingPathComponent("Projects") }
    var tasksFilePath: URL { openclawBasePath.appendingPathComponent("tasks.json") }
    var secondBrainPath: URL { workspacePath.appendingPathComponent("second-brain") }

    var sessionKey: String {
        guard let agent = selectedAgent else { return "agent:main:main" }
        return "agent:\(agent.id):\(agent.id)"
    }
}
