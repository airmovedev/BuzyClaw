import SwiftUI
import ServiceManagement

struct DetectedModel: Identifiable {
    let id = UUID()
    let fullId: String      // e.g. "anthropic/claude-sonnet-4-20250514"
    let displayName: String // e.g. "Claude Sonnet 4"
    let provider: String    // e.g. "anthropic"
    let isClaude: Bool      // provider contains "anthropic"
    let tint: Color         // based on provider
    let icon: String        // SF Symbol name

    init(fullId: String) {
        self.fullId = fullId
        let parts = fullId.split(separator: "/", maxSplits: 1)
        self.provider = parts.count >= 2 ? String(parts[0]) : "unknown"
        let modelSlug = parts.count >= 2 ? String(parts[1]) : fullId
        self.isClaude = provider.contains("anthropic")
        self.displayName = Self.humanName(for: modelSlug, provider: provider)

        switch provider {
        case "anthropic":
            self.tint = .purple; self.icon = "brain.head.profile"
        case "openai", "openai-codex":
            self.tint = .green; self.icon = "bubble.left.and.bubble.right"
        case "minimax", "minimax-portal":
            self.tint = .orange; self.icon = "sparkles"
        case "moonshot":
            self.tint = .blue; self.icon = "moon.stars"
        case "zai":
            self.tint = .cyan; self.icon = "text.word.spacing"
        case "qwen":
            self.tint = .indigo; self.icon = "cloud"
        case "google":
            self.tint = .red; self.icon = "globe"
        case "xai":
            self.tint = .gray; self.icon = "bolt"
        case "openrouter":
            self.tint = .mint; self.icon = "arrow.triangle.branch"
        default:
            self.tint = .secondary; self.icon = "cpu"
        }
    }

