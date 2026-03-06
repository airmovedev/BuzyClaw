import Foundation
import CryptoKit

final class ChatMessageStore: Sendable {
    static let shared = ChatMessageStore()

    private static let maxMessages = 200

    private init() {}

    private func cacheDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClawTower/chat-cache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func fileURL(for sessionKey: String) -> URL {
        let hash = Insecure.MD5.hash(data: Data(sessionKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectory().appendingPathComponent("\(hash).json")
    }

    func loadMessages(sessionKey: String) -> [ChatMessage] {
        let url = fileURL(for: sessionKey)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    func saveMessages(sessionKey: String, messages: [ChatMessage]) {
        let trimmed = messages.suffix(Self.maxMessages)
        let url = fileURL(for: sessionKey)
        if let data = try? JSONEncoder().encode(Array(trimmed)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func appendMessage(sessionKey: String, message: ChatMessage) {
        var msgs = loadMessages(sessionKey: sessionKey)
        msgs.append(message)
        saveMessages(sessionKey: sessionKey, messages: msgs)
    }

    func updateLastMessage(sessionKey: String, message: ChatMessage) {
        var msgs = loadMessages(sessionKey: sessionKey)
        if let idx = msgs.lastIndex(where: { $0.id == message.id }) {
            msgs[idx] = message
        } else {
            msgs.append(message)
        }
        saveMessages(sessionKey: sessionKey, messages: msgs)
    }
}
