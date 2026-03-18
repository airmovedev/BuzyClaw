import Foundation

// MARK: - Data Models

enum UsagePeriod: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var days: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        }
    }

    var label: String {
        switch self {
        case .day: "1天"
        case .week: "7天"
        case .month: "30天"
        }
    }
}

struct AgentUsage: Identifiable {
    let id: String
    let agentId: String
    let totalTokens: Int
    let totalCost: Double
    let input: Int
    let output: Int
}

struct ModelUsage: Identifiable {
    let id: String
    let provider: String
    let model: String
    let count: Int
    let totalTokens: Int
    let totalCost: Double
}

struct SessionUsage: Identifiable {
    let id: String
    let key: String
    let label: String
    let agentId: String
    let totalTokens: Int
    let totalCost: Double
}

// MARK: - Service

@MainActor @Observable
final class UsageStatisticsService {
    private let gatewayClient: GatewayClient

    var isLoading = false
    var errorMessage: String?
    var selectedPeriod: UsagePeriod = .week

    var totalTokens: Int = 0
    var totalCost: Double = 0

    var byAgent: [AgentUsage] = []
    var byModel: [ModelUsage] = []
    var bySessions: [SessionUsage] = []

    init(gatewayClient: GatewayClient) {
        self.gatewayClient = gatewayClient
    }

    func fetch() async {
        isLoading = true
        errorMessage = nil

        do {
            let json = try await gatewayClient.fetchSessionsUsage(days: selectedPeriod.days)

            // Navigate to the payload – CLI wraps in { ok, payload } or returns flat
            let payload = json["payload"] as? [String: Any] ?? json

            // Parse totals
            let totals = payload["totals"] as? [String: Any] ?? [:]
            totalTokens = totals["totalTokens"] as? Int ?? 0
            totalCost = totals["totalCost"] as? Double ?? 0

            // Parse aggregates
            let aggregates = payload["aggregates"] as? [String: Any] ?? [:]

            // By Agent
            if let agents = aggregates["byAgent"] as? [[String: Any]] {
                byAgent = agents.compactMap { entry in
                    guard let agentId = entry["agentId"] as? String else { return nil }
                    let t = entry["totals"] as? [String: Any] ?? [:]
                    return AgentUsage(
                        id: agentId,
                        agentId: agentId,
                        totalTokens: t["totalTokens"] as? Int ?? 0,
                        totalCost: t["totalCost"] as? Double ?? 0,
                        input: t["input"] as? Int ?? 0,
                        output: t["output"] as? Int ?? 0
                    )
                }
            }

            // By Model
            if let models = aggregates["byModel"] as? [[String: Any]] {
                byModel = models.compactMap { entry in
                    let provider = entry["provider"] as? String ?? "unknown"
                    let model = entry["model"] as? String ?? "unknown"
                    let t = entry["totals"] as? [String: Any] ?? [:]
                    return ModelUsage(
                        id: "\(provider)::\(model)",
                        provider: provider,
                        model: model,
                        count: entry["count"] as? Int ?? t["count"] as? Int ?? 0,
                        totalTokens: t["totalTokens"] as? Int ?? 0,
                        totalCost: t["totalCost"] as? Double ?? 0
                    )
                }
            }

            // By Session
            if let sessions = payload["sessions"] as? [[String: Any]] {
                bySessions = sessions.compactMap { entry in
                    let key = entry["key"] as? String ?? ""
                    let label = entry["label"] as? String ?? key
                    let agentId = entry["agentId"] as? String ?? ""
                    let usage = entry["usage"] as? [String: Any] ?? [:]
                    let tokens = usage["totalTokens"] as? Int ?? 0
                    guard tokens > 0 else { return nil }
                    return SessionUsage(
                        id: key,
                        key: key,
                        label: label,
                        agentId: agentId,
                        totalTokens: tokens,
                        totalCost: usage["totalCost"] as? Double ?? 0
                    )
                }.sorted { $0.totalTokens > $1.totalTokens }
            }

        } catch {
            NSLog("[UsageStatisticsService] fetch error: %@", error.localizedDescription)
            let detail = error.localizedDescription
            if detail.contains("超时") || detail.contains("timeout") {
                errorMessage = "查询超时，数据量较大，请稍后重试"
            } else {
                errorMessage = "获取用量数据失败: \(detail)"
            }
        }

        isLoading = false
    }
}
