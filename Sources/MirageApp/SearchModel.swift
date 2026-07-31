import MirageCore
import Foundation

/// 搜索页的唯一状态源，负责防抖、筛选、分页、去重和旧会话隔离。
@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published var filter: SearchFilter = .avatars {
        didSet { scheduleSearch() }
    }
    @Published private(set) var state: SearchState = .idle
    @Published private(set) var results: [RemoteImageRecord] = []
    @Published private(set) var paginationState: SearchPaginationState = .unavailable
    @Published private(set) var accessibilityEvent: SearchAccessibilityEvent?

    private static let pageSize = DiscoveryRecommendation.pageSize
    private static let maximumPagesPerLoad = 3
    private let service: ImageSearchService
    private var isWaitingForRecommendationFeed: Bool
    private var recommendationFeed: (any DiscoveryFeedProviding)?
    private var initialTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var loadMoreTaskID: UUID?
    private var activeRequest: SearchRequest?
    private var nextPage: Int?
    private var sessionID = UUID()
    private var resultIDs = Set<String>()
    private var isActive = false

    init(
        service: ImageSearchService = ImageSearchService(),
        recommendationFeed: (any DiscoveryFeedProviding)? = nil,
        waitsForRecommendationFeed: Bool = false
    ) {
        self.service = service
        self.recommendationFeed = recommendationFeed
        self.isWaitingForRecommendationFeed = waitsForRecommendationFeed
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

    /// 网络恢复或限流结束后，从第一页重新执行当前条件。
    func retrySearch() {
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
        initialTask?.cancel()
        loadMoreTask?.cancel()
        sessionID = UUID()
        initialTask = nil
        // 续页句柄由原任务退出时清理；期间保持 loading，禁止同一页并发重入。
        if state == .searching {
            state = .idle
        }
    }

    /// 条件变化立即隔离旧会话，并在400毫秒静默期后请求第一页。
    private func scheduleSearch() {
        initialTask?.cancel()
        loadMoreTask?.cancel()
        let newSessionID = UUID()
        sessionID = newSessionID
        activeRequest = nil
        results = []
        resultIDs = []
        resetPagination()

        guard let request = pendingRequest() else {
            state = .idle
            return
        }
        guard isActive else {
            state = .idle
            return
        }
        state = .searching
        initialTask = Task { [weak self] in
            do {
                if self?.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    try await Task.sleep(for: .milliseconds(400))
                }
                guard let self else { return }
                let loaded = try await self.firstVisiblePage(for: request)
                try Task.checkCancellation()
                guard self.sessionID == newSessionID else { return }
                let page = loaded.page
                let records = Self.unique(page.records)
                self.results = records
                self.resultIDs = Set(records.map(\.id))
                self.activeRequest = loaded.request
                self.nextPage = page.nextPage
                let paginationState = Self.paginationState(
                    after: page,
                    hasVisibleRecords: !records.isEmpty
                )
                self.paginationState = paginationState
                self.state = records.isEmpty ? .empty : .results
                if records.isEmpty {
                    self.announceEmptyResult(for: paginationState)
                } else {
                    self.announceLoaded(
                        records.count,
                        total: records.count,
                        exhausted: paginationState == .exhausted
                    )
                }
            } catch is CancellationError {
                return
            } catch let error as OpenverseError {
                guard !Task.isCancelled, self?.sessionID == newSessionID else { return }
                self?.commitInitialFailure(SearchState(openverseError: error))
            } catch {
                guard !Task.isCancelled, self?.sessionID == newSessionID else { return }
                self?.commitInitialFailure(.failed(error.localizedDescription))
            }
        }
    }

    /// 启动唯一的下一页任务，避免网格重复出现底部卡片时并发请求同一页。
    private func startLoadingNextPage() {
        guard isActive, state == .results || state == .empty else { return }
        guard loadMoreTask == nil, let request = activeRequest, let page = nextPage else { return }
        let activeSessionID = sessionID
        let taskID = UUID()
        loadMoreTaskID = taskID
        paginationState = .loading
        loadMoreTask = Task { [weak self] in
            guard let self else { return }
            await self.performLoadNextPage(
                request: request,
                startingAt: page,
                sessionID: activeSessionID,
                taskID: taskID
            )
        }
    }

    /// 追加下一批唯一记录；若一页经安全过滤后为空，自动推进到后续服务端页。
    private func performLoadNextPage(
        request: SearchRequest,
        startingAt page: Int,
        sessionID: UUID,
        taskID: UUID
    ) async {
        defer {
            if loadMoreTaskID == taskID {
                loadMoreTask = nil
                loadMoreTaskID = nil
                if self.sessionID != sessionID, paginationState == .loading {
                    paginationState = nextPage == nil ? .exhausted : .ready
                }
            }
        }
        do {
            var requestedPage = page
            for _ in 0..<Self.maximumPagesPerLoad {
                let loaded = try await loadPage(for: request, page: requestedPage)
                let response = loaded.page
                try Task.checkCancellation()
                guard self.sessionID == sessionID, activeRequest == request else { return }

                let additions = Self.unique(response.records, excluding: resultIDs)
                nextPage = response.nextPage
                if !additions.isEmpty {
                    resultIDs.formUnion(additions.map(\.id))
                    results.append(contentsOf: additions)
                    state = .results
                    paginationState = response.nextPage == nil ? .exhausted : .ready
                    announceLoaded(
                        additions.count,
                        total: results.count,
                        exhausted: paginationState == .exhausted
                    )
                    return
                }
                guard let followingPage = response.nextPage, followingPage > requestedPage else {
                    paginationState = .exhausted
                    announce("已加载全部结果")
                    return
                }
                requestedPage = followingPage
            }
            let message = "连续三页没有新的可用图片，可以继续查找。"
            paginationState = .needsContinuation(message)
            announce(message)
        } catch is CancellationError {
            return
        } catch DiscoveryFeedError.snapshotExpired {
            guard sessionID == self.sessionID, case .recommendations = request else { return }
            restartExpiredRecommendationSession()
        } catch let error as OpenverseError {
            guard self.sessionID == sessionID else { return }
            paginationState = .failed(error.localizedDescription)
            announce(error.localizedDescription)
        } catch {
            guard self.sessionID == sessionID else { return }
            paginationState = .failed(error.localizedDescription)
            announce(error.localizedDescription)
        }
    }

    /// 初页被安全校验全部过滤时最多连续检查三页，避免单次触发无限请求。
    private func firstVisiblePage(for request: SearchRequest) async throws -> SearchLoadResult {
        var requestedPage = 1
        var latest = SearchLoadResult(
            page: ImageSearchPage(records: [], nextPage: nil),
            request: request
        )
        for _ in 0..<Self.maximumPagesPerLoad {
            let loaded = try await loadPage(for: latest.request, page: requestedPage)
            try Task.checkCancellation()
            latest = loaded
            guard loaded.page.records.isEmpty, let followingPage = loaded.page.nextPage,
                  followingPage > requestedPage else { return loaded }
            requestedPage = followingPage
        }
        return latest
    }

    /// 空查询读取共享推荐 generation；普通关键词继续使用统一图片搜索服务。
    private func loadPage(for request: SearchRequest, page: Int) async throws -> SearchLoadResult {
        switch request {
        case let .recommendations(generation):
            guard let recommendationFeed else {
                let fallback = try await service.search(
                    DiscoveryRecommendation.query,
                    page: page,
                    pageSize: Self.pageSize
                )
                return SearchLoadResult(page: fallback, request: .query(DiscoveryRecommendation.query))
            }
            let result = try await recommendationFeed.page(
                generation: generation,
                page: page,
                pageSize: Self.pageSize
            )
            return SearchLoadResult(
                page: ImageSearchPage(records: result.records, nextPage: result.nextPage),
                request: .recommendations(result.generation)
            )
        case let .query(rawQuery):
            let page = try await service.search(rawQuery, page: page, pageSize: Self.pageSize)
            return SearchLoadResult(page: page, request: request)
        }
    }

    /// 空搜索框映射为推荐流；只有不完整的手工关键词进入真正 idle 状态。
    private func pendingRequest() -> SearchRequest? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if filter == .all {
                if recommendationFeed == nil, isWaitingForRecommendationFeed {
                    return nil
                }
                // App Group 尚未初始化或不可用时，loadPage 会降级到普通网络推荐，避免发现页永久空白。
                return .recommendations(nil)
            }
            return .query(filter.serviceQuery(for: DiscoveryRecommendation.query))
        }
        let request = filter.serviceQuery(for: query)
        // 统一以移除“头像:”或“图片:”前缀后的正文判断，单个中文字符也应是有效查询。
        guard !SearchQueryParser.parse(request).text.isEmpty else { return nil }
        return .query(request)
    }

    /// 新搜索完整清空旧游标和分页反馈，防止筛选切换后沿用上一条件。
    private func resetPagination() {
        loadMoreTask = nil
        loadMoreTaskID = nil
        nextPage = nil
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
    private static func paginationState(
        after page: ImageSearchPage,
        hasVisibleRecords: Bool
    ) -> SearchPaginationState {
        guard page.nextPage != nil else { return .exhausted }
        return hasVisibleRecords
            ? .ready
            : .needsContinuation("连续三页没有新的可用图片，可以继续查找。")
    }

    /// 空结果只播报需要继续操作或已经结束，不制造“加载0张”的无意义通知。
    private func announceEmptyResult(for paginationState: SearchPaginationState) {
        switch paginationState {
        case let .needsContinuation(message):
            announce(message)
        case .exhausted:
            announce("没有更多可用结果")
        case .unavailable, .ready, .loading, .failed:
            break
        }
    }

    /// 把新增数量、总数和末页状态合并成一条完整的 VoiceOver 信息。
    private func announceLoaded(_ count: Int, total: Int, exhausted: Bool) {
        guard count > 0 else { return }
        let suffix = exhausted ? "；已加载全部结果" : ""
        announce("已加载 \(count) 张图片，共 \(total) 张\(suffix)")
    }

    /// 使用唯一事件标识发布，即使相同错误再次发生也能重新播报。
    private func announce(_ message: String) {
        accessibilityEvent = SearchAccessibilityEvent(message: message)
    }

    /// 首屏失败同时提交视觉状态与单次 VoiceOver 播报，避免辅助功能停留在“正在搜索”。
    private func commitInitialFailure(_ failure: SearchState) {
        state = failure
        switch failure {
        case let .network(message):
            announce("网络不可用：\(message)")
        case let .rateLimited(message):
            announce("请求过于频繁：\(message)")
        case let .failed(message):
            announce("搜索失败：\(message)")
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
    case query(String)
    case recommendations(UInt64?)
}

/// 一次加载同时返回可见页和解析后的稳定会话，第一页由此锁定推荐 generation。
private struct SearchLoadResult {
    let page: ImageSearchPage
    let request: SearchRequest
}
