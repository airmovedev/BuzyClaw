import SwiftUI

enum NavigationItem: String, CaseIterable, Hashable, Sendable {
    case dashboard
    case secondBrain
    case projects
    case cronJobs
    case skills
    case chat
    case settings

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .secondBrain: "第二大脑"
        case .projects: "项目"
        case .cronJobs: "定时任务"
        case .skills: "Skills"
        case .chat: "对话"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .secondBrain: "brain"
        case .projects: "folder"
        case .cronJobs: "clock"
        case .skills: "puzzlepiece"
        case .chat: "bubble.left"
        case .settings: "gear"
        }
    }
}