    private static func humanName(for slug: String, provider: String) -> String {
        var name = slug
            .replacingOccurrences(of: "-20\\d{6}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "-", with: " ")
        name = name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return name
    }
}

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var apiKey = ""
    @State private var showResetAlert = false
    @State private var showProviderSheet = false
    @State private var detectedProviders: [String] = []
    @State private var currentToolsProfile: String = "full"
    @State private var showRestartHint = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("设置")
                    .font(.largeTitle.bold())

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Gateway 状态")
                            .font(.headline)
                        Spacer()
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 10, height: 10)
                                Text(appState.gatewayManager.statusText)
                                Spacer()
                                Button("重启") {
                                    Task { await appState.restartGateway() }
                                }
                            }

                            if appState.gatewayManager.isRunning {
                                HStack(spacing: 16) {
                                    Label("端口: \(appState.gatewayManager.port)", systemImage: "network")
                                    if let pid = appState.gatewayManager.pid {
                                        Label("PID: \(pid)", systemImage: "gearshape")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("AI 模型")
                            .font(.headline)
                        Spacer()
                        Button {
                            showProviderSheet = true
                        } label: {
                            Label("新增", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("配置 AI 服务")
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            if detectedModels.isEmpty {
                                Text("未配置 AI 服务")
                                    .foregroundStyle(.secondary)
                                Button("配置 AI 服务") { showProviderSheet = true }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(Array(detectedModels.enumerated()), id: \.element.fullId) { index, model in
                                        ModelUsageRow(model: model, client: appState.gatewayClient)
                                        if index < detectedModels.count - 1 {
                                            Divider()
                                        }
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onAppear { detectAuthProfiles() }
                .sheet(isPresented: $showProviderSheet) {
                    AIProviderSettingsView(appState: appState, isPresented: $showProviderSheet)
                        .frame(minWidth: 500, minHeight: 450)
                        .onDisappear { detectAuthProfiles() }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("工具权限")
                            .font(.headline)
                        Spacer()
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("权限级别")
                                Spacer()
                                Picker("工具权限级别", selection: $currentToolsProfile) {
                                    Text("精简").tag("minimal")
                                    Text("消息").tag("messaging")
                                    Text("编程").tag("coding")
                                    Text("完整").tag("full")
                                }
                                .labelsHidden()
                            }
                            .onChange(of: currentToolsProfile) { _, newValue in
                                saveToolsProfile(newValue)
                                showRestartHint = true
                            }

                            Text(toolsProfileDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if showRestartHint {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text("需要重启 Gateway 才能生效")
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    Button("重启") {
                                        Task {
                                            await appState.restartGateway()
                                            showRestartHint = false
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .font(.caption)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onAppear { loadToolsProfile() }

                HeartbeatSettingsView(appState: appState)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("开机自启动")
                            .font(.headline)
                        Spacer()
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("开机自启动")
                                Spacer()
                                Toggle("", isOn: $launchAtLogin)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .scaleEffect(0.7)
                                    .frame(width: 36, height: 20)
                                    .onChange(of: launchAtLogin) { _, newValue in
                                        do {
                                            if newValue {
                                                try SMAppService.mainApp.register()
                                            } else {
                                                try SMAppService.mainApp.unregister()
                                            }
                                        } catch {
                                            launchAtLogin = !newValue
                                        }
                                    }
                            }

                            Text("登录时自动启动 ClawTower，保持 Gateway 常驻运行")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("重置引导")
                            .font(.headline)
                        Spacer()
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("重新进入引导设置，将清除当前配置。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Spacer()
                                Button("重置引导配置", role: .destructive) {
                                    showResetAlert = true
                                }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(.windowBackgroundColor))
        .alert("确认重置", isPresented: $showResetAlert) {
            Button("取消", role: .cancel) { }
            Button("重置", role: .destructive) {
                appState.resetOnboarding()
            }
        } message: {
            Text("将清除所有配置并返回引导界面，确定继续？")
        }
    }

    private func detectAuthProfiles() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appendingPathComponent(".openclaw/openclaw.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["auth"] as? [String: Any],
              let profiles = auth["profiles"] as? [String: Any],
              !profiles.isEmpty else {
            detectedProviders = []
            return
        }
        var providers: [String] = []
        for (key, value) in profiles {
            if let dict = value as? [String: Any], let provider = dict["provider"] as? String {
                if !providers.contains(provider) { providers.append(provider) }
            } else {
                let provider = key.components(separatedBy: ":").first ?? key
                if !providers.contains(provider) { providers.append(provider) }
            }
        }
        detectedProviders = providers
    }

    private var detectedModels: [DetectedModel] {
        var modelIds = Set<String>()
        var models: [DetectedModel] = []
        var providersWithModels = Set<String>()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appendingPathComponent(".openclaw/openclaw.json").path
        let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath))
        let configJson = configData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

        if let json = configJson,
           let modelsConfig = json["models"] as? [String: Any],
           let providers = modelsConfig["providers"] {

            if let providerArray = providers as? [[String: Any]] {
                for provider in providerArray {
                    if let providerModels = provider["models"] as? [String] {
                        for m in providerModels where !modelIds.contains(m) {
                            modelIds.insert(m)
                            models.append(DetectedModel(fullId: m))
                            let p = m.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
                            if !p.isEmpty { providersWithModels.insert(p) }
                        }
                    }
                    if let singleModel = provider["model"] as? String, !modelIds.contains(singleModel) {
                        modelIds.insert(singleModel)
                        models.append(DetectedModel(fullId: singleModel))
                        let p = singleModel.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
                        if !p.isEmpty { providersWithModels.insert(p) }
                    }
                }
            }

            if let providerDict = providers as? [String: Any] {
                for (providerKey, providerValue) in providerDict {
                    guard let providerInfo = providerValue as? [String: Any] else { continue }
                    if let modelArray = providerInfo["models"] as? [[String: Any]] {
                        for modelObj in modelArray {
                            guard let modelId = modelObj["id"] as? String else { continue }
                            let fullId = "\(providerKey)/\(modelId)"
                            if !modelIds.contains(fullId) {
                                modelIds.insert(fullId)
                                models.append(DetectedModel(fullId: fullId))
                                providersWithModels.insert(providerKey)
                            }
                        }
                    }
                    if let modelStrings = providerInfo["models"] as? [String] {
                        for modelId in modelStrings {
                            let fullId = modelId.contains("/") ? modelId : "\(providerKey)/\(modelId)"
                            if !modelIds.contains(fullId) {
                                modelIds.insert(fullId)
                                models.append(DetectedModel(fullId: fullId))
                                providersWithModels.insert(providerKey)
                            }
                        }
                    }
                }
            }
        }

        if let json = configJson,
           let auth = json["auth"] as? [String: Any],
           let profiles = auth["profiles"] as? [String: Any] {
            for profileKey in profiles.keys {
                let provider = profileKey.components(separatedBy: ":").first ?? profileKey
                guard !providersWithModels.contains(provider) else { continue }

                switch provider {
                case "anthropic":
                    let m = "anthropic/claude-opus-4-6"
                    if !modelIds.contains(m) {
                        modelIds.insert(m)
                        models.append(DetectedModel(fullId: m))
                        providersWithModels.insert(provider)
                    }
                case "openai-codex":
                    let m = "openai-codex/gpt-5.3-codex"
                    if !modelIds.contains(m) {
                        modelIds.insert(m)
                        models.append(DetectedModel(fullId: m))
                        providersWithModels.insert(provider)
                    }
                default:
                    break
                }
            }
        }

        return models
    }

    private var toolsProfileDescription: String {
        switch currentToolsProfile {
        case "minimal": return "最精简，基本只有对话能力"
        case "messaging": return "消息、搜索、记忆等安全工具，无 coding/system 权限"
        case "coding": return "面向编程场景（读写文件、执行命令等）"
        case "full": return "全部工具开放（文件、终端、浏览器、消息等）"
        default: return ""
        }
    }

    private func loadToolsProfile() {
        let configPath = appState.openclawBasePath.appendingPathComponent("openclaw.json")
        guard let data = try? Data(contentsOf: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tools = json["tools"] as? [String: Any],
              let profile = tools["profile"] as? String else { return }
        currentToolsProfile = profile
    }

    private func saveToolsProfile(_ profile: String) {
        let configPath = appState.openclawBasePath.appendingPathComponent("openclaw.json")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        }
        var tools = root["tools"] as? [String: Any] ?? [:]
        tools["profile"] = profile
        root["tools"] = tools
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configPath, options: .atomic)
        }
    }

    private var statusColor: Color {
        switch appState.gatewayManager.state {
        case .running: return .green
        case .starting: return .orange
        case .stopped: return .gray
        case .error: return .red
        }
    }
}
