import Foundation

@MainActor
@Observable
final class ProjectsManager {
    private(set) var projects: [ProjectItem] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    let rootDirectoryKey = "projectsRootDirectoryPath"
    var rootURL: URL

    init() {
        rootURL = Self.resolveInitialRootURL()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let urls = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            let dirs = try urls.filter { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                return values.isDirectory == true
            }

            projects = try dirs.map { try self.scanProject(at: $0) }
                .sorted { lhs, rhs in
                    (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
                }
            lastError = nil
        } catch {
            projects = []
            lastError = error.localizedDescription
        }
    }

    func setRootURL(_ url: URL) async {
        rootURL = url
        UserDefaults.standard.set(url.path, forKey: rootDirectoryKey)
        await reload()
    }

    func sections(for project: ProjectItem) -> [ProjectSectionInfo] {
        let names = ["pm", "design", "engineering", "marketing"]
        return names.map { section in
            let sectionURL = project.url.appendingPathComponent(section, isDirectory: true)
            let files = (try? listFiles(in: sectionURL)) ?? []
            return ProjectSectionInfo(name: section, url: sectionURL, files: files)
        }
    }

    func markdownContent(for file: ProjectFileItem) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8)) ?? "无法读取文件"
    }

    /// Load milestones from project_dir/milestones.json
    func milestones(for project: ProjectItem) -> [Milestone] {
        let url = project.url.appendingPathComponent("milestones.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Milestone].self, from: data)) ?? []
    }

    /// List .md files under pm/ and design/ directories
    func markdownDocs(for project: ProjectItem) -> [ProjectFileItem] {
        let dirs = ["pm", "design"]
        return dirs.flatMap { dir -> [ProjectFileItem] in
            let dirURL = project.url.appendingPathComponent(dir, isDirectory: true)
            let files = (try? listFiles(in: dirURL)) ?? []
            return files.filter { $0.isMarkdown }
        }
    }

    /// Return the 5 most recently modified files in the project
    func recentFiles(for project: ProjectItem, limit: Int = 5) -> [ProjectFileItem] {
        guard let enumerator = FileManager.default.enumerator(
            at: project.url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [ProjectFileItem] = []
        while case let fileURL as URL = enumerator.nextObject() {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            items.append(ProjectFileItem(
                name: fileURL.lastPathComponent,
                url: fileURL,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            ))
        }
        return items
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// Load tasks from ~/.openclaw/tasks.json filtered by project name
    func relatedTasks(for project: ProjectItem) -> [TaskItem] {
        let tasksURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/tasks.json")
        guard let data = try? Data(contentsOf: tasksURL),
              let tasks = try? JSONDecoder().decode([TaskItem].self, from: data) else { return [] }
        let name = project.name.lowercased()
        return tasks.filter { task in
            task.source.lowercased().contains(name) || task.context.lowercased().contains(name)
        }
    }

    private func listFiles(in directory: URL) throws -> [ProjectFileItem] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { return nil }
            return ProjectFileItem(
                name: url.lastPathComponent,
                url: url,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func scanProject(at url: URL) throws -> ProjectItem {
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var subdirectoryCount = 0
        var fileCount = 0
        var latest: Date?

        while case let fileURL as URL = enumerator?.nextObject() {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey])
            if values.isDirectory == true {
                subdirectoryCount += 1
            } else if values.isRegularFile == true {
                fileCount += 1
                if let modified = values.contentModificationDate {
                    if let existing = latest {
                        latest = max(existing, modified)
                    } else {
                        latest = modified
                    }
                }
            }
        }

        // Detect known subdirectories
        let knownNames = ["pm", "design", "engineering"]
        var found = Set<String>()
        for name in knownNames {
            var isDir: ObjCBool = false
            let sub = url.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue {
                found.insert(name)
            }
        }

        return ProjectItem(
            name: url.lastPathComponent,
            url: url,
            subdirectoryCount: subdirectoryCount,
            fileCount: fileCount,
            lastActivityAt: latest,
            knownSubdirs: found
        )
    }

    static func resolveInitialRootURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home
            .appendingPathComponent(".openclaw", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)

        if let saved = UserDefaults.standard.string(forKey: "projectsRootDirectoryPath"), !saved.isEmpty {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }

        return projectsDir
    }
}
