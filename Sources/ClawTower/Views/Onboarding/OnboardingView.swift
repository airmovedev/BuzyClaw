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
    @State private var claudeAuthMethod = 0
    @State private var minimaxAuthMethod = 0 // 0 = API Key, 1 = OAuth

    // Detection step state
    @State private var existingInstallDetected = false
    @State private var existingAuthDetected = false
    @State private var isDetecting = true
    @State private var detectedAgentCount = 0

    // Step 3: Agent personality
    @State private var selectedPersonality: String = ""
    @State private var selectedProactiveness: String = "适度"
    @State private var selectedFeedbackStyle: String = "委婉"

    // Step 4: User info + scenarios
    @State private var selectedSchedule: String = "正常"
    @State private var selectedOccupations: Set<String> = []
    @State private var customOccupation: String = ""
    @State private var selectedScenarios: Set<String> = []

    // Step 6: Tools profile
    @State private var selectedToolsProfile: String = "full"

    private let totalSteps = 8

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
                case 2: nameStep
                case 3: personalityStep
                case 4: userInfoStep
                case 5: providerStep
                case 6: toolsProfileStep
                case 7: readyStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: 500)

            Spacer()

            // Navigation
            HStack {
                if currentStep > 0 && currentStep != 1 {
                    Button("上一步") {
                        if currentStep == 7 && appState.gatewayMode == .existingInstall {
                            currentStep = 1
                            return
                        }
                        if currentStep == 5 {
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
                    EmptyView()
                } else if currentStep < totalSteps - 1 {
                    Button("下一步") { currentStep += 1 }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canAdvance)
                } else {
                    Button("开始对话 →") {
                        if appState.gatewayMode != .existingInstall {
                            let generator = OnboardingProfileGenerator(
                                agentName: agentName,
                                agentEmoji: agentEmoji,
                                selectedPersonality: selectedPersonality,
                                selectedProactiveness: selectedProactiveness,
                                selectedFeedbackStyle: selectedFeedbackStyle,
                                userName: userName,
                                selectedSchedule: selectedSchedule,
                                selectedOccupations: selectedOccupations,
                                selectedScenarios: selectedScenarios,
                                gatewayMode: appState.gatewayMode,
                                selectedToolsProfile: selectedToolsProfile
                            )
                            try? generator.generate()
                        }
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
        case 1: return !isDetecting
        case 3: return !selectedPersonality.isEmpty
        case 4: return !selectedScenarios.isEmpty
        case 5: return authService.isAuthenticated
        default: return true
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Text("🏗️")
                .font(.system(size: 64))
            Text("找一个 AI 合伙人")
                .font(.largeTitle.bold())
            Text("运行在你的 Mac 上，只为你工作")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Label("完全本地运行，数据只属于你", systemImage: "lock.shield")
                Label("有记忆、有性格、会主动工作", systemImage: "brain.head.profile")
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
                        currentStep = existingAuthDetected ? 7 : 5
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
        try? await Task.sleep(for: .seconds(1))

        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appendingPathComponent(".openclaw/openclaw.json").path

        if FileManager.default.fileExists(atPath: configPath) {
            existingInstallDetected = true
            let agentsDir = home.appendingPathComponent(".openclaw/agents")
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: agentsDir.path) {
                detectedAgentCount = contents.filter { !$0.hasPrefix(".") }.count
            }
            // Check if auth.profiles exists and is non-empty
            if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let auth = json["auth"] as? [String: Any],
               let profiles = auth["profiles"] as? [String: Any],
               !profiles.isEmpty {
                existingAuthDetected = true
            } else {
                existingAuthDetected = false
            }
        } else {
            existingInstallDetected = false
            appState.gatewayMode = .freshInstall
            try? await Task.sleep(for: .seconds(1))
            currentStep = 2
        }

        isDetecting = false
    }

    // MARK: - Step 2: Name

    private var nameStep: some View {
        VStack(spacing: 20) {
            Text("给你的合伙人起个名字")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 12) {
                Text("名字")
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
            }
        }
    }

    // MARK: - Step 3: Personality

    private var personalityStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("TA 的性格是？")
                    .font(.title2.bold())

                // 1. Speaking style (4 choices)
                VStack(alignment: .leading, spacing: 10) {
                    Text("说话风格")
                        .font(.headline)
                    personalityCard(id: "professional", emoji: "🎯", title: "专业高效", desc: "简洁精准，不废话")
                    personalityCard(id: "warm", emoji: "😊", title: "温暖贴心", desc: "耐心友善，像朋友")
                    personalityCard(id: "witty", emoji: "😏", title: "幽默毒舌", desc: "有态度有个性，敢怼你")
                    personalityCard(id: "rational", emoji: "📚", title: "沉稳理性", desc: "客观冷静，逻辑导向")
                }

                // 2. Proactiveness (3 choices)
                VStack(alignment: .leading, spacing: 10) {
                    Text("主动程度")
                        .font(.headline)
                    Picker("主动程度", selection: $selectedProactiveness) {
                        Text("🐑 被动").tag("被动")
                        Text("🐕 适度主动").tag("适度")
                        Text("🦉 高度主动").tag("高度")
                    }
                    .pickerStyle(.segmented)

                    Text(proactivenessHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // 3. Feedback style (2 choices)
                VStack(alignment: .leading, spacing: 10) {
                    Text("犯错提醒方式")
                        .font(.headline)
                    Picker("犯错提醒方式", selection: $selectedFeedbackStyle) {
                        Text("🤝 委婉建议").tag("委婉")
                        Text("⚡ 直接指出").tag("直接")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var proactivenessHint: String {
        switch selectedProactiveness {
        case "被动": return "你说什么做什么，不多嘴"
        case "适度": return "发现问题会提醒，有建议会说"
        case "高度": return "主动调研、主动建议、主动做事"
        default: return ""
        }
    }

    private func personalityCard(id: String, emoji: String, title: String, desc: String) -> some View {
        let isSelected = selectedPersonality == id
        return Button {
            selectedPersonality = id
        } label: {
            HStack(spacing: 12) {
                Text(emoji).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(desc).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 4: User Info + Scenarios

    private var userInfoStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("让合伙人了解你")
                    .font(.title2.bold())

                // 1. Name
                VStack(alignment: .leading, spacing: 6) {
                    Text("你的称呼")
                        .font(.headline)
                    TextField("助手怎么称呼你？", text: $userName)
                        .textFieldStyle(.roundedBorder)
                }

                // 2. Schedule
                VStack(alignment: .leading, spacing: 10) {
                    Text("作息习惯")
                        .font(.headline)
                    Picker("作息习惯", selection: $selectedSchedule) {
                        Text("🌅 早起型").tag("早起")
                        Text("🌙 夜猫子").tag("夜猫")
                        Text("⏰ 正常作息").tag("正常")
                    }
                    .pickerStyle(.segmented)
                }

                // 3. Occupation tags
                VStack(alignment: .leading, spacing: 10) {
                    Text("职业/身份")
                        .font(.headline)
                    tagGrid(
                        options: ["独立开发者", "产品经理", "设计师", "学生", "创业者", "自由职业", "上班族", "内容创作者"],
                        selected: $selectedOccupations
                    )
                    HStack {
                        TextField("自定义职业…", text: $customOccupation)
                            .textFieldStyle(.roundedBorder)
                        if !customOccupation.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("添加") {
                                selectedOccupations.insert(customOccupation.trimmingCharacters(in: .whitespaces))
                                customOccupation = ""
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                // 4. Scenarios (at least 1)
                VStack(alignment: .leading, spacing: 10) {
                    Text("使用场景（至少选 1 个）")
                        .font(.headline)
                    tagGrid(
                        options: ["💻 编程开发", "📝 写作内容", "🔍 研究分析", "📅 日程管理", "📋 项目管理", "🧠 知识管理", "🎨 创意设计", "💬 日常助手"],
                        selected: $selectedScenarios
                    )
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func tagGrid(options: [String], selected: Binding<Set<String>>) -> some View {
        let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(options, id: \.self) { option in
                let isSelected = selected.wrappedValue.contains(option)
                Button {
                    if isSelected {
                        selected.wrappedValue.remove(option)
                    } else {
                        selected.wrappedValue.insert(option)
                    }
                } label: {
                    Text(option)
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(.controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Step 5: Provider + Auth

    private var providerStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("连接你的 AI 大脑")
                    .font(.title2.bold())
                Text("选择一个 AI 服务来连接")
                    .foregroundStyle(.secondary)

                let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
                LazyVGrid(columns: columns, spacing: 16) {
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
                    providerCard(
                        provider: .minimax,
                        name: "MiniMax",
                        subtitle: "MiniMax",
                        description: "国产大模型领先者",
                        icon: "sparkles",
                        tint: .orange
                    )
                    providerCard(
                        provider: .kimi,
                        name: "Kimi",
                        subtitle: "Moonshot AI",
                        description: "擅长长文本理解",
                        icon: "moon.stars",
                        tint: .blue
                    )
                    providerCard(
                        provider: .zai,
                        name: "智谱 GLM",
                        subtitle: "Z.AI",
                        description: "国产旗舰大模型",
                        icon: "text.word.spacing",
                        tint: .cyan
                    )
                    providerCard(
                        provider: .qwen,
                        name: "通义千问",
                        subtitle: "Alibaba",
                        description: "阿里巴巴大模型",
                        icon: "cloud",
                        tint: .indigo
                    )
                    providerCard(
                        provider: .google,
                        name: "Gemini",
                        subtitle: "Google",
                        description: "Google 旗舰大模型",
                        icon: "globe",
                        tint: .red
                    )
                    providerCard(
                        provider: .xai,
                        name: "Grok",
                        subtitle: "xAI",
                        description: "Elon Musk 的 AI",
                        icon: "bolt",
                        tint: .gray
                    )
                    providerCard(
                        provider: .openrouter,
                        name: "OpenRouter",
                        subtitle: "多模型路由",
                        description: "一个 Key 用所有模型",
                        icon: "arrow.triangle.branch",
                        tint: .mint
                    )
                }

                if let provider = selectedProvider {
                    Group {
                        switch provider {
                        case .anthropic:
                            anthropicAuthSection
                        case .openai:
                            oauthSection
                        case .minimax:
                            minimaxAuthSection
                        case .kimi:
                            kimiAuthSection
                        case .zai:
                            genericApiKeyAuthSection(provider: .zai, providerName: "Z.AI", consoleName: "open.bigmodel.cn", consoleURL: "https://open.bigmodel.cn", tint: .cyan)
                        case .qwen:
                            genericApiKeyAuthSection(provider: .qwen, providerName: "通义千问", consoleName: "dashscope.console.aliyun.com", consoleURL: "https://dashscope.console.aliyun.com", tint: .indigo)
                        case .google:
                            genericApiKeyAuthSection(provider: .google, providerName: "Google Gemini", consoleName: "ai.google.dev", consoleURL: "https://ai.google.dev", tint: .red)
                        case .xai:
                            genericApiKeyAuthSection(provider: .xai, providerName: "xAI (Grok)", consoleName: "console.x.ai", consoleURL: "https://console.x.ai", tint: .gray)
                        case .openrouter:
                            genericApiKeyAuthSection(provider: .openrouter, providerName: "OpenRouter", consoleName: "openrouter.ai/keys", consoleURL: "https://openrouter.ai/keys", tint: .mint)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.vertical, 8)
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

    // MARK: - Anthropic Auth Section

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

            HStack(spacing: 10) {
                TextField("粘贴你的 Setup Token", text: $setupTokenInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(authService.isAuthenticated)

                Button {
                    let homeDir: String? = appState.gatewayMode == .freshInstall
                        ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ClawTower").path
                        : nil
                    authService.verifyAnthropicSetupToken(token: setupTokenInput.trimmingCharacters(in: .whitespacesAndNewlines), homeDir: homeDir)
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
        let oauthHomeDir: String? = appState.gatewayMode == .freshInstall
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ClawTower").path
            : nil
        return VStack(spacing: 16) {
            switch authService.state {
            case .idle:
                Button("使用 OpenAI 账号登录") {
                    authService.authenticateOpenAIOAuth(homeDir: oauthHomeDir)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            case .launching:
                Button("使用 OpenAI 账号登录") {
                    authService.authenticateOpenAIOAuth(homeDir: oauthHomeDir)
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
            case .waitingForBrowser(let url):
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("请在浏览器中完成登录...")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)

                    Button("打开浏览器") {
                        if let browserURL = URL(string: url) {
                            NSWorkspace.shared.open(browserURL)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .controlSize(.small)
                }
            case .waitingForCode:
                EmptyView()
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
                    authService.authenticateOpenAIOAuth(homeDir: oauthHomeDir)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            case .modelSelection:
                EmptyView()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.textBackgroundColor).opacity(0.5))
        )
    }

    // MARK: - MiniMax Auth Section

    private var minimaxAuthSection: some View {
        VStack(spacing: 16) {
            Picker("认证方式", selection: $minimaxAuthMethod) {
                Text("API Key").tag(0)
                Text("OAuth 登录").tag(1)
            }
            .pickerStyle(.segmented)
            .disabled(authService.isAuthenticated)
            .onChange(of: minimaxAuthMethod) {
                if !authService.isAuthenticated {
                    authService.reset()
                }
            }

            if minimaxAuthMethod == 0 {
                minimaxKeyInputSection
            } else {
                minimaxOAuthSection
            }
        }
    }

    private var minimaxKeyInputSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("输入 MiniMax API Key：")
                .font(.headline)

            Text("在 platform.minimaxi.com 获取 API Key")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("粘贴你的 API Key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(authService.isAuthenticated)

                Button {
                    let homeDir: String? = appState.gatewayMode == .freshInstall
                        ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ClawTower").path
                        : nil
                    authService.persistMinimaxApiKey(apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines), homeDir: homeDir)
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
                .tint(authService.isAuthenticated ? .green : .orange)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authService.state == .verifying || authService.isAuthenticated)
            }

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

    private var minimaxOAuthSection: some View {
        let oauthHomeDir: String? = appState.gatewayMode == .freshInstall
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ClawTower").path
            : nil
        return VStack(spacing: 16) {
            switch authService.state {
            case .idle:
                Button("使用 MiniMax 账号登录") {
                    authService.authenticateMinimaxOAuth(homeDir: oauthHomeDir)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            case .launching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在请求授权...")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            case .waitingForCode(let url, let code):
                VStack(spacing: 12) {
                    Text("请在浏览器中输入以下代码完成授权")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text(code)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(.textBackgroundColor))
                        )

                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("等待授权...")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)

                    Button("重新打开浏览器") {
                        if let browserURL = URL(string: url) {
                            NSWorkspace.shared.open(browserURL)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.small)
                }
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
                    authService.authenticateMinimaxOAuth(homeDir: oauthHomeDir)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            case .modelSelection:
                EmptyView()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.textBackgroundColor).opacity(0.5))
        )
    }

    // MARK: - Kimi Auth Section

    private var kimiAuthSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("输入 Moonshot API Key：")
                .font(.headline)

            Text("在 platform.moonshot.cn 获取 API Key")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("粘贴你的 API Key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(authService.isAuthenticated)

                Button {
                    let homeDir: String? = appState.gatewayMode == .freshInstall
                        ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ClawTower").path
                        : nil
                    authService.persistMoonshotApiKey(apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines), homeDir: homeDir)
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
                .tint(authService.isAuthenticated ? .green : .blue)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authService.state == .verifying || authService.isAuthenticated)
            }

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

    // MARK: - Generic API Key Auth Section

    private func genericApiKeyAuthSection(provider: AuthService.Provider, providerName: String, consoleName: String, consoleURL: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("输入 \(providerName) API Key：")
                .font(.headline)

            HStack(spacing: 4) {
                Text("在")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: consoleURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(consoleName)
                        .font(.callout)
                        .foregroundStyle(tint)
                        .underline()
                }
                .buttonStyle(.plain)
                Text("获取 API Key")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                TextField("粘贴你的 API Key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(authService.isAuthenticated)

                Button {
                    let homeDir: String? = appState.gatewayMode == .freshInstall
                        ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ClawTower").path
                        : nil
                    authService.persistGenericApiKey(provider: provider, apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines), homeDir: homeDir)
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

            // Model selection for Qwen (after key verification)
            if provider == .qwen && authService.state == .modelSelection {
                VStack(alignment: .leading, spacing: 8) {
                    Text("选择模型：")
                        .font(.subheadline.bold())

                    Picker("模型", selection: Binding(
                        get: { authService.selectedModelId ?? "" },
                        set: { authService.selectedModelId = $0 }
                    )) {
                        ForEach(authService.availableModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Button("确认") {
                        guard let modelId = authService.selectedModelId else { return }
                        let homeDir: String? = appState.gatewayMode == .freshInstall
                            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ClawTower").path
                            : nil
                        authService.persistQwenWithSelectedModel(apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines), modelId: modelId, homeDir: homeDir)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                }
            }

            switch authService.state {
            case .verified:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("API Key 验证成功！点击「下一步」继续")
                        .foregroundStyle(.green)
                }
                .font(.caption)
            case .modelSelection:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                    Text("请选择要使用的模型")
                        .foregroundStyle(.blue)
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
            Text("获取你的 API Key：")
                .font(.headline)

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

            HStack(alignment: .top, spacing: 10) {
                stepBadge(number: 2, tint: tint)
                Text("在 \(keyPath) 中创建一个新的 Key")
                    .font(.callout)
            }

            HStack(alignment: .top, spacing: 10) {
                stepBadge(number: 3, tint: tint)
                Text("复制 Key 并粘贴到下方")
                    .font(.callout)
            }

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

    // MARK: - Step 6: Tools Profile

    private var toolsProfileStep: some View {
        VStack(spacing: 20) {
            Text("选择工具权限")
                .font(.title2.bold())
            Text("Tools Profile — 控制 AI 可使用的工具范围")
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                toolsProfileCard(
                    id: "full",
                    emoji: "🔓",
                    title: "完整 Full",
                    desc: "全部工具开放（文件、终端、浏览器、消息等）"
                )
                toolsProfileCard(
                    id: "coding",
                    emoji: "💻",
                    title: "编程 Coding",
                    desc: "面向开发：读写文件、执行命令等"
                )
                toolsProfileCard(
                    id: "messaging",
                    emoji: "💬",
                    title: "消息 Messaging",
                    desc: "消息、搜索、记忆等安全工具，无系统权限"
                )
                toolsProfileCard(
                    id: "minimal",
                    emoji: "🔒",
                    title: "精简 Minimal",
                    desc: "最精简，基本只有对话能力"
                )
            }
        }
    }

    private func toolsProfileCard(id: String, emoji: String, title: String, desc: String) -> some View {
        let isSelected = selectedToolsProfile == id
        return Button {
            selectedToolsProfile = id
        } label: {
            HStack(spacing: 12) {
                Text(emoji).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(desc).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 7: Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            if appState.gatewayMode == .existingInstall {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("一切就绪！")
                    .font(.title.bold())

                VStack(spacing: 8) {
                    Text("已检测到你的 OpenClaw 配置")
                        .font(.title3)
                    Text("点击「开始对话 →」即可启动")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.controlBackgroundColor))
                )
            } else {
                Text(agentEmoji)
                    .font(.system(size: 64))
                Text(agentName)
                    .font(.title.bold())

                Text(readySummary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("📱 手机端可在 App Store 搜索「ClawTower」下载，远程连接控制你的 AI Agent。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
    }

    private var readySummary: String {
        let style: String
        switch selectedPersonality {
        case "professional": style = "专业高效"
        case "warm": style = "温暖贴心"
        case "witty": style = "幽默毒舌"
        case "rational": style = "沉稳理性"
        default: style = "全能"
        }
        let scenes = selectedScenarios.joined(separator: "、")
        return "你的\(style)助手，帮你\(scenes)"
    }
}
