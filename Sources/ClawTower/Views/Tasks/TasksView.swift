import SwiftUI

struct TasksView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("任务")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("查看和管理 Agent 任务")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
