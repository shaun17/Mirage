import MirageCore
import Foundation
import SwiftUI

/// 搜索页提供来源筛选和完整的异步状态反馈。
struct DiscoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var searchModel: SearchModel
    @Environment(\.openSettings) private var openSettings
    @State private var queryDraft = ""
    @State private var filterDraft: SearchFilter = .avatars
    @State private var isSwitchingContentMode = false
    /// 详情交给窗口级覆盖抽屉统一呈现。
    var onShowDetails: (RemoteImageRecord) -> Void = { _ in }

    var body: some View {
        searchableContent
            .navigationTitle("发现")
            .onAppear(perform: synchronizeCriteriaDrafts)
            .onChange(of: queryDraft) { _, query in
                commitQueryAfterViewUpdate(query)
            }
            .onChange(of: filterDraft) { _, filter in
                commitFilterAfterViewUpdate(filter)
            }
            .onChange(of: searchModel.query) { _, query in
                guard queryDraft != query else { return }
                queryDraft = query
            }
            .onChange(of: searchModel.filter) { _, filter in
                guard filterDraft != filter else { return }
                filterDraft = filter
            }
            .onChange(of: searchModel.accessibilityEvent) { _, event in
                guard let event else { return }
                AccessibilityNotification.Announcement(event.message).post()
            }
    }

    /// 所有内容类型共用搜索框；GIF 会把原始关键词直接交给 GIPHY Search。
    private var searchableContent: some View {
        discoveryContent
            .searchable(
                text: $queryDraft,
                placement: .toolbar,
                prompt: Text(searchPrompt)
            )
    }

    private var discoveryContent: some View {
        VStack(spacing: 0) {
            filterBar
                .frame(minHeight: 52)

            Divider()
            if filterDraft == .avatars {
                avatarTypeFilterBar
                Divider()
            } else if filterDraft == .gif {
                giphyContentTypeFilterBar
                Divider()
            } else if filterDraft == .photos {
                photoSourceFilterBar
                Divider()
            }
            searchBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 筛选工具条固定在结果滚动区上方，不随空态或图片数量改变纵向位置。
    private var filterBar: some View {
        HStack(spacing: 10) {
            Text("内容类型")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Picker("内容类型", selection: $filterDraft) {
                ForEach(SearchFilter.contentTypes) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220, alignment: .leading)

            if filterDraft == .gif {
                Spacer(minLength: 0)
                GiphyAttributionLink()
            } else {
                if let message = model.libraryAvailability.unavailableDescription {
                    Label("收藏不可用", systemImage: "heart.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(message)
                        .accessibilityLabel(message)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }

    /// 头像内容类型由 SearchModel 持有，切换内容页签不会重建或重置勾选。
    private var avatarTypeFilterBar: some View {
        AvatarTypeFilterBar(
            selection: searchModel.avatarTypeSelection,
            onToggle: searchModel.toggleAvatarType
        )
    }

    /// GIF 类型选择由 SearchModel 持有，未选中的 GIPHY 子流不会发起网络请求。
    private var giphyContentTypeFilterBar: some View {
        GiphyContentTypeFilterBar(
            selection: searchModel.giphyContentTypeSelection,
            onToggle: searchModel.toggleGiphyContentType
        )
    }

    /// 图片内容类型下固定展示完整服务商列表；只有标签区域横向滚动。
    private var photoSourceFilterBar: some View {
        PhotoSourceFilterBar(
            selection: searchModel.photoSourceSelection,
            enabledSourceIDs: searchModel.enabledPhotoSourceIDs,
            onSelect: searchModel.selectPhotoSource
        )
    }

    /// 本地草稿保持 AppKit Binding 的同步语义，模型只在下一主队列轮次接收变更。
    private func commitQueryAfterViewUpdate(_ query: String) {
        DispatchQueue.main.async { [weak searchModel] in
            guard let searchModel, searchModel.query != query else { return }
            searchModel.query = query
        }
    }

    /// 分段 Picker 使用同一提交边界，快速切换仍由 SearchModel 合并成最后一次搜索。
    private func commitFilterAfterViewUpdate(_ filter: SearchFilter) {
        guard searchModel.filter != filter else { return }
        isSwitchingContentMode = true
        DispatchQueue.main.async { [weak searchModel] in
            guard let searchModel, searchModel.filter != filter else {
                isSwitchingContentMode = false
                return
            }
            searchModel.filter = filter
            if filter == .gif {
                AccessibilityNotification.Announcement(
                    "已切换到 GIF；可以搜索 GIPHY GIF 和 Sticker"
                ).post()
            }
            // SearchModel 会在自己的下一次主队列轮次清空旧结果；等它先提交再恢复内容渲染。
            DispatchQueue.main.async { [weak searchModel] in
                guard searchModel?.filter == filter else { return }
                isSwitchingContentMode = false
            }
        }
    }

    /// 视图重新出现或模型由外部恢复条件时，让控件草稿与唯一状态源保持一致。
    private func synchronizeCriteriaDrafts() {
        if queryDraft != searchModel.query {
            queryDraft = searchModel.query
        }
        if filterDraft != searchModel.filter {
            filterDraft = searchModel.filter
        }
    }

    /// 每一种搜索结果都有独立视觉和辅助功能语义。
    @ViewBuilder
    private var searchBody: some View {
        if isSwitchingContentMode || hasResultsFromOtherPresentation {
            ProgressView("正在切换内容类型…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("正在切换内容类型")
        } else {
            searchStateBody
        }
    }

    /// 所有稳定搜索状态只在结果来源与当前隔离模式一致时呈现。
    @ViewBuilder
    private var searchStateBody: some View {
        switch searchModel.state {
        case .idle:
            if isGiphyMode {
                ProgressView("正在准备 GIPHY 内容…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("正在准备 GIPHY 内容")
            } else if searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ProgressView("正在准备推荐内容…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("正在准备推荐内容")
            } else {
                unavailable("继续输入关键词", symbol: "text.cursor", description: "输入至少一个字符开始搜索。")
            }
        case .searching:
            ProgressView(searchingDescription)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(giphySearchingAccessibilityLabel)
        case .results:
            VStack(spacing: 0) {
                if showsSourceIssueBar {
                    sourceIssueBar
                    Divider()
                }
                LibraryGridView(
                    title: nil,
                    records: searchModel.results,
                    favoriteIDs: model.favoriteIDs,
                    emptyTitle: isGiphyMode ? "没有可用 GIF" : "没有结果",
                    emptyDescription: resultEmptyDescription,
                    allowsFavoriteChanges: model.libraryAvailability.allowsFavoriteChanges,
                    pagination: GridPagination(
                        state: searchModel.paginationState,
                        contentName: contentName,
                        continueButtonTitle: isGiphyMode ? "继续浏览" : "继续查找",
                        loadNextPage: searchModel.loadNextPage,
                        continueLoading: searchModel.continueLoadingNextPage,
                        retry: searchModel.retryLoadingNextPage
                    ),
                    onToggleFavorite: { record in Task { await model.toggleFavorite(record) } },
                    onShowDetails: onShowDetails
                )
            }
        case .empty:
            VStack(spacing: 0) {
                if showsSourceIssueBar {
                    sourceIssueBar
                    Divider()
                }
                emptySearchView
            }
        case .network(let message):
            errorView("网络不可用", symbol: "wifi.exclamationmark", message: message)
        case .rateLimited(let message):
            errorView("请求过于频繁", symbol: "clock.badge.exclamationmark", message: message)
        case .failed(let message):
            errorView(
                isGiphyMode ? "加载 GIF 失败" : "搜索失败",
                symbol: "exclamationmark.triangle",
                message: message,
                showsSettings: isGiphyMode && hasGiphyCredentialIssue
            )
        }
    }

    /// 安全过滤连续产生空页时保留后续游标，让用户显式继续而不是无限连发请求。
    private var emptySearchView: some View {
        ContentUnavailableView {
            Label(
                isGiphyMode ? "暂时没有可用 GIF" : "暂时没有可用结果",
                systemImage: isGiphyMode ? "photo.stack" : "photo.on.rectangle.angled"
            )
        } description: {
            Text(emptySearchDescription)
        } actions: {
            switch searchModel.paginationState {
            case .loadingSources:
                ProgressView("正在等待其他图片数据源…")
            case .loading:
                ProgressView(isGiphyMode ? "正在继续浏览…" : "正在继续查找…")
            case .ready:
                EmptyView()
            case .needsContinuation:
                Button(isGiphyMode ? "继续浏览" : "继续查找", action: searchModel.continueLoadingNextPage)
            case .failed:
                Button("重新加载更多\(contentName)", action: searchModel.retryLoadingNextPage)
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
            return isGiphyMode
                ? "已浏览全部 GIPHY 内容。"
                : "已加载全部结果，可以换一个关键词或内容类型。"
        case .loadingSources:
            return "已收到部分结果，其他图片数据源仍在加载。"
        case .unavailable, .ready, .loading:
            return isGiphyMode
                ? "可以继续浏览 GIPHY Emoji、GIF 和 Sticker。"
                : "可以继续查找后续页面，或换一个关键词和内容类型。"
        }
    }

    /// 空白状态使用系统组件，确保字体缩放和 VoiceOver 行为一致。
    private func unavailable(_ title: String, symbol: String, description: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(description))
    }

    /// 错误状态保留具体原因，并允许在相同查询条件下重新执行。
    private func errorView(
        _ title: String,
        symbol: String,
        message: String,
        showsSettings: Bool = false
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if showsSettings {
                Button("打开设置") { openSettings() }
            }
            Button("重试") { searchModel.retrySearch() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var showsSourceIssueBar: Bool {
        !searchModel.sourceIssues.isEmpty
    }

    private var hasGiphyCredentialIssue: Bool {
        searchModel.sourceIssues.contains {
            $0.kind == .missingCredential || $0.kind == .invalidCredential
        }
    }

    private var isGiphyMode: Bool {
        filterDraft == .gif
    }

    private var hasGiphyQuery: Bool {
        isGiphyMode
            && !searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchPrompt: String {
        isGiphyMode ? "搜索 GIPHY GIF 或 Sticker" : "搜索头像或图片"
    }

    private var searchingDescription: String {
        if hasGiphyQuery { return "正在搜索 GIPHY GIF 与 Sticker…" }
        if isGiphyMode { return "正在读取 GIPHY 内容…" }
        if filterDraft == .avatars { return "正在生成头像…" }
        switch searchModel.photoSourceSelection {
        case .all:
            return "正在搜索已启用的图片数据源…"
        case let .source(sourceID):
            let name = PhotoSourceRegistry.descriptor(for: sourceID)?.displayName
                ?? sourceID.rawValue
            return "正在搜索 \(name)…"
        }
    }

    private var giphySearchingAccessibilityLabel: String {
        if hasGiphyQuery { return "正在搜索 GIPHY GIF 与 Sticker" }
        return isGiphyMode ? "正在读取 GIPHY 内容" : "正在搜索"
    }

    private var resultEmptyDescription: String {
        guard isGiphyMode else { return "换一个关键词再试。" }
        return hasGiphyQuery
            ? "GIPHY 没有返回匹配的 GIF 或 Sticker，换一个关键词再试。"
            : "GIPHY 当前没有返回可显示的 Emoji、GIF 或 Sticker。"
    }

    private var contentName: String {
        isGiphyMode ? "GIF" : "图片"
    }

    private var hasResultsFromOtherPresentation: Bool {
        searchModel.results.contains { record in
            (record.source == .giphy) != isGiphyMode
        }
    }

    /// 顶部只展示会影响当前结果的局部故障；供应商与许可信息保留在图片卡片和详情中。
    private var sourceIssueBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(searchModel.sourceIssues, id: \.sourceID) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle")
                    .lineLimit(2)
            }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// 来源标签沿用原生语义色；停用来源保留位置但不响应点击、键盘或悬停。
private struct PhotoSourceFilterBar: View {
    let selection: PhotoSourceFilterSelection
    let enabledSourceIDs: Set<PhotoSourceID>
    let onSelect: (PhotoSourceFilterSelection) -> Void

    private let descriptors = PhotoSourceRegistry.descriptors.filter {
        $0.availability == .available
            && $0.supportsAggregatedSearch(on: .app, purpose: .interactive)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("来源")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    sourceButton(
                        selection: .all,
                        isEnabled: !enabledSourceIDs.isEmpty
                    )
                    ForEach(descriptors) { descriptor in
                        sourceButton(
                            selection: .source(descriptor.id),
                            isEnabled: enabledSourceIDs.contains(descriptor.id)
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private func sourceButton(
        selection option: PhotoSourceFilterSelection,
        isEnabled: Bool
    ) -> some View {
        let isSelected = selection == option && isEnabled
        let disabledHelp = option == .all
            ? "没有在设置中启用可用的图片服务商"
            : "未在设置中启用"

        return Button {
            onSelect(option)
        } label: {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                }
                Text(option.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(
                isEnabled
                    ? (isSelected ? Color.accentColor : Color.primary)
                    : Color.secondary
            )
            .padding(.horizontal, isSelected ? 9 : 11)
            .frame(height: 22)
            .background {
                Capsule()
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.12)
                            : Color.secondary.opacity(0.08)
                    )
            }
            .overlay {
                Capsule()
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.35) : Color.clear,
                        lineWidth: 1
                    )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .help(isEnabled ? enabledHelp(for: option) : disabledHelp)
        .accessibilityLabel(
            isEnabled ? option.title : "\(option.title)，\(disabledHelp)"
        )
        .accessibilityValue(
            isEnabled ? (isSelected ? "已选择" : "未选择") : disabledHelp
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func enabledHelp(for option: PhotoSourceFilterSelection) -> String {
        option == .all ? "显示全部已启用来源" : "仅显示 \(option.title) 图片"
    }
}
