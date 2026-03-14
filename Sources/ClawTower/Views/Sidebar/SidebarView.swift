import SwiftUI

struct SidebarView: View {
    @Bindable var appState: AppState
    @Binding var selectedNavigation: NavigationItem?

    @State private var showCreateSheet = false
    @State private var editingAgent: Agent?
    @State private var pendingDeleteAgent: Agent?
    @State private var agentSessions: [String: [Session]] = [:]
    @State private var expandedAgents: Set<String> = []
    @State private var activeAgentIDs: Set<String> = []
    @State private var activeSubagents: [String: [Session]] = [:]
    @State private var previousSubagentKeys: Set<String> = []
    @State private var initialLoadDone = false
    @State private var readTimestamps: [String: Double] = {
        UserDefaults.standard.dictionary(forKey: "SidebarReadTimestamps") as? [String: Double] ?? [:]
    }()

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedNavigation) {
                Section("导航") {
                    NavigationLink(value: NavigationItem.tasks) {
                        Label("任务看板", systemImage: "checklist")
                    }

                    NavigationLink(value: NavigationItem.cronJobs) {
                        Label("定时提醒", systemImage: "clock.badge.checkmark")
                    }

                    NavigationLink(value: NavigationItem.skills) {
                        Label("技能库", systemImage: "puzzlepiece")
                    }

                    NavigationLink(value: NavigationItem.secondBrain) {
                        Label("记忆中枢", systemImage: "books.vertical")
                    }
                }

                Section {
                    if appState.agents.isEmpty {
                        Text("连接 Gateway 后显示")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(appState.agents) { agent in
                            agentRow(agent)
                        }
                    }
                } header: {
                    HStack {
                        Text("Agents")
                        Spacer()
                        Button {
                            showCreateSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)

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

                GatewayStatusBadge(gatewayManager: appState.gatewayManager, compact: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .task {
            await appState.loadAgents()
            while !Task.isCancelled {
                await loadSessions()
                try? await Task.sleep(for: .seconds(5))
                await appState.loadAgents()
            }
        }
        .onChange(of: appState.subagentRefreshTrigger) { _, _ in
            Task { await loadSessions() }
        }
        .onChange(of: selectedNavigation) { _, newValue in
            if case let .chat(agentId) = newValue {
                appState.selectedAgent = appState.agents.first(where: { $0.id == agentId })
                appState.markAgentAsRead(agentId)
            } else if case let .chatSession(_, sessionKey, _) = newValue {
                markSessionRead(sessionKey)
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            AgentFormSheet(isEditing: false) { name, emoji, description, model in
                Task {
                    let draft = AgentDraft(name: name, emoji: emoji, roleDescription: description, model: model)
                    do {
                        let agentId = try await appState.gatewayClient.createAgent(draft)
                        await appState.loadAgents()
                    } catch {
                        print("[ClawTower] createAgent failed: \(error)")
                        await appState.loadAgents()
                    }
                }
            }
        }
        .sheet(item: $editingAgent) { agent in
            AgentFormSheet(
                name: agent.displayName,
                emoji: agent.emoji,
                description: agent.roleDescription ?? "",
                model: agent.model ?? "default",
                isEditing: true
            ) { name, emoji, description, model in
                Task {
                    let draft = AgentDraft(name: name, emoji: emoji, roleDescription: description, model: model)
                    try? await appState.gatewayClient.updateAgent(id: agent.id, draft: draft)
                    await appState.loadAgents()
                }
            }
        }
        .alert("确认删除 Agent", isPresented: Binding(
            get: { pendingDeleteAgent != nil },
            set: { if !$0 { pendingDeleteAgent = nil } }
        )) {
            Button("取消", role: .cancel) {
                pendingDeleteAgent = nil
            }
            Button("删除", role: .destructive) {
                guard let agent = pendingDeleteAgent else { return }
                Task {
                    try? await appState.gatewayClient.deleteAgent(id: agent.id)
                    pendingDeleteAgent = nil

                    agentSessions.removeValue(forKey: agent.id)
                    activeSubagents.removeValue(forKey: agent.id)
                    activeAgentIDs.remove(agent.id)
                    expandedAgents.remove(agent.id)
                    appState.markAgentAsRead(agent.id)
                    appState.removeAgentLocally(agent.id)

                    switch selectedNavigation {
                    case .chat(let agentId) where agentId == agent.id,
                         .chatSession(let agentId, _, _) where agentId == agent.id:
                        if let mainAgent = appState.agents.first(where: { $0.id == "main" }) {
                            selectedNavigation = .chat(agentId: mainAgent.id)
                            appState.selectedAgent = mainAgent
                        } else {
                            selectedNavigation = nil
                            appState.selectedAgent = appState.agents.first
                        }
                    default:
                        break
                    }

                    await appState.loadAgents()
                }
            }
        } message: {
            Text("删除后不可恢复：\(pendingDeleteAgent?.displayName ?? "")")
        }
    }

    // MARK: - Agent Row with DisclosureGroup

    @ViewBuilder
    private func agentRow(_ agent: Agent) -> some View {
        let sessions = agentSessions[agent.id] ?? []
        
        NavigationLink(value: NavigationItem.chat(agentId: agent.id)) {
            HStack {
                if !sessions.isEmpty {
                    Image(systemName: expandedAgents.contains(agent.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation {
                                if expandedAgents.contains(agent.id) {
                                    expandedAgents.remove(agent.id)
                                } else {
                                    expandedAgents.insert(agent.id)
                                }
                            }
                        }
                } else {
                    Spacer().frame(width: 20)
                }
                agentLabel(agent)
            }
        }
        .contextMenu { agentContextMenu(agent) }

        // 显示活跃的 sub-agent 任务
        if let activeSubs = activeSubagents[agent.id] {
            ForEach(activeSubs) { session in
                HStack(spacing: 4) {
                    Text(activeSubagentLabel(session))
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("工作中…")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .padding(.leading, 28)
                .padding(.vertical, 2)
            }
        }

        if expandedAgents.contains(agent.id), !sessions.isEmpty {
            ForEach(sessions) { session in
                let label = sessionLabel(session)
                NavigationLink(value: NavigationItem.chatSession(agentId: agent.id, sessionKey: session.key, label: label)) {
                    HStack {
                        Image(systemName: session.isCronSession ? "clock.arrow.circlepath" : "person.2")
                            .foregroundStyle(.secondary)
                        Text(label)
                            .lineLimit(1)
                        Spacer()
                        if isSessionUnread(session) {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    @ViewBuilder
    private func agentLabel(_ agent: Agent) -> some View {
        HStack {
            Text(agent.emoji)
            Text(agent.displayName)
                .lineLimit(1)
            Spacer()
            if isAgentWorking(agent) {
                Text("工作中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if appState.unreadAgentIDs.contains(agent.id) {
                Text("新消息")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.red))
            }
        }
    }

    @ViewBuilder
    private func agentContextMenu(_ agent: Agent) -> some View {
        Button("编辑") {
            editingAgent = agent
        }
        Divider()
        Button("删除", role: .destructive) {
            pendingDeleteAgent = agent
        }
    }

    private func activeSubagentLabel(_ session: Session) -> String {
        if let label = session.label, !label.isEmpty {
            // label 格式已经是 "角色: 任务标题"
            let short = label.prefix(35)
            return short.count < label.count ? "\(short)…" : label
        }
        // 回退：从 key 提取 agentId
        let parts = session.key.split(separator: ":")
        let sourceAgent = parts.count >= 2 ? String(parts[1]) : "agent"
        return "\(sourceAgent): 子任务"
    }

    private func isAgentWorking(_ agent: Agent) -> Bool {
        return activeAgentIDs.contains(agent.id)
    }

    private func normalizedSessionStatus(_ session: Session) -> String? {
        session.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func isTerminalSession(_ session: Session) -> Bool {
        let terminalStatuses: Set<String> = [
            "done", "completed", "complete", "finished", "success",
            "failed", "error", "errored", "cancelled", "canceled",
            "timed_out", "timeout", "killed", "stopped", "terminated"
        ]
        guard let status = normalizedSessionStatus(session) else { return false }
        return terminalStatuses.contains(status)
    }

    private func hasInactiveSessionStatus(_ session: Session) -> Bool {
        let inactiveStatuses: Set<String> = ["idle", "inactive", "closed", "exited"]
        guard let status = normalizedSessionStatus(session) else { return false }
        return inactiveStatuses.contains(status)
    }

    private func hasSubagentCompletionEvent(_ sessionKey: String) async -> Bool {
        guard let messages = try? await appState.gatewayClient.getHistoryWithTools(sessionKey: sessionKey, limit: 40) else {
            return false
        }

        for msg in messages.reversed() {
            let role = msg["role"] as? String ?? ""
            let isSystem = MessageParser.isSystemInjected(role: role, content: msg["content"])
            if MessageParser.isSubagentCompletion(role: role, content: msg["content"], isSystemInjected: isSystem) {
                return true
            }
        }

        return false
    }

    private func isRecentlyActive(_ session: Session, now: Date = Date(), threshold: TimeInterval = 15) -> Bool {
        guard let updatedAt = session.updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) < threshold
    }

    // MARK: - Sessions

    private func loadSessions() async {
        guard let sessions = try? await appState.gatewayClient.listSessions(limit: 100) else { return }
        var grouped: [String: [Session]] = [:]
        for session in sessions {
            let isCron = session.key.contains(":cron:")
            let isSubagent = session.key.contains(":subagent:") && session.label != nil
            guard isCron || isSubagent else { continue }
            // Extract agentId from key pattern "agent:<agentId>:..."
            let parts = session.key.split(separator: ":")
            guard parts.count >= 2 else { continue }
            let agentId = String(parts[1])
            grouped[agentId, default: []].append(session)
        }
        // Sort each group by updatedAt descending
        for key in grouped.keys {
            grouped[key]?.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        }
        agentSessions = grouped

        // 收集所有 subagent sessions
        var allSubagentSessions: [String: [Session]] = [:]
        var currentSubagentKeys = Set<String>()
        for session in sessions {
            guard session.key.contains(":subagent:") else { continue }
            let parts = session.key.split(separator: ":")
            guard parts.count >= 2 else { continue }
            let agentId = String(parts[1])
            currentSubagentKeys.insert(session.key)
            allSubagentSessions[agentId, default: []].append(session)
        }

        // 首次加载：记录现有 session keys，不跟踪任何
        if !initialLoadDone {
            previousSubagentKeys = currentSubagentKeys
            initialLoadDone = true
        } else {
            // 只跟踪新出现的 session（上次 poll 没有的）
            let newKeys = currentSubagentKeys.subtracting(previousSubagentKeys)
            for key in newKeys {
                appState.addTrackedSubagent(key)
            }
            previousSubagentKeys = currentSubagentKeys
        }

        // Sidebar 的 subagent 运行态尽量跟活动动态对齐：
        // - 直接信任明确终态 status
        // - 对 tracked subagent，不再用 idle / updatedAt 猜结束，而是检查历史里是否出现 completion event
        let trackedSubagentSessions = sessions.filter { session in
            session.isSubAgent && appState.trackedSubagentKeys.contains(session.key)
        }

        var completedKeys = Set(sessions.filter { session in
            guard session.isSubAgent else { return false }
            guard appState.trackedSubagentKeys.contains(session.key) else { return false }
            return isTerminalSession(session)
        }.map { $0.key })

        for session in trackedSubagentSessions where !completedKeys.contains(session.key) {
            if await hasSubagentCompletionEvent(session.key) {
                completedKeys.insert(session.key)
            }
        }

        // 统一回收 tracked keys：
        // 1) session 已经不在列表里
        // 2) session 明确进入终态
        // 3) 活动动态已出现 completion event
        let staleKeys = appState.trackedSubagentKeys.subtracting(currentSubagentKeys)
        appState.removeTrackedSubagents(staleKeys.union(completedKeys))

        // 只显示被跟踪且仍未完成的 subagent sessions
        var activeSubs: [String: [Session]] = [:]
        for (agentId, agentSessions) in allSubagentSessions {
            let tracked = agentSessions.filter {
                appState.trackedSubagentKeys.contains($0.key) && !completedKeys.contains($0.key)
            }
            if !tracked.isEmpty {
                activeSubs[agentId] = tracked.sorted {
                    ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
                }
            }
        }
        activeSubagents = activeSubs

        // active agent IDs: tracked subagents + standalone agent main sessions with recent activity
        let now = Date()
        var active = Set<String>()
        for (agentId, subs) in activeSubs {
            if !subs.isEmpty { active.insert(agentId) }
        }
        // Check standalone agent sessions (non-main agents with recent main/subagent session activity)
        for session in sessions {
            // Skip cron sessions
            if session.key.contains(":cron:") { continue }
            let parts = session.key.split(separator: ":")
            guard parts.count >= 2 else { continue }
            let agentId = String(parts[1])
            // Skip main agent's own main session (always active from user chat)
            if agentId == "main" && !session.key.contains(":subagent:") { continue }
            // Already marked active
            if active.contains(agentId) { continue }
            // 明确终态 / 明显非运行态的 standalone session 不应让 agent 持续显示“工作中…”
            if isTerminalSession(session) || hasInactiveSessionStatus(session) { continue }
            // 只把“刚刚真的有活动”的 standalone agent 算作工作中，避免完成后长挂 2 分钟
            if isRecentlyActive(session, now: now) {
                active.insert(agentId)
            }
        }
        activeAgentIDs = active
    }

    private func sessionLabel(_ session: Session) -> String {
        if let label = session.label ?? session.displayName {
            var cleaned = label
            if cleaned.hasPrefix("Cron: ") {
                cleaned = String(cleaned.dropFirst(6))
            }
            return cleaned
        }
        if session.isCronSession {
            return "定时任务"
        }
        return "子会话"
    }

    private func isSessionUnread(_ session: Session) -> Bool {
        guard let updatedAt = session.updatedAt else { return false }
        let lastRead = readTimestamps[session.key] ?? 0
        return updatedAt.timeIntervalSince1970 > lastRead
    }

    private func markSessionRead(_ sessionKey: String) {
        readTimestamps[sessionKey] = Date().timeIntervalSince1970
        UserDefaults.standard.set(readTimestamps, forKey: "SidebarReadTimestamps")
    }
}

struct GatewayStatusBadge: View {
    let gatewayManager: GatewayManager
    var compact: Bool = false
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: compact ? 4 : 8) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(gatewayManager.isReconnecting ? 0.22 : 1))
                    .frame(width: compact ? 6 : 10, height: compact ? 6 : 10)
                    .scaleEffect(gatewayManager.isReconnecting && isAnimating ? 1.9 : 1)
                    .opacity(gatewayManager.isReconnecting && isAnimating ? 0 : 1)

                Circle()
                    .fill(statusColor)
                    .frame(width: compact ? 6 : 10, height: compact ? 6 : 10)
                    .overlay {
                        if gatewayManager.isReconnecting {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white)
                                .scaleEffect(compact ? 0.35 : 0.55)
                        }
                    }
            }
            .frame(width: compact ? 8 : 12, height: compact ? 8 : 12)

            Text(gatewayManager.statusText)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(gatewayManager.isConnectionWarning ? .orange : .secondary)
        }
        .onAppear { updateAnimationState() }
        .onChange(of: gatewayManager.state) { _, _ in updateAnimationState() }
        .accessibilityLabel("Gateway \(gatewayManager.statusText)")
    }

    private var statusColor: Color {
        switch gatewayManager.state {
        case .running:
            return .green
        case .starting, .reconnecting:
            return .orange
        case .disconnected:
            return .orange
        case .stopped:
            return .gray
        case .error:
            return .red
        }
    }

    private func updateAnimationState() {
        if gatewayManager.isReconnecting {
            withAnimation(.easeOut(duration: 1).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        } else {
            isAnimating = false
        }
    }
}
