import SwiftUI

struct MobileDashboardView: View {
    @State private var viewModel = MobileDashboardViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                if viewModel.isLoading && viewModel.snapshot == nil {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let error = viewModel.error, viewModel.snapshot == nil {
                    ContentUnavailableView {
                        Label("无法加载", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await viewModel.fetch() } }
                    }
                } else if viewModel.isEffectivelyEmpty {
                    ContentUnavailableView("暂无看板数据", systemImage: "rectangle.grid.2x2")
                } else {
                    dashboardContent
                }
            }
            .refreshable { await viewModel.fetch() }
            .navigationTitle("看板")
            .toolbar {
                if let age = viewModel.snapshotAge {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text(age)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task { await viewModel.fetch() }
        }
    }

    @ViewBuilder
    private var dashboardContent: some View {
        LazyVStack(spacing: 20) {
            if !viewModel.projects.isEmpty {
                sectionHeader("项目", icon: "folder")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(viewModel.projects) { project in
                        projectCard(project)
                    }
                }
                .padding(.horizontal)
            }

            if !viewModel.tasksByStatus.isEmpty {
                sectionHeader("建议板", icon: "checklist")
                ForEach(viewModel.tasksByStatus, id: \.0) { label, tasks in
                    taskGroup(label: label, tasks: tasks)
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
    }

    // MARK: - Components

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal)
    }

    private func projectCard(_ project: ProjectSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func taskGroup(label: String, tasks: [TaskSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            ForEach(tasks) { task in
                HStack(spacing: 8) {
                    Image(systemName: taskIcon(task.status))
                        .foregroundStyle(taskColor(task.status))
                        .font(.caption)
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
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
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
