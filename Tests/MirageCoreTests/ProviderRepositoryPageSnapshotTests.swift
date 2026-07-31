import FileProvider
import Foundation
import MirageCore
import UniformTypeIdentifiers
import XCTest

final class ProviderRepositoryPageSnapshotTests: XCTestCase {
    private var temporaryURL: URL!
    /// 泵会在后台继续写共享存储；不等它收敛就删临时目录会撞上权限错误。
    private var activePump: ProviderFeedPump?

    /// 每个测试使用独立目录，保证 generation 裁剪与目录发布状态互不干扰。
    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageProviderPageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    }

    /// 先让泵停下并收敛在途任务，再删除本用例创建的临时目录。
    override func tearDown() async throws {
        if let activePump {
            await activePump.disarm()
            await activePump.waitForPendingAdvance()
        }
        activePump = nil
        if let temporaryURL, FileManager.default.fileExists(atPath: temporaryURL.path) {
            try FileManager.default.removeItem(at: temporaryURL)
        }
    }

    /// 根目录是扁平推荐流：只有固定目录和图片，绝不再出现任何续页目录。
    func testPreparedRootPublishesFlatFeedWithoutContinuationDirectories() async throws {
        let context = try makeContext()
        let rootItems = try await context.catalog.preparedItems(for: .root)

        let images = rootItems.filter { $0.contentType == .png }
        XCTAssertEqual(images.count, DiscoveryRecommendation.pageSize)
        XCTAssertTrue(images.allSatisfy { $0.parentItemIdentifier == .rootContainer })
        XCTAssertTrue(Self.discoveryDirectories(in: rootItems).isEmpty)

        // 打开目录只应触达首页；后续页必须等到真实的可见信号。
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [1])
    }

    /// 关掉首屏保底后，没有可见信号的反复枚举绝不拉页——系统后台同步不会拖空远端。
    func testRepeatedRootEnumerationNeverAdvancesFeedOnItsOwn() async throws {
        let context = try makeContext()
        await context.pump.arm()

        for _ in 0..<3 {
            _ = try await context.catalog.preparedItems(for: .root)
            await context.pump.waitForPendingAdvance()
        }

        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [1])
    }

    /// 首次枚举必须就地补到保底线并一次返回。内容同步进系统副本后 macOS 不再回问扩展，
    /// 第一次返回多少，用户就只能滚多少——这是「滚动加载」能启动的前提。
    func testFirstRootEnumerationInlineFillsToMinimum() async throws {
        let context = try makeContext(minimumRootRecords: 60)

        let rootItems = try await context.catalog.preparedItems(for: .root)

        XCTAssertEqual(rootItems.filter { $0.contentType == .png }.count, 60)
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [1, 2, 3])
    }

    /// 就地补齐有页数上限，远端再长也不会把首次建域拖成无限等待。
    func testInlineFillIsBounded() async throws {
        let context = try makeContext(minimumRootRecords: 10_000)

        let rootItems = try await context.catalog.preparedItems(for: .root)

        // 首页 + 最多十页就地补齐。
        XCTAssertEqual(rootItems.filter { $0.contentType == .png }.count, 220)
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, Array(1...11))
    }

    /// 可见项滚到尾部水位时补一页，同一个根目录随之变长——这就是 Finder 里的滚动加载。
    func testVisibleTailAdvancesFeedAndGrowsTheSameDirectory() async throws {
        let context = try makeContext()
        await context.pump.arm()

        let firstRoot = try await context.catalog.preparedItems(for: .root)
        XCTAssertEqual(firstRoot.filter { $0.contentType == .png }.count, 20)

        // 模拟系统为列表尾部的可见条目请求缩略图。
        await context.pump.noteVisible(firstRoot.suffix(4).map(\.itemIdentifier))
        await context.pump.waitForPendingAdvance()

        let secondRoot = try await context.catalog.preparedItems(for: .root)
        let images = secondRoot.filter { $0.contentType == .png }
        XCTAssertEqual(images.count, 40)
        XCTAssertTrue(images.allSatisfy { $0.parentItemIdentifier == .rootContainer })
        // 前 20 张的标识必须原样保留，系统才会把新内容识别为追加而不是整目录替换。
        XCTAssertEqual(
            Array(images.prefix(20)).map(\.itemIdentifier),
            firstRoot.filter { $0.contentType == .png }.map(\.itemIdentifier)
        )
        XCTAssertTrue(Self.discoveryDirectories(in: secondRoot).isEmpty)

        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [1, 2])
    }

    /// 列表头部的可见条目属于正常浏览，不应该触发任何补页。
    func testVisibleHeadDoesNotAdvanceFeed() async throws {
        let context = try makeContext()
        await context.pump.arm()

        let firstRoot = try await context.catalog.preparedItems(for: .root)
        await context.pump.noteVisible(firstRoot.prefix(6).map(\.itemIdentifier))
        await context.pump.waitForPendingAdvance()

        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [1])
    }

    /// 旧完整快照首次读取时应按精确页边界迁移，不能把上一页成员混入当前页。
    func testLegacyGenerationMigratesToExactPageSnapshots() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let records = Self.records(prefix: "legacy", page: 1)
            + Self.records(prefix: "legacy", page: 2)
        let generation = try await storage.commitDiscoveryFeed(
            records: records,
            refreshedAt: Date(),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            nextPage: 3
        ).generation

        let storedFirst = try await storage.readDiscoveryPageSnapshot(
            generation: generation,
            page: 1
        )
        let storedSecond = try await storage.readDiscoveryPageSnapshot(
            generation: generation,
            page: 2
        )
        let first = try XCTUnwrap(storedFirst)
        let second = try XCTUnwrap(storedSecond)
        XCTAssertEqual(first.records.map(\.id), Array(records.prefix(20)).map(\.id))
        XCTAssertEqual(second.records.map(\.id), Array(records.dropFirst(20)).map(\.id))
        XCTAssertEqual(first.nextPage, 2)
        XCTAssertEqual(second.nextPage, 3)
    }

    /// 构造带可观测网络页序列的完整 Provider 依赖图，并接上真实增量泵。
    /// 默认关闭首屏保底，让每个用例只锁定自己关心的那一条触发路径。
    private func makeContext(
        limits: ProviderFeedPump.Limits = ProviderFeedPump.Limits(minimumPublishedItems: 0),
        minimumRootRecords: Int = 0
    ) throws -> ProviderTestContext {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let openverse = ProviderPagedOpenverse()
        let diceBear = DiceBearClient(styles: [.pixelArt])
        let feed = DiscoveryFeedRepository(
            storage: storage,
            service: ImageSearchService(openverse: openverse, diceBear: diceBear),
            diceBear: diceBear
        )
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: feed
        )
        let pump = ProviderFeedPump(
            advancer: ProviderSystemFeedAdvancer(repository: repository),
            limits: limits
        )
        activePump = pump
        return ProviderTestContext(
            storage: storage,
            openverse: openverse,
            repository: repository,
            catalog: ProviderCatalog(
                repository: repository,
                pump: pump,
                minimumRootRecords: minimumRootRecords
            ),
            pump: pump
        )
    }

    /// 根目录只允许最近使用、收藏和隐藏的搜索 backing 三个固定目录，不得有任何续页目录。
    private static func discoveryDirectories(in items: [ProviderItem]) -> [ProviderItem] {
        let fixed: Set<NSFileProviderItemIdentifier> = [
            ProviderIdentifiers.recent,
            ProviderIdentifiers.favorites,
            ProviderIdentifiers.searchBacking
        ]
        return items.filter { $0.contentType == .folder && !fixed.contains($0.itemIdentifier) }
    }

    /// 为测试生成固定 20 条、跨页不重复的远端记录。
    fileprivate static func records(prefix: String, page: Int) -> [RemoteImageRecord] {
        (0..<DiscoveryRecommendation.pageSize).map { index in
            let url = URL(string: "https://example.com/\(prefix)-\(page)-\(index).png")!
            return RemoteImageRecord(
                id: "\(prefix):\(page):\(index)",
                title: "\(prefix) \(page)-\(index)",
                source: .openverse,
                imageURL: url,
                thumbnailURL: url,
                license: .cc0
            )
        }
    }
}

/// 组合测试所需的存储、网络替身、File Provider 目录对象和增量泵。
private struct ProviderTestContext {
    let storage: AppGroupStorage
    let openverse: ProviderPagedOpenverse
    let repository: ProviderRepository
    let catalog: ProviderCatalog
    let pump: ProviderFeedPump
}

private actor ProviderPagedOpenverse: OpenverseSearching {
    private var pages: [Int] = []

    /// 每页返回 20 条并提供连续下一页，模拟 Finder 的推荐数据源。
    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        pages.append(page)
        return ImageSearchPage(
            records: ProviderRepositoryPageSnapshotTests.records(
                prefix: "provider",
                page: page
            ),
            nextPage: page + 1
        )
    }

    /// 返回实际联网页序列，用于验证未发布目录不会提前请求网络。
    func requestedPages() -> [Int] {
        pages
    }
}
