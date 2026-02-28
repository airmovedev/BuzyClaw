import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.showOnboarding {
                OnboardingView()
            } else {
                MainView()
            }
        }
    }
}

struct MainView: View {
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

struct DetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.selectedNavigation {
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
        case .chat:
            ChatView()
        case .settings:
            SettingsView()
        }
    }
}
