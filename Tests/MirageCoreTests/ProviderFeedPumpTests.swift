import FileProvider
import XCTest

/// 推荐流增量泵的水位、保底、单飞、上限与退避语义；这些规则决定 Finder 里“滚动加载”的手感与联网量。
final class ProviderFeedPumpTests: XCTestCase {
    /// 可见项停在列表头部属于正常浏览，不该补页。
    func testDoesNotAdvanceWhenVisibleItemsAreFarFromTail() async throws {
        let advancer = FakeFeedAdvancer(count: 40)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)
        await pump.noteEnumerated(publishedCount: 40)

        await pump.noteVisible(Self.identifiers(0..<10))
        await pump.waitForPendingAdvance()

        let count = await advancer.advanceCount
        XCTAssertEqual(count, 0)
    }

    /// 可见项进入尾部水位即补一页，并把增量发布给系统。
    func testAdvancesOnceWhenVisibleItemsReachWatermark() async throws {
        let advancer = FakeFeedAdvancer(count: 40)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)
        await pump.noteEnumerated(publishedCount: 40)

        await pump.noteVisible(Self.identifiers(36..<40))
        await pump.waitForPendingAdvance()

        let advanceCount = await advancer.advanceCount
        let publishCount = await advancer.publishCount
        XCTAssertEqual(advanceCount, 1)
        XCTAssertEqual(publishCount, 1)
    }

    /// 补页后列表变长，同一批可见项不再处于水位内，一次滚动不会连锁拉空远端。
    func testAdvanceMovesWatermarkSoSameVisibilityStopsAdvancing() async throws {
        let advancer = FakeFeedAdvancer(count: 40)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)
        await syncReplica(pump, advancer)

        // 副本没有跟着变长时，重复的同批可见项只会促成一次补页。
        for _ in 0..<5 {
            await pump.noteVisible(Self.identifiers(36..<40))
            await pump.waitForPendingAdvance()
        }

        let count = await advancer.advanceCount
        XCTAssertEqual(count, 1)
    }

    /// 继续滚到新的尾部才继续补页。
    func testAdvancesAgainWhenVisibilityReachesTheNewTail() async throws {
        let advancer = FakeFeedAdvancer(count: 40)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)
        await syncReplica(pump, advancer)

        await pump.noteVisible(Self.identifiers(36..<40))
        await pump.waitForPendingAdvance()
        // 新一页要先真正上屏，用户才可能滚到它的尾部。
        await syncReplica(pump, advancer)
        await pump.noteVisible(Self.identifiers(56..<60))
        await pump.waitForPendingAdvance()

        let count = await advancer.advanceCount
        XCTAssertEqual(count, 2)
    }

    /// 远端已无更多内容时停止补页，避免对空结果反复发请求。
    func testDoesNotAdvanceWhenFeedIsExhausted() async throws {
        let advancer = FakeFeedAdvancer(count: 40, hasMore: false)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)
        await pump.noteEnumerated(publishedCount: 40)

        await pump.noteVisible(Self.identifiers(36..<40))
        await pump.waitForPendingAdvance()

        let count = await advancer.advanceCount
        XCTAssertEqual(count, 0)
    }

    /// 未知标识（其他视图或已过期条目）不参与水位计算，不会伪造出尾部可见。
    func testUnknownIdentifiersDoNotTriggerAdvance() async throws {
        let advancer = FakeFeedAdvancer(count: 40)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)
        await pump.noteEnumerated(publishedCount: 40)

        await pump.noteVisible([
            NSFileProviderItemIdentifier("favorite:whatever"),
            NSFileProviderItemIdentifier("search:whatever")
        ])
        await pump.waitForPendingAdvance()

        let count = await advancer.advanceCount
        XCTAssertEqual(count, 0)
    }

    /// 时间窗口内有页数硬上限，异常的批量缩略图请求不会把整个远端拉下来。
    func testStopsAfterWindowPageLimit() async throws {
        let advancer = FakeFeedAdvancer(count: 40)
        var limits = ProviderFeedPump.Limits.test
        limits.maximumPagesPerWindow = 2
        let pump = ProviderFeedPump(advancer: advancer, limits: limits)

        for step in 0..<5 {
            await syncReplica(pump, advancer)
            let tail = 40 + step * 20
            await pump.noteVisible(Self.identifiers((tail - 4)..<tail))
            await pump.waitForPendingAdvance()
        }

        let count = await advancer.advanceCount
        XCTAssertEqual(count, 2)
    }

    /// 页数预算是时间窗口而不是枚举器会话：每次补页引发的系统重新枚举都会建新枚举器，
    /// 若 arm 重置预算，重扫循环就没有刹车；预算只随窗口过期恢复。
    func testPageBudgetIsTimeWindowedNotResetByRearm() async throws {
        let advancer = FakeFeedAdvancer(count: 40)
        let clock = TestClock(start: Date(timeIntervalSince1970: 5_000))
        var limits = ProviderFeedPump.Limits.test
        limits.maximumPagesPerWindow = 1
        limits.pageWindowSeconds = 600
        let pump = ProviderFeedPump(advancer: advancer, limits: limits, now: { clock.now })
        await syncReplica(pump, advancer)

        await pump.noteVisible(Self.identifiers(36..<40))
        await pump.waitForPendingAdvance()

        // 系统因内容变化重建枚举器；这不是新的浏览意图，预算不得恢复。
        await pump.arm()
        await syncReplica(pump, advancer)
        await pump.noteVisible(Self.identifiers(56..<60))
        await pump.waitForPendingAdvance()

        let duringWindow = await advancer.advanceCount
        XCTAssertEqual(duringWindow, 1, "枚举器重建不能重置页数预算")

        clock.advance(by: 601)
        await pump.noteVisible(Self.identifiers(56..<60))
        await pump.waitForPendingAdvance()

        let afterWindow = await advancer.advanceCount
        XCTAssertEqual(afterWindow, 2, "窗口过期后预算恢复，正常浏览可以继续")
    }

    /// 补页失败后进入退避窗口，窗口内的可见事件一律不再联网。
    func testBacksOffAfterFailure() async throws {
        let advancer = FakeFeedAdvancer(count: 40)
        await advancer.setFailsNextAdvance(true)
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        let pump = ProviderFeedPump(
            advancer: advancer,
            limits: .test,
            now: { clock.now }
        )
        await pump.noteEnumerated(publishedCount: 40)

        await pump.noteVisible(Self.identifiers(36..<40))
        await pump.waitForPendingAdvance()
        await pump.noteVisible(Self.identifiers(36..<40))
        await pump.waitForPendingAdvance()

        let duringBackoff = await advancer.advanceCount
        XCTAssertEqual(duringBackoff, 1)

        clock.advance(by: ProviderFeedPump.Limits.test.backoffSeconds + 1)
        await pump.noteVisible(Self.identifiers(36..<40))
        await pump.waitForPendingAdvance()

        let afterBackoff = await advancer.advanceCount
        XCTAssertEqual(afterBackoff, 2)
    }

    /// 失效后取消在途补页，用户关闭窗口就不该再有后台流量。
    func testDisarmCancelsPendingAdvance() async throws {
        let advancer = FakeFeedAdvancer(count: 40)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)
        await pump.noteEnumerated(publishedCount: 40)

        await pump.noteVisible(Self.identifiers(36..<40))
        await pump.disarm()
        await pump.waitForPendingAdvance()

        let publishCount = await advancer.publishCount
        XCTAssertEqual(publishCount, 0)
    }

    /// 回归：存储已经领先副本时，滚到副本底部必须先请求重扫，而不是继续抓更多。
    /// 线上就是栽在这里——存储 60 条、Finder 只显示 20 张，水位拿存储长度当分母，
    /// 于是 `19 >= 60 - 8` 恒为假，滚到底永远不会有反应。
    func testStoreAheadOfReplicaPublishesInsteadOfFetchingMore() async throws {
        let advancer = FakeFeedAdvancer(count: 60)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)
        // 副本只发布了 20 张，存储却已有 60 条。
        await pump.noteEnumerated(publishedCount: 20)

        // 用户滚到了副本的底部。
        await pump.noteVisible(Self.identifiers(16..<20))
        await pump.waitForPendingAdvance()

        let advanceCount = await advancer.advanceCount
        let publishCount = await advancer.publishCount
        XCTAssertEqual(advanceCount, 0, "存储已经领先，不该再抓")
        XCTAssertGreaterThanOrEqual(publishCount, 1, "必须请求把已有内容推上屏")
    }

    /// 模拟系统完成一次重新枚举：副本追上存储长度。
    /// 真实链路里这一步由 `reimportItems` 触发的枚举完成，泵无法自己制造它。
    fileprivate func syncReplica(_ pump: ProviderFeedPump, _ advancer: FakeFeedAdvancer) async {
        await pump.noteEnumerated(publishedCount: await advancer.currentCount)
    }

    /// 构造与已发布顺序一致的稳定标识。
    fileprivate static func identifiers(_ range: Range<Int>) -> [NSFileProviderItemIdentifier] {
        range.map { NSFileProviderItemIdentifier(FakeFeedAdvancer.identifier(at: $0)) }
    }
}

