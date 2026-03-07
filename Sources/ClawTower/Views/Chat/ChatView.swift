import SwiftUI
import MarkdownUI

import AppKit
import UniformTypeIdentifiers
import PDFKit

@MainActor
struct ChatView: View {
    let agent: Agent
    let client: GatewayClient
    let sessionKey: String
    let injectedContext: String?
    var appState: AppState

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isStreaming = false
    @State private var streamingGeneration: Int = 0
    @State private var expandedMessages: Set<String> = []

    @State private var isLoadingHistory = false
    @State private var hasMoreHistory = true
    @State private var historyCursor: Int64?

    @State private var attachments: [PendingAttachment] = []
    @State private var displayMessages: [ChatMessage] = []
    @State private var displayContentCache: [String: String] = [:]

    @State private var showCommandMenu = false
    @State private var commandSelection = 0
    @State private var isInitialLoadDone = false
    @State private var scrollTrigger = 0
    @State private var currentModel: String
    @State private var lastUpdateTime: Date = .distantPast
    @State private var rateLimitInfo: RateLimitInfo?
    init(agent: Agent, client: GatewayClient, sessionKey: String, injectedContext: String? = nil, appState: AppState) {
        self.agent = agent
        self.client = client
        self.sessionKey = sessionKey
        self.injectedContext = injectedContext
        self.appState = appState
        _currentModel = State(initialValue: agent.model ?? "default")
        // Load draft
        if let draft = appState.chatDrafts[sessionKey] {
            _inputText = State(initialValue: draft.text)
            _attachments = State(initialValue: draft.attachments)
        }
    }

    private let baseCommands: [SlashCommand] = [
        .init(name: "/status", description: "查看 Agent 状态"),
        .init(name: "/clear", description: "清空当前对话显示"),
        .init(name: "/model", description: "查看/切换当前模型")
    ]

