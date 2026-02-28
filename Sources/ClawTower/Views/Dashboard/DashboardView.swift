import SwiftUI

struct DashboardView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                Text("Dashboard")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Placeholder cards
                HStack(spacing: 16) {
                    StatusCard(title: "Agent 状态", value: "—", icon: "cpu", color: .blue)
                    StatusCard(title: "今日对话", value: "—", icon: "bubble.left.and.bubble.right", color: .green)
                    StatusCard(title: "待办任务", value: "—", icon: "checklist", color: .orange)
                }

                Text("更多功能开发中...")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20)
        }
        .background(Color(.windowBackgroundColor))
    }
}

struct StatusCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
