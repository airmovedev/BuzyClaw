import Foundation

@MainActor
@Observable
final class TaskManager {
    private(set) var tasks: [TaskItem] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    private var pollTask: Task<Void, Never>?
    private var lastKnownModificationDate: Date?

    let tasksFileURL: URL

    init() {
        tasksFileURL = Self.resolveTasksFileURL()
    }

    func start() {
        guard pollTask == nil else { return }
        Task { await loadTasks() }

        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self.reloadIfChanged()
            }
        }
    }

    func loadTasks() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try ensureTasksFileIfNeeded()
            let data = try Data(contentsOf: tasksFileURL)
            let decoded = try JSONDecoder().decode([TaskItem].self, from: data)
            tasks = decoded.sorted(by: { $0.updatedAt > $1.updatedAt })
            lastKnownModificationDate = try tasksFileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            if tasks.isEmpty { tasks = [] }
        }
    }

    func addTask(title: String, priority: TaskItem.Priority, note: String?) async {
        let now = Date()
        let context = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newTask = TaskItem(
            title: title,
            status: .todo,
            priority: priority,
            source: "ClawTower",
            context: context,
            createdAt: now,
            updatedAt: now
        )
        tasks.insert(newTask, at: 0)
        await saveTasks()
    }

    /// Add a task linked to a subagent session key, with inProgress status.
    func addSubagentTask(title: String, sessionKey: String, parentTaskId: String? = nil) async {
        // Avoid duplicates: if a task with this source already exists, skip
        guard !tasks.contains(where: { $0.source == sessionKey }) else { return }
        let now = Date()
        let newTask = TaskItem(
            title: title,
            status: .inProgress,
            priority: .medium,
            source: sessionKey,
            context: "",
            parentTaskId: parentTaskId,
            createdAt: now,
            updatedAt: now
        )
        tasks.insert(newTask, at: 0)
        await saveTasks()
    }

    func findMatchingParentTask(subagentTitle: String) -> String? {
        let trimmed = subagentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let coreTitle = trimmed.replacingFirstMatch(
            pattern: #"^[A-Za-z][A-Za-z0-9 _-]*\s*:\s*"#,
            with: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !coreTitle.isEmpty else { return nil }

        return tasks
            .filter { $0.source == "ClawTower" }
            .filter { $0.status == .todo || $0.status == .inProgress }
            .filter { $0.title.localizedCaseInsensitiveContains(coreTitle) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first?
            .id
    }

    /// Mark a subagent-linked task as inReview and update its context with a summary.
    func completeSubagentTask(sessionKey: String, summary: String) async {
        guard let index = tasks.firstIndex(where: { $0.source == sessionKey }) else { return }
        guard tasks[index].status == .inProgress else { return }

        let now = Date()
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let parentTaskId = tasks[index].parentTaskId

        tasks[index].status = .inReview
        tasks[index].updatedAt = now
        if !trimmedSummary.isEmpty {
            tasks[index].context = trimmedSummary
        }

        if !trimmedSummary.isEmpty,
           let parentTaskId,
           let parentIndex = tasks.firstIndex(where: { $0.id == parentTaskId }) {
            tasks[parentIndex].context = trimmedSummary
            tasks[parentIndex].status = .inReview
            tasks[parentIndex].updatedAt = now
        }

        await saveTasks()
    }

    func updateTaskStatus(taskID: String, newStatus: TaskItem.Status) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard tasks[index].status != newStatus else { return }
        tasks[index].status = newStatus
        tasks[index].updatedAt = Date()
        await saveTasks()
    }

    func updateTaskPriority(taskID: String, newPriority: TaskItem.Priority) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard tasks[index].priority != newPriority else { return }
        tasks[index].priority = newPriority
        tasks[index].updatedAt = Date()
        await saveTasks()
    }

    func updateTask(taskID: String, title: String, priority: TaskItem.Priority, status: TaskItem.Status, context: String) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].title = title
        tasks[index].priority = priority
        tasks[index].status = status
        tasks[index].context = context
        tasks[index].updatedAt = Date()
        await saveTasks()
    }

    func markTaskDone(taskID: String) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard tasks[index].status != .done else { return }
        tasks[index].status = .done
        tasks[index].updatedAt = Date()
        await saveTasks()
    }

    func visibleTasks(for filter: TaskFilter) -> [TaskItem] {
        switch filter {
        case .all:
            return tasks
        case .todo:
            return tasks.filter { $0.status == .todo }
        case .inProgress:
            return tasks.filter { $0.status == .inProgress }
        case .inReview:
            return tasks.filter { $0.status == .inReview }
        case .done:
            return tasks.filter { $0.status == .done }
        }
    }

    func groupedTasks(for filter: TaskFilter) -> [(TaskItem.Status, [TaskItem])] {
        let filtered = visibleTasks(for: filter)

        let orderedStatuses: [TaskItem.Status] = {
            if filter == .all {
                return [.todo, .inProgress, .inReview, .done]
            }
            if filter == .done {
                return [.done]
            }
            if filter == .todo {
                return [.todo]
            }
            if filter == .inProgress {
                return [.inProgress]
            }
            return [.inReview]
        }()

        return orderedStatuses.compactMap { status in
            let sectionItems = filtered.filter { $0.status == status }
            if sectionItems.isEmpty { return nil }
            return (status, sectionItems)
        }
    }

    private func reloadIfChanged() async {
        do {
            let attrs = try tasksFileURL.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = attrs.contentModificationDate
            if let modified, modified != lastKnownModificationDate {
                await loadTasks()
            }
        } catch {
            // ignore poll errors to keep UI responsive
        }
    }

    private func saveTasks() async {
        do {
            try ensureTasksFileIfNeeded()
            let data = try JSONEncoder().encode(tasks)
            try data.write(to: tasksFileURL, options: [.atomic])
            lastKnownModificationDate = try tasksFileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func ensureTasksFileIfNeeded() throws {
        let dir = tasksFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: tasksFileURL.path) {
            try Data("[]".utf8).write(to: tasksFileURL)
        }
    }

    static func resolveTasksFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw", isDirectory: true)
            .appendingPathComponent("tasks.json", isDirectory: false)
    }
}

private extension String {
    func replacingFirstMatch(pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let range = NSRange(startIndex..., in: self)
        guard let match = regex.firstMatch(in: self, range: range),
              let matchRange = Range(match.range, in: self) else {
            return self
        }

        var value = self
        value.replaceSubrange(matchRange, with: replacement)
        return value
    }
}