    private var filteredCommands: [SlashCommand] {
        guard inputText.hasPrefix("/") else { return [] }
        let keyword = inputText.lowercased()
        return baseCommands.filter { $0.name.hasPrefix(keyword) || keyword == "/" }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isInitialLoadDone {
                messageList
            } else {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            Divider()
            inputArea
        }
        .task {
            await loadInitialHistory()
            updateDisplayMessages()
            isInitialLoadDone = true
            scrollTrigger += 1
            // 预填任务上下文到输入框
            if let injectedContext, !injectedContext.isEmpty, inputText.isEmpty {
                inputText = "关于这个任务：\n\(injectedContext)\n\n"
            }
            // 持续轮询新消息（每 3 秒）
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await pollNewMessages()
            }
        }
        .onDisappear {
            saveDraft()
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(agent.emoji) \(agent.displayName)")
                    .font(.headline)

                Spacer()

                Picker("模型", selection: $currentModel) {
                    ForEach(AgentDraft.modelOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Circle()
                    .fill(agent.status == .online ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(agent.status == .online ? "在线" : "离线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    Color.clear.frame(height: 0)
                        .id("__top_anchor__")
                    if hasMoreHistory {
                        HistoryLoaderRow(isLoading: isLoadingHistory) {
                            Task { await loadMoreHistoryIfNeeded() }
                        }
                    }

                    ForEach(displayMessages) { message in
                        MessageBubble(
                            message: message,
                            displayContent: displayContentCache[message.id] ?? chatDisplayContent(message),
                            agentEmoji: agent.emoji,
                            isExpanded: expandedMessages.contains(message.id),
                            isLastMessage: message.id == displayMessages.last?.id,
                            rateLimitInfo: message.id == displayMessages.last?.id ? rateLimitInfo : nil,
                            onToggleExpand: {
                                if expandedMessages.contains(message.id) {
                                    expandedMessages.remove(message.id)
                                } else {
                                    expandedMessages.insert(message.id)
                                }
                            }
                        )
                        .id(message.id)
                    }
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) { _, _ in
                guard isInitialLoadDone else { return }
                updateDisplayMessages()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let target = displayMessages.last {
                        NSLog("🔥 [ScrollTo] target: %@", target.id)
                        proxy.scrollTo(target.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: scrollTrigger) { _, _ in
                let scrollTriggerStart = CFAbsoluteTimeGetCurrent()
                if isStreaming {
                    // During streaming, only update the streaming message's content in-place
                    if let streamingMsg = messages.first(where: { $0.isStreaming }),
                       let idx = displayMessages.firstIndex(where: { $0.id == streamingMsg.id }) {
                        displayMessages[idx].content = streamingMsg.content
                        displayContentCache[streamingMsg.id] = chatDisplayContent(streamingMsg)
                    }
                } else {
                    updateDisplayMessages()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let target = displayMessages.last {
                        NSLog("🔥 [ScrollTo] target: %@", target.id)
                        proxy.scrollTo(target.id, anchor: .bottom)
                    }
                }
                let scrollTriggerElapsed = CFAbsoluteTimeGetCurrent() - scrollTriggerStart
                NSLog("🔥 [ScrollTrigger] took %.1fms, isStreaming: %d, displayCount: %d", scrollTriggerElapsed * 1000, isStreaming ? 1 : 0, displayMessages.count)
            }
            .onChange(of: isStreaming) { _, newValue in
                if newValue {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if let target = messages.last {
                            proxy.scrollTo(target.id, anchor: .bottom)
                        }
                    }
                } else {
                    // Streaming ended — do a full rebuild
                    updateDisplayMessages()
                }
            }
        }
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 改动5: 附件预览在输入框外部上方
            if !attachments.isEmpty {
                AttachmentPreviewStrip(attachments: attachments, onRemove: { id in
                    attachments.removeAll { $0.id == id }
                })
            }

            ZStack(alignment: .bottomLeading) {
                ChatInputBar(
                    inputText: $inputText,
                    isStreaming: isStreaming,
                    canSend: !(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty) || isStreaming,
                    onPickAttachment: pickAttachment,
                    onSend: sendMessage
                )
                .onChange(of: inputText) { _, newValue in
                    showCommandMenu = newValue.hasPrefix("/")
                    if commandSelection >= filteredCommands.count { commandSelection = 0 }
                }
                .onKeyPress(.downArrow) {
                    guard showCommandMenu, !filteredCommands.isEmpty else { return .ignored }
                    commandSelection = min(commandSelection + 1, filteredCommands.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard showCommandMenu, !filteredCommands.isEmpty else { return .ignored }
                    commandSelection = max(commandSelection - 1, 0)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard showCommandMenu, !filteredCommands.isEmpty else { return .ignored }
                    executeCommand(filteredCommands[commandSelection], fromMenu: true)
                    return .handled
                }

                if showCommandMenu, !filteredCommands.isEmpty {
                    SlashCommandMenu(
                        commands: filteredCommands,
                        selectedIndex: commandSelection,
                        onSelect: { command in executeCommand(command, fromMenu: true) }
                    )
                    .offset(y: -84)
                }
            }
        }
        .padding(12)
        .background(.bar)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                    guard let data = data as? Data,
                          let urlString = String(data: data, encoding: .utf8),
                          let url = URL(string: urlString) else { return }
                    DispatchQueue.main.async {
                        do {
                            let attachment = try PendingAttachment.from(url: url)
                            attachments.append(attachment)
                        } catch {
                            messages.append(ChatMessage(role: .assistant, content: "⚠️ 附件读取失败: \(error.localizedDescription)"))
                        }
                    }
                }
            }
            return true
        }
    }

