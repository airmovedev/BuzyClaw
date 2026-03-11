import CloudKit
import Foundation

struct DashboardSnapshot: Codable, Sendable {
    var timestamp: Date?
    var agents: [AgentSnapshot]
    var projects: [ProjectSnapshot]
    var tasks: [TaskSnapshot]
    var cronJobs: [CronJobSnapshot]?
    var secondBrainDocs: [SecondBrainDocSnapshot]?
    var sessions: [SessionSnapshot]?
    var availableModels: [String]?

    init(
        timestamp: Date? = nil,
        agents: [AgentSnapshot] = [],
        projects: [ProjectSnapshot] = [],
        tasks: [TaskSnapshot] = [],
        cronJobs: [CronJobSnapshot]? = nil,
        secondBrainDocs: [SecondBrainDocSnapshot]? = nil,
        sessions: [SessionSnapshot]? = nil,
        availableModels: [String]? = nil
    ) {
        self.timestamp = timestamp
        self.agents = agents
        self.projects = projects
        self.tasks = tasks
        self.cronJobs = cronJobs
        self.secondBrainDocs = secondBrainDocs
        self.sessions = sessions
        self.availableModels = availableModels
    }
}

struct AgentSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let emoji: String?
    let isOnline: Bool?
    let currentModel: String?
    let tokenUsage: Int?
    let identityEmoji: String?
    let identityName: String?
    let creature: String?
    let vibe: String?
    let lastMessage: String?

    init(id: String, displayName: String, emoji: String?, isOnline: Bool? = nil, currentModel: String? = nil, tokenUsage: Int? = nil, identityEmoji: String? = nil, identityName: String? = nil, creature: String? = nil, vibe: String? = nil, lastMessage: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.emoji = emoji
        self.isOnline = isOnline
        self.currentModel = currentModel
        self.tokenUsage = tokenUsage
        self.identityEmoji = identityEmoji
        self.identityName = identityName
        self.creature = creature
        self.vibe = vibe
        self.lastMessage = lastMessage
    }
}

struct ProjectSnapshot: Identifiable, Codable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let stage: String
    let agentHints: [String]
    let lastModified: Date?

    init(name: String, stage: String, agentHints: [String], lastModified: Date? = nil) {
        self.name = name
        self.stage = stage
        self.agentHints = agentHints
        self.lastModified = lastModified
    }
}

struct TaskSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let status: String
    let priority: String
    let context: String?
    let createdAt: String?

    init(id: String, title: String, status: String, priority: String, context: String? = nil, createdAt: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.context = context
        self.createdAt = createdAt
    }
}

struct SessionSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let agentId: String
    let kind: String
    let label: String?
    let model: String?
    let lastMessage: String?
    let totalTokens: Int
    let isActive: Bool?
    let updatedAt: Double?

    init(id: String, agentId: String, kind: String, label: String? = nil, model: String? = nil, lastMessage: String? = nil, totalTokens: Int = 0, isActive: Bool? = nil, updatedAt: Double? = nil) {
        self.id = id
        self.agentId = agentId
        self.kind = kind
        self.label = label
        self.model = model
        self.lastMessage = lastMessage
        self.totalTokens = totalTokens
        self.isActive = isActive
        self.updatedAt = updatedAt
    }
}

struct CronJobSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let agentId: String
    let name: String
    let enabled: Bool
    let scheduleKind: String?
    let scheduleExpr: String?
    let scheduleTz: String?
    let message: String
    let lastRunAt: Date?
    let lastStatus: String?
    let didRunToday: Bool

    init(id: String, agentId: String, name: String, enabled: Bool, scheduleKind: String? = nil, scheduleExpr: String? = nil, scheduleTz: String? = nil, message: String, lastRunAt: Date? = nil, lastStatus: String? = nil, didRunToday: Bool = false) {
        self.id = id
        self.agentId = agentId
        self.name = name
        self.enabled = enabled
        self.scheduleKind = scheduleKind
        self.scheduleExpr = scheduleExpr
        self.scheduleTz = scheduleTz
        self.message = message
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.didRunToday = didRunToday
    }
}

struct SecondBrainDocSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let fileName: String?
    let group: String
    let displayName: String
    let modifiedAt: Date
    let contentPreview: String

    init(id: String, fileName: String? = nil, group: String, displayName: String, modifiedAt: Date, contentPreview: String) {
        self.id = id
        self.fileName = fileName
        self.group = group
        self.displayName = displayName
        self.modifiedAt = modifiedAt
        self.contentPreview = contentPreview
    }
}

// MARK: - CloudKit Record Helpers

enum DashboardSnapshotRecord {
    static let recordType = "DashboardSnapshot"
    static let recordName = "latest-dashboard"

    static var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: CloudKitConstants.zoneID)
    }

    static func toCKRecord(_ snapshot: DashboardSnapshot) throws -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID)
        let data = try JSONEncoder().encode(snapshot)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "DashboardSnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode JSON"])
        }
        record["payload"] = json as CKRecordValue
        record["timestamp"] = (snapshot.timestamp ?? Date()) as CKRecordValue
        return record
    }

    static func from(record: CKRecord) -> DashboardSnapshot? {
        guard let json = record["payload"] as? String,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DashboardSnapshot.self, from: data)
    }
}
