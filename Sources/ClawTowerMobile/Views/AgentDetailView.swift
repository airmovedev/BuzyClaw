import SwiftUI

struct AgentDetailView: View {
    let agentId: String
    let fallbackName: String

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
                VStack(alignment: .leading, spacing: 6) {
                    Text(agent.resolvedWorkingModel ?? "未同步")
                        .font(.body.weight(.medium))
                        .textSelection(.enabled)

                    let secondaryModelText = secondaryModelDescription
                    if let secondaryModelText {
                        Text(secondaryModelText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Agent 详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await snapshotStore.refresh()
        }
    }

    private var secondaryModelDescription: String? {
        let configuredModel = normalizedModel(agent.configuredModel)
        let currentModel = normalizedModel(agent.resolvedWorkingModel)
        let displayModel = normalizedModel(agent.currentDisplayModel)

        if let configuredModel, configuredModel != currentModel {
            return "配置模型：\(configuredModel)"
        }

        if let displayModel, displayModel != currentModel {
            return "展示模型：\(displayModel)"
        }

        return nil
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