/// 首屏保底填充：系统会缓存缩略图，重开目录时一个请求都不发；
/// 而且目录内容进入系统副本后 `enumerateItems` 也不会再被调用。
/// 只靠滚动信号，20 张的目录没有“未缓存的新项”可滚，会永远停在首页。
extension ProviderFeedPumpTests {
    /// 低于保底线时，一次枚举通知就足以启动填充——不需要任何可见项。
    func testEnumerationFillsUpToMinimum() async throws {
        let advancer = FakeFeedAdvancer(count: 20)
        var limits = ProviderFeedPump.Limits.test
        limits.minimumPublishedItems = 60
        let pump = ProviderFeedPump(advancer: advancer, limits: limits)

        // 真实链路里每次补页都会 signal，系统随之重新枚举；这里显式驱动同一循环。
        for _ in 0..<4 {
            await pump.noteEnumerated(publishedCount: await advancer.currentCount)
            await pump.waitForPendingAdvance()
        }

        let advanceCount = await advancer.advanceCount
        let finalCount = await advancer.currentCount
        XCTAssertEqual(advanceCount, 2)
        XCTAssertEqual(finalCount, 60)
    }

    /// 缩略图请求同样能触发保底填充，即使可见项都在列表头部。
    func testVisibilityAlsoFillsUpToMinimum() async throws {
        let advancer = FakeFeedAdvancer(count: 20)
        var limits = ProviderFeedPump.Limits.test
        limits.minimumPublishedItems = 60
        let pump = ProviderFeedPump(advancer: advancer, limits: limits)
        await syncReplica(pump, advancer)

        await pump.noteVisible(Self.identifiers(0..<5))
        await pump.waitForPendingAdvance()

        let advanceCount = await advancer.advanceCount
        XCTAssertEqual(advanceCount, 1)
    }

