import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Circle()
                .fill(appState.gatewayManager.status.statusColor)
                .frame(width: 8, height: 8)
            Text("ClawTower — \(appState.gatewayManager.status.displayText)")
        }

        Divider()

        Button("打开主窗口") {
            openWindow(id: "main")
        }
        .keyboardShortcut("o")

        Divider()

        Button("退出 ClawTower") {
            appState.stopGateway()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
