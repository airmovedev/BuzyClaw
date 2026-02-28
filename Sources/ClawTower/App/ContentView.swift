import SwiftUI

struct ContentView: View {
    @State var appState = AppState()

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
            SidebarView(appState: appState)
                .frame(minWidth: 200)
        } detail: {
            if let agent = appState.selectedAgent {
                ChatView(
                    agent: agent,
                    client: appState.gatewayClient,
                    sessionKey: appState.sessionKey
                )
            } else {
                DashboardView()
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
