import SwiftUI

struct CronJobsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock")
                .font(.system(size: 48))
                .foregroundStyle(.teal)
            Text("定时任务")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("管理 Agent 的定时任务")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
