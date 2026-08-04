import MirageCore
import SwiftUI

/// 搜索网格的分页展示状态与动作；收藏页传 nil 保持静态列表。
struct GridPagination {
    let state: SearchPaginationState
    let contentName: String
    let continueButtonTitle: String
    let loadNextPage: () -> Void
    let continueLoading: () -> Void
    let retry: () -> Void

    init(
        state: SearchPaginationState,
        contentName: String = "图片",
        continueButtonTitle: String = "继续查找",
        loadNextPage: @escaping () -> Void,
        continueLoading: @escaping () -> Void,
        retry: @escaping () -> Void
    ) {
        self.state = state
        self.contentName = contentName
        self.continueButtonTitle = continueButtonTitle
        self.loadNextPage = loadNextPage
        self.continueLoading = continueLoading
        self.retry = retry
    }
}

/// 收藏与搜索共用的自适应网格，最近使用通过独立只读包装调用。
struct LibraryGridView: View {
    let title: String?
    let records: [RemoteImageRecord]
    let favoriteIDs: Set<String>
    let emptyTitle: String
    let emptyDescription: String
    let allowsFavoriteChanges: Bool
    let pagination: GridPagination?
    let onToggleFavorite: (RemoteImageRecord) -> Void
    /// 详情由上层的单个检查器呈现，网格只负责报告用户选了哪一张。
    var onShowDetails: (RemoteImageRecord) -> Void = { _ in }

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
                    LazyVStack(spacing: 16) {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(records) { record in
                                ImageCard(
                                    record: record,
                                    isFavorite: favoriteIDs.contains(record.id),
                                    allowsFavoriteChanges: allowsFavoriteChanges
                                        && (record.source.allowsPersistentLibraryStorage
                                            || favoriteIDs.contains(record.id)),
                                    onToggleFavorite: { onToggleFavorite(record) },
                                    onShowDetails: { onShowDetails(record) }
                                )
                                .modifier(
                                    AutomaticPaginationTailModifier(
                                        taskID: automaticPaginationTaskID(for: record),
                                        loadNextPage: pagination?.loadNextPage ?? {}
                                    )
                                )
                            }
                        }
                        paginationFooter
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle(title ?? "发现")
    }

    /// 下一页加载失败时保留网格，并在底部提供不会自动连点的显式重试。
    @ViewBuilder
    private var paginationFooter: some View {
        if let pagination {
            switch pagination.state {
            case .loadingSources:
                ProgressView("其他\(pagination.contentName)数据源仍在加载…")
                    .padding(.vertical, 8)
                    .accessibilityLabel("其他\(pagination.contentName)数据源仍在加载")
            case .loading:
                ProgressView("正在加载更多\(pagination.contentName)…")
                    .padding(.vertical, 8)
                    .accessibilityLabel("正在加载更多\(pagination.contentName)")
            case let .needsContinuation(message):
                VStack(spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(pagination.continueButtonTitle, action: pagination.continueLoading)
                }
                .padding(.vertical, 8)
            case let .failed(message):
                VStack(spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("重新加载更多\(pagination.contentName)", action: pagination.retry)
                }
                .padding(.vertical, 8)
            case .exhausted:
                Text("已加载全部\(pagination.contentName)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            case .ready:
                Button("加载更多\(pagination.contentName)", action: pagination.loadNextPage)
                    .padding(.vertical, 8)
            case .unavailable:
                EmptyView()
            }
        }
    }

    /// 只给当前最后一张真实卡片分配任务标识；分页状态离开 ready 时会自动取消旧任务。
    private func automaticPaginationTaskID(
        for record: RemoteImageRecord
    ) -> AutomaticPaginationTailTaskID? {
        guard let pagination,
              pagination.state.allowsAutomaticLoading,
              record.id == records.last?.id,
              let firstID = records.first?.id else {
            return nil
        }
        return AutomaticPaginationTailTaskID(
            firstID: firstID,
            lastID: record.id,
            count: records.count
        )
    }
}

/// 首尾标识与数量共同区分结果会话和新页面，避免旧尾部任务误触发新条件的分页。
private struct AutomaticPaginationTailTaskID: Hashable {
    let firstID: String
    let lastID: String
    let count: Int
}

/// Lazy 网格实例化最后一张卡片时预取下一页，不再读取任何子视图坐标或回写布局状态。
private struct AutomaticPaginationTailModifier: ViewModifier {
    let taskID: AutomaticPaginationTailTaskID?
    let loadNextPage: () -> Void

    func body(content: Content) -> some View {
        content.task(id: taskID) {
            guard taskID != nil else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            loadNextPage()
        }
    }
}

/// 最近使用只展示扩展记录，不允许在这个视图中改变任何资料库状态。
struct RecentGridView: View {
    let records: [RecentImageRecord]
    let favoriteIDs: Set<String>
    /// 详情交给窗口级检查器统一呈现。
    var onShowDetails: (RemoteImageRecord) -> Void = { _ in }

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
                                    onToggleFavorite: {},
                                    onShowDetails: { onShowDetails(recent.image) }
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
