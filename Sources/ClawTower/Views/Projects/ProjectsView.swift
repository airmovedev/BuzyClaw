import SwiftUI

struct ProjectsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("项目")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("管理 Agent 的项目产出")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
