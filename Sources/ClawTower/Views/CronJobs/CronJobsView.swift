import SwiftUI

struct CronJobsView: View {
    let client: GatewayClient

    @State private var jobs: [CronJob] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var agentNames: [String: String] = [:]
    @State private var showCreateSheet = false

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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("创建定时任务")
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateCronJobSheet(client: client) {
                Task { await loadJobs() }
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
    @State private var showHistory = false
    @State private var runs: [[String: Any]] = []
    @State private var isLoadingRuns = false

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

                Button("历史") {
                    showHistory.toggle()
                    if showHistory && runs.isEmpty {
                        loadRuns()
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

            // History panel
            if showHistory {
                VStack(alignment: .leading, spacing: 4) {
                    if isLoadingRuns {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else if runs.isEmpty {
                        Text("暂无运行记录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(runs.prefix(5).enumerated()), id: \.offset) { _, run in
                            CronRunRowView(run: run)
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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

    private func loadRuns() {
        isLoadingRuns = true
        Task {
            do {
                runs = try await client.cronJobRuns(jobId: job.id)
            } catch {
                runs = []
            }
            isLoadingRuns = false
        }
    }
}

// MARK: - Cron Run Row

private struct CronRunRowView: View {
    let run: [String: Any]

    private var timestamp: String {
        if let ts = run["startedAt"] as? Double {
            let date = Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
            return Self.formatter.string(from: date)
        }
        if let ts = run["timestamp"] as? Double {
            let date = Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
            return Self.formatter.string(from: date)
        }
        if let ts = run["time"] as? String {
            return ts
        }
        return "—"
    }

    private var status: String {
        if let s = run["status"] as? String { return s }
        if let s = run["result"] as? String { return s }
        if let ok = run["success"] as? Bool { return ok ? "success" : "error" }
        return "unknown"
    }

    private var statusColor: Color {
        switch status {
        case "success", "ok", "completed": return .green
        case "error", "failed", "failure": return .red
        case "running", "pending": return .orange
        default: return .gray
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(timestamp)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(status)
                .font(.caption2)
                .foregroundStyle(statusColor)
        }
    }
}

// MARK: - Create Cron Job Sheet

private struct CreateCronJobSheet: View {
    let client: GatewayClient
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var jobName = ""
    @State private var selectedAgentId = "main"
    @State private var scheduleType: ScheduleType = .daily
    @State private var dailyHour = 9
    @State private var dailyMinute = 0
    @State private var intervalHours = 4
    @State private var customCron = ""
    @State private var taskContent = ""
    @State private var isCreating = false
    @State private var createError: String?

    private var agents: [(id: String, label: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".openclaw/openclaw.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [("main", "main")] }

        // Try agents.list format
        if let agentsConfig = json["agents"] as? [String: Any],
           let list = agentsConfig["list"] as? [[String: Any]] {
            let result = list.compactMap { agent -> (id: String, label: String)? in
                guard let id = agent["id"] as? String else { return nil }
                let identity = agent["identity"] as? [String: Any]
                let emoji = identity?["emoji"] as? String ?? "🤖"
                let name = identity?["name"] as? String ?? id
                return (id: id, label: "\(emoji) \(name)")
            }
            if !result.isEmpty { return result }
        }

        // Fallback: flat agents array
        if let agentsList = json["agents"] as? [[String: Any]] {
            let result = agentsList.compactMap { agent -> (id: String, label: String)? in
                guard let id = agent["id"] as? String else { return nil }
                let emoji = agent["emoji"] as? String ?? "🤖"
                let name = agent["name"] as? String ?? id
                return (id: id, label: "\(emoji) \(name)")
            }
            if !result.isEmpty { return result }
        }

        return [("main", "main")]
    }

    private enum ScheduleType: String, CaseIterable {
        case daily = "每天定时"
        case interval = "每隔N小时"
        case custom = "自定义 cron"
    }

    private static let intervalOptions = [1, 2, 4, 6, 12]

    private var cronExpression: String {
        switch scheduleType {
        case .daily:
            return "\(dailyMinute) \(dailyHour) * * *"
        case .interval:
            return "0 */\(intervalHours) * * *"
        case .custom:
            return customCron
        }
    }

    private var canCreate: Bool {
        !jobName.trimmingCharacters(in: .whitespaces).isEmpty
        && !taskContent.trimmingCharacters(in: .whitespaces).isEmpty
        && (scheduleType != .custom || !customCron.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("创建定时任务")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Job name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("任务名称")
                            .font(.subheadline.weight(.medium))
                        TextField("输入任务名称", text: $jobName)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Agent picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agent")
                            .font(.subheadline.weight(.medium))
                        Picker("Agent", selection: $selectedAgentId) {
                            ForEach(agents, id: \.id) { agent in
                                Text(agent.label).tag(agent.id)
                            }
                        }
                        .labelsHidden()
                    }

                    // Schedule type
                    VStack(alignment: .leading, spacing: 4) {
                        Text("调度类型")
                            .font(.subheadline.weight(.medium))
                        Picker("调度类型", selection: $scheduleType) {
                            ForEach(ScheduleType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // Schedule config
                    switch scheduleType {
                    case .daily:
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("小时")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("小时", selection: $dailyHour) {
                                    ForEach(0..<24, id: \.self) { h in
                                        Text(String(format: "%02d", h)).tag(h)
                                    }
                                }
                                .frame(width: 80)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("分钟")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("分钟", selection: $dailyMinute) {
                                    ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { m in
                                        Text(String(format: "%02d", m)).tag(m)
                                    }
                                }
                                .frame(width: 80)
                            }
                        }
                    case .interval:
                        VStack(alignment: .leading, spacing: 4) {
                            Text("间隔")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("间隔", selection: $intervalHours) {
                                ForEach(Self.intervalOptions, id: \.self) { h in
                                    Text("每 \(h) 小时").tag(h)
                                }
                            }
                        }
                    case .custom:
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cron 表达式")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("例如: 30 9 * * 1-5", text: $customCron)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    // Preview
                    Text("预览: \(cronExpression)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)

                    // Task content
                    VStack(alignment: .leading, spacing: 4) {
                        Text("任务内容")
                            .font(.subheadline.weight(.medium))
                        TextEditor(text: $taskContent)
                            .font(.body)
                            .frame(minHeight: 100)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }

                    if let createError {
                        Text(createError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    // Create button
                    Button {
                        createJob()
                    } label: {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("创建")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate || isCreating)
                }
                .padding()
            }
        }
        .frame(width: 420, height: 560)
    }

    private func createJob() {
        isCreating = true
        createError = nil
        Task {
            do {
                let schedule: [String: Any] = [
                    "kind": "cron",
                    "expr": cronExpression,
                    "tz": "Asia/Shanghai"
                ]
                let payload: [String: Any] = [
                    "message": taskContent.trimmingCharacters(in: .whitespacesAndNewlines)
                ]
                try await client.cronCreateJob(
                    name: jobName.trimmingCharacters(in: .whitespaces),
                    agentId: selectedAgentId,
                    schedule: schedule,
                    payload: payload
                )
                onCreated()
                dismiss()
            } catch {
                createError = error.localizedDescription
            }
            isCreating = false
        }
    }
}
