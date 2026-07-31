import Foundation
import XCTest
@testable import MirageCore

final class DiscoveryFeedRepositoryTests: XCTestCase {
    private var temporaryURL: URL!

    /// 每个测试使用独立共享目录，避免推荐 generation 与其他测试相互污染。
    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    }

    /// 测试结束后删除本测试创建的完整临时目录。
    override func tearDownWithError() throws {
        if let temporaryURL, FileManager.default.fileExists(atPath: temporaryURL.path) {
            try FileManager.default.removeItem(at: temporaryURL)
        }
    }

    /// 首次与续页都应返回20条，并在同一 generation 内累计持久化40条。
    func testRecommendationPagesShareGenerationAndPersistTwentyRecordsPerPage() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let openverse = DiscoveryPagedOpenverse()
        let diceBear = DiceBearClient(styles: [.pixelArt])
        let repository = DiscoveryFeedRepository(
            storage: storage,
            service: ImageSearchService(openverse: openverse, diceBear: diceBear),
            diceBear: diceBear,
            now: { Date(timeIntervalSince1970: 10_000) }
        )

        let first = try await repository.page(
            generation: nil,
            page: 1,
            pageSize: DiscoveryRecommendation.pageSize
        )
        XCTAssertEqual(first.records.count, 20)
        XCTAssertEqual(first.nextPage, 2)
        XCTAssertTrue(first.didMutateSnapshot)

        let second = try await repository.page(
            generation: first.generation,
            page: 2,
            pageSize: DiscoveryRecommendation.pageSize
        )
        XCTAssertEqual(second.generation, first.generation)
        XCTAssertEqual(second.records.count, 20)
        XCTAssertEqual(Set((first.records + second.records).map(\.id)).count, 40)

        let snapshot = try await storage.readDiscoveryFeedSnapshot(generation: first.generation)
        XCTAssertEqual(snapshot?.records.count, 40)
        XCTAssertEqual(snapshot?.nextPage, 3)

        let cachedSecond = try await repository.page(
            generation: first.generation,
            page: 2,
            pageSize: DiscoveryRecommendation.pageSize
        )
        XCTAssertFalse(cachedSecond.didMutateSnapshot)
        let calls = await openverse.pages()
        XCTAssertEqual(calls, [1, 2])
    }

    /// 当前推荐刷新后，旧 Finder token 仍须续读旧 generation 且不能覆盖当前指针。
    func testFrozenGenerationSurvivesCurrentSnapshotRefresh() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let openverse = DiscoveryPagedOpenverse()
        let diceBear = DiceBearClient(styles: [.pixelArt])
        let repository = DiscoveryFeedRepository(
            storage: storage,
            service: ImageSearchService(openverse: openverse, diceBear: diceBear),
            diceBear: diceBear,
            now: { Date(timeIntervalSince1970: 20_000) }
        )
        let oldFirst = try await repository.page(
            generation: nil,
            page: 1,
            pageSize: DiscoveryRecommendation.pageSize
        )
        let replacement = try await storage.commitDiscoveryFeed(
            records: Self.records(prefix: "replacement", count: 20),
            refreshedAt: Date(timeIntervalSince1970: 20_100),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            pageSize: DiscoveryRecommendation.pageSize,
            nextPage: 2
        )
        XCTAssertNotEqual(replacement.generation, oldFirst.generation)

        let oldSecond = try await repository.page(
            generation: oldFirst.generation,
            page: 2,
            pageSize: DiscoveryRecommendation.pageSize
        )
        XCTAssertEqual(oldSecond.generation, oldFirst.generation)
        XCTAssertEqual(oldSecond.records.count, 20)
        let current = try await storage.readDiscoveryFeedSnapshot()
        XCTAssertEqual(current?.generation, replacement.generation)
        XCTAssertEqual(current?.records.map(\.id), replacement.records.map(\.id))
    }

    /// 两个进程等价仓库并发刷新首页时，迟到响应必须采用 CAS 胜者而不能再创建新 generation。
    func testConcurrentHomepageRefreshUsesWinningSnapshotCAS() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let secondStorage = try AppGroupStorage(baseURL: temporaryURL)
        let expired = try await firstStorage.commitDiscoveryFeed(
            records: Self.records(prefix: "expired", count: DiscoveryRecommendation.pageSize),
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            nextPage: 2
        )
        let gate = DiscoveryRaceGate(participantCount: 2)
        let firstOpenverse = RacingDiscoveryOpenverse(
            prefix: "homepage-first",
            nextPage: 2,
            gate: gate
        )
        let secondOpenverse = RacingDiscoveryOpenverse(
            prefix: "homepage-second",
            nextPage: 2,
            gate: gate
        )
        let diceBear = DiceBearClient(styles: [.pixelArt])
        let fixedNow = Date(timeIntervalSince1970: 10_000)
        let firstRepository = DiscoveryFeedRepository(
            storage: firstStorage,
            service: ImageSearchService(openverse: firstOpenverse, diceBear: diceBear),
            diceBear: diceBear,
            now: { fixedNow }
        )
        let secondRepository = DiscoveryFeedRepository(
            storage: secondStorage,
            service: ImageSearchService(openverse: secondOpenverse, diceBear: diceBear),
            diceBear: diceBear,
            now: { fixedNow }
        )

        async let firstPage = firstRepository.page(
            generation: nil,
            page: 1,
            pageSize: DiscoveryRecommendation.pageSize
        )
        async let secondPage = secondRepository.page(
            generation: nil,
            page: 1,
            pageSize: DiscoveryRecommendation.pageSize
        )
        let pages = try await [firstPage, secondPage]
        let storedCurrent = try await firstStorage.readDiscoveryFeedSnapshot()
        let current = try XCTUnwrap(storedCurrent)

        XCTAssertEqual(pages[0].generation, pages[1].generation)
        XCTAssertEqual(pages[0].records, pages[1].records)
        XCTAssertEqual(pages.filter(\.didMutateSnapshot).count, 1)
        XCTAssertEqual(current.generation, expired.generation + 1)
        XCTAssertEqual(current.records, pages[0].records)
    }

    /// 两个仓库同时加载同一页时，输家应返回赢家记录与赢家 nextPage，且磁盘只追加一页。
    func testConcurrentRepositoriesReuseWinningPageAndNextPage() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let secondStorage = try AppGroupStorage(baseURL: temporaryURL)
        let pageSize = DiscoveryRecommendation.pageSize
        let committed = try await firstStorage.commitDiscoveryFeed(
            records: Self.records(prefix: "initial", count: pageSize),
            refreshedAt: Date(timeIntervalSince1970: 30_000),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            pageSize: pageSize,
            nextPage: 2
        )
        let gate = DiscoveryRaceGate(participantCount: 2)
        let firstOpenverse = RacingDiscoveryOpenverse(
            prefix: "first",
            nextPage: 3,
            gate: gate
        )
        let secondOpenverse = RacingDiscoveryOpenverse(
            prefix: "second",
            nextPage: 8,
            gate: gate
        )
        let diceBear = DiceBearClient(styles: [.pixelArt])
        let firstRepository = DiscoveryFeedRepository(
            storage: firstStorage,
            service: ImageSearchService(openverse: firstOpenverse, diceBear: diceBear),
            diceBear: diceBear
        )
        let secondRepository = DiscoveryFeedRepository(
            storage: secondStorage,
            service: ImageSearchService(openverse: secondOpenverse, diceBear: diceBear),
            diceBear: diceBear
        )

        async let firstPage = firstRepository.page(
            generation: committed.generation,
            page: 2,
            pageSize: pageSize
        )
        async let secondPage = secondRepository.page(
            generation: committed.generation,
            page: 2,
            pageSize: pageSize
        )
        let pages = try await [firstPage, secondPage]
        let restored = try await firstStorage.readDiscoveryFeedSnapshot(
            generation: committed.generation
        )
        let winner = try XCTUnwrap(restored)
        let winnerRecords = Array(winner.records.dropFirst(pageSize).prefix(pageSize))

        XCTAssertEqual(pages.map { $0.records.map(\.id) }, [
            winnerRecords.map(\.id), winnerRecords.map(\.id)
        ])
        XCTAssertEqual(pages.map(\.nextPage), [winner.nextPage, winner.nextPage])
        XCTAssertEqual(winner.records.count, pageSize * 2)
        // 远端游标只决定是否还有内容；本地目录树始终推进到连续逻辑页 3。
        XCTAssertEqual(winner.nextPage, 3)
    }

    /// 同一仓库的锚点与目录枚举并发读取同一页时，只允许一个远端请求在途。
    func testConcurrentCallsOnSameRepositoryShareSingleFlight() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let committed = try await storage.commitDiscoveryFeed(
            records: Self.records(prefix: "single-flight-initial", count: 20),
            refreshedAt: Date(),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            nextPage: 2
        )
        let openverse = SingleFlightDiscoveryOpenverse()
        let diceBear = DiceBearClient(styles: [.pixelArt])
        let repository = DiscoveryFeedRepository(
            storage: storage,
            service: ImageSearchService(openverse: openverse, diceBear: diceBear),
            diceBear: diceBear
        )

        async let first = repository.page(generation: committed.generation, page: 2, pageSize: 20)
        async let second = repository.page(generation: committed.generation, page: 2, pageSize: 20)
        let pages = try await [first, second]
        let requestedPages = await openverse.requestedPages()

        XCTAssertEqual(pages[0].records, pages[1].records)
        XCTAssertEqual(requestedPages, [2])
    }

    /// 单个关键词在 Openverse 匿名深度上限见底后，同一条逻辑流必须切到下一关键词继续。
    func testRotatesToNextQueryWhenRemoteExhausts() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let queries = DiscoveryRecommendation.queries
        // 第一个关键词只有 1 页远端内容，第二个还有 2 页。
        let openverse = RotatingDiscoveryOpenverse(depths: [queries[0]: 1, queries[1]: 2])
        let diceBear = DiceBearClient(styles: [.pixelArt])
        let repository = DiscoveryFeedRepository(
            storage: storage,
            service: ImageSearchService(openverse: openverse, diceBear: diceBear),
            diceBear: diceBear,
            now: { Date(timeIntervalSince1970: 50_000) }
        )

        let first = try await repository.page(
            generation: nil,
            page: 1,
            pageSize: DiscoveryRecommendation.pageSize
        )
        XCTAssertEqual(first.records.count, 20)
        XCTAssertEqual(first.nextPage, 2, "第一个关键词耗尽不该终结整条推荐流")

        let second = try await repository.page(
            generation: first.generation,
            page: 2,
            pageSize: DiscoveryRecommendation.pageSize
        )
        XCTAssertEqual(second.records.count, 20)
        XCTAssertEqual(second.nextPage, 3)
        XCTAssertTrue(second.records.contains { $0.source == .openverse })

        let calls = await openverse.requestedCalls()
        XCTAssertEqual(calls, [
            .init(query: queries[0], page: 1),
            .init(query: queries[1], page: 1)
        ], "第二逻辑页必须从下一关键词的第一页抓取")
    }

    /// 轮换游标必须持久化：另一个进程的仓库实例续读时不能重放已耗尽的关键词。
    func testRotationCursorSurvivesRepositoryRestart() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let queries = DiscoveryRecommendation.queries
        let openverse = RotatingDiscoveryOpenverse(depths: [queries[0]: 1, queries[1]: 3])
        let diceBear = DiceBearClient(styles: [.pixelArt])
        let makeRepository = {
            DiscoveryFeedRepository(
                storage: storage,
                service: ImageSearchService(openverse: openverse, diceBear: diceBear),
                diceBear: diceBear,
                now: { Date(timeIntervalSince1970: 60_000) }
            )
        }

        let first = try await makeRepository().page(
            generation: nil,
            page: 1,
            pageSize: DiscoveryRecommendation.pageSize
        )
        let second = try await makeRepository().page(
            generation: first.generation,
            page: 2,
            pageSize: DiscoveryRecommendation.pageSize
        )

        XCTAssertEqual(second.records.count, 20)
        let calls = await openverse.requestedCalls()
        XCTAssertEqual(calls, [
            .init(query: queries[0], page: 1),
            .init(query: queries[1], page: 1)
        ], "新仓库实例必须从持久化游标续读，而不是重放旧关键词")
    }

    /// 只有整个关键词目录全部耗尽，推荐流才真正宣告结束。
    func testFeedExhaustsOnlyAfterAllQueriesExhaust() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let queries = DiscoveryRecommendation.queries
        // 每个关键词只有 1 页：N 个关键词就是 N 个逻辑页。
        let openverse = RotatingDiscoveryOpenverse(
            depths: Dictionary(uniqueKeysWithValues: queries.map { ($0, 1) })
        )
        let diceBear = DiceBearClient(styles: [.pixelArt])
        let repository = DiscoveryFeedRepository(
            storage: storage,
            service: ImageSearchService(openverse: openverse, diceBear: diceBear),
            diceBear: diceBear,
            now: { Date(timeIntervalSince1970: 70_000) }
        )

        var generation: UInt64?
        var lastNextPage: Int?
        for page in 1...queries.count {
            let result = try await repository.page(
                generation: generation,
                page: page,
                pageSize: DiscoveryRecommendation.pageSize
            )
            generation = result.generation
            lastNextPage = result.nextPage
            if page < queries.count {
                XCTAssertEqual(result.nextPage, page + 1)
            }
        }

        XCTAssertNil(lastNextPage, "目录耗尽后必须宣告结束，不能无限空转")
        let calls = await openverse.requestedCalls()
        XCTAssertEqual(calls, queries.map { .init(query: $0, page: 1) })
    }

    /// 网络失败页走本地兜底，但远端位置不被消费；下一逻辑页必须原地重试同一远端页。
    func testFallbackPageKeepsRemoteCursorForRetry() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let queries = DiscoveryRecommendation.queries
        let openverse = RotatingDiscoveryOpenverse(
            depths: [queries[0]: 3],
            failingOnce: [.init(query: queries[0], page: 2)]
        )
        let diceBear = DiceBearClient(styles: [.pixelArt])
        let repository = DiscoveryFeedRepository(
            storage: storage,
            service: ImageSearchService(openverse: openverse, diceBear: diceBear),
            diceBear: diceBear,
            now: { Date(timeIntervalSince1970: 80_000) }
        )

        let first = try await repository.page(
            generation: nil,
            page: 1,
            pageSize: DiscoveryRecommendation.pageSize
        )
        let second = try await repository.page(
            generation: first.generation,
            page: 2,
            pageSize: DiscoveryRecommendation.pageSize
        )
        XCTAssertTrue(
            second.records.allSatisfy { $0.source == .diceBear },
            "失败页应交付本地兜底头像"
        )
        XCTAssertEqual(second.nextPage, 3, "兜底页不能终结推荐流")

        let third = try await repository.page(
            generation: first.generation,
            page: 3,
            pageSize: DiscoveryRecommendation.pageSize
        )
        XCTAssertTrue(third.records.contains { $0.source == .openverse })

        let calls = await openverse.requestedCalls()
        XCTAssertEqual(calls, [
            .init(query: queries[0], page: 1),
            .init(query: queries[0], page: 2),
            .init(query: queries[0], page: 2)
        ], "兜底页之后必须原地重试同一远端页，不能跳过其内容")
    }

    /// File Provider 可注入更短单页预算；超时后必须迅速交付同页本地兜底而不是挂住枚举。
    func testInjectedNetworkTimeoutReturnsFallbackWithinBudget() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let diceBear = DiceBearClient(styles: [.pixelArt])
        let repository = DiscoveryFeedRepository(
            storage: storage,
            service: ImageSearchService(
                openverse: SlowDiscoveryOpenverse(),
                diceBear: diceBear
            ),
            diceBear: diceBear,
            networkTimeout: .milliseconds(30)
        )
        let clock = ContinuousClock()
        let started = clock.now

        let page = try await repository.page(
            generation: nil,
            page: 1,
            pageSize: DiscoveryRecommendation.pageSize
        )
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(page.records.count, DiscoveryRecommendation.pageSize)
        XCTAssertTrue(page.records.allSatisfy { $0.source == .diceBear })
        XCTAssertLessThan(elapsed, .milliseconds(500))
    }

    /// 持久化由独立 single-flight 完成后，即使 UI caller 已取消，也必须继续交付刷新通知。
    func testCommittedMutationSignalsAfterCallerCancellation() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let openverse = SingleFlightDiscoveryOpenverse()
        let diceBear = DiceBearClient(styles: [.pixelArt])
        let signal = DiscoverySnapshotSignalProbe()
        let repository = DiscoveryFeedRepository(
            storage: storage,
            service: ImageSearchService(openverse: openverse, diceBear: diceBear),
            diceBear: diceBear,
            snapshotDidChange: { try await signal.send() },
            snapshotNotificationRetryDelay: .milliseconds(10)
        )

        let request = Task {
            try await repository.page(
                generation: nil,
                page: 1,
                pageSize: DiscoveryRecommendation.pageSize
            )
        }
        let requestStarted = await openverse.waitForRequestedPages(1)
        XCTAssertTrue(requestStarted)
        request.cancel()

        do {
            _ = try await request.value
            XCTFail("已取消 caller 不应收到成功页面")
        } catch is CancellationError {
            // 预期：caller 取消只影响页面交付，不撤销已经开始的持久化与通知。
        }

        let didSignal = await signal.waitForAttempts(1)
        XCTAssertTrue(didSignal)
        let snapshot = try await storage.readDiscoveryFeedSnapshot()
        XCTAssertEqual(snapshot?.records.count, DiscoveryRecommendation.pageSize)
        let successes = await signal.successCount()
        XCTAssertEqual(successes, 1)
    }

    /// working set signal 的瞬时失败必须保留 dirty 状态并自动重试，而不是永久吞掉。
    func testSnapshotSignalRetriesAfterInitialFailure() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let openverse = DiscoveryPagedOpenverse()
        let diceBear = DiceBearClient(styles: [.pixelArt])
        let signal = DiscoverySnapshotSignalProbe(failuresBeforeSuccess: 1)
        let repository = DiscoveryFeedRepository(
            storage: storage,
            service: ImageSearchService(openverse: openverse, diceBear: diceBear),
            diceBear: diceBear,
            snapshotDidChange: { try await signal.send() },
            snapshotNotificationRetryDelay: .milliseconds(10)
        )

        _ = try await repository.page(
            generation: nil,
            page: 1,
            pageSize: DiscoveryRecommendation.pageSize
        )

        let retried = await signal.waitForAttempts(2)
        XCTAssertTrue(retried)
        let attempts = await signal.attemptCount()
        let successes = await signal.successCount()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(successes, 1)
    }

    /// 构造与 Openverse 测试记录相同约束的安全 HTTPS 元数据。
    fileprivate static func records(prefix: String, count: Int) -> [RemoteImageRecord] {
        (0..<count).map { index in
            let url = URL(string: "https://example.com/\(prefix)-\(index).png")!
            return RemoteImageRecord(
                id: "\(prefix)-\(index)",
                title: "\(prefix) \(index)",
                source: .openverse,
                imageURL: url,
                thumbnailURL: url,
                license: .cc0
            )
        }
    }
}

