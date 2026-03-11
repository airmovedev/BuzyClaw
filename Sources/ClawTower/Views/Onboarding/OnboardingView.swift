import SwiftUI
import AppKit

struct OnboardingView: View {
    let appState: AppState

    private enum AuthFlow: Hashable {
        case anthropicAPIKey
        case anthropicSetupToken
        case openAIAPIKey
        case openAIOAuth
        case minimaxAPIKey
        case minimaxOAuth
        case kimiAPIKey
        case zaiAPIKey
        case qwenAPIKey
        case googleAPIKey
        case xaiAPIKey
        case openRouterAPIKey
    }

    private struct ProviderOption: Identifiable {
        let provider: AuthService.Provider
        let name: String
        let subtitle: String
        let description: String

        var id: AuthService.Provider { provider }
    }

    @State private var currentStep = 0
    @State private var agentName = "Assistant"
    @State private var agentEmoji = "🤖"
    @State private var userName = ""

    @State private var authService = AuthService()
    @State private var selectedProvider: AuthService.Provider?
    @State private var apiKeyInput = ""
    @State private var setupTokenInput = ""
    @State private var activeAuthFlow: AuthFlow?

    @State private var skillsService = SkillsService()
    @State private var didLoadSkills = false

    @State private var existingInstallDetected = false
    @State private var existingAuthDetected = false
    @State private var isDetecting = true
    @State private var detectedAgentCount = 0

    @State private var selectedPersonality: String = ""
    @State private var selectedProactiveness: String = "适度"
    @State private var selectedFeedbackStyle: String = "委婉"

    @State private var selectedSchedule: String = "正常"
    @State private var customOccupationOptions: [String] = []
    @State private var selectedOccupations: Set<String> = []
    @State private var customOccupation: String = ""
    @State private var selectedScenarios: Set<String> = []

    @State private var selectedToolsProfile: String = "full"

    @State private var permissionStatus: [PermissionCapability: Bool] = [:]
    @State private var pendingPermission: PermissionCapability?

    private let totalSteps = 10
    private let defaultOccupationOptions = ["独立开发者", "产品经理", "设计师", "学生", "创业者", "自由职业", "上班族", "内容创作者"]

    private let providerOptions: [ProviderOption] = [
        .init(provider: .anthropic, name: "Claude", subtitle: "Anthropic", description: "写作、分析和长期协作体验很强"),
        .init(provider: .openai, name: "ChatGPT", subtitle: "OpenAI", description: "代码、推理和通用能力都很稳"),
        .init(provider: .minimax, name: "MiniMax", subtitle: "MiniMax", description: "国产模型里综合能力很能打"),
        .init(provider: .kimi, name: "Kimi", subtitle: "Moonshot AI", description: "长文本理解和资料处理更擅长"),
        .init(provider: .zai, name: "智谱 GLM", subtitle: "Z.AI", description: "国产旗舰模型，适合日常主力使用"),
        .init(provider: .qwen, name: "通义千问", subtitle: "Alibaba", description: "模型选择丰富，适配场景多"),
        .init(provider: .google, name: "Gemini", subtitle: "Google", description: "多模态和 Google 生态配合顺手"),
        .init(provider: .xai, name: "Grok", subtitle: "xAI", description: "回答直接，适合快速探索和发散"),
        .init(provider: .openrouter, name: "OpenRouter", subtitle: "多模型路由", description: "一个 Key 连接多个模型服务")
    ]

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerSection

                Spacer(minLength: 16)

                Group {
                    switch currentStep {
                    case 0: welcomeStep
                    case 1: detectionStep
                    case 2: nameStep
                    case 3: personalityStep
                    case 4: userInfoStep
                    case 5: providerStep
                    case 6: skillsStep
                    case 7: toolsProfileStep
                    case 8: permissionsStep
                    case 9: readyStep
                    default: EmptyView()
                    }
                }
                .frame(maxWidth: 760, maxHeight: .infinity, alignment: .center)
                .padding(.top, 28)

                Spacer(minLength: 20)

