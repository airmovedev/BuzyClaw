import SwiftUI
import AppKit


struct ProjectsView: View {
    @State private var manager = ProjectsManager()

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 16)]
    }

    var body: some View {
        ScrollView {
            if manager.projects.isEmpty {
                ContentUnavailableView("暂无项目", systemImage: "folder")
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(manager.projects) { project in
                        NavigationLink {
                            ProjectDetailView(project: project, manager: manager)
                        } label: {
                            ProjectCardRow(project: project)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("项目")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    chooseRootDirectory()
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .help("配置项目根目录")
            }
        }
        .task { await manager.reload() }
    }

    private func chooseRootDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            Task { await manager.setRootURL(url) }
        }
    }
}

// MARK: - Project Card

private struct ProjectCardRow: View {
    @Environment(\.themeColor) private var themeColor
    let project: ProjectItem

    private var subdirLabels: [(String, String)] {
        var result: [(String, String)] = []
        if project.knownSubdirs.contains("pm") { result.append(("PM", "doc.text")) }
        if project.knownSubdirs.contains("design") { result.append(("Design", "paintbrush")) }
        if project.knownSubdirs.contains("engineering") { result.append(("Eng", "hammer")) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(themeColor)
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
            }

            HStack {
                Label("\(project.subdirectoryCount)", systemImage: "folder")
                Label("\(project.fileCount)", systemImage: "doc")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !subdirLabels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(subdirLabels, id: \.0) { label, icon in
                        HStack(spacing: 3) {
                            Image(systemName: icon)
                                .font(.system(size: 9))
                            Text(label)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(Capsule())
                    }
                }
            }

            if let last = project.lastActivityAt {
                Text("最近活动：\(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("最近活动：暂无")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Project Detail

private struct ProjectDetailView: View {
    let project: ProjectItem
    let manager: ProjectsManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 1. Overview
                ProjectOverviewSection(project: project)

                // 2. Progress bars
                ProjectProgressSection(sections: manager.sections(for: project))

                // 3. Related docs
                ProjectDocsSection(docs: manager.markdownDocs(for: project), manager: manager)

                // 4. Recent activity
                ProjectRecentSection(files: manager.recentFiles(for: project))

                // 5. Milestones
                let milestones = manager.milestones(for: project)
                if !milestones.isEmpty {
                    ProjectMilestonesSection(milestones: milestones)
                }

                // 6. Related tasks
                let tasks = manager.relatedTasks(for: project)
                if !tasks.isEmpty {
                    ProjectTasksSection(tasks: tasks)
                }
            }
            .padding(20)
        }
        .navigationTitle(project.name)
    }
}

// MARK: - Overview Section

private struct ProjectOverviewSection: View {
    let project: ProjectItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.name)
                .font(.title2.bold())

            HStack(spacing: 16) {
                Label("\(project.subdirectoryCount) 个子目录", systemImage: "folder")
                Label("\(project.fileCount) 个文件", systemImage: "doc")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let last = project.lastActivityAt {
                Label("最近活动：\(last.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Progress Section

private struct ProjectProgressSection: View {
    let sections: [ProjectSectionInfo]

    private var totalFiles: Int {
        sections.reduce(0) { $0 + $1.files.count }
    }

    var body: some View {
        if totalFiles > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("目录分布")
                    .font(.headline)

                ForEach(sections, id: \.name) { section in
                    if !section.files.isEmpty {
                        HStack(spacing: 8) {
                            Text(section.name.uppercased())
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .leading)

                            GeometryReader { geo in
                                let ratio = CGFloat(section.files.count) / CGFloat(max(totalFiles, 1))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(colorForSection(section.name))
                                    .frame(width: geo.size.width * ratio)
                            }
                            .frame(height: 8)

                            Text("\(section.files.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func colorForSection(_ name: String) -> Color {
        switch name {
        case "pm": .blue
        case "design": .purple
        case "engineering": .green
        case "marketing": .orange
        default: .gray
        }
    }
}

// MARK: - Related Docs Section

private struct ProjectDocsSection: View {
    @Environment(\.themeColor) private var themeColor
    let docs: [ProjectFileItem]
    let manager: ProjectsManager

    var body: some View {
        if !docs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("相关文档")
                    .font(.headline)

                ForEach(docs) { doc in
                    NavigationLink {
                        ProjectFileDetailView(file: doc, markdown: manager.markdownContent(for: doc))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(themeColor)
                            Text(doc.name)
                                .lineLimit(1)
                            Spacer()
                            if let modified = doc.modifiedAt {
                                Text(modified.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Recent Activity Section

private struct ProjectRecentSection: View {
    @Environment(\.themeColor) private var themeColor
    let files: [ProjectFileItem]

    var body: some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("最近活动")
                    .font(.headline)

                ForEach(files) { file in
                    HStack(spacing: 8) {
                        Image(systemName: file.isMarkdown ? "doc.text" : "doc")
                            .foregroundStyle(file.isMarkdown ? themeColor : .secondary)
                            .frame(width: 20)
                        Text(file.name)
                            .lineLimit(1)
                        Spacer()
                        if let modified = file.modifiedAt {
                            Text(modified.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(16)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Milestones Timeline Section

private struct ProjectMilestonesSection: View {
    let milestones: [Milestone]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("里程碑")
                .font(.headline)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(milestones.enumerated()), id: \.element.id) { index, milestone in
                    HStack(alignment: .top, spacing: 12) {
                        // Timeline line + dot
                        VStack(spacing: 0) {
                            Circle()
                                .fill(milestone.completed ? Color.green : Color.gray.opacity(0.4))
                                .frame(width: 12, height: 12)

                            if index < milestones.count - 1 {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(width: 2)
                                    .frame(minHeight: 32)
                            }
                        }
                        .frame(width: 12)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(milestone.name)
                                .font(.subheadline)
                                .foregroundStyle(milestone.completed ? .primary : .secondary)
                            Text(milestone.date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, index < milestones.count - 1 ? 16 : 0)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Related Tasks Section

private struct ProjectTasksSection: View {
    let tasks: [TaskItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("关联任务")
                .font(.headline)

            ForEach(tasks) { task in
                HStack(spacing: 8) {
                    Circle()
                        .fill(task.priority.color)
                        .frame(width: 8, height: 8)

                    Text(task.title)
                        .font(.subheadline)
                        .lineLimit(2)

                    Spacer()

                    Text(task.status.title)
                        .font(.caption)
                        .foregroundStyle(colorForStatus(task.status))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(colorForStatus(task.status).opacity(0.12))
                        .clipShape(Capsule())
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func colorForStatus(_ status: TaskItem.Status) -> Color {
        switch status {
        case .todo: .gray
        case .inProgress: .blue
        case .inReview: .orange
        case .done: .green
        }
    }
}

// MARK: - File Detail (unchanged)

private struct ProjectFileDetailView: View {
    let file: ProjectFileItem
    let markdown: String

    var body: some View {
        ScrollView {
            if file.isMarkdown {
                Text(projectMarkdown(markdown))
                    .padding(16)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(file.name)
                        .font(.title3)
                    Text("大小：\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                    if let modified = file.modifiedAt {
                        Text("修改时间：\(modified.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .navigationTitle(file.name)
    }
}

private func projectMarkdown(_ string: String) -> AttributedString {
    do {
        return try AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    } catch {
        return AttributedString(string)
    }
}
