import FileProvider
import Foundation
import MirageCore
import XCTest

@available(macOS 26.0, *)
final class SearchEnumeratorPaginationTests: XCTestCase {
    /// 系统允许更大页面时 Finder 固定请求 40；App 的 20 张限制由独立服务实例负责。
    func testInitialFinderCursorUsesFortyResultPage() throws {
        let cursor = try SearchPagePlanner.cursor(
            startingAt: nil,
            request: SearchRequestStub(query: "图片:cat", desiredNumberOfResults: 80),
            observer: SearchObserverStub(maximumResults: 80),
            configurationKey: "sources:1:openverse,pexels"
        )

        XCTAssertEqual(cursor.pageSize, 40)
    }

    /// 单个中文字符是有效系统查询，必须返回一页结果并写入搜索 backing。
    func testSingleChineseCharacterReturnsResults() async {
        let store = SearchStoreSpy()
        let enumerator = SearchEnumerator(
            request: SearchRequestStub(query: "猫", desiredNumberOfResults: 20),
            service: ImageSearchService(
                openverse: FiniteOpenverse(),
                diceBear: DiceBearClient(styles: [.pixelArt])
            ),
            repository: store,
            cache: ProviderSearchCache(),
            manager: nil
        )

        let finished = expectation(description: "单字中文搜索完成")
        let observer = SearchObserverStub(maximumResults: 20, completion: finished)
        enumerator.enumerateSearchResults(for: observer, startingAt: nil)
        await fulfillment(of: [finished], timeout: 2)

        let result = observer.snapshot()
        XCTAssertEqual(result.resultCount, 20)
        XCTAssertNil(result.error)
        let calls = await store.snapshot()
        XCTAssertEqual(calls.map(\.recordCount), [20])
        XCTAssertEqual(calls.map(\.appending), [false])
    }

    /// 纯空白和只有来源前缀的请求都应返回空页，且不能污染搜索 backing。
    func testBlankAndPrefixOnlyQueriesDoNotSearchOrPersist() async {
        let store = SearchStoreSpy()

        for query in ["   ", "图片:"] {
            let enumerator = SearchEnumerator(
                request: SearchRequestStub(query: query, desiredNumberOfResults: 20),
                service: ImageSearchService(
                    openverse: FiniteOpenverse(),
                    diceBear: DiceBearClient(styles: [.pixelArt])
                ),
                repository: store,
                cache: ProviderSearchCache(),
                manager: nil
            )
            let finished = expectation(description: "无效查询返回空页：\(query)")
            let observer = SearchObserverStub(maximumResults: 20, completion: finished)
            enumerator.enumerateSearchResults(for: observer, startingAt: nil)
            await fulfillment(of: [finished], timeout: 2)

            let result = observer.snapshot()
            XCTAssertEqual(result.resultCount, 0)
            XCTAssertNil(result.nextPage)
            XCTAssertNil(result.error)
        }

        let calls = await store.snapshot()
        XCTAssertTrue(calls.isEmpty)
    }

    /// desired 数量达到后仍应返回下一页，同一枚举器的第二次调用必须由独立 relay 正常完成。
    func testDesiredHintKeepsContinuationAndSecondEnumerationCompletes() async throws {
        let request = SearchRequestStub(query: "图片:cat", desiredNumberOfResults: 1)
        let store = SearchStoreSpy()
        let enumerator = SearchEnumerator(
            request: request,
            service: ImageSearchService(
                openverse: FiniteOpenverse(),
                diceBear: DiceBearClient(styles: [.pixelArt])
            ),
            repository: store,
            cache: ProviderSearchCache(),
            manager: nil
        )

        let firstFinished = expectation(description: "第一页完成")
        let firstObserver = SearchObserverStub(maximumResults: 20, completion: firstFinished)
        enumerator.enumerateSearchResults(for: firstObserver, startingAt: nil)
        await fulfillment(of: [firstFinished], timeout: 2)
        let first = firstObserver.snapshot()
        XCTAssertEqual(first.resultCount, 1)
        XCTAssertNil(first.error)
        let nextPage = try XCTUnwrap(first.nextPage)
        let cursor = try SearchPaginationCursor.decode(nextPage.rawValue)
        XCTAssertEqual(cursor.page, 2)
        XCTAssertEqual(cursor.pageSize, 1)
        XCTAssertEqual(cursor.delivered, 1)
        XCTAssertEqual(cursor.searchCursor?.page, 2)
        XCTAssertEqual(
            cursor.searchCursor?.photoCursor?.states.first?.cursor?.rawValue,
            "2"
        )

        let secondFinished = expectation(description: "第二页完成")
        let secondObserver = SearchObserverStub(maximumResults: 20, completion: secondFinished)
        enumerator.enumerateSearchResults(for: secondObserver, startingAt: nextPage)
        await fulfillment(of: [secondFinished], timeout: 2)
        let second = secondObserver.snapshot()
        XCTAssertEqual(second.resultCount, 1)
        XCTAssertNotNil(second.nextPage)
        XCTAssertNil(second.error)
        let calls = await store.snapshot()
        XCTAssertEqual(calls.map(\.appending), [false, true])
        XCTAssertEqual(calls.map(\.recordCount), [1, 1])
    }

