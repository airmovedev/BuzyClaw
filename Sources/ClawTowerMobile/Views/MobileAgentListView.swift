import SwiftUI

struct MobileAgentListView: View {
    @Environment(CloudKitMessageClient.self) private var messageClient
    @Environment(DashboardSnapshotStore.self) private var snapshotStore
    @Environment(NavigationState.self) private var navigationState
    @State private var viewModel = MobileAgentListViewModel()
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if !snapshotStore.isMacOSConnected && viewModel.sortedAgents.isEmpty && !viewModel.isLoading {
                    SetupGuideView(
                        icon: "bubble.left.and.bubble.right",
                        title: "guide.chat.title",
                        description: "guide.chat.description",
                        features: [
                            .init(icon: "paperplane", text: "guide.chat.feature1"),
                            .init(icon: "mic", text: "guide.chat.feature2"),
                            .init(icon: "photo", text: "guide.chat.feature3"),
                        ],
                        onRetry: { await snapshotStore.refresh() }
                    )
                } else {
                    List {
                        if !snapshotStore.isMacOSConnected && !viewModel.sortedAgents.isEmpty {
                            Section {
                                HStack(spacing: 8) {
                                    Image(systemName: "bolt.slash.fill")
                                        .foregroundStyle(.red)
                                    Text("电脑端「虾忙」未连接")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    RetryButton { await snapshotStore.refresh() }
                                }
                                .listRowBackground(Color.red.opacity(0.08))
                            }
                        }

                        if let error = viewModel.error {
                            ContentUnavailableView {
                                Label("无法加载", systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(error)
                            } actions: {
                                Button("重试") { Task { await viewModel.fetch() } }
                            }
                        } else if viewModel.sortedAgents.isEmpty && !viewModel.isLoading {
                            ContentUnavailableView {
                                Label("暂无 Agent", systemImage: "person.2.slash")
                            } description: {
                                Text("请确保 macOS ClawTower 正在运行")
                            }
                        } else {
                            Section("Agents") {
                                ForEach(viewModel.sortedAgents) { agent in
                                    NavigationLink(value: agent) {
                                        AgentRow(agent: agent, isUnread: messageClient.unreadAgentIds.contains(agent.id))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("对话")
            .navigationDestination(for: AgentSnapshot.self) { agent in
                MobileChatView(agentId: agent.id, agentName: agent.displayName)
            }
            .refreshable {
                await viewModel.fetch()
            }
            .overlay {
                if viewModel.isLoading && viewModel.agents.isEmpty {
                    ProgressView("加载中…")
                }
            }
            .task {
                await viewModel.fetch()
            }
            .onChange(of: navigationState.pendingAgentId) { _, newValue in
                guard let agentId = newValue else { return }
                navigationState.pendingAgentId = nil
                if let agent = viewModel.sortedAgents.first(where: { $0.id == agentId }) {
                    navigationPath = NavigationPath()
                    navigationPath.append(agent)
                }
            }
        }
    }
}

// MARK: - Agent Row

private struct AgentRow: View {
    let agent: AgentSnapshot
    let isUnread: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(agent.identityEmoji ?? agent.emoji ?? "🤖")
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.identityName ?? agent.displayName)
                    .font(.body.weight(.medium))
                if let lastMsg = agent.lastMessage, !lastMsg.isEmpty {
                    Text(lastMsg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isUnread {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.vertical, 4)
    }
}
