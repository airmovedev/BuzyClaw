
import SwiftUI
import MarkdownUI

struct MobileSecondBrainView: View {
    @Environment(DashboardSnapshotStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.isRefreshing && docs.isEmpty {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if !store.isMacOSConnected && docs.isEmpty {
                    SetupGuideView(
                        icon: "brain",
                        title: "guide.brain.title",
                        description: "guide.brain.description",
                        features: [
                            .init(icon: "doc.text", text: "guide.brain.feature1"),
                            .init(icon: "brain.head.profile", text: "guide.brain.feature2"),
                            .init(icon: "folder.badge.gearshape", text: "guide.brain.feature3"),
                        ],
                        onRetry: { await store.refresh() }
                    )
                } else if let error = store.lastError, docs.isEmpty {
                    ContentUnavailableView {
                        Label("无法加载", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await store.refresh() } }
                    }
                } else if docs.isEmpty {
                    ContentUnavailableView("暂无文档", systemImage: "brain")
                } else {
                    docList
                }
            }
            .refreshable { await store.refresh() }
            .navigationTitle("第二大脑")
        }
    }

    // MARK: - Computed Properties

    private var docs: [SecondBrainDocSnapshot] {
        store.snapshot?.secondBrainDocs ?? []
    }

    private var groupedDocs: [(group: String, docs: [SecondBrainDocSnapshot])] {
        let grouped = Dictionary(grouping: docs) { $0.group }
        return grouped.sorted { $0.key < $1.key }
            .map { (group: $0.key, docs: $0.value.sorted { $0.modifiedAt > $1.modifiedAt }) }
    }

    // MARK: - Subviews

    private var docList: some View {
        List {
            if !store.isMacOSConnected {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.slash.fill")
                            .foregroundStyle(.red)
                        Text("电脑端「虾忙」未连接")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        RetryButton { await store.refresh() }
                    }
                    .listRowBackground(Color.red.opacity(0.08))
                }
            }

            ForEach(groupedDocs, id: \.group) { group, docs in
                Section(group) {
                    ForEach(docs) { doc in
                        NavigationLink {
                            SecondBrainDocDetailView(doc: doc)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(doc.displayName)
                                        .font(.subheadline.bold())
                                        .lineLimit(1)
                                    Text(doc.modifiedAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct SecondBrainDocDetailView: View {
    let doc: SecondBrainDocSnapshot

    var body: some View {
        ScrollView {
            Markdown(doc.contentPreview)
                .padding()
        }
        .navigationTitle(doc.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
