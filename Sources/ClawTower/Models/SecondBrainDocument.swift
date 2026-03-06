import Foundation

struct SecondBrainDocument: Identifiable, Sendable {
    let id: String
    let fileName: String
    let group: String
    let filePath: URL
    let modifiedAt: Date
    var content: String

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    var isImage: Bool {
        Self.imageExtensions.contains(filePath.pathExtension.lowercased())
    }

    var fileExtension: String {
        filePath.pathExtension.lowercased()
    }

    /// Display name: strip .md extension for cleaner UI
    var displayName: String {
        if filePath.pathExtension.lowercased() == "md" {
            return String(fileName.dropLast(3)) // remove ".md"
        }
        return fileName
    }

    init(filePath: URL, group: String, content: String = "", modifiedAt: Date = Date()) {
        self.id = filePath.path
        self.fileName = filePath.lastPathComponent
        self.group = group
        self.filePath = filePath
        self.modifiedAt = modifiedAt
        self.content = content
    }
}
