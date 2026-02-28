import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var apiKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("设置")
                    .font(.largeTitle.bold())

                // Gateway Status
                GroupBox("Gateway 状态") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                            Text(appState.gatewayManager.statusText)
                            Spacer()
                            Button("重启") {
                                Task { await appState.restartGateway() }
                            }
                        }

                        if appState.gatewayManager.isRunning {
                            HStack(spacing: 16) {
                                Label("端口: \(appState.gatewayManager.port)", systemImage: "network")
                                if let pid = appState.gatewayManager.pid {
                                    Label("PID: \(pid)", systemImage: "gearshape")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }

                // AI Account
                GroupBox("AI 账号") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key")
                            .font(.headline)
                        SecureField("输入 API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        Text("存储在 macOS 钥匙串中，安全加密")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                // About
                GroupBox("关于") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ClawTower v1.0.0")
                        Text("基于 OpenClaw 开源项目")
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
            }
            .padding(20)
        }
        .background(Color(.windowBackgroundColor))
    }

    private var statusColor: Color {
        switch appState.gatewayManager.state {
        case .running: return .green
        case .starting: return .orange
        case .stopped: return .gray
        case .error: return .red
        }
    }
}
