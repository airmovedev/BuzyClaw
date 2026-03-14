import SwiftUI

struct AIProviderSettingsView: View {
    let appState: AppState
    @Binding var isPresented: Bool

    @State private var authService = AuthService()
    @State private var selectedProvider: AuthService.Provider?
    @State private var apiKeyInput = ""
    @State private var setupTokenInput = ""
    @State private var claudeAuthMethod = 0
    @State private var minimaxAuthMethod = 0

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("配置 AI 服务")
                    .font(.title2.bold())
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }

            Text("选择一个 AI 服务来连接")
                .foregroundStyle(.secondary)

            // Provider cards
            let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
            LazyVGrid(columns: columns, spacing: 16) {
                providerCard(
                    provider: .anthropic,
                    name: "Claude",
                    subtitle: "Anthropic",
                    icon: "brain.head.profile",
                    tint: .purple
                )
                providerCard(
                    provider: .openai,
                    name: "ChatGPT",
                    subtitle: "OpenAI",
                    icon: "bubble.left.and.bubble.right",
                    tint: .green
                )
                providerCard(
                    provider: .minimax,
                    name: "MiniMax",
                    subtitle: "MiniMax",
                    icon: "sparkles",
                    tint: .orange
                )
                providerCard(
                    provider: .kimi,
                    name: "Kimi",
                    subtitle: "Moonshot AI",
                    icon: "moon.stars",
                    tint: .blue
                )
                providerCard(
                    provider: .zai,
                    name: "智谱 GLM",
                    subtitle: "Z.AI",
                    icon: "text.word.spacing",
                    tint: .cyan
                )
                providerCard(
                    provider: .qwen,
                    name: "通义千问",
                    subtitle: "Alibaba",
                    icon: "cloud",
                    tint: .indigo
                )
                providerCard(
                    provider: .google,
                    name: "Gemini",
                    subtitle: "Google",
                    icon: "globe",
                    tint: .red
                )
                providerCard(
                    provider: .xai,
                    name: "Grok",
                    subtitle: "xAI",
                    icon: "bolt",
                    tint: .gray
                )
                providerCard(
                    provider: .openrouter,
                    name: "OpenRouter",
                    subtitle: "多模型路由",
                    icon: "arrow.triangle.branch",
                    tint: .mint
                )
            }

            if let provider = selectedProvider {
                Group {
                    switch provider {
                    case .anthropic:
                        anthropicSection
                    case .openai:
                        openaiSection
                    case .minimax:
                        minimaxSection
                    case .kimi:
                        kimiSection
                    case .zai:
                        genericApiKeySection(provider: .zai, providerName: "Z.AI", consoleName: "open.bigmodel.cn", consoleURL: "https://open.bigmodel.cn", tint: .cyan)
                    case .qwen:
                        genericApiKeySection(provider: .qwen, providerName: "通义千问", consoleName: "dashscope.console.aliyun.com", consoleURL: "https://dashscope.console.aliyun.com", tint: .indigo)
                    case .google:
                        genericApiKeySection(provider: .google, providerName: "Google Gemini", consoleName: "ai.google.dev", consoleURL: "https://ai.google.dev", tint: .red)
                    case .xai:
                        genericApiKeySection(provider: .xai, providerName: "xAI (Grok)", consoleName: "console.x.ai", consoleURL: "https://console.x.ai", tint: .gray)
                    case .openrouter:
                        genericApiKeySection(provider: .openrouter, providerName: "OpenRouter", consoleName: "openrouter.ai/keys", consoleURL: "https://openrouter.ai/keys", tint: .mint)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer()
        }
        .padding(24)
        .animation(.easeInOut(duration: 0.2), value: selectedProvider)
        .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                // Config was written to openclaw.json — restart gateway so it picks up new provider/model.
                // prepareForConfigChange() resets crash counters in case OpenClaw auto-restarted
                // from detecting the file change before we explicitly restart.
                appState.gatewayManager.prepareForConfigChange()
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    await appState.restartGateway()
                }
            }
        }
    }

    // MARK: - Provider Card

    private func providerCard(provider: AuthService.Provider, name: String, subtitle: String, icon: String, tint: Color) -> some View {
        let isSelected = selectedProvider == provider
        return Button {
            guard !authService.isAuthenticated else { return }
            authService.reset()
            apiKeyInput = ""
            setupTokenInput = ""
            selectedProvider = provider
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(tint)
                Text(name).font(.title3.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? tint.opacity(0.1) : Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? tint : .clear, lineWidth: 2)
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

    // MARK: - Anthropic Section

    private var anthropicSection: some View {
        VStack(spacing: 16) {
            Picker("认证方式", selection: $claudeAuthMethod) {
                Text("API Key").tag(0)
                Text("Setup Token").tag(1)
            }
            .pickerStyle(.segmented)
            .disabled(authService.isAuthenticated)
            .onChange(of: claudeAuthMethod) {
                if !authService.isAuthenticated { authService.reset() }
            }

            if claudeAuthMethod == 0 {
                keyInputSection(provider: .anthropic, tint: .purple)
            } else {
                setupTokenSection
            }
        }
    }

    // MARK: - Setup Token Section

    private var setupTokenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("通过 Setup Token 连接：")
                .font(.headline)

            Text("在终端运行 `claude setup-token`，复制获得的 Token 粘贴到下方")
                .font(.callout)
                .foregroundStyle(.secondary)

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
                        ProgressView().controlSize(.small).frame(width: 60)
                    case .verified:
                        Label("已验证", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    default:
                        Text("验证")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(authService.isAuthenticated ? .green : .purple)
                .disabled(setupTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authService.state == .verifying || authService.isAuthenticated)
            }

            authStatusMessage
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.textBackgroundColor).opacity(0.5)))
    }

    // MARK: - OpenAI Section

    private var openaiSection: some View {
        VStack(spacing: 16) {
            keyInputSection(provider: .openai, tint: .green)

            Divider()

            VStack(spacing: 12) {
                Text("或者").foregroundStyle(.secondary).font(.callout)

                switch authService.state {
                case .waitingForBrowser(let url):
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("请在浏览器中完成登录...").foregroundStyle(.secondary)
                        }

                        Button("打开浏览器") {
                            if let browserURL = URL(string: url) {
                                NSWorkspace.shared.open(browserURL)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                        .controlSize(.small)
                    }
                case .verified:
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("授权成功").foregroundStyle(.green)
                    }
                default:
                    Button("使用 OpenAI 账号登录") {
                        authService.authenticateOpenAIOAuth()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(authService.isAuthenticated)
                }
            }
        }
    }

    // MARK: - MiniMax Section

    private var minimaxSection: some View {
        VStack(spacing: 16) {
            Picker("认证方式", selection: $minimaxAuthMethod) {
                Text("API Key").tag(0)
                Text("OAuth 登录").tag(1)
            }
            .pickerStyle(.segmented)
            .disabled(authService.isAuthenticated)
            .onChange(of: minimaxAuthMethod) {
                if !authService.isAuthenticated { authService.reset() }
            }

            if minimaxAuthMethod == 0 {
                minimaxKeySection
            } else {
                minimaxOAuthSection
            }
        }
    }

    private var minimaxKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    authService.persistMinimaxApiKey(apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    switch authService.state {
                    case .verifying:
                        ProgressView().controlSize(.small).frame(width: 60)
                    case .verified:
                        Label("已验证", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    default:
                        Text("验证")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(authService.isAuthenticated ? .green : .orange)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authService.state == .verifying || authService.isAuthenticated)
            }

            authStatusMessage

            Text("API Key 仅存储在你的 Mac 上，不会上传到任何服务器")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.textBackgroundColor).opacity(0.5)))
    }

    private var minimaxOAuthSection: some View {
        VStack(spacing: 16) {
            switch authService.state {
            case .idle:
                Button("使用 MiniMax 账号登录") {
                    authService.authenticateMinimaxOAuth()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            case .launching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在请求授权...").foregroundStyle(.secondary)
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
                        Text("等待授权...").foregroundStyle(.secondary)
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
            case .waitingForBrowser:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("请在浏览器中完成登录...").foregroundStyle(.secondary)
                }
                .font(.callout)
            case .verified:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("授权成功").foregroundStyle(.green)
                }
                .font(.callout)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        isPresented = false
                    }
                }
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("验证中...").foregroundStyle(.secondary)
                }
                .font(.callout)
            case .error(let message):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(message).foregroundStyle(.red)
                }
                .font(.caption)

                Button("重试") {
                    authService.authenticateMinimaxOAuth()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            case .modelSelection:
                EmptyView()
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.textBackgroundColor).opacity(0.5)))
    }

    // MARK: - Kimi Section

    private var kimiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    authService.persistMoonshotApiKey(apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    switch authService.state {
                    case .verifying:
                        ProgressView().controlSize(.small).frame(width: 60)
                    case .verified:
                        Label("已验证", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    default:
                        Text("验证")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(authService.isAuthenticated ? .green : .blue)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authService.state == .verifying || authService.isAuthenticated)
            }

            authStatusMessage

            Text("API Key 仅存储在你的 Mac 上，不会上传到任何服务器")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.textBackgroundColor).opacity(0.5)))
    }

    // MARK: - Generic API Key Section

    private func genericApiKeySection(provider: AuthService.Provider, providerName: String, consoleName: String, consoleURL: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    authService.persistGenericApiKey(provider: provider, apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    switch authService.state {
                    case .verifying:
                        ProgressView().controlSize(.small).frame(width: 60)
                    case .verified:
                        Label("已验证", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
                        authService.persistQwenWithSelectedModel(apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines), modelId: modelId)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                }
            }

            authStatusMessage

            Text("API Key 仅存储在你的 Mac 上，不会上传到任何服务器")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.textBackgroundColor).opacity(0.5)))
    }

    // MARK: - Key Input

    private func keyInputSection(provider: AuthService.Provider, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("输入 API Key：")
                .font(.headline)

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
                        ProgressView().controlSize(.small).frame(width: 60)
                    case .verified:
                        Label("已验证", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    default:
                        Text("验证")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(authService.isAuthenticated ? .green : tint)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authService.state == .verifying || authService.isAuthenticated)
            }

            authStatusMessage

            Text("API Key 仅存储在你的 Mac 上，不会上传到任何服务器")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.textBackgroundColor).opacity(0.5)))
    }

    // MARK: - Auth Status

    @ViewBuilder
    private var authStatusMessage: some View {
        switch authService.state {
        case .verified:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("验证成功！").foregroundStyle(.green)
            }
            .font(.caption)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    isPresented = false
                }
            }
        case .error(let message):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(message).foregroundStyle(.red)
            }
            .font(.caption)
        default:
            EmptyView()
        }
    }
}
