import SwiftUI

struct AIProviderSettingsView: View {
    let appState: AppState
    @Binding var isPresented: Bool
    @Environment(\.themeColor) private var themeColor

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

    @State private var authService = AuthService()
    @State private var selectedProvider: AuthService.Provider?
    @State private var apiKeyInput = ""
    @State private var setupTokenInput = ""
    @State private var activeAuthFlow: AuthFlow?

    private let authControlHeight: CGFloat = 44
    private let authControlCornerRadius: CGFloat = 14
    private let authActionMinWidth: CGFloat = 92
    private let authPrimaryButtonMinWidth: CGFloat = 178
    private let authSecondaryButtonMinWidth: CGFloat = 110

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
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选一个最顺手的 AI 大脑")
                        .font(.title3.bold())
                    Text("先选模型，再在同一页完成认证。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Content
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    // Left: provider list
                    VStack(spacing: 6) {
                        ForEach(providerOptions) { option in
                            providerRow(option)
                        }
                    }
                    .frame(width: selectedProvider == nil ? nil : 290, alignment: .leading)
                    .frame(maxWidth: selectedProvider == nil ? .infinity : nil)

                    // Right: auth content
                    if let provider = selectedProvider {
                        providerAuthContent(for: provider)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .frame(minWidth: selectedProvider == nil ? 500 : 820, minHeight: 500)
        .animation(.easeInOut(duration: 0.2), value: selectedProvider)
        .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                appState.gatewayManager.prepareForConfigChange()
                Task {
                    try? await Task.sleep(for: .milliseconds(1500))
                    isPresented = false
                    await appState.restartGateway()
                }
            }
        }
    }

    // MARK: - Provider Selection

    private func selectProvider(_ provider: AuthService.Provider) {
        guard !authService.isAuthenticated else { return }
        authService.reset()
        selectedProvider = nil
        apiKeyInput = ""
        setupTokenInput = ""
        activeAuthFlow = nil
        selectedProvider = provider
    }

    private func stateForActiveFlow(_ flow: AuthFlow) -> AuthService.AuthState? {
        activeAuthFlow == flow ? authService.state : nil
    }

    // MARK: - Provider Row

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

    // MARK: - Provider Auth Content

    @ViewBuilder
    private func providerAuthContent(for provider: AuthService.Provider) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch provider {
            case .anthropic:
                authMethodGroup(title: "使用浏览器创建 API Key") {
                    keyInputSection(provider: .anthropic, flow: .anthropicAPIKey)
                }
                authMethodGroup(title: "或者使用 Claude CLI Setup Token") {
                    setupTokenSection
                }
            case .openai:
                authMethodGroup(title: "先用 OpenAI 账号授权") {
                    openAIOAuthSection
                }
                authMethodGroup(title: "或者手动填写 API Key") {
                    keyInputSection(provider: .openai, flow: .openAIAPIKey)
                }
            case .minimax:
                authMethodGroup(title: "先用 MiniMax 账号授权") {
                    minimaxOAuthSection
                }
                authMethodGroup(title: "或者手动填写 API Key") {
                    minimaxKeyInputSection
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Auth Method Group

    private func authMethodGroup<Content: View>(title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
        )
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

            authFeedback(flow: flow, success: "API Key 已验证。")

            Text("API Key 只会保存在你的 Mac 上，不会上传到其他服务器。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
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
                        token: setupTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            )

            authFeedback(flow: .anthropicSetupToken, success: "Setup Token 已验证。")

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
                authActionButton(title: "使用 OpenAI 账号登录", icon: "person.crop.circle.badge.checkmark", tint: .green) {
                    activeAuthFlow = .openAIOAuth
                    authService.authenticateOpenAIOAuth()
                }
                .frame(maxWidth: 240, alignment: .leading)
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

                authActionButton(title: "打开浏览器", icon: "safari", tint: .green, prominence: .secondary) {
                    if let browserURL = URL(string: url) {
                        NSWorkspace.shared.open(browserURL)
                    }
                }
                .frame(maxWidth: 164, alignment: .leading)
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
                authActionButton(title: "重试", icon: "arrow.clockwise", tint: .green, prominence: .secondary) {
                    activeAuthFlow = .openAIOAuth
                    authService.authenticateOpenAIOAuth()
                }
                .frame(maxWidth: 120, alignment: .leading)
            case .modelSelection:
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

                    authActionButton(title: "确认模型", icon: "checkmark", tint: .green) {
                        guard let modelId = authService.selectedModelId else { return }
                        activeAuthFlow = .openAIOAuth
                        authService.persistOpenAIOAuthWithModel(modelId: modelId)
                    }
                    .frame(width: 136)

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(themeColor)
                        Text("请选择你要使用的模型")
                            .foregroundStyle(themeColor)
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - MiniMax Auth Sections

    private var minimaxKeyInputSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("输入 MiniMax API Key")
                .font(.headline)

            HStack(spacing: 4) {
                Text("可在")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link("platform.minimaxi.com", destination: URL(string: "https://platform.minimaxi.com")!)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .underline()
                Text("获取。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            authInputRow(
                placeholder: "粘贴你的 API Key",
                text: $apiKeyInput,
                tint: .orange,
                isAuthenticated: authService.isAuthenticated,
                state: stateForActiveFlow(.minimaxAPIKey),
                action: {
                    activeAuthFlow = .minimaxAPIKey
                    authService.persistMinimaxApiKey(
                        apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            )

            authFeedback(flow: .minimaxAPIKey, success: "API Key 已验证。")

            Text("API Key 只会保存在你的 Mac 上，不会上传到其他服务器。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var minimaxOAuthSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch stateForActiveFlow(.minimaxOAuth) ?? .idle {
            case .idle:
                authActionButton(title: "使用 MiniMax 账号登录", icon: "person.crop.circle.badge.checkmark", tint: .orange) {
                    activeAuthFlow = .minimaxOAuth
                    authService.authenticateMinimaxOAuth()
                }
                .frame(maxWidth: 240, alignment: .leading)
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

                authActionButton(title: "重新打开浏览器", icon: "safari", tint: .orange, prominence: .secondary) {
                    if let browserURL = URL(string: url) {
                        NSWorkspace.shared.open(browserURL)
                    }
                }
                .frame(maxWidth: 176, alignment: .leading)
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
                authActionButton(title: "重试", icon: "arrow.clockwise", tint: .orange, prominence: .secondary) {
                    activeAuthFlow = .minimaxOAuth
                    authService.authenticateMinimaxOAuth()
                }
                .frame(maxWidth: 120, alignment: .leading)
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
            HStack(spacing: 4) {
                Text("可在")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link("platform.moonshot.cn", destination: URL(string: "https://platform.moonshot.cn")!)
                    .font(.callout)
                    .foregroundStyle(themeColor)
                    .underline()
                Text("获取。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            authInputRow(
                placeholder: "粘贴你的 API Key",
                text: $apiKeyInput,
                tint: .blue,
                isAuthenticated: authService.isAuthenticated,
                state: stateForActiveFlow(.kimiAPIKey),
                action: {
                    activeAuthFlow = .kimiAPIKey
                    authService.persistMoonshotApiKey(
                        apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            )

            authFeedback(flow: .kimiAPIKey, success: "API Key 已验证。")

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
                        apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
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

                    authActionButton(title: "确认模型", icon: "checkmark", tint: tint) {
                        guard let modelId = authService.selectedModelId else { return }
                        activeAuthFlow = flow
                        authService.persistQwenWithSelectedModel(
                            apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                            modelId: modelId
                        )
                    }
                    .frame(width: 136)
                }
            }

            switch stateForActiveFlow(flow) {
            case .verified:
                authSuccessLabel("API Key 已验证。")
            case .modelSelection:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(themeColor)
                    Text("请选择你要使用的模型")
                        .foregroundStyle(themeColor)
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

    // MARK: - Shared UI Components

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

    private func selectionBackground(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isSelected ? themeColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? themeColor.opacity(0.75) : Color.secondary.opacity(0.12), lineWidth: isSelected ? 1.5 : 1)
            )
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(isSelected ? themeColor : Color.secondary.opacity(0.35), lineWidth: 2)
                .frame(width: 18, height: 18)
            if isSelected {
                Circle()
                    .fill(themeColor)
                    .frame(width: 8, height: 8)
            }
        }
    }

    private func infoChip(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private enum AuthActionProminence {
        case primary
        case secondary
    }

    private func authActionButton(
        title: String,
        icon: String,
        tint: Color,
        prominence: AuthActionProminence = .primary,
        action: @escaping () -> Void
    ) -> some View {
        let background = prominence == .primary ? tint.opacity(0.12) : Color(nsColor: .controlBackgroundColor)
        let border = prominence == .primary ? tint.opacity(0.24) : Color.secondary.opacity(0.14)
        let minWidth = prominence == .primary ? authPrimaryButtonMinWidth : authSecondaryButtonMinWidth

        return Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .foregroundStyle(Color.primary.opacity(0.92))
            }
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, prominence == .primary ? 16 : 14)
            .frame(minWidth: minWidth)
            .frame(height: authControlHeight)
            .background(background, in: RoundedRectangle(cornerRadius: authControlCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: authControlCornerRadius, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func authInputRow(
        placeholder: String,
        text: Binding<String>,
        tint: Color,
        isAuthenticated: Bool,
        state: AuthService.AuthState?,
        action: @escaping () -> Void
    ) -> some View {
        let isVerifying = state == .verifying
        let isVerified = isAuthenticated || state == .verified
        let actionTint = isVerified ? Color.green : tint
        let isDisabled = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifying || isAuthenticated

        return HStack(spacing: 0) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .padding(.leading, 16)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .disabled(isAuthenticated)

            Rectangle()
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 1)
                .padding(.vertical, 10)

            Button(action: action) {
                HStack(spacing: 6) {
                    if isVerifying {
                        ProgressView()
                            .controlSize(.small)
                    } else if isVerified {
                        Image(systemName: "checkmark.circle.fill")
                        Text("已验证")
                    } else {
                        Text("验证")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(actionTint)
                .frame(minWidth: authActionMinWidth)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 12)
                .background(actionTint.opacity(isDisabled && !isVerified ? 0.05 : 0.10))
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
        .frame(height: authControlHeight)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: authControlCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: authControlCornerRadius, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: authControlCornerRadius, style: .continuous))
    }
}
