import SwiftUI

struct UsageStatisticsView: View {
    @Environment(\.themeColor) private var themeColor
    @Bindable var service: UsageStatisticsService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("用量统计")
                    .font(.largeTitle.bold())

                // Period picker
                HStack {
                    Picker("时间范围", selection: $service.selectedPeriod) {
                        ForEach(UsagePeriod.allCases) { period in
                            Text(period.label).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)

                    Spacer()

                    Button {
                        Task { await service.fetch() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(service.isLoading)
                }

                // Error banner
                if let error = service.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.callout)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                }

                if service.isLoading && service.totalTokens == 0 {
                    // First load
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在加载用量数据...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                } else {
                    // Totals summary
                    totalsSummary

                    // Agent breakdown
                    agentSection

                    // Model breakdown
                    modelSection

                    // Session breakdown
                    sessionSection
                }
            }
            .padding(20)
        }
        .background(Color(.windowBackgroundColor))
        .navigationTitle("用量统计")
        .task(id: service.selectedPeriod) {
            await service.fetch()
        }
    }

    // MARK: - Totals

    @ViewBuilder
    private var totalsSummary: some View {
        GroupBox {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("总 Token")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatTokens(service.totalTokens))
                        .font(.title2.bold().monospacedDigit())
                }
                Divider().frame(height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text("总费用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatCost(service.totalCost))
                        .font(.title2.bold().monospacedDigit())
                }
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Agent Section

    @ViewBuilder
    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent 用量")
                .font(.headline)

            if service.byAgent.isEmpty {
                emptyPlaceholder
            } else {
                GroupBox {
                    VStack(spacing: 0) {
                        let maxTokens = service.byAgent.map(\.totalTokens).max() ?? 1
                        ForEach(Array(service.byAgent.enumerated()), id: \.element.id) { index, agent in
                            UsageBarRow(
                                icon: "person.fill",
                                label: agent.agentId,
                                tokens: agent.totalTokens,
                                cost: agent.totalCost,
                                fraction: Double(agent.totalTokens) / Double(max(maxTokens, 1)),
                                tint: themeColor
                            )
                            if index < service.byAgent.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .padding(4)
                }
            }
        }
    }

    // MARK: - Model Section

    @ViewBuilder
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("模型用量")
                .font(.headline)

            if service.byModel.isEmpty {
                emptyPlaceholder
            } else {
                GroupBox {
                    VStack(spacing: 0) {
                        let maxTokens = service.byModel.map(\.totalTokens).max() ?? 1
                        ForEach(Array(service.byModel.enumerated()), id: \.element.id) { index, model in
                            UsageBarRow(
                                icon: "cpu",
                                label: formatModelName(provider: model.provider, model: model.model),
                                tokens: model.totalTokens,
                                cost: model.totalCost,
                                fraction: Double(model.totalTokens) / Double(max(maxTokens, 1)),
                                tint: themeColor,
                                subtitle: "\(model.count) 次调用"
                            )
                            if index < service.byModel.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .padding(4)
                }
            }
        }
    }

    // MARK: - Session Section

    @ViewBuilder
    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Session 用量")
                    .font(.headline)
                Spacer()
                Text("\(service.bySessions.count) 个会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if service.bySessions.isEmpty {
                emptyPlaceholder
            } else {
                GroupBox {
                    VStack(spacing: 0) {
                        let maxTokens = service.bySessions.first?.totalTokens ?? 1
                        let displayItems = service.bySessions.prefix(20)
                        ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, session in
                            UsageBarRow(
                                icon: "bubble.left.fill",
                                label: session.label.isEmpty ? session.key : session.label,
                                tokens: session.totalTokens,
                                cost: session.totalCost,
                                fraction: Double(session.totalTokens) / Double(max(maxTokens, 1)),
                                tint: themeColor,
                                subtitle: session.agentId.isEmpty ? nil : session.agentId
                            )
                            if index < displayItems.count - 1 {
                                Divider()
                            }
                        }

                        if service.bySessions.count > 20 {
                            Text("还有 \(service.bySessions.count - 20) 个会话未显示")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                        }
                    }
                    .padding(4)
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var emptyPlaceholder: some View {
        GroupBox {
            Text("暂无数据")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(12)
        }
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 && cost > 0 {
            return String(format: "$%.4f", cost)
        }
        return String(format: "$%.2f", cost)
    }

    private func formatModelName(provider: String, model: String) -> String {
        // Clean up model slug: remove date suffix, replace hyphens with dots for version numbers
        var name = model
            .replacingOccurrences(of: "-20\\d{6,}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(\\d)-(\\d)", with: "$1.$2", options: .regularExpression)
        // Capitalize words
        name = name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return name
    }
}

// MARK: - Usage Bar Row

private struct UsageBarRow: View {
    let icon: String
    let label: String
    let tokens: Int
    let cost: Double
    let fraction: Double
    let tint: Color
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            ProgressView(value: max(0, min(1, fraction)))
                .tint(tint)
                .frame(minWidth: 80)

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatTokensCompact(tokens))
                    .font(.caption.monospacedDigit().weight(.medium))
                Text(formatCostCompact(cost))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 60, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private func formatTokensCompact(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }

    private func formatCostCompact(_ cost: Double) -> String {
        if cost < 0.01 && cost > 0 {
            return String(format: "$%.4f", cost)
        }
        return String(format: "$%.2f", cost)
    }
}