    /// 达到保底线后不再自动填充，后续增长只能由真实滚动驱动。
    func testStopsFillingOnceMinimumIsReached() async throws {
        let advancer = FakeFeedAdvancer(count: 60)
        var limits = ProviderFeedPump.Limits.test
        limits.minimumPublishedItems = 60
        let pump = ProviderFeedPump(advancer: advancer, limits: limits)

        await pump.noteEnumerated(publishedCount: await advancer.currentCount)
        await pump.waitForPendingAdvance()

        let advanceCount = await advancer.advanceCount
        XCTAssertEqual(advanceCount, 0)
    }

    /// 远端已耗尽时保底填充也必须停手，不对空结果反复请求。
    func testDoesNotFillWhenFeedIsExhausted() async throws {
        let advancer = FakeFeedAdvancer(count: 20, hasMore: false)
        var limits = ProviderFeedPump.Limits.test
        limits.minimumPublishedItems = 60
        let pump = ProviderFeedPump(advancer: advancer, limits: limits)

        await pump.noteEnumerated(publishedCount: await advancer.currentCount)
        await pump.waitForPendingAdvance()

        let advanceCount = await advancer.advanceCount
        XCTAssertEqual(advanceCount, 0)
    }

    /// 窗口页数上限同样约束保底填充，异常的重复枚举不会把远端拉空。
    func testFillRespectsSessionPageLimit() async throws {
        let advancer = FakeFeedAdvancer(count: 20)
        var limits = ProviderFeedPump.Limits.test
        limits.minimumPublishedItems = 10_000
        limits.maximumPagesPerWindow = 3
        let pump = ProviderFeedPump(advancer: advancer, limits: limits)

        for _ in 0..<10 {
            await pump.noteEnumerated(publishedCount: await advancer.currentCount)
            await pump.waitForPendingAdvance()
        }

        let advanceCount = await advancer.advanceCount
        XCTAssertEqual(advanceCount, 3)
    }
}

