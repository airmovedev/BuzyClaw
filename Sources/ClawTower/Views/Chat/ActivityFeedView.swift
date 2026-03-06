import SwiftUI

// MARK: - Activity Item

private enum ActivityKind: String, CaseIterable {
    case tool = "工具"
    case system = "系统"
    case heartbeat = "心跳"
    case subagent = "子任务"
}

private struct ActivityItem: Identifiable {
    let id = UUID()
    let kind: ActivityKind
    let toolName: String
    let summary: String
    let iconName: String
    let timestamp: Date
    let isError: Bool
}

// MARK: - ActivityFeedView

struct ActivityFeedView: View {
    let client: GatewayClient
    let sessionKey: String
    @State private var items: [ActivityItem] = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty && !isLoading {
                Spacer()
                Text("暂无活动")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedByDate, id: \.0) { dateLabel, dayItems in
                            Text(dateLabel)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 4)

                            ForEach(dayItems) { item in
                                activityRow(item)
                                Divider()
                                    .padding(.leading, 36)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .background {
            if #available(macOS 26, *) {
                Color.clear
            } else {
                Color(.windowBackgroundColor)
            }
        }
        .task {
            await loadItems()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await loadItems()
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ item: ActivityItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if #available(macOS 26, *) {
                Image(systemName: item.iconName)
                    .font(.caption)
                    .foregroundStyle(item.isError ? .red : .secondary)
                    .frame(width: 16, height: 16)
                    .glassEffect(.regular, in: .circle)
            } else {
                Image(systemName: item.iconName)
                    .font(.caption)
                    .foregroundStyle(item.isError ? .red : .secondary)
                    .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(item.isError ? .red : .primary)
                    .lineLimit(4)
                Text(item.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Grouping

    private var groupedByDate: [(String, [ActivityItem])] {
        let cal = Calendar.current
        var groups: [(String, [ActivityItem])] = []
        var current: (String, [ActivityItem])?

        for item in items {
            let label = dateLabel(for: item.timestamp, calendar: cal)
            if current?.0 == label {
                current?.1.append(item)
            } else {
                if let c = current { groups.append(c) }
                current = (label, [item])
            }
        }
        if let c = current { groups.append(c) }
        return groups
    }

    private func dateLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日"
        return fmt.string(from: date)
    }

    // MARK: - Data Loading

    private func loadItems() async {
        if items.isEmpty {
            isLoading = true
        }
        defer { isLoading = false }

        guard let messages = try? await client.getHistoryWithTools(sessionKey: sessionKey) else { return }

        var parsed: [ActivityItem] = []
        for msg in messages {
            let role = msg["role"] as? String ?? ""
            let ts = (msg["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            let isSystem = MessageParser.isSystemInjected(role: role, content: msg["content"])

            // Parse text content for filtered message types
            let textContent: String = {
                if let s = msg["content"] as? String { return s }
                if let arr = msg["content"] as? [[String: Any]] {
                    return arr.compactMap { $0["text"] as? String }.joined()
                }
                return ""
            }()
            let trimmedText = textContent.trimmingCharacters(in: .whitespacesAndNewlines)

            // Background task completion (check before system to avoid duplicate)
            if MessageParser.isSubagentCompletion(role: role, content: msg["content"], isSystemInjected: isSystem) {
                let taskName = MessageParser.extractSubagentTaskName(from: msg["content"])
                parsed.append(ActivityItem(
                    kind: .subagent,
                    toolName: "subagent",
                    summary: "任务：「\(taskName)」已完成",
                    iconName: "checkmark.circle.fill",
                    timestamp: ts,
                    isError: false
                ))
                continue
            }

            // System injected messages
            if isSystem {
                let summary = String(textContent.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
                parsed.append(ActivityItem(
                    kind: .system,
                    toolName: "system",
                    summary: summary.isEmpty ? "系统消息" : summary,
                    iconName: "gearshape",
                    timestamp: ts,
                    isError: false
                ))
            }

            // HEARTBEAT_OK
            if trimmedText == "HEARTBEAT_OK" {
                parsed.append(ActivityItem(
                    kind: .heartbeat,
                    toolName: "heartbeat",
                    summary: "心跳检查",
                    iconName: "heart.fill",
                    timestamp: ts,
                    isError: false
                ))
            }

            // Tool call text messages — only from system-injected or assistant messages
            let isToolCallCandidate = (role == "user" && isSystem) || role == "assistant"
            if isToolCallCandidate && (textContent.contains("[调用工具：") || textContent.contains("[调用工具:") || textContent.contains("[Tool:")) {
                let toolName = extractToolName(from: textContent)
                let detail = extractToolDetail(from: textContent, toolName: toolName)
                let summary = detail.isEmpty ? "调用 \(toolName)" : "调用 \(toolName): \(detail)"
                parsed.append(ActivityItem(
                    kind: .tool,
                    toolName: toolName,
                    summary: summary,
                    iconName: MessageParser.toolIcon(toolName),
                    timestamp: ts,
                    isError: false
                ))
            }

            // Existing: toolCall blocks from content array
            if role == "assistant", let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    guard let type = block["type"] as? String, type == "toolCall" else { continue }
                    let name = block["name"] as? String ?? "unknown"
                    let args = block["arguments"] as? [String: Any] ?? block["input"] as? [String: Any] ?? [:]
                    let detail = MessageParser.toolDetail(name: name, arguments: args)
                    let summary = detail.isEmpty ? MessageParser.toolSummary(name) : "\(MessageParser.toolSummary(name)): \(detail)"
                    parsed.append(ActivityItem(
                        kind: .tool,
                        toolName: name,
                        summary: summary,
                        iconName: MessageParser.toolIcon(name),
                        timestamp: ts,
                        isError: false
                    ))
                }
            }
        }

        // Sort by time descending (newest first)
        items = parsed.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Helpers

    private func extractToolName(from text: String) -> String {
        // Match [调用工具：xxx] or [调用工具: xxx] or [Tool: xxx]
        if let match = text.range(of: #"\[调用工具[：:]\s*([^\]]+)\]"#, options: .regularExpression) {
            let inner = text[match].dropFirst(1).dropLast(1) // drop [ and ]
            // Drop "调用工具：" or "调用工具: " prefix
            if let colonRange = inner.range(of: #"调用工具[：:]\s*"#, options: .regularExpression) {
                return String(inner[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        if let match = text.range(of: #"\[Tool:\s*([^\]]+)\]"#, options: .regularExpression) {
            let inner = text[match].dropFirst(1).dropLast(1)
            if let colonRange = inner.range(of: #"Tool:\s*"#, options: .regularExpression) {
                return String(inner[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return "工具"
    }

    private func extractToolDetail(from text: String, toolName: String) -> String {
        // Try to find content after the [调用工具: xxx] tag
        let patterns = [
            #"\[调用工具[：:]\s*[^\]]+\]\s*"#,
            #"\[Tool:\s*[^\]]+\]\s*"#
        ]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let after = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty {
                    return String(after.prefix(60))
                }
            }
        }
        return ""
    }

    // Tool detail/summary/icon methods moved to MessageParser
}
