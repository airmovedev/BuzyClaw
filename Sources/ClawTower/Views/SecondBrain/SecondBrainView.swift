import AppKit
import MarkdownUI
import SwiftUI

struct SecondBrainView: View {
    private let viewTitle = "记忆中枢"
    @State private var documents: [SecondBrainDocument] = []
    @State private var selectedDocument: SecondBrainDocument?
    @State private var expandedGroups: Set<String> = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var dispatchSource: DispatchSourceFileSystemObject?

    // Search
    @State private var searchText: String = ""

    // Category tabs
    @State private var selectedCategory: String = "全部"

    // Inline editing
    @State private var isEditing = false
    @State private var editingContent: String = ""
    @State private var isSaving = false

    let basePath: URL

    private var baseDir: URL { basePath }

    private let categories = ["全部", "concepts", "daily-logs", "memory"]

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
        .navigationTitle(viewTitle)
    }

    // MARK: - Filtered Documents

    private var filteredDocuments: [SecondBrainDocument] {
        var result = documents

        // Filter by category
        if selectedCategory != "全部" {
            result = result.filter { $0.group == selectedCategory }
        }

        // Filter by search text
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter { doc in
                doc.fileName.lowercased().contains(query) ||
                doc.content.lowercased().contains(query)
            }
        }

        return result
    }

    private var filteredGroupedDocuments: [DocumentGroup] {
        let grouped = Dictionary(grouping: filteredDocuments, by: \.group)
        return grouped.keys.sorted().map { key in
            DocumentGroup(group: key, documents: grouped[key]!.sorted { $0.modifiedAt > $1.modifiedAt })
        }
    }

    // MARK: - Search match snippet

    private func matchSnippet(for document: SecondBrainDocument) -> String? {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return nil }

        // Search in content for a match
        let content = document.content
        let lowerContent = content.lowercased()
        guard let range = lowerContent.range(of: query) else { return nil }

        let matchStart = content.distance(from: content.startIndex, to: range.lowerBound)
        let matchEnd = content.distance(from: content.startIndex, to: range.upperBound)

        let snippetStart = max(0, matchStart - 30)
        let snippetEnd = min(content.count, matchEnd + 30)

        let startIdx = content.index(content.startIndex, offsetBy: snippetStart)
        let endIdx = content.index(content.startIndex, offsetBy: snippetEnd)
        var snippet = String(content[startIdx..<endIdx])

        // Clean up newlines for display
        snippet = snippet.replacingOccurrences(of: "\n", with: " ")

        let prefix = snippetStart > 0 ? "…" : ""
        let suffix = snippetEnd < content.count ? "…" : ""

        return "\(prefix)\(snippet)\(suffix)"
    }

    // MARK: - File List Panel

    @ViewBuilder
    private var fileListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索文档…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Category tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(categories, id: \.self) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            Text(category)
                                .font(.caption.weight(selectedCategory == category ? .semibold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    selectedCategory == category ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                    in: Capsule()
                                )
                                .foregroundStyle(selectedCategory == category ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 8)

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
            } else if filteredDocuments.isEmpty {
                ContentUnavailableView {
                    Label("无匹配结果", systemImage: "magnifyingglass")
                } description: {
                    Text("没有找到匹配的文档")
                }
            } else {
                List(selection: Binding(
                    get: { selectedDocument?.id },
                    set: { id in
                        if let id, let doc = filteredDocuments.first(where: { $0.id == id }) {
                            cancelEditing()
                            selectDocument(doc)
                        }
                    }
                )) {
                    ForEach(filteredGroupedDocuments, id: \.group) { group in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedGroups.contains(group.group) },
                                set: { if $0 { expandedGroups.insert(group.group) } else { expandedGroups.remove(group.group) } }
                            )
                        ) {
                            ForEach(group.documents) { doc in
                                VStack(alignment: .leading, spacing: 2) {
                                    SecondBrainDocRow(document: doc)
                                    if let snippet = matchSnippet(for: doc) {
                                        Text(snippet)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
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
                        expandedGroups = Set(filteredGroupedDocuments.map(\.group))
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

                    // Edit / Save / Cancel buttons (only for .md files)
                    if !document.isImage {
                        if isEditing {
                            Button("取消") {
                                cancelEditing()
                            }

                            Button("保存") {
                                saveDocument()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSaving)
                        } else {
                            Button {
                                startEditing()
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .help("编辑文档")
                        }
                    }

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([document.filePath])
                    } label: {
                        Image(systemName: "folder.badge.arrow.forward")
                    }
                    .help("在 Finder 中显示")
                    .fixedSize()
                }
                .padding()

                Divider()

                if document.isImage {
                    ScrollView {
                        imageContent(for: document)
                    }
                } else if isEditing {
                    TextEditor(text: $editingContent)
                        .font(.body.monospaced())
                        .padding(4)
                } else {
                    ScrollView {
                        Markdown(document.content)
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

    // MARK: - Editing

    private func startEditing() {
        guard let document = selectedDocument, !document.isImage else { return }
        isEditing = true
        Task {
            let content = (try? String(contentsOf: document.filePath, encoding: .utf8)) ?? document.content
            await MainActor.run {
                editingContent = content
            }
        }
    }

    private func cancelEditing() {
        isEditing = false
        editingContent = ""
    }

    private func saveDocument() {
        guard let document = selectedDocument, !isSaving else { return }
        isSaving = true
        let contentToSave = editingContent
        Task {
            do {
                try contentToSave.write(to: document.filePath, atomically: true, encoding: .utf8)
            } catch {
                // Silently fail — could add alert later
            }
            await MainActor.run {
                var updated = document
                updated.content = contentToSave
                selectedDocument = updated
                if let idx = documents.firstIndex(where: { $0.id == document.id }) {
                    documents[idx].content = contentToSave
                }
                isEditing = false
                editingContent = ""
                isSaving = false
            }
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