/// 冷启动与信号可信度：重扫后系统会为整个目录重新请求缩略图（实测可达尾部），
/// 扩展实例又随时可能被系统回收再重建。冷实例若把「存储有货、内存计数为零」
/// 误判成副本落后，或把全量缩略图扫描误判成滚动到底，就会形成
/// 「重扫 → 全量缩略图 → 补页 → 再重扫」的自激循环——Finder 表现为空白页反复闪动。
extension ProviderFeedPumpTests {
    /// 冷启动实例把存储长度当作已上屏基线：头部可见既不发布也不补页。
    func testColdStartHeadVisibilityDoesNotPublishOrAdvance() async throws {
        let advancer = FakeFeedAdvancer(count: 200)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)

        // 没有任何枚举通知——模拟系统只为缩略图唤醒的全新扩展实例。
        await pump.noteVisible(Self.identifiers(0..<8))
        await pump.waitForPendingAdvance()

        let advanceCount = await advancer.advanceCount
        let publishCount = await advancer.publishCount
        let rescanCount = await advancer.rescanCount
        XCTAssertEqual(advanceCount, 0)
        XCTAssertEqual(publishCount, 0, "冷启动不能把内存计数为零误判成副本落后")
        XCTAssertEqual(rescanCount, 0)
    }

    /// 冷启动实例的尾部可见仍然有效：以存储长度为基线正常补页。
    func testColdStartTailVisibilityAdvancesFromStoreBaseline() async throws {
        let advancer = FakeFeedAdvancer(count: 200)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)

        await pump.noteVisible(Self.identifiers(196..<200))
        await pump.waitForPendingAdvance()

        let advanceCount = await advancer.advanceCount
        XCTAssertEqual(advanceCount, 1, "真实滚动到底的信号在冷实例上不能失效")
    }

    /// 正常补页只发轻量 signal（系统增量追加，不闪屏）；绝不触发会引发
    /// 全目录缩略图重扫的 reimport。
    func testAdvancePublishesSignalWithoutRescan() async throws {
        let advancer = FakeFeedAdvancer(count: 40)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)
        await pump.noteEnumerated(publishedCount: 40)

        await pump.noteVisible(Self.identifiers(36..<40))
        await pump.waitForPendingAdvance()

        let advanceCount = await advancer.advanceCount
        let publishCount = await advancer.publishCount
        let rescanCount = await advancer.rescanCount
        XCTAssertEqual(advanceCount, 1)
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(rescanCount, 0, "常规补页不得触发全量重扫")
    }

    /// 副本落后先发轻量 signal；静默窗口后仍未追平才升级为重扫修复。
    func testLagEscalatesToRescanOnlyAfterSignalDidNotHelp() async throws {
        let advancer = FakeFeedAdvancer(count: 60)
        let clock = TestClock(start: Date(timeIntervalSince1970: 2_000))
        var limits = ProviderFeedPump.Limits.test
        limits.publishDebounceSeconds = 10
        let pump = ProviderFeedPump(advancer: advancer, limits: limits, now: { clock.now })

        await pump.noteEnumerated(publishedCount: 20)
        await pump.waitForPendingAdvance()

        let firstPublish = await advancer.publishCount
        let firstRescan = await advancer.rescanCount
        XCTAssertEqual(firstPublish, 1, "第一次滞后先尝试轻量 signal")
        XCTAssertEqual(firstRescan, 0)

        clock.advance(by: 11)
        await pump.noteVisible(Self.identifiers(16..<20))
        await pump.waitForPendingAdvance()

        let secondPublish = await advancer.publishCount
        let secondRescan = await advancer.rescanCount
        XCTAssertEqual(secondPublish, 2)
        XCTAssertEqual(secondRescan, 1, "signal 未奏效才升级为重扫")
    }
}

