import SwiftUI

struct MemoryFlushSettingsView: View {
    @Bindable var appState: AppState

    @State private var isEnabled = true
    @State private var hasLoaded = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("记忆刷新")
                    .font(.headline)
                Spacer()
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Memory Flush（内存刷新）")
                        Spacer()
                        Toggle("", isOn: $isEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .scaleEffect(0.7)
                            .frame(width: 36, height: 20)
                    }

                    Text("开启后，agent 会定期将短期记忆整合到长期记忆，释放上下文空间，让 agent 能处理更长的对话。关闭则保留完整上下文，适合需要精确回溯的场景。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { load() }
        .onChange(of: isEnabled) { _, _ in scheduleSaveIfLoaded() }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
        }
    }

    private var configURL: URL {
        appState.openclawBasePath.appendingPathComponent("openclaw.json")
    }

    private func readConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func load() {
        hasLoaded = false
        defer { hasLoaded = true }

        guard let json = readConfig(),
              let agents = json["agents"] as? [String: Any],
              let defaults = agents["defaults"] as? [String: Any],
              let compaction = defaults["compaction"] as? [String: Any],
              let memoryFlush = compaction["memoryFlush"] as? [String: Any] else {
            isEnabled = true
            return
        }

        isEnabled = memoryFlush["enabled"] as? Bool ?? true
    }

    private func scheduleSaveIfLoaded() {
        guard hasLoaded else { return }

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
        guard var json = readConfig() else { return }

        var agents = json["agents"] as? [String: Any] ?? [:]
        var defaults = agents["defaults"] as? [String: Any] ?? [:]
        var compaction = defaults["compaction"] as? [String: Any] ?? [:]
        var memoryFlush = compaction["memoryFlush"] as? [String: Any] ?? [:]

        memoryFlush["enabled"] = isEnabled
        compaction["memoryFlush"] = memoryFlush
        defaults["compaction"] = compaction
        agents["defaults"] = defaults
        json["agents"] = agents

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL, options: .atomic)
        }
    }
}
