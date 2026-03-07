import SwiftUI

struct ModelUsageRow: View {
    let model: DetectedModel
    let client: GatewayClient

    @State private var usageInfo: ModelUsageInfo?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 第一行：模型名 + 状态灯 + 刷新按钮
            HStack(spacing: 12) {
                Text(model.displayName)
                    .font(.callout.bold())
                    .lineLimit(1)

                Spacer()

                // 状态灯 + 文案
                if let info = usageInfo {
                    if info.isAvailable {
                        if info.errorMessage == "已达上限" {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                            Text("已达上限").font(.caption2).foregroundStyle(.orange)
                        } else {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text("可用").font(.caption2).foregroundStyle(.green)
                        }
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                        Text("不可用").font(.caption2).foregroundStyle(.orange)
                    }
                } else {
                    Circle().fill(.gray.opacity(0.3)).frame(width: 6, height: 6)
                }

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

            // 第二行：仅显示用量条（有数据时）
            if let info = usageInfo, info.isAvailable, info.hasUsageData {
                HStack(spacing: 12) {
                    if let fiveH = info.fiveHourUtilization {
                        compactBar(label: "5H", value: fiveH, resetTime: info.fiveHourResetTime)
                    }
                    if let sevenD = info.sevenDayUtilization {
                        compactBar(label: "7D", value: sevenD, resetTime: info.sevenDayResetTime)
                    }
                    if let req = info.requestUtilization {
                        compactBar(label: "请求", value: req, resetTime: nil)
                    }
                    if let tok = info.tokenUtilization {
                        compactBar(label: "Token", value: tok, resetTime: nil)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .onAppear {
            if usageInfo == nil {
                usageInfo = ModelUsageCache.shared.load(for: model.fullId)
            }
        }
    }

    private func compactBar(label: String, value: Double, resetTime: Date?) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            ProgressView(value: min(max(value, 0), 1))
                .tint(value > 0.8 ? .red : value > 0.5 ? .yellow : .green)
                .frame(width: 40)
            Text("\(Int(round(value * 100)))%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            if let reset = resetTime {
                Text(Self.formatResetTime(reset))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        }
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
