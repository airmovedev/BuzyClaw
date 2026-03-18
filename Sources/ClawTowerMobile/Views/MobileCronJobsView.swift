import SwiftUI

struct MobileCronJobsView: View {
    @Environment(DashboardSnapshotStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.isRefreshing && jobs.isEmpty {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if !store.isMacOSConnected && jobs.isEmpty {
                    SetupGuideView(
                        icon: "clock.badge.checkmark",
                        title: "guide.cron.title",
                        description: "guide.cron.description",
                        features: [
                            .init(icon: "clock", text: "guide.cron.feature1"),
                            .init(icon: "arrow.triangle.2.circlepath", text: "guide.cron.feature2"),
                            .init(icon: "bell.badge", text: "guide.cron.feature3"),
                        ],
                        onRetry: { await store.refresh() }
                    )
                } else if let error = store.lastError, jobs.isEmpty {
                    ContentUnavailableView {
                        Label("无法加载", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await store.refresh() } }
                    }
                } else if jobs.isEmpty {
                    ContentUnavailableView("暂无定时任务", systemImage: "clock")
                } else {
                    jobList
                }
            }
            .refreshable { await store.refresh() }
            .navigationTitle("定时任务")
        }
    }

    // MARK: - Computed Properties

    private var jobs: [CronJobSnapshot] {
        store.snapshot?.cronJobs ?? []
    }

    private var groupedJobs: [(agentId: String, jobs: [CronJobSnapshot])] {
        let grouped = Dictionary(grouping: jobs) { $0.agentId }
        return grouped.sorted { $0.key < $1.key }
            .map { (agentId: $0.key, jobs: $0.value) }
    }

    // MARK: - Subviews

    private var jobList: some View {
        List {
            if !store.isMacOSConnected {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.slash.fill")
                            .foregroundStyle(.red)
                        Text("电脑端「虾忙」未连接")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        RetryButton { await store.refresh() }
                    }
                    .listRowBackground(Color.red.opacity(0.08))
                }
            }

            ForEach(groupedJobs, id: \.agentId) { agentId, jobs in
                Section(agentId) {
                    ForEach(jobs) { job in
                        NavigationLink {
                            CronJobDetailView(job: job)
                        } label: {
                            jobRow(job)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func jobRow(_ job: CronJobSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(job))
                    .frame(width: 10, height: 10)
                Text(job.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                if !job.enabled {
                    Text("已禁用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
            }

            if let expr = job.scheduleExpr {
                Text(CronExpressionFormatter.humanReadable(expr))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !job.message.isEmpty {
                Text(job.message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            if let lastRun = job.lastRunAt {
                HStack(spacing: 4) {
                    Text("上次运行:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(lastRun, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func statusColor(_ job: CronJobSnapshot) -> Color {
        if job.lastStatus == "error" { return .red }
        if job.didRunToday { return .green }
        return .gray
    }
}

// MARK: - Cron Job Detail View

struct CronJobDetailView: View {
    let job: CronJobSnapshot

    var body: some View {
        List {
            Section("标题") {
                Text(job.name)
                    .font(.body)
                    .textSelection(.enabled)
            }

            Section("负责 Agent") {
                HStack(spacing: 8) {
                    Image(systemName: "person.circle")
                        .foregroundStyle(.secondary)
                    Text(job.agentId)
                        .font(.body)
                }
            }

            Section("执行时间") {
                if let expr = job.scheduleExpr {
                    Text(CronExpressionFormatter.humanReadable(expr))
                        .font(.body)
                } else {
                    Text("未设置")
                        .foregroundStyle(.secondary)
                }
            }

            Section("指令详情") {
                if job.message.isEmpty {
                    Text("无指令内容")
                        .foregroundStyle(.secondary)
                } else {
                    Text(job.message)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }

            Section("状态") {
                HStack {
                    Text("启用")
                    Spacer()
                    Text(job.enabled ? "已启用" : "已禁用")
                        .foregroundStyle(job.enabled ? .green : .secondary)
                }

                if let lastRun = job.lastRunAt {
                    HStack {
                        Text("上次运行")
                        Spacer()
                        Text(lastRun, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastStatus = job.lastStatus, !lastStatus.isEmpty {
                    HStack {
                        Text("上次结果")
                        Spacer()
                        Text(statusLabel(lastStatus))
                            .foregroundStyle(statusColor(lastStatus))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helpers

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "success": "成功"
        case "error": "失败"
        case "running": "运行中"
        default: status
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "success": .green
        case "error": .red
        case "running": .blue
        default: .secondary
        }
    }
}
