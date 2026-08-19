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

    /// 重建系统域只清理可再生成缓存，收藏、最近使用和当前推荐快照必须保留。
    func testResetFileProviderGeneratedCachesPreservesUserState() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let favorite = Self.record(1)
        let recent = Self.record(2)
        let staleAvatar = Self.record(3)
        let discovery = Self.record(4)
        _ = try await storage.toggleFavorite(favorite)
        try await storage.writeRecent(recent)
        try await storage.writeItem(staleAvatar)
        let feed = try await storage.commitDiscoveryFeed(
            records: [discovery],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            source: .network,
            catalogKey: "cache-reset",
            queryKey: "cache-reset",
            nextPage: nil
        )
        _ = try await storage.commitDiscoveryPageSnapshot(
            generation: feed.generation,
            page: 1,
            records: [discovery],
            nextPage: nil
        )

        try await storage.resetFileProviderGeneratedCaches()

        let favoritesAfterReset = try await storage.readFavoriteRecords()
        let recentAfterReset = try await storage.readRecent().map(\.image)
        let favoriteItemAfterReset = try await storage.readItem(id: favorite.id)
        let recentItemAfterReset = try await storage.readItem(id: recent.id)
        let staleAvatarAfterReset = try await storage.readItem(id: staleAvatar.id)
        let discoveryFeedAfterReset = try await storage.readDiscoveryFeedSnapshot()
        let discoveryRecordAfterReset = try await storage.readDiscoveryRecord(id: discovery.id)
        let persistedPageAfterReset = try await storage.readPersistedDiscoveryPageSnapshot(
            generation: feed.generation,
            page: 1
        )

        XCTAssertEqual(favoritesAfterReset, [favorite])
        XCTAssertEqual(recentAfterReset, [recent])
        XCTAssertNil(favoriteItemAfterReset)
        XCTAssertNil(recentItemAfterReset)
        XCTAssertNil(staleAvatarAfterReset)
        XCTAssertEqual(discoveryFeedAfterReset?.records, [discovery])
        XCTAssertEqual(discoveryRecordAfterReset, discovery)
        XCTAssertNil(persistedPageAfterReset)
    }

    /// 收藏标准副本按稳定 ID 落盘，并可由指向同一 App Group 的另一个 storage 实例读取。
    func testFavoriteRenditionPersistsAcrossStorageInstances() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let secondStorage = try AppGroupStorage(baseURL: temporaryURL)
        let favorite = Self.record(41)
        let rendition = try Self.favoriteRenditionPNG()
        _ = try await firstStorage.toggleFavorite(favorite)

        let committed = try await firstStorage.commitFavoriteRenditionIfFavorited(
            rendition,
            for: favorite
        )
        let restored = try await secondStorage.readFavoriteRendition(id: favorite.id)
        let versions = try await secondStorage.favoriteRenditionVersions()
        let singleVersion = try await secondStorage.favoriteRenditionVersion(id: favorite.id)
        let files = try FileManager.default.contentsOfDirectory(
            at: temporaryURL.appendingPathComponent("favorite-renditions-v1", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "png" }

        XCTAssertTrue(committed)
        XCTAssertEqual(restored, rendition)
        XCTAssertEqual(versions[favorite.id], StableImageID.dataHash(rendition))
        XCTAssertEqual(singleVersion, versions[favorite.id])
        XCTAssertEqual(files.count, 1)
        let key = files[0].deletingPathExtension().lastPathComponent
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertFalse(files[0].lastPathComponent.contains(favorite.id))
    }

    /// toggle 与幂等 remove 都必须删除副本；取消后的迟到下载不得重新写回文件。
    func testRemovingFavoriteDeletesRenditionAndRejectsLateCommit() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let secondStorage = try AppGroupStorage(baseURL: temporaryURL)
        let favorite = Self.record(42)
        let rendition = try Self.favoriteRenditionPNG()
        _ = try await firstStorage.toggleFavorite(favorite)
        let initialCommit = try await firstStorage.commitFavoriteRenditionIfFavorited(
            rendition,
            for: favorite
        )
        XCTAssertTrue(initialCommit)

        _ = try await secondStorage.toggleFavorite(favorite)

        let afterToggleRemoval = try await firstStorage.readFavoriteRendition(id: favorite.id)
        let lateCommit = try await firstStorage.commitFavoriteRenditionIfFavorited(
            rendition,
            for: favorite
        )
        XCTAssertNil(afterToggleRemoval)
        XCTAssertFalse(lateCommit)

        _ = try await firstStorage.toggleFavorite(favorite)
        let recommitted = try await firstStorage.commitFavoriteRenditionIfFavorited(
            rendition,
            for: favorite
        )
        XCTAssertTrue(recommitted)
        _ = try await secondStorage.removeFavorite(id: favorite.id)
        _ = try await firstStorage.removeFavorite(id: favorite.id)

        let afterDirectRemoval = try await secondStorage.readFavoriteRendition(id: favorite.id)
        XCTAssertNil(afterDirectRemoval)
        let files = try FileManager.default.contentsOfDirectory(
            at: temporaryURL.appendingPathComponent("favorite-renditions-v1", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "png" }
        XCTAssertTrue(files.isEmpty)
    }

    /// 同 ID 在取消后重新收藏了新快照时，旧下载任务不能抢先占用新收藏的本地副本。
    func testLateCommitFromOlderFavoriteSnapshotCannotPopulateReaddedFavorite() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let oldFavorite = Self.record(45)
        let refreshedFavorite = RemoteImageRecord(
            id: oldFavorite.id,
            title: oldFavorite.title,
            source: oldFavorite.source,
            imageURL: URL(string: "https://example.com/refreshed-full.jpg")!,
            thumbnailURL: URL(string: "https://example.com/refreshed-thumb.jpg")!,
            license: oldFavorite.license,
            width: oldFavorite.width,
            height: oldFavorite.height,
            mimeType: oldFavorite.mimeType
        )
        _ = try await storage.toggleFavorite(oldFavorite)
        _ = try await storage.removeFavorite(id: oldFavorite.id)
        _ = try await storage.toggleFavorite(refreshedFavorite)

        let staleCommit = try await storage.commitFavoriteRenditionIfFavorited(
            try Self.favoriteRenditionPNG(),
            for: oldFavorite
        )
        let availableIDsBeforeFreshCommit = try await storage.favoriteRenditionIDs()
        let freshCommit = try await storage.commitFavoriteRenditionIfFavorited(
            try Self.favoriteRenditionPNG(),
            for: refreshedFavorite
        )
        let availableIDsAfterFreshCommit = try await storage.favoriteRenditionIDs()

        XCTAssertFalse(staleCommit)
        XCTAssertFalse(availableIDsBeforeFreshCommit.contains(oldFavorite.id))
        XCTAssertTrue(freshCommit)
        XCTAssertTrue(availableIDsAfterFreshCommit.contains(oldFavorite.id))
    }

    /// GIPHY 收藏允许保存对象 ID，但来源策略禁止任何媒体副本落盘。
    func testGiphyFavoriteRejectsRenditionPersistence() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let giphyID = "rendition-policy"
        let favorite = RemoteImageRecord(
            id: StableImageID.giphy(id: giphyID),
            title: "GIPHY Favorite",
            source: .giphy,
            giphyContentType: .gif,
            giphyID: giphyID,
            imageURL: URL(string: "https://media1.giphy.com/media/rendition-policy/giphy.gif")!,
            thumbnailURL: URL(string: "https://media1.giphy.com/media/rendition-policy/200w.gif")!,
            sourcePageURL: URL(string: "https://giphy.com/gifs/rendition-policy")!,
            license: .giphy,
            mimeType: "image/gif"
        )
        _ = try await storage.toggleFavorite(favorite)

        let committed = try await storage.commitFavoriteRenditionIfFavorited(
            try Self.favoriteRenditionPNG(),
            for: favorite
        )

        XCTAssertFalse(committed)
        let stored = try await storage.readFavoriteRendition(id: favorite.id)
        XCTAssertNil(stored)
        let renditionDirectory = temporaryURL.appendingPathComponent(
            "favorite-renditions-v1",
            isDirectory: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: renditionDirectory.path))
    }

    /// File Provider 域重建只清理可再生成目录，不得删除用户收藏的本地标准副本。
    func testResetFileProviderGeneratedCachesPreservesFavoriteRendition() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let favorite = Self.record(43)
        let rendition = try Self.favoriteRenditionPNG()
        _ = try await storage.toggleFavorite(favorite)
        let committed = try await storage.commitFavoriteRenditionIfFavorited(
            rendition,
            for: favorite
        )
        XCTAssertTrue(committed)

        try await storage.resetFileProviderGeneratedCaches()

        let restored = try await storage.readFavoriteRendition(id: favorite.id)
        XCTAssertEqual(restored, rendition)
    }

    /// 提交和读取都执行硬大小上限与 PNG 边界校验，损坏数据不得进入共享缓存。
    func testFavoriteRenditionValidatesPNGAndMaximumBytes() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let favorite = Self.record(44)
        _ = try await storage.toggleFavorite(favorite)

        do {
            _ = try await storage.commitFavoriteRenditionIfFavorited(
                Data("not-png".utf8),
                for: favorite
            )
            XCTFail("损坏图片不应进入收藏副本")
        } catch {
            XCTAssertEqual(error as? FavoriteRenditionStorageError, .invalidPNG)
        }

        let tooLarge = Data(
            repeating: 0,
            count: AppGroupStorage.maximumFavoriteRenditionBytes + 1
        )
        do {
            _ = try await storage.commitFavoriteRenditionIfFavorited(tooLarge, for: favorite)
            XCTFail("超出上限的图片不应进入收藏副本")
        } catch {
            XCTAssertEqual(
                error as? FavoriteRenditionStorageError,
                .dataTooLarge(
                    actualBytes: tooLarge.count,
                    maximumBytes: AppGroupStorage.maximumFavoriteRenditionBytes
                )
            )
        }

        let rendition = try Self.favoriteRenditionPNG()
        let committed = try await storage.commitFavoriteRenditionIfFavorited(
            rendition,
            for: favorite
        )
        XCTAssertTrue(committed)
        do {
            _ = try await storage.readFavoriteRendition(
                id: favorite.id,
                maximumBytes: rendition.count - 1
            )
            XCTFail("读取也必须执行调用方给出的大小上限")
        } catch {
            XCTAssertEqual(
                error as? FavoriteRenditionStorageError,
                .dataTooLarge(
                    actualBytes: rendition.count,
                    maximumBytes: rendition.count - 1
                )
            )
        }
    }

    /// 删除 items 前必须把旧 ID-only 收藏与搜索快照迁移到各自的权威存储。
    func testResetFileProviderGeneratedCachesMigratesLegacyUserState() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let favorite = Self.record(5, title: "旧收藏")
        let search = Self.record(6, title: "旧搜索")
        try await storage.writeItem(favorite)
        try await storage.writeItem(search)
        try JSONEncoder().encode([favorite.id]).write(
            to: temporaryURL.appendingPathComponent("favorites.json"),
            options: .atomic
        )
        try JSONEncoder().encode(LegacySearchBackingFixture(
            queryKey: "legacy-reset",
            recordIDs: [search.id],
            committedAt: Date(timeIntervalSince1970: 123)
        )).write(
            to: temporaryURL.appendingPathComponent("search-backing.json"),
            options: .atomic
        )

        try await storage.resetFileProviderGeneratedCaches()

        let favoritesAfterReset = try await storage.readFavoriteRecords()
        let searchAfterReset = try await storage.readSearchBackingRecords()
        let searchableRecordAfterReset = try await storage.readSearchRecord(id: search.id)
        let favoriteItemAfterReset = try await storage.readItem(id: favorite.id)
        let searchItemAfterReset = try await storage.readItem(id: search.id)
        XCTAssertEqual(favoritesAfterReset, [favorite])
        XCTAssertEqual(searchAfterReset, [search])
        XCTAssertEqual(searchableRecordAfterReset, search)
        XCTAssertNil(favoriteItemAfterReset)
        XCTAssertNil(searchItemAfterReset)
    }

    /// 迁移 lease 必须阻止同进程的第二个 storage 实例进入，释放后才允许继续。
    func testFileProviderMigrationLeaseSerializesStorageInstances() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let secondStorage = try AppGroupStorage(baseURL: temporaryURL)
        let firstLease = try await firstStorage.acquireFileProviderMigrationLease()
        let probe = MigrationLeaseProbe()
        let started = expectation(description: "第二个 lease 已开始等待")
        let secondLeaseTask = Task {
            started.fulfill()
            let lease = try await secondStorage.acquireFileProviderMigrationLease()
            await probe.markAcquired()
            return lease
        }
        await fulfillment(of: [started], timeout: 1)
        try await Task.sleep(for: .milliseconds(50))
        let acquiredWhileLocked = await probe.acquired

        firstLease.release()
        let secondLease = try await secondLeaseTask.value
        let acquiredAfterRelease = await probe.acquired
        secondLease.release()

        XCTAssertFalse(acquiredWhileLocked)
        XCTAssertTrue(acquiredAfterRelease)
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

    /// GIPHY 收藏只能落盘对象 ID 和内部引用，媒体 URL 不得进入收藏或 items 快照。
    func testGiphyFavoritePersistsIdentifierWithoutMediaURLs() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let giphyID = "favorite123"
        let record = RemoteImageRecord(
            id: StableImageID.giphy(id: giphyID),
            title: "Favorite GIF",
            source: .giphy,
            giphyContentType: .gif,
            giphyID: giphyID,
            imageURL: URL(string: "https://media1.giphy.com/media/favorite123/giphy.gif")!,
            thumbnailURL: URL(string: "https://media1.giphy.com/media/favorite123/200w.gif")!,
            sourcePageURL: URL(string: "https://giphy.com/gifs/favorite123")!,
            license: .giphy,
            mimeType: "image/gif"
        )

        let snapshot = try await storage.toggleFavorite(record)
        let persisted = try XCTUnwrap(snapshot.favorites.first)
        let loadedItem = try await storage.readItem(id: record.id)
        let storedItem = try XCTUnwrap(loadedItem)
        let rawFavorites = try String(
            contentsOf: temporaryURL.appendingPathComponent("favorites.json"),
            encoding: .utf8
        )

        XCTAssertEqual(persisted.giphyID, giphyID)
        XCTAssertTrue(persisted.isGiphyFavoriteReference)
        XCTAssertEqual(storedItem, persisted)
        XCTAssertFalse(rawFavorites.contains("media1.giphy.com"))
        XCTAssertFalse(rawFavorites.contains("giphy.gif"))
        XCTAssertFalse(rawFavorites.contains("200w.gif"))
    }

    func testGiphyFavoriteWithoutPublicIdentifierIsRejected() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let record = RemoteImageRecord(
            id: "giphy:legacy",
            title: "Legacy GIF",
            source: .giphy,
            imageURL: URL(string: "https://media1.giphy.com/media/legacy/giphy.gif")!,
            thumbnailURL: URL(string: "https://media1.giphy.com/media/legacy/200w.gif")!,
            license: .giphy
        )

        do {
            _ = try await storage.toggleFavorite(record)
            XCTFail("缺少 GIPHY ID 的记录不应落盘")
        } catch {
            XCTAssertEqual(error as? FavoriteStorageError, .missingGiphyIdentifier)
        }
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

    /// 受限来源的遗留收藏使用幂等删除；重复点击不能像 toggle 一样把记录重新加入。
    func testRemoveFavoriteIsIdempotent() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let favorite = Self.record(1)
        _ = try await storage.toggleFavorite(favorite)

        let firstRemoval = try await storage.removeFavorite(id: favorite.id)
        let repeatedRemoval = try await storage.removeFavorite(id: favorite.id)

        XCTAssertFalse(firstRemoval.favoriteIDs.contains(favorite.id))
        XCTAssertFalse(repeatedRemoval.favoriteIDs.contains(favorite.id))
        XCTAssertTrue(repeatedRemoval.favorites.isEmpty)
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

    /// 重建系统文件域时只清空 provider 发布索引，用户内容缓存与推荐快照必须保留。
    func testResetProviderPublicationStateExpiresOldDomainWithoutClearingContent() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let oldPublicationEpoch = try await storage.currentProviderPublicationEpoch()
        let recentRecord = Self.record(1, title: "保留的最近图片")
        try await storage.writeRecent(recentRecord)
        let discoverySnapshot = try await storage.commitDiscoveryFeed(
            records: [Self.record(2, title: "保留的推荐图片")],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query
        )
        let pageDirectory = ProviderStoredItemState(
            identifier: "discover-page:v3:2",
            fingerprint: "generation:\(discoverySnapshot.generation)",
            discoveryGeneration: discoverySnapshot.generation
        )
        let pageImage = ProviderStoredItemState(
            identifier: "discover-page-item:v3:2:test",
            fingerprint: "v1",
            discoveryGeneration: discoverySnapshot.generation
        )
        let oldAnchor = try await storage.commitProviderScopes(
            [
                ProviderStoredScopeCommit(scope: "root", items: [pageDirectory]),
                ProviderStoredScopeCommit(scope: "discovery:v3:2", items: [pageImage])
            ],
            openedDiscoveryPage: 2
        )

        let resetAnchor = try await storage.resetProviderPublicationState()
        let resetPublicationEpoch = try await storage.currentProviderPublicationEpoch()
        let rootScopeAfterReset = try await storage.providerScopeSnapshot("root")
        let pageScopeAfterReset = try await storage.providerScopeSnapshot("discovery:v3:2")
        let openedPageAfterReset = try await storage.maximumOpenedProviderDiscoveryPage()
        XCTAssertGreaterThan(resetAnchor, oldAnchor)
        XCTAssertGreaterThan(resetPublicationEpoch, oldPublicationEpoch)
        XCTAssertNil(rootScopeAfterReset)
        XCTAssertNil(pageScopeAfterReset)
        XCTAssertNil(openedPageAfterReset)
        do {
            _ = try await storage.providerChanges(in: "root", after: oldAnchor)
            XCTFail("旧文件域的 provider anchor 必须明确过期")
        } catch let error as ProviderChangeStorageError {
            XCTAssertEqual(error, .anchorExpired)
        }

        let retainedRecent = try await storage.readRecent(limit: 10)
        let retainedDiscoverySnapshot = try await storage.readDiscoveryFeedSnapshot()
        let repeatedResetAnchor = try await storage.resetProviderPublicationState()
        let repeatedResetEpoch = try await storage.currentProviderPublicationEpoch()
        XCTAssertEqual(retainedRecent.map(\.id), [recentRecord.id])
        XCTAssertEqual(retainedDiscoverySnapshot, discoverySnapshot)
        XCTAssertGreaterThan(repeatedResetAnchor, resetAnchor)
        XCTAssertGreaterThan(repeatedResetEpoch, resetPublicationEpoch)
    }

    /// 即使 scope 仍为空，域重建前捕获的纪元也不能回填 root 或 working-set。
    func testProviderPublicationEpochRejectsLateRootAndWorkingSetCommitsAfterReset() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        _ = try await storage.resetProviderPublicationState()
        let staleEpoch = try await storage.currentProviderPublicationEpoch()
        _ = try await storage.resetProviderPublicationState()
        let currentEpoch = try await storage.currentProviderPublicationEpoch()
        XCTAssertGreaterThan(currentEpoch, staleEpoch)

        let lateCommits = [
            ProviderStoredScopeCommit(
                scope: "root",
                items: [ProviderStoredItemState(identifier: "late-root", fingerprint: "v1")]
            ),
            ProviderStoredScopeCommit(
                scope: "working-set",
                items: [ProviderStoredItemState(identifier: "late-working", fingerprint: "v1")]
            )
        ]
        do {
            _ = try await storage.commitProviderScopes(
                lateCommits,
                expectedPublicationEpoch: staleEpoch
            )
            XCTFail("域重建前开始的发布任务不应回填已清空 scope")
        } catch let error as ProviderPublicationError {
            XCTAssertEqual(error, .stalePublicationEpoch)
        }
        let rejectedRoot = try await storage.providerScopeSnapshot("root")
        let rejectedWorkingSet = try await storage.providerScopeSnapshot("working-set")
        XCTAssertNil(rejectedRoot)
        XCTAssertNil(rejectedWorkingSet)

        _ = try await storage.commitProviderScopes(
            lateCommits,
            expectedPublicationEpoch: currentEpoch
        )
        let committedRoot = try await storage.providerScopeSnapshot("root")
        let committedWorkingSet = try await storage.providerScopeSnapshot("working-set")
        XCTAssertEqual(committedRoot?.map(\.identifier), ["late-root"])
        XCTAssertEqual(committedWorkingSet?.map(\.identifier), ["late-working"])
    }

    /// 筛选失效只推进发布边界并拒绝迟到提交，既有 scope 在新枚举成功前仍作为 Finder 旧快照保留。
    func testAdvanceProviderPublicationEpochPreservesScopesAndRejectsLateCommit() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let root = ProviderStoredItemState(identifier: "discover:retained", fingerprint: "v1")
        let avatarPage = ProviderStoredItemState(
            identifier: "avatar-page:v2:2",
            fingerprint: "filter:old"
        )
        let initialAnchor = try await storage.commitProviderScopes([
            ProviderStoredScopeCommit(scope: "root", items: [root]),
            ProviderStoredScopeCommit(scope: "avatars:v4", items: [avatarPage]),
        ])
        let staleEpoch = try await storage.currentProviderPublicationEpoch()

        let advancedEpoch = try await storage.advanceProviderPublicationEpoch()
        let advancedAnchor = try await storage.currentProviderAnchor()
        XCTAssertGreaterThan(advancedEpoch, staleEpoch)
        XCTAssertGreaterThan(advancedAnchor, initialAnchor)
        XCTAssertEqual(advancedEpoch, advancedAnchor)
        let retainedRoot = try await storage.providerScopeSnapshot("root")
        let retainedAvatars = try await storage.providerScopeSnapshot("avatars:v4")
        XCTAssertEqual(retainedRoot, [root])
        XCTAssertEqual(retainedAvatars, [avatarPage])

        do {
            _ = try await storage.commitProviderScope(
                "root",
                items: [ProviderStoredItemState(identifier: "discover:late", fingerprint: "v1")],
                expectedPublicationEpoch: staleEpoch
            )
            XCTFail("筛选变化前开始的枚举不应覆盖保留快照")
        } catch let error as ProviderPublicationError {
            XCTAssertEqual(error, .stalePublicationEpoch)
        }
        let rootAfterRejectedCommit = try await storage.providerScopeSnapshot("root")
        XCTAssertEqual(rootAfterRejectedCommit, [root])

        let replacement = ProviderStoredItemState(
            identifier: "discover:current",
            fingerprint: "v2"
        )
        _ = try await storage.commitProviderScope(
            "root",
            items: [replacement],
            expectedPublicationEpoch: advancedEpoch
        )
        let currentRoot = try await storage.providerScopeSnapshot("root")
        XCTAssertEqual(currentRoot, [replacement])
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
        XCTAssertEqual(recoveredObject["schemaVersion"] as? Int, 4)
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

    /// 旧扩展写回的 schema v3 即使结构完整也必须开启新纪元并清空，不能绕过域重建屏障。
    func testProviderSchema3WriterOutputAlwaysRecoversIntoNewPublicationEpoch() async throws {
        let stateURL = temporaryURL.appendingPathComponent("provider-sync-state.json")
        let schema3Data = Data(
            "{\"schemaVersion\":3,\"generation\":77,\"minimumValidAnchor\":0,\"maximumOpenedDiscoveryPage\":null,\"scopes\":{\"root\":{\"items\":[{\"identifier\":\"legacy-root\",\"fingerprint\":\"v1\"}],\"history\":[],\"minimumValidAnchor\":0,\"hasCommittedSnapshot\":true}}}".utf8
        )
        try schema3Data.write(to: stateURL, options: .atomic)

        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let anchor = try await storage.currentProviderAnchor()
        let epoch = try await storage.currentProviderPublicationEpoch()
        let openedPage = try await storage.maximumOpenedProviderDiscoveryPage()
        let recoveredScope = try await storage.providerScopeSnapshot("root")
        let recoveredObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
                as? [String: Any]
        )
        XCTAssertGreaterThan(anchor, 77)
        XCTAssertEqual(epoch, anchor)
        XCTAssertNil(openedPage)
        XCTAssertNil(recoveredScope)
        XCTAssertEqual(recoveredObject["schemaVersion"] as? Int, 4)
        XCTAssertEqual((recoveredObject["publicationEpoch"] as? NSNumber)?.uint64Value, epoch)

        // 模拟仍存活的旧扩展在 v4 恢复后再次覆盖 schema3；下一次读取必须再次恢复新纪元。
        let legacyRewriteGeneration = anchor + 1
        let repeatedSchema3Data = Data(
            "{\"schemaVersion\":3,\"generation\":\(legacyRewriteGeneration),\"minimumValidAnchor\":0,\"maximumOpenedDiscoveryPage\":null,\"scopes\":{\"working-set\":{\"items\":[{\"identifier\":\"legacy-working\",\"fingerprint\":\"v1\"}],\"history\":[],\"minimumValidAnchor\":0,\"hasCommittedSnapshot\":true}}}".utf8
        )
        try repeatedSchema3Data.write(to: stateURL, options: .atomic)

        let restartedStorage = try AppGroupStorage(baseURL: temporaryURL)
        let repeatedAnchor = try await restartedStorage.currentProviderAnchor()
        let repeatedEpoch = try await restartedStorage.currentProviderPublicationEpoch()
        let repeatedScope = try await restartedStorage.providerScopeSnapshot("working-set")
        XCTAssertGreaterThan(repeatedAnchor, legacyRewriteGeneration)
        XCTAssertGreaterThan(repeatedEpoch, epoch)
        XCTAssertEqual(repeatedEpoch, repeatedAnchor)
        XCTAssertNil(repeatedScope)
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

    private static func favoriteRenditionPNG() throws -> Data {
        try ImageTranscoder().transcode(sourcePNG)
    }

    private static let sourcePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    /// 模拟旧版只保存 recordIDs 的搜索 backing 文件。
    private struct LegacySearchBackingFixture: Encodable {
        let queryKey: String
        let recordIDs: [String]
        let committedAt: Date
    }
}

private actor MigrationLeaseProbe {
    private(set) var acquired = false

    func markAcquired() {
        acquired = true
    }
}
