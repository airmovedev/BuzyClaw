import CloudKit
import Foundation

@MainActor
@Observable
final class MobileSecondBrainViewModel {
    var docs: [SecondBrainDocSnapshot] = []
    var isLoading = false
    var error: String?
    var lastFetchedAt: Date?

    private let database = CKContainer(identifier: CloudKitConstants.containerID).privateCloudDatabase

    var groupedDocs: [(group: String, docs: [SecondBrainDocSnapshot])] {
        let grouped = Dictionary(grouping: docs) { $0.group }
        return grouped.sorted { $0.key < $1.key }
            .map { (group: $0.key, docs: $0.value.sorted { $0.modifiedAt > $1.modifiedAt }) }
    }

    func fetch() async {
        isLoading = true
        defer { isLoading = false }
        error = nil

        do {
            let record = try await database.record(for: DashboardSnapshotRecord.recordID)
            if let snap = DashboardSnapshotRecord.from(record: record) {
                self.docs = snap.secondBrainDocs ?? []
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
