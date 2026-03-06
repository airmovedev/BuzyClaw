import SwiftUI
import ServiceManagement

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

                // Gateway Status
                GroupBox("Gateway 状态") {
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
                }

                // AI Account
                GroupBox("AI 服务") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !detectedProviders.isEmpty {
                            ForEach(detectedProviders, id: \.self) { provider in
                                HStack {
                                    Label(providerDisplayName(provider), systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Spacer()
                                }
                            }
                            Button("更换") { showProviderSheet = true }
                        } else {
                            Text("未配置 AI 服务")
                                .foregroundStyle(.secondary)
                            Button("配置") { showProviderSheet = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(8)
                }
                .onAppear { detectAuthProfiles() }
                .sheet(isPresented: $showProviderSheet) {
                    AIProviderSettingsView(appState: appState, isPresented: $showProviderSheet)
                        .frame(minWidth: 500, minHeight: 450)
                        .onDisappear { detectAuthProfiles() }
                }

                // Tools Profile
                GroupBox("工具权限 (Tools Profile)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("工具权限级别", selection: $currentToolsProfile) {
                            Text("🔒 精简 Minimal").tag("minimal")
                            Text("💬 消息 Messaging").tag("messaging")
                            Text("💻 编程 Coding").tag("coding")
                            Text("🔓 完整 Full").tag("full")
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
                }
                .onAppear { loadToolsProfile() }

                // Heartbeat
                HeartbeatSettingsView(appState: appState)

                // Launch at Login
                GroupBox("通用") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("开机自启动", isOn: $launchAtLogin)
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
                        Text("登录时自动启动 ClawTower，保持 Gateway 常驻运行")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                // About
                GroupBox("关于") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ClawTower v1.0.0")
                        Text("基于 OpenClaw 开源项目")
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
                // 重置
                GroupBox("重置") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("重新进入引导设置，将清除当前配置。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("重置引导配置", role: .destructive) {
                            showResetAlert = true
                        }
                    }
                    .padding(8)
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
        // Extract unique provider names from profile keys like "anthropic:default"
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

    private func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "anthropic": return "Anthropic (Claude)"
        case "openai": return "OpenAI (ChatGPT)"
        default: return provider
        }
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
