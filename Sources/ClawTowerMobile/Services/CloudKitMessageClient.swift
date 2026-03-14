import CloudKit
import Foundation
import os.log
import UserNotifications

// MARK: - Codable extension for local cache

extension MessageDirection: Codable {}
extension MessageStatus: Codable {}

/// Codable wrapper for local JSON cache
struct CachedMessage: Codable {
    let id: String
    let sessionKey: String
    let direction: MessageDirection
    let content: String
    var status: MessageStatus
    let timestamp: Date
    let metadata: String

    init(from record: MessageRecord) {
        self.id = record.id
        self.sessionKey = record.sessionKey
        self.direction = record.direction
        self.content = record.content
        self.status = record.status
        self.timestamp = record.timestamp
        self.metadata = record.metadata
    }

    func toMessageRecord() -> MessageRecord {
        MessageRecord(
            id: id,
            sessionKey: sessionKey,
            direction: direction,
            content: content,
            status: status,
            timestamp: timestamp,
            metadata: metadata
        )
    }
}

/// iOS CloudKit message client — sends messages to macOS Gateway via CloudKit Private DB.
@MainActor
@Observable
final class CloudKitMessageClient {
    // MARK: - Observable state

    var messages: [MessageRecord] = []
    var isSyncing = false
    var lastSyncDate: Date?
    var lastError: String?
    var iCloudStatus: CKAccountStatus = .couldNotDetermine
    var unreadAgentIds: Set<String> = []
    var selectedAgentId = "main"
    var isWaitingForReply = false
    private(set) var optimisticallyReceivedMessageIDs: Set<String> = []

    // MARK: - Debug properties

    var debugICloudStatus: String = "检查中..."
    var debugLastFetchResult: String = "未执行"
    var debugLastFetchTime: Date?
    var debugRecordCount: Int = 0
    var debugSyncEngineActive: Bool = false
    var debugLastError: String?
    var debugContainerID: String = ""
    var debugTestWriteResult: String?
    var debugDashboardResult: String = "未测试"
    var debugDashboardLoading: Bool = false

    // MARK: - Private

    private let container: CKContainer
    private let database: CKDatabase
    private var syncEngine: CKSyncEngine?
    private var pollingTask: Task<Void, Never>?
    private var lastSyncEngineState: CKSyncEngine.State.Serialization?

    private let logger = Logger(subsystem: "com.clawtower.mobile", category: "CloudKitMessage")
    private static let stateKey = "MobileCloudKitSyncState"
    private static let agentKey = "SelectedAgentId"
    private static let notifiedIDsKey = "NotifiedMessageIDs"
    private var isInBackground = false
    private var isInitialSyncDone = false
    private var notifiedMessageIDs: Set<String> = []
    private let pollingIntervalForeground: TimeInterval = 5
    private let pollingIntervalBackground: TimeInterval = 30
    /// Change token for direct zone-change fetches (independent of CKSyncEngine state)
    private var directFetchChangeToken: CKServerChangeToken?
    private var activeDirectFetchOperation: CKFetchRecordZoneChangesOperation?
    private var isDirectFetchInFlight = false

    private func statusRank(_ status: MessageStatus) -> Int {
        switch status {
        case .pending: return 0
        case .sent: return 1
        case .received: return 2
        case .delivered: return 3
        case .read: return 4
        }
    }

    private func mergedStatus(local: MessageStatus, remote: MessageStatus) -> MessageStatus {
        statusRank(remote) >= statusRank(local) ? remote : local
    }
    private static let directFetchTokenKey = "DirectFetchChangeToken"

    private static let hasLaunchedBeforeKey = "HasLaunchedBefore_v1"

