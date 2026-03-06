import SwiftUI

@MainActor
struct AgentChatContainerView: View {
    let agent: Agent
    let client: GatewayClient
    let injectedContext: String?
    var appState: AppState

    @State private var sessions: [Session] = []
    @State private var showSessions = false
    @State private var selectedSessionKey: String
    init(agent: Agent, client: GatewayClient, injectedContext: String? = nil, appState: AppState) {
        self.agent = agent
        self.client = client
        self.injectedContext = injectedContext
        self.appState = appState
        _selectedSessionKey = State(initialValue: "agent:\(agent.id):\(agent.id)")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showSessions.toggle()
                } label: {
                    Label(showSessions ? "隐藏子会话" : "显示子会话", systemImage: showSessions ? "chevron.down" : "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.plain)

                Spacer()

                if selectedSessionKey != "agent:\(agent.id):\(agent.id)" {
                    Text("当前: \(selectedSessionKey)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)

            if showSessions {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredSessions, id: \.key) { session in
                        Button {
                            selectedSessionKey = session.key
                        } label: {
                            HStack {
                                Image(systemName: session.isCronSession ? "clock" : (session.isSubAgent ? "person.2" : "message"))
                                Text(session.displayName ?? session.label ?? session.key)
                                    .lineLimit(1)
                                Spacer()
                                if let updated = session.updatedAt {
                                    Text(updated, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
            }

            ChatView(agent: agent, client: client, sessionKey: selectedSessionKey, injectedContext: injectedContext, appState: appState)
                .id("\(agent.id)-\(selectedSessionKey)-\(injectedContext ?? "")")
        }
        .task {
            await loadSessions()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await loadSessions()
            }
        }
    }

    private var filteredSessions: [Session] {
        sessions
            .filter { $0.key.contains(":\(agent.id):") || $0.key.hasSuffix(":\(agent.id)") }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    private func loadSessions() async {
        sessions = (try? await client.listSessions(agentId: agent.id, limit: 100)) ?? []
        if !sessions.contains(where: { $0.key == selectedSessionKey }) {
            selectedSessionKey = "agent:\(agent.id):\(agent.id)"
        }
    }
}
