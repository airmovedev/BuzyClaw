import Foundation

enum NavigationItem: Hashable {
    case dashboard
    case secondBrain
    case projects
    case cronJobs
    case skills
    case settings
    case chat(agentId: String)
}
