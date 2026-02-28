import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        List(selection: $state.selectedNavigation) {
            Section("概览") {
                Label("Dashboard", systemImage: "square.grid.2x2")
                    .tag(NavigationItem.dashboard)
            }

            Section("工具") {
                Label("项目", systemImage: "folder")
                    .tag(NavigationItem.projects)
                Label("定时任务", systemImage: "clock")
                    .tag(NavigationItem.cronJobs)
                Label("第二大脑", systemImage: "brain")
                    .tag(NavigationItem.secondBrain)
                Label("Skills", systemImage: "puzzlepiece")
                    .tag(NavigationItem.skills)
            }

            Section("Agents") {
                Label {
                    Text("William")
                } icon: {
                    Text("🦉")
                }
                .tag(NavigationItem.chat)
            }

            Section {
                Label("设置", systemImage: "gear")
                    .tag(NavigationItem.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("ClawTower")
    }
}
