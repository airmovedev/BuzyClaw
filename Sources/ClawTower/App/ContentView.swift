import SwiftUI

struct ContentView: View {
    @State var appState = AppState()
    @State private var selectedNavigation: NavigationItem? = .dashboard

    var body: some View {
        Group {
            if appState.isOnboardingComplete {
                mainView
            } else {
                OnboardingView(appState: appState)
            }
        }
        .task {
            appState.gatewayManager.connect()
        }
    }

    @ViewBuilder
    private var mainView: some View {
        NavigationSplitView {
            SidebarView(appState: appState, selectedNavigation: $selectedNavigation)
                .frame(minWidth: 200)
        } detail: {
            detailView
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedNavigation {
        case .dashboard, .none:
            DashboardView()
        case .secondBrain:
            SecondBrainView()
        case .projects:
            ProjectsView()
        case .cronJobs:
            CronJobsView()
        case .skills:
            SkillsView()
        case .settings:
            SettingsView(appState: appState)
        case .chat(let agentId):
            if let agent = appState.agents.first(where: { $0.id == agentId }) ?? appState.selectedAgent {
                ChatView(
                    agent: agent,
                    client: appState.gatewayClient,
                    sessionKey: "agent:\(agent.id):\(agent.id)"
                )
            } else {
                DashboardView()
            }
        }
    }
}
