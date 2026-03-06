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

        return ProjectItem(
            name: url.lastPathComponent,
            url: url,
            subdirectoryCount: subdirectoryCount,
            fileCount: fileCount,
            lastActivityAt: latest
        )
    }

    static func resolveInitialRootURL() -> URL {
        if let saved = UserDefaults.standard.string(forKey: "projectsRootDirectoryPath"), !saved.isEmpty {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }

        let mode = UserDefaults.standard.string(forKey: "gatewayMode")
        let home = FileManager.default.homeDirectoryForCurrentUser
        if mode == "freshInstall" {
            return home
                .appendingPathComponent("Library/Application Support/ClawTower", isDirectory: true)
                .appendingPathComponent("Projects", isDirectory: true)
        }

        return home
            .appendingPathComponent(".openclaw", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
    }
}
