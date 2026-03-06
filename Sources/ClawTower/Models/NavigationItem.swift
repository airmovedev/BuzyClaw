import Foundation

enum NavigationItem: Hashable {
    case secondBrain
    case tasks
    case projects
    case cronJobs
    case skills
    case settings
    case chat(agentId: String)
    case chatSession(agentId: String, sessionKey: String, label: String)
}
