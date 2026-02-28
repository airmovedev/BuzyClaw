import SwiftUI

struct SkillsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece")
                .font(.system(size: 48))
                .foregroundStyle(.indigo)
            Text("Skills")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("管理 Agent 的能力和工具")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
