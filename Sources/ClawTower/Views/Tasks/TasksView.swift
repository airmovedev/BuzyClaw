import SwiftUI

struct TasksView: View {
    var onOpenTaskContext: (String) -> Void

    @State private var manager = TaskManager()
    @State private var showCreateSheet = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            taskColumn(status: .todo, title: "待办", color: .blue)
            taskColumn(status: .inReview, title: "待审核", color: .purple)
            taskColumn(status: .done, title: "已完成", color: .green)
        }
        .padding(16)
        .navigationTitle("任务")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateTaskSheet { title, priority, note in
                Task { await manager.addTask(title: title, priority: priority, note: note) }
            }
        }
        .task {
            manager.start()
        }
    }

    private func taskColumn(status: TaskItem.Status, title: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 列标题
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title)
                    .font(.title3.weight(.semibold))
                Text("\(tasksForStatus(status).count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                Spacer()
            }
            .padding(.horizontal, 8)

            // 任务卡片列表
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasksForStatus(status)) { task in
                        TaskCard(task: task) {
                            onOpenTaskContext(task.context)
                        } onMarkDone: {
                            Task { await manager.markTaskDone(taskID: task.id) }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func tasksForStatus(_ status: TaskItem.Status) -> [TaskItem] {
        manager.tasks.filter { $0.status == status }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

private struct TaskCard: View {
    let task: TaskItem
    let onOpen: () -> Void
    let onMarkDone: () -> Void
    @State private var isContextExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(task.priority.color)
                    .frame(width: 8, height: 8)
                Text(task.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer()
                Button {
                    onMarkDone()
                } label: {
                    Image(systemName: task.status == .done ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(task.status == .done ? .green : .secondary)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .disabled(task.status == .done)
            }
            if !task.source.isEmpty {
                Text(task.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !task.context.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.context)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(isContextExpanded ? nil : 2)
                    Button(isContextExpanded ? "收起" : "展开") {
                        withAnimation { isContextExpanded.toggle() }
                    }
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

private struct CreateTaskSheet: View {
    let onCreate: (String, TaskItem.Priority, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var priority: TaskItem.Priority = .medium
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题", text: $title)
                Picker("优先级", selection: $priority) {
                    ForEach(TaskItem.Priority.allCases, id: \.self) { p in
                        Text(p.title).tag(p)
                    }
                }
                TextField("备注（可选）", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            }
            .navigationTitle("新建任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        onCreate(title.trimmingCharacters(in: .whitespacesAndNewlines), priority, note)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }
}
