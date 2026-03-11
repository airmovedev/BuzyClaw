import CloudKit
import Foundation

/// Periodically writes a DashboardSnapshot to CloudKit for iOS consumption.
/// macOS-only service — reads from Gateway API and local files.
@MainActor
@Observable
final class DashboardSyncService {
    var lastSyncedAt: Date?
    var syncError: String?

    private var timer: Timer?
    private let syncInterval: TimeInterval = 30
    private let database = CKContainer(identifier: CloudKitConstants.containerID).privateCloudDatabase

    private weak var appState: AppState?

    func start(appState: AppState) {
        self.appState = appState
        stop()
        // Sync immediately, then every 30s
        Task { await self.sync() }
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

    private func sync() async {
        guard let appState else { return }
        await checkModelChangeCommands()
        let snapshot = await buildSnapshot(appState: appState)
        do {
            let record = try DashboardSnapshotRecord.toCKRecord(snapshot)
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            lastSyncedAt = Date()
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func checkModelChangeCommands() async {
        guard let appState else { return }
        let zoneID = CloudKitConstants.zoneID

        for agent in appState.agents {
            let recordID = CKRecord.ID(recordName: "ModelChange-\(agent.id)", zoneID: zoneID)
            do {
                let record = try await database.record(for: recordID)
                guard let model = record["model"] as? String else { continue }
                try? await appState.gatewayClient.updateAgentModel(agentId: agent.id, model: model)
                _ = try? await database.modifyRecords(saving: [], deleting: [recordID], savePolicy: .allKeys)
                NSLog("[macOS] Applied model change from iOS: agent=%@ model=%@", agent.id, model)
                await appState.loadAgents()
            } catch {
                // Record doesn't exist = no pending command, normal
            }
        }
    }

    private func buildSnapshot(appState: AppState) async -> DashboardSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".openclaw/openclaw.json")
        let config: [String: Any]? = {
            guard let data = try? Data(contentsOf: configURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json
        }()

        let agents = appState.agents.map { agent in
            let (identityEmoji, identityName, creature, vibe) = Self.parseIdentity(agentId: agent.id, config: config)
            return AgentSnapshot(
                id: agent.id,
                displayName: agent.displayName,
                emoji: agent.emoji,
                isOnline: agent.status == .online,
                currentModel: agent.model,
                tokenUsage: 0,
                identityEmoji: identityEmoji ?? agent.emoji,
                identityName: identityName ?? agent.displayName,
                creature: creature,
                vibe: vibe,
                lastMessage: nil
            )
        }

        let tasks = Self.loadTasks(from: appState.tasksFilePath)
        let secondBrainDocs = Self.loadSecondBrainDocs(from: appState.secondBrainPath)
        let cronJobs = await loadCronJobs(client: appState.gatewayClient)
        let sessions = await loadSessions(client: appState.gatewayClient, agents: appState.agents)
        let availableModels = AgentDraft.modelOptions

        return DashboardSnapshot(
            timestamp: Date(),
            agents: agents,
            projects: [],
            tasks: tasks,
            cronJobs: cronJobs,
            secondBrainDocs: secondBrainDocs,
            sessions: sessions,
            availableModels: availableModels
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

    nonisolated private static func parseIdentity(agentId: String, config: [String: Any]?) -> (emoji: String?, name: String?, creature: String?, vibe: String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent(".openclaw")

        let workspacePath: String
        if agentId == "main" {
            workspacePath = base.appendingPathComponent("workspace").path
        } else if let agentsConfig = config?["agents"] as? [String: Any],
                  let list = agentsConfig["list"] as? [[String: Any]],
                  let agentConf = list.first(where: { ($0["id"] as? String) == agentId }),
                  let ws = agentConf["workspace"] as? String {
            workspacePath = (ws as NSString).expandingTildeInPath
        } else {
            workspacePath = base.appendingPathComponent("workspace-\(agentId)").path
        }

        let identityPath = (workspacePath as NSString).appendingPathComponent("IDENTITY.md")
        guard let content = try? String(contentsOfFile: identityPath, encoding: .utf8) else { return (nil, nil, nil, nil) }

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
