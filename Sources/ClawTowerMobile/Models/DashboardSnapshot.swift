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

struct AgentWorkspaceFile: Identifiable, Codable, Hashable, Sendable {
    let fileName: String
    let content: String

    var id: String { fileName }

    var displayName: String {
        switch fileName {
        case "IDENTITY.md": return "身份"
        case "AGENTS.md": return "原则"
        case "SOUL.md": return "灵魂"
        case "HEARTBEAT.md": return "心跳"
        case "MEMORY.md": return "记忆"
        case "TOOLS.md": return "工具"
        default: return fileName.replacingOccurrences(of: ".md", with: "")
        }
    }

    var icon: String {
        switch fileName {
        case "IDENTITY.md": return "person.text.rectangle"
        case "AGENTS.md": return "list.bullet.rectangle"
        case "SOUL.md": return "sparkles"
        case "HEARTBEAT.md": return "heart.text.square"
        case "MEMORY.md": return "brain.head.profile"
        case "TOOLS.md": return "wrench.and.screwdriver"
        default: return "doc.text"
        }
    }
}

struct AgentSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let emoji: String?
    let isOnline: Bool?
    let currentModel: String?
    let configuredModel: String?
    let effectiveModel: String?
    let currentDisplayModel: String?
    let availableModels: [String]?
    let heartbeatModel: String?
    let tokenUsage: Int?
    let identityEmoji: String?
    let identityName: String?
    let creature: String?
    let vibe: String?
    let lastMessage: String?
    let latestModelCommand: AgentModelCommandStatus?
    let workspaceFiles: [AgentWorkspaceFile]?

    init(
        id: String,
        displayName: String,
        emoji: String?,
        isOnline: Bool? = nil,
        currentModel: String? = nil,
        configuredModel: String? = nil,
        effectiveModel: String? = nil,
        currentDisplayModel: String? = nil,
        availableModels: [String]? = nil,
        heartbeatModel: String? = nil,
        tokenUsage: Int? = nil,
        identityEmoji: String? = nil,
        identityName: String? = nil,
        creature: String? = nil,
        vibe: String? = nil,
        lastMessage: String? = nil,
        latestModelCommand: AgentModelCommandStatus? = nil,
        workspaceFiles: [AgentWorkspaceFile]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.emoji = emoji
        self.isOnline = isOnline
        let resolvedDisplayModel = currentDisplayModel ?? currentModel
        self.currentModel = resolvedDisplayModel
        self.configuredModel = configuredModel
        self.effectiveModel = effectiveModel
        self.currentDisplayModel = resolvedDisplayModel
        self.availableModels = availableModels
        self.heartbeatModel = heartbeatModel
        self.tokenUsage = tokenUsage
        self.identityEmoji = identityEmoji
        self.identityName = identityName
        self.creature = creature
        self.vibe = vibe
        self.lastMessage = lastMessage
        self.latestModelCommand = latestModelCommand
        self.workspaceFiles = workspaceFiles
    }

    var resolvedWorkingModel: String? {
        let candidates = [currentDisplayModel, effectiveModel, configuredModel, currentModel]
        return candidates.first { candidate in
            guard let candidate else { return false }
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && normalized != "default"
        } ?? nil
    }

    func merged(with incoming: AgentSnapshot) -> AgentSnapshot {
        AgentSnapshot(
            id: incoming.id,
            displayName: incoming.displayName,
            emoji: AgentSnapshot.preferredNonEmpty(incoming.emoji, emoji),
            isOnline: incoming.isOnline ?? isOnline,
            currentModel: AgentSnapshot.preferredNonEmpty(incoming.currentDisplayModel, incoming.currentModel, currentDisplayModel, currentModel),
            configuredModel: AgentSnapshot.preferredNonEmpty(incoming.configuredModel, configuredModel),
            effectiveModel: AgentSnapshot.preferredNonEmpty(incoming.effectiveModel, effectiveModel),
            currentDisplayModel: AgentSnapshot.preferredNonEmpty(incoming.currentDisplayModel, incoming.currentModel, currentDisplayModel, currentModel),
            availableModels: AgentSnapshot.preferredArray(incoming.availableModels, availableModels),
            heartbeatModel: AgentSnapshot.preferredNonEmpty(incoming.heartbeatModel, heartbeatModel),
            tokenUsage: incoming.tokenUsage ?? tokenUsage,
            identityEmoji: AgentSnapshot.preferredNonEmpty(incoming.identityEmoji, identityEmoji, incoming.emoji, emoji),
            identityName: AgentSnapshot.preferredNonEmpty(incoming.identityName, identityName, incoming.displayName, displayName),
            creature: AgentSnapshot.preferredNonEmpty(incoming.creature, creature),
            vibe: AgentSnapshot.preferredNonEmpty(incoming.vibe, vibe),
            lastMessage: AgentSnapshot.preferredNonEmpty(incoming.lastMessage, lastMessage),
            latestModelCommand: incoming.latestModelCommand ?? latestModelCommand,
            workspaceFiles: incoming.workspaceFiles ?? workspaceFiles
        )
    }

    private static func preferredNonEmpty(_ candidates: String?...) -> String? {
        candidates.first { candidate in
            guard let candidate else { return false }
            return !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? nil
    }

    private static func preferredArray(_ candidates: [String]?...) -> [String]? {
        candidates.first { candidate in
            guard let candidate else { return false }
            return !candidate.isEmpty
        } ?? nil
    }
}

