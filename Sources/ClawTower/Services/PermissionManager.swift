import AppKit
import AVFoundation
import EventKit
import ScreenCaptureKit
import UserNotifications

// MARK: - PermissionCapability

enum PermissionCapability: String, CaseIterable, Identifiable, Hashable, Sendable {
    case calendar
    case reminders
    case accessibility
    case notifications
    case screenRecording
    case microphone
    case camera

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "日历"
        case .reminders: "提醒事项"
        case .accessibility: "辅助功能"
        case .notifications: "通知"
        case .screenRecording: "录屏与截屏"
        case .microphone: "麦克风"
        case .camera: "摄像头"
        }
    }

    var subtitle: String {
        switch self {
        case .calendar: "让 AI 查看和管理你的日程安排"
        case .reminders: "让 AI 帮你创建和管理待办事项"
        case .accessibility: "让 AI 自动化操作系统级任务"
        case .notifications: "接收 AI 任务完成或重要事件的提醒"
        case .screenRecording: "让 AI 看到你的屏幕内容以提供帮助"
        case .microphone: "让 AI 听到你的语音指令"
        case .camera: "让 AI 通过摄像头获取视觉信息"
        }
    }

    var icon: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .accessibility: "accessibility"
        case .notifications: "bell.badge"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .microphone: "mic"
        case .camera: "camera"
        }
    }
}

// MARK: - Accessibility helper (concurrency-safe)

/// Wraps `AXIsProcessTrustedWithOptions` so it can be called from `@MainActor` without
/// tripping Swift 6's strict-concurrency check on the global `kAXTrustedCheckOptionPrompt`.
private nonisolated func axIsProcessTrustedFresh() -> Bool {
    // The string value of kAXTrustedCheckOptionPrompt is "AXTrustedCheckOptionPrompt"
    let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

// MARK: - PermissionManager

@MainActor
final class PermissionManager: Sendable {
    static let shared = PermissionManager()
    private init() {}

    func status() async -> [PermissionCapability: Bool] {
        var result: [PermissionCapability: Bool] = [:]
        for cap in PermissionCapability.allCases {
            result[cap] = await checkPermission(cap)
        }
        return result
    }

    /// Request or open system settings for a capability.
    @discardableResult
    func grant(_ capability: PermissionCapability) async -> Bool {
        switch capability {
        case .calendar:
            let ekStatus = EKEventStore.authorizationStatus(for: .event)
            if ekStatus == .notDetermined {
                let granted = await requestCalendarAccess()
                return granted
            } else {
                openSystemSettings(for: capability)
                return await waitForPermission(capability)
            }
        case .reminders:
            let ekStatus = EKEventStore.authorizationStatus(for: .reminder)
            if ekStatus == .notDetermined {
                let granted = await requestRemindersAccess()
                return granted
            } else {
                openSystemSettings(for: capability)
                return await waitForPermission(capability)
            }
        case .accessibility:
            openSystemSettings(for: capability)
            return await waitForPermission(capability)
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                let granted = await requestNotificationAccess()
                return granted
            } else {
                openSystemSettings(for: capability)
                return await waitForPermission(capability)
            }
        case .screenRecording:
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
                return await waitForPermission(capability)
            }
            return true
        case .microphone:
            let avStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if avStatus == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                return granted
            } else {
                openSystemSettings(for: capability)
                return await waitForPermission(capability)
            }
        case .camera:
            let avStatus = AVCaptureDevice.authorizationStatus(for: .video)
            if avStatus == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                return granted
            } else {
                openSystemSettings(for: capability)
                return await waitForPermission(capability)
            }
        }
    }

    // MARK: - Private

    private func checkPermission(_ cap: PermissionCapability) async -> Bool {
        switch cap {
        case .calendar:
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders:
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        case .accessibility:
            return axIsProcessTrustedFresh()
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return settings.authorizationStatus == .authorized
        case .screenRecording:
            return await checkScreenRecordingPermission()
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .camera:
            return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }

    /// Checks screen recording permission by attempting to enumerate shareable content.
    /// `CGPreflightScreenCaptureAccess()` can return false positives on fresh installs
    /// before the app has been added to the TCC database. Using `SCShareableContent`
    /// is more reliable: it requires actual screen recording permission to return
    /// window information from other apps.
    private func checkScreenRecordingPermission() async -> Bool {
        // Quick gate: if CGPreflight says no, it's definitely not granted
        guard CGPreflightScreenCaptureAccess() else { return false }

        // CGPreflight said yes — verify with SCShareableContent to avoid false positives
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            // If we can see windows from other apps, permission is truly granted.
            // On a fresh install without permission, this call throws an error.
            let ownBundleID = Bundle.main.bundleIdentifier ?? ""
            let otherAppWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier != ownBundleID }
            return !otherAppWindows.isEmpty
        } catch {
            // SCShareableContent throws when screen recording is not authorized
            return false
        }
    }

    private func requestCalendarAccess() async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    private func requestRemindersAccess() async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    private func requestNotificationAccess() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Wait for the user to toggle the permission in System Settings and return to the app.
    /// First waits for the app to lose focus (System Settings opened), then waits for it
    /// to regain focus (user returned). Polls every 0.5s, up to 120 seconds total.
    private func waitForPermission(_ capability: PermissionCapability) async -> Bool {
        // Phase 1: wait for the app to lose focus (System Settings takes over)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if !NSApp.isActive { break }
        }

        // Phase 2: wait for the app to regain focus (user came back)
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(500))
            if NSApp.isActive {
                // Give the system a moment to propagate the TCC change
                try? await Task.sleep(for: .milliseconds(500))
                return await checkPermission(capability)
            }
        }
        return await checkPermission(capability)
    }

    private func openSystemSettings(for capability: PermissionCapability) {
        let urlString: String
        switch capability {
        case .calendar:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case .reminders:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .notifications:
            urlString = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .camera:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
