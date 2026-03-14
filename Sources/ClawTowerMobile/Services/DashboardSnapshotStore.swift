import CloudKit
import Foundation
import os.log

@MainActor
@Observable
final class DashboardSnapshotStore {
    var snapshot: DashboardSnapshot?
    var isRefreshing = false
    var lastRefreshDate: Date?
    var lastError: String?

    private let container: CKContainer
    private let database: CKDatabase
    private let logger = Logger(subsystem: "com.clawtower.mobile", category: "DashboardSnapshotStore")

    init(container: CKContainer = CKContainer(identifier: CloudKitConstants.containerID)) {
        self.container = container
        self.database = container.privateCloudDatabase
        loadCache()
    }

    var agents: [AgentSnapshot] {
        snapshot?.agents ?? []
    }

    func agent(for agentId: String) -> AgentSnapshot? {
        snapshot?.agents.first(where: { $0.id == agentId })
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let record = try await database.record(for: DashboardSnapshotRecord.recordID)
            guard let fetched = DashboardSnapshotRecord.from(record: record) else {
                lastError = "无法解析看板数据"
                return
            }
            let merged = mergeSnapshot(fetched, onto: snapshot)
            applySnapshot(merged, persist: true)
            lastError = nil
        } catch let ckError as CKError where ckError.code == .unknownItem {
            if snapshot == nil {
                lastError = "暂无看板数据，请确保 macOS 端已打开"
            }
        } catch {
            logger.error("Failed to refresh snapshot: \(error.localizedDescription)")
            if snapshot == nil {
                lastError = error.localizedDescription
            }
        }
    }

    func updateLocalCommandStatus(agentId: String, status: AgentModelCommandStatus) {
        guard var snapshot else { return }
        guard let index = snapshot.agents.firstIndex(where: { $0.id == agentId }) else { return }

        let existing = snapshot.agents[index]
        snapshot.agents[index] = AgentSnapshot(
            id: existing.id,
            displayName: existing.displayName,
            emoji: existing.emoji,
            isOnline: existing.isOnline,
            currentModel: existing.currentModel,
            configuredModel: existing.configuredModel,
            effectiveModel: existing.effectiveModel,
            currentDisplayModel: existing.currentDisplayModel,
            availableModels: existing.availableModels,
            heartbeatModel: existing.heartbeatModel,
            tokenUsage: existing.tokenUsage,
            identityEmoji: existing.identityEmoji,
            identityName: existing.identityName,
            creature: existing.creature,
            vibe: existing.vibe,
            lastMessage: existing.lastMessage,
            latestModelCommand: status
        )
        applySnapshot(snapshot, persist: true)
    }

    private func applySnapshot(_ snapshot: DashboardSnapshot, persist: Bool) {
        self.snapshot = snapshot
        self.lastRefreshDate = Date()
        if persist {
            saveCache(snapshot)
        }
    }

    private func mergeSnapshot(_ incoming: DashboardSnapshot, onto existing: DashboardSnapshot?) -> DashboardSnapshot {
        let mergedAgents = mergeAgents(incoming.agents, existing: existing?.agents ?? [])
        let resolvedAgents = mergedAgents.isEmpty ? (existing?.agents ?? []) : mergedAgents
        let resolvedTasks = preferredNonEmptyArray(incoming.tasks, fallback: existing?.tasks)
        let resolvedProjects = preferredNonEmptyArray(incoming.projects, fallback: existing?.projects)
        let resolvedCronJobs = preferredOptionalArray(incoming.cronJobs, fallback: existing?.cronJobs)
        let resolvedDocs = preferredOptionalArray(incoming.secondBrainDocs, fallback: existing?.secondBrainDocs)
        let resolvedSessions = preferredOptionalArray(incoming.sessions, fallback: existing?.sessions)
        let resolvedAvailableModels = preferredOptionalArray(incoming.availableModels, fallback: existing?.availableModels)

        return DashboardSnapshot(
            timestamp: incoming.timestamp ?? existing?.timestamp,
            agents: resolvedAgents,
            projects: resolvedProjects,
            tasks: resolvedTasks,
            cronJobs: resolvedCronJobs,
            secondBrainDocs: resolvedDocs,
            sessions: resolvedSessions,
            availableModels: resolvedAvailableModels
        )
    }

    private func mergeAgents(_ incoming: [AgentSnapshot], existing: [AgentSnapshot]) -> [AgentSnapshot] {
        guard !incoming.isEmpty else { return existing }

        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var result = incoming.map { agent in
            guard let previous = existingByID[agent.id] else { return agent }
            return previous.merged(with: agent)
        }

        let incomingIDs = Set(incoming.map(\.id))
        for agent in existing where !incomingIDs.contains(agent.id) {
            result.append(agent)
        }
        return result
    }

    private func preferredNonEmptyArray<T>(_ incoming: [T], fallback: [T]?) -> [T] {
        incoming.isEmpty ? (fallback ?? []) : incoming
    }

    private func preferredOptionalArray<T>(_ incoming: [T]?, fallback: [T]?) -> [T]? {
        guard let incoming else { return fallback }
        return incoming.isEmpty ? fallback : incoming
    }

    private func cacheFileURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("dashboard-snapshot-cache.json")
    }

    private func saveCache(_ snapshot: DashboardSnapshot) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: cacheFileURL(), options: .atomic)
        } catch {
            logger.error("Failed to save snapshot cache: \(error.localizedDescription)")
        }
    }

    private func loadCache() {
        let url = cacheFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snapshot = try decoder.decode(DashboardSnapshot.self, from: data)
        } catch {
            logger.error("Failed to load snapshot cache: \(error.localizedDescription)")
        }
    }
    
    // MARK: - App Lifecycle Methods
    
    func start() {
        loadCache()
        Task { await refresh() }
    }
    
    func appDidBecomeActive() {
        Task { await refresh() }
    }
}
