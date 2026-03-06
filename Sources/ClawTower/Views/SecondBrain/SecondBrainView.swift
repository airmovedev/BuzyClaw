import AppKit

import SwiftUI

struct SecondBrainView: View {
    @State private var documents: [SecondBrainDocument] = []
    @State private var selectedDocument: SecondBrainDocument?
    @State private var expandedGroups: Set<String> = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var dispatchSource: DispatchSourceFileSystemObject?

    let basePath: URL

    private var baseDir: URL { basePath }

    var body: some View {
        HSplitView {
            fileListPanel
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            documentPanel
        }
        .onAppear {
            loadDocuments()
            startWatching()
        }
        .onDisappear {
            stopWatching()
        }
    }

    // MARK: - File List Panel

    @ViewBuilder
    private var fileListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("第二大脑")
                    .font(.largeTitle.bold())
                Spacer()
                Button { loadDocuments() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新文件列表")
            }
            .padding()

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if documents.isEmpty {
                ContentUnavailableView {
                    Label("暂无文档", systemImage: "doc.text")
                } description: {
                    Text("~/.openclaw/workspace/second-brain/ 目录下没有 .md 文件")
                }
            } else {
                List(selection: Binding(
                    get: { selectedDocument?.id },
                    set: { id in
                        if let id, let doc = documents.first(where: { $0.id == id }) {
                            selectDocument(doc)
                        }
                    }
                )) {
                    ForEach(groupedDocuments, id: \.group) { group in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedGroups.contains(group.group) },
                                set: { if $0 { expandedGroups.insert(group.group) } else { expandedGroups.remove(group.group) } }
                            )
                        ) {
                            ForEach(group.documents) { doc in
                                SecondBrainDocRow(document: doc)
                                    .tag(doc.id)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.secondary)
                                Text(group.group)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(group.documents.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onAppear {
                    if expandedGroups.isEmpty {
                        expandedGroups = Set(groupedDocuments.map(\.group))
                    }
                }
            }
        }
    }

    // MARK: - Document Panel

    @ViewBuilder
    private var documentPanel: some View {
        Group {
        if let document = selectedDocument {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.fileName)
                            .font(.title2.bold())
                        HStack(spacing: 12) {
                            Label(document.group, systemImage: "folder")
                            Label(document.modifiedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([document.filePath])
                    } label: {
                        Image(systemName: "folder.badge.arrow.forward")
                    }
                    .help("在 Finder 中显示")
                }
                .padding()

                Divider()

                ScrollView {
                    if document.isImage {
                        imageContent(for: document)
                    } else {
                        Text(secondBrainMarkdown(document.content))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
        } else {
            ContentUnavailableView("选择一个文档查看", systemImage: "doc.text.magnifyingglass")
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func imageContent(for document: SecondBrainDocument) -> some View {
        if let nsImage = NSImage(contentsOf: document.filePath) {
            VStack(spacing: 12) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 800)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 4)

                HStack(spacing: 16) {
                    Label("\(Int(nsImage.size.width)) × \(Int(nsImage.size.height))", systemImage: "aspectratio")
                    if let fileSize = try? document.filePath.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        Label(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file), systemImage: "doc")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else {
            ContentUnavailableView("无法加载图片", systemImage: "photo.badge.exclamationmark")
                .padding()
        }
    }

    // MARK: - Grouped Documents

    private struct DocumentGroup {
        let group: String
        let documents: [SecondBrainDocument]
    }

    private var groupedDocuments: [DocumentGroup] {
        let grouped = Dictionary(grouping: documents, by: \.group)
        return grouped.keys.sorted().map { key in
            DocumentGroup(group: key, documents: grouped[key]!.sorted { $0.modifiedAt > $1.modifiedAt })
        }
    }

    // MARK: - Data Loading

    private func loadDocuments() {
        isLoading = true
        errorMessage = nil

        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDir.path) else {
            documents = []
            isLoading = false
            return
        }

        guard let enumerator = fm.enumerator(at: baseDir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            errorMessage = "无法读取目录"
            isLoading = false
            return
        }

        let supportedExtensions = Set(["md"]).union(SecondBrainDocument.imageExtensions)
        var docs: [SecondBrainDocument] = []

        while let url = enumerator.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }

            // Get relative path components to determine group
            let relativePath = url.path.replacingOccurrences(of: baseDir.path + "/", with: "")
            let components = relativePath.components(separatedBy: "/")

            // Skip root-level files (only show files in subdirectories)
            guard components.count >= 2 else { continue }

            let group = components[0]
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()

            var content = ""
            if url.pathExtension.lowercased() == "md" {
                content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }

            docs.append(SecondBrainDocument(filePath: url, group: group, content: content, modifiedAt: modDate))
        }

        documents = docs
        isLoading = false
    }

    private func selectDocument(_ doc: SecondBrainDocument) {
        var updated = doc
        if !doc.isImage {
            updated.content = (try? String(contentsOf: doc.filePath, encoding: .utf8)) ?? doc.content
        }
        selectedDocument = updated
    }

    // MARK: - File Watching

    private func startWatching() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: baseDir.path) {
            try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }

        let fd = open(baseDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [self] in
            self.loadDocuments()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        dispatchSource = source
    }

    private func stopWatching() {
        dispatchSource?.cancel()
        dispatchSource = nil
    }
}

// MARK: - Document Row

private struct SecondBrainDocRow: View {
    let document: SecondBrainDocument

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: document.isImage ? "photo" : "doc.text")
                .foregroundStyle(document.isImage ? .orange : .secondary)
                .frame(width: 16)
            Text(document.displayName)
                .font(.body)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

private func secondBrainMarkdown(_ string: String) -> AttributedString {
    do {
        return try AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    } catch {
        return AttributedString(string)
    }
}
