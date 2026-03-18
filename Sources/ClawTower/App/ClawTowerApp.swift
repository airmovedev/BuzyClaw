import SwiftUI
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set ourselves as delegate for the main window to intercept close
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.delegate = self
                window.isReleasedWhenClosed = false
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = NSApp.windows.first(where: { $0.className != "NSStatusBarWindow" && !$0.className.contains("MenuBarExtra") }) {
                window.isReleasedWhenClosed = false
                if window.delegate == nil { window.delegate = self }
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.stopGateway()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.hide(nil)
        return false
    }
}

@main
struct ClawTowerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("app.name", id: "main") {
            ContentView(appDelegate: appDelegate)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1000, height: 700)

        MenuBarExtra("app.name", image: "favicon") {
            Button("menu.open") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.className != "NSStatusBarWindow" && !$0.className.contains("MenuBarExtra") }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            Divider()
            Button("menu.quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