/// 按 (关键词, 页码) 记录请求序列；每个关键词只提供固定深度的远端页，模拟匿名分页上限。
private actor RotatingDiscoveryOpenverse: OpenverseSearching {
    struct RemoteCall: Hashable, Sendable {
        let query: String
        let page: Int
    }

    private let depths: [String: Int]
    private var pendingFailures: Set<RemoteCall>
    private var calls: [RemoteCall] = []

    init(depths: [String: Int], failingOnce: [RemoteCall] = []) {
        self.depths = depths
        pendingFailures = Set(failingOnce)
    }

    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        let call = RemoteCall(query: query, page: page)
        calls.append(call)
        if pendingFailures.remove(call) != nil {
            throw URLError(.networkConnectionLost)
        }
        let depth = depths[query] ?? 0
        guard page <= depth else { return ImageSearchPage(records: [], nextPage: nil) }
        let records = (0..<pageSize).map { index in
            let url = URL(string: "https://example.com/\(query)-\(page)-\(index).png")!
            return RemoteImageRecord(
                id: "\(query):\(page):\(index)",
                title: "\(query) \(page)-\(index)",
                source: .openverse,
                imageURL: url,
                thumbnailURL: url,
                license: .cc0
            )
        }
        return ImageSearchPage(records: records, nextPage: page < depth ? page + 1 : nil)
    }

    /// 返回完整远端请求序列，锁定轮换与重试的确切路径。
    func requestedCalls() -> [RemoteCall] {
        calls
    }
}

