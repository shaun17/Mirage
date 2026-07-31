import MirageCore
import SwiftUI

/// 搜索网格的分页展示状态与动作；收藏页传 nil 保持静态列表。
struct GridPagination {
    let state: SearchPaginationState
    let loadNextPage: () -> Void
    let continueLoading: () -> Void
    let retry: () -> Void
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
                GeometryReader { viewport in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            LazyVGrid(columns: columns, spacing: 20) {
                                ForEach(records) { record in
                                    ImageCard(
                                        record: record,
                                        isFavorite: favoriteIDs.contains(record.id),
                                        allowsFavoriteChanges: allowsFavoriteChanges,
                                        onToggleFavorite: { onToggleFavorite(record) },
                                        onShowDetails: { onShowDetails(record) }
                                    )
                                }
                            }
                            if let pagination {
                                PaginationLoadTrigger(
                                    state: pagination.state,
                                    viewportHeight: viewport.size.height,
                                    loadNextPage: pagination.loadNextPage
                                )
                                // 新页面追加后重建触发器，防止旧尾部仍在视口内时连续偷跑下一页。
                                .id(records.last?.id)
                                .frame(height: 1)
                            }
                            paginationFooter
                        }
                        .padding(20)
                    }
                    .coordinateSpace(name: PaginationCoordinateSpace.name)
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
            case .loading:
                ProgressView("正在加载更多图片…")
                    .padding(.vertical, 8)
                    .accessibilityLabel("正在加载更多图片")
            case let .needsContinuation(message):
                VStack(spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("继续查找", action: pagination.continueLoading)
                }
                .padding(.vertical, 8)
            case let .failed(message):
                VStack(spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("重新加载更多图片", action: pagination.retry)
                }
                .padding(.vertical, 8)
            case .exhausted:
                Text("已加载全部结果")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            case .ready:
                Button("加载更多图片", action: pagination.loadNextPage)
                    .padding(.vertical, 8)
            case .unavailable:
                EmptyView()
            }
        }
    }
}

/// 搜索滚动区使用固定坐标空间测量尾部位置，避免把 Lazy 容器的预取误判成真实可见。
private enum PaginationCoordinateSpace {
    static let name = "Mirage.LibraryGrid.Scroll"
}

/// 记录尾部哨兵在滚动视口中的真实矩形；每次滚动都会通过偏好值更新。
private struct PaginationTriggerFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// 尾部进入视口前方的加载阈值后触发一页，同时保留显式按钮作为键盘和 VoiceOver 兜底。
private struct PaginationLoadTrigger: View {
    let state: SearchPaginationState
    let viewportHeight: CGFloat
    let loadNextPage: () -> Void

    @State private var frameInViewport = CGRect.null
    private let loadAheadDistance: CGFloat = 160

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: PaginationTriggerFramePreferenceKey.self,
                value: proxy.frame(in: .named(PaginationCoordinateSpace.name))
            )
        }
        .onPreferenceChange(PaginationTriggerFramePreferenceKey.self) { frame in
            frameInViewport = frame
            requestNextPageIfReady()
        }
        .onChange(of: state) { _, _ in
            requestNextPageIfReady()
        }
        .accessibilityHidden(true)
    }

    /// 只有哨兵真正靠近可见区域且分页就绪时才请求，模型层再保证同页只有一个任务。
    private func requestNextPageIfReady() {
        guard state.allowsAutomaticLoading, !frameInViewport.isNull else { return }
        let visibleRange = (-loadAheadDistance)...(viewportHeight + loadAheadDistance)
        guard frameInViewport.maxY >= visibleRange.lowerBound,
              frameInViewport.minY <= visibleRange.upperBound else {
            return
        }
        loadNextPage()
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
