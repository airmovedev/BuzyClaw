import SwiftUI

@main
struct ClawTowerApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        Window("ClawTower", id: "main") {
            ContentView()
                .environment(appState)
        }

        MenuBarExtra("ClawTower", systemImage: "brain.head.profile") {
            MenuBarView()
                .environment(appState)
        }
    }
}
