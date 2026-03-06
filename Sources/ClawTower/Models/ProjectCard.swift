import Foundation

/// Project card model scanned from ~/.openclaw/Projects/
struct ProjectCard: Identifiable {
    let id: String          // directory name
    let name: String
    let stage: ProjectStage
    let agentHints: [String] // e.g. ["pm", "designer", "engineer"]
    let path: URL
    let lastModified: Date
}

enum ProjectStage: String, CaseIterable {
    case inProgress = "进行中"
    case review = "待审核"
    case completed = "已完成"

    var sortOrder: Int {
        switch self {
        case .inProgress: 0
        case .review: 1
        case .completed: 2
        }
    }

    /// Parse a raw status string into a ProjectStage
    static func from(_ raw: String) -> ProjectStage {
        let lower = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch lower {
        case "in-progress", "active", "wip", "进行中":
            return .inProgress
        case "review", "待审核", "pending":
            return .review
        case "done", "completed", "已完成", "archived":
            return .completed
        default:
            return .inProgress
        }
    }
}
