import SwiftUI

struct SecondBrainView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain")
                .font(.system(size: 48))
                .foregroundStyle(.purple)
            Text("第二大脑")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("这是你的 AI 助手的记忆库，TA 会把重要的事情记在这里")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
