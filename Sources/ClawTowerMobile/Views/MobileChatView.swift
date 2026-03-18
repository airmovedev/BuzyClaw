import SwiftUI
import PhotosUI
import CloudKit

struct MobileChatView: View {
    let agentId: String
    let agentName: String

    @Environment(\.themeColor) private var themeColor
    @Environment(CloudKitMessageClient.self) private var messageClient
    @Environment(DashboardSnapshotStore.self) private var snapshotStore
    @Environment(SpeechRecognitionService.self) private var speechService
    @State private var inputText = ""
    @State private var isSending = false
    @State private var showSessionPicker = false
    @State private var showPermissionAlert = false
    @FocusState private var isInputFocused: Bool
    @State private var pendingImageData: Data?
    @State private var pendingImagePreview: UIImage?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var voiceGlowOpacity: Double = 1.0

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
                NavigationLink {
                    AgentDetailView(agentId: agentId, fallbackName: agentName)
                } label: {
                    Image(systemName: "info.circle")
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
            await snapshotStore.refresh()
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    if messageClient.allSessionMessages.isEmpty {
                        emptyState
                    } else {
                        // "Load more" button at the top
                        if messageClient.hasMoreMessages {
                            Button {
                                messageClient.loadMoreMessages()
                            } label: {
                                Text("加载更早的消息")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            }
                            .id("load-more")
                        }

                        let messages = messageClient.displayedMessages
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
            .onChange(of: messageClient.allSessionMessages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: messageClient.isWaitingForReply) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: messageClient.allSessionMessages.last?.status) {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.3)) {
            if messageClient.isWaitingForReply {
                proxy.scrollTo("typing-indicator", anchor: .bottom)
            } else if let last = messageClient.displayedMessages.last {
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
            if !snapshotStore.isMacOSConnected {
                Text("guide.chat.ready")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("guide.chat.sync_hint")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("通过 iCloud 向 Gateway 发送消息")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Whether voice input is currently active.
    private var isVoiceActive: Bool {
        speechService.state == .recording
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            if !snapshotStore.isMacOSConnected {
                // Disconnected state: show neutral guidance
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Text("guide.chat.input_hint")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("guide.chat.input_detail")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.bar)
            } else {
                normalInputBar
            }
        }
        .background(.bar)
        .onChange(of: speechService.liveText) { _, newText in
            if isVoiceActive {
                inputText = newText
            }
        }
        .onChange(of: speechService.state) { oldState, newState in
            if newState == .recording {
                startVoiceGlow()
            } else if oldState == .recording {
                stopVoiceGlow()
                // Clear liveText so stale transcription doesn't leak back into inputText
                // (e.g. when user clears the field then dismisses keyboard)
                speechService.liveText = ""
            }
        }
        .alert("需要麦克风权限", isPresented: $showPermissionAlert) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在设置中允许虾忙访问麦克风，以便使用语音输入")
        }
    }

    // MARK: - Normal Input Bar

    private var normalInputBar: some View {
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
                    ZStack {
                        Circle()
                            .stroke(themeColor.opacity(0.3), lineWidth: 1.5)
                            .frame(width: 36, height: 36)
                        Image(systemName: "paperclip")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(themeColor)
                    }
                }
                .onChange(of: selectedPhotoItem) { _, newItem in
                    guard let newItem else { return }
                    Task { await loadPhoto(from: newItem) }
                    selectedPhotoItem = nil
                }

                TextField(isVoiceActive ? String(localized: "voice.listening_hint") : "输入消息...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isInputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(themeColor, lineWidth: isVoiceActive ? 2 : 0)
                            .opacity(isVoiceActive ? voiceGlowOpacity : 0)
                    )
                    .onSubmit { sendIfReady() }
                    .disabled(isVoiceActive)

