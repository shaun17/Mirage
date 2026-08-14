import MirageCore
import Foundation

/// 搜索页的唯一状态源，负责防抖、筛选、分页、去重和旧会话隔离。
@MainActor
final class SearchModel: ObservableObject {
    typealias PhotoSearchServiceFactory = (PhotoSourceID?) -> ImageSearchService
    typealias AvatarTypeSelectionDidChange = (AvatarTypeSelection) -> Void
    typealias GiphyContentTypeSelectionDidChange = (GiphyContentTypeSelection) -> Void
    typealias PhotoSourceSelectionDidChange = (PhotoSourceFilterSelection) -> Void

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            deferSearchAfterCriteriaChange()
        }
    }
    @Published var filter: SearchFilter = .avatars {
        didSet {
            guard filter != oldValue else { return }
            deferSearchAfterCriteriaChange()
        }
    }
    @Published private(set) var state: SearchState = .idle
    @Published private(set) var results: [RemoteImageRecord] = []
    @Published private(set) var paginationState: SearchPaginationState = .unavailable
    @Published private(set) var sourceIssues: [PhotoSourceIssue] = []
    @Published private(set) var accessibilityEvent: SearchAccessibilityEvent?
    @Published private(set) var avatarTypeSelection: AvatarTypeSelection
    @Published private(set) var giphyContentTypeSelection: GiphyContentTypeSelection
    @Published private(set) var photoSourceSelection: PhotoSourceFilterSelection
    @Published private(set) var enabledPhotoSourceIDs: Set<PhotoSourceID> = [.openverse]

    private static let pageSize = DiscoveryRecommendation.pageSize
    private static let giphyPageSize = SearchPaginationCursor.maximumPageSize
    private static let maximumPagesPerLoad = 3
    private let service: ImageSearchService
    private let photoSearchService: PhotoSearchServiceFactory
    private let avatarTypeSelectionDidChange: AvatarTypeSelectionDidChange
    private let giphyContentTypeSelectionDidChange: GiphyContentTypeSelectionDidChange
    private let photoSourceSelectionDidChange: PhotoSourceSelectionDidChange
    private var isWaitingForRecommendationFeed: Bool
    private var recommendationFeed: (any DiscoveryFeedProviding)?
    private var criteriaChangeRevision: UInt64 = 0
    private var initialTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var loadMoreTaskID: UUID?
    private var activeRequest: SearchRequest?
    private var nextCursor: ImageSearchCursor?
    private var paginationRetryAt: Date?
    private var giphyRetryAt: Date?
    private var sessionID = UUID()
    private var resultIDs = Set<String>()
    private var isActive = false

    init(
        service: ImageSearchService = ImageSearchService(),
        photoSearchService: PhotoSearchServiceFactory? = nil,
        initialAvatarTypeSelection: AvatarTypeSelection = .all,
        avatarTypeSelectionDidChange: @escaping AvatarTypeSelectionDidChange = { _ in },
        initialGiphyContentTypeSelection: GiphyContentTypeSelection = .all,
        giphyContentTypeSelectionDidChange: @escaping GiphyContentTypeSelectionDidChange = { _ in },
        initialPhotoSourceSelection: PhotoSourceFilterSelection = .all,
        photoSourceSelectionDidChange: @escaping PhotoSourceSelectionDidChange = { _ in },
        recommendationFeed: (any DiscoveryFeedProviding)? = nil,
        waitsForRecommendationFeed: Bool = false
    ) {
        self.service = service
        self.photoSearchService = photoSearchService ?? { _ in service }
        self.avatarTypeSelection = initialAvatarTypeSelection
        self.avatarTypeSelectionDidChange = avatarTypeSelectionDidChange
        self.giphyContentTypeSelection = initialGiphyContentTypeSelection
        self.giphyContentTypeSelectionDidChange = giphyContentTypeSelectionDidChange
        self.photoSourceSelection = initialPhotoSourceSelection
        self.photoSourceSelectionDidChange = photoSourceSelectionDidChange
        self.recommendationFeed = recommendationFeed
        self.isWaitingForRecommendationFeed = waitsForRecommendationFeed
    }

    /// 头像类型支持任意多选；最后一个已选类型不会被取消。
    func toggleAvatarType(_ type: AvatarType) {
        let updatedSelection = avatarTypeSelection.toggling(type)
        guard updatedSelection != avatarTypeSelection else {
            announce("至少保留一种头像类型")
            return
        }
        avatarTypeSelection = updatedSelection
        avatarTypeSelectionDidChange(updatedSelection)
        guard filter == .avatars else { return }
        deferSearchAfterCriteriaChange()
    }

    /// GIF 类型支持任意多选；改变选择时开启全新 GIPHY 游标会话。
    func toggleGiphyContentType(_ type: GiphyContentType) {
        let updatedSelection = giphyContentTypeSelection.toggling(type)
        guard updatedSelection != giphyContentTypeSelection else {
            announce("至少保留一种 GIF 类型")
            return
        }
        giphyContentTypeSelection = updatedSelection
        giphyContentTypeSelectionDidChange(updatedSelection)
        guard filter == .gif else { return }
        deferSearchAfterCriteriaChange()
    }

    /// App Group 准备完成后注入共享推荐仓库，并立即启动空查询首页加载。
    func configureRecommendationFeed(_ feed: any DiscoveryFeedProviding) {
        guard recommendationFeed == nil else { return }
        recommendationFeed = feed
        isWaitingForRecommendationFeed = false
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           filter == .all {
            // 启动失败后可能已显示普通网络兜底；共享仓库恢复时必须切回同一 generation 推荐流。
            scheduleSearch()
        }
    }

    /// App Group 明确初始化失败后才启用普通网络推荐，避免启动阶段先请求一次再被共享仓库重置。
    func useRecommendationFallback() {
        guard recommendationFeed == nil else { return }
        isWaitingForRecommendationFeed = false
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           results.isEmpty,
           activeRequest == nil {
            scheduleSearch()
        }
    }

    /// 来源按钮只接受当前设置中已启用的服务商；选择会立即持久化并启动独立搜索会话。
    func selectPhotoSource(_ selection: PhotoSourceFilterSelection) {
        guard selection != photoSourceSelection,
              isPhotoSourceSelectionEnabled(selection) else { return }
        photoSourceSelection = selection
        photoSourceSelectionDidChange(selection)
        guard filter == .photos else { return }
        deferSearchAfterCriteriaChange()
    }

    /// App 启动时读取真实配置；若本地记住的来源已停用，则回退到仍可工作的聚合入口。
    func updatePhotoSourcePreferences(_ snapshot: PhotoSourcePreferencesSnapshot) {
        let didFallback = applyEnabledPhotoSources(from: snapshot)
        guard didFallback, filter == .photos else { return }
        scheduleSearch()
    }

    func isPhotoSourceSelectionEnabled(_ selection: PhotoSourceFilterSelection) -> Bool {
        guard let sourceID = selection.sourceID else { return !enabledPhotoSourceIDs.isEmpty }
        return enabledPhotoSourceIDs.contains(sourceID)
    }

    /// 网络恢复或限流结束后，从第一页重新执行当前条件。
    func retrySearch() {
        scheduleSearch()
    }

    /// 数据源开关或凭据变化后只重启受影响的搜索会话，防止无关设置绕过 GIPHY 退避。
    func sourceConfigurationDidChange(
        sourceID: PhotoSourceID,
        snapshot: PhotoSourcePreferencesSnapshot? = nil
    ) {
        let didFallback = snapshot.map { applyEnabledPhotoSources(from: $0) } ?? false
        if sourceID == .giphy {
            giphyRetryAt = nil
            guard filter == .gif else { return }
        } else {
            guard filter == .photos || filter == .all else { return }
            if filter == .photos,
               !didFallback,
               case let .source(selectedSourceID) = photoSourceSelection,
               selectedSourceID != sourceID {
                return
            }
        }
        scheduleSearch()
    }

    /// 网格接近底部时只从就绪态自动加载，避免重复触底并发请求同一页。
    func loadNextPage() {
        guard isActive, paginationState == .ready else { return }
        startLoadingNextPage()
    }

    /// 连续安全过滤空页达到预算后，由用户显式继续扫描下一批页面。
    func continueLoadingNextPage() {
        guard isActive, case .needsContinuation = paginationState else { return }
        startLoadingNextPage()
    }

    /// 分页失败不会清空已有结果，用户重试时继续请求同一页。
    func retryLoadingNextPage() {
        guard isActive, case .failed = paginationState else { return }
        if filter == .gif {
            if let retryAt = giphyRetryAt {
                guard retryAt <= Date() else {
                    announce("GIPHY 限流尚未结束，请稍后重试加载更多 GIF。")
                    return
                }
                giphyRetryAt = nil
            }
            if let paginationRetryAt, paginationRetryAt > Date() {
                announce("GIPHY 限流尚未结束，请稍后重试加载更多 GIF。")
                return
            }
        }
        paginationRetryAt = nil
        startLoadingNextPage()
    }

    /// 由窗口场景与当前栏目共同派生活跃状态，确保网络任务只有一个生命周期写入入口。
    func setActive(_ shouldBeActive: Bool) {
        guard shouldBeActive != isActive else { return }
        isActive = shouldBeActive
        if shouldBeActive {
            // 恢复时只重启尚未完成的首屏；续页仍由真实触底或用户操作决定。
            guard state == .idle, pendingRequest() != nil else { return }
            scheduleSearch()
        } else {
            cancelPendingWork()
        }
    }

    /// 离开发现页或窗口失活时取消页面等待，并使迟到响应失去提交资格。
    private func cancelPendingWork() {
        let wasLoadingInitialPage = state == .searching || paginationState == .loadingSources
        initialTask?.cancel()
        loadMoreTask?.cancel()
        sessionID = UUID()
        initialTask = nil
        // 条件变更任务仍需在下一轮把旧结果清为 idle；它会因 isActive=false 而保持离线。
        // 续页句柄由原任务退出时清理；期间保持 loading，禁止同一页并发重入。
        if wasLoadingInitialPage || filter == .gif {
            activeRequest = nil
            results = []
            resultIDs = []
            sourceIssues = []
            resetPagination()
            state = .idle
        }
    }

    /// Picker 和搜索框会在 SwiftUI 更新事务中写入筛选条件；把派生状态提交延后一轮，避免同步重入布局。
    private func deferSearchAfterCriteriaChange() {
        initialTask?.cancel()
        loadMoreTask?.cancel()

        // 立即让旧请求和旧分页失效，但不在控件的写入事务中发布新的视图状态。
        sessionID = UUID()
        initialTask = nil
        loadMoreTask = nil
        loadMoreTaskID = nil
        activeRequest = nil
        nextCursor = nil

        criteriaChangeRevision &+= 1
        let revision = criteriaChangeRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.criteriaChangeRevision == revision else { return }
            self.scheduleSearch()
        }
    }

    /// 条件变化立即隔离旧会话，并在400毫秒静默期后请求第一页。
    private func scheduleSearch() {
        // 显式重试或配置变化会使尚未执行的条件调度失效；条件调度自身也在这里完成消费。
        criteriaChangeRevision &+= 1
        initialTask?.cancel()
        loadMoreTask?.cancel()
        let newSessionID = UUID()
        sessionID = newSessionID
        activeRequest = nil
        results = []
        resultIDs = []
        sourceIssues = []
        resetPagination()

        guard let request = pendingRequest() else {
            state = .idle
            return
        }
        guard isActive else {
            state = .idle
            return
        }
        if request.isGiphy, let retryAt = giphyRetryAt {
            guard retryAt <= Date() else {
                commitInitialFailure(.rateLimited("GIPHY 请求过于频繁，请稍后重试。"))
                return
            }
            giphyRetryAt = nil
        }
        state = .searching
        initialTask = Task { [weak self] in
            do {
                guard let self else { return }
                if request.requiresDebounce(userQuery: self.query) {
                    try await Task.sleep(for: .milliseconds(400))
                }
                let loaded = try await self.firstVisiblePage(for: request) { [weak self] records in
                    await self?.commitInitialBatch(records, sessionID: newSessionID)
                }
                try Task.checkCancellation()
                guard self.sessionID == newSessionID else { return }
                let page = loaded.page
                let additions = Self.unique(page.records, excluding: self.resultIDs)
                self.resultIDs.formUnion(additions.map(\.id))
                self.results.append(contentsOf: additions)
                self.activeRequest = loaded.request
                self.nextCursor = page.nextCursor
                self.sourceIssues = page.issues
                self.updateRetryBoundaries(from: page.issues, for: request)
                let paginationState = self.paginationState(
                    after: page,
                    hasVisibleRecords: !self.results.isEmpty
                )
                self.paginationState = paginationState
                self.state = self.results.isEmpty ? .empty : .results
                if self.results.isEmpty {
                    self.announceEmptyResult(for: paginationState)
                } else {
                    self.announceLoaded(
                        self.results.count,
                        total: self.results.count,
                        exhausted: paginationState == .exhausted
                    )
                }
            } catch is CancellationError {
                // 条件切换、离开页面等真实 Task 取消应保持静默；若下游把一次独立的
                // I/O 中断包装成 CancellationError，则必须收敛为可见失败，不能永远 searching。
                guard !Task.isCancelled, let self, self.sessionID == newSessionID else { return }
                let message: AppDisplayMessage = request.isGiphy
                    ? "GIPHY 请求被中断，请重试。"
                    : "搜索请求被中断，请重试。"
                self.commitInitialFailure(.network(message))
            } catch let error as OpenverseError {
                guard !Task.isCancelled, self?.sessionID == newSessionID else { return }
                self?.commitInitialFailure(SearchState(openverseError: error))
            } catch let error as PhotoSearchError {
                guard !Task.isCancelled, let self, self.sessionID == newSessionID else { return }
                if case let .allSourcesFailed(issues) = error {
                    self.sourceIssues = issues
                }
                if request.isGiphy {
                    self.captureGiphyRetryBoundary(from: error)
                }
                self.commitInitialFailure(SearchState(photoSearchError: error))
            } catch {
                guard !Task.isCancelled, self?.sessionID == newSessionID else { return }
                self?.commitInitialFailure(.failed(.error(error)))
            }
        }
    }

    /// 启动唯一的下一页任务，避免网格重复出现底部卡片时并发请求同一页。
    private func startLoadingNextPage() {
        guard isActive, state == .results || state == .empty else { return }
        guard loadMoreTask == nil, let request = activeRequest, let cursor = nextCursor else { return }
        let activeSessionID = sessionID
        let taskID = UUID()
        loadMoreTaskID = taskID
        paginationState = .loading
        loadMoreTask = Task { [weak self] in
            guard let self else { return }
            await self.performLoadNextPage(
                request: request,
                startingAt: cursor,
                sessionID: activeSessionID,
                taskID: taskID
            )
        }
    }

    /// 追加下一批唯一记录；若一页经安全过滤后为空，自动推进到后续服务端页。
    private func performLoadNextPage(
        request: SearchRequest,
        startingAt cursor: ImageSearchCursor,
        sessionID: UUID,
        taskID: UUID
    ) async {
        defer {
            if loadMoreTaskID == taskID {
                loadMoreTask = nil
                loadMoreTaskID = nil
                if self.sessionID != sessionID, paginationState == .loading {
                    paginationState = nextCursor == nil ? .exhausted : .ready
                }
            }
        }
        do {
            var requestedCursor = cursor
            for _ in 0..<Self.maximumPagesPerLoad {
                let loaded = try await loadPage(for: request, cursor: requestedCursor)
                let response = loaded.page
                try Task.checkCancellation()
                guard self.sessionID == sessionID, activeRequest == request else { return }

                let additions = Self.unique(response.records, excluding: resultIDs)
                nextCursor = response.nextCursor
                sourceIssues = response.issues
                updateRetryBoundaries(from: response.issues, for: request)
                let responsePaginationState = paginationState(
                    after: response,
                    hasVisibleRecords: !results.isEmpty || !additions.isEmpty
                )
                if !additions.isEmpty {
                    resultIDs.formUnion(additions.map(\.id))
                    results.append(contentsOf: additions)
                    state = .results
                    paginationState = responsePaginationState
                    announceLoaded(
                        additions.count,
                        total: results.count,
                        exhausted: paginationState == .exhausted
                    )
                    return
                }
                if case let .failed(message) = responsePaginationState {
                    paginationState = responsePaginationState
                    announceIncludingSourceIssues(message)
                    return
                }
                guard let followingCursor = response.nextCursor,
                      followingCursor.page > requestedCursor.page else {
                    paginationState = .exhausted
                    announceIncludingSourceIssues(allLoadedMessage)
                    return
                }
                requestedCursor = followingCursor
            }
            let message = continuationMessage
            paginationState = .needsContinuation(message)
            announceIncludingSourceIssues(message)
        } catch is CancellationError {
            guard !Task.isCancelled,
                  self.sessionID == sessionID,
                  activeRequest == request else { return }
            let message: AppDisplayMessage = request.isGiphy
                ? "GIPHY 请求被中断，请重试。"
                : "搜索请求被中断，请重试。"
            paginationState = .failed(message)
            announce(message)
        } catch DiscoveryFeedError.snapshotExpired {
            guard sessionID == self.sessionID, case .recommendations = request else { return }
            restartExpiredRecommendationSession()
        } catch let error as OpenverseError {
            guard self.sessionID == sessionID else { return }
            let message = error.appDisplayMessage
            paginationState = .failed(message)
            announce(message)
        } catch let error as PhotoSearchError {
            guard self.sessionID == sessionID else { return }
            if case let .allSourcesFailed(issues) = error {
                sourceIssues = issues
            }
            if request.isGiphy {
                captureGiphyRetryBoundary(from: error)
                paginationRetryAt = giphyRetryAt
            }
            let message = error.appDisplayMessage
            paginationState = .failed(message)
            announce(message)
        } catch {
            guard self.sessionID == sessionID else { return }
            let message = AppDisplayMessage.error(error)
            paginationState = .failed(message)
            announce(message)
        }
    }

    /// 初页被安全校验全部过滤时最多连续检查三页，避免单次触发无限请求。
    private func firstVisiblePage(
        for request: SearchRequest,
        onPartialResults: @escaping @Sendable ([RemoteImageRecord]) async -> Void
    ) async throws -> SearchLoadResult {
        var requestedCursor: ImageSearchCursor?
        var latest = SearchLoadResult(
            page: ImageSearchPage(records: [], nextPage: nil),
            request: request
        )
        for _ in 0..<Self.maximumPagesPerLoad {
            let loaded = try await loadPage(
                for: latest.request,
                cursor: requestedCursor,
                onPartialResults: onPartialResults
            )
            try Task.checkCancellation()
            latest = loaded
            if request.isGiphy, !loaded.page.issues.isEmpty {
                return loaded
            }
            guard loaded.page.records.isEmpty, let followingCursor = loaded.page.nextCursor,
                  followingCursor.page > (requestedCursor?.page ?? 0) else { return loaded }
            requestedCursor = followingCursor
        }
        return latest
    }

    /// 空查询读取共享推荐 generation；普通关键词继续使用统一图片搜索服务。
    private func loadPage(
        for request: SearchRequest,
        cursor: ImageSearchCursor?,
        onPartialResults: (@Sendable ([RemoteImageRecord]) async -> Void)? = nil
    ) async throws -> SearchLoadResult {
        switch request {
        case let .recommendations(generation):
            guard let recommendationFeed else {
                let fallback = try await service.search(
                    DiscoveryRecommendation.query,
                    cursor: cursor,
                    pageSize: Self.pageSize
                )
                return SearchLoadResult(
                    page: fallback,
                    request: .query(
                        DiscoveryRecommendation.query,
                        photoSourceID: nil,
                        avatarTypes: nil
                    )
                )
            }
            let result = try await recommendationFeed.page(
                generation: generation,
                page: cursor?.page ?? 1,
                pageSize: Self.pageSize
            )
            return SearchLoadResult(
                page: ImageSearchPage(records: result.records, nextPage: result.nextPage),
                request: .recommendations(result.generation)
            )
        case let .query(rawQuery, selectedSourceID, avatarTypes):
            let activeService = photoSearchService(selectedSourceID)
            let page: ImageSearchPage
            if let onPartialResults, selectedSourceID == nil {
                page = try await activeService.search(
                    rawQuery,
                    cursor: cursor,
                    pageSize: Self.pageSize,
                    avatarTypes: avatarTypes,
                    onPartialResults: onPartialResults
                )
            } else {
                page = try await activeService.search(
                    rawQuery,
                    cursor: cursor,
                    pageSize: Self.pageSize,
                    avatarTypes: avatarTypes
                )
            }
            return SearchLoadResult(
                page: page,
                request: request
            )
        case let .giphy(query, contentTypes):
            return SearchLoadResult(
                page: try await service.giphyCatalog(
                    query: query,
                    cursor: cursor,
                    pageSize: Self.giphyPageSize,
                    contentTypes: contentTypes
                ),
                request: request
            )
        }
    }

    /// 首个完成来源立即进入网格；完整页返回前不开放触底分页，也不提前提交来源错误。
    private func commitInitialBatch(_ records: [RemoteImageRecord], sessionID: UUID) {
        guard self.sessionID == sessionID, isActive else { return }
        let additions = Self.unique(records, excluding: resultIDs)
        guard !additions.isEmpty else { return }
        let isFirstBatch = results.isEmpty
        resultIDs.formUnion(additions.map(\.id))
        results.append(contentsOf: additions)
        paginationState = .loadingSources
        state = .results
        if isFirstBatch {
            announce(.localized(
                "已先加载 %lld 张图片，其他图片数据源仍在加载",
                .integer(additions.count)
            ))
        }
    }

    /// GIF 空查询读取混合目录；其他空查询按当前内容类型读取推荐或默认内容。
    private func pendingRequest() -> SearchRequest? {
        if filter == .gif {
            return .giphy(
                query.trimmingCharacters(in: .whitespacesAndNewlines),
                contentTypes: giphyContentTypeSelection.types
            )
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if filter == .all {
                if recommendationFeed == nil, isWaitingForRecommendationFeed {
                    return nil
                }
                // App Group 尚未初始化或不可用时，loadPage 会降级到普通网络推荐，避免发现页永久空白。
                return .recommendations(nil)
            }
            return .query(
                filter.serviceQuery(for: DiscoveryRecommendation.query),
                photoSourceID: filter == .photos ? photoSourceSelection.sourceID : nil,
                avatarTypes: filter == .avatars ? avatarTypeSelection.types : nil
            )
        }
        let request = filter.serviceQuery(for: query)
        // 统一以移除内容范围前缀后的正文判断，单个中文字符也应是有效查询。
        guard !SearchQueryParser.parse(request).text.isEmpty else { return nil }
        return .query(
            request,
            photoSourceID: filter == .photos ? photoSourceSelection.sourceID : nil,
            avatarTypes: filter == .avatars ? avatarTypeSelection.types : nil
        )
    }

    /// 只把可在 App 内聚合搜索的来源暴露给标签行，GIPHY 等隔离来源不会混入。
    private func applyEnabledPhotoSources(
        from snapshot: PhotoSourcePreferencesSnapshot
    ) -> Bool {
        let enabled = Set(snapshot.appSourceIDs.filter { sourceID in
            guard let descriptor = PhotoSourceRegistry.descriptor(for: sourceID) else {
                return false
            }
            return descriptor.availability == .available
                && descriptor.supportsAggregatedSearch(on: .app, purpose: .interactive)
        })
        if enabled != enabledPhotoSourceIDs {
            enabledPhotoSourceIDs = enabled
        }
        guard let selectedSourceID = photoSourceSelection.sourceID,
              !enabled.contains(selectedSourceID) else { return false }

        let disabledName = photoSourceSelection.title
        photoSourceSelection = .all
        photoSourceSelectionDidChange(.all)
        announce(.localized(
            "%@ 未在设置中启用，已切换到全部来源",
            .text(disabledName)
        ))
        return true
    }

    /// 新搜索完整清空旧游标和分页反馈，防止筛选切换后沿用上一条件。
    private func resetPagination() {
        loadMoreTask = nil
        loadMoreTaskID = nil
        nextCursor = nil
        paginationRetryAt = nil
        paginationState = .unavailable
    }

    /// 冻结推荐代次被淘汰时丢弃旧游标并重新读取第一页，避免“重试”永久命中同一失效代次。
    private func restartExpiredRecommendationSession() {
        activeRequest = nil
        results = []
        resultIDs = []
        state = .idle
        resetPagination()
        announce("推荐内容已刷新，正在重新加载")
        scheduleSearch()
    }

    /// 根据当前服务页确定是继续自动加载、显式继续，还是已经全部结束。
    private func paginationState(
        after page: ImageSearchPage,
        hasVisibleRecords: Bool
    ) -> SearchPaginationState {
        guard page.nextPage != nil else { return .exhausted }
        if filter == .gif, !page.issues.isEmpty {
            if page.issues.contains(where: { $0.kind == .rateLimited }) {
                return .failed("部分 GIPHY 内容受到限流，请稍后重试加载更多 GIF。")
            }
            if page.issues.contains(where: {
                $0.kind == .missingCredential || $0.kind == .invalidCredential
            }) {
                return .failed("部分 GIPHY 接口无法使用，请检查 API Key 后重试。")
            }
            return .failed("部分 GIPHY 内容暂时不可用，请重试加载更多 GIF。")
        }
        return hasVisibleRecords
            ? .ready
            : .needsContinuation(continuationMessage)
    }

    /// GIPHY 的限流门槛跨分页、筛选切换和窗口失活保留，避免重建会话后提前重复请求。
    private func updateRetryBoundaries(
        from issues: [PhotoSourceIssue],
        for request: SearchRequest
    ) {
        guard request.isGiphy else {
            paginationRetryAt = nil
            return
        }
        let rateLimitIssues = issues.filter { $0.kind == .rateLimited }
        let retryAt = rateLimitIssues.isEmpty
            ? nil
            : rateLimitIssues.compactMap(\.retryAt).max()
                ?? Date().addingTimeInterval(
                    PhotoSourceRequestPolicies.policy(for: .giphy).rateLimitFallback
                )
        paginationRetryAt = retryAt

        guard let retryAt else {
            giphyRetryAt = nil
            return
        }
        giphyRetryAt = max(giphyRetryAt ?? retryAt, retryAt)
    }

    /// GIPHY 不经过持久化请求协调器，因此整页 429 的退避必须在唯一 App 请求入口执行。
    private func captureGiphyRetryBoundary(from error: PhotoSearchError) {
        guard case let .allSourcesFailed(issues) = error,
              issues.contains(where: { $0.kind == .rateLimited }) else {
            return
        }
        let retryAt = issues
            .filter { $0.kind == .rateLimited }
            .compactMap(\.retryAt)
            .max()
            ?? Date().addingTimeInterval(
                PhotoSourceRequestPolicies.policy(for: .giphy).rateLimitFallback
            )
        giphyRetryAt = max(giphyRetryAt ?? retryAt, retryAt)
    }

    /// 空结果只播报需要继续操作或已经结束，不制造“加载0张”的无意义通知。
    private func announceEmptyResult(for paginationState: SearchPaginationState) {
        switch paginationState {
        case let .needsContinuation(message):
            announceIncludingSourceIssues(message)
        case .exhausted:
            announceIncludingSourceIssues(
                filter == .gif ? "没有更多可用 GIF" : "没有更多可用图片"
            )
        case .unavailable, .loadingSources, .ready, .loading, .failed:
            break
        }
    }

    /// 把新增数量、总数和末页状态合并成一条完整的 VoiceOver 信息。
    private func announceLoaded(_ count: Int, total: Int, exhausted: Bool) {
        guard count > 0 else { return }
        if filter == .gif, exhausted {
            announceIncludingSourceIssues(.localized(
                "已加载 %lld 个 GIF，共 %lld 个 GIF；已加载全部 GIF",
                .integer(count),
                .integer(total)
            ))
        } else if filter == .gif {
            announceIncludingSourceIssues(.localized(
                "已加载 %lld 个 GIF，共 %lld 个 GIF",
                .integer(count),
                .integer(total)
            ))
        } else if exhausted {
            announceIncludingSourceIssues(.localized(
                "已加载 %lld 张图片，共 %lld 张；已加载全部图片",
                .integer(count),
                .integer(total)
            ))
        } else {
            announceIncludingSourceIssues(.localized(
                "已加载 %lld 张图片，共 %lld 张",
                .integer(count),
                .integer(total)
            ))
        }
    }

    private var allLoadedMessage: AppDisplayMessage {
        filter == .gif ? "已加载全部 GIF" : "已加载全部图片"
    }

    private var continuationMessage: AppDisplayMessage {
        filter == .gif
            ? "连续三页没有新的可用 GIF，可以继续浏览。"
            : "连续三页没有新的可用图片，可以继续查找。"
    }

    /// 聚合搜索仍有可用结果时，把局部来源故障合并进同一次 VoiceOver 公告。
    private func announceIncludingSourceIssues(_ message: AppDisplayMessage) {
        guard !sourceIssues.isEmpty else {
            announce(message)
            return
        }
        guard let issueSummary = AppDisplayMessage.joined(
            sourceIssues.map(\.appDisplayMessage)
        ) else {
            announce(message)
            return
        }
        announce(.localized(
            "%@；部分数据源不可用：%@",
            .message(message),
            .message(issueSummary)
        ))
    }

    /// 使用唯一事件标识发布，即使相同错误再次发生也能重新播报。
    private func announce(_ message: AppDisplayMessage) {
        accessibilityEvent = SearchAccessibilityEvent(message: message)
    }

    /// 首屏失败同时提交视觉状态与单次 VoiceOver 播报，避免辅助功能停留在“正在搜索”。
    private func commitInitialFailure(_ failure: SearchState) {
        state = failure
        switch failure {
        case let .network(message):
            announce(.localized("网络不可用：%@", .message(message)))
        case let .rateLimited(message):
            announce(.localized("请求过于频繁：%@", .message(message)))
        case let .failed(message):
            announce(
                filter == .gif
                    ? .localized("加载 GIF 失败：%@", .message(message))
                    : .localized("搜索失败：%@", .message(message))
            )
        case .idle, .searching, .results, .empty:
            break
        }
    }

    /// 按稳定图片ID去重并保留数据源原始顺序。
    private static func unique(
        _ records: [RemoteImageRecord],
        excluding existingIDs: Set<String> = []
    ) -> [RemoteImageRecord] {
        var seen = existingIDs
        return records.filter { seen.insert($0.id).inserted }
    }

}

/// 搜索会话要么绑定普通查询文字，要么绑定共享推荐快照的 generation。
private enum SearchRequest: Equatable {
    case query(
        String,
        photoSourceID: PhotoSourceID?,
        avatarTypes: Set<AvatarType>?
    )
    case recommendations(UInt64?)
    case giphy(String, contentTypes: Set<GiphyContentType>)

    var isGiphy: Bool {
        guard case .giphy = self else { return false }
        return true
    }

    func requiresDebounce(userQuery: String) -> Bool {
        switch self {
        case .query:
            return !userQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .giphy(query, _):
            return !query.isEmpty
        case .recommendations:
            return false
        }
    }
}

/// 一次加载同时返回可见页和解析后的稳定会话，第一页由此锁定推荐 generation。
private struct SearchLoadResult {
    let page: ImageSearchPage
    let request: SearchRequest
}
