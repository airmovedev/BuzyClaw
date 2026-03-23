import CloudKit
import Foundation
import os.log

/// CloudKit Relay service that syncs messages between iOS and macOS via iCloud Private Database.
/// On macOS, it monitors for `toGateway` messages, forwards them to the local Gateway,
/// and writes back responses as `fromGateway` messages.
@MainActor
@Observable
final class CloudKitRelayService {
    // MARK: - Observable state

    var isRunning = false
    var lastSyncDate: Date?
    var lastError: String?
    var pendingMessageCount = 0
    var isQuotaExceeded = false
    /// True when Gateway tools (sessions_history/cron) are persistently failing,
    /// typically due to an internal token mismatch. Gateway restart may be needed.
    var hasToolSyncIssue = false

    // MARK: - Private

    // Created on first access to avoid SIGTRAP when CloudKit entitlements are absent.
    @ObservationIgnored private var cachedContainer: CKContainer?
    @ObservationIgnored private var cachedDatabase: CKDatabase?
    private var container: CKContainer {
        if let c = cachedContainer { return c }
        let c = CKContainer(identifier: CloudKitConstants.containerID)
        cachedContainer = c
        return c
    }
    private var database: CKDatabase {
        if let d = cachedDatabase { return d }
        let d = container.privateCloudDatabase
        cachedDatabase = d
        return d
    }
    private var syncEngine: CKSyncEngine?
    private var relayClient: GatewayRelayClient?
    private var pollingTask: Task<Void, Never>?
    private let messageGuard = MessageProcessingGuard()
    private var syncedCronRunIDs: Set<String> = []
    private var isCronInitialBackfill = false
    private var sessionHistoryLastSyncedMs: [String: Double] = [:]
    private var syncedGatewayMessageIDs: [String: Set<String>] = [:]

    /// Persisted sync engine state (token, etc.)
    private var lastSyncEngineState: CKSyncEngine.State.Serialization?

    private let logger = Logger(subsystem: "com.clawtower.app", category: "CloudKitRelay")
    private static let stateKey = "CloudKitSyncEngineState"
    private static let cronRunSyncedIDsKey = "CronRunSyncedIDs"
    private static let directFetchTokenKey = "CloudKitRelayZoneChangeToken"
    private static let processedClientMessageIDsKey = "ProcessedClientMessageIDs"
    private static let sessionCursorKey = "CloudKitRelaySessionHistoryLastSyncedMs"
    private static let sessionSyncedIDsKey = "CloudKitRelaySessionHistorySyncedIDs"
    private static let monitoredMainSessions = [
        "agent:main:main",
    ]

    init() {
        // CKContainer is created lazily to avoid SIGTRAP when CloudKit entitlements are absent.
        NSLog("[CloudKitRelay] init — deferred container creation for: %@", CloudKitConstants.containerID)
    }

    // MARK: - iCloud status

    func checkiCloudStatus() async -> CKAccountStatus {
        do {
            return try await container.accountStatus()
        } catch {
            NSLog("[CloudKitRelay] Failed to check iCloud status: %@", error.localizedDescription)
            return .couldNotDetermine
        }
    }

    // MARK: - Lifecycle

    func start(gatewayBaseURL: URL, authToken: String) {
        guard !isRunning else {
            NSLog("[CloudKitRelay] already running, skipping start")
            return
        }

        // Validate port is non-zero
        if let port = gatewayBaseURL.port, port == 0 {
            NSLog("[CloudKitRelay] ⚠️ WARNING: gateway port is 0! URL=%@", gatewayBaseURL.absoluteString)
        }

        NSLog("[CloudKitRelay] start() called — gateway: %@", gatewayBaseURL.absoluteString)
        logger.info("Starting CloudKit Relay Service")
        relayClient = GatewayRelayClient(baseURL: gatewayBaseURL, authToken: authToken)

        // Check iCloud status first
        Task {
            let status = await checkiCloudStatus()
            guard status == .available else {
                let msg: String
                switch status {
                case .noAccount: msg = "请先登录 iCloud"
                case .restricted: msg = "iCloud 访问受限"
                case .temporarilyUnavailable: msg = "iCloud 暂时不可用"
                default: msg = "无法确定 iCloud 状态"
                }
                NSLog("[CloudKitRelay] iCloud not available: %@", msg)
                lastError = msg
                return
            }
            await self.startSyncEngine()
        }
    }

    private static let envMigrationKey = "CloudKitEnvMigratedToDev"

