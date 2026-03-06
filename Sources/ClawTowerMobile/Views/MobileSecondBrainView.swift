
import SwiftUI

struct MobileSecondBrainView: View {
    @State private var viewModel = MobileSecondBrainViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.docs.isEmpty {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let error = viewModel.error, viewModel.docs.isEmpty {
                    ContentUnavailableView {
                        Label("无法加载", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await viewModel.fetch() } }
                    }
                } else if viewModel.docs.isEmpty {
                    ContentUnavailableView("暂无文档", systemImage: "brain")
                } else {
                    docList
                }
            }
            .refreshable { await viewModel.fetch() }
            .navigationTitle("第二大脑")
            .task { await viewModel.fetch() }
        }
    }

    private var docList: some View {
        List {
            ForEach(viewModel.groupedDocs, id: \.group) { group, docs in
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
            Text(mobileSecondBrainMarkdown(doc.contentPreview))
                .padding()
        }
        .navigationTitle(doc.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func mobileSecondBrainMarkdown(_ string: String) -> AttributedString {
    do {
        return try AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    } catch {
        return AttributedString(string)
    }
}