    /// 续页时 observer 硬上限变小必须返回 pageExpired，不能超量回调导致系统终止扩展。
    func testReducedObserverLimitExpiresExistingPageToken() async throws {
        let request = SearchRequestStub(query: "图片:cat", desiredNumberOfResults: 20)
        let enumerator = SearchEnumerator(
            request: request,
            service: ImageSearchService(
                openverse: FiniteOpenverse(),
                diceBear: DiceBearClient(styles: [.pixelArt])
            ),
            repository: SearchStoreSpy(),
            cache: ProviderSearchCache(),
            manager: nil
        )
        let firstFinished = expectation(description: "取得20条页令牌")
        let firstObserver = SearchObserverStub(maximumResults: 20, completion: firstFinished)
        enumerator.enumerateSearchResults(for: firstObserver, startingAt: nil)
        await fulfillment(of: [firstFinished], timeout: 2)
        let nextPage = try XCTUnwrap(firstObserver.snapshot().nextPage)

        let secondFinished = expectation(description: "旧页令牌被拒绝")
        let reducedObserver = SearchObserverStub(maximumResults: 5, completion: secondFinished)
        enumerator.enumerateSearchResults(for: reducedObserver, startingAt: nextPage)
        await fulfillment(of: [secondFinished], timeout: 2)
        let second = reducedObserver.snapshot()
        XCTAssertEqual(second.resultCount, 0)
        assertPageExpired(second.error)
    }

    /// 页令牌必须绑定查询且遵守缓存 TTL，跨查询或过期后都要求系统从第一页开始。
    func testCrossQueryAndExpiredTokensReturnPageExpired() throws {
        let observer = SearchObserverStub(maximumResults: 20)
        let current = try SearchPaginationCursor(
            page: 2,
            pageSize: 20,
            delivered: 20,
            query: "cat",
            configurationKey: "sources:1:openverse"
        )
        let crossQueryPage = NSFileProviderPage(rawValue: try current.encoded())
        XCTAssertThrowsError(
            try SearchPagePlanner.cursor(
                startingAt: crossQueryPage,
                request: SearchRequestStub(query: "dog", desiredNumberOfResults: 20),
                observer: observer,
                configurationKey: "sources:1:openverse"
            )
        ) { self.assertPageExpired($0) }

        let expired = try SearchPaginationCursor(
            page: 2,
            pageSize: 20,
            delivered: 20,
            query: "cat",
            configurationKey: "sources:1:openverse",
            issuedAt: Date().addingTimeInterval(-SearchPaginationCursor.maximumAge - 1)
        )
        let expiredPage = NSFileProviderPage(rawValue: try expired.encoded())
        XCTAssertThrowsError(
            try SearchPagePlanner.cursor(
                startingAt: expiredPage,
                request: SearchRequestStub(query: "cat", desiredNumberOfResults: 20),
                observer: observer,
                configurationKey: "sources:1:openverse"
            )
        ) { self.assertPageExpired($0) }
    }

