import SwiftUI

struct MobileSettingsView: View {
    @Environment(DashboardSnapshotStore.self) private var snapshotStore

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                aboutSection
            }
            .navigationTitle("设置")
        }
    }

    // MARK: - Connection Status

    private var connectionSection: some View {
        Section("连接状态") {
            HStack {
                Label("电脑端", systemImage: "desktopcomputer")
                Spacer()
                if snapshotStore.isMacOSConnected {
                    Label("已连接", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else {
                    Label("未连接", systemImage: "bolt.slash.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("说明")
                Spacer()
                Text("与虾忙 macOS 版配合使用")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("版权")
                Spacer()
                Text("© AIRGO LIMITED")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
