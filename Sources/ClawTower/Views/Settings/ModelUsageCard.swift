import SwiftUI

struct ModelUsageCard: View {
    let model: DetectedModel
    let client: GatewayClient

    @State private var usageInfo: ModelUsageInfo?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top: icon + model name
            HStack(spacing: 8) {
                Image(systemName: model.icon)
                    .font(.title3)
                    .foregroundStyle(model.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.caption.bold())
                        .lineLimit(1)
                    Text(model.provider)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Refresh button
                Button {
                    Task { await refresh() }
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isLoading)
            }

            // Usage / availability section
            if let info = usageInfo {
                if info.isAvailable {
                    if info.hasUsageData {
                        VStack(alignment: .leading, spacing: 4) {
                            if let fiveH = info.fiveHourUtilization {
                                usageBar(label: "5H", value: fiveH, resetTime: info.fiveHourResetTime)
                            }
                            if let sevenD = info.sevenDayUtilization {
                                usageBar(label: "7D", value: sevenD, resetTime: info.sevenDayResetTime)
                            }
                            if let req = info.requestUtilization {
                                usageBar(label: "请求", value: req)
                            }
                            if let tok = info.tokenUtilization {
                                usageBar(label: "Token", value: tok)
                            }

                            // Token counts
                            if let remaining = info.tokensRemaining, let limit = info.tokensLimit {
                                Text("剩余 \(Self.formatNumber(remaining)) / \(Self.formatNumber(limit))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Text("更新于 \(info.updatedAt.formatted(.dateTime.hour().minute().second()))")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            Text("可用")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(info.errorMessage ?? "不可用")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("点击刷新查看用量")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            if usageInfo == nil {
                usageInfo = ModelUsageCache.shared.load(for: model.fullId)
            }
        }
    }

    private func usageBar(label: String, value: Double, resetTime: Date? = nil) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            ProgressView(value: min(max(value, 0), 1))
                .tint(value > 0.8 ? .red : value > 0.5 ? .yellow : .green)
            Text("\(Int(round(value * 100)))%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            if let resetTime {
                Text(Self.formatResetTime(resetTime))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        }
    }

    private static func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static func formatResetTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM HH:mm"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func refresh() async {
        isLoading = true
        let info = await client.probeModelUsage(model: model.fullId)
        usageInfo = info
        ModelUsageCache.shared.save(info, for: model.fullId)
        isLoading = false
    }
}
