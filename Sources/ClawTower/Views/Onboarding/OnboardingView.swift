import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var currentStep = 0

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 4) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Capsule()
                        .fill(step <= currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)

            // Step content
            Group {
                switch currentStep {
                case 0: WelcomeStep()
                case 1: AIAccountStep()
                case 2: AssistantSetupStep()
                case 3: PermissionsStep()
                case 4: InitializationStep()
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.slide)

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("上一步") {
                        withAnimation { currentStep -= 1 }
                    }
                }

                Spacer()

                if currentStep < totalSteps - 1 {
                    Button("下一步") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("开始使用") {
                        appState.completeOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        .frame(width: 600, height: 450)
    }
}

// MARK: - Step Views

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            Text("你的私人 AI 助手，就在 Mac 上")
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "desktopcomputer", text: "AI 助手，私密运行在你的 Mac 上")
                FeatureRow(icon: "lock.shield", text: "数据不上传，只属于你")
                FeatureRow(icon: "iphone", text: "iPhone 远程控制，随时随地")
            }
            .padding(.horizontal, 40)
        }
    }
}

private struct AIAccountStep: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("连接你的 AI 大脑")
                .font(.title2)
                .fontWeight(.bold)

            Text("选择一个 AI 服务")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                ProviderButton(name: "Claude", description: "由 Anthropic 提供", icon: "sparkle")
                ProviderButton(name: "ChatGPT", description: "由 OpenAI 提供", icon: "bubble.left.and.text.bubble.right")
                ProviderButton(name: "使用 API Key", description: "高级用户", icon: "key")
            }
            .padding(.horizontal, 40)
        }
    }
}

private struct AssistantSetupStep: View {
    @State private var agentName = "William"
    @State private var userName = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("认识你的 AI 助手")
                .font(.title2)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading) {
                    Text("TA 叫什么？")
                        .font(.headline)
                    TextField("助手名字", text: $agentName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading) {
                    Text("选一个代表 TA 的 emoji")
                        .font(.headline)
                    HStack(spacing: 12) {
                        ForEach(["🦉", "🐱", "🤖", "🧙", "🦊", "🐸", "⚡"], id: \.self) { emoji in
                            Text(emoji)
                                .font(.title)
                                .padding(6)
                                .background(.background.secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                VStack(alignment: .leading) {
                    Text("TA 该怎么称呼你？")
                        .font(.headline)
                    TextField("你的昵称", text: $userName)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.horizontal, 40)
        }
    }
}

private struct PermissionsStep: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("让助手帮你更多")
                .font(.title2)
                .fontWeight(.bold)

            Text("以下权限均可选，随时可在设置中更改")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                PermissionRow(icon: "folder", title: "文件管理", description: "让助手帮你整理文件")
                PermissionRow(icon: "calendar", title: "日历", description: "让助手查看和管理你的日程")
                PermissionRow(icon: "checklist", title: "提醒事项", description: "让助手帮你管理待办事项")
            }
            .padding(.horizontal, 40)
        }
    }
}

private struct InitializationStep: View {
    @State private var progress = 0.0

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .scaleEffect(2)

            Text(progress < 1.0 ? "正在唤醒你的 AI 助手..." : "准备好了！")
                .font(.title2)
                .fontWeight(.bold)

            Text(progress < 1.0 ? "快好了..." : "点击「开始使用」进入主界面")
                .foregroundStyle(.secondary)
        }
        .task {
            for i in 1...10 {
                try? await Task.sleep(for: .milliseconds(300))
                progress = Double(i) / 10.0
            }
        }
    }
}

// MARK: - Shared Components

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            Text(text)
        }
    }
}

private struct ProviderButton: View {
    let name: String
    let description: String
    let icon: String

    var body: some View {
        Button(action: {}) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 24)
                VStack(alignment: .leading) {
                    Text(name).fontWeight(.medium)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    @State private var granted = false

    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading) {
                Text(title).fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(granted ? "已授权" : "授权") {
                granted = true
            }
            .buttonStyle(.bordered)
            .disabled(granted)
        }
        .padding(8)
    }
}
