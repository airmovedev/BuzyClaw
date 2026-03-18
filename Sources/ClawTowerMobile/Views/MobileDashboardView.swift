import SwiftUI

struct MobileDashboardView: View {
    @Environment(DashboardSnapshotStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.isRefreshing && store.snapshot == nil {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if !store.isMacOSConnected && isEffectivelyEmpty {
                    SetupGuideView(
                        icon: "rectangle.grid.2x2",
                        title: "guide.dashboard.title",
                        description: "guide.dashboard.description",
                        features: [
                            .init(icon: "folder", text: "guide.dashboard.feature1"),
                            .init(icon: "checklist", text: "guide.dashboard.feature2"),
                            .init(icon: "chart.bar", text: "guide.dashboard.feature3"),
                        ],
                        onRetry: { await store.refresh() }
                    )
                } else if let error = store.lastError, store.snapshot == nil {
                    ContentUnavailableView {
                        Label("无法加载", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await store.refresh() } }
                    }
                } else if isEffectivelyEmpty {
                    ContentUnavailableView("暂无看板数据", systemImage: "rectangle.grid.2x2")
                } else {
                    dashboardContent
                }
            }
            .refreshable { await store.refresh() }
            .navigationTitle("看板")
        }
    }

    @ViewBuilder
    private var dashboardContent: some View {
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

            if !projects.isEmpty {
                Section("项目") {
                    ForEach(projects) { project in
                        projectRow(project)
                    }
                }
            }

            ForEach(tasksByStatus, id: \.0) { label, tasks in
                Section(label) {
                    ForEach(tasks) { task in
                        NavigationLink {
                            TaskDetailView(task: task)
                        } label: {
                            taskRow(task)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Row Views

    private func projectRow(_ project: ProjectSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.name)
                .font(.subheadline.bold())
                .lineLimit(2)

            Text(project.stage)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(stageColor(project.stage).opacity(0.15), in: Capsule())
                .foregroundStyle(stageColor(project.stage))

            if !project.agentHints.isEmpty {
                HStack(spacing: 4) {
                    ForEach(project.agentHints, id: \.self) { hint in
                        Text(hint)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.1), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func taskRow(_ task: TaskSnapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: taskIcon(task.status))
                .foregroundStyle(taskColor(task.status))
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(priorityLabel(task.priority))
                    .font(.caption2)
                    .foregroundStyle(priorityColor(task.priority))
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Computed Properties (from DashboardSnapshotStore)

    private var projects: [ProjectSnapshot] { store.snapshot?.projects ?? [] }

    private var tasksByStatus: [(String, [TaskSnapshot])] {
        guard let tasks = store.snapshot?.tasks else { return [] }
        let order = ["inProgress", "todo", "inReview", "done"]
        let reverseLabels: [String: String] = [
            "inProgress": "进行中",
            "todo": "建议",
            "inReview": "待审核",
            "done": "已完成",
        ]
        let grouped = Dictionary(grouping: tasks, by: { $0.status })
        return order.compactMap { status in
            guard let items = grouped[status], !items.isEmpty else { return nil }
            return (reverseLabels[status] ?? status, items)
        }
    }

    private var isEffectivelyEmpty: Bool {
        guard let snapshot = store.snapshot else { return true }
        return snapshot.agents.isEmpty && snapshot.projects.isEmpty && snapshot.tasks.isEmpty
            && (snapshot.cronJobs?.isEmpty ?? true)
            && (snapshot.secondBrainDocs?.isEmpty ?? true)
            && (snapshot.sessions?.isEmpty ?? true)
    }

    // MARK: - Helpers

    private func stageColor(_ stage: String) -> Color {
        switch stage {
        case "进行中": .blue
        case "待审核": .orange
        case "已完成": .green
        default: .secondary
        }
    }

    private func taskIcon(_ status: String) -> String {
        switch status {
        case "inProgress": "play.circle.fill"
        case "todo": "circle"
        case "inReview": "eye.circle.fill"
        case "done": "checkmark.circle.fill"
        default: "circle"
        }
    }

    private func taskColor(_ status: String) -> Color {
        switch status {
        case "inProgress": .blue
        case "todo": .secondary
        case "inReview": .orange
        case "done": .green
        default: .secondary
        }
    }

    private func priorityLabel(_ priority: String) -> String {
        switch priority {
        case "urgent": "🔴 紧急"
        case "high": "🟠 高优"
        case "medium": "🟡 中等"
        case "low": "🟢 低优"
        default: priority
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "urgent": .red
        case "high": .orange
        case "medium": .yellow
        case "low": .green
        default: .secondary
        }
    }
}

// MARK: - Task Detail View

struct TaskDetailView: View {
    let task: TaskSnapshot

    var body: some View {
        List {
            Section("标题") {
                Text(task.title)
                    .font(.body)
                    .textSelection(.enabled)
            }

            Section("优先级") {
                HStack(spacing: 8) {
                    Text(priorityLabel(task.priority))
                        .font(.body)
                    Spacer()
                    Text(priorityCaption(task.priority))
                        .font(.caption)
                        .foregroundStyle(priorityColor(task.priority))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(priorityColor(task.priority).opacity(0.12), in: Capsule())
                }
            }

            if let context = task.context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("备注") {
                    Text(context)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helpers

    private func priorityLabel(_ priority: String) -> String {
        switch priority {
        case "urgent": "🔴 紧急"
        case "high": "🟠 高优"
        case "medium": "🟡 中等"
        case "low": "🟢 低优"
        default: priority
        }
    }

    private func priorityCaption(_ priority: String) -> String {
        switch priority {
        case "urgent": "urgent"
        case "high": "high"
        case "medium": "medium"
        case "low": "low"
        default: priority
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "urgent": .red
        case "high": .orange
        case "medium": .yellow
        case "low": .green
        default: .secondary
        }
    }
}
