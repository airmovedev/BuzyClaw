import SwiftUI
import CloudKit

struct AgentDetailView: View {
    let agent: AgentSnapshot
    @State private var selectedModel: String

    private let availableModels: [String]

    init(agent: AgentSnapshot, currentSession: SessionSnapshot? = nil, availableModels: [String] = []) {
        self.agent = agent

        let savedOverride = UserDefaults.standard.string(forKey: "modelOverride-\(agent.id)")
        let configuredModels = Self.sanitizedModels(availableModels)
        let resolvedModel = Self.resolveSelectedModel(
            sessionModel: currentSession?.model,
            agentModel: agent.currentModel,
            savedOverride: savedOverride,
            configuredModels: configuredModels
        )

        self.availableModels = Self.buildAvailableModels(
            configuredModels: configuredModels,
            selectedModel: resolvedModel
        )
        _selectedModel = State(initialValue: resolvedModel)
    }

    private static func resolveSelectedModel(
        sessionModel: String?,
        agentModel: String?,
        savedOverride: String?,
        configuredModels: [String]
    ) -> String {
        let candidates = [sessionModel, agentModel, savedOverride]
            .compactMap { $0 }
            .map(normalizeModelId)
            .filter { !$0.isEmpty && $0 != "default" }

        if let first = candidates.first {
            return first
        }

        return configuredModels.first ?? "anthropic/claude-sonnet-4-20250514"
    }

    private static func buildAvailableModels(configuredModels: [String], selectedModel: String) -> [String] {
        var result = sanitizedModels(configuredModels)
        if !selectedModel.isEmpty && !result.contains(selectedModel) {
            result.append(selectedModel)
        }
        return result
    }

    private static func sanitizedModels(_ models: [String]) -> [String] {
        var result: [String] = []

        for model in models.map(normalizeModelId) where !model.isEmpty && model != "default" {
            if !result.contains(model) {
                result.append(model)
            }
        }

        return result
    }

    private static func normalizeModelId(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