/// 重扫是系统级重放整棵子树的重操作；副本落后期间每一批缩略图请求都会命中
/// 「存储领先于副本」分支，不节流就是滚动一次触发十几次重扫。
extension ProviderFeedPumpTests {
    /// 静默窗口内重复的可见信号不再重复请求重扫；窗口过后允许重试，防止一次丢失的重扫请求永久搁浅。
    func testStoreAheadPublishRequestsAreDebounced() async throws {
        let advancer = FakeFeedAdvancer(count: 60)
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        var limits = ProviderFeedPump.Limits.test
        limits.publishDebounceSeconds = 10
        let pump = ProviderFeedPump(advancer: advancer, limits: limits, now: { clock.now })
        await pump.noteEnumerated(publishedCount: 20)
        await pump.waitForPendingAdvance()

        await pump.noteVisible(Self.identifiers(16..<20))
        await pump.waitForPendingAdvance()
        await pump.noteVisible(Self.identifiers(16..<20))
        await pump.waitForPendingAdvance()

        let duringWindow = await advancer.publishCount
        XCTAssertEqual(duringWindow, 1, "重扫在途时重复的可见信号不该再次请求重扫")

        clock.advance(by: 11)
        await pump.noteVisible(Self.identifiers(16..<20))
        await pump.waitForPendingAdvance()

        let afterWindow = await advancer.publishCount
        XCTAssertEqual(afterWindow, 2, "静默窗口过后必须允许重试")
    }

    /// 每次补页都触发重扫，系统会先建新的根枚举器、稍后才失效旧的；
    /// 旧枚举器的失效不能取消新会话正在执行的补页，否则每翻一页都要卡一拍。
    func testDisarmOfPreviousEnumeratorKeepsNewSessionAdvancing() async throws {
        let advancer = GatedFeedAdvancer(count: 40)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)
        await pump.arm()
        await pump.noteEnumerated(publishedCount: 40)
        await pump.waitForPendingAdvance()

        await advancer.closeGate()
        await pump.noteVisible(Self.identifiers(36..<40))
        await advancer.waitUntilAdvanceStarted()
        // 重扫让系统创建了新的根枚举器，旧枚举器随后才失效。
        await pump.arm()
        await pump.disarm()
        await advancer.openGate()
        await pump.waitForPendingAdvance()

        let advanceCount = await advancer.advanceCount
        let publishCount = await advancer.publishCount
        XCTAssertEqual(advanceCount, 1)
        XCTAssertEqual(publishCount, 1, "在途补页必须完成并发布，不该被旧枚举器的失效连带取消")
    }

    /// 最后一个根枚举器失效才真正停泵，语义与旧的单枚举器行为一致。
    func testLastDisarmStillCancelsPendingAdvance() async throws {
        let advancer = GatedFeedAdvancer(count: 40)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)
        await pump.arm()
        await pump.noteEnumerated(publishedCount: 40)
        await pump.waitForPendingAdvance()

        await advancer.closeGate()
        await pump.noteVisible(Self.identifiers(36..<40))
        await advancer.waitUntilAdvanceStarted()
        await pump.disarm()

        let publishCount = await advancer.publishCount
        XCTAssertEqual(publishCount, 0, "用户关闭最后一个浏览窗口后不该再有后台发布")
    }

    /// 扩展实例失效必须无条件停泵，无论系统还欠着多少个枚举器的 invalidate。
    func testShutdownCancelsPendingAdvanceRegardlessOfActiveEnumerators() async throws {
        let advancer = GatedFeedAdvancer(count: 40)
        let pump = ProviderFeedPump(advancer: advancer, limits: .test)
        await pump.arm()
        await pump.arm()
        await pump.noteEnumerated(publishedCount: 40)
        await pump.waitForPendingAdvance()

        await advancer.closeGate()
        await pump.noteVisible(Self.identifiers(36..<40))
        await advancer.waitUntilAdvanceStarted()
        await pump.shutdown()

        let publishCount = await advancer.publishCount
        XCTAssertEqual(publishCount, 0, "扩展失效后不该再有任何发布")
    }
}

