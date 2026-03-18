import SwiftUI

struct CronJobsView: View {
    let appState: AppState

    private var client: GatewayClient { appState.gatewayClient }

    @State private var jobs: [CronJob] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var agentNames: [String: String] = [:]
    @State private var showCreateSheet = false

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
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                        Spacer()
                        Button("重试") {
                            Task { await loadJobs() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                if jobs.isEmpty && !isLoading && errorMessage == nil {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("直接告诉 AI 助手或点击右上角 ＋ 来新增定时提醒")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                } else {
                    let columns = [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ]
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(groupedJobs, id: \.agentId) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(agentDisplayName(group.agentId)) (\(group.jobs.count))")
                                    .font(.headline)
                                    .padding(.horizontal, 4)
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(group.jobs) { job in
                                        CronJobCardView(job: job, client: client, onRefresh: { Task { await loadJobs() } })
                                    }
                                }
                            }
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
            CronJobFormSheet(client: client) {
                Task { await loadJobs() }
            }
        }
        .navigationTitle("定时提醒")
        .task {
            loadAgentNames()
            // Wait for Gateway to be running before calling API
            for _ in 0..<30 {
                if appState.gatewayManager.isRunning { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard appState.gatewayManager.isRunning else {
                errorMessage = "Gateway 未运行，请在设置中检查 Gateway 状态"
                return
            }
            // Retry a few times in case Gateway just started
            for _ in 0..<3 {
                await loadJobs()
                if errorMessage == nil || Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func loadJobs() async {
        isLoading = true
        errorMessage = nil
        do {
            let data = try await client.cronListRaw()
            jobs = CronJobParser.parse(from: data)
        } catch let urlError as URLError {
            NSLog("[CronJobsView] URLError: \(urlError.code.rawValue), baseURL: \(client.baseURL)")
            errorMessage = "无法连接 Gateway（\(urlError.code.rawValue)），请确认 Gateway 已启动"
        } catch let gatewayError as GatewayClient.GatewayError {
            NSLog("[CronJobsView] GatewayError: \(gatewayError.localizedDescription ?? "nil"), baseURL: \(client.baseURL)")
            // Retry once after reloading auth token from config file
            client.reloadAuthToken()
            do {
                let data = try await client.cronListRaw()
                jobs = CronJobParser.parse(from: data)
                errorMessage = nil
                isLoading = false
                return
            } catch {
                errorMessage = gatewayError.localizedDescription
            }
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
    @Environment(\.themeColor) private var themeColor
    let job: CronJob
    let client: GatewayClient
    let onRefresh: () -> Void

    @State private var showFullMessage = false
    @State private var showDeleteAlert = false
    @State private var showEditSheet = false
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
                    .foregroundStyle(themeColor)
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

                Button("编辑") {
                    showEditSheet = true
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
        .sheet(isPresented: $showEditSheet) {
            CronJobFormSheet(client: client, editingJob: job, onSaved: onRefresh)
        }
    }

}

// MARK: - Cron Job Form Sheet (Create / Edit)

private struct CronJobFormSheet: View {
    let client: GatewayClient
    let editingJob: CronJob?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColor) private var themeColor

    @State private var jobName = ""
    @State private var selectedAgentId = "main"
    @State private var scheduleType: ScheduleType = .daily
    @State private var dailyHour = 9
    @State private var dailyMinute = 0
    @State private var intervalHours = 4
    @State private var customCron = ""
    @State private var taskContent = ""
    @State private var isSaving = false
    @State private var saveError: String?

    private var isEditMode: Bool { editingJob != nil }

    init(client: GatewayClient, editingJob: CronJob? = nil, onSaved: @escaping () -> Void) {
        self.client = client
        self.editingJob = editingJob
        self.onSaved = onSaved

        if let job = editingJob {
            _jobName = State(initialValue: job.name)
            _selectedAgentId = State(initialValue: job.agentId)
            _taskContent = State(initialValue: job.message)

            // Parse existing cron expression back to schedule type
            let parsed = Self.parseSchedule(job.schedule.expr)
            _scheduleType = State(initialValue: parsed.type)
            _dailyHour = State(initialValue: parsed.hour)
            _dailyMinute = State(initialValue: parsed.minute)
            _intervalHours = State(initialValue: parsed.interval)
            _customCron = State(initialValue: parsed.custom)
        }
    }

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

    private var canSave: Bool {
        !jobName.trimmingCharacters(in: .whitespaces).isEmpty
        && !taskContent.trimmingCharacters(in: .whitespaces).isEmpty
        && (scheduleType != .custom || !customCron.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 任务名称
                    VStack(alignment: .leading, spacing: 6) {
                        Text("任务名称")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("输入任务名称", text: $jobName)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Agent
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Agent")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $selectedAgentId) {
                            ForEach(agents, id: \.id) { agent in
                                Text(agent.label).tag(agent.id)
                            }
                        }
                        .labelsHidden()
                    }

                    // 调度类型
                    VStack(alignment: .leading, spacing: 6) {
                        Text("调度类型")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $scheduleType) {
                            ForEach(ScheduleType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    // 调度配置
                    switch scheduleType {
                    case .daily:
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("小时")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $dailyHour) {
                                    ForEach(0..<24, id: \.self) { h in
                                        Text(String(format: "%02d", h)).tag(h)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 80)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("分钟")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $dailyMinute) {
                                    ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { m in
                                        Text(String(format: "%02d", m)).tag(m)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 80)
                            }
                        }
                    case .interval:
                        VStack(alignment: .leading, spacing: 4) {
                            Text("间隔")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $intervalHours) {
                                ForEach(Self.intervalOptions, id: \.self) { h in
                                    Text("每 \(h) 小时").tag(h)
                                }
                            }
                            .labelsHidden()
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

                    // 预览
                    Text("预览: \(cronExpression)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)

                    // 任务内容
                    VStack(alignment: .leading, spacing: 6) {
                        Text("任务内容")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $taskContent)
                            .font(.body)
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }

                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                .padding(20)
            }
            .navigationTitle(isEditMode ? "编辑定时任务" : "创建定时任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(isEditMode ? "保存" : "创建") { saveJob() }
                            .disabled(!canSave)
                            .tint(themeColor)
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 520)
    }

    private func saveJob() {
        isSaving = true
        saveError = nil
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
                if let job = editingJob {
                    try await client.cronUpdateJob(
                        jobId: job.id,
                        name: jobName.trimmingCharacters(in: .whitespaces),
                        agentId: selectedAgentId,
                        schedule: schedule,
                        payload: payload
                    )
                } else {
                    try await client.cronCreateJob(
                        name: jobName.trimmingCharacters(in: .whitespaces),
                        agentId: selectedAgentId,
                        schedule: schedule,
                        payload: payload
                    )
                }
                onSaved()
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }

    // MARK: - Parse existing cron expression

    private static func parseSchedule(_ expr: String?) -> (type: ScheduleType, hour: Int, minute: Int, interval: Int, custom: String) {
        guard let expr, !expr.isEmpty else {
            return (.daily, 9, 0, 4, "")
        }

        let parts = expr.split(separator: " ").map(String.init)
        guard parts.count == 5 else {
            return (.custom, 9, 0, 4, expr)
        }

        let minuteStr = parts[0]
        let hourStr = parts[1]
        let dom = parts[2]
        let month = parts[3]
        let dow = parts[4]

        // Check interval pattern: "0 */N * * *"
        if minuteStr == "0" && hourStr.hasPrefix("*/") && dom == "*" && month == "*" && dow == "*" {
            if let n = Int(hourStr.dropFirst(2)), intervalOptions.contains(n) {
                return (.interval, 9, 0, n, "")
            }
        }

        // Check daily pattern: "M H * * *"
        if dom == "*" && month == "*" && dow == "*",
           let h = Int(hourStr), let m = Int(minuteStr) {
            // Round minute to nearest 5 for picker compatibility
            let roundedMinute = (m / 5) * 5
            return (.daily, h, roundedMinute, 4, "")
        }

        // Everything else is custom
        return (.custom, 9, 0, 4, expr)
    }
}
