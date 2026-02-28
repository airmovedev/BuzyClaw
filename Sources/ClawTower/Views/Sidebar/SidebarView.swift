import SwiftUI

struct SidebarView: View {
    @Bindable var appState: AppState
    @Binding var selectedNavigation: NavigationItem?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedNavigation) {
                Section("导航") {
                    NavigationLink(value: NavigationItem.dashboard) {
                        Label("Dashboard", systemImage: "square.grid.2x2")
                    }

                    NavigationLink(value: NavigationItem.secondBrain) {
                        Label("第二大脑", systemImage: "books.vertical")
                    }

                    NavigationLink(value: NavigationItem.projects) {
                        Label("项目", systemImage: "folder")
                    }

                    NavigationLink(value: NavigationItem.cronJobs) {
                        Label("定时任务", systemImage: "clock.badge.checkmark")
                    }

                    NavigationLink(value: NavigationItem.skills) {
                        Label("Skills", systemImage: "puzzlepiece")
                    }
                }

                Section("Agents") {
                    if appState.agents.isEmpty {
                        Text("连接 Gateway 后显示")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(appState.agents) { agent in
                            NavigationLink(value: NavigationItem.chat(agentId: agent.id)) {
                                HStack {
                                    Text(agent.emoji)
                                    Text(agent.displayName)
                                        .lineLimit(1)
                                    Spacer()
                                    Circle()
                                        .fill(agent.status == .online ? .green : .gray)
                                        .frame(width: 8, height: 8)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            // Bottom bar
            Divider()
            HStack {
                Button {
                    selectedNavigation = .settings
                } label: {
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(appState.gatewayManager.isRunning ? .green : .red)
                        .frame(width: 6, height: 6)
                    Text(appState.gatewayManager.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .task {
            await appState.loadAgents()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await appState.loadAgents()
            }
        }
    }
}
