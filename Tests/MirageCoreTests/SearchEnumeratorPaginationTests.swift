import FileProvider
import Foundation
import MirageCore
import XCTest

@available(macOS 26.0, *)
final class SearchEnumeratorPaginationTests: XCTestCase {
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
            query: "cat"
        )
        let crossQueryPage = NSFileProviderPage(rawValue: try current.encoded())
        XCTAssertThrowsError(
            try SearchPagePlanner.cursor(
                startingAt: crossQueryPage,
                request: SearchRequestStub(query: "dog", desiredNumberOfResults: 20),
                observer: observer
            )
        ) { self.assertPageExpired($0) }

        let expired = try SearchPaginationCursor(
            page: 2,
            pageSize: 20,
            delivered: 20,
            query: "cat",
            issuedAt: Date().addingTimeInterval(-SearchPaginationCursor.maximumAge - 1)
        )
        let expiredPage = NSFileProviderPage(rawValue: try expired.encoded())
        XCTAssertThrowsError(
            try SearchPagePlanner.cursor(
                startingAt: expiredPage,
                request: SearchRequestStub(query: "cat", desiredNumberOfResults: 20),
                observer: observer
            )
        ) { self.assertPageExpired($0) }
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
