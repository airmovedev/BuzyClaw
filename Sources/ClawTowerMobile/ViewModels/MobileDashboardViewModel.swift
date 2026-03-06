import CloudKit
import Foundation

@MainActor
@Observable
final class MobileDashboardViewModel {
    var snapshot: DashboardSnapshot?
    var isLoading = false
    var error: String?
    var lastFetchedAt: Date?

    private let database = CKContainer(identifier: CloudKitConstants.containerID).privateCloudDatabase

    func fetch() async {
        isLoading = true
        defer { isLoading = false }
        error = nil

        do {
            let record = try await database.record(for: DashboardSnapshotRecord.recordID)
            if let snap = DashboardSnapshotRecord.from(record: record) {
                self.snapshot = snap
                self.lastFetchedAt = Date()
            } else {
                self.error = "无法解析看板数据"
            }
        } catch let ckError as CKError where ckError.code == .unknownItem {
            self.error = "暂无看板数据，请确保 macOS 端已打开"
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Computed helpers

    var agents: [AgentSnapshot] { snapshot?.agents ?? [] }
    var projects: [ProjectSnapshot] { snapshot?.projects ?? [] }

    var tasksByStatus: [(String, [TaskSnapshot])] {
        guard let tasks = snapshot?.tasks else { return [] }
        let order = ["inProgress", "todo", "inReview", "done"]
        let reverseLabels: [String: String] = [
            "inProgress": "进行中",
            "todo": "建议",
            "inReview": "待审核",
            "done": "已完成",
        ]

        let grouped = Dictionary(grouping: tasks, by: { $0.status })
        return order.compactMap { status in
            guard let items = grouped[status], !items.isEmpty else { return nil }
            return (reverseLabels[status] ?? status, items)
        }
    }

    var snapshotAge: String? {
        guard let ts = snapshot?.timestamp else { return nil }
        let interval = Date().timeIntervalSince(ts)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60))分钟前" }
        return "\(Int(interval / 3600))小时前"
    }

    var isEffectivelyEmpty: Bool {
        guard let snapshot else { return true }
        return snapshot.agents.isEmpty && snapshot.projects.isEmpty && snapshot.tasks.isEmpty
            && (snapshot.cronJobs?.isEmpty ?? true)
            && (snapshot.secondBrainDocs?.isEmpty ?? true)
            && (snapshot.sessions?.isEmpty ?? true)
    }
}
