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

private struct ProjectCardRow: View {
    let project: ProjectItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
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

private struct ProjectDetailView: View {
    let project: ProjectItem
    let manager: ProjectsManager

    var body: some View {
        List {
            ForEach(manager.sections(for: project), id: \.name) { section in
                Section(section.name.uppercased()) {
                    if section.files.isEmpty {
                        Text("暂无文件")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(section.files) { file in
                            NavigationLink {
                                ProjectFileDetailView(file: file, markdown: manager.markdownContent(for: file))
                            } label: {
                                HStack {
                                    Image(systemName: file.isMarkdown ? "doc.text" : "doc")
                                        .foregroundStyle(file.isMarkdown ? .blue : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name)
                                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(project.name)
    }
}

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
