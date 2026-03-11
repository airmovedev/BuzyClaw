import SwiftUI
import PhotosUI
import CloudKit

struct MobileChatView: View {
    let agentId: String
    let agentName: String

    @Environment(CloudKitMessageClient.self) private var messageClient
    @State private var inputText = ""
    @State private var isSending = false
    @State private var showSessionPicker = false
    @FocusState private var isInputFocused: Bool
    @State private var showAgentDetail = false
    @State private var agentSnapshot: AgentSnapshot?
    @State private var currentSessionSnapshot: SessionSnapshot?
    @State private var availableModels: [String] = []
    @State private var pendingImageData: Data?
    @State private var pendingImagePreview: UIImage?
    @State private var selectedPhotoItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
        }
        .navigationTitle(agentName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    showSessionPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text(agentName)
                            .font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        let shortId = UUID().uuidString.prefix(8).lowercased()
                        let newKey = "agent:\(agentId):mobile-\(shortId)"
                        messageClient.selectSession(newKey)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }

                    NavigationLink {
                        AgentDetailView(
                            agent: agentSnapshot ?? AgentSnapshot(id: agentId, displayName: agentName, emoji: nil),
                            currentSession: currentSessionSnapshot,
                            availableModels: availableModels
                        )
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showSessionPicker) {
            NavigationStack {
                SessionPickerView(agentId: agentId, agentName: agentName)
            }
            .presentationDetents([.medium])
        }
        .task {
            messageClient.selectAgent(agentId)
            await fetchAgentSnapshot()
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    if messageClient.messages.isEmpty {
                        emptyState
                    } else {
                        let messages = messageClient.messages
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            let shouldTruncate = index < messages.count - 3
                            MobileMessageBubble(message: message, shouldTruncate: shouldTruncate)
                                .id(message.id)
                        }

                        if messageClient.isWaitingForReply {
                            TypingIndicatorView()
                                .id("typing-indicator")
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messageClient.messages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: messageClient.isWaitingForReply) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: messageClient.messages.last?.status) {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.3)) {
            if messageClient.isWaitingForReply {
                proxy.scrollTo("typing-indicator", anchor: .bottom)
            } else if let last = messageClient.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 100)
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("通过 iCloud 向 Gateway 发送消息")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("确保 macOS ClawTower 正在运行")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Pending image preview
            if let uiImage = pendingImagePreview {
                HStack {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                pendingImageData = nil
                                pendingImagePreview = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .offset(x: 6, y: -6)
                        }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            HStack(spacing: 8) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .onChange(of: selectedPhotoItem) { _, newItem in
                    guard let newItem else { return }
                    Task { await loadPhoto(from: newItem) }
                    selectedPhotoItem = nil
                }

                TextField("输入消息...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 20))
                    .onSubmit { sendIfReady() }

                Button {
                    sendIfReady()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? Color.accentColor : .secondary)
                }
                .disabled(!canSend)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImage = pendingImageData != nil
        return (hasText || hasImage) && !isSending
    }

    private func sendIfReady() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImage = pendingImageData != nil
        guard (!text.isEmpty || hasImage), !isSending else { return }

        isSending = true
        let contentText = text.isEmpty ? "[图片]" : text
        let imageData = pendingImageData
        inputText = ""
        pendingImageData = nil
        pendingImagePreview = nil

        Task {
            if let imageData {
                // Write to temp file and create CKAsset
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                do {
                    try imageData.write(to: tempURL)
                } catch {
                    isSending = false
                    return
                }
                let asset = CKAsset(fileURL: tempURL)
                await messageClient.sendMessage(contentText, imageAsset: asset)
                try? FileManager.default.removeItem(at: tempURL)
            } else {
                await messageClient.sendMessage(contentText)
            }
            isSending = false
        }
    }

    // MARK: - Photo Loading

    private func loadPhoto(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        guard let uiImage = UIImage(data: data) else { return }
        guard let jpegData = compressImageForAsset(uiImage) else { return }
        pendingImageData = jpegData
        pendingImagePreview = UIImage(data: jpegData)
    }

    private func compressImageForAsset(_ image: UIImage) -> Data? {
        var targetImage = image

        // Compress at quality 0.8
        guard var jpegData = targetImage.jpegData(compressionQuality: 0.8) else { return nil }

        // If > 5MB, resize to max 2048px on longest side and re-compress
        if jpegData.count > 5_000_000 {
            let maxDimension: CGFloat = 2048
            let size = targetImage.size
            if max(size.width, size.height) > maxDimension {
                let scale = maxDimension / max(size.width, size.height)
                let newSize = CGSize(width: size.width * scale, height: size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: newSize)
                targetImage = renderer.image { _ in
                    targetImage.draw(in: CGRect(origin: .zero, size: newSize))
                }
            }
            jpegData = targetImage.jpegData(compressionQuality: 0.8) ?? jpegData
        }

        return jpegData
    }

    // MARK: - Fetch Agent Snapshot

    private func fetchAgentSnapshot() async {
        let database = CKContainer(identifier: CloudKitConstants.containerID).privateCloudDatabase
        do {
            let record = try await database.record(for: DashboardSnapshotRecord.recordID)
            if let snap = DashboardSnapshotRecord.from(record: record) {
                agentSnapshot = snap.agents.first { $0.id == agentId }
                currentSessionSnapshot = snap.sessions?.first { $0.id == messageClient.currentSessionKey }
                availableModels = snap.availableModels ?? []
            }
        } catch {
            // Silently fail
        }
    }

    // MARK: - Sync Status

    private var syncStatusView: some View {
        Group {
            if messageClient.isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else if messageClient.lastError != nil {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.green)
            }
        }
    }
}

