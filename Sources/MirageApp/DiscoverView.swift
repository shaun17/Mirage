import MirageCore
import SwiftUI

/// 搜索页提供来源筛选、前缀提示和完整的异步状态反馈。
struct DiscoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var searchModel: SearchModel
    /// 详情交给窗口级检查器统一呈现。
    var onShowDetails: (RemoteImageRecord) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .frame(minHeight: 52)

            Divider()
            searchBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("发现")
        .searchable(text: $searchModel.query, placement: .toolbar, prompt: "搜索头像或图片")
        .onChange(of: searchModel.accessibilityEvent) { _, event in
            guard let event else { return }
            AccessibilityNotification.Announcement(event.message).post()
        }
    }

    /// 筛选工具条固定在结果滚动区上方，不随空态或图片数量改变纵向位置。
    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("内容类型", selection: $searchModel.filter) {
                ForEach(SearchFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            Text("也可输入“头像:”或“图片:”前缀")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = model.libraryAvailability.unavailableDescription {
                Label("收藏不可用", systemImage: "heart.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(message)
                    .accessibilityLabel(message)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 每一种搜索结果都有独立视觉和辅助功能语义。
    @ViewBuilder
    private var searchBody: some View {
        switch searchModel.state {
        case .idle:
            if searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ProgressView("正在准备推荐内容…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("正在准备推荐内容")
            } else {
                unavailable("继续输入关键词", symbol: "text.cursor", description: "输入至少一个字符开始搜索。")
            }
        case .searching:
            ProgressView("正在搜索 CC0 / 公版内容…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("正在搜索")
        case .results:
            LibraryGridView(
                title: nil,
                records: searchModel.results,
                favoriteIDs: model.favoriteIDs,
                emptyTitle: "没有结果",
                emptyDescription: "换一个关键词再试。",
                allowsFavoriteChanges: model.libraryAvailability.allowsFavoriteChanges,
                pagination: GridPagination(
                    state: searchModel.paginationState,
                    loadNextPage: searchModel.loadNextPage,
                    continueLoading: searchModel.continueLoadingNextPage,
                    retry: searchModel.retryLoadingNextPage
                ),
                onToggleFavorite: { record in Task { await model.toggleFavorite(record) } },
                onShowDetails: onShowDetails
            )
        case .empty:
            emptySearchView
        case .network(let message):
            errorView("网络不可用", symbol: "wifi.exclamationmark", message: message)
        case .rateLimited(let message):
            errorView("请求过于频繁", symbol: "clock.badge.exclamationmark", message: message)
        case .failed(let message):
            errorView("搜索失败", symbol: "exclamationmark.triangle", message: message)
        }
    }

    /// 安全过滤连续产生空页时保留后续游标，让用户显式继续而不是无限连发请求。
    private var emptySearchView: some View {
        ContentUnavailableView {
            Label("暂时没有可用结果", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(emptySearchDescription)
        } actions: {
            switch searchModel.paginationState {
            case .loading:
                ProgressView("正在继续查找…")
            case .ready:
                Button("继续查找", action: searchModel.loadNextPage)
            case .needsContinuation:
                Button("继续查找", action: searchModel.continueLoadingNextPage)
            case .failed:
                Button("重新加载更多图片", action: searchModel.retryLoadingNextPage)
            case .unavailable, .exhausted:
                EmptyView()
            }
        }
    }

    /// 空结果页依据分页状态区分正常扫描暂停、网络失败和真正无更多结果。
    private var emptySearchDescription: String {
        switch searchModel.paginationState {
        case let .needsContinuation(message), let .failed(message):
            return message
        case .exhausted:
            return "已加载全部结果，可以换一个关键词或内容类型。"
        case .unavailable, .ready, .loading:
            return "可以继续查找后续页面，或换一个关键词和内容类型。"
        }
    }

    /// 空白状态使用系统组件，确保字体缩放和 VoiceOver 行为一致。
    private func unavailable(_ title: String, symbol: String, description: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(description))
    }

    /// 错误状态保留具体原因，并允许在相同查询条件下重新执行。
    private func errorView(_ title: String, symbol: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            Button("重试") { searchModel.retrySearch() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
