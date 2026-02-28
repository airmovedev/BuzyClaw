import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var apiKey = ""
    @State private var gatewayPort = "18789"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("设置")
                    .font(.largeTitle.bold())

                // Gateway Status
                GroupBox("Gateway 状态") {
                    HStack {
                        Circle()
                            .fill(appState.gatewayManager.isConnected ? .green : .red)
                            .frame(width: 10, height: 10)
                        Text(appState.gatewayManager.statusText)
                        Spacer()
                        Button("重新连接") {
                            appState.gatewayManager.connect()
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

                // Gateway Port
                GroupBox("高级设置") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Gateway 端口")
                            .font(.headline)
                        TextField("18789", text: $gatewayPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
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
}
