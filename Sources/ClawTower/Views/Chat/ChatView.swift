import SwiftUI
import MarkdownUI

struct ChatView: View {
    let agent: Agent
    let client: GatewayClient
    let sessionKey: String

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var isStreaming = false
    @State private var expandedMessages: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("\(agent.emoji) \(agent.displayName)")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(agent.status == .online ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(agent.status == .online ? "在线" : "离线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(
                                message: message,
                                agentEmoji: agent.emoji,
                                isExpanded: expandedMessages.contains(message.id),
                                onToggleExpand: {
                                    if expandedMessages.contains(message.id) {
                                        expandedMessages.remove(message.id)
                                    } else {
                                        expandedMessages.insert(message.id)
                                    }
                                }
                            )
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input
            HStack(alignment: .bottom, spacing: 8) {
                TextField("输入消息...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit {
                        if !inputText.isEmpty && !isStreaming {
                            sendMessage()
                        }
                    }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(inputText.isEmpty && !isStreaming ? .secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty && !isStreaming)
            }
            .padding(12)
            .background(.bar)
        }
        .task {
            await loadHistory()
        }
    }

    private func loadHistory() async {
        do {
            messages = try await client.getHistory(sessionKey: sessionKey)
        } catch {
            // No history yet or gateway not connected
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""

        let streamingId = UUID().uuidString
        let streamingMessage = ChatMessage(id: streamingId, role: .assistant, content: "", isStreaming: true)
        messages.append(streamingMessage)
        isStreaming = true

        Task {
            do {
                let stream = client.sendMessage(sessionKey: sessionKey, content: text)
                for try await token in stream {
                    if let idx = messages.firstIndex(where: { $0.id == streamingId }) {
                        messages[idx].content += token
                    }
                }
                if let idx = messages.firstIndex(where: { $0.id == streamingId }) {
                    messages[idx].isStreaming = false
                }
            } catch {
                if let idx = messages.firstIndex(where: { $0.id == streamingId }) {
                    messages[idx].content = "⚠️ 发送失败: \(error.localizedDescription)"
                    messages[idx].isStreaming = false
                }
            }
            isStreaming = false
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    let agentEmoji: String
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isUser {
                Spacer(minLength: 60)
            } else {
                Text(agentEmoji)
                    .font(.title3)
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                if message.isStreaming && message.content.isEmpty {
                    // Thinking animation
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(.secondary)
                                .frame(width: 6, height: 6)
                                .opacity(0.5)
                        }
                    }
                    .padding(12)
                    .background(Color(.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    let displayContent = (!isExpanded && message.isLong)
                        ? String(message.content.prefix(500)) + "..."
                        : message.content

                    Group {
                        if message.isUser {
                            Text(displayContent)
                                .textSelection(.enabled)
                        } else if message.content.count > 4000 {
                            Text(displayContent)
                                .textSelection(.enabled)
                        } else {
                            Markdown(displayContent)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .background(message.isUser ? Color.accentColor.opacity(0.15) : Color(.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    if message.isLong {
                        Button(isExpanded ? "收起" : "查看全部") {
                            onToggleExpand()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !message.isUser {
                Spacer(minLength: 60)
            }
        }
    }
}
