import MirageCore
import SwiftUI

/// 收藏与搜索共用的自适应网格，最近使用通过独立只读包装调用。
struct LibraryGridView: View {
    let title: String?
    let records: [RemoteImageRecord]
    let favoriteIDs: Set<String>
    let emptyTitle: String
    let emptyDescription: String
    let allowsFavoriteChanges: Bool
    let onToggleFavorite: (RemoteImageRecord) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 230), spacing: 18)
    ]

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "photo.stack",
                    description: Text(emptyDescription)
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(records) { record in
                            ImageCard(
                                record: record,
                                isFavorite: favoriteIDs.contains(record.id),
                                allowsFavoriteChanges: allowsFavoriteChanges,
                                onToggleFavorite: { onToggleFavorite(record) }
                            )
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle(title ?? "发现")
    }
}

/// 最近使用只展示扩展记录，不允许在这个视图中改变任何资料库状态。
struct RecentGridView: View {
    let records: [RecentImageRecord]
    let favoriteIDs: Set<String>

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 230), spacing: 18)
    ]

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "还没有最近使用",
                    systemImage: "clock",
                    description: Text("从文件面板选择图片后，它会显示在这里。")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(records) { recent in
                            VStack(alignment: .leading, spacing: 6) {
                                ImageCard(
                                    record: recent.image,
                                    isFavorite: favoriteIDs.contains(recent.id),
                                    allowsFavoriteChanges: false,
                                    onToggleFavorite: {}
                                )
                                Text(recent.accessedAt, format: .relative(presentation: .named))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityLabel("使用时间，\(recent.accessedAt.formatted())")
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("最近使用")
    }
}
