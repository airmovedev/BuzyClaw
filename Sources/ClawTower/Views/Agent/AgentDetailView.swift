import SwiftUI

@MainActor
struct AgentDetailView: View {
    let agent: Agent
    let client: GatewayClient

    @State private var selectedModel: String
    @State private var identityContent: String = ""
    @State private var sessions: [Session] = []
    @State private var isLoadingSessions = false
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @Environment(\.dismiss) private var dismiss

    var onDelete: (() -> Void)?

    init(agent: Agent, client: GatewayClient, onDelete: (() -> Void)? = nil) {
        self.agent = agent
        self.client = client
        self.onDelete = onDelete
        let saved = UserDefaults.standard.string(forKey: "modelOverride-\(agent.id)")
        let raw = saved ?? agent.model ?? AgentDraft.modelOptions[0]
        let resolved = (raw == "default") ? AgentDraft.modelOptions[0] : raw
        _selectedModel = State(initialValue: resolved)
    }

    private var modelPickerOptions: [String] {
        if AgentDraft.modelOptions.contains(selectedModel) {
            return AgentDraft.modelOptions
        } else {
            return AgentDraft.modelOptions + [selectedModel]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent 详情")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Form {
                // Agent Info
                Section("基本信息") {
                    HStack(spacing: 12) {
                        Text(agent.emoji)
                            .font(.system(size: 40))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent.displayName)
                                .font(.title3.bold())
                        }
                    }
                    .padding(.vertical, 4)

                    if !identityContent.isEmpty {
                        Text(identityContent)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                // Model Selection
                Section("AI 模型") {
                    Picker("模型", selection: $selectedModel) {
                        ForEach(modelPickerOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .onChange(of: selectedModel) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "modelOverride-\(agent.id)")
                        Task {
                            try? await client.updateAgentModel(agentId: agent.id, model: newValue)
                        }
                    }
                }

                // Delete Agent — 不允许删除 main agent
                if agent.id != "main" {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                if isDeleting {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("删除中...")
                                } else {
                                    Image(systemName: "trash")
                                    Text("删除 Agent")
                                }
                                Spacer()
                            }
                        }
                        .disabled(isDeleting)
                    } footer: {
                        Text("删除将清除该 Agent 的所有历史对话、workspace 文件和配置。此操作不可恢复。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .alert("确认删除", isPresented: $showDeleteConfirmation) {
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) {
                    Task {
                        isDeleting = true
                        do {
                            try await client.deleteAgent(id: agent.id)
                            dismiss()
                            onDelete?()
                        } catch {
                            print("[ClawTower] deleteAgent failed: \(error)")
                            isDeleting = false
                        }
                    }
                }
            } message: {
                Text("确定要删除 \(agent.displayName) 吗？\n\n这将删除所有历史对话、workspace 文件和配置，且无法恢复。")
            }
        }
        .frame(minWidth: 420, minHeight: 400)
        .task {
            loadIdentity()
            await loadSessions()
        }
    }

    private func loadIdentity() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent(".openclaw")

        var identityURL: URL
        if agent.id == "main" {
            identityURL = base.appendingPathComponent("workspace/IDENTITY.md")
        } else {
            // 从 openclaw.json 读取 agent 的 workspace 路径
            let configURL = base.appendingPathComponent("openclaw.json")
            if let data = try? Data(contentsOf: configURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let agentsConfig = json["agents"] as? [String: Any],
               let agentsList = agentsConfig["list"] as? [[String: Any]],
               let agentConf = agentsList.first(where: { ($0["id"] as? String) == agent.id }),
               let workspace = agentConf["workspace"] as? String {
                let wsPath = (workspace as NSString).expandingTildeInPath
                identityURL = URL(fileURLWithPath: wsPath).appendingPathComponent("IDENTITY.md")
            } else {
                // fallback: 尝试常见路径模式
                identityURL = base.appendingPathComponent("workspace-\(agent.id)/IDENTITY.md")
            }
        }
        guard let content = try? String(contentsOf: identityURL, encoding: .utf8) else {
            identityContent = ""
            return
        }

        var parts: [String] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("**Creature:**") {
                let value = trimmed.replacingOccurrences(of: "- **Creature:**", with: "").trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { parts.append(value) }
            } else if trimmed.contains("**Vibe:**") {
                let value = trimmed.replacingOccurrences(of: "- **Vibe:**", with: "").trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { parts.append(value) }
            }
        }
        identityContent = parts.joined(separator: "\n")
    }

    private func loadSessions() async {
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        sessions = (try? await client.listSessions(agentId: agent.id, limit: 100)) ?? []
        sessions.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
