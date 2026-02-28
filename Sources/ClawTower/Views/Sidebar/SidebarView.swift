import SwiftUI

struct SidebarView: View {
    @Bindable var appState: AppState

    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { appState.selectedAgent?.id },
                set: { newId in
                    appState.selectedAgent = appState.agents.first { $0.id == newId }
                }
            )) {
                Section("导航") {
                    NavigationLink(value: "dashboard") {
                        Label("Dashboard", systemImage: "square.grid.2x2")
                    }

                    NavigationLink(value: "secondBrain") {
                        Label("第二大脑", systemImage: "books.vertical")
                    }

                    NavigationLink(value: "projects") {
                        Label("项目", systemImage: "folder")
                    }

                    NavigationLink(value: "cronJobs") {
                        Label("定时任务", systemImage: "clock.badge.checkmark")
                    }

                    NavigationLink(value: "skills") {
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
                            HStack {
                                Text(agent.emoji)
                                Text(agent.displayName)
                                    .lineLimit(1)
                                Spacer()
                                Circle()
                                    .fill(agent.status == .online ? .green : .gray)
                                    .frame(width: 8, height: 8)
                            }
                            .tag(agent.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                appState.selectedAgent = agent
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
                    // Navigate to settings
                } label: {
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(appState.gatewayManager.isConnected ? .green : .red)
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
            // Refresh every 10s
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await appState.loadAgents()
            }
        }
    }
}
