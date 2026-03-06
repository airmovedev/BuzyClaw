import Foundation

struct Agent: Identifiable, Hashable, Sendable {
    let id: String
    var displayName: String
    var emoji: String
    var roleDescription: String?
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

struct AgentDraft: Sendable {
    var name: String = ""
    var emoji: String = "🤖"
    var roleDescription: String = ""
    var model: String = "anthropic/claude-sonnet-4-20250514"

    static let modelOptions = [
        "anthropic/claude-sonnet-4-20250514",
        "anthropic/claude-opus-4-6",
        "openai-codex/gpt-5.3-codex"
    ]
}