/// 以「仓库为唯一真值」的测试替身：补页真的会让顺序变长，泵下次读到的就是新长度。
private actor FakeFeedAdvancer: ProviderFeedAdvancing {
    private(set) var advanceCount = 0
    private(set) var publishCount = 0
    private(set) var rescanCount = 0
    private(set) var currentCount: Int
    private let hasMore: Bool
    private var failsNextAdvance = false

    init(count: Int, hasMore: Bool = true) {
        currentCount = count
        self.hasMore = hasMore
    }

    /// 与生产实现一致的稳定标识格式。
    static func identifier(at index: Int) -> String {
        "discover:item-\(index)"
    }

    func setFailsNextAdvance(_ value: Bool) {
        failsNextAdvance = value
    }

    func feedState() async throws -> ProviderFeedState {
        ProviderFeedState(
            identifiers: (0..<currentCount).map(Self.identifier(at:)),
            hasMore: hasMore
        )
    }

    func advanceFeed() async throws -> Bool {
        advanceCount += 1
        if failsNextAdvance {
            failsNextAdvance = false
            throw FakeFeedError.unavailable
        }
        currentCount += 20
        return hasMore
    }

    func publishFeedChanges() async {
        publishCount += 1
    }

    func forceFeedRescan() async {
        rescanCount += 1
    }
}

/// 可在 advanceFeed 中途挂起的替身：交叠 arm/disarm 的用例需要「补页确定在途」这个状态点。
private actor GatedFeedAdvancer: ProviderFeedAdvancing {
    private(set) var advanceCount = 0
    private(set) var publishCount = 0
    private var currentCount: Int
    private var gateClosed = false
    private var gateWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledWaiters: Set<UUID> = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var advanceInFlight = false

    init(count: Int) {
        currentCount = count
    }

    func closeGate() {
        gateClosed = true
    }

    func openGate() {
        gateClosed = false
        let waiters = Array(gateWaiters.values)
        gateWaiters = [:]
        waiters.forEach { $0.resume() }
    }

    /// 等到补页真正走进闸门，测试才能在「确定在途」状态下驱动 arm/disarm。
    func waitUntilAdvanceStarted() async {
        guard !advanceInFlight else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func feedState() async throws -> ProviderFeedState {
        ProviderFeedState(
            identifiers: (0..<currentCount).map(FakeFeedAdvancer.identifier(at:)),
            hasMore: true
        )
    }

    func advanceFeed() async throws -> Bool {
        advanceCount += 1
        advanceInFlight = true
        startWaiters.forEach { $0.resume() }
        startWaiters = []
        defer { advanceInFlight = false }
        if gateClosed {
            try await waitForGate()
        }
        try Task.checkCancellation()
        currentCount += 20
        return true
    }

    func publishFeedChanges() async {
        publishCount += 1
    }

    func forceFeedRescan() async {}

    /// 闸门等待必须响应取消，否则 disarm/shutdown 等待任务收敛时会和测试互相死锁。
    private func waitForGate() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledWaiters.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else if gateClosed {
                    gateWaiters[id] = continuation
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.failWaiter(id) }
        }
    }

    /// 取消可能先于等待注册到达，此时记下 ID 由注册方立刻自取消。
    private func failWaiter(_ id: UUID) {
        if let continuation = gateWaiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledWaiters.insert(id)
        }
    }
}

/// 退避窗口需要可控时间源，测试不依赖真实等待。
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// 补页失败的确定性错误。
private enum FakeFeedError: Error {
    case unavailable
}

extension ProviderFeedPump.Limits {
    /// 单测使用更小的水位并默认关闭保底，让每个用例只锁定自己关心的那条触发路径。
    static var test: ProviderFeedPump.Limits {
        ProviderFeedPump.Limits(
            prefetchDistance: 6,
            minimumPublishedItems: 0,
            maximumPagesPerWindow: 15,
            pageWindowSeconds: 600,
            backoffSeconds: 30,
            publishDebounceSeconds: 10
        )
    }
}
