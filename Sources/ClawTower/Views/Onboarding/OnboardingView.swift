import SwiftUI

struct OnboardingView: View {
    let appState: AppState
    @State private var currentStep = 0
    @State private var agentName = "Assistant"
    @State private var agentEmoji = "🤖"
    @State private var userName = ""

    @State private var authService = AuthService()
    @State private var selectedProvider: String?
    @State private var showManualKey = false
    @State private var manualAPIKey = ""
    @State private var manualProvider = "anthropic"

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
                        if currentStep == 2 || currentStep == 1 {
                            authService.cancel()
                            selectedProvider = nil
                            showManualKey = false
                            manualAPIKey = ""
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
        .frame(minWidth: 600, minHeight: 450)
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
            Text("选择一个 AI 服务开始认证")
                .foregroundStyle(.secondary)

            // Provider cards
            HStack(spacing: 16) {
                providerCard(
                    id: "claude",
                    name: "Claude",
                    subtitle: "Anthropic",
                    icon: "brain.head.profile",
                    tint: .purple
                )
                providerCard(
                    id: "openai",
                    name: "ChatGPT",
                    subtitle: "OpenAI",
                    icon: "bubble.left.and.bubble.right",
                    tint: .green
                )
            }

            // Auth flow area
            if selectedProvider != nil || showManualKey {
                authFlowSection
            }

            // Manual key link
            if !showManualKey && !authService.isAuthenticated {
                Button("我有 API Key，手动输入") {
                    authService.cancel()
                    selectedProvider = nil
                    showManualKey = true
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
    }

    private func providerCard(
        id: String,
        name: String,
        subtitle: String,
        icon: String,
        tint: Color
    ) -> some View {
        Button {
            guard !authService.isAuthenticated else { return }
            showManualKey = false
            manualAPIKey = ""
            selectedProvider = id
            authService.cancel()
            if id == "claude" {
                authService.authenticateClaude(openclawPath: appState.openclawPath)
            } else {
                authService.authenticateOpenAI(openclawPath: appState.openclawPath)
            }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundStyle(tint)
                Text(name)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selectedProvider == id ? tint.opacity(0.1) : Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selectedProvider == id ? tint : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .disabled(authService.isAuthenticated)
    }

    // MARK: - Auth Flow Section

    @ViewBuilder
    private var authFlowSection: some View {
        if showManualKey {
            manualKeySection
        } else {
            authProgressSection
        }
    }

    private var authProgressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status header
            HStack(spacing: 8) {
                switch authService.state {
                case .idle:
                    EmptyView()
                case .authenticating:
                    ProgressView()
                        .controlSize(.small)
                    Text("正在初始化认证…")
                        .foregroundStyle(.secondary)
                case .waitingForUser(let url):
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("请在浏览器中完成认证")
                            .foregroundStyle(.secondary)
                        if let url, let linkURL = URL(string: url) {
                            Link(url, destination: linkURL)
                                .font(.caption)
                        }
                    }
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                    Text("认证成功！")
                        .font(.headline)
                        .foregroundStyle(.green)
                case .error(let message):
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("认证失败")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Retry button on error
            if case .error = authService.state, let provider = selectedProvider {
                Button("重试") {
                    if provider == "claude" {
                        authService.authenticateClaude(openclawPath: appState.openclawPath)
                    } else {
                        authService.authenticateOpenAI(openclawPath: appState.openclawPath)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Terminal output
            if !authService.outputLines.isEmpty {
                terminalOutput
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.textBackgroundColor).opacity(0.5))
        )
    }

    private var terminalOutput: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(authService.outputLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 100)
            .onChange(of: authService.outputLines.count) {
                if let last = authService.outputLines.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Manual Key

    private var manualKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("服务商", selection: $manualProvider) {
                Text("Anthropic (Claude)").tag("anthropic")
                Text("OpenAI (ChatGPT)").tag("openai")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            SecureField("粘贴你的 API Key", text: $manualAPIKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("确认") {
                    guard !manualAPIKey.isEmpty else { return }
                    authService.pasteToken(
                        openclawPath: appState.openclawPath,
                        provider: manualProvider,
                        apiKey: manualAPIKey
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(manualAPIKey.isEmpty)

                if authService.isAuthenticated {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("已验证")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                if case .error(let msg) = authService.state {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(msg)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Text("API Key 会通过 openclaw 安全存储")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.textBackgroundColor).opacity(0.5))
        )
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