    private func saveDraft() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && attachments.isEmpty {
            appState.chatDrafts.removeValue(forKey: sessionKey)
        } else {
            appState.chatDrafts[sessionKey] = ChatDraft(text: inputText, attachments: attachments)
        }
    }

    private func loadInitialHistory() async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        // 1. 先加载本地缓存（异步读磁盘，只取最近50条快速显示）
        let sk = sessionKey
        let cached = await Task.detached {
            ChatMessageStore.shared.loadMessages(sessionKey: sk)
        }.value
        if !cached.isEmpty {
            let sorted = cached.sorted { $0.timestamp < $1.timestamp || ($0.timestamp == $1.timestamp && $0.role == .user && $1.role != .user) }
            messages = Array(sorted.suffix(100))
        }

        // 2. 从服务端拉取最新
        do {
            let fetched = try await client.getHistory(sessionKey: sessionKey, limit: 100)
            let sorted = fetched.sorted { $0.timestamp < $1.timestamp || ($0.timestamp == $1.timestamp && $0.role == .user && $1.role != .user) }

            if messages.isEmpty {
                // 没有缓存，直接用服务端数据
                messages = sorted
            } else {
                // 合并：按 ID 去重，服务端优先
                var seen = Set<String>()
                var merged: [ChatMessage] = []
                // 服务端消息优先
                for msg in sorted {
                    if seen.insert(msg.id).inserted {
                        merged.append(msg)
                    }
                }
                // 补充缓存中服务端没有的旧消息
                for msg in messages {
                    if seen.insert(msg.id).inserted {
                        merged.append(msg)
                    }
                }
                messages = merged.sorted { $0.timestamp < $1.timestamp || ($0.timestamp == $1.timestamp && $0.role == .user && $1.role != .user) }
            }

            // 限制上限
            if messages.count > 200 {
                messages = Array(messages.suffix(200))
            }

            ChatMessageStore.shared.saveMessages(sessionKey: sessionKey, messages: messages)
            historyCursor = messages.first.map { Int64($0.timestamp.timeIntervalSince1970 * 1000) }
            hasMoreHistory = fetched.count >= 100
        } catch {
            // 服务端失败，至少还有本地缓存
            historyCursor = messages.first.map { Int64($0.timestamp.timeIntervalSince1970 * 1000) }
            hasMoreHistory = !messages.isEmpty
        }
    }

    private func loadMoreHistoryIfNeeded() async {
        guard !isLoadingHistory, hasMoreHistory, let cursor = historyCursor else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            let fetched = try await client.getHistory(sessionKey: sessionKey, limit: 100, before: cursor)
            let sorted = fetched.sorted { $0.timestamp < $1.timestamp || ($0.timestamp == $1.timestamp && $0.role == .user && $1.role != .user) }
            let merged = deduplicated(sorted + messages).sorted { $0.timestamp < $1.timestamp || ($0.timestamp == $1.timestamp && $0.role == .user && $1.role != .user) }
            messages = merged
            // 限制最大消息数
            if messages.count > 200 {
                messages = Array(messages.suffix(200))
            }
            historyCursor = messages.first.map { Int64($0.timestamp.timeIntervalSince1970 * 1000) }
            hasMoreHistory = fetched.count >= 100
        } catch {
            hasMoreHistory = false
        }
    }

    private func pollNewMessages() async {
        guard !isStreaming else { return }

        do {
            let fetched = try await client.getHistory(sessionKey: sessionKey, limit: 20)
            let sorted = fetched.sorted { $0.timestamp < $1.timestamp || ($0.timestamp == $1.timestamp && $0.role == .user && $1.role != .user) }

            let currentLastId = messages.last?.id
            let fetchedLastId = sorted.last?.id

            if fetchedLastId != currentLastId {
                // 用服务端消息替换本地消息（避免时间戳差异导致重复）
                // 对 user 和 assistant 消息都按 role+timestamp 去重
                let serverTimestamps = sorted.map { (role: $0.role, ts: Int($0.timestamp.timeIntervalSince1970)) }
                let filteredLocal = messages.filter { msg in
                    let localTs = Int(msg.timestamp.timeIntervalSince1970)
                    let hasServerMatch = serverTimestamps.contains { $0.role == msg.role && abs($0.ts - localTs) <= 2 }
                    // If server has a matching message by role+timestamp, drop the local copy (server version wins)
                    if hasServerMatch && !sorted.contains(where: { $0.id == msg.id }) {
                        return false
                    }
                    return true
                }
                let merged = deduplicated(filteredLocal + sorted).sorted { $0.timestamp < $1.timestamp || ($0.timestamp == $1.timestamp && $0.role == .user && $1.role != .user) }
                var finalMessages = merged
                // 限制最大消息数
                if finalMessages.count > 200 {
                    finalMessages = Array(finalMessages.suffix(200))
                }
                // Skip assignment if messages are identical (avoid SwiftUI diff)
                let currentIds = messages.map(\.id)
                let finalIds = finalMessages.map(\.id)
                guard currentIds != finalIds else { return }
                messages = finalMessages
                updateDisplayMessages()
                ChatMessageStore.shared.saveMessages(sessionKey: sessionKey, messages: finalMessages)

                // 只检查本次新增的消息（不在之前 messages 中的）
                let previousIds = Set(filteredLocal.map { $0.id })
                let newMessages = sorted.filter { !previousIds.contains($0.id) }

                // 检测新消息中的 sub-agent 完成通知
                let hasCompletionNotice = newMessages.contains { msg in
                    msg.isSystemInjected && msg.content.contains("just completed")
                }
                if hasCompletionNotice {
                    appState.clearAllTrackedSubagents()
                }
                // 有新消息时触发侧栏刷新
                if !newMessages.isEmpty {
                    appState.triggerSubagentRefresh()
                }
            }
        } catch {
            // 轮询失败不影响使用，静默忽略
        }
    }

    private func updateDisplayMessages() {
        let updateStart = CFAbsoluteTimeGetCurrent()
        let now = Date()
        if now.timeIntervalSince(lastUpdateTime) < 0.2 { return }
        lastUpdateTime = now

        let filtered = messages.filter { !shouldHideInChat($0) }
        displayMessages = filtered
        // Update display content cache
        var newCache: [String: String] = [:]
        for msg in filtered {
            if let cached = displayContentCache[msg.id] {
                newCache[msg.id] = cached
            } else {
                newCache[msg.id] = chatDisplayContent(msg)
            }
        }
        displayContentCache = newCache
        NSLog("🔥 [UpdateDisplay] took %.1fms, count: %d", (CFAbsoluteTimeGetCurrent() - updateStart) * 1000, displayMessages.count)
    }

    private func deduplicated(_ items: [ChatMessage]) -> [ChatMessage] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private func chatDisplayContent(_ message: ChatMessage) -> String {
        NSLog("🔥 [DisplayContent] called, length: %d, isUser: %d", message.content.count, message.isUser ? 1 : 0)
        if message.isUser && !message.isSystemInjected { return message.content }
        let lines = message.content.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[调用工具：") || trimmed.hasPrefix("[调用工具:") || trimmed.hasPrefix("[Tool:") {
                return false
            }
            return true
        }
        return filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldHideInChat(_ message: ChatMessage) -> Bool {
        if message.isStreaming { return false }
        if message.isUser && !message.isSystemInjected { return false }
        if message.isSystemInjected { return true }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "HEARTBEAT_OK" { return true }
        if message.role == .assistant && message.content.contains("Stats: runtime") { return true }
        let displayContent = chatDisplayContent(message)
        if displayContent.isEmpty { return true }
        return false
    }

    private func sendMessage() {
        // Allow sending while streaming — user message goes out independently

        if let command = filteredCommands.first(where: { $0.name == inputText.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            executeCommand(command, fromMenu: false)
            return
        }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }

        let finalText = text

        var outgoingParts: [GatewayClient.MessagePart] = []
        if !finalText.isEmpty {
            outgoingParts.append(.text(finalText))
        }

        for attachment in attachments {
            switch attachment.kind {
            case .imageDataURL(let dataURL):
                // Save image to local file and send path as text (Gateway drops image_url content parts)
                if let sourceURL = attachment.sourceURL {
                    outgoingParts.append(.text(sourceURL.path))
                } else {
                    // No source file (e.g. pasted image) — decode base64 and save to disk
                    let mediaDir = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".openclaw/media/inbound")
                    try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
                    let fileName = UUID().uuidString + ".jpg"
                    let fileURL = mediaDir.appendingPathComponent(fileName)
                    // Extract base64 data from data URL
                    if let commaIndex = dataURL.firstIndex(of: ",") {
                        let base64String = String(dataURL[dataURL.index(after: commaIndex)...])
                        if let data = Data(base64Encoded: base64String) {
                            try? data.write(to: fileURL)
                        }
                    }
                    outgoingParts.append(.text(fileURL.path))
                }
            case .text(let fileName, let content):
                outgoingParts.append(.text("[附件: \(fileName)]\n\(content)"))
            }
        }

        let previewText = [finalText] + attachments.map(\.displayText)
        let userMessage = ChatMessage(role: .user, content: previewText.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        messages.append(userMessage)
        ChatMessageStore.shared.appendMessage(sessionKey: sessionKey, message: userMessage)
        inputText = ""
        attachments.removeAll()
        appState.chatDrafts.removeValue(forKey: sessionKey)
        showCommandMenu = false

        let streamingId = UUID().uuidString
        streamingGeneration += 1
        let myGeneration = streamingGeneration
        messages.append(ChatMessage(id: streamingId, role: .assistant, content: "", isStreaming: true))
        isStreaming = true
        scrollTrigger += 1

        Task {
            do {
                let stream = client.sendMessage(sessionKey: sessionKey, content: outgoingParts, model: currentModel)
                var buffer = ""
                var lastFlush = Date()
                var tokensSinceLastFlush = 0
                for try await token in stream {
                    buffer += token
                    tokensSinceLastFlush += 1
                    let now = Date()
                    // 每 50ms 或缓冲超过 20 字符时刷新一次 UI
                    if now.timeIntervalSince(lastFlush) > 0.05 || buffer.count > 20 {
                        if let idx = messages.firstIndex(where: { $0.id == streamingId }) {
                            messages[idx].content += buffer
                            NSLog("🔥 [Stream] flush UI, content length: %d, tokens since last: %d", messages[idx].content.count, tokensSinceLastFlush)
                        }
                        buffer = ""
                        lastFlush = now
                        tokensSinceLastFlush = 0
                        scrollTrigger += 1
                    }
                }
                // 刷新剩余缓冲
                if !buffer.isEmpty {
                    if let idx = messages.firstIndex(where: { $0.id == streamingId }) {
                        messages[idx].content += buffer
                    }
                }
                if let idx = messages.firstIndex(where: { $0.id == streamingId }) {
                    messages[idx].isStreaming = false
                    ChatMessageStore.shared.updateLastMessage(sessionKey: sessionKey, message: messages[idx])
                }
                // Capture rate limit info from the client after streaming
                if let info = client.rateLimitInfo, info.hasData {
                    rateLimitInfo = info
                }
                // Only clear streaming state if no newer stream has started
                if streamingGeneration == myGeneration {
                    isStreaming = false
                }
                // 流式结束后立即刷新一次，快速拉取后续消息
                try? await Task.sleep(for: .milliseconds(500))
                // Abort post-stream fetch if a new stream started during the sleep
                guard streamingGeneration == myGeneration else { return }
                if let history = try? await client.getHistory(sessionKey: sessionKey) {
                    // Merge server history with local messages, deduplicating by ID
                    // AND by role+timestamp proximity (local messages have different IDs than server)
                    let existingIds = Set(messages.map(\.id))
                    let existingTimestamps = messages.map { (role: $0.role, ts: Int($0.timestamp.timeIntervalSince1970)) }
                    let newMessages = history.filter { serverMsg in
                        if existingIds.contains(serverMsg.id) { return false }
                        // Check if a local message with same role exists within 2 seconds
                        let serverTs = Int(serverMsg.timestamp.timeIntervalSince1970)
                        let hasTsMatch = existingTimestamps.contains { $0.role == serverMsg.role && abs($0.ts - serverTs) <= 2 }
                        if hasTsMatch { return false }
                        if shouldHideInChat(serverMsg) { return false }
                        return true
                    }
                    if !newMessages.isEmpty {
                        messages.append(contentsOf: newMessages)
                        scrollTrigger += 1
                    }
                }
            } catch {
                if let idx = messages.firstIndex(where: { $0.id == streamingId }) {
                    messages[idx].content = "⚠️ 发送失败: \(error.localizedDescription)"
                    messages[idx].isStreaming = false
                    ChatMessageStore.shared.updateLastMessage(sessionKey: sessionKey, message: messages[idx])
                }
            }
            // Only clear streaming state if no newer stream has started
            if streamingGeneration == myGeneration {
                isStreaming = false
            }
        }
    }

    private func executeCommand(_ command: SlashCommand, fromMenu: Bool) {
        switch command.name {
        case "/status":
            messages.append(ChatMessage(role: .assistant, content: "Agent: \(agent.displayName)\n状态: \(agent.status == .online ? "在线" : "离线")\nSession: \(sessionKey)"))
            inputText = ""
        case "/clear":
            messages.removeAll()
            expandedMessages.removeAll()
            inputText = ""
        case "/model":
            let typed = inputText.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces)
            if typed.count >= 2 {
                currentModel = typed[1]
                messages.append(ChatMessage(role: .assistant, content: "已切换模型: \(currentModel)"))
            } else {
                messages.append(ChatMessage(role: .assistant, content: "当前模型: \(currentModel)\n可输入 `/model <name>` 切换。"))
            }
            inputText = ""
        default:
            break
        }
        if fromMenu { showCommandMenu = false }
    }

    private func pickAttachment() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .png, .jpeg, .gif, .webP,
            .plainText, .text, .utf8PlainText,
            .pdf,
            UTType(filenameExtension: "md") ?? .text,
            UTType(filenameExtension: "swift") ?? .text
        ]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let attachment = try PendingAttachment.from(url: url)
            attachments.append(attachment)
        } catch {
            messages.append(ChatMessage(role: .assistant, content: "⚠️ 附件读取失败: \(error.localizedDescription)"))
        }
    }

}

