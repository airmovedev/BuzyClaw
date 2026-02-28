import Foundation

struct Session: Identifiable, Sendable {
    var id: String { key }
    let key: String
    let agentId: String
    let kind: String?
    let label: String?
    let updatedAt: Date?
    let messageCount: Int?

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