struct AgentModelCommandStatus: Codable, Hashable, Sendable {
    let requestID: String
    let requestedModel: String
    let status: String
    let requestedAt: Date?
    let updatedAt: Date?
    let errorMessage: String?

    var isPending: Bool { status == ModelChangeCommandRecord.Status.pending.rawValue }
    var isApplied: Bool { status == ModelChangeCommandRecord.Status.applied.rawValue }
    var isFailed: Bool { status == ModelChangeCommandRecord.Status.failed.rawValue }
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

enum DashboardSnapshotRecord {
    static let recordType = "DashboardSnapshot"
    static let recordName = "latest-dashboard"

    static var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: CloudKitConstants.zoneID)
    }

    static func toCKRecord(_ snapshot: DashboardSnapshot) throws -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID)
        try applySnapshot(snapshot, to: record)
        return record
    }

    /// Update an existing CKRecord in-place (preserves changeTag to avoid serverRecordChanged conflicts).
    static func applySnapshot(_ snapshot: DashboardSnapshot, to record: CKRecord) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "DashboardSnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode JSON"])
        }
        record["payload"] = json as CKRecordValue
        record["timestamp"] = (snapshot.timestamp ?? Date()) as CKRecordValue
    }

    static func from(record: CKRecord) -> DashboardSnapshot? {
        guard let json = record["payload"] as? String,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DashboardSnapshot.self, from: data)
    }
}

enum ModelChangeCommandRecord {
    static let recordType = "ModelChange"

    enum Status: String, Codable, Sendable {
        case pending
        case applied
        case failed
    }

    struct Payload: Codable, Sendable {
        let requestID: String
        let agentId: String
        let model: String
        let timestamp: Date
        let status: Status
        let processedAt: Date?
        let errorMessage: String?

        var snapshotStatus: AgentModelCommandStatus {
            AgentModelCommandStatus(
                requestID: requestID,
                requestedModel: model,
                status: status.rawValue,
                requestedAt: timestamp,
                updatedAt: processedAt ?? timestamp,
                errorMessage: errorMessage
            )
        }
    }

    static func recordID(agentId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "ModelChange-\(agentId)", zoneID: CloudKitConstants.zoneID)
    }

    static func makeRecord(payload: Payload) -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID(agentId: payload.agentId))
        apply(payload, to: record)
        return record
    }

    static func apply(_ payload: Payload, to record: CKRecord) {
        record["requestID"] = payload.requestID as CKRecordValue
        record["agentId"] = payload.agentId as CKRecordValue
        record["model"] = payload.model as CKRecordValue
        record["timestamp"] = payload.timestamp as CKRecordValue
        record["status"] = payload.status.rawValue as CKRecordValue
        if let processedAt = payload.processedAt {
            record["processedAt"] = processedAt as CKRecordValue
        } else {
            record["processedAt"] = nil
        }
        if let errorMessage = payload.errorMessage, !errorMessage.isEmpty {
            record["errorMessage"] = errorMessage as CKRecordValue
        } else {
            record["errorMessage"] = nil
        }
    }

    static func payload(from record: CKRecord) -> Payload? {
        guard let requestID = record["requestID"] as? String,
              let agentId = record["agentId"] as? String,
              let model = record["model"] as? String,
              let timestamp = record["timestamp"] as? Date else {
            return nil
        }

        let rawStatus = (record["status"] as? String) ?? Status.pending.rawValue
        let status = Status(rawValue: rawStatus) ?? .pending
        let processedAt = record["processedAt"] as? Date
        let errorMessage = record["errorMessage"] as? String

        return Payload(
            requestID: requestID,
            agentId: agentId,
            model: model,
            timestamp: timestamp,
            status: status,
            processedAt: processedAt,
            errorMessage: errorMessage
        )
    }
}
