import CloudKit
import Foundation

@MainActor
@Observable
final class MobileCronJobsViewModel {
    var jobs: [CronJobSnapshot] = []
    var isLoading = false
    var error: String?
    var lastFetchedAt: Date?

    private let database = CKContainer(identifier: CloudKitConstants.containerID).privateCloudDatabase

    var groupedJobs: [(agentId: String, jobs: [CronJobSnapshot])] {
        let grouped = Dictionary(grouping: jobs) { $0.agentId }
        return grouped.sorted { $0.key < $1.key }
            .map { (agentId: $0.key, jobs: $0.value) }
    }

    func fetch() async {
        isLoading = true
        defer { isLoading = false }
        error = nil

        do {
            let record = try await database.record(for: DashboardSnapshotRecord.recordID)
            if let snap = DashboardSnapshotRecord.from(record: record) {
                self.jobs = snap.cronJobs ?? []
                self.lastFetchedAt = Date()
            } else {
                self.error = "无法解析数据"
            }
        } catch let ckError as CKError where ckError.code == .unknownItem {
            self.error = "暂无数据，请确保 macOS 端已打开"
        } catch {
            self.error = error.localizedDescription
        }
    }
}
