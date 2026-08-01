import Foundation
import MirageCore
import XCTest

@MainActor
final class SearchModelTests: XCTestCase {
    /// 内容类型按产品入口优先级展示，头像应默认出现在最左侧。
    func testContentFiltersPresentAvatarsPhotosThenAll() {
        XCTAssertEqual(SearchFilter.allCases, [.avatars, .photos, .all])
    }

    /// 新搜索会话默认进入头像来源，避免首次发现页混入图片结果。
    func testNewSearchModelDefaultsToAvatarFilter() {
        XCTAssertEqual(SearchModel().filter, .avatars)
    }

    /// 筛选控件只应同步发布自身绑定值；结果清空和状态切换必须离开当前 SwiftUI 更新事务。
    func testFilterChangeDefersDerivedStateReset() async {
        let openverse = OpenverseCallCounter()
        let model = SearchModel(
            service: ImageSearchService(
                openverse: openverse,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.setActive(true)
        let loaded = await waitUntil { model.results.count == 20 }
        XCTAssertTrue(loaded)

        let previousResults = model.results
        model.filter = .photos

        XCTAssertEqual(model.state, .results)
        XCTAssertEqual(model.results, previousResults)

        let completedDeferredSearch = await waitUntil {
            model.state == .empty && model.results.isEmpty
        }
        XCTAssertTrue(completedDeferredSearch)
    }

    /// 同一主线程轮次中的快速切换只执行最后一个条件，避免中间筛选启动无效网络和布局更新。
    func testRapidFilterChangesAreCoalesced() async {
        let openverse = OpenverseCallCounter()
        let model = SearchModel(
            service: ImageSearchService(
                openverse: openverse,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.setActive(true)
        let loaded = await waitUntil { model.results.count == 20 }
        XCTAssertTrue(loaded)

        model.filter = .photos
        model.filter = .all
        model.filter = .avatars

        try? await Task.sleep(for: .milliseconds(100))
        let openverseCalls = await openverse.callCount()
        XCTAssertEqual(openverseCalls, 0)
        XCTAssertEqual(model.filter, .avatars)
        XCTAssertEqual(model.state, .results)
        XCTAssertEqual(model.results.count, 20)
    }

    /// 条件写入后立刻离开发现页也必须完成离线重置，返回时才能按新条件重新加载。
    func testDeferredCriteriaResetSurvivesTemporaryInactivity() async {
        let openverse = OpenverseCallCounter()
        let model = SearchModel(
            service: ImageSearchService(
                openverse: openverse,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.setActive(true)
        let loaded = await waitUntil { model.results.count == 20 }
        XCTAssertTrue(loaded)

        model.filter = .photos
        model.setActive(false)

        let resetWhileInactive = await waitUntil {
            model.state == .idle && model.results.isEmpty
        }
        XCTAssertTrue(resetWhileInactive)
        let callsWhileInactive = await openverse.callCount()
        XCTAssertEqual(callsWhileInactive, 0)

        model.setActive(true)
        let loadedNewCriteria = await waitUntil { model.state == .empty }
        XCTAssertTrue(loadedNewCriteria)
        let callsAfterResume = await openverse.callCount()
        XCTAssertEqual(callsAfterResume, 1)
    }

    /// 默认空查询直接生成头像，不应访问 Openverse 或共享图片推荐流。
    func testDefaultAvatarFilterLoadsDiceBearWithoutOpenverse() async {
        let openverse = OpenverseCallCounter()
        let model = SearchModel(
            service: ImageSearchService(
                openverse: openverse,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )

        model.setActive(true)

        let loaded = await waitUntil { model.results.count == 20 }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.filter, .avatars)
        XCTAssertTrue(model.results.allSatisfy { $0.source == .diceBear })
        let openverseCalls = await openverse.callCount()
        XCTAssertEqual(openverseCalls, 0)
    }

    /// 空搜索框首次进入应立即读取共享推荐，滚动续页后累计40张且搜索框保持为空。
    func testEmptyQueryLoadsSharedRecommendationsAndPaginates() async {
        let feed = SearchRecommendationFeed()
        let openverse = OpenverseCallCounter()
        let model = SearchModel(
            service: ImageSearchService(
                openverse: openverse,
                diceBear: DiceBearClient(styles: [.pixelArt])
            ),
            recommendationFeed: feed
        )
        model.filter = .all
        model.setActive(true)
        let loadedFirstPage = await waitUntil { model.results.count == 20 }
        XCTAssertTrue(loadedFirstPage)
        XCTAssertEqual(model.query, "")
        model.loadNextPage()
        let loadedSecondPage = await waitUntil { model.results.count == 40 }
        XCTAssertTrue(loadedSecondPage)
        let recommendationPages = await feed.pages()
        let openverseCalls = await openverse.callCount()
        XCTAssertEqual(recommendationPages, [1, 2])
        XCTAssertEqual(openverseCalls, 0)
    }

    /// 生产启动应等待共享仓库，重复注入不能清空已经滚动到 40 张的会话。
    func testRecommendationFeedConfigurationIsDeferredAndIdempotent() async {
        let firstFeed = SearchRecommendationFeed()
        let replacementFeed = SearchRecommendationFeed()
        let openverse = OpenverseCallCounter()
        let model = SearchModel(
            service: ImageSearchService(
                openverse: openverse,
                diceBear: DiceBearClient(styles: [.pixelArt])
            ),
            waitsForRecommendationFeed: true
        )

        model.filter = .all
        model.setActive(true)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.state, .idle)
        let callsBeforeConfiguration = await openverse.callCount()
        XCTAssertEqual(callsBeforeConfiguration, 0)

        model.configureRecommendationFeed(firstFeed)
        let loadedFirstPage = await waitUntil { model.results.count == 20 }
        XCTAssertTrue(loadedFirstPage)
        model.loadNextPage()
        let loadedSecondPage = await waitUntil { model.results.count == 40 }
        XCTAssertTrue(loadedSecondPage)

        model.configureRecommendationFeed(replacementFeed)
        try? await Task.sleep(for: .milliseconds(80))
        let firstPages = await firstFeed.pages()
        let replacementPages = await replacementFeed.pages()
        let finalOpenverseCalls = await openverse.callCount()
        XCTAssertEqual(model.results.count, 40)
        XCTAssertEqual(firstPages, [1, 2])
        XCTAssertEqual(replacementPages, [])
        XCTAssertEqual(finalOpenverseCalls, 0)
    }

    /// App Group 从失败恢复后必须用共享推荐替换普通网络兜底，避免与 Finder 展示不同代次。
    func testRecoveredRecommendationFeedReplacesExistingFallbackResults() async {
        let feed = SearchRecommendationFeed()
        let openverse = OpenverseCallCounter()
        let model = SearchModel(
            service: ImageSearchService(
                openverse: openverse,
                diceBear: DiceBearClient(styles: [.pixelArt])
            ),
            waitsForRecommendationFeed: true
        )
        model.filter = .all
        model.setActive(true)
        model.useRecommendationFallback()

        let loadedFallback = await waitUntil {
            model.results.count == 20 && model.results.allSatisfy { $0.source == .diceBear }
        }
        XCTAssertTrue(loadedFallback)

        model.configureRecommendationFeed(feed)
        let switchedToSharedFeed = await waitUntil {
            model.results.count == 20 && model.results.allSatisfy { $0.source == .openverse }
        }
        XCTAssertTrue(switchedToSharedFeed)
        let recommendationPages = await feed.pages()
        XCTAssertEqual(recommendationPages, [1])
    }

    /// 首屏网络失败必须同时更新视觉状态并发布辅助功能事件。
    func testInitialFailurePublishesAccessibilityEvent() async {
        let model = SearchModel(
            service: ImageSearchService(
                openverse: FailingOpenverse(),
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.filter = .photos
        model.query = "图片:cat"
        model.setActive(true)

        let failed = await waitUntil {
            if case .network = model.state { return true }
            return false
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(model.accessibilityEvent?.message.contains("网络不可用") == true)
    }

    /// 单个中文字符是完整关键词，防抖结束后必须进入搜索服务并显示结果。
    func testSingleChineseCharacterStartsSearch() async {
        let openverse = OpenverseCallCounter()
        let model = SearchModel(
            service: ImageSearchService(
                openverse: openverse,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )

        model.filter = .all
        model.query = "猫"
        model.setActive(true)

        let loaded = await waitUntil { model.state == .results }
        XCTAssertTrue(loaded)
        let callCount = await openverse.callCount()
        XCTAssertEqual(callCount, 1)
    }

    /// 只有查询前缀不能启动联网搜索；纯空白继续沿用空搜索框的推荐流语义。
    func testPrefixOnlyAndWhitespaceDoNotBecomeSearchQueries() async {
        let feed = SearchRecommendationFeed()
        let openverse = OpenverseCallCounter()
        let model = SearchModel(
            service: ImageSearchService(
                openverse: openverse,
                diceBear: DiceBearClient(styles: [.pixelArt])
            ),
            recommendationFeed: feed
        )

        model.filter = .all
        model.query = "图片:"
        model.setActive(true)
        XCTAssertEqual(model.state, .idle)
        try? await Task.sleep(for: .milliseconds(500))
        let prefixOnlyCalls = await openverse.callCount()
        XCTAssertEqual(prefixOnlyCalls, 0)

        model.query = "   "
        let loadedRecommendations = await waitUntil { model.results.count == 20 }
        XCTAssertTrue(loadedRecommendations)
        let recommendationPages = await feed.pages()
        let whitespaceCalls = await openverse.callCount()
        XCTAssertEqual(recommendationPages, [1])
        XCTAssertEqual(whitespaceCalls, 0)
    }

    /// 头像筛选首批和续页都应各追加20条，并且完全不访问 Openverse。
    func testAvatarFilterLoadsTwentyUniqueRecordsPerPage() async {
        let openverse = OpenverseCallCounter()
        let model = SearchModel(
            service: ImageSearchService(
                openverse: openverse,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.filter = .avatars
        model.query = "cat"
        model.setActive(true)
        let loadedFirstPage = await waitUntil { model.results.count == 20 }
        XCTAssertTrue(loadedFirstPage)
        model.loadNextPage()
        let loadedSecondPage = await waitUntil { model.results.count == 40 }
        XCTAssertTrue(loadedSecondPage)
        XCTAssertEqual(Set(model.results.map(\.id)).count, 40)
        XCTAssertEqual(model.paginationState, .ready)
        let callCount = await openverse.callCount()
        XCTAssertEqual(callCount, 0)
    }

    /// 失活时触底不能重启请求；恢复后必须再次触底才续页，不能在返回页面时偷跑。
    func testInactivePaginationRequiresAVisibleTriggerAfterResume() async {
        let openverse = BlockingSecondPageOpenverse()
        let model = SearchModel(
            service: ImageSearchService(
                openverse: openverse,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.filter = .photos
        model.query = "图片:cat"
        model.setActive(true)
        let loadedFirstPage = await waitUntil { model.results.count == 20 }
        XCTAssertTrue(loadedFirstPage)
        model.loadNextPage()
        let startedFirstPageTwoRequest = await openverse.waitForSecondPageCalls(1)
        XCTAssertTrue(startedFirstPageTwoRequest)

        model.setActive(false)
        model.loadNextPage()
        try? await Task.sleep(for: .milliseconds(80))
        let inactiveCalls = await openverse.secondPageCallCount()
        XCTAssertEqual(inactiveCalls, 1)

        model.setActive(true)
        model.setActive(true)
        try? await Task.sleep(for: .milliseconds(80))
        let callsBeforeVisibleTrigger = await openverse.secondPageCallCount()
        XCTAssertEqual(callsBeforeVisibleTrigger, 1)

        // 旧等待退出前即使再次触底也不能并发请求同一页。
        model.loadNextPage()
        try? await Task.sleep(for: .milliseconds(80))
        let overlappingCalls = await openverse.secondPageCallCount()
        XCTAssertEqual(overlappingCalls, 1)

        await openverse.releaseSecondPages()
        let cancellationSettled = await waitUntil { model.paginationState == .ready }
        XCTAssertTrue(cancellationSettled)

        model.loadNextPage()
        let startedResumedPageTwoRequest = await openverse.waitForSecondPageCalls(2)
        XCTAssertTrue(startedResumedPageTwoRequest)
        let resumedCalls = await openverse.secondPageCallCount()
        XCTAssertEqual(resumedCalls, 2)
        await openverse.releaseSecondPages()
        let loadedResumedPage = await waitUntil { model.results.count == 40 }
        XCTAssertTrue(loadedResumedPage)
        XCTAssertEqual(Set(model.results.map(\.id)).count, 40)
    }

    /// 最后一页新增内容只发布一个合并总数和结束状态的辅助功能事件。
    func testLastPagePublishesSingleCombinedAccessibilityEvent() async {
        let model = SearchModel(
            service: ImageSearchService(
                openverse: TwoPageOpenverse(),
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.filter = .photos
        model.query = "图片:cat"
        model.setActive(true)
        let loadedFirstPage = await waitUntil { model.results.count == 20 }
        XCTAssertTrue(loadedFirstPage)
        let firstEventID = model.accessibilityEvent?.id
        model.loadNextPage()
        let loadedLastPage = await waitUntil { model.results.count == 25 }
        XCTAssertTrue(loadedLastPage)
        XCTAssertEqual(model.paginationState, .exhausted)
        XCTAssertNotEqual(model.accessibilityEvent?.id, firstEventID)
        XCTAssertEqual(
            model.accessibilityEvent?.message,
            "已加载 5 张图片，共 25 张；已加载全部结果"
        )
    }

    /// 连续三张空页是正常扫描暂停而不是失败，显式继续后应从第四页接着查。
    func testEmptyPageBudgetUsesContinuationState() async {
        let openverse = EmptyPagedOpenverse()
        let model = SearchModel(
            service: ImageSearchService(
                openverse: openverse,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.filter = .photos
        model.query = "图片:cat"
        model.setActive(true)
        let reachedInitialContinuation = await waitUntil {
            if case .needsContinuation = model.paginationState { return true }
            return false
        }
        XCTAssertTrue(reachedInitialContinuation)
        let initialCalls = await openverse.callCount()
        XCTAssertEqual(initialCalls, 3)
        XCTAssertEqual(model.state, .empty)

        model.continueLoadingNextPage()
        let requestedSixPages = await openverse.waitForCalls(6)
        XCTAssertTrue(requestedSixPages)
        let reachedSecondContinuation = await waitUntil {
            if case .needsContinuation = model.paginationState { return true }
            return false
        }
        XCTAssertTrue(reachedSecondContinuation)
        let continuedCalls = await openverse.callCount()
        XCTAssertEqual(continuedCalls, 6)
    }

    /// 推荐冻结代次被淘汰后应自动重开第一页，并允许新代次继续分页。
    func testExpiredRecommendationSnapshotRestartsFromFirstPage() async {
        let feed = ExpiringRecommendationFeed()
        let model = SearchModel(recommendationFeed: feed)
        model.filter = .all
        model.setActive(true)

        let loadedFirstPage = await waitUntil { model.results.count == 20 }
        XCTAssertTrue(loadedFirstPage)
        model.loadNextPage()

        let restartedFirstPage = await feed.waitForCalls(3)
        XCTAssertTrue(restartedFirstPage)
        let reloaded = await waitUntil {
            model.results.count == 20 && model.paginationState == .ready
        }
        XCTAssertTrue(reloaded)
        let callsAfterRestart = await feed.requests()
        XCTAssertEqual(callsAfterRestart.map(\.page), [1, 2, 1])
        XCTAssertEqual(callsAfterRestart.map(\.generation), [nil, 42, nil])

        model.loadNextPage()
        let loadedNewGenerationPage = await waitUntil { model.results.count == 40 }
        XCTAssertTrue(loadedNewGenerationPage)
        let finalCalls = await feed.requests()
        XCTAssertEqual(finalCalls.last?.generation, 43)
        XCTAssertEqual(finalCalls.last?.page, 2)
    }

    /// 在限定时间内轮询主线程状态，使异步防抖与 actor 响应测试保持确定性。
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

private actor SearchRecommendationFeed: DiscoveryFeedProviding {
    private var requestedPages: [Int] = []

    /// 每页返回20条稳定记录，第一页同时把会话锁定到 generation 42。
    func page(generation: UInt64?, page: Int, pageSize: Int) async throws -> DiscoveryFeedPage {
        requestedPages.append(page)
        return DiscoveryFeedPage(
            generation: generation ?? 42,
            records: makeModelRecords(page: page, count: pageSize),
            nextPage: page + 1,
            didMutateSnapshot: true
        )
    }

    /// 返回推荐页调用序列，验证触底从共享 generation 继续。
    func pages() -> [Int] {
        requestedPages
    }
}

private actor ExpiringRecommendationFeed: DiscoveryFeedProviding {
    struct Request: Sendable {
        let generation: UInt64?
        let page: Int
    }

    private var recordedRequests: [Request] = []
    private var didExpire = false

    /// 旧代次第二页失效一次；重新读取第一页后切换到可继续分页的新代次。
    func page(generation: UInt64?, page: Int, pageSize: Int) async throws -> DiscoveryFeedPage {
        recordedRequests.append(Request(generation: generation, page: page))
        if generation == 42, page == 2, !didExpire {
            didExpire = true
            throw DiscoveryFeedError.snapshotExpired
        }
        return DiscoveryFeedPage(
            generation: generation ?? (didExpire ? 43 : 42),
            records: makeModelRecords(page: page, count: pageSize),
            nextPage: page + 1,
            didMutateSnapshot: true
        )
    }

    /// 等待自动刷新完成三次调用，避免依赖固定休眠判断会话是否重开。
    func waitForCalls(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if recordedRequests.count >= expected { return true }
            await Task.yield()
        }
        return recordedRequests.count >= expected
    }

    /// 返回请求快照，验证续页严格绑定新旧 generation。
    func requests() -> [Request] {
        recordedRequests
    }
}

private actor OpenverseCallCounter: OpenverseSearching {
    private var calls = 0

    /// 若头像筛选错误访问该数据源，记录调用并返回空末页。
    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        calls += 1
        return ImageSearchPage(records: [], nextPage: nil)
    }

    /// 返回调用次数快照。
    func callCount() -> Int {
        calls
    }
}

private actor FailingOpenverse: OpenverseSearching {
    /// 始终返回结构化网络错误，验证首屏错误播报。
    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        throw OpenverseError.network("离线测试")
    }
}

private actor BlockingSecondPageOpenverse: OpenverseSearching {
    private var pageTwoCalls = 0
    private var pageTwoContinuations: [CheckedContinuation<Void, Never>] = []

    /// 第一页立即返回；第二页挂起，供测试精确控制取消和恢复顺序。
    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        if page == 2 {
            pageTwoCalls += 1
            await withCheckedContinuation { continuation in
                pageTwoContinuations.append(continuation)
            }
        }
        return ImageSearchPage(
            records: makeModelRecords(page: page, count: pageSize),
            nextPage: page < 3 ? page + 1 : nil
        )
    }

    /// 等到指定数量的第二页请求真正进入挂起点。
    func waitForSecondPageCalls(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if pageTwoCalls >= expected { return true }
            await Task.yield()
        }
        return pageTwoCalls >= expected
    }

    /// 返回第二页调用次数快照。
    func secondPageCallCount() -> Int {
        pageTwoCalls
    }

    /// 同时释放旧取消任务和唯一恢复任务，验证只有当前 session 可以提交。
    func releaseSecondPages() {
        let continuations = pageTwoContinuations
        pageTwoContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor TwoPageOpenverse: OpenverseSearching {
    /// 第一页20条并继续，第二页5条后明确结束。
    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        if page == 1 {
            return ImageSearchPage(
                records: makeModelRecords(page: page, count: pageSize),
                nextPage: 2
            )
        }
        return ImageSearchPage(
            records: makeModelRecords(page: page, count: 5),
            nextPage: nil
        )
    }
}

private actor EmptyPagedOpenverse: OpenverseSearching {
    private var calls = 0

    /// 每页均为空但保持前进，用于验证三页扫描预算和续页游标。
    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        calls += 1
        return ImageSearchPage(records: [], nextPage: page + 1)
    }

    /// 返回累计调用次数。
    func callCount() -> Int {
        calls
    }

    /// 等待累计调用达到目标，避免依赖固定休眠猜测任务完成时间。
    func waitForCalls(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if calls >= expected { return true }
            await Task.yield()
        }
        return calls >= expected
    }
}

/// 为 SearchModel 测试构造每页稳定且互不重复的图片记录。
private func makeModelRecords(page: Int, count: Int) -> [RemoteImageRecord] {
    (0..<count).map { index in
        let url = URL(string: "https://example.com/model-\(page)-\(index).png")!
        return RemoteImageRecord(
            id: "model-\(page)-\(index)",
            title: "Model \(page)-\(index)",
            source: .openverse,
            imageURL: url,
            thumbnailURL: url,
            license: .cc0
        )
    }
}