private struct HistoryLoaderRow: View {
    let isLoading: Bool
    let onAppearAction: () -> Void

    var body: some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text("上拉加载更多")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .onAppear(perform: onAppearAction)
    }
}

// AutoResizingTextView: NSTextView wrapper to avoid SwiftUI TextField paste performance issues
private struct AutoResizingTextView: NSViewRepresentable {
    @Binding var text: String
    var maxHeight: CGFloat = 120
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 4)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 22)
        heightConstraint.isActive = true
        context.coordinator.heightConstraint = heightConstraint
        context.coordinator.maxHeight = maxHeight
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 输入法正在预编辑时不要覆盖文本，否则会打断中文输入
        if textView.hasMarkedText() { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.updateHeight(textView)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AutoResizingTextView
        var heightConstraint: NSLayoutConstraint?
        var maxHeight: CGFloat = 120
        weak var scrollView: NSScrollView?

        init(_ parent: AutoResizingTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // 输入法预编辑阶段不同步，等确认后再同步
            guard !textView.hasMarkedText() else { return }
            parent.text = textView.string
            updateHeight(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let event = NSApp.currentEvent
                if let event, event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit?()
                return true
            }
            return false
        }

        func updateHeight(_ textView: NSTextView) {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let usedHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
            let insetHeight = textView.textContainerInset.height * 2
            let newHeight: CGFloat
            if textView.string.isEmpty {
                newHeight = 22
            } else {
                newHeight = min(max(usedHeight + insetHeight, 22), maxHeight)
            }
            heightConstraint?.constant = newHeight
            scrollView?.hasVerticalScroller = usedHeight + insetHeight > maxHeight
        }
    }
}

