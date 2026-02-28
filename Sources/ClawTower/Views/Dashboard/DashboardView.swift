import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Dashboard")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                HStack(spacing: 16) {
                    StatusCard(
                        title: "Gateway",
                        value: appState.gatewayManager.status.displayText,
                        color: appState.gatewayManager.status.statusColor,
                        icon: "server.rack"
                    )

                    StatusCard(
                        title: "对话",
                        value: "0 条",
                        color: .blue,
                        icon: "bubble.left.and.bubble.right"
                    )

                    StatusCard(
                        title: "任务",
                        value: "0 个",
                        color: .orange,
                        icon: "checklist"
                    )
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatusCard: View {
    let title: String
    let value: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
        }
        .padding()
        .frame(minWidth: 160, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
