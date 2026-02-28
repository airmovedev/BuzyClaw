import Foundation

struct ChatMessage: Identifiable, Sendable {
    let id: String
    let role: Role
    var content: String
    let timestamp: Date
    var isStreaming: Bool

    enum Role: String, Sendable {
        case user
        case assistant
        case system
    }

    init(id: String = UUID().uuidString, role: Role, content: String, timestamp: Date = Date(), isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }

    var isUser: Bool { role == .user }
    var isAssistant: Bool { role == .assistant }
    var isLong: Bool { content.count > 500 }
}
