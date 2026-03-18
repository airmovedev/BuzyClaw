import SwiftUI

struct ContentView: View {
    @State var appState = AppState()
    @State private var selectedNavigation: NavigationItem?
    @State private var chatInjectedContext: String?
    @State private var showActivityFeed = true
    @State private var showAgentDetail = false
    @State private var chatViewGeneration: Int = 0
    @State private var showQuotaAlert = false
    private let themeManager = ThemeManager.shared
    var appDelegate: AppDelegate

    var body: some View {
        Group {
            if appState.isOnboardingComplete {
                mainView
            } else {
                OnboardingView(appState: appState)
            }
        }
        .environment(\.themeColor, themeManager.themeColor)
        .tint(themeManager.themeColor)
        .accentColor(themeManager.themeColor)
        .task {
            // Wire up delegate so it can stop gateway on quit
            appDelegate.appState = appState

            if appState.isOnboardingComplete {
                await appState.startGateway()
                await appState.loadAgents()
            }
        }
        .onChange(of: appState.isOnboardingComplete) { _, completed in
            if completed {
                Task {
                    await appState.startGateway()
                    await appState.loadAgents()
                }
            }
        }
    }

    @ViewBuilder
    private var mainView: some View {
        NavigationSplitView {
            SidebarView(appState: appState, selectedNavigation: $selectedNavigation)
                .frame(minWidth: 200)
        } detail: {
            NavigationStack {
                detailView
                    .navigationTitle(currentTitle)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if isChatView, let agent = currentAgent {
                    Button {
                        showAgentDetail = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .help("Agent 详情")
                }
            }
            ToolbarItem(placement: .automatic) {
                if isChatView {
                    Button {
                        withAnimation { showActivityFeed.toggle() }
                    } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .help(showActivityFeed ? "收起活动面板" : "展开活动面板")
                }
            }
        }
        .onChange(of: selectedNavigation) { _, _ in
            chatViewGeneration += 1
        }
        .sheet(isPresented: $showAgentDetail) {
            if let agent = currentAgent {
                AgentDetailView(agent: agent, client: appState.gatewayClient, onDelete: {
                    appState.removeAgentLocally(agent.id)
                    Task { await appState.loadAgents() }
                })
            }
        }
        .alert("iCloud 空间不足", isPresented: $showQuotaAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("iCloud 存储空间已满，无法与 iOS 端同步数据。请前往系统设置清理或扩容 iCloud 空间。")
        }
        .onChange(of: appState.cloudKitRelay?.isQuotaExceeded) { _, exceeded in
            if exceeded == true { showQuotaAlert = true }
        }
        .onChange(of: appState.dashboardSync?.isQuotaExceeded) { _, exceeded in
            if exceeded == true { showQuotaAlert = true }
        }
    }

    private var currentAgent: Agent? {
        switch selectedNavigation {
        case .chat(let agentId):
            return appState.agents.first(where: { $0.id == agentId })
        case .chatSession(let agentId, _, _):
            return appState.agents.first(where: { $0.id == agentId })
        default:
            return nil
        }
    }

    private var isChatView: Bool {
        switch selectedNavigation {
        case .chat, .chatSession: return true
        default: return false
        }
    }

    private func preferredMainAgent() -> Agent? {
        if let main = appState.agents.first(where: { $0.id == "main" || $0.id.lowercased().contains("main") }) {
            return main
        }
        return appState.selectedAgent ?? appState.agents.first
    }

    private var currentTitle: String {
        switch selectedNavigation {
        case .none:
            return "ClawTower"
        case .secondBrain:
            return "记忆中枢"
        case .tasks:
            return "任务看板"
        case .projects:
            return "ClawTower"
        case .cronJobs:
            return "定时提醒"
        case .skills:
            return "技能库"
        case .usageStatistics:
            return "用量统计"
        case .settings:
            return "设置"
        case .chat(let agentId):
            if let agent = appState.agents.first(where: { $0.id == agentId }) {
                return "\(agent.emoji) \(agent.displayName)"
            }
            return "Chat"
        case .chatSession(_, _, let label):
            return label
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedNavigation {
        case .none:
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "message.badge.waveform")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("选择一个对话或功能开始")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(40)
        case .secondBrain:
            SecondBrainView(basePath: appState.secondBrainPath)
        case .tasks:
            TasksView(manager: appState.taskManager) { context in
                guard let agent = preferredMainAgent() else { return }
                chatInjectedContext = context
                selectedNavigation = .chat(agentId: agent.id)
                // 1秒后清除，确保 ChatView 已读取
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    chatInjectedContext = nil
                }
            }
        case .projects:
            ProjectsView()
        case .cronJobs:
            CronJobsView(appState: appState)
        case .skills:
            SkillsView()
        case .usageStatistics:
            UsageStatisticsView(service: appState.usageStatisticsService)
        case .settings:
            SettingsView(appState: appState)
        case .chat(let agentId):
            if let agent = appState.agents.first(where: { $0.id == agentId }) {
                let sk = "agent:\(agent.id):\(agent.id)"
                ChatView(
                    agent: agent,
                    client: appState.gatewayClient,
                    sessionKey: sk,
                    injectedContext: agentId == "main" ? chatInjectedContext : nil,
                    appState: appState
                )
                .id("\(agent.id)-\(chatViewGeneration)")
                .inspector(isPresented: $showActivityFeed) {
                    ActivityFeedView(client: appState.gatewayClient, sessionKey: sk)
                    .inspectorColumnWidth(min: 200, ideal: 280, max: 350)
                }
            } else {
                Text("选择一个对话或功能开始")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .chatSession(let agentId, let sessionKey, _):
            if let agent = appState.agents.first(where: { $0.id == agentId }) {
                ChatView(
                    agent: agent,
                    client: appState.gatewayClient,
                    sessionKey: sessionKey,
                    appState: appState
                )
                .id("\(sessionKey)-\(chatViewGeneration)")
                .inspector(isPresented: $showActivityFeed) {
                    ActivityFeedView(client: appState.gatewayClient, sessionKey: sessionKey)
                    .inspectorColumnWidth(min: 200, ideal: 280, max: 350)
                }
            } else {
                Text("选择一个对话或功能开始")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
