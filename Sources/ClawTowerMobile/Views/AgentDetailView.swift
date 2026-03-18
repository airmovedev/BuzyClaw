import MarkdownUI
import SwiftUI

struct AgentDetailView: View {
    let agentId: String
    let fallbackName: String

    @Environment(\.themeColor) private var themeColor
    @Environment(DashboardSnapshotStore.self) private var snapshotStore

    init(agentId: String, fallbackName: String) {
        self.agentId = agentId
        self.fallbackName = fallbackName
    }

    private var agent: AgentSnapshot {
        snapshotStore.agent(for: agentId)
        ?? AgentSnapshot(id: agentId, displayName: fallbackName, emoji: nil, availableModels: snapshotStore.snapshot?.availableModels)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Text(agent.identityEmoji ?? agent.emoji ?? "🤖")
                        .font(.system(size: 48))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.identityName ?? agent.displayName)
                            .font(.title3.bold())
                        if let creature = agent.creature, !creature.isEmpty {
                            Text(creature)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let vibe = agent.vibe, !vibe.isEmpty {
                            Text(vibe)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("AI 模型") {
                HStack {
                    Text("当前模型")
                    Spacer()
                    Text(agent.resolvedWorkingModel ?? "未同步")
                        .foregroundStyle(.secondary)
                }

                if let configuredModel = normalizedModel(agent.configuredModel),
                   configuredModel != normalizedModel(agent.resolvedWorkingModel) {
                    HStack {
                        Text("配置模型")
                        Spacer()
                        Text(configuredModel)
                            .foregroundStyle(.secondary)
                    }
                }

                if let models = agent.availableModels, !models.isEmpty {
                    NavigationLink {
                        List(models, id: \.self) { model in
                            HStack {
                                Text(model)
                                Spacer()
                                if model == agent.resolvedWorkingModel {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(themeColor)
                                }
                            }
                        }
                        .navigationTitle("可用模型")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack {
                            Text("可用模型")
                            Spacer()
                            Text("\(models.count) 个")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let files = agent.workspaceFiles, !files.isEmpty {
                Section("Workspace 文档") {
                    ForEach(files) { file in
                        NavigationLink {
                            WorkspaceFileDetailView(file: file)
                        } label: {
                            Label {
                                Text(file.displayName)
                            } icon: {
                                Image(systemName: file.icon)
                                    .foregroundStyle(themeColor)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Agent 详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await snapshotStore.refresh()
        }
    }

    private func normalizedModel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "default"
        else {
            return nil
        }

        return trimmed
    }
}

// MARK: - Workspace File Detail View

struct WorkspaceFileDetailView: View {
    let file: AgentWorkspaceFile

    var body: some View {
        ScrollView {
            if file.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("文档为空", systemImage: file.icon)
                } description: {
                    Text("该文档暂无内容")
                }
            } else {
                Markdown(file.content)
                    .textSelection(.enabled)
                    .padding()
            }
        }
        .navigationTitle(file.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
