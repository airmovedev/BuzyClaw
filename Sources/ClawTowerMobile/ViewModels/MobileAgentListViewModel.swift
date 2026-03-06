import CloudKit
import Foundation

@MainActor
@Observable
final class MobileAgentListViewModel {
    var agents: [AgentSnapshot] = []
    var isLoading = false
    var error: String?

    private let database = CKContainer(identifier: CloudKitConstants.containerID).privateCloudDatabase

    var sortedAgents: [AgentSnapshot] {
        agents.sorted { a, b in
            if a.id == "main" { return true }
            if b.id == "main" { return false }
            return a.displayName.localizedCompare(b.displayName) == .orderedAscending
        }
    }

    func fetch() async {
        isLoading = true
        defer { isLoading = false }
        error = nil

        do {
            let record = try await database.record(for: DashboardSnapshotRecord.recordID)
            if let snap = DashboardSnapshotRecord.from(record: record) {
                self.agents = snap.agents
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
