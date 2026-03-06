import Foundation

struct ProjectItem: Identifiable, Hashable {
    var id: String { url.path }
    let name: String
    let url: URL
    let subdirectoryCount: Int
    let fileCount: Int
    let lastActivityAt: Date?
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