private actor DiscoveryPagedOpenverse: OpenverseSearching {
    private var requestedPages: [Int] = []

    /// 每个远端页返回调用方请求的条数，并稳定提供第三页游标。
    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        requestedPages.append(page)
        let records = (0..<pageSize).map { index in
            let url = URL(string: "https://example.com/discovery-\(page)-\(index).png")!
            return RemoteImageRecord(
                id: "discovery-\(page)-\(index)",
                title: "Discovery \(page)-\(index)",
                source: .openverse,
                imageURL: url,
                thumbnailURL: url,
                license: .cc0
            )
        }
        return ImageSearchPage(records: records, nextPage: page + 1)
    }

    /// 返回实际请求页序列，验证缓存命中不会重复访问网络。
    func pages() -> [Int] {
        requestedPages
    }
}

/// 让两个远端请求都读取旧快照后再同时返回，稳定制造同页追加竞态。
private actor DiscoveryRaceGate {
    private let participantCount: Int
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    /// 收齐所有参与者后一次性放行，避免测试依赖任务调度先后。
    func arriveAndWait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            guard continuations.count == participantCount else { return }
            let waiting = continuations
            continuations.removeAll()
            waiting.forEach { $0.resume() }
        }
    }
}

/// 为同页竞态返回实例专属记录与游标，验证输家不会泄漏自己的响应。
private actor RacingDiscoveryOpenverse: OpenverseSearching {
    private let prefix: String
    private let nextPage: Int
    private let gate: DiscoveryRaceGate

    init(prefix: String, nextPage: Int, gate: DiscoveryRaceGate) {
        self.prefix = prefix
        self.nextPage = nextPage
        self.gate = gate
    }

    /// 等待另一个实例也进入网络阶段，再构造当前实例的唯一结果。
    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        await gate.arriveAndWait()
        let records = DiscoveryFeedRepositoryTests.records(prefix: prefix, count: pageSize)
        return ImageSearchPage(records: records, nextPage: nextPage)
    }
}

