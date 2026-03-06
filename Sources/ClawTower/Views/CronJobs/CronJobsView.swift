import SwiftUI

struct CronJobsView: View {
    let client: GatewayClient

    @State private var jobs: [CronJob] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var agentNames: [String: String] = [:]

    init(client: GatewayClient) {
        self.client = client
    }

    private var groupedJobs: [(agentId: String, jobs: [CronJob])] {
        let dict = Dictionary(grouping: jobs, by: \.agentId)
        return dict.keys.sorted().map { key in
            let sorted = dict[key]!.sorted { CronExpressionFormatter.sortMinuteOfDay($0.schedule.expr) < CronExpressionFormatter.sortMinuteOfDay($1.schedule.expr) }
            return (agentId: key, jobs: sorted)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                // Agent columns
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(groupedJobs, id: \.agentId) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(agentDisplayName(group.agentId)) (\(group.jobs.count))")
                                    .font(.headline)
                                    .padding(.horizontal, 4)
                                ForEach(group.jobs) { job in
                                    CronJobCardView(job: job, client: client, onRefresh: { Task { await loadJobs() } })
                                }
                            }
                            .frame(width: 320)
                        }
                    }
                    .padding()
                }
            }
        }
        .task {
            loadAgentNames()
            await loadJobs()
        }
    }

    private func loadJobs() async {
        isLoading = true
        errorMessage = nil
        do {
            let data = try await client.cronListRaw()
            jobs = CronJobParser.parse(from: data)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func agentDisplayName(_ agentId: String) -> String {
        agentNames[agentId] ?? agentId
    }

    private func loadAgentNames() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".openclaw/openclaw.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agents = json["agents"] as? [[String: Any]] else { return }
        for agent in agents {
            if let id = agent["id"] as? String {
                let emoji = agent["emoji"] as? String ?? "🤖"
                let name = agent["name"] as? String ?? id
                agentNames[id] = "\(emoji) \(name)"
            }
        }
    }
}

// MARK: - Card View

private struct CronJobCardView: View {
    let job: CronJob
    let client: GatewayClient
    let onRefresh: () -> Void

    @State private var showFullMessage = false
    @State private var showDeleteAlert = false
    @State private var isToggling = false

    private var statusDotColor: Color {
        switch job.statusColor {
        case "green": return .green
        case "red": return .red
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status + name + toggle
            HStack {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                Text(job.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { job.enabled },
                    set: { newValue in
                        isToggling = true
                        Task {
                            try? await client.updateCron(jobId: job.id, enabled: newValue)
                            onRefresh()
                            isToggling = false
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isToggling)
            }

            // Schedule
            Text(CronExpressionFormatter.humanReadable(job.schedule.expr))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Message
            if !job.message.isEmpty {
                let truncated = job.message.count > 100 && !showFullMessage
                Text(truncated ? String(job.message.prefix(100)) + "…" : job.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(showFullMessage ? nil : 3)
                if job.message.count > 100 {
                    Button(showFullMessage ? "收起" : "显示全部") {
                        showFullMessage.toggle()
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }

            // Actions
            HStack {
                Button("立即执行") {
                    Task {
                        try? await client.triggerCron(jobId: job.id)
                        onRefresh()
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("删除", role: .destructive) {
                    showDeleteAlert = true
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.background.shadow(.drop(radius: 1)), in: RoundedRectangle(cornerRadius: 8))
        .alert("确认删除", isPresented: $showDeleteAlert) {
            Button("删除", role: .destructive) {
                Task {
                    try? await client.cronDeleteJob(jobId: job.id)
                    onRefresh()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除定时任务「\(job.name)」吗？此操作不可撤销。")
        }
    }
}
