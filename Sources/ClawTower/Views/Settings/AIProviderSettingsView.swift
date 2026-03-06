import SwiftUI

struct AIProviderSettingsView: View {
    let appState: AppState
    @Binding var isPresented: Bool

    @State private var authService = AuthService()
    @State private var selectedProvider: AuthService.Provider?
    @State private var apiKeyInput = ""
    @State private var setupTokenInput = ""
    @State private var claudeAuthMethod = 0

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
            HStack(spacing: 16) {
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
            }

            if let provider = selectedProvider {
                if provider == .anthropic {
                    anthropicSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    openaiSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Spacer()
        }
        .padding(24)
        .animation(.easeInOut(duration: 0.2), value: selectedProvider)
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
                case .waitingForBrowser:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("请在浏览器中完成登录...").foregroundStyle(.secondary)
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