    /// 数据源配置变化后，旧令牌必须在访问缓存和网络前过期。
    func testConfigurationChangeExpiresTokenBeforeSearch() async throws {
        let photos = RevisionedPhotoSearcher()
        let service = ImageSearchService(
            photos: photos,
            diceBear: DiceBearClient(styles: [.pixelArt]),
            automaticAvatarCount: 0
        )
        let request = SearchRequestStub(query: "图片:cat", desiredNumberOfResults: 20)
        let enumerator = SearchEnumerator(
            request: request,
            service: service,
            repository: SearchStoreSpy(),
            cache: ProviderSearchCache(),
            manager: nil
        )

        let firstFinished = expectation(description: "取得旧配置页令牌")
        let firstObserver = SearchObserverStub(maximumResults: 20, completion: firstFinished)
        enumerator.enumerateSearchResults(for: firstObserver, startingAt: nil)
        await fulfillment(of: [firstFinished], timeout: 2)
        let oldPage = try XCTUnwrap(firstObserver.snapshot().nextPage)
        let callsBeforeChange = await photos.recordedCallCount()
        XCTAssertEqual(callsBeforeChange, 1)

        await photos.setRevision(2)
        let secondFinished = expectation(description: "旧配置页令牌被拒绝")
        let secondObserver = SearchObserverStub(maximumResults: 20, completion: secondFinished)
        enumerator.enumerateSearchResults(for: secondObserver, startingAt: oldPage)
        await fulfillment(of: [secondFinished], timeout: 2)

        let second = secondObserver.snapshot()
        XCTAssertEqual(second.resultCount, 0)
        assertPageExpired(second.error)
        let callsAfterChange = await photos.recordedCallCount()
        XCTAssertEqual(callsAfterChange, 1)
    }

    /// 缓存同时绑定完整来源游标和配置，同一逻辑页也不能跨批次复用。
    func testSearchCacheSeparatesConfigurationAndSourceCursor() async {
        let cache = ProviderSearchCache()
        let result = ImageSearchPage(records: [], nextCursor: nil)
        let firstCursor = makeImageSearchCursor(sourcePage: "2")
        let otherCursor = makeImageSearchCursor(sourcePage: "3")
        let now = Date(timeIntervalSince1970: 10_000)

        await cache.store(
            result,
            for: "cat",
            cursor: firstCursor,
            page: 2,
            pageSize: 20,
            configurationKey: "sources:1:openverse",
            now: now
        )
        let exact = await cache.page(
            for: "CAT",
            cursor: firstCursor,
            page: 2,
            pageSize: 20,
            configurationKey: "sources:1:openverse",
            now: now
        )
        let differentCursor = await cache.page(
            for: "cat",
            cursor: otherCursor,
            page: 2,
            pageSize: 20,
            configurationKey: "sources:1:openverse",
            now: now
        )
        let differentConfiguration = await cache.page(
            for: "cat",
            cursor: firstCursor,
            page: 2,
            pageSize: 20,
            configurationKey: "sources:2:openverse",
            now: now
        )

        XCTAssertNotNil(exact)
        XCTAssertNil(differentCursor)
        XCTAssertNil(differentConfiguration)
    }

    /// 统一断言 File Provider 使用专用 pageExpired 错误，而不是普通网络失败。
    private func assertPageExpired(
        _ error: Error?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let nsError = error as NSError?
        XCTAssertEqual(nsError?.domain, NSFileProviderErrorDomain, file: file, line: line)
        XCTAssertEqual(
            nsError?.code,
            NSFileProviderError.Code.pageExpired.rawValue,
            file: file,
            line: line
        )
    }
}

@available(macOS 26.0, *)
private final class SearchRequestStub: NSFileProviderStringSearchRequest {
    private let storedQuery: String
    private let storedDesiredNumberOfResults: Int

    override var query: String { storedQuery }
    override var desiredNumberOfResults: Int { storedDesiredNumberOfResults }

    /// 用只读覆写构造系统未公开初始化器的搜索请求测试替身。
    init(query: String, desiredNumberOfResults: Int) {
        storedQuery = query
        storedDesiredNumberOfResults = desiredNumberOfResults
        super.init()
    }
}

@available(macOS 26.0, *)
private final class SearchObserverStub: NSObject, NSFileProviderSearchEnumerationObserver, @unchecked Sendable {
    private struct State {
        var resultCount = 0
        var nextPage: NSFileProviderPage?
        var error: Error?
    }

    struct Snapshot {
        let resultCount: Int
        let nextPage: NSFileProviderPage?
        let error: Error?
    }

