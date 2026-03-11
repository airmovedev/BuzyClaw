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

private enum SessionVisibility: String, CaseIterable, Identifiable {
    case tree
    case selfOnly = "self"
    case agent
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tree: return "tree（默认）"
        case .selfOnly: return "self"
        case .agent: return "agent"
        case .all: return "all"
        }
    }

    var description: String {
        switch self {
        case .tree: return "仅当前会话树：当前会话，以及它派生出来的子会话。"
        case .selfOnly: return "仅当前会话：只能看到正在使用的这个会话。"
        case .agent: return "同 Agent 全部会话：可看到当前 Agent 名下的所有会话。"
        case .all: return "所有会话：跨 Agent 查看整个实例里的全部会话。"
        }
    }
}

private struct SessionVisibilityOptionsList: View {
    let selected: SessionVisibility

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SessionVisibilityOptionRow(option: .tree, selected: selected == .tree)
            SessionVisibilityOptionRow(option: .selfOnly, selected: selected == .selfOnly)
            SessionVisibilityOptionRow(option: .agent, selected: selected == .agent)
            SessionVisibilityOptionRow(option: .all, selected: selected == .all)
        }
    }
}

private struct SessionVisibilityOptionRow: View {
    let option: SessionVisibility
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(selected ? "●" : "○")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                    .font(.caption.weight(.medium))
                Text(option.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsView: View {
    @Bindable var appState: AppState
    private let settingsTitle = "设置"
    @State private var apiKey = ""
    @State private var showResetAlert = false
    @State private var showProviderSheet = false
    @State private var detectedProviders: [String] = []
    @State private var currentToolsProfile: String = "full"
    @State private var currentSessionVisibility: SessionVisibility = .tree
    @State private var isRestartingGateway = false
    @State private var showRestartHint = false
    @AppStorage("launchAtLogin") private var launchAtLogin = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(settingsTitle)
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
                                GatewayStatusBadge(gatewayManager: appState.gatewayManager)
                                Spacer()
                                Button(isRestartingGateway ? "重启中..." : "重启") {
                                    Task {
                                        isRestartingGateway = true
                                        await appState.restartGateway()
                                        isRestartingGateway = false
                                    }
                                }
                                .disabled(isRestartingGateway)
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

                            Divider()
                                .padding(.vertical, 4)

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Session Visibility")
                                    Spacer()
                                    Picker("Session Visibility", selection: $currentSessionVisibility) {
                                        Text("tree").tag(SessionVisibility.tree)
                                        Text("self").tag(SessionVisibility.selfOnly)
                                        Text("agent").tag(SessionVisibility.agent)
                                        Text("all").tag(SessionVisibility.all)
                                    }
                                    .labelsHidden()
                                }

                                SessionVisibilityOptionsList(selected: currentSessionVisibility)
                                    .opacity(isRestartingGateway ? 0.7 : 1)
                            }
                            .disabled(isRestartingGateway)
                            .onChange(of: currentSessionVisibility) { _, newValue in
                                Task { await updateSessionVisibility(newValue) }
                            }

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
                .onAppear {
                    loadToolsProfile()
                    loadSessionVisibility()
                }

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
        .navigationTitle(settingsTitle)
        .onAppear {
            syncLaunchAtLoginStateIfNeeded()
        }
        .alert("确认重置", isPresented: $showResetAlert) {
            Button("取消", role: .cancel) { }
            Button("重置", role: .destructive) {
                appState.resetOnboarding()
            }
        } message: {
            Text("将清除所有配置并返回引导界面，确定继续？")
        }
    }

    private func syncLaunchAtLoginStateIfNeeded() {
        if UserDefaults.standard.object(forKey: "launchAtLogin") != nil {
            return
        }

        let serviceStatus = SMAppService.mainApp.status
        if serviceStatus == .enabled {
            launchAtLogin = true
            return
        }

        do {
            try SMAppService.mainApp.register()
            launchAtLogin = true
        } catch {
            launchAtLogin = false
        }
    }

    private func detectAuthProfiles() {
        guard let json = loadOpenClawConfig(),
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

        let configJson = loadOpenClawConfig()

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

        // 从 agents.defaults.models 读取用户配置的所有模型
        if let json = configJson,
           let agents = json["agents"] as? [String: Any],
           let defaults = agents["defaults"] as? [String: Any],
           let configuredModels = defaults["models"] as? [String: Any] {
            for modelKey in configuredModels.keys {
                if !modelIds.contains(modelKey) {
                    modelIds.insert(modelKey)
                    models.append(DetectedModel(fullId: modelKey))
                }
            }
        }

        // 也读取 primary model
        if let json = configJson,
           let agents = json["agents"] as? [String: Any],
           let defaults = agents["defaults"] as? [String: Any],
           let model = defaults["model"] as? [String: Any],
           let primary = model["primary"] as? String {
            if !modelIds.contains(primary) {
                modelIds.insert(primary)
                models.append(DetectedModel(fullId: primary))
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
        guard let json = loadOpenClawConfig(),
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

    private func loadSessionVisibility() {
        guard let json = loadOpenClawConfig(),
              let tools = json["tools"] as? [String: Any],
              let sessions = tools["sessions"] as? [String: Any],
              let rawValue = sessions["visibility"] as? String,
              let visibility = SessionVisibility(rawValue: rawValue) else {
            currentSessionVisibility = .tree
            return
        }
        currentSessionVisibility = visibility
    }

    private func saveSessionVisibility(_ visibility: SessionVisibility) {
        let configPath = appState.openclawBasePath.appendingPathComponent("openclaw.json")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        }

        var tools = root["tools"] as? [String: Any] ?? [:]
        var sessions = tools["sessions"] as? [String: Any] ?? [:]
        sessions["visibility"] = visibility.rawValue
        tools["sessions"] = sessions
        root["tools"] = tools

        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configPath, options: .atomic)
        }
    }

    private func updateSessionVisibility(_ visibility: SessionVisibility) async {
        saveSessionVisibility(visibility)
        isRestartingGateway = true
        await appState.restartGateway()
        isRestartingGateway = false
    }

    private func loadOpenClawConfig() -> [String: Any]? {
        let candidates = [
            appState.openclawBasePath.appendingPathComponent("openclaw.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw/openclaw.json")
        ]

        for path in candidates {
            guard let data = try? Data(contentsOf: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            return json
        }

        return nil
    }
}
