import Foundation

struct ProjectItem: Identifiable, Hashable {
    var id: String { url.path }
    let name: String
    let url: URL
    let subdirectoryCount: Int
    let fileCount: Int
    let lastActivityAt: Date?
    let knownSubdirs: Set<String> // e.g. ["pm", "design", "engineering"]
}

struct Milestone: Identifiable, Hashable, Codable {
    var id: String { name + date }
    let name: String
    let date: String
    let completed: Bool
}

struct ProjectSectionInfo: Hashable {
    let name: String
    let url: URL
    let files: [ProjectFileItem]
}

struct ProjectFileItem: Identifiable, Hashable {
    var id: String { url.path }
    let name: String
    let url: URL
    let size: Int64
    let modifiedAt: Date?

    var isMarkdown: Bool {
        url.pathExtension.lowercased() == "md"
    }
}
