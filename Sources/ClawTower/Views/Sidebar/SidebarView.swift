import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SidebarView: View {
    @Bindable var appState: AppState
    @Binding var selectedNavigation: NavigationItem?
    @Environment(\.themeColor) private var themeColor
    @Environment(\.colorScheme) private var colorScheme
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
                Section {
                    NavigationLink(value: NavigationItem.tasks) {
                        Label("任务看板", systemImage: "checklist")
                    }
                    .listRowBackground(rowBackground(for: .tasks))

                    NavigationLink(value: NavigationItem.cronJobs) {
                        Label("定时提醒", systemImage: "clock.badge.checkmark")
                    }
                    .listRowBackground(rowBackground(for: .cronJobs))

                    NavigationLink(value: NavigationItem.skills) {
                        Label("技能库", systemImage: "puzzlepiece")
                    }
                    .listRowBackground(rowBackground(for: .skills))

                    NavigationLink(value: NavigationItem.secondBrain) {
                        Label("记忆中枢", systemImage: "books.vertical")
                    }
                    .listRowBackground(rowBackground(for: .secondBrain))

                    NavigationLink(value: NavigationItem.usageStatistics) {
                        Label("用量统计", systemImage: "chart.bar.fill")
                    }
                    .listRowBackground(rowBackground(for: .usageStatistics))
                } header: {
                    Text("导航")
                        .font(.subheadline.weight(.semibold))
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
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            showCreateSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                    }
                }
            }
            .listStyle(.sidebar)
            .background(SidebarSelectionDisabler())

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
                // Poll faster when subagents are active for responsive status updates
                let hasActive = !activeSubagents.isEmpty || !activeAgentIDs.isEmpty
                try? await Task.sleep(for: .seconds(hasActive ? 2 : 5))
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
        .listRowBackground(rowBackground(for: .chat(agentId: agent.id)))
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
            // Filter out subagent sessions that are already shown as active indicators above
            let activeSubKeys = Set((activeSubagents[agent.id] ?? []).map(\.key))
            let visibleSessions = sessions.filter { !activeSubKeys.contains($0.key) }
            ForEach(visibleSessions) { session in
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
                .listRowBackground(rowBackground(for: .chatSession(agentId: agent.id, sessionKey: session.key, label: label)))
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

    /// A subagent is considered stale (likely finished) if it hasn't been updated recently.
    /// This catches cases where the completion event format is unrecognized.
    private func isSubagentStale(_ session: Session, now: Date = Date()) -> Bool {
        guard let updatedAt = session.updatedAt else { return true }
        // If no update in the last 30 seconds, treat as likely completed
        return now.timeIntervalSince(updatedAt) > 30
    }

    /// Extract a human-readable summary from a subagent session's chat history.
    /// Walks backwards through messages, extracting only text content (skipping
    /// raw tool-call blocks) so the task notes show an actual completion summary.
    private func extractSubagentSummary(_ sessionKey: String) async -> String {
        guard let messages = try? await appState.gatewayClient.getHistoryWithTools(sessionKey: sessionKey, limit: 20) else {
            return ""
        }

        var fallbackToolMessage = ""

        for msg in messages.reversed() {
            let role = msg["role"] as? String ?? ""
            guard role == "assistant" else { continue }

            let text = MessageParser.extractTextOnly(from: msg["content"])
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !MessageParser.isHeartbeatOK(trimmed) {
                return String(trimmed.prefix(2000))
            }

            let rawContent = MessageParser.extractText(from: msg["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if fallbackToolMessage.isEmpty, rawContent.contains("[调用工具:") {
                fallbackToolMessage = String(rawContent.prefix(2000))
            }
        }

        return fallbackToolMessage
    }

    // MARK: - Sessions

    private func loadSessions() async {
        guard let sessions = try? await appState.gatewayClient.listSessions(limit: 100) else { return }

        // Deduplicate subagent sessions that share the same label across agents.
        // When a parent agent dispatches a subagent, both the parent and child get
        // a session with the same label. We keep only the child's (most recent) copy.
        var subagentByLabel: [String: Session] = [:]
        var duplicateKeys = Set<String>()
        for session in sessions {
            guard session.key.contains(":subagent:"), let label = session.label, !label.isEmpty else { continue }
            if let existing = subagentByLabel[label] {
                // Keep the more recently updated one; mark the other as duplicate
                if (session.updatedAt ?? .distantPast) > (existing.updatedAt ?? .distantPast) {
                    duplicateKeys.insert(existing.key)
                    subagentByLabel[label] = session
                } else {
                    duplicateKeys.insert(session.key)
                }
            } else {
                subagentByLabel[label] = session
            }
        }

        var grouped: [String: [Session]] = [:]
        for session in sessions {
            guard !duplicateKeys.contains(session.key) else { continue }
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

        // 收集所有 subagent sessions（排除重复的 dispatch record）
        var allSubagentSessions: [String: [Session]] = [:]
        var currentSubagentKeys = Set<String>()
        for session in sessions {
            guard session.key.contains(":subagent:") else { continue }
            guard !duplicateKeys.contains(session.key) else { continue }
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
                // Auto-create a kanban task for the new subagent session
                if let session = sessions.first(where: { $0.key == key }),
                   let label = session.label, !label.isEmpty {
                    let parentId = appState.taskManager.findMatchingParentTask(subagentTitle: label)
                    await appState.taskManager.addSubagentTask(title: label, sessionKey: key, parentTaskId: parentId)
                }
            }
            previousSubagentKeys = currentSubagentKeys
        }

        // Detect completed subagent sessions using multiple signals:
        // 1. Explicit terminal status (done, completed, failed, etc.)
        // 2. Staleness: no updatedAt change in 30s → likely finished
        // 3. History check: completion event in message history (only for recently active sessions)
        let now = Date()
        let trackedSubagentSessions = sessions.filter { session in
            session.isSubAgent && appState.trackedSubagentKeys.contains(session.key)
        }

        var completedKeys = Set<String>()
        var needsHistoryCheck: [Session] = []

        for session in trackedSubagentSessions {
            if isTerminalSession(session) {
                // Signal 1: explicit terminal status
                completedKeys.insert(session.key)
            } else if isSubagentStale(session, now: now) {
                // Signal 2: no activity for 30s — likely finished
                completedKeys.insert(session.key)
            } else {
                // Still active; check history for completion event
                needsHistoryCheck.append(session)
            }
        }

        // Signal 3: only check history for still-active sessions (avoids unnecessary API calls)
        for session in needsHistoryCheck {
            if await hasSubagentCompletionEvent(session.key) {
                completedKeys.insert(session.key)
            }
        }

        // Auto-complete kanban tasks for finished subagent sessions
        for key in completedKeys {
            let summary = await extractSubagentSummary(key)
            await appState.taskManager.completeSubagentTask(sessionKey: key, summary: summary)
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

    @ViewBuilder
    private func rowBackground(for item: NavigationItem) -> some View {
        if selectedNavigation == item {
            RoundedRectangle(cornerRadius: 5)
                .fill(themeColor.opacity(colorScheme == .dark ? 0.35 : 0.25))
                .padding(.horizontal, 4)
        } else {
            // 提供透明背景，防止系统选中色泄漏
            Color.clear
        }
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

// MARK: - Disable default NSOutlineView selection highlight

#if os(macOS)
/// An invisible NSView that traverses the view hierarchy to find the parent
/// NSOutlineView and suppresses its default selection highlight,
/// so that `.listRowBackground()` can provide a custom theme-colored highlight.
private struct SidebarSelectionDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer so the view is already in the hierarchy
        DispatchQueue.main.async {
            disableSelectionHighlight(in: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func disableSelectionHighlight(in view: NSView) {
        guard let outlineView = findOutlineView(from: view) else { return }
        outlineView.selectionHighlightStyle = .none
    }

    private func findOutlineView(from view: NSView) -> NSOutlineView? {
        var current: NSView? = view
        while let v = current {
            if let outline = v as? NSOutlineView { return outline }
            // Also check siblings / subviews of ancestors
            if let found = findOutlineViewInSubviews(of: v) { return found }
            current = v.superview
        }
        return nil
    }

    private func findOutlineViewInSubviews(of view: NSView) -> NSOutlineView? {
        for subview in view.subviews {
            if let outline = subview as? NSOutlineView { return outline }
            if let found = findOutlineViewInSubviews(of: subview) { return found }
        }
        return nil
    }
}
#endif