/// 延迟返回让第二个调用稳定进入 actor，验证同一实例的 single-flight 去重。
private actor SingleFlightDiscoveryOpenverse: OpenverseSearching {
    private var pages: [Int] = []

    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        pages.append(page)
        try await Task.sleep(for: .milliseconds(100))
        return ImageSearchPage(
            records: DiscoveryFeedRepositoryTests.records(
                prefix: "single-flight-page-\(page)",
                count: pageSize
            ),
            nextPage: page + 1
        )
    }

    /// 返回调用页序列，单页并发只应留下一个元素。
    func requestedPages() -> [Int] {
        pages
    }

    /// 等到请求真正进入远端替身后再取消 caller，稳定覆盖提交前取消的竞争窗口。
    func waitForRequestedPages(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if pages.count >= expected { return true }
            await Task.yield()
        }
        return pages.count >= expected
    }
}

private actor SlowDiscoveryOpenverse: OpenverseSearching {
    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        try await Task.sleep(for: .seconds(2))
        return ImageSearchPage(
            records: DiscoveryFeedRepositoryTests.records(prefix: "slow", count: pageSize),
            nextPage: page + 1
        )
    }
}

/// 记录通知尝试，并可让前几次稳定失败以验证 repository 的退避重试。
private actor DiscoverySnapshotSignalProbe {
    private let failuresBeforeSuccess: Int
    private var attempts = 0
    private var successes = 0

    init(failuresBeforeSuccess: Int = 0) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func send() throws {
        attempts += 1
        if attempts <= failuresBeforeSuccess {
            throw URLError(.cannotConnectToHost)
        }
        successes += 1
    }

    func waitForAttempts(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if attempts >= expected { return true }
            await Task.yield()
        }
        return attempts >= expected
    }

    func attemptCount() -> Int { attempts }

    func successCount() -> Int { successes }
}
