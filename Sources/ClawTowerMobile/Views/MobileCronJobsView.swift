import SwiftUI

struct MobileCronJobsView: View {
    @State private var viewModel = MobileCronJobsViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.jobs.isEmpty {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let error = viewModel.error, viewModel.jobs.isEmpty {
                    ContentUnavailableView {
                        Label("无法加载", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await viewModel.fetch() } }
                    }
                } else if viewModel.jobs.isEmpty {
                    ContentUnavailableView("暂无定时任务", systemImage: "clock")
                } else {
                    jobList
                }
            }
            .refreshable { await viewModel.fetch() }
            .navigationTitle("定时任务")
            .task { await viewModel.fetch() }
        }
    }

    private var jobList: some View {
        List {
            ForEach(viewModel.groupedJobs, id: \.agentId) { agentId, jobs in
                Section(agentId) {
                    ForEach(jobs) { job in
                        jobRow(job)
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
