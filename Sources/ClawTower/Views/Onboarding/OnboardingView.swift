import SwiftUI

struct OnboardingView: View {
    let appState: AppState
    @State private var currentStep = 0
    @State private var apiKey = ""
    @State private var agentName = "Assistant"
    @State private var agentEmoji = "🤖"
    @State private var userName = ""
    @State private var selectedProvider = "claude"

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            // Progress
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
                    Button("上一步") { currentStep -= 1 }
                        .buttonStyle(.plain)
                }
                Spacer()
                if currentStep < totalSteps - 1 {
                    Button("下一步") { currentStep += 1 }
                        .buttonStyle(.borderedProminent)
                        .disabled(currentStep == 1 && apiKey.isEmpty)
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

    // MARK: - Steps

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

    private var providerStep: some View {
        VStack(spacing: 20) {
            Text("连接你的 AI 大脑")
                .font(.title2.bold())
            Text("选择一个 AI 服务")
                .foregroundStyle(.secondary)

            Picker("Provider", selection: $selectedProvider) {
                Text("Claude (Anthropic)").tag("claude")
                Text("ChatGPT (OpenAI)").tag("openai")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key")
                    .font(.headline)
                SecureField("输入你的 API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("API Key 会安全地存储在你的 Mac 钥匙串中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

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
