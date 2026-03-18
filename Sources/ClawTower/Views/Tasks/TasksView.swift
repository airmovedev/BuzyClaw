import SwiftUI

struct TasksView: View {
    var manager: TaskManager
    var onOpenTaskContext: (String) -> Void
    @State private var showCreateSheet = false
    @State private var editingTask: TaskItem?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 12) {
                taskColumn(status: .todo, title: "待办", color: .blue)
                taskColumn(status: .inProgress, title: "进行中", color: .yellow)
                taskColumn(status: .inReview, title: "待审核", color: .purple)
                taskColumn(status: .done, title: "已完成", color: .green)
            }
            .padding(16)
        }
        .navigationTitle("任务看板")
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
        .sheet(item: $editingTask) { task in
            EditTaskSheet(task: task) { title, priority, status, context in
                Task { await manager.updateTask(taskID: task.id, title: title, priority: priority, status: status, context: context) }
            } onExecute: { context in
                onOpenTaskContext(context)
            }
        }
        .task {
            manager.start()
        }
    }

    private func taskColumn(status: TaskItem.Status, title: String, color: Color) -> some View {
        let allForStatus = tasksForStatus(status)
        let totalCount = allForStatus.count
        let displayTasks: [TaskItem] = status == .done ? Array(allForStatus.prefix(10)) : allForStatus

        return VStack(alignment: .leading, spacing: 8) {
            // 列标题
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title)
                    .font(.title3.weight(.semibold))
                Text("\(totalCount)")
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
                    ForEach(displayTasks) { task in
                        TaskCard(task: task) {
                            editingTask = task
                        } onMarkDone: {
                            Task { await manager.markTaskDone(taskID: task.id) }
                        }
                        .draggable(task.id)
                        .contextMenu {
                            ForEach(TaskItem.Priority.allCases, id: \.self) { priority in
                                Button {
                                    Task { await manager.updateTaskPriority(taskID: task.id, newPriority: priority) }
                                } label: {
                                    Label(priority.title, systemImage: task.priority == priority ? "checkmark" : "")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .dropDestination(for: String.self) { droppedIDs, _ in
                for taskID in droppedIDs {
                    Task { await manager.updateTaskStatus(taskID: taskID, newStatus: status) }
                }
                return true
            }
        }
        .frame(width: 280)
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
    @Environment(\.themeColor) private var themeColor
    @State private var title = ""
    @State private var priority: TaskItem.Priority = .medium
    @State private var note = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 标题输入
                    VStack(alignment: .leading, spacing: 6) {
                        Text("标题")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("任务标题", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    // 优先级
                    VStack(alignment: .leading, spacing: 6) {
                        Text("优先级")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $priority) {
                            ForEach(TaskItem.Priority.allCases, id: \.self) { p in
                                Label(p.title, systemImage: p.icon).tag(p)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    // 备注
                    VStack(alignment: .leading, spacing: 6) {
                        Text("备注（可选）")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("输入备注", text: $note, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...8)
                    }
                }
                .padding(20)
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
                    .tint(themeColor)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
    }
}

private struct EditTaskSheet: View {
    let task: TaskItem
    let onSave: (String, TaskItem.Priority, TaskItem.Status, String) -> Void
    let onExecute: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColor) private var themeColor
    @State private var title: String
    @State private var priority: TaskItem.Priority
    @State private var status: TaskItem.Status
    @State private var context: String

    init(task: TaskItem, onSave: @escaping (String, TaskItem.Priority, TaskItem.Status, String) -> Void, onExecute: @escaping (String) -> Void) {
        self.task = task
        self.onSave = onSave
        self.onExecute = onExecute
        _title = State(initialValue: task.title)
        _priority = State(initialValue: task.priority)
        _status = State(initialValue: task.status)
        _context = State(initialValue: task.context)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 标题
                    VStack(alignment: .leading, spacing: 6) {
                        Text("标题")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("任务标题", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    // 优先级 & 状态
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("优先级")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            Picker("", selection: $priority) {
                                ForEach(TaskItem.Priority.allCases, id: \.self) { p in
                                    Label(p.title, systemImage: p.icon).tag(p)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("状态")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            Picker("", selection: $status) {
                                ForEach(TaskItem.Status.allCases, id: \.self) { s in
                                    Text(s.title).tag(s)
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    // 备注
                    VStack(alignment: .leading, spacing: 6) {
                        Text("备注")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $context)
                            .font(.body)
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2))
                            )
                    }

                    // 立即执行
                    HStack {
                        Spacer()
                        Button {
                            let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
                            let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
                            let content = ctx.isEmpty ? text : text + "\n" + ctx
                            onExecute(content)
                            dismiss()
                        } label: {
                            Label("立即执行", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(themeColor)
                        Spacer()
                    }
                }
                .padding(20)
            }
            .navigationTitle("编辑任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(
                            title.trimmingCharacters(in: .whitespacesAndNewlines),
                            priority,
                            status,
                            context.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .tint(themeColor)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 460)
    }
}
