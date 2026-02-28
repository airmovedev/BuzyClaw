import SwiftUI

struct OnboardingView: View {
    let appState: AppState
    @State private var currentStep = 0
    @State private var agentName = "Assistant"
    @State private var agentEmoji = "🤖"
    @State private var userName = ""

    @State private var authService = AuthService()
    @State private var selectedProvider: AuthService.Provider?
    @State private var apiKeyInput = ""
    @State private var setupTokenInput = ""
    @State private var claudeAuthMethod = 0 // 0 = API Key, 1 = Setup Token

    // Detection step state
    @State private var existingInstallDetected = false
    @State private var isDetecting = true
    @State private var detectedAgentCount = 0

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            HStack(spacing: 4) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)

            Spacer()

            // Step content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: detectionStep
                case 2: providerStep
                case 3: personalizeStep
                case 4: readyStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: 500)

            Spacer()

            // Navigation
            HStack {
                if currentStep > 0 && currentStep != 1 {
                    Button("上一步") {
                        if currentStep == 2 {
                            authService.reset()
                            selectedProvider = nil
                            apiKeyInput = ""
                        }
                        currentStep -= 1
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if currentStep == 1 {
                    // Detection step has its own navigation
                    EmptyView()
                } else if currentStep < totalSteps - 1 {
                    Button("下一步") { currentStep += 1 }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canAdvance)
                } else {
                    Button("开始使用") {
                        appState.completeOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(30)
        }
        .frame(minWidth: 600, minHeight: 500)
    }

    private var canAdvance: Bool {
        switch currentStep {
        case 1: return !isDetecting // Detection step
        case 2: return authService.isAuthenticated
        default: return true
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Text("🏗️")
                .font(.system(size: 64))
            Text("欢迎使用 ClawTower")
                .font(.largeTitle.bold())
            Text("你的私人 AI 助手，运行在你的 Mac 上")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Label("AI 助手完全本地运行", systemImage: "desktopcomputer")
                Label("数据只属于你，不上传云端", systemImage: "lock.shield")
                Label("iPhone 远程访问，随时随地", systemImage: "iphone")
            }
            .font(.body)
            .padding(.top, 10)
        }
    }

    // MARK: - Step 1: Detection

    private var detectionStep: some View {
        VStack(spacing: 20) {
            if isDetecting {
                ProgressView()
                    .scaleEffect(1.5)
                Text("正在检测已有安装...")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else if existingInstallDetected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("发现已有 OpenClaw 安装")
                    .font(.title2.bold())
                Text("在 ~/.openclaw/ 中找到了已有的配置")
                    .foregroundStyle(.secondary)

                if detectedAgentCount > 0 {
                    Text("包含 \(detectedAgentCount) 个 Agent")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    Button {
                        appState.gatewayMode = .existingInstall
                        // Skip provider step, go to personalize
                        currentStep = 3
                    } label: {
                        HStack {
                            Image(systemName: "arrow.right.circle.fill")
                            Text("使用已有配置")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        appState.gatewayMode = .freshInstall
                        currentStep = 2
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text("全新开始")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .frame(maxWidth: 300)
                .padding(.top, 10)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                Text("全新安装")
                    .font(.title2.bold())
                Text("将为你配置全新的 AI 助手环境")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await detectExistingInstall()
        }
    }

    private func detectExistingInstall() async {
        isDetecting = true

        // Brief delay for UX
        try? await Task.sleep(for: .seconds(1))

        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appendingPathComponent(".openclaw/openclaw.json").path

        if FileManager.default.fileExists(atPath: configPath) {
            existingInstallDetected = true

            // Count agents
            let agentsDir = home.appendingPathComponent(".openclaw/agents")
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: agentsDir.path) {
                detectedAgentCount = contents.filter { !$0.hasPrefix(".") }.count
            }
        } else {
            existingInstallDetected = false
            appState.gatewayMode = .freshInstall
            // Auto-advance after brief pause
            try? await Task.sleep(for: .seconds(1))
            currentStep = 2
        }

        isDetecting = false
    }

    // MARK: - Step 2: Provider + Auth

    private var providerStep: some View {
        VStack(spacing: 20) {
            Text("连接你的 AI 大脑")
                .font(.title2.bold())
            Text("选择一个 AI 服务来连接")
                .foregroundStyle(.secondary)

            // Provider cards
            HStack(spacing: 16) {
                providerCard(
                    provider: .anthropic,
                    name: "Claude",
                    subtitle: "Anthropic",
                    description: "最擅长写作和分析",
                    icon: "brain.head.profile",
                    tint: .purple
                )
                providerCard(
                    provider: .openai,
                    name: "ChatGPT",
                    subtitle: "OpenAI",
                    description: "最擅长代码和推理",
                    icon: "bubble.left.and.bubble.right",
                    tint: .green
                )
            }

            // Expanded section for selected provider
            if let provider = selectedProvider {
                if provider == .anthropic {
                    anthropicAuthSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    oauthSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedProvider)
    }

    private func providerCard(
        provider: AuthService.Provider,
        name: String,
        subtitle: String,
        description: String,
        icon: String,
        tint: Color
    ) -> some View {
        let isSelected = selectedProvider == provider

        return Button {
            guard !authService.isAuthenticated else { return }
            authService.reset()
            apiKeyInput = ""
            selectedProvider = provider
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundStyle(tint)
                Text(name)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? tint.opacity(0.1) : Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? tint : Color.clear, lineWidth: 2)
            )
            .overlay(alignment: .topTrailing) {
                if authService.isAuthenticated && isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(authService.isAuthenticated)
    }

    // MARK: - Anthropic Auth Section (API Key / Setup Token)

    private var anthropicAuthSection: some View {
        VStack(spacing: 16) {
            Picker("认证方式", selection: $claudeAuthMethod) {
                Text("API Key").tag(0)
                Text("Setup Token").tag(1)
            }
            .pickerStyle(.segmented)
            .disabled(authService.isAuthenticated)
            .onChange(of: claudeAuthMethod) {
                if !authService.isAuthenticated {
                    authService.reset()
                }
            }

            if claudeAuthMethod == 0 {
                keyInputSection(provider: .anthropic)
            } else {
                setupTokenSection
            }
        }
    }

    // MARK: - Setup Token Section

    private var setupTokenSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("如果你已安装 Claude CLI，可以通过 Setup Token 连接：")
                .font(.headline)

            HStack(alignment: .top, spacing: 10) {
                stepBadge(number: 1, tint: .purple)
                Text("打开终端 (Terminal)")
                    .font(.callout)
            }

            HStack(alignment: .top, spacing: 10) {
                stepBadge(number: 2, tint: .purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text("输入命令：")
                        .font(.callout)
                    Text("claude setup-token")
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .textSelection(.enabled)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                stepBadge(number: 3, tint: .purple)
                Text("按照提示完成授权后，复制获得的 Token")
                    .font(.callout)
            }

            HStack(alignment: .top, spacing: 10) {
                stepBadge(number: 4, tint: .purple)
                Text("将 Token 粘贴到下方")
                    .font(.callout)
            }

            // Token input
            HStack(spacing: 10) {
                TextField("粘贴你的 Setup Token", text: $setupTokenInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(authService.isAuthenticated)

                Button {
                    authService.verifyAnthropicSetupToken(token: setupTokenInput.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    switch authService.state {
                    case .verifying:
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 60)
                    case .verified:
                        Label("已验证", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    default:
                        Text("验证")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(authService.isAuthenticated ? .green : .purple)
                .disabled(setupTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authService.state == .verifying || authService.isAuthenticated)
            }

            // Status messages
            switch authService.state {
            case .verified:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Setup Token 验证成功！点击「下一步」继续")
                        .foregroundStyle(.green)
                }
                .font(.caption)
            case .error(let message):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .foregroundStyle(.red)
                }
                .font(.caption)
            default:
                EmptyView()
            }

            Text("Token 仅存储在你的 Mac 上，不会上传到任何服务器")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.textBackgroundColor).opacity(0.5))
        )
    }

    // MARK: - OpenAI OAuth Section

    private var oauthSection: some View {
        VStack(spacing: 16) {
            switch authService.state {
            case .idle:
                Button("使用 OpenAI 账号登录") {
                    authService.authenticateOpenAIOAuth()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            case .launching:
                Button("使用 OpenAI 账号登录") {
                    authService.authenticateOpenAIOAuth()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(true)

                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在启动...")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            case .waitingForBrowser(_):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("请在浏览器中完成登录...")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            case .verified:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("授权成功")
                        .foregroundStyle(.green)
                }
                .font(.callout)
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("验证中...")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            case .error(let message):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .foregroundStyle(.red)
                }
                .font(.caption)

                Button("重试") {
                    authService.authenticateOpenAIOAuth()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.textBackgroundColor).opacity(0.5))
        )
    }

    // MARK: - Key Input Section

    private func keyInputSection(provider: AuthService.Provider) -> some View {
        let isAnthropic = provider == .anthropic
        let tint: Color = isAnthropic ? .purple : .green
        let consoleName = isAnthropic ? "console.anthropic.com" : "platform.openai.com"
        let consoleURL = isAnthropic
            ? "https://console.anthropic.com"
            : "https://platform.openai.com/api-keys"
        let keyPath = isAnthropic
            ? "Settings → API Keys"
            : "API Keys → Create new secret key"

        return VStack(alignment: .leading, spacing: 14) {
            // Instructions header
            Text("获取你的 API Key：")
                .font(.headline)

            // Step 1
            HStack(alignment: .top, spacing: 10) {
                stepBadge(number: 1, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("前往 \(consoleName) 注册/登录")
                        .font(.callout)
                    Button {
                        if let url = URL(string: consoleURL) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text(consoleURL)
                            .font(.caption)
                            .foregroundStyle(tint)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }

            // Step 2
            HStack(alignment: .top, spacing: 10) {
                stepBadge(number: 2, tint: tint)
                Text("在 \(keyPath) 中创建一个新的 Key")
                    .font(.callout)
            }

            // Step 3
            HStack(alignment: .top, spacing: 10) {
                stepBadge(number: 3, tint: tint)
                Text("复制 Key 并粘贴到下方")
                    .font(.callout)
            }

            // API Key input
            HStack(spacing: 10) {
                TextField("粘贴你的 API Key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(authService.isAuthenticated)

                Button {
                    authService.verifyKey(provider: provider, apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    switch authService.state {
                    case .verifying:
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 60)
                    case .verified:
                        Label("已验证", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    default:
                        Text("验证")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(authService.isAuthenticated ? .green : tint)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authService.state == .verifying || authService.isAuthenticated)
            }

            // Status messages
            switch authService.state {
            case .verified:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("API Key 验证成功！点击「下一步」继续")
                        .foregroundStyle(.green)
                }
                .font(.caption)
            case .error(let message):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .foregroundStyle(.red)
                }
                .font(.caption)
            default:
                EmptyView()
            }

            Text("API Key 仅存储在你的 Mac 上，不会上传到任何服务器")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.textBackgroundColor).opacity(0.5))
        )
    }

    private func stepBadge(number: Int, tint: Color) -> some View {
        Text("\(number)")
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(tint))
    }

    // MARK: - Step 2: Personalize

    private var personalizeStep: some View {
        VStack(spacing: 20) {
            Text("认识你的助手")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 12) {
                Text("助手名字")
                    .font(.headline)
                TextField("给 TA 起个名字", text: $agentName)
                    .textFieldStyle(.roundedBorder)

                Text("选一个 Emoji")
                    .font(.headline)
                HStack(spacing: 12) {
                    ForEach(["🤖", "🦉", "🐱", "🧙", "🦊", "🐸", "⚡", "🎭"], id: \.self) { emoji in
                        Button(emoji) { agentEmoji = emoji }
                            .font(.title)
                            .padding(6)
                            .background(agentEmoji == emoji ? Color.accentColor.opacity(0.2) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                Text("你的昵称")
                    .font(.headline)
                TextField("助手怎么称呼你？", text: $userName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Step 3: Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            Text(agentEmoji)
                .font(.system(size: 64))
            Text("一切就绪！")
                .font(.title.bold())
            Text("\(agentName) 已经准备好为你服务了")
                .foregroundStyle(.secondary)
        }
    }
}
