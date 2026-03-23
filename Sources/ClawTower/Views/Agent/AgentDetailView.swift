import MarkdownUI
import SwiftUI

@MainActor
struct AgentDetailView: View {
    let agent: Agent
    let client: GatewayClient

    @State private var selectedModel: String
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColor) private var themeColor

    var onDelete: (() -> Void)?

    // MARK: - MD File Tabs

    private enum MDTab: String, CaseIterable {
        case identity = "IDENTITY.md"
        case agents = "AGENTS.md"
        case soul = "SOUL.md"
        case heartbeat = "HEARTBEAT.md"
        case memory = "MEMORY.md"
        case tools = "TOOLS.md"

        var label: String {
            switch self {
            case .identity: return "身份"
            case .agents: return "原则"
            case .soul: return "灵魂"
            case .heartbeat: return "心跳"
            case .memory: return "记忆"
            case .tools: return "工具"
            }
        }

        var icon: String {
            switch self {
            case .identity: return "person.text.rectangle"
            case .agents: return "list.bullet.rectangle"
            case .soul: return "sparkles"
            case .heartbeat: return "heart.text.square"
            case .memory: return "brain.head.profile"
            case .tools: return "wrench.and.screwdriver"
            }
        }
    }

    @State private var selectedTab: MDTab = .identity
    @State private var tabContents: [MDTab: String] = [:]
    @State private var isEditing = false
    @State private var editingContent: String = ""
    @State private var isSaving = false

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
            // Header
            headerBar
            Divider()

            // Content
            VStack(spacing: 0) {
                // Agent info + model picker row
                agentInfoRow
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)

                Divider()

                // MD file tab bar
                tabBar
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                Divider()

                // MD content area
                mdContentArea
            }
        }
        .frame(minWidth: 620, minHeight: 520)
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
        .task {
            loadAllTabs()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Agent 详情")
                .font(.headline)
            Spacer()

            if agent.id != "main" {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("删除Agent", systemImage: "trash")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.7))
                .disabled(isDeleting)
                .help("删除 Agent")
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Agent Info Row

    private var agentInfoRow: some View {
        HStack(spacing: 14) {
            Text(agent.emoji)
                .font(.system(size: 32))

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                    .font(.title3.bold())
                if let role = agent.roleDescription, !role.isEmpty {
                    Text(role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Model picker
            HStack(spacing: 8) {
                Text("模型")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("", selection: $selectedModel) {
                    ForEach(modelPickerOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .onChange(of: selectedModel) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "modelOverride-\(agent.id)")
                    Task {
                        try? await client.updateAgentModel(agentId: agent.id, model: newValue)
                    }
                }
            }

        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(MDTab.allCases, id: \.self) { tab in
                Button {
                    if isEditing { cancelEditing() }
                    selectedTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.caption)
                        Text(tab.label)
                            .font(.callout.weight(selectedTab == tab ? .semibold : .regular))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        selectedTab == tab ? AnyShapeStyle(themeColor.opacity(0.12)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(selectedTab == tab ? themeColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()

            if !isEditing {
                Button {
                    startEditing()
                } label: {
                    Label("编辑", systemImage: "pencil")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(themeColor)
                .disabled(currentTabContent == nil)
                .help("编辑当前文档")
            } else {
                Button("取消") {
                    cancelEditing()
                }
                .buttonStyle(.plain)

                Button {
                    saveDocument()
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(themeColor)
                .disabled(isSaving)
            }
        }
    }

    // MARK: - MD Content Area

    private var currentTabContent: String? {
        tabContents[selectedTab]
    }

    @ViewBuilder
    private var mdContentArea: some View {
        if isEditing {
            TextEditor(text: $editingContent)
                .font(.body.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let content = currentTabContent {
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: selectedTab.icon)
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("该文档为空")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("点击右上角「编辑」开始撰写")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Markdown(content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: selectedTab.icon)
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("文件不存在")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("创建 \(selectedTab.rawValue)") {
                    createAndEditFile()
                }
                .buttonStyle(.borderedProminent)
                .tint(themeColor)
                .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Workspace Path Resolution

    private func resolveWorkspaceDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent(".openclaw")

        if agent.id == "main" {
            return base.appendingPathComponent("workspace")
        }

        // Try reading workspace path from openclaw.json
        let configURL = base.appendingPathComponent("openclaw.json")
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let agentsConfig = json["agents"] as? [String: Any],
           let agentsList = agentsConfig["list"] as? [[String: Any]],
           let agentConf = agentsList.first(where: { ($0["id"] as? String) == agent.id }),
           let workspace = agentConf["workspace"] as? String {
            let wsPath = (workspace as NSString).expandingTildeInPath
            return URL(fileURLWithPath: wsPath)
        }

        // Fallback
        return base.appendingPathComponent("workspace-\(agent.id)")
    }

    // MARK: - Loading

    private func loadAllTabs() {
        let workspaceDir = resolveWorkspaceDir()
        var contents: [MDTab: String] = [:]

        for tab in MDTab.allCases {
            let fileURL = workspaceDir.appendingPathComponent(tab.rawValue)
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                contents[tab] = content
            }
            // nil means file doesn't exist
        }

        tabContents = contents
    }

    // MARK: - Editing

    private func startEditing() {
        if let content = currentTabContent {
            // Re-read from disk to get latest
            let fileURL = resolveWorkspaceDir().appendingPathComponent(selectedTab.rawValue)
            editingContent = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? content
        } else {
            editingContent = ""
        }
        isEditing = true
    }

    private func cancelEditing() {
        isEditing = false
        editingContent = ""
    }

    private func saveDocument() {
        guard !isSaving else { return }
        isSaving = true
        let contentToSave = editingContent
        let tab = selectedTab

        Task {
            let fileURL = resolveWorkspaceDir().appendingPathComponent(tab.rawValue)
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? contentToSave.write(to: fileURL, atomically: true, encoding: .utf8)

            tabContents[tab] = contentToSave
            isEditing = false
            editingContent = ""
            isSaving = false
        }
    }

    private func createAndEditFile() {
        let fileURL = resolveWorkspaceDir().appendingPathComponent(selectedTab.rawValue)
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let initialContent = "# \(selectedTab.label)\n\n"
        try? initialContent.write(to: fileURL, atomically: true, encoding: .utf8)

        tabContents[selectedTab] = initialContent
        editingContent = initialContent
        isEditing = true
    }
}
