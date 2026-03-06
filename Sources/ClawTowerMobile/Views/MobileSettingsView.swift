import SwiftUI
import CloudKit

struct MobileSettingsView: View {
    @Environment(CloudKitMessageClient.self) private var messageClient

    @State private var isTestingWrite = false
    @State private var isManualFetching = false
    @State private var isTestingDashboard = false

    var body: some View {
        NavigationStack {
            List {
                iCloudSection
                connectionSection
                agentSection
                cloudKitDebugSection
            }
            .navigationTitle("设置")
            .task {
                await messageClient.checkiCloudStatus()
            }
        }
    }

    // MARK: - iCloud Status

    private var iCloudSection: some View {
        Section("iCloud 账号") {
            HStack {
                Label("状态", systemImage: "icloud")
                Spacer()
                iCloudStatusBadge
            }

            HStack {
                Label("容器", systemImage: "shippingbox")
                Spacer()
                Text(CloudKitConstants.containerID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var iCloudStatusBadge: some View {
        switch messageClient.iCloudStatus {
        case .available:
            Label("已登录", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        case .noAccount:
            Label("未登录", systemImage: "xmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        case .restricted:
            Label("受限", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .couldNotDetermine:
            Label("检测中...", systemImage: "questionmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .temporarilyUnavailable:
            Label("暂不可用", systemImage: "clock")
                .font(.subheadline)
                .foregroundStyle(.orange)
        @unknown default:
            Label("未知", systemImage: "questionmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Connection Status

    private var connectionSection: some View {
        Section("连接状态") {
            HStack {
                Label("同步状态", systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                if messageClient.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("空闲")
                        .foregroundStyle(.secondary)
                }
            }

            if let lastSync = messageClient.lastSyncDate {
                HStack {
                    Label("上次同步", systemImage: "clock")
                    Spacer()
                    Text(lastSync, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = messageClient.lastError {
                HStack {
                    Label("错误", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label("消息数", systemImage: "number")
                Spacer()
                Text("\(messageClient.messages.count)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Agent Selection

    private var agentSection: some View {
        Section("Agent 选择") {
            HStack {
                Label("当前 Agent", systemImage: "person.circle")
                Spacer()
                Text(messageClient.selectedAgentId)
                    .foregroundStyle(.secondary)
            }

            Button("切换至 main") {
                messageClient.selectAgent("main")
            }
            .disabled(messageClient.selectedAgentId == "main")
        }
    }

    // MARK: - CloudKit Debug

    private var cloudKitDebugSection: some View {
        Section("CloudKit 调试") {
            debugRow("iCloud 状态", value: messageClient.debugICloudStatus)
            debugRow("Container ID", value: messageClient.debugContainerID)
            debugRow("SyncEngine 已初始化", value: messageClient.debugSyncEngineActive ? "✅ 是" : "❌ 否")
            debugRow("Zone 名称", value: CloudKitConstants.zoneName)
            debugRow("Record Type", value: MessageRecord.recordType)
            debugRow("最近 Fetch 结果", value: messageClient.debugLastFetchResult)
            debugRow("获取记录数", value: "\(messageClient.debugRecordCount)")

            if let fetchTime = messageClient.debugLastFetchTime {
                HStack {
                    Text("最近 Fetch 时间")
                        .font(.caption)
                    Spacer()
                    Text(fetchTime, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = messageClient.debugLastError {
                HStack(alignment: .top) {
                    Text("最近错误")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                }
            }

            if let testResult = messageClient.debugTestWriteResult {
                HStack(alignment: .top) {
                    Text("测试写入结果")
                        .font(.caption)
                    Spacer()
                    Text(testResult)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            Button {
                isManualFetching = true
                Task {
                    await messageClient.debugManualFetch()
                    isManualFetching = false
                }
            } label: {
                HStack {
                    Label("手动刷新", systemImage: "arrow.clockwise")
                    if isManualFetching {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isManualFetching)

            // CloudKit 环境信息
            debugRow("Default Container", value: CKContainer.default().containerIdentifier ?? "nil")
            debugRow("Zone ID", value: CloudKitConstants.zoneID.zoneName)
            debugRow("Dashboard Record ID", value: DashboardSnapshotRecord.recordID.recordName)

            // 测试读取 Dashboard
            Button {
                isTestingDashboard = true
                Task {
                    await messageClient.debugFetchDashboard()
                    isTestingDashboard = false
                }
            } label: {
                HStack {
                    Label("测试读取 Dashboard", systemImage: "icloud.and.arrow.down")
                    if isTestingDashboard {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isTestingDashboard)

            HStack(alignment: .top) {
                Text("Dashboard 结果")
                    .font(.caption)
                Spacer()
                Text(messageClient.debugDashboardResult)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Button {
                isTestingWrite = true
                Task {
                    await messageClient.debugTestWrite()
                    isTestingWrite = false
                }
            } label: {
                HStack {
                    Label("测试写入", systemImage: "square.and.pencil")
                    if isTestingWrite {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isTestingWrite)
        }
    }

    private func debugRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
