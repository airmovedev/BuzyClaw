import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var apiKey: String = ""
    @State private var saveConfirmation = false

    var body: some View {
        Form {
            Section("AI 账号") {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("保存") {
                        appState.saveAPIKey(apiKey)
                        saveConfirmation = true
                    }
                    .disabled(apiKey.isEmpty)

                    if saveConfirmation {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
            }

            Section("Gateway 状态") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.gatewayManager.status.statusColor)
                        .frame(width: 10, height: 10)
                    Text(appState.gatewayManager.status.displayText)
                        .font(.headline)
                }

                if case .running(let port) = appState.gatewayManager.status {
                    LabeledContent("端口", value: "\(port)")
                }

                HStack(spacing: 12) {
                    Button("启动") {
                        Task { await appState.startGateway() }
                    }
                    .disabled(appState.gatewayManager.status.isRunning)

                    Button("停止") {
                        appState.stopGateway()
                    }
                    .disabled(!appState.gatewayManager.status.isRunning)

                    Button("重启") {
                        Task { await appState.gatewayManager.restart() }
                    }
                }
            }

            Section("数据") {
                LabeledContent("数据目录") {
                    Text("~/Library/Application Support/ClawTower/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("关于") {
                LabeledContent("版本", value: "0.1.0")
                LabeledContent("基于", value: "OpenClaw 开源项目")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .onAppear {
            apiKey = appState.loadAPIKey()
        }
    }
}
