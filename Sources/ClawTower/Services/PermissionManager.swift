import AppKit
import EventKit

// MARK: - PermissionCapability

enum PermissionCapability: String, CaseIterable, Identifiable, Hashable, Sendable {
    case calendar
    case reminders
    case fullDiskAccess
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "日历"
        case .reminders: "提醒事项"
        case .fullDiskAccess: "完全磁盘访问"
        case .accessibility: "辅助功能"
        }
    }

    var subtitle: String {
        switch self {
        case .calendar: "让 AI 查看和管理你的日程安排"
        case .reminders: "让 AI 帮你创建和管理待办事项"
        case .fullDiskAccess: "让 AI 读取你指定的文件和文件夹"
        case .accessibility: "让 AI 自动化操作系统级任务"
        }
    }

    var icon: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .fullDiskAccess: "folder.badge.gear"
        case .accessibility: "accessibility"
        }
    }
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

    @discardableResult
    func grant(_ capability: PermissionCapability) async -> Bool {
        switch capability {
        case .calendar:
            return await requestEventAccess(.event)
        case .reminders:
            return await requestEventAccess(.reminder)
        case .fullDiskAccess, .accessibility:
            openSystemPreferences(for: capability)
            return false
        }
    }

    // MARK: - Private

    private func checkPermission(_ cap: PermissionCapability) async -> Bool {
        switch cap {
        case .calendar:
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders:
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        case .fullDiskAccess:
            // Heuristic: try reading a protected path
            return FileManager.default.isReadableFile(atPath: "\(NSHomeDirectory())/Library/Mail")
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    private func requestEventAccess(_ type: EKEntityType) async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    private func openSystemPreferences(for capability: PermissionCapability) {
        let urlString: String
        switch capability {
        case .fullDiskAccess:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        default:
            return
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
