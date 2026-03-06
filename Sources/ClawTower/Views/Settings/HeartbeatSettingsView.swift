import SwiftUI

struct HeartbeatSettingsView: View {
    @Bindable var appState: AppState

    private static let intervalOptions = ["30m", "1h", "2h", "4h"]
    private static let modelOptions = [
        "anthropic/claude-opus-4-6",
        "anthropic/claude-sonnet-4-20250514",
    ]
    /// Sentinel value meaning "inherit default"
    private static let inheritSentinel = "__inherit__"

    @State private var globalEnabled = false
    @State private var defaultInterval = "1h"
    @State private var defaultModel = "anthropic/claude-opus-4-6"
    @State private var agents: [AgentHeartbeatConfig] = []
    @State private var hasLoaded = false
    @State private var showSavedHint = false

    struct AgentHeartbeatConfig: Identifiable {
        let id: String
        let displayName: String
        /// Empty string = inherit default
        var interval: String
        var model: String
    }

    var body: some View {
        GroupBox("心跳设置") {
            VStack(alignment: .leading, spacing: 12) {
                // Global toggle
                Toggle("启用全局心跳", isOn: $globalEnabled)
                    .fontWeight(.medium)

                if globalEnabled {
                    // Global defaults
                    HStack {
                        Text("默认").fontWeight(.medium)
                        Spacer()
                        Picker("间隔", selection: $defaultInterval) {
                            ForEach(Self.intervalOptions, id: \.self) { Text($0) }
                        }
                        .frame(width: 90)
                        Picker("模型", selection: $defaultModel) {
                            ForEach(Self.modelOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(width: 280)
                    }

                    if !agents.isEmpty {
                        Divider()
                        Text("Per-Agent 覆盖").font(.caption).foregroundStyle(.secondary)
                        ForEach($agents) { $agent in
                            HStack {
                                Text(agent.displayName)
                                Spacer()
                                Picker("间隔", selection: $agent.interval) {
                                    Text("继承默认").tag("")
                                    ForEach(Self.intervalOptions, id: \.self) { Text($0).tag($0) }
                                }
                                .frame(width: 110)
                                Picker("模型", selection: $agent.model) {
                                    Text("继承默认").tag("")
                                    ForEach(Self.modelOptions, id: \.self) { Text($0).tag($0) }
                                }
                                .frame(width: 280)
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    if showSavedHint {
                        Text("✅ 已保存，下次重启 Gateway 后生效")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    Button("保存心跳设置") { save() }
                        .buttonStyle(.borderedProminent)
                }
                .animation(.easeInOut, value: showSavedHint)
            }
            .padding(8)
        }
        .onAppear { if !hasLoaded { load(); hasLoaded = true } }
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
        guard let json = readConfig(),
              let agentsObj = json["agents"] as? [String: Any] else { return }

        // Defaults
        if let defaults = agentsObj["defaults"] as? [String: Any],
           let hb = defaults["heartbeat"] as? [String: Any] {
            globalEnabled = true
            if let every = hb["every"] as? String { defaultInterval = every }
            if let model = hb["model"] as? String { defaultModel = model }
        } else {
            globalEnabled = false
        }

        // Agent list
        if let list = agentsObj["list"] as? [[String: Any]] {
            agents = list.map { a in
                let id = a["id"] as? String ?? "unknown"
                let identity = a["identity"] as? [String: Any]
                let name = identity?["name"] as? String ?? id
                let hb = a["heartbeat"] as? [String: Any]
                let agentEvery = hb?["every"] as? String ?? ""
                let agentModel = hb?["model"] as? String ?? ""
                return AgentHeartbeatConfig(
                    id: id,
                    displayName: name,
                    interval: agentEvery,
                    model: agentModel
                )
            }
        }
    }

    private func save() {
        guard var json = readConfig(),
              var agentsObj = json["agents"] as? [String: Any] else { return }

        // Update defaults
        var defaults = agentsObj["defaults"] as? [String: Any] ?? [:]
        if globalEnabled {
            defaults["heartbeat"] = ["every": defaultInterval, "model": defaultModel]
        } else {
            defaults.removeValue(forKey: "heartbeat")
        }
        agentsObj["defaults"] = defaults

        // Update each agent's heartbeat
        if var list = agentsObj["list"] as? [[String: Any]] {
            for i in list.indices {
                let agentId = list[i]["id"] as? String ?? ""
                if let config = agents.first(where: { $0.id == agentId }) {
                    var hb: [String: Any] = [:]
                    if !config.interval.isEmpty { hb["every"] = config.interval }
                    if !config.model.isEmpty { hb["model"] = config.model }
                    if hb.isEmpty {
                        list[i].removeValue(forKey: "heartbeat")
                    } else {
                        list[i]["heartbeat"] = hb
                    }
                }
            }
            agentsObj["list"] = list
        }

        json["agents"] = agentsObj

        // Write back
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL)
        }

        showSavedHint = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { showSavedHint = false }
        }
    }
}