    /// Clear all cached sync state when switching CloudKit environment (e.g. Production → Development).
    private func clearSyncStateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.envMigrationKey) else { return }
        NSLog("[CloudKitRelay] 🔄 Clearing sync state for CloudKit environment switch to Development")
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
        UserDefaults.standard.removeObject(forKey: Self.directFetchTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.cronRunSyncedIDsKey)
        UserDefaults.standard.removeObject(forKey: Self.processedClientMessageIDsKey)
        UserDefaults.standard.removeObject(forKey: Self.sessionCursorKey)
        UserDefaults.standard.removeObject(forKey: Self.sessionSyncedIDsKey)
        UserDefaults.standard.set(true, forKey: Self.envMigrationKey)
        NSLog("[CloudKitRelay] ✅ Sync state cleared")
    }

    private func startSyncEngine() {
        do {
            // One-time: clear cached sync state after environment switch
            clearSyncStateIfNeeded()

            // Load persisted sync state
            lastSyncEngineState = loadSyncState()
            syncedCronRunIDs = loadSyncedCronRunIDs()
            Task { await messageGuard.loadProcessedIDs(loadProcessedClientMessageIDs()) }
            sessionHistoryLastSyncedMs = loadSessionHistoryCursors()
            syncedGatewayMessageIDs = loadSessionSyncedMessageIDs()
            isCronInitialBackfill = syncedCronRunIDs.isEmpty

            // Load direct fetch change token
            if let data = UserDefaults.standard.data(forKey: Self.directFetchTokenKey),
               let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) {
                directFetchChangeToken = token
                NSLog("[CloudKitRelay] Loaded persisted direct fetch change token")
            }

            // Initialize session history cursors to "now" on first run to avoid backfilling old messages
            if sessionHistoryLastSyncedMs.isEmpty {
                let nowMs = Date().timeIntervalSince1970 * 1000
                for sessionKey in Self.monitoredMainSessions {
                    sessionHistoryLastSyncedMs[sessionKey] = nowMs
                }
                saveSessionHistoryCursors(sessionHistoryLastSyncedMs)
            }

            // Initialize CKSyncEngine
            let delegate = SyncEngineDelegate(service: self)
            let config = CKSyncEngine.Configuration(
                database: database,
                stateSerialization: lastSyncEngineState,
                delegate: delegate
            )
            syncEngine = CKSyncEngine(config)
            isRunning = true
            lastError = nil
            NSLog("[CloudKitRelay] Using container=%@ zone=%@", CloudKitConstants.containerID, CloudKitConstants.zoneID.zoneName)

            // Start fallback polling (every 3 seconds)
            startPolling()

            // Register zone subscription for push-triggered fetch
            Task {
                await registerZoneSubscription()
            }

            NSLog("[CloudKitRelay] Service started, polling every 3s")
            logger.info("CloudKit Relay Service started")
        } catch {
            NSLog("[CloudKitRelay] Failed to start sync engine: %@", error.localizedDescription)
            lastError = "CloudKit 启动失败: \(error.localizedDescription)"
        }
    }

    func stop() {
        logger.info("Stopping CloudKit Relay Service")
        pollingTask?.cancel()
        pollingTask = nil
        activeDirectFetchOperation?.cancel()
        activeDirectFetchOperation = nil
        isDirectFetchInFlight = false
        syncEngine = nil
        relayClient = nil
        isRunning = false
    }

    // MARK: - Polling fallback

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            var cronElapsedSeconds = 0
            var sessionHistoryElapsedSeconds = 0
            var toolBackoffRetrySeconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                guard let self else { continue }

                await self.pollForPendingMessages()

                cronElapsedSeconds += 3
                sessionHistoryElapsedSeconds += 3
                toolBackoffRetrySeconds += 3

                // Sync tool error state from relay client
                if let client = self.relayClient {
                    let backoff = await client.hasToolErrorBackoff
                    if self.hasToolSyncIssue != backoff {
                        self.hasToolSyncIssue = backoff
                    }
                }

                // Periodically reset tool error backoff so we retry after ~2 minutes
                if toolBackoffRetrySeconds >= 120 {
                    toolBackoffRetrySeconds = 0
                    await self.relayClient?.resetToolErrors()
                    self.hasToolSyncIssue = false
                }

                if cronElapsedSeconds >= 10 {
                    cronElapsedSeconds = 0
                    await self.pollCronRuns()
                }
                if sessionHistoryElapsedSeconds >= 15 {
                    sessionHistoryElapsedSeconds = 0
                    await self.pollGatewaySessionHistory()
                }
            }
        }
    }

    @ObservationIgnored private var pollDiagCounter = 0
    @ObservationIgnored private var hasCompletedInitialFullFetch = false
    @ObservationIgnored private var directFetchChangeToken: CKServerChangeToken?
    @ObservationIgnored private var activeDirectFetchOperation: CKFetchRecordZoneChangesOperation?
    @ObservationIgnored private var isDirectFetchInFlight = false
    @ObservationIgnored private var directFetchBackoffUntil = Date.distantPast
    @ObservationIgnored private var directFetchFailureCount = 0

    /// Poll for pending messages using direct CKFetchRecordZoneChangesOperation with persisted change token.
    /// First poll (nil token) does a full fetch; subsequent polls are incremental.
    private func pollForPendingMessages() async {
        guard isRunning else { return }

        pollDiagCounter += 1
        let shouldLogDiag = (pollDiagCounter % 10 == 1) // Log every ~30s

        if isDirectFetchInFlight {
            if shouldLogDiag {
                NSLog("[CloudKitRelay] Poll diag #%d: skip direct fetch because previous fetch still running", pollDiagCounter)
            }
            return
        }

        if Date() < directFetchBackoffUntil {
            if shouldLogDiag {
                NSLog("[CloudKitRelay] Poll diag #%d: direct fetch in backoff, using fallback path", pollDiagCounter)
            }
            await pollPendingMessagesFallback(reason: "directFetchBackoff")
            return
        }

        do {
            let records = try await fetchZoneChangesDirectly()
            directFetchFailureCount = 0
            lastSyncDate = Date()

            // Filter for pending toGateway messages
            var processedCount = 0
            for (message, record) in records {
                if message.direction == .toGateway && message.status == .pending {
                    await processIncomingMessage(message, record: record)
                    processedCount += 1
                }
            }

            if shouldLogDiag {
                NSLog("[CloudKitRelay] Poll diag #%d: directFetch got %d records, %d pending toGateway, zone=%@",
                      pollDiagCounter, records.count, processedCount, CloudKitConstants.zoneID.zoneName)
            }
        } catch {
            handleDirectFetchFailure(error)
            await pollPendingMessagesFallback(reason: error.localizedDescription)
        }
    }

    // MARK: - Direct zone changes fetch

    /// Fetch zone changes using CKFetchRecordZoneChangesOperation with persisted change token.
    /// Returns all MessageRecords found (caller filters by direction/status).
    private func fetchZoneChangesDirectly() async throws -> [(MessageRecord, CKRecord)] {
        isDirectFetchInFlight = true
        return try await withCheckedThrowingContinuation { continuation in
            let zoneID = CloudKitConstants.zoneID
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: directFetchChangeToken
            )

            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: config]
            )

            activeDirectFetchOperation = operation
            var results: [(MessageRecord, CKRecord)] = []

            operation.recordWasChangedBlock = { _, result in
                switch result {
                case .success(let record):
                    guard record.recordType == MessageRecord.recordType else { return }
                    if let msg = MessageRecord.from(record: record) {
                        results.append((msg, record))
                    }
                case .failure(let error):
                    NSLog("[CloudKitRelay] directFetch recordWasChanged error: %@", error.localizedDescription)
                }
            }

            operation.recordZoneChangeTokensUpdatedBlock = { [weak self] _, token, _ in
                guard let token else { return }
                Task { @MainActor in
                    self?.directFetchChangeToken = token
                    Self.saveDirectFetchToken(token)
                }
            }

            operation.recordZoneFetchCompletionBlock = { [weak self] _, token, _, _, error in
                if let error, (error as? CKError)?.code == .changeTokenExpired {
                    Task { @MainActor in
                        self?.directFetchChangeToken = nil
                        Self.saveDirectFetchToken(nil)
                        NSLog("[CloudKitRelay] Change token expired, will do full fetch next poll")
                    }
                } else if let token {
                    Task { @MainActor in
                        self?.directFetchChangeToken = token
                        Self.saveDirectFetchToken(token)
                    }
                }
            }

            operation.fetchRecordZoneChangesCompletionBlock = { [weak self] error in
                Task { @MainActor in
                    self?.isDirectFetchInFlight = false
                    self?.activeDirectFetchOperation = nil
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: results)
                    }
                }
            }

            operation.qualityOfService = .userInitiated
            self.database.add(operation)
        }
    }

    private static func saveDirectFetchToken(_ token: CKServerChangeToken?) {
        guard let token else {
            UserDefaults.standard.removeObject(forKey: directFetchTokenKey)
            return
        }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            UserDefaults.standard.set(data, forKey: directFetchTokenKey)
        } catch {
            NSLog("[CloudKitRelay] Failed to save direct fetch token: %@", error.localizedDescription)
        }
    }

    private func handleDirectFetchFailure(_ error: Error) {
        let nsError = error as NSError
        let ckError = error as? CKError
        let message = error.localizedDescription
        NSLog("[CloudKitRelay] ❌ fetchZoneChangesDirectly error: %@", message)
        logger.error("fetchZoneChangesDirectly error: \(message)")

        if ckError?.code == .changeTokenExpired {
            directFetchChangeToken = nil
            Self.saveDirectFetchToken(nil)
        }

        let looksLikeClientValidationFailure = message.localizedCaseInsensitiveContains("Client went away before operation")
            || nsError.domain == CKError.errorDomain
                && (ckError?.code == .serviceUnavailable || ckError?.code == .networkFailure || ckError?.code == .networkUnavailable)

        if looksLikeClientValidationFailure {
            directFetchChangeToken = nil
            Self.saveDirectFetchToken(nil)
            directFetchFailureCount += 1
            let backoffSeconds = min(pow(2.0, Double(directFetchFailureCount)), 30.0)
            directFetchBackoffUntil = Date().addingTimeInterval(backoffSeconds)
            NSLog("[CloudKitRelay] Direct fetch entering backoff for %.0fs", backoffSeconds)
        }
    }

    private func pollPendingMessagesFallback(reason: String) async {
        guard isRunning else { return }

        do {
            if let syncEngine {
                try? await syncEngine.fetchChanges()
            }

            let records = try await fetchPendingMessagesByQuery()
            if !records.isEmpty {
                NSLog("[CloudKitRelay] Fallback pending-message query returned %d records (reason=%@)", records.count, reason)
            }
            for (message, record) in records {
                await processIncomingMessage(message, record: record)
            }
            lastSyncDate = Date()
        } catch {
            NSLog("[CloudKitRelay] ❌ fallback pending-message query failed: %@", error.localizedDescription)
            logger.error("fallback pending-message query failed: \(error.localizedDescription)")
        }
    }

    private func fetchPendingMessagesByQuery() async throws -> [(MessageRecord, CKRecord)] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = NSPredicate(
                format: "direction == %@ AND status == %@",
                MessageDirection.toGateway.rawValue,
                MessageStatus.pending.rawValue
            )
            let query = CKQuery(recordType: MessageRecord.recordType, predicate: predicate)
            let operation = CKQueryOperation(query: query)
            operation.zoneID = CloudKitConstants.zoneID

            var results: [(MessageRecord, CKRecord)] = []

            operation.recordMatchedBlock = { _, result in
                switch result {
                case .success(let record):
                    guard let message = MessageRecord.from(record: record) else { return }
                    results.append((message, record))
                case .failure(let error):
                    NSLog("[CloudKitRelay] fallback query recordMatched error: %@", error.localizedDescription)
                }
            }

            operation.queryResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: results)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            operation.qualityOfService = .utility
            self.database.add(operation)
        }
    }

    /// Fetch all records from the zone using CKFetchRecordZoneChangesOperation with nil token
    /// (full fetch), then filter for pending toGateway messages in memory.
    private func fetchPendingMessagesDirectly() async throws -> [(MessageRecord, CKRecord)] {
        try await withCheckedThrowingContinuation { continuation in
            let zoneID = CloudKitConstants.zoneID
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: nil  // nil = full fetch from beginning
            )

            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: config]
            )

            var results: [(MessageRecord, CKRecord)] = []
            var totalRecordCount = 0

            operation.recordWasChangedBlock = { _, result in
                switch result {
                case .success(let record):
                    totalRecordCount += 1
                    guard record.recordType == MessageRecord.recordType else { return }
                    guard let message = MessageRecord.from(record: record) else { return }
                    if message.direction == .toGateway && message.status == .pending {
                        NSLog("[CloudKitRelay] Direct fetch found pending: id=%@ session=%@",
                              message.id, message.sessionKey)
                        results.append((message, record))
                    }
                case .failure(let error):
                    NSLog("[CloudKitRelay] directFetch recordWasChanged error: %@", error.localizedDescription)
                }
            }

            operation.fetchRecordZoneChangesCompletionBlock = { error in
                NSLog("[CloudKitRelay] Direct fetch parsed: %d total, %d pending toGateway", totalRecordCount, results.count)
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: results)
                }
            }

            operation.qualityOfService = .userInitiated
            database.add(operation)
        }
    }

    private func pollCronRuns() async {
        guard isRunning, let relayClient else { return }

        do {
            let jobs = try await relayClient.fetchCronJobs()
            let nowMs = Date().timeIntervalSince1970 * 1000
            let minRunAtMs = isCronInitialBackfill ? (nowMs - 3600 * 1000) : 0
            var hasNewSyncedIDs = false

            for job in jobs where job.enabled {
                let runs = try await relayClient.fetchCronRuns(jobId: job.id)
                for run in runs where run.status == "ok" {
                    guard run.runAtMs >= minRunAtMs else { continue }
                    guard let summary = run.summary?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                    guard !shouldSkipGatewayAssistantMessage(summary) else { continue }
                    guard !(job.delivery?.mode == "none" && !hasSubstantialContent(summary)) else { continue }

                    let runID = buildCronRunID(jobID: job.id, run: run)
                    guard !syncedCronRunIDs.contains(runID) else { continue }

                    try await writeCronRunMessageToCloudKit(job: job, run: run, summary: summary)
                    syncedCronRunIDs.insert(runID)
                    hasNewSyncedIDs = true
                }
            }

            if isCronInitialBackfill {
                isCronInitialBackfill = false
            }

            if syncedCronRunIDs.count > 2000 {
                syncedCronRunIDs = Set(syncedCronRunIDs.suffix(2000))
                hasNewSyncedIDs = true
            }
            if hasNewSyncedIDs {
                saveSyncedCronRunIDs(syncedCronRunIDs)
            }
        } catch let ckError as CKError where ckError.code == .quotaExceeded {
            logger.error("iCloud quota exceeded during cron run sync")
            lastError = "iCloud 空间不足，无法同步消息"
            isQuotaExceeded = true
        } catch {
            logger.error("Cron runs poll failed: \(error.localizedDescription)")
        }
    }

    private func pollGatewaySessionHistory() async {
        guard isRunning, let relayClient else { return }

        for sessionKey in Self.monitoredMainSessions {
            do {
                let messages = try await relayClient.fetchSessionHistory(sessionKey: sessionKey, limit: 80)
                guard !messages.isEmpty else { continue }

                let lastSyncedMs = sessionHistoryLastSyncedMs[sessionKey] ?? 0
                var sessionSyncedIDs = syncedGatewayMessageIDs[sessionKey] ?? []
                var maxTimestamp = lastSyncedMs

                for message in messages where message.role == "assistant" {
                    maxTimestamp = max(maxTimestamp, message.timestampMs)
                    guard message.timestampMs > lastSyncedMs else { continue }
                    guard !sessionSyncedIDs.contains(message.id) else { continue }
                    guard !shouldSkipGatewayAssistantMessage(message.content) else {
                        sessionSyncedIDs.insert(message.id)
                        continue
                    }

                    try await writeGatewayHistoryMessageToCloudKit(
                        sessionKey: sessionKey,
                        content: message.content,
                        sourceMessageID: message.id,
                        timestampMs: message.timestampMs
                    )

                    sessionSyncedIDs.insert(message.id)
                }

                sessionHistoryLastSyncedMs[sessionKey] = maxTimestamp
                if sessionSyncedIDs.count > 200 {
                    sessionSyncedIDs = Set(sessionSyncedIDs.suffix(200))
                }
                syncedGatewayMessageIDs[sessionKey] = sessionSyncedIDs
            } catch let ckError as CKError where ckError.code == .quotaExceeded {
                logger.error("iCloud quota exceeded during session history sync")
                lastError = "iCloud 空间不足，无法同步消息"
                isQuotaExceeded = true
            } catch {
                logger.error("Session history poll failed for \(sessionKey): \(error.localizedDescription)")
            }
        }

        saveSessionHistoryCursors(sessionHistoryLastSyncedMs)
        saveSessionSyncedMessageIDs(syncedGatewayMessageIDs)
    }

    private func writeGatewayHistoryMessageToCloudKit(
        sessionKey: String,
        content: String,
        sourceMessageID: String,
        timestampMs: Double
    ) async throws {
        let metadataDict: [String: String] = [
            "source": "gateway-session-history",
            "sessionMessageId": sourceMessageID,
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadataDict)
        let metadata = String(data: metadataData, encoding: .utf8) ?? "{}"

        let timestamp = timestampMs > 0
            ? Date(timeIntervalSince1970: timestampMs / 1000)
            : Date()

        let responseMessage = MessageRecord(
            id: UUID().uuidString,
            sessionKey: sessionKey,
            direction: .fromGateway,
            content: content,
            status: .pending,
            timestamp: timestamp,
            metadata: metadata
        )
        try await database.save(responseMessage.toCKRecord())
    }

    private func buildCronRunID(jobID: String, run: GatewayRelayClient.CronRun) -> String {
        if let sessionId = run.sessionId, !sessionId.isEmpty {
            return "\(jobID):\(sessionId)"
        }
        return "\(jobID):\(run.runAtMs):\(run.durationMs ?? 0)"
    }

    private func hasSubstantialContent(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2
    }

    private func writeCronRunMessageToCloudKit(
        job: GatewayRelayClient.CronJob,
        run: GatewayRelayClient.CronRun,
        summary: String
    ) async throws {
        let metadataDict: [String: String] = [
            "source": "cron",
            "jobName": job.name,
            "jobId": job.id,
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadataDict)
        let metadata = String(data: metadataData, encoding: .utf8) ?? "{}"

        // Use the cron run's session key if available so messages appear
        // in the correct cron sub-session on iOS instead of the main session.
        let sessionKey: String
        if let runSessionId = run.sessionId, !runSessionId.isEmpty {
            // sessionId from the Gateway is already a full session key (e.g. "agent:main:cron-xxx")
            if runSessionId.contains(":") {
                sessionKey = runSessionId
            } else {
                sessionKey = "agent:\(job.agentId):cron-\(runSessionId)"
            }
        } else {
            sessionKey = "agent:\(job.agentId):main"
        }
        let timestamp = Date(timeIntervalSince1970: run.runAtMs / 1000)

        let responseMessage = MessageRecord(
            id: UUID().uuidString,
            sessionKey: sessionKey,
            direction: .fromGateway,
            content: summary,
            status: .pending,
            timestamp: timestamp,
            metadata: metadata
        )
        try await database.save(responseMessage.toCKRecord())
    }

    private func shouldSkipGatewayAssistantMessage(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed == "NO_REPLY" { return true }
        if trimmed == "HEARTBEAT_OK" { return true }
        if trimmed.contains("ANNOUNCE_SKIP") { return true }
        return false
    }

    // MARK: - Message processing

    func processIncomingMessage(_ message: MessageRecord, record: CKRecord) async {
        guard message.direction == .toGateway, message.status == .pending else { return }

        let clientMessageId = extractClientMessageID(from: message)
        guard await messageGuard.tryAcquire(messageID: message.id, clientMessageID: clientMessageId) else {
            NSLog("[CloudKitRelay] Skip duplicate/in-progress message: %@", message.id)
            // Still try to ACK if it was a duplicate (already processed)
            if let cid = clientMessageId, await messageGuard.isProcessed(clientMessageID: cid) {
                do {
                    let latestRecord = try await database.record(for: record.recordID)
                    latestRecord["status"] = MessageStatus.delivered.rawValue as CKRecordValue
                    try await database.save(latestRecord)
                } catch {
                    logger.warning("Failed to ack duplicate message \(message.id) (non-critical): \(error.localizedDescription)")
                }
            }
            return
        }

        NSLog("[CloudKitRelay] processIncomingMessage: id=%@ session=%@", message.id, message.sessionKey)
        if let sourceInfo = extractSourceInfo(from: message) {
            NSLog("[CloudKitRelay] Source metadata for %@: platform=%@ clientId=%@ transport=%@", message.id, sourceInfo.platform, sourceInfo.clientId, sourceInfo.transport)
        } else {
            NSLog("[CloudKitRelay] Source metadata for %@: unavailable", message.id)
        }

        guard let relayClient else {
            logger.error("Relay client not configured")
            return
        }

        // ACK stage 1: mark as received (macOS got the message, about to forward to Gateway)
        do {
            let latestRecord = try await database.record(for: record.recordID)
            latestRecord["status"] = MessageStatus.received.rawValue as CKRecordValue
            try await database.save(latestRecord)
            NSLog("[CloudKitRelay] ✅ ACK stage 1 (received) for %@", message.id)
        } catch {
            NSLog("[CloudKitRelay] ⚠️ ACK stage 1 failed for %@ (non-critical): %@", message.id, error.localizedDescription)
        }

        // Save image to local file and append path to message text (Gateway drops image_url content parts)
        let fm = FileManager.default
        let mediaDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw/media/inbound")
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        var imageLocalPath: String?

        // Check for CKAsset image — first try from MessageRecord, then directly from CKRecord
        let effectiveAsset = message.imageAsset ?? (record["imageAsset"] as? CKAsset)
        NSLog("[CloudKitRelay] Checking CKAsset: imageAsset=%@", effectiveAsset.map { String(describing: $0) } ?? "nil")
        if let asset = effectiveAsset {
            NSLog("[CloudKitRelay] CKAsset fileURL=%@", asset.fileURL?.absoluteString ?? "nil")
            if let fileURL = asset.fileURL {
                let exists = fm.fileExists(atPath: fileURL.path)
                let size: Int64 = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? -1
                NSLog("[CloudKitRelay] CKAsset file exists=%d, size=%lld", exists ? 1 : 0, size)
                if let imageData = try? Data(contentsOf: fileURL) {
                    NSLog("[CloudKitRelay] ✅ Image extracted: %d bytes", imageData.count)
                    let savedName = UUID().uuidString + ".jpg"
                    let savedURL = mediaDir.appendingPathComponent(savedName)
                    try? imageData.write(to: savedURL)
                    imageLocalPath = savedURL.path
                } else {
                    NSLog("[CloudKitRelay] ❌ Failed to extract image from CKAsset")
                }
            } else {
                NSLog("[CloudKitRelay] ❌ Failed to extract image from CKAsset — fileURL is nil, will re-fetch record")
                // CKAsset fileURL is nil — re-fetch the full record to download the asset
                do {
                    let fullRecord = try await database.record(for: record.recordID)
                    if let refetchedAsset = fullRecord["imageAsset"] as? CKAsset,
                       let refetchedURL = refetchedAsset.fileURL,
                       let imageData = try? Data(contentsOf: refetchedURL) {
                        NSLog("[CloudKitRelay] ✅ Image extracted after re-fetch: %d bytes", imageData.count)
                        let savedName = UUID().uuidString + ".jpg"
                        let savedURL = mediaDir.appendingPathComponent(savedName)
                        try? imageData.write(to: savedURL)
                        imageLocalPath = savedURL.path
                    } else {
                        NSLog("[CloudKitRelay] ❌ Failed to extract image even after re-fetch")
                    }
                } catch {
                    NSLog("[CloudKitRelay] ❌ Re-fetch record failed: %@", error.localizedDescription)
                }
            }
        }

        // Fallback: legacy base64 in metadata — save to file instead of data URL
        if imageLocalPath == nil,
           let metaData = message.metadata.data(using: .utf8),
           let metaJson = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
           let atts = metaJson["attachments"] as? [[String: String]], !atts.isEmpty,
           let firstAtt = atts.first,
           firstAtt["type"] == "image_url",
           let dataURL = firstAtt["url"], dataURL.hasPrefix("data:"),
           let commaIndex = dataURL.firstIndex(of: ",") {
            let base64String = String(dataURL[dataURL.index(after: commaIndex)...])
            if let data = Data(base64Encoded: base64String) {
                let savedName = UUID().uuidString + ".jpg"
                let savedURL = mediaDir.appendingPathComponent(savedName)
                try? data.write(to: savedURL)
                imageLocalPath = savedURL.path
            }
        }

        do {
            var messageText = message.content
            if let path = imageLocalPath {
                messageText = messageText.isEmpty ? path : messageText + "\n" + path
            }

            // Inject source metadata so the agent can tell which device/platform sent the message.
            if let metaData = message.metadata.data(using: .utf8),
               let metaJson = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
                let platform = (metaJson["sourcePlatform"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let clientId = (metaJson["clientId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

                if platform?.isEmpty == false || clientId?.isEmpty == false {
                    var conversationInfo: [String: Any] = [:]

                    if let platform, !platform.isEmpty {
                        conversationInfo["source_platform"] = platform
                    }
                    if let clientId, !clientId.isEmpty {
                        conversationInfo["client_id"] = clientId
                    }

                    conversationInfo["message_id"] = "webchat:\(message.id)"

                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = .current
                    formatter.dateFormat = "EEE yyyy-MM-dd HH:mm zzz"
                    conversationInfo["timestamp"] = formatter.string(from: message.timestamp)

                    if let attachments = metaJson["attachments"] as? [[String: Any]],
                       let firstAttachment = attachments.first,
                       let transport = firstAttachment["transport"] as? String,
                       !transport.isEmpty {
                        conversationInfo["attachment_transport"] = transport
                    }

                    if let infoData = try? JSONSerialization.data(withJSONObject: conversationInfo, options: [.prettyPrinted, .sortedKeys]),
                       let infoStr = String(data: infoData, encoding: .utf8) {
                        let prefix = """
                        Conversation info (untrusted metadata):
                        ```json
                        \(infoStr)
                        ```

                        """
                        messageText = prefix + messageText
                    }
                }
            }

            let contentPreview = String(messageText.prefix(50))
            NSLog("[CloudKitRelay] Sending to Gateway: session=%@ content=%@", message.sessionKey, contentPreview)
            let response: String
            NSLog("[CloudKitRelay] 📝 Sending text%@", imageLocalPath != nil ? " (with image path)" : " only (no attachments)")
            response = try await relayClient.sendMessage(
                sessionKey: message.sessionKey,
                message: messageText
            )
            NSLog("[CloudKitRelay] Gateway responded: %d chars", response.count)

            // Extract image file paths from AI response and attach as CKAsset
            let (responseImageAsset, responseTempURL) = Self.extractImageAssetFromResponse(response)
            if responseImageAsset != nil {
                NSLog("[CloudKitRelay] 🖼️ Found image in AI response, attaching as CKAsset")
            }

            // 1. Write response FIRST as a new record (independent of ACK)
            var responseMessage = MessageRecord(
                id: UUID().uuidString,
                sessionKey: message.sessionKey,
                direction: .fromGateway,
                content: response,
                status: .pending,
                timestamp: Date(),
                metadata: message.metadata
            )
            responseMessage.imageAsset = responseImageAsset
            NSLog("[CloudKitRelay] Writing response to CloudKit: id=%@ hasImage=%d", responseMessage.id, responseImageAsset != nil ? 1 : 0)
            try await database.save(responseMessage.toCKRecord())
            // Clean up temp file after save
            if let responseTempURL {
                try? FileManager.default.removeItem(at: responseTempURL)
            }
            NSLog("[CloudKitRelay] ✅ Response saved to CloudKit")

            // Advance session history cursor to avoid re-importing this response
            let nowMs = Date().timeIntervalSince1970 * 1000
            sessionHistoryLastSyncedMs[message.sessionKey] = max(sessionHistoryLastSyncedMs[message.sessionKey] ?? 0, nowMs)
            saveSessionHistoryCursors(sessionHistoryLastSyncedMs)

            await messageGuard.markProcessed(messageID: message.id, clientMessageID: clientMessageId)
            saveProcessedClientMessageIDs(await messageGuard.allProcessedIDs())

            // 2. ACK original message (best effort — re-fetch to avoid oplock conflict)
            do {
                let latestRecord = try await database.record(for: record.recordID)
                latestRecord["status"] = MessageStatus.delivered.rawValue as CKRecordValue
                try await database.save(latestRecord)
                NSLog("[CloudKitRelay] ✅ ACK succeeded for %@", message.id)
            } catch {
                NSLog("[CloudKitRelay] ⚠️ ACK failed for %@ (best effort, response already saved): %@", message.id, error.localizedDescription)
                logger.warning("ACK failed for \(message.id): \(error.localizedDescription)")
            }

            logger.info("Relayed message \(message.id), response written")
            isQuotaExceeded = false
        } catch let ckError as CKError where ckError.code == .quotaExceeded {
            NSLog("[CloudKitRelay] ❌ iCloud quota exceeded for message %@", message.id)
            logger.error("iCloud quota exceeded — cannot save relay response")
            await messageGuard.release(messageID: message.id)
            lastError = "iCloud 空间不足，无法同步消息"
            isQuotaExceeded = true
        } catch {
            NSLog("[CloudKitRelay] Relay failed for %@: %@", message.id, error.localizedDescription)
            logger.error("Failed to relay message \(message.id): \(error.localizedDescription)")
            await messageGuard.release(messageID: message.id)
            lastError = error.localizedDescription
        }
    }

    // MARK: - Image extraction from AI response

    /// Scans the AI response text for local image file paths and returns a CKAsset if found.
    /// Supports markdown image syntax, absolute paths, and tilde paths.
    /// Returns (CKAsset, tempFileURL) — caller should delete tempFileURL after CloudKit save.
    private static func extractImageAssetFromResponse(_ response: String) -> (CKAsset?, URL?) {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"]
        let fm = FileManager.default

        var candidatePaths: [String] = []

        // Markdown images: ![...]( /path/to/file.ext )
        let markdownPattern = try? NSRegularExpression(pattern: #"!\[.*?\]\((/[^)]+)\)"#)
        if let matches = markdownPattern?.matches(in: response, range: NSRange(response.startIndex..., in: response)) {
            for match in matches {
                if let range = Range(match.range(at: 1), in: response) {
                    candidatePaths.append(String(response[range]).trimmingCharacters(in: .whitespaces))
                }
            }
        }

        // Bare absolute paths: /Users/... or /tmp/... or /var/... ending with image extension
        let pathPattern = try? NSRegularExpression(pattern: #"(?:^|[\s`\"'(])(/(?:Users|tmp|var|private)[^\s`\"')]*\.(?:png|jpg|jpeg|gif|webp|bmp|tiff|heic))"#, options: [.caseInsensitive])
        if let matches = pathPattern?.matches(in: response, range: NSRange(response.startIndex..., in: response)) {
            for match in matches {
                if let range = Range(match.range(at: 1), in: response) {
                    candidatePaths.append(String(response[range]).trimmingCharacters(in: .whitespaces))
                }
            }
        }

        // Tilde paths: ~/Desktop/image.png
        let tildePattern = try? NSRegularExpression(pattern: #"(?:^|[\s`\"'(])(~/[^\s`\"')]*\.(?:png|jpg|jpeg|gif|webp|bmp|tiff|heic))"#, options: [.caseInsensitive])
        if let matches = tildePattern?.matches(in: response, range: NSRange(response.startIndex..., in: response)) {
            for match in matches {
                if let range = Range(match.range(at: 1), in: response) {
                    let tildePath = String(response[range]).trimmingCharacters(in: .whitespaces)
                    candidatePaths.append(NSString(string: tildePath).expandingTildeInPath)
                }
            }
        }

        // Deduplicate and try each candidate
        var seen = Set<String>()
        for path in candidatePaths {
            guard seen.insert(path).inserted else { continue }

            let ext = (path as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            guard fm.fileExists(atPath: path) else {
                NSLog("[CloudKitRelay] 🖼️ Candidate image path not found: %@", path)
                continue
            }

            guard let imageData = fm.contents(atPath: path) else {
                NSLog("[CloudKitRelay] 🖼️ Could not read image at: %@", path)
                continue
            }

            NSLog("[CloudKitRelay] 🖼️ Found image in response: %@ (%d bytes)", path, imageData.count)

            // Write to temp file for CKAsset (CKAsset supports large files natively)
            let tempURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            do {
                try imageData.write(to: tempURL)
                let asset = CKAsset(fileURL: tempURL)
                return (asset, tempURL)
            } catch {
                NSLog("[CloudKitRelay] 🖼️ Failed to write temp image: %@", error.localizedDescription)
                continue
            }
        }

        return (nil, nil)
    }

    // MARK: - CKSyncEngine handling

    func handleSyncEvent(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let stateUpdate):
            saveSyncState(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            handleAccountChange(accountChange)

        case .fetchedDatabaseChanges(let fetchedChanges):
            handleFetchedDatabaseChanges(fetchedChanges)

        case .fetchedRecordZoneChanges(let fetchedChanges):
            handleFetchedRecordZoneChanges(fetchedChanges)

        case .sentRecordZoneChanges(let sentChanges):
            handleSentRecordZoneChanges(sentChanges)

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchChanges,
             .didFetchRecordZoneChanges, .willSendChanges, .didSendChanges,
             .sentDatabaseChanges:
            break

        @unknown default:
            logger.warning("Unknown sync engine event")
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingChanges = syncEngine?.state.pendingRecordZoneChanges ?? []
        let scope = context.options.scope

        let filteredChanges: [CKSyncEngine.PendingRecordZoneChange]
        switch scope {
        case .zoneIDs(let zoneIDs):
            filteredChanges = pendingChanges.filter { change in
                let zoneID: CKRecordZone.ID
                switch change {
                case .saveRecord(let id):
                    zoneID = id.zoneID
                case .deleteRecord(let id):
                    zoneID = id.zoneID
                @unknown default:
                    return false
                }
                return zoneIDs.contains(zoneID)
            }
        default:
            filteredChanges = Array(pendingChanges)
        }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: filteredChanges) { _ in
            return nil
        }
    }

    // MARK: - Sync event handlers

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn, .switchAccounts:
            logger.info("iCloud account changed, restarting sync")
        case .signOut:
            logger.warning("iCloud account signed out")
            lastError = "iCloud 账号已登出"
        @unknown default:
            break
        }
    }

    private func handleFetchedDatabaseChanges(
        _ changes: CKSyncEngine.Event.FetchedDatabaseChanges
    ) {
        for modification in changes.modifications {
            logger.debug("Zone modified: \(modification.zoneID.zoneName)")
        }
    }

    private func handleFetchedRecordZoneChanges(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges
    ) {
        var pendingCount = 0
        var skippedCount = 0

        for modification in changes.modifications {
            let record = modification.record
            guard record.recordType == MessageRecord.recordType else { continue }
            guard let message = MessageRecord.from(record: record) else { continue }

            if message.direction == .toGateway && message.status == .pending {
                pendingCount += 1
                NSLog("[CloudKitRelay] ✅ Found pending toGateway message via sync: %@", message.id)
                Task {
                    await processIncomingMessage(message, record: record)
                }
            } else {
                skippedCount += 1
            }
        }

        if changes.modifications.count > 0 || changes.deletions.count > 0 {
            NSLog("[CloudKitRelay] fetchedRecordZoneChanges: %d modifications (%d pending, %d skipped), %d deletions",
                  changes.modifications.count, pendingCount, skippedCount, changes.deletions.count)
        }
        lastSyncDate = Date()
    }

    private func handleSentRecordZoneChanges(
        _ changes: CKSyncEngine.Event.SentRecordZoneChanges
    ) {
        for savedRecord in changes.savedRecords {
            logger.debug("Record saved to CloudKit: \(savedRecord.recordID.recordName)")
        }
        for failedSave in changes.failedRecordSaves {
            logger.error("Failed to save record: \(failedSave.record.recordID.recordName), error: \(failedSave.error.localizedDescription)")
        }
    }

    // MARK: - Zone subscription

    private func registerZoneSubscription() async {
        let subscriptionID = "clawtower-relay-zone-changes"

        do {
            _ = try await database.subscription(for: subscriptionID)
            NSLog("[CloudKitRelay] Zone subscription already exists")
            return
        } catch {
            // Subscription doesn't exist, create it
        }

        let subscription = CKRecordZoneSubscription(
            zoneID: CloudKitConstants.zoneID,
            subscriptionID: subscriptionID
        )

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            try await database.save(subscription)
            NSLog("[CloudKitRelay] ✅ Zone subscription registered")
        } catch {
            NSLog("[CloudKitRelay] ⚠️ Failed to register zone subscription: %@", error.localizedDescription)
        }
    }

    // MARK: - Zone creation

    func ensureZoneExists() async {
        let zone = CKRecordZone(zoneID: CloudKitConstants.zoneID)
        do {
            try await database.save(zone)
            NSLog("[CloudKitRelay] ClawTowerZone created or confirmed")
            logger.info("ClawTowerZone created or confirmed")
        } catch {
            NSLog("[CloudKitRelay] Zone creation result: %@", error.localizedDescription)
            logger.debug("Zone creation result: \(error.localizedDescription)")
        }
    }

    // MARK: - State persistence

    private func saveSyncState(_ state: CKSyncEngine.State.Serialization) {
        lastSyncEngineState = state
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        } catch {
            logger.error("Failed to save sync state: \(error.localizedDescription)")
        }
    }

    private func loadSyncState() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey) else { return nil }
        do {
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            logger.error("Failed to load sync state: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveSyncedCronRunIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: Self.cronRunSyncedIDsKey)
    }

    private func loadSyncedCronRunIDs() -> Set<String> {
        let raw = UserDefaults.standard.array(forKey: Self.cronRunSyncedIDsKey) as? [String] ?? []
        return Set(raw)
    }

    private struct SourceInfo {
        let platform: String
        let clientId: String
        let transport: String
    }

    private func extractSourceInfo(from message: MessageRecord) -> SourceInfo? {
        guard let data = message.metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let platform = (json["sourcePlatform"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientId = (json["clientId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = json["attachments"] as? [[String: Any]]
        let transport = attachments?.compactMap { $0["transport"] as? String }.first?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard platform?.isEmpty == false || clientId?.isEmpty == false || transport?.isEmpty == false else {
            return nil
        }

        return SourceInfo(
            platform: (platform?.isEmpty == false ? platform! : "unknown"),
            clientId: (clientId?.isEmpty == false ? clientId! : "unknown"),
            transport: (transport?.isEmpty == false ? transport! : "unknown")
        )
    }

    private func extractClientMessageID(from message: MessageRecord) -> String? {
        guard let data = message.metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientMessageID = json["clientMessageId"] as? String,
              !clientMessageID.isEmpty else {
            return nil
        }
        return clientMessageID
    }

    private func saveProcessedClientMessageIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: Self.processedClientMessageIDsKey)
    }

    private func loadProcessedClientMessageIDs() -> Set<String> {
        let raw = UserDefaults.standard.array(forKey: Self.processedClientMessageIDsKey) as? [String] ?? []
        return Set(raw)
    }

    private func saveSessionHistoryCursors(_ cursors: [String: Double]) {
        UserDefaults.standard.set(cursors, forKey: Self.sessionCursorKey)
    }

    private func loadSessionHistoryCursors() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: Self.sessionCursorKey) as? [String: Double] ?? [:]
    }

    private func saveSessionSyncedMessageIDs(_ idsBySession: [String: Set<String>]) {
        let serializable = idsBySession.mapValues { Array($0) }
        UserDefaults.standard.set(serializable, forKey: Self.sessionSyncedIDsKey)
    }

    private func loadSessionSyncedMessageIDs() -> [String: Set<String>] {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.sessionSyncedIDsKey) as? [String: [String]] else {
            return [:]
        }
        return raw.mapValues(Set.init)
    }
}

