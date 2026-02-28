import Foundation

struct Agent: Identifiable, Hashable, Sendable {
    let id: String
    var displayName: String
    var emoji: String
    var status: AgentStatus
    var model: String?
    var lastActivity: Date?

    enum AgentStatus: String, Sendable {
        case online
        case offline
        case starting
        case error
    }
}
