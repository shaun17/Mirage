import Foundation
import MirageCore
import XCTest

@MainActor
final class SearchModelTests: XCTestCase {
    /// 内容类型按产品入口优先级展示，头像应默认出现在最左侧。
    func testContentFiltersPresentAvatarsPhotosAllThenGIF() {
        XCTAssertEqual(SearchFilter.allCases, [.avatars, .photos, .all, .gif])
        XCTAssertEqual(SearchFilter.gif.title, "GIF")
        XCTAssertEqual(SearchFilter.gif.rawValue, "emoji")
    }

    /// 进入或离开 GIPHY 会话时应关闭详情抽屉，普通图片筛选之间切换则保留当前详情。
    func testOnlyGIFBoundaryRequiresDetailDrawerDismissal() {
        XCTAssertTrue(SearchFilter.photos.crossesGIFBoundary(to: .gif))
        XCTAssertTrue(SearchFilter.gif.crossesGIFBoundary(to: .all))
        XCTAssertFalse(SearchFilter.avatars.crossesGIFBoundary(to: .photos))
        XCTAssertFalse(SearchFilter.gif.crossesGIFBoundary(to: .gif))
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

    /// GIF 筛选只读取 GIPHY 混合目录，使用“个 GIF”播报，并在失活时丢弃瞬时记录。
    func testGIFFilterPaginatesWithGiphySemanticsAndClearsWhenInactive() async {
        let giphy = SearchModelGiphySource()
        let openverse = OpenverseCallCounter()
        let model = SearchModel(
            service: ImageSearchService(
                openverse: openverse,
                giphy: giphy,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.filter = .gif
        model.setActive(true)

        let loadedFirstPage = await waitUntil { model.results.map(\.id) == ["giphy-first"] }
        XCTAssertTrue(loadedFirstPage)
        XCTAssertEqual(model.accessibilityEvent?.message, "已加载 1 个 GIF，共 1 个 GIF")
        model.loadNextPage()

        let loadedLastPage = await waitUntil {
            model.results.map(\.id) == ["giphy-first", "giphy-second"]
        }
        XCTAssertTrue(loadedLastPage)
        XCTAssertEqual(model.paginationState, .exhausted)
        XCTAssertEqual(model.accessibilityEvent?.message, "已加载 1 个 GIF，共 2 个 GIF；已加载全部 GIF")
        let giphyCursors = await giphy.recordedCursors()
        let openverseCalls = await openverse.callCount()
        XCTAssertEqual(giphyCursors, [nil, "40"])
        XCTAssertEqual(openverseCalls, 0)

        model.setActive(false)
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.paginationState, .unavailable)
    }

    /// 非调用方触发的 CancellationError 必须成为可见失败，不能把 GIF 页永久留在搜索态。
    func testUnexpectedGiphyCancellationSettlesAsNetworkFailure() async {
        let model = SearchModel(
            service: ImageSearchService(
                giphy: UnexpectedCancelledGiphySource(),
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.filter = .gif
        model.setActive(true)

        let settled = await waitUntil {
            model.state == .network("GIPHY 请求被中断，请重试。")
        }

        XCTAssertTrue(settled)
        XCTAssertEqual(model.accessibilityEvent?.message, "网络不可用：GIPHY 请求被中断，请重试。")
    }

    /// 三路中只有部分端点限流时保留已到达结果，但暂停自动续页且在 retryAt 前不重复请求。
    func testPartialGiphyRateLimitPausesPaginationUntilRetryBoundary() async {
        let giphy = PartiallyRateLimitedGiphySource(
            retryAt: Date().addingTimeInterval(60)
        )
        let model = SearchModel(
            service: ImageSearchService(
                giphy: giphy,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.filter = .gif
        model.setActive(true)

        let loaded = await waitUntil {
            model.results.map(\.id) == ["giphy-partial"]
                && model.paginationState == .failed(
                    "部分 GIPHY 内容受到限流，请稍后重试加载更多 GIF。"
                )
        }
        XCTAssertTrue(loaded)
        let initialCallCount = await giphy.callCount()
        XCTAssertEqual(initialCallCount, 1)

        model.loadNextPage()
        model.retryLoadingNextPage()
        await Task.yield()

        let finalCallCount = await giphy.callCount()
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(
            model.accessibilityEvent?.message,
            "GIPHY 限流尚未结束，请稍后重试加载更多 GIF。"
        )
    }

    /// 首屏整目录限流后，所有界面重试都必须在 retryAt 前被请求边界拦截。
    func testInitialGiphyRateLimitBlocksImmediateRetry() async {
        let retryAt = Date().addingTimeInterval(60)
        let giphy = InitiallyRateLimitedGiphySource(retryAt: retryAt)
        let model = SearchModel(
            service: ImageSearchService(
                giphy: giphy,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.filter = .gif
        model.setActive(true)

        let limited = await waitUntil {
            model.state == .rateLimited("GIPHY 请求过于频繁，请稍后重试。")
        }
        XCTAssertTrue(limited)
        let initialCallCount = await giphy.callCount()
        XCTAssertEqual(initialCallCount, 1)

        model.sourceConfigurationDidChange(sourceID: .nasa)
        model.retrySearch()
        await Task.yield()

        let finalCallCount = await giphy.callCount()
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(model.state, .rateLimited("GIPHY 请求过于频繁，请稍后重试。"))

        model.sourceConfigurationDidChange(sourceID: .giphy)
        let retriedAfterGiphyConfigurationChange = await giphy.waitForCalls(2)
        XCTAssertTrue(retriedAfterGiphyConfigurationChange)
    }

    /// 首屏成功但续页整目录限流时，retryAt 前点击续页重试也不能再次访问 GIPHY。
    func testNextGiphyPageRateLimitBlocksImmediatePaginationRetry() async {
        let giphy = NextPageRateLimitedGiphySource(
            retryAt: Date().addingTimeInterval(60)
        )
        let model = SearchModel(
            service: ImageSearchService(
                giphy: giphy,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.filter = .gif
        model.setActive(true)

        let loaded = await waitUntil { model.results.map(\.id) == ["giphy-first"] }
        XCTAssertTrue(loaded)
        model.loadNextPage()
        let limited = await waitUntil {
            if case .failed = model.paginationState { return true }
            return false
        }
        XCTAssertTrue(limited)
        let callsAfterRateLimit = await giphy.callCount()
        XCTAssertEqual(callsAfterRateLimit, 2)

        model.retryLoadingNextPage()
        await Task.yield()

        let callsAfterRetry = await giphy.callCount()
        XCTAssertEqual(callsAfterRetry, 2)
        XCTAssertEqual(
            model.accessibilityEvent?.message,
            "GIPHY 限流尚未结束，请稍后重试加载更多 GIF。"
        )
    }

    /// 部分子流限流后即使窗口失活并重建搜索会话，retryAt 前仍不能重新访问 GIPHY。
    func testPartialGiphyRateLimitSurvivesInactiveSessionReset() async {
        let giphy = PartiallyRateLimitedGiphySource(
            retryAt: Date().addingTimeInterval(60)
        )
        let model = SearchModel(
            service: ImageSearchService(
                giphy: giphy,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.filter = .gif
        model.setActive(true)

        let loaded = await waitUntil { model.results.map(\.id) == ["giphy-partial"] }
        XCTAssertTrue(loaded)
        let callsBeforeInactive = await giphy.callCount()
        XCTAssertEqual(callsBeforeInactive, 1)

        model.setActive(false)
        model.setActive(true)

        let limited = await waitUntil {
            model.state == .rateLimited("GIPHY 请求过于频繁，请稍后重试。")
        }
        XCTAssertTrue(limited)
        let callsAfterResume = await giphy.callCount()
        XCTAssertEqual(callsAfterResume, 1)
    }

    /// 普通图片来源的局部限流由其请求协调器处理，不能误用 GIPHY 文案或阻断分页重试。
    func testPhotoRateIssueDoesNotActivateGiphyPaginationGate() async {
        let photos = OrdinaryRateIssuePhotoSearcher(
            retryAt: Date().addingTimeInterval(60)
        )
        let model = SearchModel(
            service: ImageSearchService(
                photos: photos,
                diceBear: DiceBearClient(styles: [.pixelArt])
            )
        )
        model.filter = .photos
        model.setActive(true)

        let loaded = await waitUntil {
            model.results.map(\.id) == ["ordinary-photo"]
                && model.paginationState == .ready
        }
        XCTAssertTrue(loaded)
        model.loadNextPage()
        let failed = await waitUntil {
            if case .failed = model.paginationState { return true }
            return false
        }
        XCTAssertTrue(failed)

        model.retryLoadingNextPage()
        let retried = await photos.waitForCalls(3)

        XCTAssertTrue(retried)
        XCTAssertFalse(model.accessibilityEvent?.message.contains("GIPHY") == true)
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

    /// 聚合搜索局部失败仍显示可用结果，并把来源故障并入同一次 VoiceOver 公告。
    func testPartialSourceFailurePublishesAccessibilityEvent() async {
        let model = SearchModel(
            service: ImageSearchService(photos: PartialIssuePhotoSearcher())
        )
        model.filter = .photos
        model.query = "图片:cat"
        model.setActive(true)

        let loaded = await waitUntil { model.results.count == 2 }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.sourceIssues.map(\.sourceID), [.pexels])
        XCTAssertEqual(
            model.accessibilityEvent?.message,
            "已加载 2 张图片，共 2 张；已加载全部图片；部分数据源不可用：Pexels 测试不可用"
        )
    }

    /// 首个来源完成后立即显示，完整页到达时只补齐缺失记录，不能把已出现的卡片重新排序。
    func testInitialSearchDisplaysCompletedSourceBeforeFullPageFinishes() async {
        let photos = ControlledProgressivePhotoSearcher()
        let model = SearchModel(service: ImageSearchService(photos: photos))
        model.filter = .photos
        model.query = "图片:星云"
        model.setActive(true)

        let started = await photos.waitUntilStarted()
        XCTAssertTrue(started)
        let displayedFastSource = await waitUntil {
            model.results.map(\.id) == ["nasa-fast"]
                && model.state == .results
                && model.paginationState == .loadingSources
        }
        XCTAssertTrue(displayedFastSource)
        XCTAssertEqual(model.accessibilityEvent?.message, "已先加载 1 张图片，其他图片数据源仍在加载")

        await photos.releaseSlowSource()
        let completed = await waitUntil {
            model.results.map(\.id) == ["nasa-fast", "openverse-slow"]
                && model.paginationState == .exhausted
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(model.accessibilityEvent?.message, "已加载 2 张图片，共 2 张；已加载全部图片")
    }

    /// 已取消查询即使在新查询完成后迟到发布批次，也不能污染当前会话。
    func testCancelledSearchRejectsLateSourceBatch() async {
        let photos = LateProgressPhotoSearcher()
        let model = SearchModel(service: ImageSearchService(photos: photos))
        model.filter = .photos
        model.query = "old"
        model.setActive(true)
        let oldSearchStarted = await photos.waitUntilOldSearchStarted()
        XCTAssertTrue(oldSearchStarted)

        model.query = "new"
        let loadedNewQuery = await waitUntil {
            model.results.map(\.id) == ["new-result"] && model.paginationState == .exhausted
        }
        XCTAssertTrue(loadedNewQuery)

        await photos.releaseOldSearch()
        let oldSearchCompleted = await photos.waitUntilOldSearchCompleted()
        XCTAssertTrue(oldSearchCompleted)
        await Task.yield()
        XCTAssertEqual(model.results.map(\.id), ["new-result"])
    }

    /// 首屏仍在等待其他来源时失活，应清掉临时结果且禁止触底续页。
    func testInactiveProgressiveSearchClearsPartialResultsAndCannotLoadMore() async {
        let photos = ControlledProgressivePhotoSearcher()
        let model = SearchModel(service: ImageSearchService(photos: photos))
        model.filter = .photos
        model.query = "星云"
        model.setActive(true)
        let started = await photos.waitUntilStarted()
        XCTAssertTrue(started)
        let displayedPartial = await waitUntil {
            model.results.map(\.id) == ["nasa-fast"]
                && model.paginationState == .loadingSources
        }
        XCTAssertTrue(displayedPartial)

        model.loadNextPage()
        XCTAssertEqual(model.paginationState, .loadingSources)
        model.setActive(false)
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.paginationState, .unavailable)

        await photos.releaseSlowSource()
        await Task.yield()
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.state, .idle)
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
        let loadedFirstPage = await waitUntil {
            model.results.count == 20 && model.paginationState == .ready
        }
        XCTAssertTrue(loadedFirstPage)
        let firstEventID = model.accessibilityEvent?.id
        model.loadNextPage()
        let loadedLastPage = await waitUntil { model.results.count == 25 }
        XCTAssertTrue(loadedLastPage)
        XCTAssertEqual(model.paginationState, .exhausted)
        XCTAssertNotEqual(model.accessibilityEvent?.id, firstEventID)
        XCTAssertEqual(
            model.accessibilityEvent?.message,
            "已加载 5 张图片，共 25 张；已加载全部图片"
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

    /// 聚合错误按可操作性选择状态，不能让排在前面的凭据问题遮住限流或网络故障。
    func testAggregatedFailurePrioritizesRateLimitThenNetwork() {
        let credential = PhotoSourceIssue(
            sourceID: .pexels,
            kind: .missingCredential,
            message: "missing"
        )
        let network = PhotoSourceIssue(
            sourceID: .openverse,
            kind: .network,
            message: "network"
        )
        let rateLimit = PhotoSourceIssue(
            sourceID: .pexels,
            kind: .rateLimited,
            message: "limited"
        )

        XCTAssertEqual(
            SearchState(photoSearchError: .allSourcesFailed([credential, network])),
            .network("network")
        )
        XCTAssertEqual(
            SearchState(photoSearchError: .allSourcesFailed([credential, network, rateLimit])),
            .rateLimited("limited")
        )
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

private actor SearchModelGiphySource: PhotoSourceSearching {
    let sourceID = PhotoSourceID.giphy
    private var cursors: [String?] = []

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        cursors.append(cursor?.rawValue)
        XCTAssertEqual(query, "")
        XCTAssertEqual(pageSize, SearchPaginationCursor.maximumPageSize)
        if cursor == nil {
            return PhotoSourcePage(
                records: [Self.record(id: "giphy-first")],
                nextCursor: PhotoSourceCursor(rawValue: "40")
            )
        }
        return PhotoSourcePage(records: [Self.record(id: "giphy-second")], nextCursor: nil)
    }

    func recordedCursors() -> [String?] {
        cursors
    }

    private static func record(id: String) -> RemoteImageRecord {
        RemoteImageRecord(
            id: id,
            title: id,
            source: .giphy,
            imageURL: URL(string: "https://media1.giphy.com/media/\(id)/giphy.gif")!,
            thumbnailURL: URL(string: "https://media1.giphy.com/media/\(id)/200w.gif")!,
            license: .giphy
        )
    }
}

private actor PartiallyRateLimitedGiphySource: PhotoSourceSearching {
    let sourceID = PhotoSourceID.giphy
    private let retryAt: Date
    private var calls = 0

    init(retryAt: Date) {
        self.retryAt = retryAt
    }

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        calls += 1
        return PhotoSourcePage(
            records: [RemoteImageRecord(
                id: "giphy-partial",
                title: "GIPHY Partial",
                source: .giphy,
                imageURL: URL(string: "https://media1.giphy.com/media/partial/giphy.gif")!,
                thumbnailURL: URL(string: "https://media1.giphy.com/media/partial/200w.gif")!,
                license: .giphy
            )],
            nextCursor: PhotoSourceCursor(rawValue: "40"),
            issues: [PhotoSourceIssue(
                sourceID: .giphy,
                kind: .rateLimited,
                message: "GIPHY Sticker 子流暂时不可用。",
                retryAt: retryAt
            )]
        )
    }

    func callCount() -> Int {
        calls
    }
}

private actor NextPageRateLimitedGiphySource: PhotoSourceSearching {
    let sourceID = PhotoSourceID.giphy
    private let retryAt: Date
    private var calls = 0

    init(retryAt: Date) {
        self.retryAt = retryAt
    }

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        calls += 1
        guard cursor != nil else {
            return PhotoSourcePage(
                records: [RemoteImageRecord(
                    id: "giphy-first",
                    title: "GIPHY First",
                    source: .giphy,
                    imageURL: URL(string: "https://media1.giphy.com/media/first/giphy.gif")!,
                    thumbnailURL: URL(string: "https://media1.giphy.com/media/first/200w.gif")!,
                    license: .giphy
                )],
                nextCursor: PhotoSourceCursor(rawValue: "40")
            )
        }
        throw PhotoSearchError.allSourcesFailed([
            PhotoSourceIssue(
                sourceID: .giphy,
                kind: .rateLimited,
                message: "GIPHY 请求过于频繁，请稍后重试。",
                retryAt: retryAt
            )
        ])
    }

    func callCount() -> Int {
        calls
    }
}

private actor InitiallyRateLimitedGiphySource: PhotoSourceSearching {
    let sourceID = PhotoSourceID.giphy
    private let retryAt: Date
    private var calls = 0

    init(retryAt: Date) {
        self.retryAt = retryAt
    }

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        calls += 1
        throw PhotoSearchError.allSourcesFailed([
            PhotoSourceIssue(
                sourceID: .giphy,
                kind: .rateLimited,
                message: "GIPHY 请求过于频繁，请稍后重试。",
                retryAt: retryAt
            )
        ])
    }

    func callCount() -> Int {
        calls
    }

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

private struct UnexpectedCancelledGiphySource: PhotoSourceSearching {
    let sourceID = PhotoSourceID.giphy

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        throw CancellationError()
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

private struct PartialIssuePhotoSearcher: PhotoSearching {
    func search(query: String, cursor: PhotoSearchCursor?, pageSize: Int) async throws -> PhotoSearchPage {
        PhotoSearchPage(
            records: makeModelRecords(page: 1, count: 2),
            nextCursor: nil,
            issues: [
                PhotoSourceIssue(
                    sourceID: .pexels,
                    kind: .unavailable,
                    message: "Pexels 测试不可用"
                )
            ]
        )
    }

    func search(query: String, page: Int, pageSize: Int) async throws -> PhotoSearchPage {
        try await search(query: query, cursor: nil, pageSize: pageSize)
    }

    func configurationKey() async -> String { "partial-issue" }
}

private actor OrdinaryRateIssuePhotoSearcher: PhotoSearching {
    private let retryAt: Date
    private var calls = 0

    init(retryAt: Date) {
        self.retryAt = retryAt
    }

    func search(
        query: String,
        cursor: PhotoSearchCursor?,
        pageSize: Int
    ) async throws -> PhotoSearchPage {
        calls += 1
        guard cursor == nil else {
            throw PhotoSearchError.allSourcesFailed([
                PhotoSourceIssue(
                    sourceID: .pexels,
                    kind: .unavailable,
                    message: "Pexels 分页暂时不可用"
                )
            ])
        }
        return PhotoSearchPage(
            records: [RemoteImageRecord(
                id: "ordinary-photo",
                title: "Ordinary Photo",
                source: .openverse,
                imageURL: URL(string: "https://images.example/photo.jpg")!,
                thumbnailURL: URL(string: "https://images.example/thumb.jpg")!,
                license: .cc0
            )],
            nextCursor: PhotoSearchCursor(
                configurationRevision: 1,
                states: [PhotoSourceCursorState(
                    sourceID: .pexels,
                    cursor: PhotoSourceCursor(rawValue: "2"),
                    pageSize: pageSize,
                    exhausted: false
                )]
            ),
            issues: [PhotoSourceIssue(
                sourceID: .pexels,
                kind: .rateLimited,
                message: "Pexels 请求过于频繁",
                retryAt: retryAt
            )]
        )
    }

    func search(query: String, page: Int, pageSize: Int) async throws -> PhotoSearchPage {
        try await search(query: query, cursor: nil, pageSize: pageSize)
    }

    func configurationKey() async -> String { "ordinary-rate-issue" }

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

private actor ControlledProgressivePhotoSearcher: PhotoSearching {
    private var started = false
    private var slowSourceWaiter: CheckedContinuation<Void, Never>?
    private var shouldReleaseSlowSource = false

    func search(query: String, cursor: PhotoSearchCursor?, pageSize: Int) async throws -> PhotoSearchPage {
        PhotoSearchPage(records: [Self.slowRecord, Self.fastRecord], nextCursor: nil)
    }

    /// 先发布 NASA，再等待测试显式释放 Openverse，模拟真实来源完成顺序。
    func search(
        query: String,
        cursor: PhotoSearchCursor?,
        pageSize: Int,
        onBatch: @escaping PhotoSearchBatchHandler
    ) async throws -> PhotoSearchPage {
        started = true

        await onBatch(PhotoSearchBatch(sourceID: .nasa, records: [Self.fastRecord]))
        await withCheckedContinuation { continuation in
            if shouldReleaseSlowSource {
                continuation.resume()
            } else {
                slowSourceWaiter = continuation
            }
        }
        try Task.checkCancellation()
        await onBatch(PhotoSearchBatch(sourceID: .openverse, records: [Self.slowRecord]))
        return PhotoSearchPage(records: [Self.slowRecord, Self.fastRecord], nextCursor: nil)
    }

    func search(query: String, page: Int, pageSize: Int) async throws -> PhotoSearchPage {
        try await search(query: query, cursor: nil, pageSize: pageSize)
    }

    func configurationKey() async -> String { "controlled-progressive" }

    func waitUntilStarted() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if started { return true }
            await Task.yield()
        }
        return started
    }

    func releaseSlowSource() {
        shouldReleaseSlowSource = true
        slowSourceWaiter?.resume()
        slowSourceWaiter = nil
    }

    private static let fastRecord = RemoteImageRecord(
        id: "nasa-fast",
        title: "NASA Fast",
        source: .nasa,
        imageURL: URL(string: "https://example.com/nasa-fast.jpg")!,
        thumbnailURL: URL(string: "https://example.com/nasa-fast-thumb.jpg")!,
        license: .nasaMediaUsage
    )

    private static let slowRecord = RemoteImageRecord(
        id: "openverse-slow",
        title: "Openverse Slow",
        source: .openverse,
        imageURL: URL(string: "https://example.com/openverse-slow.jpg")!,
        thumbnailURL: URL(string: "https://example.com/openverse-slow-thumb.jpg")!,
        license: .cc0
    )
}

private actor LateProgressPhotoSearcher: PhotoSearching {
    private var oldSearchStarted = false
    private var oldSearchCompleted = false
    private var oldSearchWaiter: CheckedContinuation<Void, Never>?
    private var shouldReleaseOldSearch = false

    func search(query: String, cursor: PhotoSearchCursor?, pageSize: Int) async throws -> PhotoSearchPage {
        PhotoSearchPage(records: [Self.newRecord], nextCursor: nil)
    }

    func search(
        query: String,
        cursor: PhotoSearchCursor?,
        pageSize: Int,
        onBatch: @escaping PhotoSearchBatchHandler
    ) async throws -> PhotoSearchPage {
        guard query == "old" else {
            return PhotoSearchPage(records: [Self.newRecord], nextCursor: nil)
        }
        oldSearchStarted = true
        await withCheckedContinuation { continuation in
            if shouldReleaseOldSearch {
                continuation.resume()
            } else {
                oldSearchWaiter = continuation
            }
        }
        // 故意忽略取消并发布迟到批次，验证 SearchModel 的 session 隔离边界。
        await onBatch(PhotoSearchBatch(sourceID: .nasa, records: [Self.oldRecord]))
        oldSearchCompleted = true
        return PhotoSearchPage(records: [Self.oldRecord], nextCursor: nil)
    }

    func search(query: String, page: Int, pageSize: Int) async throws -> PhotoSearchPage {
        try await search(query: query, cursor: nil, pageSize: pageSize)
    }

    func configurationKey() async -> String { "late-progress" }

    func waitUntilOldSearchStarted() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if oldSearchStarted { return true }
            await Task.yield()
        }
        return oldSearchStarted
    }

    func waitUntilOldSearchCompleted() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if oldSearchCompleted { return true }
            await Task.yield()
        }
        return oldSearchCompleted
    }

    func releaseOldSearch() {
        shouldReleaseOldSearch = true
        oldSearchWaiter?.resume()
        oldSearchWaiter = nil
    }

    private static let oldRecord = RemoteImageRecord(
        id: "old-result",
        title: "Old",
        source: .nasa,
        imageURL: URL(string: "https://example.com/old.jpg")!,
        thumbnailURL: URL(string: "https://example.com/old-thumb.jpg")!,
        license: .nasaMediaUsage
    )

    private static let newRecord = RemoteImageRecord(
        id: "new-result",
        title: "New",
        source: .openverse,
        imageURL: URL(string: "https://example.com/new.jpg")!,
        thumbnailURL: URL(string: "https://example.com/new-thumb.jpg")!,
        license: .cc0
    )
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