    let maximumNumberOfResultsPerPage: Int
    private let lock = NSLock()
    private let completion: XCTestExpectation?
    private var state = State()

    /// 每个 observer 只对应一次页回调，完成 expectation 用于异步测试等待。
    init(maximumResults: Int, completion: XCTestExpectation? = nil) {
        maximumNumberOfResultsPerPage = maximumResults
        self.completion = completion
    }

    /// 记录本页结果数量，具体元数据不参与分页协议断言。
    func didEnumerate(_ searchResults: [any NSFileProviderSearchResult]) {
        lock.withLock { state.resultCount += searchResults.count }
    }

    /// 保存下一页并结束本次成功枚举。
    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        lock.withLock { state.nextPage = nextPage }
        completion?.fulfill()
    }

    /// 保存系统错误并结束本次失败枚举。
    func finishEnumeratingWithError(_ error: any Error) {
        lock.withLock { state.error = error }
        completion?.fulfill()
    }

    /// 在线程安全边界内返回 observer 的不可变快照。
    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                resultCount: state.resultCount,
                nextPage: state.nextPage,
                error: state.error
            )
        }
    }
}

private actor SearchStoreSpy: ProviderSearchResultStoring {
    struct Call: Sendable {
        let recordCount: Int
        let appending: Bool
    }

    private var calls: [Call] = []

    /// 记录每页是否追加，验证第一页替换、续页追加的持久化语义。
    func storeSearchResults(
        _ records: [RemoteImageRecord],
        queryKey: String,
        appending: Bool
    ) async throws {
        calls.append(Call(recordCount: records.count, appending: appending))
    }

    /// 返回调用快照，避免测试跨 actor 读取可变数组。
    func snapshot() -> [Call] {
        calls
    }
}

private actor FiniteOpenverse: OpenverseSearching {
    /// 返回三页稳定记录，让测试可以检查连续两个系统页回调。
    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        ImageSearchPage(
            records: makeSearchRecords(page: page, count: pageSize),
            nextPage: page < 3 ? page + 1 : nil
        )
    }
}

/// 让测试可以在两次系统枚举之间切换数据源配置，并观察旧令牌是否触发网络请求。
private actor RevisionedPhotoSearcher: PhotoSearching {
    private var revision: UInt64 = 1
    private var callCount = 0

    func configurationKey() async -> String {
        "sources:\(revision):openverse"
    }

    func search(
        query: String,
        cursor: PhotoSearchCursor?,
        pageSize: Int
    ) async throws -> PhotoSearchPage {
        callCount += 1
        return try await searcher().search(query: query, cursor: cursor, pageSize: pageSize)
    }

    func search(query: String, page: Int, pageSize: Int) async throws -> PhotoSearchPage {
        callCount += 1
        return try await searcher().search(query: query, page: page, pageSize: pageSize)
    }

    func setRevision(_ value: UInt64) {
        revision = value
    }

    func recordedCallCount() -> Int {
        callCount
    }

    private func searcher() -> AggregatedPhotoSearcher {
        AggregatedPhotoSearcher(
            sources: [OpenversePhotoSource(client: FiniteOpenverse())],
            configurationRevision: revision
        )
    }
}

/// 构造同一逻辑页、不同 provider 位置的缓存键输入。
private func makeImageSearchCursor(sourcePage: String) -> ImageSearchCursor {
    ImageSearchCursor(
        page: 2,
        photoCursor: PhotoSearchCursor(
            configurationRevision: 1,
            states: [
                PhotoSourceCursorState(
                    sourceID: .openverse,
                    cursor: PhotoSourceCursor(rawValue: sourcePage),
                    pageSize: 20,
                    exhausted: false
                )
            ]
        )
    )
}

/// 为 File Provider 测试构造稳定、安全且每页不重复的远程记录。
private func makeSearchRecords(page: Int, count: Int) -> [RemoteImageRecord] {
    (0..<count).map { index in
        let url = URL(string: "https://example.com/\(page)-\(index).png")!
        return RemoteImageRecord(
            id: "search-\(page)-\(index)",
            title: "Search \(page)-\(index)",
            source: .openverse,
            imageURL: url,
            thumbnailURL: url,
            license: .cc0
        )
    }
}
