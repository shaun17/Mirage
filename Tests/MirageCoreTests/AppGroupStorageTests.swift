import Foundation
import XCTest
@testable import MirageCore

final class AppGroupStorageTests: XCTestCase {
    private var temporaryURL: URL!

    /// 每个测试使用独立目录，避免磁盘状态影响结果。
    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    }

    /// 测试结束后删除本测试创建的临时目录。
    override func tearDownWithError() throws {
        if let temporaryURL, FileManager.default.fileExists(atPath: temporaryURL.path) {
            try FileManager.default.removeItem(at: temporaryURL)
        }
    }

    /// 并发写入不能丢记录、产生半个 JSON，读取顺序必须稳定。
    func testConcurrentRecentWritesAndLimit() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let date = Date(timeIntervalSince1970: 1_000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<25 {
                group.addTask {
                    try await storage.writeRecent(Self.record(index), at: date, limit: 100)
                }
            }
            try await group.waitForAll()
        }

        let recent = try await storage.readRecent(limit: 10)
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.map(\.id), recent.map(\.id).sorted())
        let files = try FileManager.default.contentsOfDirectory(
            at: temporaryURL.appendingPathComponent("recent"), includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, 25)
    }

    /// 两个 actor 实例共享同一目录时，写入与裁剪必须形成跨进程等价的完整事务。
    func testConcurrentRecentTransactionsAcrossStorageInstancesRespectLimit() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let secondStorage = try AppGroupStorage(baseURL: temporaryURL)
        let limit = 10
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let storage = index.isMultiple(of: 2) ? firstStorage : secondStorage
                    try await storage.writeRecent(
                        Self.record(index),
                        at: Date(timeIntervalSince1970: TimeInterval(index)),
                        limit: limit
                    )
                }
            }
            try await group.waitForAll()
        }

        let recent = try await firstStorage.readRecent(limit: 100)
        XCTAssertEqual(recent.count, limit)
        XCTAssertEqual(recent.map(\.id), (30..<40).reversed().map { Self.record($0).id })
    }

    /// 批量清空 recent 只删除访问历史，不应删除底层图片元数据。
    func testClearRecentPreservesItems() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let first = Self.record(1)
        let second = Self.record(2)
        try await storage.writeRecent(first)
        try await storage.writeRecent(second)

        try await storage.clearRecent()

        let recent = try await storage.readRecent()
        let restoredFirst = try await storage.readItem(id: first.id)
        let restoredSecond = try await storage.readItem(id: second.id)
        XCTAssertTrue(recent.isEmpty)
        XCTAssertEqual(restoredFirst, first)
        XCTAssertEqual(restoredSecond, second)
    }

    /// 收藏去重应保留首次出现的顺序，且条目元数据独立可读。
    func testItemsAndFavoritesRoundTrip() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let first = Self.record(1)
        let second = Self.record(2)
        try await storage.writeItem(first)
        try await storage.writeItem(second)
        try await storage.writeFavoriteIDs([second.id, first.id, second.id])

        let loadedFirst = try await storage.readItem(id: first.id)
        let favoriteIDs = try await storage.readFavoriteIDs()
        let itemIDs = try await storage.readItems().map(\.id)
        XCTAssertEqual(loadedFirst, first)
        XCTAssertEqual(favoriteIDs, [second.id, first.id])
        XCTAssertEqual(itemIDs, [first.id, second.id])
    }

    /// 两个 storage 实例并发切换收藏也必须共享同一事务锁，不能丢失任何一次新增。
    func testConcurrentFavoriteTransactionsDoNotLoseUpdates() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let secondStorage = try AppGroupStorage(baseURL: temporaryURL)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<25 {
                group.addTask {
                    let storage = index.isMultiple(of: 2) ? firstStorage : secondStorage
                    _ = try await storage.toggleFavorite(Self.record(index))
                }
            }
            try await group.waitForAll()
        }

        let snapshot = try await firstStorage.readLibrarySnapshot()
        XCTAssertEqual(snapshot.favoriteIDs.count, 25)
        XCTAssertEqual(Set(snapshot.favorites.map(\.id)), snapshot.favoriteIDs)
    }

    /// 资料库快照只按收藏 ID 读取，损坏但未收藏的搜索缓存不能拖垮整个刷新。
    func testLibrarySnapshotIgnoresUnrelatedCorruptItem() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let favorite = Self.record(1)
        _ = try await storage.toggleFavorite(favorite)
        let corruptURL = temporaryURL
            .appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent("unrelated.json")
        try Data("not-json".utf8).write(to: corruptURL, options: .atomic)

        let first = try await storage.readLibrarySnapshot()
        let second = try await storage.readLibrarySnapshot()
        XCTAssertEqual(first.favorites, [favorite])
        XCTAssertGreaterThan(second.revision, first.revision)
    }

    /// 发现快照必须保留顺序、来源和查询 key，并在新 actor 中恢复同一个 generation。
    func testDiscoverySnapshotPersistsAcrossStorageRestart() async throws {
        let independentItem = Self.record(2, title: "全局记录")
        let records = [Self.record(2, title: "发现记录"), Self.record(1)]
        let refreshedAt = Date(timeIntervalSince1970: 2_000)
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        try await firstStorage.writeItem(independentItem)
        let committed = try await firstStorage.commitDiscoveryFeed(
            records: records,
            refreshedAt: refreshedAt,
            source: .network,
            catalogKey: "root-v1",
            queryKey: "portrait"
        )

        let restartedStorage = try AppGroupStorage(baseURL: temporaryURL)
        let restored = try await restartedStorage.readDiscoveryFeedSnapshot()
        let restoredItem = try await restartedStorage.readItem(id: records[0].id)
        XCTAssertEqual(restored, committed)
        XCTAssertEqual(restored?.records.map(\.id), records.map(\.id))
        XCTAssertEqual(restoredItem, independentItem)

        let next = try await restartedStorage.commitDiscoveryFeed(
            records: records,
            refreshedAt: refreshedAt.addingTimeInterval(60),
            source: .fallback,
            catalogKey: "root-v1",
            queryKey: "fallback-v1"
        )
        XCTAssertEqual(next.generation, committed.generation + 1)
    }

    /// 两个 storage 实例并发提交发现快照时，每次提交都必须获得唯一且连续的 generation。
    func testConcurrentDiscoveryCommitsAcrossStorageInstances() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let secondStorage = try AppGroupStorage(baseURL: temporaryURL)
        let commitCount = 30
        let generations = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for index in 0..<commitCount {
                group.addTask {
                    let storage = index.isMultiple(of: 2) ? firstStorage : secondStorage
                    let snapshot = try await storage.commitDiscoveryFeed(
                        records: [Self.record(index)],
                        refreshedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                        source: .network,
                        catalogKey: "root-v1",
                        queryKey: "query-\(index)"
                    )
                    return snapshot.generation
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        let restored = try await firstStorage.readDiscoveryFeedSnapshot()
        XCTAssertEqual(Set(generations), Set(1...UInt64(commitCount)))
        XCTAssertEqual(restored?.generation, UInt64(commitCount))
    }

    /// 当前指针丢失后仍须从持久高水位继续递增，不能复用已经发布过的 generation。
    func testDiscoveryGenerationHighWatermarkSurvivesCurrentPointerLoss() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let first = try await firstStorage.commitDiscoveryFeed(
            records: [Self.record(1)],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query
        )
        try FileManager.default.removeItem(
            at: temporaryURL.appendingPathComponent("discovery-feed.json")
        )

        let restartedStorage = try AppGroupStorage(baseURL: temporaryURL)
        let second = try await restartedStorage.commitDiscoveryFeed(
            records: [Self.record(2)],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query
        )
        let restored = try await restartedStorage.readDiscoveryFeedSnapshot()

        XCTAssertEqual(second.generation, first.generation + 1)
        XCTAssertEqual(restored?.generation, second.generation)
    }

    /// generation 达到 UInt64 上限后必须显式失败，不能使用回绕值覆盖旧快照。
    func testDiscoveryGenerationExhaustionDoesNotWrap() async throws {
        let stateURL = temporaryURL.appendingPathComponent("discovery-generation.json")
        let stateData = Data(
            "{\"highWatermark\":18446744073709551615,\"schemaVersion\":1}".utf8
        )
        try stateData.write(to: stateURL, options: .atomic)
        let storage = try AppGroupStorage(baseURL: temporaryURL)

        do {
            _ = try await storage.commitDiscoveryFeed(
                records: [Self.record(1)],
                refreshedAt: Date(),
                source: .network,
                catalogKey: DiscoveryRecommendation.catalogKey,
                queryKey: DiscoveryRecommendation.query
            )
            XCTFail("generation 耗尽后不得继续提交")
        } catch let error as DiscoveryFeedStorageError {
            XCTAssertEqual(error, .generationExhausted)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryURL.appendingPathComponent("discovery-feed.json").path
            )
        )
    }

    /// 两个实例竞争同一发现页时只能提交一份记录，输家必须返回赢家已经落盘的快照和游标。
    func testConcurrentDiscoveryAppendsUsePageAndOffsetCASAcrossStorageInstances() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let secondStorage = try AppGroupStorage(baseURL: temporaryURL)
        let pageSize = DiscoveryRecommendation.pageSize
        let firstPage = (0..<pageSize).map { Self.record($0) }
        let committed = try await firstStorage.commitDiscoveryFeed(
            records: firstPage,
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            pageSize: pageSize,
            nextPage: 2
        )
        let firstCandidate = (pageSize..<(pageSize * 2)).map { Self.record($0) }
        let secondCandidate = ((pageSize * 2)..<(pageSize * 3)).map { Self.record($0) }

        async let firstResult = firstStorage.appendDiscoveryFeed(
            generation: committed.generation,
            expectedNextPage: 2,
            expectedRecordCount: pageSize,
            records: firstCandidate,
            nextPage: 3
        )
        async let secondResult = secondStorage.appendDiscoveryFeed(
            generation: committed.generation,
            expectedNextPage: 2,
            expectedRecordCount: pageSize,
            records: secondCandidate,
            nextPage: 7
        )
        let results = try await [firstResult, secondResult]
        let restored = try await firstStorage.readDiscoveryFeedSnapshot(
            generation: committed.generation
        )
        let winner = try XCTUnwrap(restored)
        let appendedIDs = Array(winner.records.dropFirst(pageSize).map(\.id))

        XCTAssertEqual(results, [winner, winner])
        XCTAssertEqual(winner.records.count, pageSize * 2)
        if winner.nextPage == 3 {
            XCTAssertEqual(appendedIDs, firstCandidate.map(\.id))
        } else {
            XCTAssertEqual(winner.nextPage, 7)
            XCTAssertEqual(appendedIDs, secondCandidate.map(\.id))
        }
    }

    /// 搜索索引与单条元数据一起持久化，扩展重启后仍按原顺序恢复 backing。
    func testSearchBackingPersistsAcrossStorageRestart() async throws {
        let records = [Self.record(3), Self.record(1), Self.record(2)]
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        try await storage.commitSearchBacking(queryKey: "cat", records: records)

        let restartedStorage = try AppGroupStorage(baseURL: temporaryURL)
        let restored = try await restartedStorage.readSearchBackingRecords()
        XCTAssertEqual(restored.map(\.id), records.map(\.id))
    }

    /// 同一查询的后续页应累计去重，新查询仍然替换当前搜索 backing。
    func testSearchBackingAppendsPagesForSameQuery() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let first = [Self.record(1), Self.record(2)]
        let second = [Self.record(2), Self.record(3)]
        try await storage.commitSearchBacking(queryKey: "cat", records: first)
        try await storage.commitSearchBacking(queryKey: "cat", records: second, appending: true)
        let appended = try await storage.readSearchBackingRecords()
        XCTAssertEqual(appended.map(\.id), [
            Self.record(1).id, Self.record(2).id, Self.record(3).id
        ])

        try await storage.commitSearchBacking(queryKey: "dog", records: [Self.record(4)], appending: true)
        let replaced = try await storage.readSearchBackingRecords()
        XCTAssertEqual(replaced, [Self.record(4)])
    }

    /// 新查询替换当前 backing 后，旧搜索 occurrence 仍须通过独立权威记录回查。
    func testSearchRecordsSurviveLaterBackingReplacementAcrossInstances() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let secondStorage = try AppGroupStorage(baseURL: temporaryURL)
        let oldRecord = Self.record(1, title: "旧查询记录")
        let newRecord = Self.record(2, title: "新查询记录")

        try await firstStorage.commitSearchBacking(queryKey: "old", records: [oldRecord])
        try await secondStorage.commitSearchBacking(queryKey: "new", records: [newRecord])

        let active = try await firstStorage.readSearchBackingRecords()
        let restoredOld = try await secondStorage.readSearchRecord(id: oldRecord.id)
        let restoredNew = try await firstStorage.readSearchRecord(id: newRecord.id)
        XCTAssertEqual(active, [newRecord])
        XCTAssertEqual(restoredOld, oldRecord)
        XCTAssertEqual(restoredNew, newRecord)
    }

    /// 收藏和搜索遇到同一 ID 时必须各自保留提交时的元数据，不受全局 item 后写覆盖。
    func testFavoriteAndSearchSnapshotsIsolateMetadataForSameID() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let favorite = Self.record(7, title: "收藏版本")
        let search = Self.record(7, title: "搜索版本")
        let global = Self.record(7, title: "全局后写版本")

        _ = try await storage.toggleFavorite(favorite)
        try await storage.commitSearchBacking(queryKey: "same-id", records: [search])
        try await storage.writeItem(global)

        let favoriteRecords = try await storage.readFavoriteRecords()
        let searchRecords = try await storage.readSearchBackingRecords()
        let library = try await storage.readLibrarySnapshot()
        XCTAssertEqual(favoriteRecords, [favorite])
        XCTAssertEqual(searchRecords, [search])
        XCTAssertEqual(library.favorites, [favorite])
    }

    /// 旧 favorites.json 的 [String] 格式应回填一次记录并迁移，之后不再跟随全局 item 改写。
    func testLegacyFavoriteIDsMigrateToAuthoritativeRecords() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let first = Self.record(1, title: "迁移收藏一")
        let second = Self.record(2, title: "迁移收藏二")
        try await storage.writeItem(first)
        try await storage.writeItem(second)
        let favoritesURL = temporaryURL.appendingPathComponent("favorites.json")
        try JSONEncoder().encode([second.id, first.id]).write(to: favoritesURL, options: .atomic)

        let migrated = try await storage.readFavoriteRecords()
        try await storage.writeItem(Self.record(2, title: "全局覆盖"))
        let restored = try await storage.readFavoriteRecords()
        let migratedIDs = try await storage.readFavoriteIDs()
        XCTAssertEqual(migrated, [second, first])
        XCTAssertEqual(restored, [second, first])
        XCTAssertEqual(migratedIDs, [second.id, first.id])
    }

    /// 旧 search-backing.json 的 recordIDs 格式应迁移为记录快照并脱离全局 item。
    func testLegacySearchBackingMigratesToAuthoritativeRecords() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let first = Self.record(1, title: "迁移搜索一")
        let second = Self.record(2, title: "迁移搜索二")
        try await storage.writeItem(first)
        try await storage.writeItem(second)
        let legacy = LegacySearchBackingFixture(
            queryKey: "legacy",
            recordIDs: [first.id, second.id],
            committedAt: Date(timeIntervalSince1970: 123)
        )
        let backingURL = temporaryURL.appendingPathComponent("search-backing.json")
        try JSONEncoder().encode(legacy).write(to: backingURL, options: .atomic)

        let migrated = try await storage.readSearchBackingRecords()
        try await storage.writeItem(Self.record(1, title: "全局覆盖"))
        let restored = try await storage.readSearchBackingRecords()
        XCTAssertEqual(migrated, [first, second])
        XCTAssertEqual(restored, [first, second])
    }

    /// generation 必须跨 actor 重启继续递增，差异同时包含删除、新增与元数据变化。
    func testProviderAnchorAndDiffPersistAcrossRestart() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let initialAnchor = try await firstStorage.commitProviderScope(
            "root",
            items: [
                ProviderStoredItemState(identifier: "discover:a", fingerprint: "v1"),
                ProviderStoredItemState(identifier: "discover:b", fingerprint: "v1")
            ]
        )

        let restartedStorage = try AppGroupStorage(baseURL: temporaryURL)
        let restoredAnchor = try await restartedStorage.currentProviderAnchor()
        XCTAssertEqual(restoredAnchor, initialAnchor)
        let nextAnchor = try await restartedStorage.commitProviderScope(
            "root",
            items: [
                ProviderStoredItemState(identifier: "discover:b", fingerprint: "v2"),
                ProviderStoredItemState(identifier: "discover:c", fingerprint: "v1")
            ]
        )
        let changes = try await restartedStorage.providerChanges(in: "root", after: initialAnchor)
        XCTAssertGreaterThan(nextAnchor, initialAnchor)
        XCTAssertEqual(changes.anchor, nextAnchor)
        XCTAssertEqual(changes.deletedIdentifiers, ["discover:a"])
        XCTAssertEqual(changes.updatedIdentifiers, ["discover:b", "discover:c"])
    }

    /// scope 成员查询只能命中已提交快照中的稳定 ID。
    func testProviderScopeContainsOnlyCommittedMembers() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        _ = try await storage.commitProviderScope(
            "scope-membership",
            items: [
                ProviderStoredItemState(identifier: "discover:a", fingerprint: "v1"),
                ProviderStoredItemState(
                    identifier: "discover-page:v3:2",
                    fingerprint: "generation:41",
                    discoveryGeneration: 41
                )
            ]
        )

        let containsPublishedDirectory = try await storage.providerScope(
            "scope-membership",
            contains: "discover-page:v3:2"
        )
        let containsUnpublishedDirectory = try await storage.providerScope(
            "scope-membership",
            contains: "discover-page:v3:3"
        )
        let missingScopeContainsDirectory = try await storage.providerScope(
            "discovery:v3:2",
            contains: "discover-page:v3:3"
        )
        XCTAssertTrue(containsPublishedDirectory)
        XCTAssertFalse(containsUnpublishedDirectory)
        XCTAssertFalse(missingScopeContainsDirectory)
        let committedSnapshot = try await storage.providerScopeSnapshot("scope-membership")
        let committed = try XCTUnwrap(committedSnapshot)
        XCTAssertEqual(committed.count, 2)
        XCTAssertNil(committed[0].discoveryGeneration)
        XCTAssertEqual(committed[1].discoveryGeneration, 41)
        let missingSnapshot = try await storage.providerScopeSnapshot("discovery:v3:2")
        XCTAssertNil(missingSnapshot)
    }

    /// 条件提交必须在跨进程锁内观察最新权威代次；失败时既不能写子 scope，也不能推进已打开深度。
    func testConditionalProviderCommitRejectsLateGenerationAcrossStorageInstances() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let secondStorage = try AppGroupStorage(baseURL: temporaryURL)
        let page2 = "discover-page:v3:2"
        _ = try await firstStorage.commitProviderScope(
            "root",
            items: [
                ProviderStoredItemState(
                    identifier: page2,
                    fingerprint: "generation:41",
                    discoveryGeneration: 41
                )
            ]
        )
        _ = try await secondStorage.commitProviderScope(
            "working-set",
            items: [
                ProviderStoredItemState(
                    identifier: page2,
                    fingerprint: "generation:42",
                    discoveryGeneration: 42
                )
            ]
        )
        let staleCommit = ProviderStoredScopeCommit(
            scope: "discovery:v3:2",
            items: [
                ProviderStoredItemState(
                    identifier: "discover-page-item:v3:2:old",
                    fingerprint: "old",
                    discoveryGeneration: 41
                )
            ]
        )

        do {
            _ = try await firstStorage.commitProviderScopes(
                [staleCommit],
                requiring: [
                    ProviderPublicationRequirement(
                        candidateScopes: ["root", "working-set"],
                        itemIdentifier: page2,
                        expectedDiscoveryGeneration: 41
                    )
                ],
                openedDiscoveryPage: 2
            )
            XCTFail("迟到旧代次不应覆盖当前权威 scope")
        } catch let error as ProviderPublicationError {
            XCTAssertEqual(error, .staleLineage)
        }
        let rejectedScope = try await firstStorage.providerScopeSnapshot("discovery:v3:2")
        let rejectedOpenedPage = try await firstStorage.maximumOpenedProviderDiscoveryPage()
        XCTAssertNil(rejectedScope)
        XCTAssertNil(rejectedOpenedPage)

        let currentCommit = ProviderStoredScopeCommit(
            scope: "discovery:v3:2",
            items: [
                ProviderStoredItemState(
                    identifier: "discover-page-item:v3:2:new",
                    fingerprint: "new",
                    discoveryGeneration: 42
                )
            ]
        )
        _ = try await firstStorage.commitProviderScopes(
            [currentCommit],
            requiring: [
                ProviderPublicationRequirement(
                    candidateScopes: ["root", "working-set"],
                    itemIdentifier: page2,
                    expectedDiscoveryGeneration: 42
                )
            ],
            openedDiscoveryPage: 2
        )
        let restartedStorage = try AppGroupStorage(baseURL: temporaryURL)
        let restoredOpenedPage = try await restartedStorage.maximumOpenedProviderDiscoveryPage()
        XCTAssertEqual(restoredOpenedPage, 2)
    }

    /// 全局前缀查询必须跨 scope 去重，并且不受 scope 提交顺序影响。
    func testProviderItemIdentifiersMatchingPrefixAreUniqueAndSorted() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        _ = try await storage.commitProviderScope(
            "prefix-query-scope",
            items: [
                ProviderStoredItemState(identifier: "discover-page:v3:4", fingerprint: "v1"),
                ProviderStoredItemState(identifier: "search:other", fingerprint: "v1"),
                ProviderStoredItemState(identifier: "discover-page:v3:3", fingerprint: "v1")
            ]
        )
        _ = try await storage.commitProviderScope(
            "root",
            items: [
                ProviderStoredItemState(identifier: "discover-page:v3:2", fingerprint: "v1"),
                ProviderStoredItemState(identifier: "discover-page:v3:3", fingerprint: "v2")
            ]
        )

        let identifiers = try await storage.providerItemIdentifiers(
            matchingPrefix: "discover-page:v3:"
        )
        XCTAssertEqual(
            identifiers,
            ["discover-page:v3:2", "discover-page:v3:3", "discover-page:v3:4"]
        )
        let missingIdentifiers = try await storage.providerItemIdentifiers(matchingPrefix: "missing:")
        XCTAssertTrue(missingIdentifiers.isEmpty)
    }

    /// 两个 storage 实例并发提交不同 scope 时，全局 generation 与每个 scope 都不能丢失。
    func testConcurrentProviderCommitsAcrossStorageInstances() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let secondStorage = try AppGroupStorage(baseURL: temporaryURL)
        let initialAnchor = try await firstStorage.currentProviderAnchor()
        let commitCount = 30
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<commitCount {
                group.addTask {
                    let storage = index.isMultiple(of: 2) ? firstStorage : secondStorage
                    _ = try await storage.commitProviderScope(
                        "scope-\(index)",
                        items: [
                            ProviderStoredItemState(
                                identifier: "item-\(index)",
                                fingerprint: "v1"
                            )
                        ]
                    )
                }
            }
            try await group.waitForAll()
        }

        let finalAnchor = try await firstStorage.currentProviderAnchor()
        XCTAssertEqual(finalAnchor, initialAnchor + UInt64(commitCount))
        for index in 0..<commitCount {
            let changes = try await secondStorage.providerChanges(
                in: "scope-\(index)",
                after: initialAnchor
            )
            XCTAssertEqual(changes.updatedIdentifiers, ["item-\(index)"])
        }
    }

    /// 符号链接别名必须映射到同一进程锁，否则多个 storage actor 会在同一文件上丢提交。
    func testSymlinkedBaseURLsShareSameProcessTransactionLock() async throws {
        let realURL = temporaryURL.appendingPathComponent("real-group", isDirectory: true)
        let aliasURL = temporaryURL.appendingPathComponent("alias-group", isDirectory: true)
        try FileManager.default.createDirectory(at: realURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: realURL)
        let realStorage = try AppGroupStorage(baseURL: realURL)
        let aliasStorage = try AppGroupStorage(baseURL: aliasURL)
        let initialAnchor = try await realStorage.currentProviderAnchor()
        let commitCount = 80

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<commitCount {
                group.addTask {
                    let storage = index.isMultiple(of: 2) ? realStorage : aliasStorage
                    _ = try await storage.commitProviderScope(
                        "alias-scope-\(index)",
                        items: [
                            ProviderStoredItemState(
                                identifier: "alias-item-\(index)",
                                fingerprint: "v1"
                            )
                        ]
                    )
                }
            }
            try await group.waitForAll()
        }
        let finalAnchor = try await aliasStorage.currentProviderAnchor()

        XCTAssertEqual(finalAnchor, initialAnchor + UInt64(commitCount))
        for index in 0..<commitCount {
            let changes = try await realStorage.providerChanges(
                in: "alias-scope-\(index)",
                after: initialAnchor
            )
            XCTAssertEqual(changes.updatedIdentifiers, ["alias-item-\(index)"])
        }
    }

    /// provider 状态损坏后应保留原始字节、过期旧锚点，并允许全量快照重新建立差异历史。
    func testCorruptProviderStateRecoversForFullEnumeration() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let oldAnchor = try await firstStorage.commitProviderScope(
            "root",
            items: [ProviderStoredItemState(identifier: "old", fingerprint: "v1")]
        )
        let stateURL = temporaryURL.appendingPathComponent("provider-sync-state.json")
        let corruptData = Data("{broken-provider-state".utf8)
        try corruptData.write(to: stateURL, options: .atomic)

        let restartedStorage = try AppGroupStorage(baseURL: temporaryURL)
        let recoveryAnchor = try await restartedStorage.currentProviderAnchor()
        XCTAssertGreaterThan(recoveryAnchor, oldAnchor)
        do {
            _ = try await restartedStorage.providerChanges(in: "root", after: oldAnchor)
            XCTFail("恢复前的 provider anchor 必须明确过期")
        } catch let error as ProviderChangeStorageError {
            XCTAssertEqual(error, .anchorExpired)
        }

        let recoveredItems = [
            ProviderStoredItemState(identifier: "new-a", fingerprint: "v1"),
            ProviderStoredItemState(identifier: "new-b", fingerprint: "v1")
        ]
        _ = try await restartedStorage.commitProviderScope("root", items: recoveredItems)
        let changes = try await restartedStorage.providerChanges(in: "root", after: recoveryAnchor)
        XCTAssertEqual(changes.updatedIdentifiers, ["new-a", "new-b"])

        let archivedURLs = try FileManager.default.contentsOfDirectory(
            at: temporaryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("provider-sync-state.invalid-") }
        XCTAssertEqual(archivedURLs.count, 1)
        let archivedURL = try XCTUnwrap(archivedURLs.first)
        XCTAssertEqual(try Data(contentsOf: archivedURL), corruptData)
    }

    /// 缺少当前 schemaVersion 的旧 provider 文件也应升级纪元，而不是永久解码失败。
    func testLegacyProviderSchemaExpiresOldAnchorAndRecovers() async throws {
        let oldAnchor: UInt64 = 77
        let legacyData = Data("{\"generation\":77,\"scopes\":{}}".utf8)
        let stateURL = temporaryURL.appendingPathComponent("provider-sync-state.json")
        try legacyData.write(to: stateURL, options: .atomic)

        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let recoveryAnchor = try await storage.currentProviderAnchor()
        XCTAssertGreaterThan(recoveryAnchor, oldAnchor)
        do {
            _ = try await storage.providerChanges(in: "root", after: oldAnchor)
            XCTFail("旧 schema 的 anchor 必须明确过期")
        } catch let error as ProviderChangeStorageError {
            XCTAssertEqual(error, .anchorExpired)
        }
        _ = try await storage.commitProviderScope(
            "root",
            items: [ProviderStoredItemState(identifier: "restored", fingerprint: "v1")]
        )
        let changes = try await storage.providerChanges(in: "root", after: recoveryAnchor)
        XCTAssertEqual(changes.updatedIdentifiers, ["restored"])
    }

    /// schema v2 发布树不能泄漏到 v3：旧锚点过期，旧 scope 与成员索引同时清空。
    func testProviderSchema2ExpiresOldAnchorAndClearsPublishedScopes() async throws {
        let oldAnchor: UInt64 = 77
        let schema2Data = Data(
            """
            {"schemaVersion":2,"generation":77,"minimumValidAnchor":0,"scopes":{"root":{"items":[{"identifier":"discover-page:v2:2","fingerprint":"generation:9"}],"history":[],"minimumValidAnchor":0,"hasCommittedSnapshot":true}}}
            """.utf8
        )
        let stateURL = temporaryURL.appendingPathComponent("provider-sync-state.json")
        try schema2Data.write(to: stateURL, options: .atomic)

        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let recoveryAnchor = try await storage.currentProviderAnchor()
        XCTAssertGreaterThan(recoveryAnchor, oldAnchor)
        let recoveredObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
                as? [String: Any]
        )
        XCTAssertEqual(recoveredObject["schemaVersion"] as? Int, 3)
        let containsLegacyDirectory = try await storage.providerScope(
            "root",
            contains: "discover-page:v2:2"
        )
        let legacyIdentifiers = try await storage.providerItemIdentifiers(
            matchingPrefix: "discover-page:v2:"
        )
        XCTAssertFalse(containsLegacyDirectory)
        XCTAssertTrue(legacyIdentifiers.isEmpty)
        do {
            _ = try await storage.providerChanges(in: "root", after: oldAnchor)
            XCTFail("schema v2 的 provider anchor 必须明确过期")
        } catch let error as ProviderChangeStorageError {
            XCTAssertEqual(error, .anchorExpired)
        }
    }

    /// 已写出的 schema v3 文件可能尚无 opened-depth 字段；新增可选状态必须原位兼容而非误判损坏。
    func testProviderSchema3WithoutOpenedDepthRemainsReadable() async throws {
        let stateURL = temporaryURL.appendingPathComponent("provider-sync-state.json")
        let schema3Data = Data(
            "{\"schemaVersion\":3,\"generation\":77,\"minimumValidAnchor\":0,\"scopes\":{}}".utf8
        )
        try schema3Data.write(to: stateURL, options: .atomic)

        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let anchor = try await storage.currentProviderAnchor()
        let openedPage = try await storage.maximumOpenedProviderDiscoveryPage()
        XCTAssertEqual(anchor, 77)
        XCTAssertNil(openedPage)
    }

    /// 已发布递归 scope 却没有 opened-depth 时无法重建完整前缀，必须使旧锚点过期。
    func testProviderSchema3DeepScopeWithoutOpenedDepthRecovers() async throws {
        let oldAnchor: UInt64 = 77
        let stateURL = temporaryURL.appendingPathComponent("provider-sync-state.json")
        let incompleteData = Data(
            """
            {"schemaVersion":3,"generation":77,"minimumValidAnchor":0,"scopes":{"discovery:v3:2":{"items":[{"identifier":"discover-page-item:v3:2:legacy","fingerprint":"v1","discoveryGeneration":41}],"history":[],"minimumValidAnchor":0,"hasCommittedSnapshot":true}}}
            """.utf8
        )
        try incompleteData.write(to: stateURL, options: .atomic)

        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let recoveryAnchor = try await storage.currentProviderAnchor()
        let openedPage = try await storage.maximumOpenedProviderDiscoveryPage()
        let recoveredScope = try await storage.providerScopeSnapshot("discovery:v3:2")

        XCTAssertGreaterThan(recoveryAnchor, oldAnchor)
        XCTAssertNil(openedPage)
        XCTAssertNil(recoveredScope)
        do {
            _ = try await storage.providerChanges(in: "working-set", after: oldAnchor)
            XCTFail("缺少 opened-depth 的递归状态必须使旧 anchor 过期")
        } catch let error as ProviderChangeStorageError {
            XCTAssertEqual(error, .anchorExpired)
        }
    }

    /// opened-depth 存在但递归成员没有 generation 时无法授权下一层，也必须完整恢复。
    func testProviderSchema3DeepScopeWithoutGenerationRecovers() async throws {
        let oldAnchor: UInt64 = 91
        let stateURL = temporaryURL.appendingPathComponent("provider-sync-state.json")
        let incompleteData = Data(
            """
            {"schemaVersion":3,"generation":91,"minimumValidAnchor":0,"maximumOpenedDiscoveryPage":2,"scopes":{"discovery:v3:2":{"items":[{"identifier":"discover-page-item:v3:2:legacy","fingerprint":"v1"}],"history":[],"minimumValidAnchor":0,"hasCommittedSnapshot":true}}}
            """.utf8
        )
        try incompleteData.write(to: stateURL, options: .atomic)

        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let recoveryAnchor = try await storage.currentProviderAnchor()
        let openedPage = try await storage.maximumOpenedProviderDiscoveryPage()
        let recoveredScope = try await storage.providerScopeSnapshot("discovery:v3:2")

        XCTAssertGreaterThan(recoveryAnchor, oldAnchor)
        XCTAssertNil(openedPage)
        XCTAssertNil(recoveredScope)
        do {
            _ = try await storage.providerChanges(in: "working-set", after: oldAnchor)
            XCTFail("缺少 generation lineage 的递归状态必须使旧 anchor 过期")
        } catch let error as ProviderChangeStorageError {
            XCTAssertEqual(error, .anchorExpired)
        }
    }

    /// 重复提交完全相同的 scope 不得制造虚假 generation 或刷新循环。
    func testUnchangedProviderScopeDoesNotAdvanceAnchor() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let items = [ProviderStoredItemState(identifier: "discover:a", fingerprint: "v1")]
        let first = try await storage.commitProviderScope("root", items: items)
        let second = try await storage.commitProviderScope("root", items: items)
        let changes = try await storage.providerChanges(in: "root", after: first)
        XCTAssertEqual(second, first)
        XCTAssertTrue(changes.deletedIdentifiers.isEmpty)
        XCTAssertTrue(changes.updatedIdentifiers.isEmpty)
    }

    /// 首次迁移把旧 search occurrence 报为删除，同时保留仍在当前索引中的 ID。
    func testInitialSearchMigrationDeletesOnlyGhostOccurrences() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let current = ProviderStoredItemState(identifier: "search:current", fingerprint: "v1")
        let anchorBeforeMigration = try await storage.currentProviderAnchor()
        _ = try await storage.commitProviderScope(
            "search",
            items: [current],
            initialDeletedIdentifiers: ["search:old", "search:current"]
        )
        let changes = try await storage.providerChanges(in: "search", after: anchorBeforeMigration)
        XCTAssertEqual(changes.deletedIdentifiers, ["search:old"])
        XCTAssertEqual(changes.updatedIdentifiers, ["search:current"])
    }

    /// 超出每个 scope 的历史窗口后旧锚点必须明确过期，不能静默返回不完整差异。
    func testProviderAnchorExpiresAfterHistoryWindow() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let oldAnchor = try await storage.currentProviderAnchor()
        for index in 0..<70 {
            _ = try await storage.commitProviderScope(
                "root",
                items: [ProviderStoredItemState(identifier: "discover:a", fingerprint: "v\(index)")]
            )
        }

        do {
            _ = try await storage.providerChanges(in: "root", after: oldAnchor)
            XCTFail("超出历史窗口的锚点不应继续返回部分差异")
        } catch let error as ProviderChangeStorageError {
            XCTAssertEqual(error, .anchorExpired)
        }
    }

    /// 创建结构完整、HTTPS 且稳定 ID 的测试记录，可覆盖标题验证同 ID 元数据隔离。
    private static func record(_ index: Int, title: String? = nil) -> RemoteImageRecord {
        RemoteImageRecord(
            id: String(format: "ov:00000000-0000-4000-8000-%012d", index),
            title: title ?? "Image \(index)",
            source: .openverse,
            imageURL: URL(string: "https://example.com/\(index).png")!,
            thumbnailURL: URL(string: "https://example.com/t\(index).png")!,
            license: .cc0,
            width: 512,
            height: 512,
            mimeType: "image/png"
        )
    }

    /// 模拟旧版只保存 recordIDs 的搜索 backing 文件。
    private struct LegacySearchBackingFixture: Encodable {
        let queryKey: String
        let recordIDs: [String]
        let committedAt: Date
    }
}