// MARK: - Session Picker

struct SessionPickerView: View {
    let agentId: String
    let agentName: String
    @Environment(CloudKitMessageClient.self) private var messageClient
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionSnapshot] = []
    @State private var isLoading = false

    private let database = CKContainer(identifier: CloudKitConstants.containerID).privateCloudDatabase

    var body: some View {
        List {
            Section {
                Button {
                    let shortId = UUID().uuidString.prefix(8).lowercased()
                    let newKey = "agent:\(agentId):mobile-\(shortId)"
                    messageClient.selectSession(newKey)
                    dismiss()
                } label: {
                    Label("新建会话", systemImage: "plus.bubble")
                }
            }

            Section("主会话") {
                sessionRow(
                    key: "agent:\(agentId):main",
                    label: "主会话",
                    icon: "bubble.left.and.bubble.right",
                    kind: "main"
                )
            }

            let subagentSessions = sessions.filter { $0.kind == "subagent" }
            if !subagentSessions.isEmpty {
                Section("子任务") {
                    ForEach(subagentSessions) { session in
                        sessionRow(
                            key: session.id,
                            label: session.label ?? session.id,
                            icon: "arrow.triangle.branch",
                            kind: "subagent",
                            lastMessage: session.lastMessage,
                            tokens: session.totalTokens
                        )
                    }
                }
            }

            let cronSessions = sessions.filter { $0.kind == "cron" }
            if !cronSessions.isEmpty {
                Section("定时任务") {
                    ForEach(cronSessions) { session in
                        sessionRow(
                            key: session.id,
                            label: session.label ?? session.id,
                            icon: "clock",
                            kind: "cron",
                            lastMessage: session.lastMessage,
                            tokens: session.totalTokens
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if isLoading && sessions.isEmpty {
                ProgressView()
            }
        }
        .task { await fetchSessions() }
    }

    private func sessionRow(
        key: String,
        label: String,
        icon: String,
        kind: String,
        lastMessage: String? = nil,
        tokens: Int = 0
    ) -> some View {
        Button {
            messageClient.selectSession(key)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(kind == "main" ? .blue : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let msg = lastMessage, !msg.isEmpty {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if tokens > 0 {
                    Text(formatTokens(tokens))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if key == messageClient.currentSessionKey {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .tint(.primary)
    }

    private func fetchSessions() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let record = try await database.record(for: DashboardSnapshotRecord.recordID)
            if let snap = DashboardSnapshotRecord.from(record: record) {
                self.sessions = (snap.sessions ?? []).filter { $0.agentId == agentId }
            }
        } catch {
            // Silently fail — main session is always available
            sessions = []
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Message Bubble

struct MobileMessageBubble: View {
    let message: MessageRecord
    var shouldTruncate: Bool = true

    private var isUser: Bool { message.direction == .toGateway }
    @State private var isExpanded = false

    private var timestampText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: message.timestamp)
    }

    private var attachmentImages: [UIImage] {
        // Priority 1: CKAsset image
        if let asset = message.imageAsset, let fileURL = asset.fileURL,
           let data = try? Data(contentsOf: fileURL), let img = UIImage(data: data) {
            return [img]
        }
        // Priority 2: Legacy base64 data URL in metadata (backward compat)
        guard let data = message.metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attachments = json["attachments"] as? [[String: Any]] else {
            return []
        }
        return attachments.compactMap { att in
            guard (att["type"] as? String) == "image_url",
                  let url = att["url"] as? String else { return nil }
            return imageFromDataURL(url)
        }
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Show attachment images
                ForEach(Array(attachmentImages.enumerated()), id: \.offset) { _, img in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if isUser {
                    if message.content != "[图片]" {
                        Text(message.content)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                            .foregroundStyle(.white)
                    }
                } else {
                    agentBubble
                }

                HStack(spacing: 4) {
                    if isUser {
                        messageStatusView
                    }
                    Text(timestampText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }

    private var agentBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if shouldTruncate && message.content.count > 500 && !isExpanded {
                Text(String(message.content.prefix(500)) + "…")
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))

                Button("查看全部") {
                    isExpanded = true
                }
                .font(.caption)
                .padding(.leading, 14)
            } else {
                Text(mobileMarkdownAttributedString(message.content))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    @ViewBuilder
    private var messageStatusView: some View {
        if isUser {
            HStack(spacing: 4) {
                switch message.status {
                case .pending:
                    ProgressView()
                        .controlSize(.mini)
                    Text("发送中")
                case .sent:
                    Image(systemName: "checkmark")
                    Text("已发送")
                case .received:
                    Image(systemName: "checkmark")
                    Image(systemName: "checkmark")
                    Text("已接收")
                case .delivered, .read:
                    EmptyView()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

private func imageFromDataURL(_ dataURL: String) -> UIImage? {
    guard dataURL.hasPrefix("data:"),
          let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
    let base64String = String(dataURL[dataURL.index(after: commaIndex)...])
    guard let data = Data(base64Encoded: base64String) else { return nil }
    return UIImage(data: data)
}

private func mobileMarkdownAttributedString(_ string: String) -> AttributedString {
    do {
        return try AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    } catch {
        return AttributedString(string)
    }
}