                if isVoiceActive {
                    // Recording: show stop button
                    Button {
                        speechService.stopRecording()
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(Color.red, lineWidth: 1.5)
                                .frame(width: 36, height: 36)
                            Image(systemName: "stop.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.red)
                        }
                    }
                } else if canSend {
                    Button {
                        sendIfReady()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(themeColor)
                    }
                } else if speechService.state == .loading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 36, height: 36)
                } else {
                    Button {
                        Task { await startVoiceInput() }
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(speechService.isModelReady ? themeColor.opacity(0.3) : themeColor.opacity(0.1), lineWidth: 1.5)
                                .frame(width: 36, height: 36)
                            Image(systemName: "mic.fill")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(speechService.isModelReady ? themeColor : themeColor.opacity(0.2))
                        }
                    }
                    .disabled(!speechService.isModelReady)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
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

    // MARK: - Voice Input

    private func startVoiceInput() async {
        let granted = await speechService.requestPermissions()
        guard granted else {
            showPermissionAlert = true
            return
        }
        speechService.startRecording()
    }

    private func startVoiceGlow() {
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            voiceGlowOpacity = 0.3
        }
    }

    private func stopVoiceGlow() {
        withAnimation(.easeInOut(duration: 0.3)) {
            voiceGlowOpacity = 1.0
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
    @Environment(\.themeColor) private var themeColor
    @Environment(CloudKitMessageClient.self) private var messageClient
    @Environment(DashboardSnapshotStore.self) private var snapshotStore
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionSnapshot] = []
    @State private var isLoading = false

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
                        .foregroundStyle(themeColor)
                }
            }
        }
        .tint(.primary)
    }

    private func fetchSessions() async {
        isLoading = true
        defer { isLoading = false }

        await snapshotStore.refresh()
        sessions = (snapshotStore.snapshot?.sessions ?? []).filter { $0.agentId == agentId }
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

    @Environment(\.themeColor) private var themeColor
    @Environment(CloudKitMessageClient.self) private var messageClient
    @Namespace private var imageTransitionNS

    private var isUser: Bool { message.direction == .toGateway }
    @State private var isExpanded = false
    @State private var fullscreenImage: UIImage?

    private var timestampText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: message.timestamp)
    }

    private var attachmentImages: [UIImage] {
        // Priority 1: CKAsset image (live CloudKit cache)
        if let asset = message.imageAsset, let fileURL = asset.fileURL,
           let data = try? Data(contentsOf: fileURL), let img = UIImage(data: data) {
            return [img]
        }
        // Priority 2: Locally persisted image cache
        if let cachedData = CloudKitMessageClient.cachedImageData(for: message.id),
           let img = UIImage(data: cachedData) {
            return [img]
        }
        // Priority 3: Legacy base64 data URL in metadata (backward compat)
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
                        .matchedTransitionSource(id: "imageViewer", in: imageTransitionNS)
                        .onTapGesture { fullscreenImage = img }
                }

                if isUser {
                    if message.content != "[图片]" {
                        Text(message.content)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(themeColor, in: RoundedRectangle(cornerRadius: 16))
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
        .fullScreenCover(isPresented: Binding(
            get: { fullscreenImage != nil },
            set: { if !$0 { fullscreenImage = nil } }
        )) {
            if let img = fullscreenImage {
                ImageViewerSheet(image: img)
                    .navigationTransition(.zoom(sourceID: "imageViewer", in: imageTransitionNS))
            }
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
                switch messageClient.frontendStatus(for: message) {
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

// MARK: - Fullscreen Image Viewer

private struct ImageViewerSheet: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false
    @State private var savedToPhotos = false
    @State private var saveError: String?

    // Pinch-to-zoom state
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let newScale = lastScale * value.magnification
                            scale = max(1.0, min(newScale, 5.0))
                        }
                        .onEnded { _ in
                            if scale <= 1.0 {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    scale = 1.0
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                            lastScale = scale
                        }
                        .simultaneously(with:
                            DragGesture()
                                .onChanged { value in
                                    guard scale > 1.0 else { return }
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                }
                        )
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if scale > 1.0 {
                            scale = 1.0
                            lastScale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2.5
                            lastScale = 2.5
                        }
                    }
                }
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .glassCircleButton()
            .padding(.leading, 8)
            .padding(.top, 4)
        }
        .overlay(alignment: .topTrailing) {
            Menu {
                Button {
                    saveToPhotos()
                } label: {
                    Label("保存到相册", systemImage: "photo.on.rectangle")
                }
                Button {
                    showShareSheet = true
                } label: {
                    Label("分享 / 存储到文件", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .glassCircleButton()
            .padding(.trailing, 8)
            .padding(.top, 4)
        }
        .overlay(alignment: .bottom) {
            if savedToPhotos {
                Text("已保存到相册")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.green, in: Capsule())
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let error = saveError {
                Text(error)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.red, in: Capsule())
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: savedToPhotos)
        .animation(.easeInOut, value: saveError)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [image])
        }
    }

    private func saveToPhotos() {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        savedToPhotos = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            savedToPhotos = false
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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

// MARK: - Liquid Glass circle button helper

private extension View {
    @ViewBuilder
    func glassCircleButton() -> some View {
        if #available(iOS 26, *) {
            self
                .buttonStyle(.borderless)
                .foregroundStyle(.white)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            self
                .foregroundStyle(.white)
                .background(.white.opacity(0.2), in: Circle())
        }
    }
}