// MARK: - CKSyncEngineDelegate

private final class SyncEngineDelegate: CKSyncEngineDelegate {
    private let service: CloudKitRelayService

    init(service: CloudKitRelayService) {
        self.service = service
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        Task { @MainActor in
            service.handleSyncEvent(event)
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await service.nextRecordZoneChangeBatch(context)
    }
}

// MARK: - Message Processing Guard (actor-based dedup)

private actor MessageProcessingGuard {
    private var processingIDs: Set<String> = []
    private var processedClientIDs: Set<String> = []

    func tryAcquire(messageID: String, clientMessageID: String?) -> Bool {
        if processingIDs.contains(messageID) { return false }
        if let cid = clientMessageID, processedClientIDs.contains(cid) { return false }
        processingIDs.insert(messageID)
        return true
    }

    func markProcessed(messageID: String, clientMessageID: String?) {
        processingIDs.remove(messageID)
        if let cid = clientMessageID {
            processedClientIDs.insert(cid)
            if processedClientIDs.count > 2000 {
                processedClientIDs = Set(processedClientIDs.suffix(1000))
            }
        }
    }

    func release(messageID: String) {
        processingIDs.remove(messageID)
    }

    func isProcessed(clientMessageID: String) -> Bool {
        processedClientIDs.contains(clientMessageID)
    }

    func loadProcessedIDs(_ ids: Set<String>) {
        processedClientIDs = ids
    }

    func allProcessedIDs() -> Set<String> {
        processedClientIDs
    }
}
