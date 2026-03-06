import Foundation

struct ChatMessage: Identifiable, Sendable, Codable {
    let id: String
    let role: Role
    var content: String
    let timestamp: Date
    var isStreaming: Bool
    var isSystemInjected: Bool

    enum Role: String, Sendable, Codable {
        case user
        case assistant
        case system
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, isStreaming, isSystemInjected
    }

    init(id: String = UUID().uuidString, role: Role, content: String, timestamp: Date = Date(), isStreaming: Bool = false, isSystemInjected: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.isSystemInjected = isSystemInjected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        isSystemInjected = try container.decodeIfPresent(Bool.self, forKey: .isSystemInjected) ?? false
    }

    var isUser: Bool { role == .user }
    var isAssistant: Bool { role == .assistant }
    var isLong: Bool { content.count > 500 }
}
