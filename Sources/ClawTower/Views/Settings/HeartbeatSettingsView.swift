import SwiftUI

struct HeartbeatSettingsView: View {
    @Bindable var appState: AppState

    private static let intervalOptions = ["30m", "1h", "2h", "4h"]
    private static let fallbackEnabledDefault = true

    @State private var globalEnabled = false
    @State private var defaultInterval = "1h"
    @State private var defaultModel = ""
    @State private var hasLoaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var modelOptions: [ModelOption] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("心跳设置")
                    .font(.headline)
                Spacer()
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("全局心跳")
                        Spacer()
                        Toggle("", isOn: $globalEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .scaleEffect(0.7)
                            .frame(width: 36, height: 20)
                    }

                    Text("全局心跳将会定期消耗 Token，建议选择轻量级模型，并扩大心跳间隔时间，减少消耗。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if globalEnabled {
                        HStack {
                            Spacer()
                            HStack(spacing: 12) {
                                Picker("模型", selection: $defaultModel) {
                                    ForEach(modelOptions) { option in
                                        Text(option.label).tag(option.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(minWidth: 260)

                                Picker("间隔", selection: $defaultInterval) {
                                    ForEach(Self.intervalOptions, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 120)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { load() }
        .onChange(of: globalEnabled) { _, _ in scheduleSaveIfLoaded() }
        .onChange(of: defaultInterval) { _, _ in scheduleSaveIfLoaded() }
        .onChange(of: defaultModel) { _, _ in scheduleSaveIfLoaded() }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
        }
    }

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/openclaw.json")
    }

    private func readConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    private func load() {
        hasLoaded = false
        defer { hasLoaded = true }

        guard let json = readConfig() else {
            globalEnabled = Self.fallbackEnabledDefault
            buildModelOptions(from: nil)
            applyDefaultModelIfNeeded()
            return
        }

        var heartbeatModelFromConfig: String?
        var heartbeatEveryFromConfig: String?

        if let agentsObj = json["agents"] as? [String: Any] {
            // Priority: agent-specific config (agents.list[main]) overrides global default
            var effectiveHeartbeat: [String: Any]?

            // First check for main agent's specific config
            if let list = agentsObj["list"] as? [[String: Any]] {
                for agent in list {
                    if agent["id"] as? String == "main",
                       let hb = agent["heartbeat"] as? [String: Any] {
                        effectiveHeartbeat = hb
                        break
                    }
                }
            }

            // Fall back to global defaults if no agent-specific config
            if effectiveHeartbeat == nil {
                effectiveHeartbeat = (agentsObj["defaults"] as? [String: Any])?["heartbeat"] as? [String: Any]
            }

            if let hb = effectiveHeartbeat {
                globalEnabled = true
                if let every = hb["every"] as? String {
                    defaultInterval = every
                    heartbeatEveryFromConfig = every
                }
                if let model = hb["model"] as? String {
                    defaultModel = model
                    heartbeatModelFromConfig = model
                }
            } else {
                globalEnabled = Self.fallbackEnabledDefault
            }

            if defaultModel.isEmpty, let fallback = heartbeatModelFromConfig {
                defaultModel = fallback
            }

            // Build model options AFTER defaultModel is set, so it can be included in the list
            buildModelOptions(from: agentsObj["defaults"] as? [String: Any])
            applyDefaultModelIfNeeded()
            return
        }

        globalEnabled = Self.fallbackEnabledDefault
        buildModelOptions(from: nil)
        applyDefaultModelIfNeeded()
    }

    private func buildModelOptions(from defaults: [String: Any]?) {
        // Build alias lookup from defaults.models
        var aliasMap: [String: String] = [:]
        if let models = defaults?["models"] as? [String: Any] {
            for (modelId, value) in models {
                if let alias = (value as? [String: Any])?["alias"] as? String,
                   !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    aliasMap[modelId] = alias
                }
            }
        }

        // Build complete model list from config (same logic as AgentDraft.modelOptions)
        var allModelIds: [String] = []

        // 1. primary + fallbacks
        if let modelConfig = defaults?["model"] as? [String: Any] {
            if let primary = modelConfig["primary"] as? String {
                allModelIds.append(primary)
            }
            if let fallbacks = modelConfig["fallbacks"] as? [String] {
                for fb in fallbacks where !allModelIds.contains(fb) {
                    allModelIds.append(fb)
                }
            }
        }

        // 2. defaults.models keys
        if let models = defaults?["models"] as? [String: Any] {
            for key in models.keys where !allModelIds.contains(key) {
                allModelIds.append(key)
            }
        }

        // 3. models.providers
        if let json = readConfig(),
           let modelsObj = json["models"] as? [String: Any],
           let providers = modelsObj["providers"] as? [String: Any] {
            for (providerId, providerValue) in providers {
                if let providerDict = providerValue as? [String: Any],
                   let modelsList = providerDict["models"] as? [[String: Any]] {
                    for entry in modelsList {
                        if let modelId = entry["id"] as? String {
                            let fullId = "\(providerId)/\(modelId)"
                            if !allModelIds.contains(fullId) {
                                allModelIds.append(fullId)
                            }
                        }
                    }
                }
            }
        }

        // 4. Also scan agents.list for any model not yet included (e.g. heartbeat models)
        if let json = readConfig(),
           let agentsObj = json["agents"] as? [String: Any],
           let list = agentsObj["list"] as? [[String: Any]] {
            for agent in list {
                if let m = agent["model"] as? String, !allModelIds.contains(m) {
                    allModelIds.append(m)
                }
                if let hb = agent["heartbeat"] as? [String: Any],
                   let hbModel = hb["model"] as? String, !allModelIds.contains(hbModel) {
                    allModelIds.append(hbModel)
                }
            }
        }

        var options = allModelIds.map { modelId in
            ModelOption(id: modelId, label: buildLabel(alias: aliasMap[modelId], modelId: modelId))
        }

        // If the currently selected model still isn't in the list, add it
        if !defaultModel.isEmpty,
           !options.contains(where: { $0.id == defaultModel }) {
            options.insert(ModelOption(id: defaultModel, label: buildLabel(alias: nil, modelId: defaultModel)), at: 0)
        }

        modelOptions = options
    }

    private func buildLabel(alias: String?, modelId: String) -> String {
        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedAlias.isEmpty {
            return "\(trimmedAlias) (\(modelId))"
        }
        return modelId
    }

    private func applyDefaultModelIfNeeded() {
        if defaultModel.isEmpty, let first = modelOptions.first?.id {
            defaultModel = first
        }
    }

    private func scheduleSaveIfLoaded() {
        guard hasLoaded else { return }

        if globalEnabled, defaultModel.isEmpty, let first = modelOptions.first?.id {
            defaultModel = first
            return
        }

        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                save()
            }
        }
    }

    private func save() {
        guard var json = readConfig(),
              var agentsObj = json["agents"] as? [String: Any] else { return }

        let newHeartbeat: [String: Any]? = globalEnabled
            ? ["every": defaultInterval, "model": defaultModel]
            : nil

        // Priority: save to agent-specific config (main agent) if it exists,
        // otherwise fall back to global defaults
        if var list = agentsObj["list"] as? [[String: Any]] {
            var found = false
            for i in 0..<list.count {
                if list[i]["id"] as? String == "main" {
                    if let hb = newHeartbeat {
                        list[i]["heartbeat"] = hb
                    } else {
                        list[i].removeValue(forKey: "heartbeat")
                    }
                    found = true
                    break
                }
            }
            if found {
                agentsObj["list"] = list
            } else {
                // No main agent entry, save to global defaults
                var defaults = agentsObj["defaults"] as? [String: Any] ?? [:]
                if let hb = newHeartbeat {
                    defaults["heartbeat"] = hb
                } else {
                    defaults.removeValue(forKey: "heartbeat")
                }
                agentsObj["defaults"] = defaults
            }
        } else {
            // No list, save to global defaults
            var defaults = agentsObj["defaults"] as? [String: Any] ?? [:]
            if let hb = newHeartbeat {
                defaults["heartbeat"] = hb
            } else {
                defaults.removeValue(forKey: "heartbeat")
            }
            agentsObj["defaults"] = defaults
        }

        json["agents"] = agentsObj

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL, options: .atomic)
        }
    }
}

private struct ModelOption: Identifiable {
    let id: String
    let label: String
}