    init() {
        self.container = CKContainer(identifier: CloudKitConstants.containerID)
        self.database = container.privateCloudDatabase
        self.selectedAgentId = UserDefaults.standard.string(forKey: Self.agentKey) ?? "main"
        self.notifiedMessageIDs = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedIDsKey) ?? [])

        // On fresh install / reinstall, clear stale change token to force full fetch
        if !UserDefaults.standard.bool(forKey: Self.hasLaunchedBeforeKey) {
            NSLog("[CloudKitMessage] First launch detected — clearing stale change token")
            Self.saveDirectFetchToken(nil)
            UserDefaults.standard.set(true, forKey: Self.hasLaunchedBeforeKey)
            self.directFetchChangeToken = nil
        } else {
            self.directFetchChangeToken = Self.loadDirectFetchToken()
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard syncEngine == nil else { return }
        logger.info("Starting CloudKit message client")
        NSLog("[iOS] Using container=%@ zone=%@", CloudKitConstants.containerID, CloudKitConstants.zoneID.zoneName)
        debugContainerID = CloudKitConstants.containerID

        // Check iCloud status first; if unavailable, set error and bail
        Task {
            await checkiCloudStatus()
            updateDebugICloudStatus()
            guard iCloudStatus == .available else {
                switch iCloudStatus {
                case .noAccount:
                    lastError = "请在设置中登录 iCloud 以启用消息同步"
                case .restricted:
                    lastError = "iCloud 访问受限"
                case .temporarilyUnavailable:
                    lastError = "iCloud 暂时不可用，稍后重试"
                default:
                    lastError = "正在检查 iCloud 状态..."
                }
                NSLog("[CloudKitMessage] iCloud not available: %@", lastError ?? "")
                return
            }
            await self.startSyncEngine()
        }
    }

    private func startSyncEngine() async {
        lastSyncEngineState = loadSyncState()

        do {
            let delegate = MobileSyncEngineDelegate(client: self)
            let config = CKSyncEngine.Configuration(
                database: database,
                stateSerialization: lastSyncEngineState,
                delegate: delegate
            )
            syncEngine = CKSyncEngine(config)
            debugSyncEngineActive = true

            await ensureZoneExists()
            startPolling()

            // Register zone subscription for push-triggered fetch
            Task {
                await registerZoneSubscription()
            }

            lastError = nil
        } catch {
            NSLog("[CloudKitMessage] Failed to start sync engine: %@", error.localizedDescription)
            lastError = "CloudKit 启动失败: \(error.localizedDescription)"
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        activeDirectFetchOperation?.cancel()
        activeDirectFetchOperation = nil
        isDirectFetchInFlight = false
        syncEngine = nil
        debugSyncEngineActive = false
    }

    // MARK: - iCloud status

    func checkiCloudStatus() async {
        do {
            iCloudStatus = try await container.accountStatus()
        } catch {
            logger.error("Failed to check iCloud status: \(error.localizedDescription)")
            iCloudStatus = .couldNotDetermine
        }
    }

    // MARK: - Send message

    func sendMessage(_ content: String) async {
        let sessionKey = currentSessionKey
        let messageID = UUID().uuidString
        let metadata: String
        do {
            let metadataData = try JSONSerialization.data(withJSONObject: [
                "agentId": selectedAgentId,
                "clientMessageId": messageID,
            ])
            metadata = String(data: metadataData, encoding: .utf8) ?? "{}"
        } catch {
            metadata = "{}"
        }

        let message = MessageRecord(
            id: messageID,
            sessionKey: sessionKey,
            direction: .toGateway,
            content: content,
            status: .pending,
            timestamp: Date(),
            metadata: metadata
        )

        NSLog("[iOS] Sending message id=%@ sessionKey=%@ direction=%@ status=%@ to zone=%@",
              message.id, message.sessionKey, message.direction.rawValue, message.status.rawValue, CloudKitConstants.zoneID.zoneName)

        messages.append(message)
        saveLocalCache()

        let record = message.toCKRecord()
        NSLog("[iOS] CKRecord created: recordType=%@ recordID=%@ zoneID=%@",
              record.recordType, record.recordID.recordName, record.recordID.zoneID.zoneName)
        do {
            try await database.save(record)
            if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                messages[idx].status = .sent
            }
            optimisticallyReceivedMessageIDs.insert(message.id)
            isWaitingForReply = true
            NSLog("[iOS] ✅ CloudKit save SUCCESS for record %@ in zone %@", record.recordID.recordName, record.recordID.zoneID.zoneName)
            logger.info("✅ Message saved to CloudKit: \(message.id)")
            lastError = nil
            saveLocalCache()
        } catch {
            NSLog("[iOS] ❌ CloudKit save FAILED: %@", error.localizedDescription)
            logger.error("❌ Failed to send message: \(error.localizedDescription)")
            lastError = "发送失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Send message with image

    func sendMessage(_ content: String, imageAsset: CKAsset?) async {
        guard let imageAsset else {
            await sendMessage(content)
            return
        }

        let sessionKey = currentSessionKey
        let messageID = UUID().uuidString
        let metadata: String
        do {
            var metaDict: [String: Any] = [
                "agentId": selectedAgentId,
                "clientMessageId": messageID,
            ]
            metaDict["attachments"] = [["type": "image", "hasAsset": true]]
            let metadataData = try JSONSerialization.data(withJSONObject: metaDict)
            metadata = String(data: metadataData, encoding: .utf8) ?? "{}"
        } catch {
            metadata = "{}"
        }

        var message = MessageRecord(
            id: messageID,
            sessionKey: sessionKey,
            direction: .toGateway,
            content: content,
            status: .pending,
            timestamp: Date(),
            metadata: metadata
        )
        message.imageAsset = imageAsset

        NSLog("[iOS] Sending message id=%@ sessionKey=%@ direction=%@ status=%@ to zone=%@",
              message.id, message.sessionKey, message.direction.rawValue, message.status.rawValue, CloudKitConstants.zoneID.zoneName)

        messages.append(message)
        saveLocalCache()

        let record = message.toCKRecord()
        NSLog("[iOS] CKRecord created: recordType=%@ recordID=%@ zoneID=%@",
              record.recordType, record.recordID.recordName, record.recordID.zoneID.zoneName)
        do {
            try await database.save(record)
            if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                messages[idx].status = .sent
            }
            optimisticallyReceivedMessageIDs.insert(message.id)
            isWaitingForReply = true
            NSLog("[iOS] ✅ CloudKit save SUCCESS for record %@ in zone %@", record.recordID.recordName, record.recordID.zoneID.zoneName)
            logger.info("✅ Image message saved to CloudKit: \(message.id)")
            lastError = nil
            saveLocalCache()
        } catch {
            NSLog("[iOS] ❌ CloudKit save FAILED: %@", error.localizedDescription)
            logger.error("❌ Failed to send image message: \(error.localizedDescription)")
            lastError = "发送失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Polling for responses

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.isInBackground == true
                    ? self?.pollingIntervalBackground ?? 30
                    : self?.pollingIntervalForeground ?? 5
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.pollForResponses()
                await self?.pollAllAgentsForNotifications()
            }
        }
    }

    private func pollForResponses() async {
        guard !isDirectFetchInFlight else { return }

        isSyncing = true
        defer { isSyncing = false }

        // Incremental fetch first; fall back to full fetch on token error.
        // directFetchChangeToken is managed by fetchZoneChangesDirectly() callbacks.
        // If token is nil (first run or after expiry), it naturally does a full fetch.
        logger.info("pollForResponses: incremental fetch (token \(self.directFetchChangeToken != nil ? "present" : "nil/full"))")
        do {
            let newMessages = try await fetchZoneChangesDirectly()
            debugLastFetchTime = Date()
            debugRecordCount = newMessages.count
            debugLastFetchResult = "成功（\(newMessages.count) 条记录）"
            debugLastError = nil
            logger.info("pollForResponses: fetched \(newMessages.count) records (fromGateway: \(newMessages.filter { $0.direction == .fromGateway }.count))")
            let sessionKey = currentSessionKey
            let existingIDs = Set(messages.map(\.id))
            var didChange = false
            for msg in newMessages {
                if msg.direction == .fromGateway && !existingIDs.contains(msg.id) {
                    let responseAgentId = msg.sessionKey.split(separator: ":").dropFirst().first.map(String.init) ?? "main"
                    if responseAgentId != selectedAgentId || isInBackground {
                        unreadAgentIds.insert(responseAgentId)
                    }

                    // Only add to displayed messages if it belongs to the current session
                    if msg.sessionKey == sessionKey {
                        messages.append(msg)
                        didChange = true
                        isWaitingForReply = false
                    }
                }
                // Also update status of sent messages in current session
                if msg.direction == .toGateway && msg.sessionKey == sessionKey {
                    if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                        let oldStatus = messages[idx].status
                        let merged = mergedStatus(local: oldStatus, remote: msg.status)
                        if merged != oldStatus {
                            messages[idx].status = merged
                            didChange = true
                        }
                        // When macOS confirms receipt, start showing typing indicator
                        if statusRank(oldStatus) < statusRank(.received), statusRank(merged) >= statusRank(.received) {
                            isWaitingForReply = true
                        }
                    }
                }
            }
            if didChange {
                messages.sort { $0.timestamp < $1.timestamp }
                saveLocalCache()
            }
            lastSyncDate = Date()
            lastError = nil
        } catch {
            debugLastFetchTime = Date()
            debugLastFetchResult = "失败"
            debugLastError = error.localizedDescription
            logger.error("Direct zone fetch error: \(error.localizedDescription)")
            // Fallback: also try sync engine
            if let syncEngine {
                do {
                    try await syncEngine.fetchChanges()
                } catch {
                    logger.error("fetchChanges fallback error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Fetch zone changes directly using CKFetchRecordZoneChangesOperation.
    /// Manages its own change token, independent of CKSyncEngine.
    private func fetchZoneChangesDirectly() async throws -> [MessageRecord] {
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
            var fetchedMessages: [MessageRecord] = []

            // Use new API (recordWasChangedBlock) — the old recordChangedBlock
            // may not fire on newer iOS versions.
            operation.recordWasChangedBlock = { _, result in
                switch result {
                case .success(let record):
                    guard record.recordType == MessageRecord.recordType else { return }
                    if let msg = MessageRecord.from(record: record) {
                        fetchedMessages.append(msg)
                    }
                case .failure(let error):
                    NSLog("[CloudKitMessage] recordWasChanged error: %@", error.localizedDescription)
                }
            }

            operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                guard let token else { return }
                Task { @MainActor [weak self] in
                    self?.directFetchChangeToken = token
                    Self.saveDirectFetchToken(token)
                }
            }

            operation.recordZoneFetchCompletionBlock = { [weak self] _, token, _, _, error in
                if let error, (error as? CKError)?.code == .changeTokenExpired {
                    Task { @MainActor in
                        self?.directFetchChangeToken = nil
                        Self.saveDirectFetchToken(nil)
                        self?.logger.info("Change token expired, will do full fetch next poll")
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
                        continuation.resume(returning: fetchedMessages)
                    }
                }
            }

            operation.qualityOfService = .userInitiated
            database.add(operation)
        }
    }

    // MARK: - Direct fetch token persistence

    private static func saveDirectFetchToken(_ token: CKServerChangeToken?) {
        guard let token else {
            UserDefaults.standard.removeObject(forKey: directFetchTokenKey)
            return
        }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            UserDefaults.standard.set(data, forKey: directFetchTokenKey)
        } catch {
            NSLog("[CloudKitMessage] Failed to save direct fetch token: %@", error.localizedDescription)
        }
    }

    private static func loadDirectFetchToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: directFetchTokenKey) else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        } catch {
            NSLog("[CloudKitMessage] Failed to load direct fetch token: %@", error.localizedDescription)
            return nil
        }
    }

    private func pollAllAgentsForNotifications() async {
        guard isInitialSyncDone else { return }
        // Check messages already populated by sync engine for unnotified ones
        var newNotifications = 0
        for msg in messages where msg.direction == .fromGateway && !notifiedMessageIDs.contains(msg.id) {
            notifiedMessageIDs.insert(msg.id)
            newNotifications += 1

            let agentId = msg.sessionKey.split(separator: ":").dropFirst().first.map(String.init) ?? "Agent"

            if agentId != selectedAgentId || isInBackground {
                unreadAgentIds.insert(agentId)
            }

            NotificationManager.shared.sendLocalNotification(
                title: "💬 \(agentId)",
                body: msg.content,
                sessionKey: msg.sessionKey
            )
        }

        if newNotifications > 0 {
            if notifiedMessageIDs.count > 500 {
                let currentIDs = Set(messages.map(\.id))
                notifiedMessageIDs = notifiedMessageIDs.intersection(currentIDs)
            }
            UserDefaults.standard.set(Array(notifiedMessageIDs), forKey: Self.notifiedIDsKey)
        }
    }

    // MARK: - Load history

    func loadHistory() async {
        // Load local cache first for instant display
        loadLocalCache()
        // Then do a full zone fetch (nil token = fetch all records) to get complete history
        isSyncing = true
        do {
            let savedToken = directFetchChangeToken
            directFetchChangeToken = nil  // Force full fetch
            let allMessages = try await fetchZoneChangesDirectly()
            // directFetchChangeToken is now updated to latest

            let sessionKey = currentSessionKey
            let existingIDs = Set(messages.map(\.id))
            var didChange = false
            for msg in allMessages where !existingIDs.contains(msg.id) && msg.sessionKey == sessionKey {
                messages.append(msg)
                didChange = true
            }
            // Also update statuses for current session messages without regressing local ACK state
            for msg in allMessages where msg.sessionKey == sessionKey {
                if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                    let oldStatus = messages[idx].status
                    let merged = mergedStatus(local: oldStatus, remote: msg.status)
                    if merged != oldStatus {
                        messages[idx].status = merged
                        didChange = true
                    }
                }
            }
            if didChange {
                messages.sort { $0.timestamp < $1.timestamp }
                saveLocalCache()
            }
            lastSyncDate = Date()
            lastError = nil
        } catch {
            logger.error("loadHistory zone fetch failed: \(error.localizedDescription)")
            lastError = "加载历史失败: \(error.localizedDescription)"
        }
        // Mark all existing messages as notified to prevent notification flood
        if !isInitialSyncDone {
            for msg in messages where msg.direction == .fromGateway {
                notifiedMessageIDs.insert(msg.id)
            }
            UserDefaults.standard.set(Array(notifiedMessageIDs), forKey: Self.notifiedIDsKey)
            isInitialSyncDone = true
        }
        recalculateWaitingState()
        isSyncing = false
    }

    // MARK: - App lifecycle

    /// Called from AppDelegate when a silent push arrives in the background.
    /// Returns true if new fromGateway messages were found.
    func handleBackgroundPush() async -> Bool {
        let beforeIDs = Set(messages.filter { $0.direction == .fromGateway }.map(\.id))
        await pollForResponses()
        await pollAllAgentsForNotifications()
        let afterIDs = Set(messages.filter { $0.direction == .fromGateway }.map(\.id))
        return afterIDs.count > beforeIDs.count
    }

    func appDidBecomeActive() {
        isInBackground = false
        recalculateWaitingState()
        startPolling()
        Task {
            await pollForResponses()
            await pollAllAgentsForNotifications()
        }
    }

    func appDidEnterBackground() {
        isInBackground = true
        startPolling()
    }

    // MARK: - Agent / Session selection

    var currentSessionKey: String {
        customSessionKey ?? "agent:\(selectedAgentId):main"
    }

    private var customSessionKey: String?

    func selectAgent(_ agentId: String) {
        selectedAgentId = agentId
        customSessionKey = nil
        isWaitingForReply = false
        optimisticallyReceivedMessageIDs.removeAll()
        unreadAgentIds.remove(agentId)
        UserDefaults.standard.set(agentId, forKey: Self.agentKey)
        loadLocalCache()
        Task { await loadHistory() }
    }

    func selectSession(_ sessionKey: String) {
        customSessionKey = sessionKey
        isWaitingForReply = false
        optimisticallyReceivedMessageIDs.removeAll()
        let parts = sessionKey.split(separator: ":")
        if parts.count >= 2 {
            selectedAgentId = String(parts[1])
        }
        loadLocalCache()
        Task { await loadHistory() }
    }

    // MARK: - CKSyncEngine handling

    func handleSyncEvent(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let stateUpdate):
            saveSyncState(stateUpdate.stateSerialization)

        case .fetchedRecordZoneChanges(let fetchedChanges):
            var didChange = false
            let sessionKey = currentSessionKey
            for modification in fetchedChanges.modifications {
                let record = modification.record
                guard record.recordType == MessageRecord.recordType else { continue }
                guard let msg = MessageRecord.from(record: record) else { continue }

                if msg.direction == .fromGateway {
                    let existingIDs = Set(messages.map(\.id))
                    if !existingIDs.contains(msg.id) {
                        let responseAgentId = msg.sessionKey.split(separator: ":").dropFirst().first.map(String.init) ?? "main"
                        if responseAgentId != selectedAgentId || isInBackground {
                            unreadAgentIds.insert(responseAgentId)
                        }

                        // Only add to displayed messages if it belongs to the current session
                        if msg.sessionKey == sessionKey {
                            messages.append(msg)
                            messages.sort { $0.timestamp < $1.timestamp }
                            didChange = true
                            isWaitingForReply = false
                            clearOptimisticWaitingState(before: msg.timestamp, sessionKey: sessionKey)
                        }
                    }
                }

                if msg.direction == .toGateway && msg.sessionKey == sessionKey {
                    if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                        let oldStatus = messages[idx].status
                        let merged = mergedStatus(local: oldStatus, remote: msg.status)
                        if merged != oldStatus {
                            messages[idx].status = merged
                            didChange = true
                        }
                        // When macOS confirms receipt, start showing typing indicator
                        if statusRank(oldStatus) < statusRank(.received), statusRank(merged) >= statusRank(.received) {
                            isWaitingForReply = true
                        }
                    }
                }
            }
            lastSyncDate = Date()
            if didChange { saveLocalCache() }

        case .accountChange(let change):
            switch change.changeType {
            case .signOut:
                lastError = "iCloud 账号已登出"
            default:
                break
            }

        default:
            break
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

    // MARK: - Zone subscription

    private func registerZoneSubscription() async {
        let subscriptionID = "clawtower-zone-changes"

        // Check if subscription already exists
        do {
            _ = try await database.subscription(for: subscriptionID)
            NSLog("[CloudKitMessage] Zone subscription already exists")
            return
        } catch {
            // Subscription doesn't exist, create it
        }

        let subscription = CKRecordZoneSubscription(
            zoneID: CloudKitConstants.zoneID,
            subscriptionID: subscriptionID
        )

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true  // Silent push
        subscription.notificationInfo = notificationInfo

        do {
            try await database.save(subscription)
            NSLog("[CloudKitMessage] ✅ Zone subscription registered")
        } catch {
            NSLog("[CloudKitMessage] ⚠️ Failed to register zone subscription: %@", error.localizedDescription)
        }
    }

    // MARK: - Zone

    private func ensureZoneExists() async {
        let zone = CKRecordZone(zoneID: CloudKitConstants.zoneID)
        do {
            try await database.save(zone)
            logger.info("ClawTowerZone confirmed")
        } catch {
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

    // MARK: - Local JSON Cache

    private func cacheFileURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let safeKey = currentSessionKey
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return docs.appendingPathComponent("chat-cache-\(safeKey).json")
    }

    private func saveLocalCache() {
        let cached = messages.map { CachedMessage(from: $0) }
        let trimmed = Array(cached.suffix(100))
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(trimmed)
            try data.write(to: cacheFileURL(), options: .atomic)
        } catch {
            logger.error("Failed to save local cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Debug helpers

    private func updateDebugICloudStatus() {
        switch iCloudStatus {
        case .available: debugICloudStatus = "已登录"
        case .noAccount: debugICloudStatus = "未登录"
        case .restricted: debugICloudStatus = "受限"
        case .temporarilyUnavailable: debugICloudStatus = "暂时不可用"
        case .couldNotDetermine: debugICloudStatus = "无法确定"
        @unknown default: debugICloudStatus = "未知"
        }
    }

    func debugManualFetch() async {
        await pollForResponses()
    }

    func debugFetchDashboard() async {
        debugDashboardLoading = true
        debugDashboardResult = "读取中..."
        do {
            let record = try await CKContainer(identifier: CloudKitConstants.containerID)
                .privateCloudDatabase
                .record(for: DashboardSnapshotRecord.recordID)
            let recordType = record.recordType
            let recordName = record.recordID.recordName
            let creationDate = record.creationDate.map { "\($0)" } ?? "nil"
            let modificationDate = record.modificationDate.map { "\($0)" } ?? "nil"
            let payload = (record["payload"] as? String) ?? "(无 payload 字段)"
            let dataPreview = String(payload.prefix(200))
            debugDashboardResult = """
                ✅ 读取成功
                recordType: \(recordType)
                recordName: \(recordName)
                creationDate: \(creationDate)
                modificationDate: \(modificationDate)
                payload(前200字符): \(dataPreview)
                """
        } catch {
            var result = "❌ 读取失败\n"
            if let ckError = error as? CKError {
                result += "CKError code: \(ckError.code.rawValue) (\(ckError.code))\n"
                result += "localizedDescription: \(ckError.localizedDescription)\n"
                result += "errorUserInfo: \(ckError.errorUserInfo)\n"
                if ckError.code == .zoneNotFound {
                    result += "⚠️ Zone 不存在 (zoneNotFound)"
                } else if ckError.code == .unknownItem {
                    result += "⚠️ Record 不存在 (unknownItem)"
                }
            } else {
                result += "error: \(error.localizedDescription)\n"
                result += "full: \(error)"
            }
            debugDashboardResult = result
        }
        debugDashboardLoading = false
    }

    func debugTestWrite() async {
        debugTestWriteResult = "写入中..."
        let testRecordID = CKRecord.ID(recordName: "debug-test-\(UUID().uuidString)", zoneID: CloudKitConstants.zoneID)
        let record = CKRecord(recordType: MessageRecord.recordType, recordID: testRecordID)
        record["id"] = testRecordID.recordName as CKRecordValue
        record["sessionKey"] = "debug:test" as CKRecordValue
        record["direction"] = "toGateway" as CKRecordValue
        record["content"] = "Debug test at \(Date())" as CKRecordValue
        record["status"] = "delivered" as CKRecordValue
        record["timestamp"] = Date() as CKRecordValue
        record["metadata"] = "{}" as CKRecordValue

        do {
            let saved = try await database.save(record)
            debugTestWriteResult = "✅ 写入成功 (recordName: \(saved.recordID.recordName))"
            // Clean up test record
            try? await database.deleteRecord(withID: saved.recordID)
        } catch {
            debugTestWriteResult = "❌ 写入失败: \(error.localizedDescription)"
        }
    }


    func frontendStatus(for message: MessageRecord) -> MessageStatus {
        if message.direction == .toGateway,
           message.status == .sent,
           optimisticallyReceivedMessageIDs.contains(message.id) {
            return .received
        }
        return message.status
    }

    private func clearOptimisticWaitingState(before replyTimestamp: Date, sessionKey: String) {
        let acknowledgedIDs = messages
            .filter { $0.sessionKey == sessionKey && $0.direction == .toGateway && $0.timestamp <= replyTimestamp }
            .map(\.id)
        optimisticallyReceivedMessageIDs.subtract(acknowledgedIDs)
    }

    /// Recalculate `isWaitingForReply` based on actual message state.
    /// Sets true only if the last toGateway message has status `received`
    /// and no fromGateway reply exists after it.
    private func recalculateWaitingState() {
        let sessionKey = currentSessionKey
        let sessionMessages = messages.filter { $0.sessionKey == sessionKey }
        guard let lastOutgoing = sessionMessages.last(where: { $0.direction == .toGateway }) else {
            isWaitingForReply = false
            return
        }
        guard statusRank(frontendStatus(for: lastOutgoing)) >= statusRank(.received) else {
            isWaitingForReply = false
            return
        }
        let hasReplyAfter = sessionMessages.contains { msg in
            msg.direction == .fromGateway && msg.timestamp > lastOutgoing.timestamp
        }
        isWaitingForReply = !hasReplyAfter
    }

    private func loadLocalCache() {
        let url = cacheFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            messages.removeAll()
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let cached = try decoder.decode([CachedMessage].self, from: data)
            messages = cached.map { $0.toMessageRecord() }
            messages.sort { $0.timestamp < $1.timestamp }
        } catch {
            logger.error("Failed to load local cache: \(error.localizedDescription)")
            messages.removeAll()
        }
        recalculateWaitingState()
    }
}

// MARK: - CKSyncEngineDelegate

private final class MobileSyncEngineDelegate: CKSyncEngineDelegate {
    private let client: CloudKitMessageClient

    init(client: CloudKitMessageClient) {
        self.client = client
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        Task { @MainActor in
            client.handleSyncEvent(event)
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await client.nextRecordZoneChangeBatch(context)
    }
}
