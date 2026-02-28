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

    private let totalSteps = 4

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
                case 1: providerStep
                case 2: personalizeStep
                case 3: readyStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: 500)

            Spacer()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("上一步") {
                        if currentStep == 1 {
                            authService.reset()
                            selectedProvider = nil
                            apiKeyInput = ""
                        }
                        currentStep -= 1
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if currentStep < totalSteps - 1 {
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
        case 1: return authService.isAuthenticated
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

    // MARK: - Step 1: Provider + Auth

    private var providerStep: some View {
        VStack(spacing: 20) {
            Text("连接你的 AI 大脑")
                .font(.title2.bold())
            Text("选择一个 AI 服务，粘贴你的 API Key")
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

            // Expanded instructions + key input for selected provider
            if let provider = selectedProvider {
                keyInputSection(provider: provider)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
