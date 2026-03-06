import SwiftUI
import CloudKit

struct AgentDetailView: View {
    let agent: AgentSnapshot
    @State private var selectedModel: String

    private static let defaultModels = [
        "anthropic/claude-sonnet-4-20250514",
        "anthropic/claude-opus-4-6",
        "openai-codex/gpt-5.3-codex"
    ]

    private let availableModels: [String]

    init(agent: AgentSnapshot, currentSession: SessionSnapshot? = nil) {
        self.agent = agent

        let saved = UserDefaults.standard.string(forKey: "modelOverride-\(agent.id)")

        // 归一化 agent 当前模型
        let normalized: String
        if let current = agent.currentModel, current != "default", !current.isEmpty {
            normalized = Self.normalizeModelId(current)
        } else if let saved, saved != "default", !saved.isEmpty {
            normalized = Self.normalizeModelId(saved)
        } else {
            normalized = Self.defaultModels[1] // opus 作为默认
        }

        // 确保列表里有当前模型
        if Self.defaultModels.contains(normalized) {
            self.availableModels = Self.defaultModels
        } else {
            self.availableModels = Self.defaultModels + [normalized]
        }

        _selectedModel = State(initialValue: normalized)
    }

    private static func normalizeModelId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.contains("opus") && !trimmed.hasPrefix("anthropic/") {
            return "anthropic/claude-opus-4-6"
        }
        if trimmed.contains("sonnet") && !trimmed.hasPrefix("anthropic/") {
            return "anthropic/claude-sonnet-4-20250514"
        }
        if trimmed.contains("codex") && !trimmed.hasPrefix("openai") {
            return "openai-codex/gpt-5.3-codex"
        }
        if defaultModels.contains(trimmed) {
            return trimmed
        }
        if let match = defaultModels.first(where: { $0.lowercased() == trimmed }) {
            return match
        }
        return raw
    }

    var body: some View {
        List {
            // Agent Info
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

            // Model Selection
            Section("AI 模型") {
                Picker("模型", selection: $selectedModel) {
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: selectedModel) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "modelOverride-\(agent.id)")
                    Task {
                        await sendModelChangeCommand(agentId: agent.id, model: newValue)
                    }
                }
            }

        }
        .navigationTitle("Agent 详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendModelChangeCommand(agentId: String, model: String) async {
        let container = CKContainer(identifier: CloudKitConstants.containerID)
        let database = container.privateCloudDatabase
        let recordID = CKRecord.ID(recordName: "ModelChange-\(agentId)", zoneID: CloudKitConstants.zoneID)
        let record = CKRecord(recordType: "ModelChange", recordID: recordID)
        record["agentId"] = agentId as CKRecordValue
        record["model"] = model as CKRecordValue
        record["timestamp"] = Date() as CKRecordValue
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            NSLog("[iOS] Sent model change command: agent=%@ model=%@", agentId, model)
        } catch {
            NSLog("[iOS] Failed to send model change: %@", error.localizedDescription)
        }
    }
}