                navigationSection
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
        }
        .frame(minWidth: 760, minHeight: 640)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(stepEyebrow)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(stepTitle)
                        .font(.system(size: 28, weight: .bold))
                    Text(stepSubtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 24)
                Text("步骤 \(currentStep + 1) / \(totalSteps)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .frame(maxWidth: 760)
    }

    private var navigationSection: some View {
        HStack {
            if currentStep > 0 && currentStep != 1 {
                ArrowNavigationButton(direction: .back, disabled: false) {
                    if currentStep == 9 && appState.gatewayMode == .existingInstall {
                        currentStep = 1
                        return
                    }
                    if currentStep == 5 {
                        resetProviderSelection()
                    }
                    currentStep -= 1
                }
            } else {
                Color.clear
                    .frame(width: 56, height: 56)
            }

            Spacer()

            if currentStep == 1 {
                Color.clear
                    .frame(width: 56, height: 56)
            } else if currentStep < totalSteps - 1 {
                ArrowNavigationButton(direction: .forward, disabled: !canAdvance, highlight: canAdvance) {
                    currentStep += 1
                }
            } else {
                ArrowNavigationButton(direction: .forward, disabled: false, highlight: true) {
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
            }
        }
        .frame(maxWidth: 760)
        .padding(.vertical, 4)
        .background(Color.clear)
    }

    private var stepEyebrow: String {
        switch currentStep {
        case 0: return "欢迎使用 虾忙"
        case 1: return "环境检测"
        case 2: return "角色设定"
        case 3: return "协作风格"
        case 4: return "了解你"
        case 5: return "连接模型"
        case 6: return "技能库"
        case 7: return "工具范围"
        case 8: return "系统权限"
        case 9: return "准备完成"
        default: return "配置向导"
        }
    }

    private var stepTitle: String {
        switch currentStep {
        case 0: return "把你的 AI 工作台装进 Mac"
        case 1: return "先看看这台 Mac 上已经有什么"
        case 2: return "给你的合伙人定个名字"
        case 3: return "决定 TA 怎么和你合作"
        case 4: return "让助手更懂你"
        case 5: return "选一个主力模型并完成认证"
        case 6: return "把常用能力先装上"
        case 7: return "决定 TA 能用到哪些工具"
        case 8: return "打开系统能力，体验会完整很多"
        case 9: return appState.gatewayMode == .existingInstall ? "你的工作台已经可以用了" : "你的 AI 合伙人准备好了"
        default: return "配置向导"
        }
    }

    private var stepSubtitle: String {
        switch currentStep {
        case 0: return "本地优先、可自定义、有记忆，也能和 iPhone 协同。整个流程只帮你把体验打磨顺，不乱改你的核心设置。"
        case 1: return "如果已经装过 OpenClaw，我们会尽量复用现有配置，少折腾一次。"
        case 2: return "名字和形象会影响之后的默认人设，但不影响能力，后面随时都能再改。"
        case 3: return "统一好表达方式、主动程度和提醒风格，后面日常协作会顺手很多。"
        case 4: return "让 虾忙 了解你的称呼、作息和使用重点，后面给出的建议会更贴身。"
        case 5: return "先把大脑接上。你可以选熟悉的模型服务，流程不变，只把呈现方式做得更清楚。"
        case 6: return "技能就是可插拔能力。先装常用的，之后也能在设置里继续增减。"
        case 7: return "工具越多，行动能力越强；范围越小，边界越保守。按你的习惯来。"
        case 8: return "这些权限都能稍后再改。先开常用项，虾忙 才能更像一台真正会干活的工作台。"
        case 9: return appState.gatewayMode == .existingInstall ? "现有环境已识别完成，马上就能继续工作。" : "配置不会把你绑死，后面都能继续微调。先开始用，才是正经事。"
        default: return ""
        }
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

    private var selectedProviderName: String {
        providerOptions.first(where: { $0.provider == selectedProvider })?.name ?? ""
    }

    private var currentAuthState: AuthService.AuthState? {
        guard let activeAuthFlow else { return nil }
        return stateForActiveFlow(activeAuthFlow)
    }

    private var authMethodColumns: [GridItem] {
        [GridItem(.flexible(minimum: 220), spacing: 16), GridItem(.flexible(minimum: 220), spacing: 16)]
    }

    private func stateForActiveFlow(_ flow: AuthFlow) -> AuthService.AuthState? {
        activeAuthFlow == flow ? authService.state : nil
    }

    private func configHomeDir() -> String? {
        appState.gatewayMode == .freshInstall ? appState.openclawBasePath.path : nil
    }

    private func resetProviderSelection() {
        authService.reset()
        selectedProvider = nil
        apiKeyInput = ""
        setupTokenInput = ""
        activeAuthFlow = nil
    }

    private func addCustomOccupation() {
        let trimmed = customOccupation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !defaultOccupationOptions.contains(trimmed) && !customOccupationOptions.contains(trimmed) {
            customOccupationOptions.append(trimmed)
        }

        selectedOccupations = [trimmed]
        customOccupation = ""
    }

    private func selectProvider(_ provider: AuthService.Provider) {
        guard !authService.isAuthenticated else { return }
        resetProviderSelection()
        selectedProvider = provider
    }

    private func ensureSkillsLoaded() async {
        guard !didLoadSkills else { return }
        didLoadSkills = true
        skillsService.configure(configDirectory: appState.openclawBasePath)
        await skillsService.loadSkills()
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 34) {
            VStack(spacing: 18) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 108, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.10), radius: 20, y: 10)
                }

                VStack(spacing: 12) {
                    Text("虾忙 不是一个只会聊天的 AI。")
                        .font(.system(size: 30, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text("它更像一套运行在你自己设备上的个人工作台：能对话、记任务、做提醒、装技能、接管工具，也能在 macOS 和 iPhone 之间自然协同。数据留在你手里，能力按你的习惯长出来。")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 580)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 14) {
                featureCard(icon: "rectangle.on.rectangle.angled", title: "本地 Agent 工作台", description: "多 Agent 协作、任务分工和对话都在一处完成")
                featureCard(icon: "clock.badge.checkmark", title: "任务与提醒", description: "对话、待办、定时动作和技能库彼此打通")
                featureCard(icon: "lock.shield", title: "你自己掌控", description: "本地优先、能力可配、边界清楚，不被平台牵着走")
            }
        }
        .frame(maxWidth: 760)
    }

    private func featureCard(icon: String, title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(title)
                .font(.headline)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Step 1: Detection

    private var detectionStep: some View {
        onboardingCard(width: 620) {
            VStack(spacing: 22) {
                if isDetecting {
                    ProgressView()
                        .scaleEffect(1.25)
                    Text("正在检查现有安装与配置…")
                        .font(.title3.weight(.semibold))
                    Text("如果你之前已经装过，我们会优先复用，别让你重复填一遍。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if existingInstallDetected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.green)
                    Text("发现已有 OpenClaw 环境")
                        .font(.title2.bold())
                    Text("已在 ~/.openclaw 中识别到现有配置。你可以直接接着用，也可以从头重新配置一套。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if detectedAgentCount > 0 {
                        infoChip(text: "已发现 \(detectedAgentCount) 个 Agent", tint: .green)
                    }

                    VStack(spacing: 12) {
                        largeActionButton(title: "继续使用现有配置", icon: "arrow.clockwise.circle.fill", prominence: .primary) {
                            appState.gatewayMode = .existingInstall
                            currentStep = existingAuthDetected ? 9 : 5
                        }

                        largeActionButton(title: "重新开始配置", icon: "sparkles", prominence: .secondary) {
                            appState.gatewayMode = .freshInstall
                            currentStep = 2
                        }
                    }
                    .frame(maxWidth: 360)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.accentColor)
                    Text("这是一次全新配置")
                        .font(.title2.bold())
                    Text("我们会帮你搭好一套新的本地 AI 工作台，几步走完就能开始用。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
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
        onboardingCard {
            VStack(alignment: .leading, spacing: 28) {
                sectionIntro(title: "先定一个称呼和形象", description: "这是你以后每天都会看到的默认设定。先选个顺眼的，后面再改也很方便。")

                VStack(alignment: .leading, spacing: 14) {
                    fieldLabel("名字")
                    largeTextField("给 TA 起个名字", text: $agentName)
                }

                VStack(alignment: .leading, spacing: 14) {
                    fieldLabel("主视觉 Emoji")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 12) {
                        ForEach(["🤖", "🦉", "🐱", "🧙", "🦊", "🐸", "⚡", "🎭"], id: \.self) { emoji in
                            let isSelected = agentEmoji == emoji
                            Button {
                                agentEmoji = emoji
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 28))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 60)
                                    .background(selectionBackground(isSelected))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Step 3: Personality

    private var personalityStep: some View {
        ScrollView {
            onboardingCard {
                VStack(alignment: .leading, spacing: 26) {
                    sectionIntro(title: "把相处方式一次说清楚", description: "虾忙 可以有态度，但别搞成戏精。把风格定好，后面省心很多。")

                    VStack(alignment: .leading, spacing: 14) {
                        fieldLabel("说话风格")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            personalityCard(id: "professional", emoji: "🎯", title: "专业高效", desc: "简洁、明确、抓重点")
                            personalityCard(id: "warm", emoji: "😊", title: "温暖贴心", desc: "更友好，也更照顾情绪")
                            personalityCard(id: "witty", emoji: "😏", title: "幽默毒舌", desc: "有态度，不装孙子")
                            personalityCard(id: "rational", emoji: "📚", title: "沉稳理性", desc: "更客观，逻辑先行")
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        fieldLabel("主动程度")
                        Picker("", selection: $selectedProactiveness) {
                            Text("🐑 被动").tag("被动")
                            Text("🐕 适度主动").tag("适度")
                            Text("🦉 高度主动").tag("高度")
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.large)

                        Text(proactivenessHint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        fieldLabel("指出问题的方式")
                        Picker("犯错提醒方式", selection: $selectedFeedbackStyle) {
                            Text("🤝 委婉建议").tag("委婉")
                            Text("⚡ 直接指出").tag("直接")
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.large)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var proactivenessHint: String {
        switch selectedProactiveness {
        case "被动": return "你说什么做什么，不额外打扰。"
        case "适度": return "看到明显问题会提醒，有靠谱建议会说。"
        case "高度": return "会主动调研、主动推进，也会更常打断你。"
        default: return ""
        }
    }

    private func personalityCard(id: String, emoji: String, title: String, desc: String) -> some View {
        let isSelected = selectedPersonality == id
        return selectionRow(isSelected: isSelected) {
            selectedPersonality = id
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(emoji)
                        .font(.system(size: 18))
                    Spacer(minLength: 8)
                    selectionIndicator(isSelected: isSelected)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        }
    }

    // MARK: - Step 4: User Info + Scenarios

    private var userInfoStep: some View {
        ScrollView {
            onboardingCard {
                VStack(alignment: .leading, spacing: 24) {
                    sectionIntro(title: "让 虾忙 更懂你", description: "不用填很多，只把影响协作体验的关键信息告诉它。")

                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("希望怎么称呼你")
                        largeTextField("助手该怎么称呼你？", text: $userName)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        fieldLabel("职业 / 身份")
                        tagGrid(
                            options: defaultOccupationOptions + customOccupationOptions,
                            selected: $selectedOccupations
                        )

                        HStack(spacing: 12) {
                            largeTextField("自定义职业", text: $customOccupation)
                            largeActionButton(title: "添加", icon: "plus", prominence: .secondary) {
                                addCustomOccupation()
                            }
                            .frame(width: 122)
                            .disabled(customOccupation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        fieldLabel("你最常用 虾忙 做什么（至少选 1 个）")
                        tagGrid(
                            options: ["💻 编程开发", "📝 写作内容", "🔍 研究分析", "📅 日程管理", "📋 项目管理", "🧠 知识管理", "🎨 创意设计", "💬 日常助手"],
                            selected: $selectedScenarios
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func tagGrid(options: [String], selected: Binding<Set<String>>) -> some View {
        let columns = [GridItem(.adaptive(minimum: 88), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(options, id: \.self) { option in
                let isSelected = selected.wrappedValue.contains(option)
                Button {
                    if isSelected {
                        selected.wrappedValue.remove(option)
                    } else {
                        selected.wrappedValue.insert(option)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(option)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 40)
                    .background(selectionBackground(isSelected))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Step 5: Provider + Auth

    private var providerStep: some View {
        ScrollView {
            onboardingCard(width: selectedProvider == nil ? 720 : 860) {
                VStack(alignment: .leading, spacing: 18) {
                    sectionIntro(title: "选一个最顺手的 AI 大脑", description: "先选模型，再在同一页完成认证。逻辑不变，只是把信息整理得更清楚。")

                    HStack(alignment: .top, spacing: 24) {
                        VStack(spacing: 6) {
                            ForEach(providerOptions) { option in
                                providerRow(option)
                            }
                        }
                        .frame(width: selectedProvider == nil ? 620 : 290, alignment: .leading)

                        if let provider = selectedProvider {
                            providerAuthContent(for: provider)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: selectedProvider == nil ? .center : .leading)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .animation(.easeInOut(duration: 0.2), value: selectedProvider)
    }

    @ViewBuilder
    private func providerAuthContent(for provider: AuthService.Provider) -> some View {
        LazyVGrid(columns: authMethodColumns, alignment: .leading, spacing: 16) {
            switch provider {
            case .anthropic:
                authMethodGroup {
                    keyInputSection(provider: .anthropic, flow: .anthropicAPIKey)
                }
                authMethodGroup {
                    setupTokenSection
                }
            case .openai:
                authMethodGroup {
                    keyInputSection(provider: .openai, flow: .openAIAPIKey)
                }
                authMethodGroup {
                    openAIOAuthSection
                }
            case .minimax:
                authMethodGroup {
                    minimaxKeyInputSection
                }
                authMethodGroup {
                    minimaxOAuthSection
                }
            case .kimi:
                authMethodGroup {
                    kimiAuthSection
                }
            case .zai:
                authMethodGroup {
                    genericApiKeyAuthSection(provider: .zai, providerName: "Z.AI", consoleName: "open.bigmodel.cn", consoleURL: "https://open.bigmodel.cn", tint: .cyan, flow: .zaiAPIKey)
                }
            case .qwen:
                authMethodGroup {
                    genericApiKeyAuthSection(provider: .qwen, providerName: "通义千问", consoleName: "dashscope.console.aliyun.com", consoleURL: "https://dashscope.console.aliyun.com", tint: .indigo, flow: .qwenAPIKey)
                }
            case .google:
                authMethodGroup {
                    genericApiKeyAuthSection(provider: .google, providerName: "Google Gemini", consoleName: "ai.google.dev", consoleURL: "https://ai.google.dev", tint: .red, flow: .googleAPIKey)
                }
            case .xai:
                authMethodGroup {
                    genericApiKeyAuthSection(provider: .xai, providerName: "xAI (Grok)", consoleName: "console.x.ai", consoleURL: "https://console.x.ai", tint: .gray, flow: .xaiAPIKey)
                }
            case .openrouter:
                authMethodGroup {
                    genericApiKeyAuthSection(provider: .openrouter, providerName: "OpenRouter", consoleName: "openrouter.ai/keys", consoleURL: "https://openrouter.ai/keys", tint: .mint, flow: .openRouterAPIKey)
                }
            }
        }
    }

    private func providerRow(_ option: ProviderOption) -> some View {
        let isSelected = selectedProvider == option.provider

        return selectionRow(isSelected: isSelected, disabled: authService.isAuthenticated) {
            selectProvider(option.provider)
        } content: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(option.name)
                            .font(.headline)
                        Text(option.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(option.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if authService.isAuthenticated && isSelected {
                    infoChip(text: "已验证", tint: .green)
                } else {
                    selectionIndicator(isSelected: isSelected)
                }
            }
        }
    }

    private func authMethodGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Step 6: Skills

    private var skillsStep: some View {
        ScrollView {
            onboardingCard {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        sectionIntro(title: "先装上常用技能", description: "先把常用的开上，后面再微调。")
                        Spacer(minLength: 16)
                    }

                    if skillsService.isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在加载技能列表…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else if let error = skillsService.errorMessage {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            largeActionButton(title: "重试", icon: "arrow.clockwise", prominence: .secondary) {
                                Task { await skillsService.loadSkills() }
                            }
                            .frame(width: 120)
                        }
                        .padding(20)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else if skillsService.skills.isEmpty {
                        Text("当前没有可展示的技能。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 28)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                            ForEach(skillsService.skills) { skill in
                                onboardingSkillRow(skill)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .task {
            await ensureSkillsLoaded()
        }
    }

    private func onboardingSkillRow(_ skill: Skill) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(skill.displayEmoji)
                        .font(.title3)
                    Text(skill.name)
                        .font(.headline)
                }

                if let description = skill.description {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { !skill.disabled },
                set: { newValue in
                    skillsService.setSkillEnabled(name: skill.name, enabled: newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .scaleEffect(0.92)
            .disabled(!skill.canBeEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(skill.canBeEnabled ? Color.secondary.opacity(0.12) : Color.orange.opacity(0.26), lineWidth: 1)
        )
    }

    // MARK: - Setup Token Section

    private var setupTokenSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("如果你已经装过 Claude CLI，也可以直接用 Setup Token 完成连接。")
                .font(.callout)
                .foregroundStyle(.secondary)

            instructionRow(number: 1, tint: .purple, text: "打开终端（Terminal）。")

            HStack(alignment: .top, spacing: 12) {
                stepBadge(number: 2, tint: .purple)
                VStack(alignment: .leading, spacing: 8) {
                    Text("输入下面这条命令：")
                        .font(.callout)
                    Text("claude setup-token")
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .textSelection(.enabled)
                }
            }

            instructionRow(number: 3, tint: .purple, text: "按提示完成授权，并复制拿到的 Token。")
            instructionRow(number: 4, tint: .purple, text: "把 Token 粘贴到下面，再点击验证。")

            authInputRow(
                placeholder: "粘贴你的 Setup Token",
                text: $setupTokenInput,
                tint: .purple,
                isAuthenticated: authService.isAuthenticated,
                state: stateForActiveFlow(.anthropicSetupToken),
                action: {
                    activeAuthFlow = .anthropicSetupToken
                    authService.verifyAnthropicSetupToken(
                        token: setupTokenInput.trimmingCharacters(in: .whitespacesAndNewlines),
                        homeDir: configHomeDir()
                    )
                }
            )

            authFeedback(flow: .anthropicSetupToken, success: "Setup Token 已验证，可以继续下一步。")

            Text("Token 只会保存在你的 Mac 上，不会上传到其他服务器。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - OpenAI OAuth Section

    private var openAIOAuthSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch stateForActiveFlow(.openAIOAuth) ?? .idle {
            case .idle:
                largeActionButton(title: "使用 OpenAI 账号登录", icon: "person.crop.circle.badge.checkmark", prominence: .primary, tint: .green) {
                    activeAuthFlow = .openAIOAuth
                    authService.authenticateOpenAIOAuth(homeDir: configHomeDir())
                }
                .frame(width: 240)
            case .launching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在启动登录流程…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            case .waitingForBrowser(let url):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("请在浏览器里完成登录。")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                largeActionButton(title: "打开浏览器", icon: "safari", prominence: .secondary, tint: .green) {
                    if let browserURL = URL(string: url) {
                        NSWorkspace.shared.open(browserURL)
                    }
                }
                .frame(width: 170)
            case .waitingForCode:
                EmptyView()
            case .verified:
                authSuccessLabel("授权成功")
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("验证中…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            case .error(let message):
                authErrorLabel(message)
                largeActionButton(title: "重试", icon: "arrow.clockwise", prominence: .primary, tint: .green) {
                    activeAuthFlow = .openAIOAuth
                    authService.authenticateOpenAIOAuth(homeDir: configHomeDir())
                }
                .frame(width: 120)
            case .modelSelection:
                EmptyView()
            }
        }
    }

    // MARK: - MiniMax Auth Section

    private var minimaxKeyInputSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("输入 MiniMax API Key")
                .font(.headline)
            Text("可在 platform.minimaxi.com 获取。")
                .font(.callout)
                .foregroundStyle(.secondary)

            authInputRow(
                placeholder: "粘贴你的 API Key",
                text: $apiKeyInput,
                tint: .orange,
                isAuthenticated: authService.isAuthenticated,
                state: stateForActiveFlow(.minimaxAPIKey),
                action: {
                    activeAuthFlow = .minimaxAPIKey
                    authService.persistMinimaxApiKey(
                        apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                        homeDir: configHomeDir()
                    )
                }
            )

            authFeedback(flow: .minimaxAPIKey, success: "API Key 已验证，可以继续下一步。")

            Text("API Key 只会保存在你的 Mac 上，不会上传到其他服务器。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var minimaxOAuthSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch stateForActiveFlow(.minimaxOAuth) ?? .idle {
            case .idle:
                largeActionButton(title: "使用 MiniMax 账号登录", icon: "person.crop.circle.badge.checkmark", prominence: .primary, tint: .orange) {
                    activeAuthFlow = .minimaxOAuth
                    authService.authenticateMinimaxOAuth(homeDir: configHomeDir())
                }
                .frame(width: 240)
            case .launching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在请求授权…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            case .waitingForCode(let url, let code):
                Text("请在浏览器中输入下面这组代码完成授权。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(code)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 14)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("等待授权完成…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                largeActionButton(title: "重新打开浏览器", icon: "safari", prominence: .secondary, tint: .orange) {
                    if let browserURL = URL(string: url) {
                        NSWorkspace.shared.open(browserURL)
                    }
                }
                .frame(width: 190)
            case .waitingForBrowser:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("请在浏览器中完成登录…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            case .verified:
                authSuccessLabel("授权成功")
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("验证中…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            case .error(let message):
                authErrorLabel(message)
                largeActionButton(title: "重试", icon: "arrow.clockwise", prominence: .primary, tint: .orange) {
                    activeAuthFlow = .minimaxOAuth
                    authService.authenticateMinimaxOAuth(homeDir: configHomeDir())
                }
                .frame(width: 120)
            case .modelSelection:
                EmptyView()
            }
        }
    }

    // MARK: - Kimi Auth Section

    private var kimiAuthSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("输入 Moonshot API Key")
                .font(.headline)
            Text("可在 platform.moonshot.cn 获取。")
                .font(.callout)
                .foregroundStyle(.secondary)

            authInputRow(
                placeholder: "粘贴你的 API Key",
                text: $apiKeyInput,
                tint: .blue,
                isAuthenticated: authService.isAuthenticated,
                state: stateForActiveFlow(.kimiAPIKey),
                action: {
                    activeAuthFlow = .kimiAPIKey
                    authService.persistMoonshotApiKey(
                        apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                        homeDir: configHomeDir()
                    )
                }
            )

            authFeedback(flow: .kimiAPIKey, success: "API Key 已验证，可以继续下一步。")

            Text("API Key 只会保存在你的 Mac 上，不会上传到其他服务器。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Generic API Key Auth Section

    private func genericApiKeyAuthSection(
        provider: AuthService.Provider,
        providerName: String,
        consoleName: String,
        consoleURL: String,
        tint: Color,
        flow: AuthFlow
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("输入 \(providerName) API Key")
                .font(.headline)

            HStack(spacing: 4) {
                Text("可在")
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
                Text("获取。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            authInputRow(
                placeholder: "粘贴你的 API Key",
                text: $apiKeyInput,
                tint: tint,
                isAuthenticated: authService.isAuthenticated,
                state: stateForActiveFlow(flow),
                action: {
                    activeAuthFlow = flow
                    authService.persistGenericApiKey(
                        provider: provider,
                        apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                        homeDir: configHomeDir()
                    )
                }
            )

            if provider == .qwen && stateForActiveFlow(flow) == .modelSelection {
                VStack(alignment: .leading, spacing: 10) {
                    Text("选择模型")
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

                    largeActionButton(title: "确认模型", icon: "checkmark", prominence: .primary, tint: tint) {
                        guard let modelId = authService.selectedModelId else { return }
                        activeAuthFlow = flow
                        authService.persistQwenWithSelectedModel(
                            apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                            modelId: modelId,
                            homeDir: configHomeDir()
                        )
                    }
                    .frame(width: 150)
                }
            }

            switch stateForActiveFlow(flow) {
            case .verified:
                authSuccessLabel("API Key 已验证，可以继续下一步。")
            case .modelSelection:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                    Text("请选择你要使用的模型")
                        .foregroundStyle(.blue)
                }
                .font(.caption)
            case .error(let message):
                authErrorLabel(message)
            default:
                EmptyView()
            }

            Text("API Key 只会保存在你的 Mac 上，不会上传到其他服务器。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Key Input Section

    private func keyInputSection(provider: AuthService.Provider, flow: AuthFlow) -> some View {
        let isAnthropic = provider == .anthropic
        let tint: Color = isAnthropic ? .purple : .green
        let consoleName = isAnthropic ? "console.anthropic.com" : "platform.openai.com"
        let consoleURL = isAnthropic ? "https://console.anthropic.com" : "https://platform.openai.com/api-keys"
        let keyPath = isAnthropic ? "Settings → API Keys" : "API Keys → Create new secret key"

        return VStack(alignment: .leading, spacing: 16) {
            instructionRow(number: 1, tint: tint, text: "前往 \(consoleName) 登录账号。", linkTitle: consoleURL, linkAction: {
                if let url = URL(string: consoleURL) {
                    NSWorkspace.shared.open(url)
                }
            })
            instructionRow(number: 2, tint: tint, text: "在 \(keyPath) 里创建新的 Key。")
            instructionRow(number: 3, tint: tint, text: "复制 Key 并粘贴到下面，再点击验证。")

            authInputRow(
                placeholder: "粘贴你的 API Key",
                text: $apiKeyInput,
                tint: tint,
                isAuthenticated: authService.isAuthenticated,
                state: stateForActiveFlow(flow),
                action: {
                    activeAuthFlow = flow
                    authService.verifyKey(provider: provider, apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            )

            authFeedback(flow: flow, success: "API Key 已验证，可以继续下一步。")

            Text("API Key 只会保存在你的 Mac 上，不会上传到其他服务器。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func authFeedback(flow: AuthFlow, success: String) -> some View {
        switch stateForActiveFlow(flow) {
        case .verified:
            authSuccessLabel(success)
        case .error(let message):
            authErrorLabel(message)
        default:
            EmptyView()
        }
    }

    private func authSuccessLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .foregroundStyle(.green)
        }
        .font(.callout)
    }

    private func authErrorLabel(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .foregroundStyle(.red)
        }
        .font(.callout)
    }

    private func stepBadge(number: Int, tint: Color) -> some View {
        Text("\(number)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(tint))
    }

    // MARK: - Step 7: Tools Profile

    private var toolsProfileStep: some View {
        onboardingCard {
            VStack(alignment: .leading, spacing: 20) {
                sectionIntro(title: "给 虾忙 划清工具边界", description: "能力和边界一起设计，才是能长期用下去的体验。")

                VStack(spacing: 12) {
                    toolsProfileCard(id: "full", emoji: "🔓", title: "完整 Full", desc: "开放全部工具：文件、终端、浏览器、消息等")
                    toolsProfileCard(id: "coding", emoji: "💻", title: "编程 Coding", desc: "更适合开发工作：读写文件、执行命令、处理工程")
                    toolsProfileCard(id: "messaging", emoji: "💬", title: "消息 Messaging", desc: "主打消息、搜索、记忆等安全工具，不碰系统能力")
                    toolsProfileCard(id: "minimal", emoji: "🔒", title: "精简 Minimal", desc: "边界最小，基本只保留对话能力")
                }
            }
        }
    }

    private func toolsProfileCard(id: String, emoji: String, title: String, desc: String) -> some View {
        let isSelected = selectedToolsProfile == id
        return selectionRow(isSelected: isSelected) {
            selectedToolsProfile = id
        } content: {
            HStack(spacing: 14) {
                Text(emoji)
                    .font(.system(size: 28))
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(desc)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                selectionIndicator(isSelected: isSelected)
            }
        }
    }

    // MARK: - Step 8: Permissions

    private var permissionsStep: some View {
        onboardingCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionIntro(title: "打开关键系统权限", description: "不开也能用，但如果你希望它真的替你干活，这几项最好开上。")

                VStack(spacing: 12) {
                    ForEach(PermissionCapability.allCases) { cap in
                        permissionRow(cap)
                    }
                }

                HStack {
                    largeActionButton(title: "刷新状态", icon: "arrow.clockwise", prominence: .secondary) {
                        Task {
                            permissionStatus = await PermissionManager.shared.status()
                        }
                    }
                    .frame(width: 150)

                    Spacer()

                    Text("所有权限都可以稍后在系统设置里调整。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task {
            permissionStatus = await PermissionManager.shared.status()
        }
    }

    private func permissionRow(_ cap: PermissionCapability) -> some View {
        let granted = permissionStatus[cap] ?? false
        let isPending = pendingPermission == cap

        return HStack(spacing: 14) {
            Image(systemName: cap.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(granted ? .green : .secondary)
                .frame(width: 42, height: 42)
                .background((granted ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(cap.title)
                    .font(.headline)
                Text(cap.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                infoChip(text: "已授权", tint: .green)
            } else if isPending {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 96, height: 40)
            } else {
                largeActionButton(title: "去授权", icon: "arrow.up.forward.app", prominence: .primary) {
                    pendingPermission = cap
                    Task {
                        _ = await PermissionManager.shared.grant(cap)
                        try? await Task.sleep(for: .seconds(1))
                        permissionStatus = await PermissionManager.shared.status()
                        pendingPermission = nil
                    }
                }
                .frame(width: 128)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background((granted ? Color.green.opacity(0.05) : Color(nsColor: .controlBackgroundColor)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(granted ? Color.green.opacity(0.24) : Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Step 9: Ready

    private var readyStep: some View {
        onboardingCard(width: 620) {
            VStack(spacing: 22) {
                if appState.gatewayMode == .existingInstall {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 62))
                        .foregroundStyle(.green)
                    Text("一切就绪")
                        .font(.system(size: 30, weight: .bold))

                    VStack(spacing: 8) {
                        Text("已识别到你的 OpenClaw 配置")
                            .font(.title3.weight(.semibold))
                        Text("直接开始对话就行，原来的环境会继续接着跑。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    Text(agentEmoji)
                        .font(.system(size: 70))
                    Text(agentName)
                        .font(.system(size: 30, weight: .bold))

                    Text(readySummary)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)

                    Text("📱 iPhone 端可在 App Store 搜索「虾忙」下载，用来远程连接和继续处理你的任务。")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var readySummary: String {
        let style: String
        switch selectedPersonality {
        case "professional": style = "专业高效"
        case "warm": style = "温暖贴心"
        case "witty": style = "幽默毒舌"
        case "rational": style = "沉稳理性"
        default: style = "顺手"
        }

        let scenes = selectedScenarios.sorted().joined(separator: "、")
        if scenes.isEmpty {
            return "你的 \(style) AI 合伙人已经准备好，可以开始一起工作了。"
        }
        return "你的 \(style) AI 合伙人已经准备好，接下来可以陪你一起处理 \(scenes)。"
    }

    // MARK: - Shared UI

    private func onboardingCard<Content: View>(width: CGFloat = 720, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(30)
        .frame(maxWidth: width, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 24, y: 10)
    }

    private func sectionIntro(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.bold())
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    private func largeTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .padding(.horizontal, 18)
            .frame(height: 50)
            .background(Color(nsColor: .textBackgroundColor), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
    }

    private func selectionBackground(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.12), lineWidth: isSelected ? 1.5 : 1)
            )
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 2)
                .frame(width: 18, height: 18)
            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
            }
        }
    }

    private func selectionRow<Content: View>(isSelected: Bool, disabled: Bool = false, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selectionBackground(isSelected))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && !isSelected ? 0.6 : 1)
    }

    private enum ButtonProminence {
        case primary
        case secondary
    }

    private func largeActionButton(title: String, icon: String, prominence: ButtonProminence, tint: Color = .accentColor, action: @escaping () -> Void) -> some View {
        Group {
            if prominence == .primary {
                Button(action: action) {
                    Label(title, systemImage: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) {
                    Label(title, systemImage: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .buttonStyle(.bordered)
            }
        }
        .tint(tint)
        .controlSize(.large)
    }

    private func infoChip(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func instructionRow(number: Int, tint: Color, text: String, linkTitle: String? = nil, linkAction: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            stepBadge(number: number, tint: tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.callout)
                if let linkTitle, let linkAction {
                    Button(action: linkAction) {
                        Text(linkTitle)
                            .font(.caption)
                            .foregroundStyle(tint)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func authInputRow(
        placeholder: String,
        text: Binding<String>,
        tint: Color,
        isAuthenticated: Bool,
        state: AuthService.AuthState?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 18)
                .frame(height: 46)
                .background(Color(nsColor: .textBackgroundColor), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
                .disabled(isAuthenticated)

            Button(action: action) {
                switch state {
                case .verifying:
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 84)
                case .verified:
                    Label("已验证", systemImage: "checkmark.circle.fill")
                        .frame(width: 112)
                default:
                    Text("验证")
                        .frame(width: 92)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(isAuthenticated ? .green : tint)
            .controlSize(.large)
            .frame(height: 46)
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || currentAuthState == .verifying || isAuthenticated)
        }
    }
}

private struct ArrowNavigationButton: View {
    enum Direction {
        case back
        case forward

        var systemImage: String {
            switch self {
            case .back: return "arrow.left"
            case .forward: return "arrow.right"
            }
        }
    }

    let direction: Direction
    let disabled: Bool
    var highlight: Bool = false
    let action: () -> Void

    var body: some View {
        let isForwardHighlight = direction == .forward && highlight && !disabled

        Button(action: action) {
            Image(systemName: direction.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(disabled ? AnyShapeStyle(Color.secondary.opacity(0.55)) : AnyShapeStyle(isForwardHighlight ? Color.white : Color.primary))
                .frame(width: 56, height: 56)
                .background(
                    Circle()
                        .fill(disabled ? Color.secondary.opacity(0.08) : (isForwardHighlight ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                )
                .overlay(
                    Circle()
                        .stroke(disabled ? Color.secondary.opacity(0.10) : (isForwardHighlight ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.16)), lineWidth: 1)
                )
                .shadow(color: .black.opacity(disabled ? 0 : (isForwardHighlight ? 0.16 : 0.08)), radius: isForwardHighlight ? 16 : 12, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(direction == .back ? "上一步" : "下一步")
    }
}
