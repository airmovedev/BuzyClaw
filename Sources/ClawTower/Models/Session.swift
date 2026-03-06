import Foundation

struct Session: Identifiable, Sendable {
    var id: String { key }
    let key: String
    let kind: String?
    let channel: String?
    let label: String?
    let displayName: String?
    let updatedAt: Date?
    let model: String?
    let totalTokens: Int

    var isMainSession: Bool {
        kind == nil || kind == "main"
    }

    var isCronSession: Bool {
        key.contains(":cron:")
    }

    var isSubAgent: Bool {
        key.contains(":subagent:")
    }
}
