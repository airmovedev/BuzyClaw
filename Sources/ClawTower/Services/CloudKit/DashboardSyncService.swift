import CloudKit
import Foundation
import os.log

/// Periodically writes a DashboardSnapshot to CloudKit for iOS consumption.
/// macOS-only service — reads from Gateway API and local files.
@MainActor
@Observable
final class DashboardSyncService {
    var lastSyncedAt: Date?
    var syncError: String?
    var isQuotaExceeded = false

    private let logger = Logger(subsystem: "com.clawtower.mac", category: "DashboardSyncService")

    private var timer: Timer?
    private let syncInterval: TimeInterval = 30
    private let database = CKContainer(identifier: CloudKitConstants.containerID).privateCloudDatabase
    private var zoneEnsured = false

    private weak var appState: AppState?

    func start(appState: AppState) {
        self.appState = appState
        stop()
        // Sync immediately, then every 30s
        Task {
            await self.ensureZoneExists()
            await self.sync()
        }
        timer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.sync()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func ensureZoneExists() async {
        guard !zoneEnsured else { return }
        let zone = CKRecordZone(zoneID: CloudKitConstants.zoneID)
        do {
            try await database.save(zone)
            logger.info("ClawTowerZone created or confirmed for DashboardSync")
        } catch {
            logger.debug("Zone creation result: \(error.localizedDescription)")
        }
        zoneEnsured = true
    }

    private func sync() async {
        guard let appState else { return }
        let commandStatuses = await checkModelChangeCommands()

        // Fetch existing record to preserve its changeTag (avoids serverRecordChanged conflicts
        // when multiple Macs write to the same "latest-dashboard" record).
        let existingRecord: CKRecord?
        let previousSnapshot: DashboardSnapshot?
        do {
            let fetched = try await database.record(for: DashboardSnapshotRecord.recordID)
            existingRecord = fetched
            previousSnapshot = DashboardSnapshotRecord.from(record: fetched)
        } catch {
            existingRecord = nil
            previousSnapshot = nil
        }

        let snapshot = await buildSnapshot(
            appState: appState,
            previousSnapshot: previousSnapshot,
            commandStatuses: commandStatuses
        )
        do {
            let record: CKRecord
            if let existingRecord {
                // Update the fetched record in-place — keeps changeTag intact
                try DashboardSnapshotRecord.applySnapshot(snapshot, to: existingRecord)
                record = existingRecord
            } else {
                // First time: create a new record
                record = try DashboardSnapshotRecord.toCKRecord(snapshot)
            }
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
            lastSyncedAt = Date()
            syncError = nil
            isQuotaExceeded = false
        } catch let ckError as CKError where ckError.code == .quotaExceeded {
            logger.error("iCloud quota exceeded — cannot sync dashboard")
            syncError = "iCloud 空间不足，无法同步看板数据"
            isQuotaExceeded = true
        } catch let ckError as CKError where ckError.code == .zoneNotFound {
            // Zone doesn't exist yet — create it and retry once
            logger.warning("Zone not found during sync, creating zone and retrying...")
            zoneEnsured = false
            await ensureZoneExists()
            do {
                let record = try DashboardSnapshotRecord.toCKRecord(snapshot)
                _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
                lastSyncedAt = Date()
                syncError = nil
            } catch let retryError as CKError where retryError.code == .quotaExceeded {
                logger.error("iCloud quota exceeded — cannot sync dashboard")
                syncError = "iCloud 空间不足，无法同步看板数据"
                isQuotaExceeded = true
            } catch {
                syncError = error.localizedDescription
            }
        } catch let ckError as CKError where ckError.code == .serverRecordChanged {
            // Another device updated the record between our fetch and save — retry once
            logger.warning("Server record changed during sync, retrying with latest...")
            do {
                let latestRecord = try await database.record(for: DashboardSnapshotRecord.recordID)
                try DashboardSnapshotRecord.applySnapshot(snapshot, to: latestRecord)
                _ = try await database.modifyRecords(saving: [latestRecord], deleting: [], savePolicy: .changedKeys)
                lastSyncedAt = Date()
                syncError = nil
            } catch {
                syncError = error.localizedDescription
            }
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func checkModelChangeCommands() async -> [String: AgentModelCommandStatus] {
        guard let appState else { return [:] }
        var statuses: [String: AgentModelCommandStatus] = [:]
        var didApplyAny = false

        for agent in appState.agents {
            let recordID = ModelChangeCommandRecord.recordID(agentId: agent.id)
            do {
                let record = try await database.record(for: recordID)
                guard var payload = ModelChangeCommandRecord.payload(from: record) else {
                    logger.error("[ModelSwitch][DashboardSync] payload decode failed agent=\(agent.id, privacy: .public) recordName=\(recordID.recordName, privacy: .public)")
                    continue
                }

                logger.log("[ModelSwitch][DashboardSync] scanned record agent=\(agent.id, privacy: .public) requestID=\(payload.requestID, privacy: .public) model=\(payload.model, privacy: .public) status=\(payload.status.rawValue, privacy: .public)")

                if payload.status == .pending {
                    logger.log("[ModelSwitch][DashboardSync] preparing updateAgentModel agent=\(agent.id, privacy: .public) requestID=\(payload.requestID, privacy: .public) model=\(payload.model, privacy: .public)")
                    do {
                        try await appState.gatewayClient.updateAgentModel(agentId: agent.id, model: payload.model)
                        payload = ModelChangeCommandRecord.Payload(
                            requestID: payload.requestID,
                            agentId: payload.agentId,
                            model: payload.model,
                            timestamp: payload.timestamp,
                            status: .applied,
                            processedAt: Date(),
                            errorMessage: nil
                        )
                        ModelChangeCommandRecord.apply(payload, to: record)
                        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
                        logger.log("[ModelSwitch][DashboardSync] updateAgentModel success agent=\(agent.id, privacy: .public) requestID=\(payload.requestID, privacy: .public) model=\(payload.model, privacy: .public)")
                        didApplyAny = true
                    } catch {
                        payload = ModelChangeCommandRecord.Payload(
                            requestID: payload.requestID,
                            agentId: payload.agentId,
                            model: payload.model,
                            timestamp: payload.timestamp,
                            status: .failed,
                            processedAt: Date(),
                            errorMessage: error.localizedDescription
                        )
                        ModelChangeCommandRecord.apply(payload, to: record)
                        _ = try? await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
                        logger.error("[ModelSwitch][DashboardSync] updateAgentModel failed agent=\(agent.id, privacy: .public) requestID=\(payload.requestID, privacy: .public) model=\(payload.model, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    }
                }

                statuses[agent.id] = payload.snapshotStatus
            } catch let ckError as CKError where ckError.code == .unknownItem {
                continue
            } catch {
                logger.error("[ModelSwitch][DashboardSync] record scan failed agent=\(agent.id, privacy: .public) recordName=\(recordID.recordName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        if didApplyAny {
            logger.log("[ModelSwitch][DashboardSync] refreshing agents after applied model change")
            await appState.loadAgents()
        }

        return statuses
    }

    private func buildSnapshot(appState: AppState, previousSnapshot: DashboardSnapshot?, commandStatuses: [String: AgentModelCommandStatus]) async -> DashboardSnapshot {
        let config = Self.loadConfig(basePath: appState.openclawBasePath)
        let previousAgents = previousSnapshot?.agents ?? []
        let previousAgentsByID = Dictionary(uniqueKeysWithValues: previousAgents.map { ($0.id, $0) })
        let loadedModels = Self.loadAvailableModels(from: config)
        let availableModels = loadedModels.isEmpty ? (previousSnapshot?.availableModels ?? []) : loadedModels

        let builtAgents = appState.agents.map { agent in
            let previous = previousAgentsByID[agent.id]
            let (identityEmoji, identityName, creature, vibe) = Self.parseIdentity(
                agentId: agent.id,
                config: config,
                basePath: appState.openclawBasePath
            )
            let configuredModel = Self.agentConfiguredModel(agentId: agent.id, config: config) ?? previous?.configuredModel
            let effectiveModel = Self.agentEffectiveModel(agentId: agent.id, config: config) ?? configuredModel ?? previous?.effectiveModel
            let runtimeModel = Self.sanitizedModel(agent.model)
            let currentDisplayModel = Self.preferredNonEmpty(
                runtimeModel,
                effectiveModel,
                configuredModel,
                previous?.currentDisplayModel,
                previous?.currentModel
            )
            let resolvedIdentityEmoji = Self.preferredNonEmpty(identityEmoji, previous?.identityEmoji, agent.emoji)
            let resolvedIdentityName = Self.preferredNonEmpty(identityName, previous?.identityName, agent.displayName)
            let resolvedCreature = Self.preferredNonEmpty(creature, previous?.creature)
            let resolvedVibe = Self.preferredNonEmpty(vibe, previous?.vibe)
            let resolvedAvailableModels = Self.agentAvailableModels(agentId: agent.id, config: config, globalModels: availableModels)
            let heartbeatModel = Self.agentHeartbeatModel(agentId: agent.id, config: config) ?? previous?.heartbeatModel
            let workspaceFiles = Self.loadWorkspaceFiles(
                agentId: agent.id,
                config: config,
                basePath: appState.openclawBasePath
            )

            return AgentSnapshot(
                id: agent.id,
                displayName: agent.displayName,
                emoji: agent.emoji,
                isOnline: agent.status == .online,
                currentModel: currentDisplayModel,
                configuredModel: configuredModel,
                effectiveModel: effectiveModel,
                currentDisplayModel: currentDisplayModel,
                availableModels: resolvedAvailableModels,
                heartbeatModel: heartbeatModel,
                tokenUsage: 0,
                identityEmoji: resolvedIdentityEmoji,
                identityName: resolvedIdentityName,
                creature: resolvedCreature,
                vibe: resolvedVibe,
                lastMessage: previous?.lastMessage,
                latestModelCommand: commandStatuses[agent.id] ?? previous?.latestModelCommand,
                workspaceFiles: workspaceFiles.isEmpty ? previous?.workspaceFiles : workspaceFiles
            )
        }

        let agents = builtAgents.isEmpty ? previousAgents : builtAgents

        let tasks = Self.loadTasks(from: appState.tasksFilePath)
        let secondBrainDocs = Self.loadSecondBrainDocs(from: appState.secondBrainPath)
        let cronJobs = await loadCronJobs(client: appState.gatewayClient)
        let sessions = await loadSessions(client: appState.gatewayClient, agents: appState.agents)

        return DashboardSnapshot(
            timestamp: Date(),
            agents: agents,
            projects: previousSnapshot?.projects ?? [],
            tasks: tasks.isEmpty ? (previousSnapshot?.tasks ?? []) : tasks,
            cronJobs: (cronJobs.isEmpty ? previousSnapshot?.cronJobs : cronJobs),
            secondBrainDocs: (secondBrainDocs.isEmpty ? previousSnapshot?.secondBrainDocs : secondBrainDocs),
            sessions: (sessions.isEmpty ? previousSnapshot?.sessions : sessions),
            availableModels: availableModels.isEmpty ? previousSnapshot?.availableModels : availableModels
        )
    }

    nonisolated private static func loadTasks(from url: URL) -> [TaskSnapshot] {
        guard let data = try? Data(contentsOf: url),
              let array = try? JSONDecoder().decode([[String: String]].self, from: data) else {
            return []
        }
        return array.compactMap { dict in
            guard let id = dict["id"], let title = dict["title"],
                  let status = dict["status"], let priority = dict["priority"] else { return nil }
            return TaskSnapshot(
                id: id,
                title: title,
                status: status,
                priority: priority,
                context: dict["context"],
                createdAt: dict["createdAt"] ?? ""
            )
        }
    }

    nonisolated private static func loadSecondBrainDocs(from basePath: URL) -> [SecondBrainDocSnapshot] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: basePath.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: basePath,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [SecondBrainDocSnapshot] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "md" else { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: basePath.path + "/", with: "")
            let components = relativePath.split(separator: "/")
            let group = components.count > 1 ? String(components[0]) : "root"

            let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let maxChars = 50000
            let truncated = String(content.prefix(maxChars))
            let preview = content.count > maxChars
                ? truncated + "\n\n---\n\n> ⚠️ 文档过长，仅显示前 50000 字符"
                : truncated

            let fileName = fileURL.lastPathComponent
            let displayName = fileName.hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName

            results.append(SecondBrainDocSnapshot(
                id: fileURL.path,
                fileName: fileName,
                group: group,
                displayName: displayName,
                modifiedAt: modDate,
                contentPreview: preview
            ))
        }
        return results
    }

    nonisolated private static func sanitizedModel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != "default" else { return nil }
        return normalized
    }

    nonisolated private static func preferredNonEmpty(_ candidates: String?...) -> String? {
        candidates.first { candidate in
            guard let candidate else { return false }
            return !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? nil
    }

    nonisolated private static func loadConfig(basePath: URL) -> [String: Any]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            basePath.appendingPathComponent("openclaw.json"),
            home.appendingPathComponent(".openclaw/openclaw.json")
        ]

        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }

        return nil
    }

    nonisolated private static func configAgentList(from json: [String: Any]?) -> [[String: Any]] {
        guard let json,
              let agentsConfig = json["agents"] as? [String: Any],
              let agentsList = agentsConfig["list"] as? [[String: Any]] else {
            return []
        }
        return agentsList
    }

    nonisolated private static func configModelCount(from json: [String: Any]) -> Int {
        var count = 0
        if let agents = json["agents"] as? [String: Any],
           let defaults = agents["defaults"] as? [String: Any],
           let models = defaults["models"] as? [String: Any] {
            count += models.count
        }
        if let models = json["models"] as? [String: Any],
           let providers = models["providers"] as? [String: Any] {
            for value in providers.values {
                if let dict = value as? [String: Any] {
                    count += (dict["models"] as? [[String: Any]])?.count ?? 0
                    count += (dict["models"] as? [String])?.count ?? 0
                }
            }
        }
        return count
    }


    nonisolated private static func agentConfig(agentId: String, config: [String: Any]?) -> [String: Any]? {
        configAgentList(from: config).first { ($0["id"] as? String) == agentId }
    }

    nonisolated private static func defaultPrimaryModel(from config: [String: Any]?) -> String? {
        guard let agents = config?["agents"] as? [String: Any],
              let defaults = agents["defaults"] as? [String: Any],
              let modelConfig = defaults["model"] as? [String: Any] else { return nil }
        return sanitizedModel(modelConfig["primary"] as? String)
    }

    nonisolated private static func agentConfiguredModel(agentId: String, config: [String: Any]?) -> String? {
        if let agentConf = agentConfig(agentId: agentId, config: config) {
            if let model = sanitizedModel(agentConf["model"] as? String) {
                return model
            }
            if let modelConfig = agentConf["model"] as? [String: Any],
               let primary = sanitizedModel(modelConfig["primary"] as? String) {
                return primary
            }
        }
        return nil
    }

    nonisolated private static func agentEffectiveModel(agentId: String, config: [String: Any]?) -> String? {
        agentConfiguredModel(agentId: agentId, config: config) ?? defaultPrimaryModel(from: config)
    }

    nonisolated private static func agentHeartbeatModel(agentId: String, config: [String: Any]?) -> String? {
        if let agentConf = agentConfig(agentId: agentId, config: config),
           let heartbeat = agentConf["heartbeat"] as? [String: Any],
           let model = sanitizedModel(heartbeat["model"] as? String) {
            return model
        }
        if let agents = config?["agents"] as? [String: Any],
           let defaults = agents["defaults"] as? [String: Any],
           let heartbeat = defaults["heartbeat"] as? [String: Any],
           let model = sanitizedModel(heartbeat["model"] as? String) {
            return model
        }
        return nil
    }

    nonisolated private static func agentAvailableModels(agentId: String, config: [String: Any]?, globalModels: [String]) -> [String] {
        var result: [String] = []

        func append(_ model: String?) {
            guard let model = sanitizedModel(model), !result.contains(model) else { return }
            result.append(model)
        }

        if let agentConf = agentConfig(agentId: agentId, config: config) {
            append(agentConf["model"] as? String)
            if let modelConfig = agentConf["model"] as? [String: Any] {
                append(modelConfig["primary"] as? String)
                for fallback in (modelConfig["fallbacks"] as? [String] ?? []) {
                    append(fallback)
                }
            }
            if let models = agentConf["models"] as? [String: Any] {
                for key in models.keys.sorted() {
                    append(key)
                }
            }
        }

        if result.isEmpty {
            for model in globalModels {
                append(model)
            }
        } else {
            for model in globalModels {
                append(model)
            }
        }

        return result
    }

    nonisolated private static func loadAvailableModels(from config: [String: Any]?) -> [String] {
        guard let config else { return [] }

        var result: [String] = []

        func append(_ model: String?) {
            guard let model = sanitizedModel(model), !result.contains(model) else { return }
            result.append(model)
        }

        if let agents = config["agents"] as? [String: Any],
           let defaults = agents["defaults"] as? [String: Any],
           let modelConfig = defaults["model"] as? [String: Any] {
            append(modelConfig["primary"] as? String)
            for fallback in (modelConfig["fallbacks"] as? [String] ?? []) {
                append(fallback)
            }
        }

        if let agents = config["agents"] as? [String: Any],
           let defaults = agents["defaults"] as? [String: Any],
           let models = defaults["models"] as? [String: Any] {
            for key in models.keys {
                append(key)
            }
        }

        if let models = config["models"] as? [String: Any],
           let providers = models["providers"] as? [String: Any] {
            for (providerId, providerValue) in providers {
                guard let providerDict = providerValue as? [String: Any] else { continue }

                if let modelEntries = providerDict["models"] as? [[String: Any]] {
                    for entry in modelEntries {
                        if let modelId = entry["id"] as? String {
                            append("\(providerId)/\(modelId)")
                        }
                    }
                }

                if let modelIds = providerDict["models"] as? [String] {
                    for modelId in modelIds {
                        append("\(providerId)/\(modelId)")
                    }
                }
            }
        }

        return result
    }

    private func loadSessions(client: GatewayClient, agents: [Agent]) async -> [SessionSnapshot] {
        var all: [SessionSnapshot] = []
        for agent in agents {
            guard let sessions = try? await client.listSessions(agentId: agent.id, limit: 20) else { continue }
            for s in sessions {
                let kind: String
                if s.isCronSession { kind = "cron" }
                else if s.isSubAgent { kind = "subagent" }
                else { kind = "main" }

                all.append(SessionSnapshot(
                    id: s.key,
                    agentId: agent.id,
                    kind: kind,
                    label: s.label,
                    model: s.model,
                    lastMessage: nil,
                    totalTokens: 0,
                    isActive: true,
                    updatedAt: s.updatedAt?.timeIntervalSince1970
                ))
            }
        }
        return all
    }

    nonisolated private static func parseIdentity(agentId: String, config: [String: Any]?, basePath: URL) -> (emoji: String?, name: String?, creature: String?, vibe: String?) {
        let workspaceCandidates: [String] = {
            if agentId == "main" {
                return [basePath.appendingPathComponent("workspace").path]
            }

            var candidates = [basePath.appendingPathComponent("agents/\(agentId)/workspace").path]
            if let agentsConfig = config?["agents"] as? [String: Any],
               let list = agentsConfig["list"] as? [[String: Any]],
               let agentConf = list.first(where: { ($0["id"] as? String) == agentId }),
               let ws = agentConf["workspace"] as? String {
                candidates.insert((ws as NSString).expandingTildeInPath, at: 0)
            }
            candidates.append(basePath.appendingPathComponent("workspace-\(agentId)").path)
            return candidates
        }()

        let content: String? = workspaceCandidates.lazy.compactMap { workspacePath in
            try? String(contentsOfFile: (workspacePath as NSString).appendingPathComponent("IDENTITY.md"), encoding: .utf8)
        }.first
        guard let content else { return (nil, nil, nil, nil) }

        var emoji: String?, name: String?, creature: String?, vibe: String?
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.contains("**Name:**") { name = t.replacingOccurrences(of: "- **Name:**", with: "").trimmingCharacters(in: .whitespaces) }
            if t.contains("**Emoji:**") { emoji = t.replacingOccurrences(of: "- **Emoji:**", with: "").trimmingCharacters(in: .whitespaces) }
            if t.contains("**Creature:**") { creature = t.replacingOccurrences(of: "- **Creature:**", with: "").trimmingCharacters(in: .whitespaces) }
            if t.contains("**Vibe:**") { vibe = t.replacingOccurrences(of: "- **Vibe:**", with: "").trimmingCharacters(in: .whitespaces) }
        }
        return (emoji, name, creature, vibe)
    }

    nonisolated private static let workspaceMDFiles = [
        "IDENTITY.md", "AGENTS.md", "SOUL.md", "HEARTBEAT.md", "MEMORY.md", "TOOLS.md"
    ]

    nonisolated private static func resolveWorkspacePath(agentId: String, config: [String: Any]?, basePath: URL) -> String? {
        let candidates: [String] = {
            if agentId == "main" {
                return [basePath.appendingPathComponent("workspace").path]
            }

            var list = [basePath.appendingPathComponent("agents/\(agentId)/workspace").path]
            if let agentsConfig = config?["agents"] as? [String: Any],
               let agentsList = agentsConfig["list"] as? [[String: Any]],
               let agentConf = agentsList.first(where: { ($0["id"] as? String) == agentId }),
               let ws = agentConf["workspace"] as? String {
                list.insert((ws as NSString).expandingTildeInPath, at: 0)
            }
            list.append(basePath.appendingPathComponent("workspace-\(agentId)").path)
            return list
        }()

        let fm = FileManager.default
        return candidates.first { fm.fileExists(atPath: $0) }
    }

    nonisolated private static func loadWorkspaceFiles(agentId: String, config: [String: Any]?, basePath: URL) -> [AgentWorkspaceFile] {
        guard let workspacePath = resolveWorkspacePath(agentId: agentId, config: config, basePath: basePath) else {
            return []
        }

        let maxChars = 30000
        var files: [AgentWorkspaceFile] = []
        for fileName in workspaceMDFiles {
            let filePath = (workspacePath as NSString).appendingPathComponent(fileName)
            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }
            let truncated = content.count > maxChars
                ? String(content.prefix(maxChars)) + "\n\n---\n\n> ⚠️ 文档过长，仅显示前 \(maxChars) 字符"
                : content
            files.append(AgentWorkspaceFile(fileName: fileName, content: truncated))
        }
        return files
    }

    private func loadCronJobs(client: GatewayClient) async -> [CronJobSnapshot] {
        guard let data = try? await client.cronListRaw() else { return [] }
        let jobs = CronJobParser.parse(from: data)
        return jobs.map { job in
            CronJobSnapshot(
                id: job.id,
                agentId: job.agentId,
                name: job.name,
                enabled: job.enabled,
                scheduleKind: job.schedule.kind,
                scheduleExpr: job.schedule.expr,
                scheduleTz: job.schedule.tz,
                message: job.message,
                lastRunAt: job.lastRunAt,
                lastStatus: job.lastStatus,
                didRunToday: job.didRunToday
            )
        }
    }
}
