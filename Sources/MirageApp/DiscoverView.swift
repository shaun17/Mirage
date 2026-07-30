import SwiftUI

/// 搜索页提供来源筛选、前缀提示和完整的异步状态反馈。
struct DiscoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("内容类型", selection: $model.searchFilter) {
                    ForEach(SearchFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)

                Text("也可输入“头像:”或“图片:”前缀")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            Divider()
            searchBody
        }
        .navigationTitle("发现")
        .searchable(text: $model.query, placement: .toolbar, prompt: "搜索头像或图片")
    }

    /// 每一种搜索结果都有独立视觉和辅助功能语义。
    @ViewBuilder
    private var searchBody: some View {
        switch model.searchState {
        case .idle:
            unavailable("搜索一张有趣的图片", symbol: "magnifyingglass", description: "输入至少两个字符开始搜索。")
        case .searching:
            ProgressView("正在搜索 CC0 / 公版内容…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("正在搜索")
        case .results:
            LibraryGridView(
                title: nil,
                records: model.results,
                favoriteIDs: model.favoriteIDs,
                emptyTitle: "没有结果",
                emptyDescription: "换一个关键词再试。",
                allowsFavoriteChanges: true,
                onToggleFavorite: { record in Task { await model.toggleFavorite(record) } }
            )
        case .empty:
            unavailable("没有结果", symbol: "photo.on.rectangle.angled", description: "换一个关键词或内容类型再试。")
        case .network(let message):
            errorView("网络不可用", symbol: "wifi.exclamationmark", message: message)
        case .rateLimited(let message):
            errorView("请求过于频繁", symbol: "clock.badge.exclamationmark", message: message)
        case .failed(let message):
            errorView("搜索失败", symbol: "exclamationmark.triangle", message: message)
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
            Button("重试") { model.retrySearch() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