// 改动1 & 2: 圆角矩形输入框，VStack布局
private struct ChatInputBar: View {
    @Binding var inputText: String
    let isStreaming: Bool
    let canSend: Bool
    let onPickAttachment: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                AutoResizingTextView(text: $inputText, onSubmit: onSend)
                if inputText.isEmpty {
                    Text("输入消息...")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Button(action: onPickAttachment) {
                    Image(systemName: "paperclip")
                        .font(.title3)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onSend) {
                    Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(10)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }
}

// 改动5: 附件预览支持点击打开
private struct AttachmentPreviewStrip: View {
    let attachments: [PendingAttachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { item in
                    AttachmentChip(attachment: item, onRemove: {
                        onRemove(item.id)
                    })
                }
            }
        }
    }
}

private struct AttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let image = attachment.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "doc.text")
                }
            }

            Button(action: {
                if let url = attachment.sourceURL {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Text(attachment.fileName)
                    .lineLimit(1)
                    .font(.caption)
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SlashCommandMenu: View {
    let commands: [SlashCommand]
    let selectedIndex: Int
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button {
                    onSelect(command)
                } label: {
                    HStack {
                        Text(command.name).font(.subheadline.monospaced())
                        Text(command.description).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(maxWidth: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 6)
    }
}

// 改动3 & 4: isLastMessage参数，截断按钮移到气泡内右下角
private struct MessageBubble: View {
    let message: ChatMessage
    var displayContent: String? = nil
    let agentEmoji: String
    let isExpanded: Bool
    let isLastMessage: Bool
    var rateLimitInfo: RateLimitInfo? = nil
    let onToggleExpand: () -> Void

    @State private var isHovering = false
    @State private var didCopy = false
    @State private var pulseOpacity = 0.25
    @State private var detectedPaths: [String] = []

    private var effectiveContent: String {
        displayContent ?? message.content
    }

    private var shouldTruncate: Bool {
        !isLastMessage && message.isLong && !isExpanded
    }

    private var isLeftAligned: Bool {
        !message.isUser || message.isSystemInjected
    }

    private var leadingEmoji: String? {
        if message.isSystemInjected { return "⚙️" }
        if !message.isUser { return agentEmoji }
        return nil
    }

    nonisolated private static func extractPaths(from text: String) -> [String] {
        let patterns = [
            "~/[^\\s`\\)\\]>\"']+",
            "/Users/[^\\s`\\)\\]>\"']+",
        ]
        var paths: [String] = []
        var seen = Set<String>()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                guard let range = Range(match.range, in: text) else { continue }
                var path = String(text[range])
                // Strip trailing punctuation
                while let last = path.last, ".,:;!?`'\")}]>".contains(last) {
                    path.removeLast()
                }
                if !path.isEmpty && seen.insert(path).inserted {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !isLeftAligned { Spacer(minLength: 60) }
            if let emoji = leadingEmoji { Text(emoji).font(.title3) }

            VStack(alignment: isLeftAligned ? .leading : .trailing, spacing: 4) {
                bubbleBody

                if !detectedPaths.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(detectedPaths, id: \.self) { path in
                            Button {
                                let expanded = path.hasPrefix("~/")
                                    ? FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
                                    : path
                                NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "folder")
                                        .font(.caption2)
                                    Text("打开")
                                        .font(.caption2)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color(.systemGray).opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help(path)
                        }
                    }
                }
//
//                HStack(spacing: 6) {
//                    Text(message.timestamp, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
//                        .font(.caption2)
//                        .foregroundStyle(.tertiary)
//
//                    if message.isAssistant, let rateLimit = rateLimitInfo, rateLimit.hasData {
//                        // 5H utilization - yellow (Claude only)
//                        if let fiveH = rateLimit.fiveHourUtilization {
//                            HStack(spacing: 3) {
//                                Text("5H")
//                                    .font(.system(size: 9))
//                                    .foregroundStyle(.secondary)
//                                RateLimitBar(value: fiveH, tint: .yellow)
//                                Text("\(Int(fiveH * 100))%")
//                                    .font(.system(size: 9))
//                                    .foregroundStyle(.secondary)
//                            }
//                        }
//                        // 7D utilization - blue
//                        if let sevenD = rateLimit.sevenDayUtilization {
//                            HStack(spacing: 3) {
//                                Text("7D")
//                                    .font(.system(size: 9))
//                                    .foregroundStyle(.secondary)
//                                RateLimitBar(value: sevenD, tint: .blue)
//                                Text("\(Int(sevenD * 100))%")
//                                    .font(.system(size: 9))
//                                    .foregroundStyle(.secondary)
//                            }
//                        }
//                    }
//                }
            }

            if isLeftAligned { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bubbleBody: some View {
        let showTruncateButton = !isLastMessage && message.isLong
        let content = shouldTruncate ? String(effectiveContent.prefix(500)) + "..." : effectiveContent

        ZStack(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 4) {
                if message.isStreaming && effectiveContent.isEmpty {
                    ThinkingIndicator()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if message.isStreaming || content.count > 4000 {
                    // 长文本降级到 Text 避免性能问题
                    Text(content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // 使用 MarkdownUI 渲染
                    Markdown(content)
                        .markdownTheme(.basic)
                        .markdownTextStyle {
                            FontSize(.em(0.85))
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if showTruncateButton {
                    HStack {
                        Spacer()
                        Button(isExpanded ? "收起" : "查看全部") { onToggleExpand() }
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(10)
            .background(message.isSystemInjected ? Color.orange.opacity(0.08) : message.isUser ? Color.accentColor.opacity(0.15) : Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if message.isStreaming {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            LinearGradient(colors: [.red.opacity(0.9), .purple.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1.5
                        )
                        .opacity(pulseOpacity)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                                pulseOpacity = 1.0
                            }
                        }
                }
            }

            if message.isAssistant {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.content, forType: .string)
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1500))
                        didCopy = false
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .padding(5)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovering || didCopy ? 1 : 0)
                .padding(6)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct RateLimitBar: View {
    let value: Double  // 0.0 - 1.0
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.25))
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(width: 44, height: 4)
    }
}

private struct ThinkingIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(.secondary).frame(width: 6, height: 6).opacity(0.5)
            }
        }
    }
}

private struct SlashCommand: Identifiable {
    let id = UUID()
    let name: String
    let description: String
}

// PendingAttachment moved to Models/PendingAttachment.swift
