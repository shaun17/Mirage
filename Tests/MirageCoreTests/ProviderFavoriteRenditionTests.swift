import CoreGraphics
import FileProvider
import Foundation
import ImageIO
import MirageCore
import XCTest

final class ProviderFavoriteRenditionTests: XCTestCase {
    private var temporaryURL: URL!

    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageFavoriteRendition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryURL, FileManager.default.fileExists(atPath: temporaryURL.path) {
            try FileManager.default.removeItem(at: temporaryURL)
        }
    }

    /// Recent 首次成功后生成 stable-ID 副本；扩展重启且完全离线时 Favorite 仍可读取同一图片。
    func testRecentSeedsRenditionThatFavoriteReusesOfflineAcrossStorageInstances() async throws {
        let firstStorage = try AppGroupStorage(baseURL: temporaryURL)
        let oldFavorite = Self.record(
            id: "pb:249638",
            imageURL: "https://example.com/expired-full.jpg",
            thumbnailURL: "https://example.com/expired-thumb.jpg"
        )
        let freshRecent = Self.record(
            id: oldFavorite.id,
            imageURL: "https://example.com/fresh-full.jpg",
            thumbnailURL: "https://example.com/fresh-thumb.jpg"
        )
        _ = try await firstStorage.toggleFavorite(oldFavorite)
        try await firstStorage.writeRecent(freshRecent, at: Date(timeIntervalSince1970: 2_000))

        let online = ProviderImageLoaderProbe(
            data: Self.sourcePNG,
            successfulURLs: [freshRecent.imageURL]
        )
        let firstRepository = Self.repository(storage: firstStorage, loader: online)
        let recentIdentifier = RecordReference(
            recordID: freshRecent.id,
            view: .recent
        ).itemIdentifier

        _ = try await firstRepository.imageData(
            for: recentIdentifier,
            record: freshRecent,
            representation: .content,
            maximumBytes: ImageTranscoder.defaultMaximumBytes
        )

        let restartedStorage = try AppGroupStorage(baseURL: temporaryURL)
        let offline = ProviderImageLoaderProbe(data: Self.sourcePNG, successfulURLs: [])
        let restartedRepository = Self.repository(storage: restartedStorage, loader: offline)
        let favoriteIdentifier = RecordReference(
            recordID: oldFavorite.id,
            view: .favorite
        ).itemIdentifier
        let restoredOccurrence = try await restartedRepository.occurrence(for: favoriteIdentifier)
        let restoredRecord = try XCTUnwrap(restoredOccurrence?.record)

        let restored = try await restartedRepository.imageData(
            for: favoriteIdentifier,
            record: restoredRecord,
            representation: .content,
            maximumBytes: ImageTranscoder.defaultMaximumBytes
        )

        let onlineRequests = await online.requestedURLs()
        let offlineRequests = await offline.requestedURLs()
        XCTAssertEqual(onlineRequests, [freshRecent.imageURL])
        XCTAssertTrue(offlineRequests.isEmpty)
        let recordForRecent = try XCTUnwrap(restored.recordForRecent)
        XCTAssertEqual(recordForRecent, freshRecent)
        try await restartedRepository.markRecent(recordForRecent)
        let recentAfterOfflineHit = try await restartedStorage.readRecent()
        XCTAssertEqual(recentAfterOfflineHit.first?.image, freshRecent)
        try Self.assertStandardRendition(restored.data)
    }

    /// Favorite 的冻结 URL 已过期时，应先采用同 ID 的 Recent 成功记录并落盘，不访问旧地址。
    func testFavoriteBackfillsFromFreshRecentBeforeTryingExpiredSnapshotURL() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let oldFavorite = Self.record(
            id: "pb:backfill",
            imageURL: "https://example.com/expired-full.jpg",
            thumbnailURL: "https://example.com/expired-thumb.jpg"
        )
        let freshRecent = Self.record(
            id: oldFavorite.id,
            imageURL: "https://example.com/fresh-full.jpg",
            thumbnailURL: "https://example.com/fresh-thumb.jpg"
        )
        _ = try await storage.toggleFavorite(oldFavorite)
        try await storage.writeRecent(freshRecent, at: Date(timeIntervalSince1970: 3_000))

        let loader = ProviderImageLoaderProbe(
            data: Self.sourcePNG,
            successfulURLs: [freshRecent.imageURL]
        )
        let repository = Self.repository(storage: storage, loader: loader)
        let favoriteIdentifier = RecordReference(
            recordID: oldFavorite.id,
            view: .favorite
        ).itemIdentifier
        let occurrence = try await repository.occurrence(for: favoriteIdentifier)
        let frozenRecord = try XCTUnwrap(occurrence?.record)

        let fetched = try await repository.imageData(
            for: favoriteIdentifier,
            record: frozenRecord,
            representation: .content,
            maximumBytes: ImageTranscoder.defaultMaximumBytes
        )

        XCTAssertEqual(fetched.data, Self.sourcePNG)
        XCTAssertEqual(fetched.recordForRecent, freshRecent)
        let requests = await loader.requestedURLs()
        XCTAssertEqual(requests, [freshRecent.imageURL])
        let persisted = try await storage.readFavoriteRendition(id: oldFavorite.id)
        try Self.assertStandardRendition(XCTUnwrap(persisted))
    }

    /// stable ID 是唯一共享键；一张收藏的副本绝不能被另一个 ID 命中。
    func testDifferentStableIDsNeverShareFavoriteRendition() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let first = Self.record(
            id: "pb:first",
            imageURL: "https://example.com/first-full.jpg",
            thumbnailURL: "https://example.com/first-thumb.jpg"
        )
        let second = Self.record(
            id: "pb:second",
            imageURL: "https://example.com/second-full.jpg",
            thumbnailURL: "https://example.com/second-thumb.jpg"
        )
        _ = try await storage.toggleFavorite(first)
        _ = try await storage.toggleFavorite(second)
        let rendition = try ImageTranscoder().transcode(Self.sourcePNG)
        let committed = try await storage.commitFavoriteRenditionIfFavorited(rendition, for: first)
        XCTAssertTrue(committed)

        let offline = ProviderImageLoaderProbe(data: Self.sourcePNG, successfulURLs: [])
        let repository = Self.repository(storage: storage, loader: offline)
        let secondIdentifier = RecordReference(recordID: second.id, view: .favorite).itemIdentifier

        do {
            _ = try await repository.imageData(
                for: secondIdentifier,
                record: second,
                representation: .thumbnail,
                maximumBytes: 5 * 1024 * 1024
            )
            XCTFail("不同 stable ID 不应复用其他收藏的图片副本")
        } catch {
            let requests = await offline.requestedURLs()
            XCTAssertEqual(requests, [second.thumbnailURL, second.imageURL])
        }
    }

    /// 缩略图只用于当前 Finder 回调，不能抢先锁定收藏的长期 512×512 副本。
    func testThumbnailFetchDoesNotPersistFavoriteRendition() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let favorite = Self.record(
            id: "pb:thumbnail-only",
            imageURL: "https://example.com/full.jpg",
            thumbnailURL: "https://example.com/thumb.jpg"
        )
        _ = try await storage.toggleFavorite(favorite)
        let loader = ProviderImageLoaderProbe(
            data: Self.sourcePNG,
            successfulURLs: [favorite.thumbnailURL]
        )
        let repository = Self.repository(storage: storage, loader: loader)
        let identifier = RecordReference(recordID: favorite.id, view: .favorite).itemIdentifier

        _ = try await repository.imageData(
            for: identifier,
            record: favorite,
            representation: .thumbnail,
            maximumBytes: 5 * 1024 * 1024
        )

        let persisted = try await storage.readFavoriteRendition(id: favorite.id)
        XCTAssertNil(persisted)
        let requests = await loader.requestedURLs()
        XCTAssertEqual(requests, [favorite.thumbnailURL])
    }

    /// 副本从无到有必须同时推进 Recent/Favorite 的内容版本，Finder 才会丢弃旧失败状态。
    func testRenditionAvailabilityChangesRecentAndFavoriteContentVersions() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let favorite = Self.record(
            id: "pb:version",
            imageURL: "https://example.com/version-full.jpg",
            thumbnailURL: "https://example.com/version-thumb.jpg"
        )
        _ = try await storage.toggleFavorite(favorite)
        try await storage.writeRecent(favorite, at: Date(timeIntervalSince1970: 4_000))
        let repository = Self.repository(
            storage: storage,
            loader: ProviderImageLoaderProbe(data: Self.sourcePNG, successfulURLs: [])
        )
        let recentItemsBefore = try await repository.recentItems()
        let favoriteItemsBefore = try await repository.favoriteItems()
        let recentBefore = try XCTUnwrap(recentItemsBefore.first)
        let favoriteBefore = try XCTUnwrap(favoriteItemsBefore.first)
        let publicationEpoch = try await repository.currentPublicationEpoch()
        let baselineAnchor = try await repository.commitScope(
            .workingSet,
            items: recentItemsBefore + favoriteItemsBefore,
            expectedPublicationEpoch: publicationEpoch
        )
        let rendition = try ImageTranscoder().transcode(Self.sourcePNG)

        let committed = try await storage.commitFavoriteRenditionIfFavorited(
            rendition,
            for: favorite
        )
        let recentItemsAfter = try await repository.recentItems()
        let favoriteItemsAfter = try await repository.favoriteItems()
        let recentAfter = try XCTUnwrap(recentItemsAfter.first)
        let favoriteAfter = try XCTUnwrap(favoriteItemsAfter.first)
        _ = try await repository.commitScope(
            .workingSet,
            items: recentItemsAfter + favoriteItemsAfter,
            expectedPublicationEpoch: publicationEpoch
        )
        let changes = try await repository.changes(
            in: ProviderEnumerationScope.workingSet.storageKey,
            after: baselineAnchor
        )

        XCTAssertTrue(committed)
        XCTAssertNotEqual(
            recentBefore.itemVersion.contentVersion,
            recentAfter.itemVersion.contentVersion
        )
        XCTAssertNotEqual(
            favoriteBefore.itemVersion.contentVersion,
            favoriteAfter.itemVersion.contentVersion
        )
        XCTAssertEqual(
            recentBefore.itemVersion.metadataVersion,
            recentAfter.itemVersion.metadataVersion
        )
        XCTAssertEqual(
            favoriteBefore.itemVersion.metadataVersion,
            favoriteAfter.itemVersion.metadataVersion
        )
        XCTAssertEqual(
            Set(changes.updatedIdentifiers),
            Set([recentAfter.itemIdentifier.rawValue, favoriteAfter.itemIdentifier.rawValue])
        )
        XCTAssertTrue(changes.deletedIdentifiers.isEmpty)

        _ = try await storage.removeFavorite(id: favorite.id)
        _ = try await storage.toggleFavorite(favorite)
        let rebuiltRendition = try ImageTranscoder().transcode(Self.alternateSourcePNG)
        XCTAssertNotEqual(rendition, rebuiltRendition)
        _ = try await storage.commitFavoriteRenditionIfFavorited(
            rebuiltRendition,
            for: favorite
        )
        let recentItemsAfterRebuild = try await repository.recentItems()
        let favoriteItemsAfterRebuild = try await repository.favoriteItems()
        let recentAfterRebuild = try XCTUnwrap(recentItemsAfterRebuild.first)
        let favoriteAfterRebuild = try XCTUnwrap(favoriteItemsAfterRebuild.first)
        XCTAssertNotEqual(
            recentAfter.itemVersion.contentVersion,
            recentAfterRebuild.itemVersion.contentVersion
        )
        XCTAssertNotEqual(
            favoriteAfter.itemVersion.contentVersion,
            favoriteAfterRebuild.itemVersion.contentVersion
        )
    }

    /// CDN 返回 HTTP 成功但正文不是图片时，不能提前结束候选链，应继续使用同记录的备用 URL。
    func testInvalidImageResponseFallsBackToAlternateURL() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let favorite = Self.record(
            id: "pb:invalid-response",
            imageURL: "https://example.com/invalid-full.jpg",
            thumbnailURL: "https://example.com/valid-thumb.jpg"
        )
        _ = try await storage.toggleFavorite(favorite)
        let loader = ProviderImageLoaderProbe(
            responses: [
                favorite.imageURL: Data("<html>not an image</html>".utf8),
                favorite.thumbnailURL: Self.sourcePNG
            ]
        )
        let repository = Self.repository(storage: storage, loader: loader)
        let identifier = RecordReference(recordID: favorite.id, view: .favorite).itemIdentifier

        let resolved = try await repository.imageData(
            for: identifier,
            record: favorite,
            representation: .content,
            maximumBytes: ImageTranscoder.defaultMaximumBytes
        )

        XCTAssertEqual(resolved.data, Self.sourcePNG)
        let requests = await loader.requestedURLs()
        XCTAssertEqual(requests, [favorite.imageURL, favorite.thumbnailURL])
        let persisted = try await storage.readFavoriteRendition(id: favorite.id)
        XCTAssertNil(persisted, "独立缩略图 URL 只能救活本次内容请求，不能占用长期原图副本")
    }

    /// 已有本地副本时，无关 Recent JSON 损坏不能阻断 Favorite 的离线读取。
    func testCachedFavoriteIgnoresUnrelatedCorruptRecentRecord() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let favorite = Self.record(
            id: "pb:corrupt-recent",
            imageURL: "https://example.com/offline-full.jpg",
            thumbnailURL: "https://example.com/offline-thumb.jpg"
        )
        _ = try await storage.toggleFavorite(favorite)
        let rendition = try ImageTranscoder().transcode(Self.sourcePNG)
        _ = try await storage.commitFavoriteRenditionIfFavorited(rendition, for: favorite)
        let corruptURL = temporaryURL
            .appendingPathComponent("recent", isDirectory: true)
            .appendingPathComponent("unrelated.json", isDirectory: false)
        try Data("not-json".utf8).write(to: corruptURL, options: .atomic)
        let offline = ProviderImageLoaderProbe(data: Self.sourcePNG, successfulURLs: [])
        let repository = Self.repository(storage: storage, loader: offline)
        let identifier = RecordReference(recordID: favorite.id, view: .favorite).itemIdentifier

        let resolved = try await repository.imageData(
            for: identifier,
            record: favorite,
            representation: .content,
            maximumBytes: ImageTranscoder.defaultMaximumBytes
        )

        try Self.assertStandardRendition(resolved.data)
        let requests = await offline.requestedURLs()
        XCTAssertTrue(requests.isEmpty)
    }

    private static func repository(
        storage: AppGroupStorage,
        loader: ProviderImageLoaderProbe
    ) -> ProviderRepository {
        ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: EmptyFavoriteRenditionDiscoveryFeed(),
            diceBear: EmptyFavoriteAvatarProvider(),
            remoteImageLoader: { url, maximumBytes in
                try await loader.load(url: url, maximumBytes: maximumBytes)
            }
        )
    }

    private static func record(
        id: String,
        imageURL: String,
        thumbnailURL: String
    ) -> RemoteImageRecord {
        RemoteImageRecord(
            id: id,
            title: id,
            source: .pixabay,
            imageURL: URL(string: imageURL)!,
            thumbnailURL: URL(string: thumbnailURL)!,
            license: .pixabay,
            width: 1_280,
            height: 853,
            mimeType: "image/jpeg"
        )
    }

    private static func assertStandardRendition(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(data as CFData, nil),
            file: file,
            line: line
        )
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            file: file,
            line: line
        )
        XCTAssertEqual(
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            ImageTranscoder.outputSize,
            file: file,
            line: line
        )
        XCTAssertEqual(
            (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            ImageTranscoder.outputSize,
            file: file,
            line: line
        )
    }

    private static let sourcePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    private static let alternateSourcePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
    )!
}

private actor ProviderImageLoaderProbe {
    private let responses: [URL: Data]
    private var requests: [URL] = []

    init(data: Data, successfulURLs: Set<URL>) {
        responses = Dictionary(
            uniqueKeysWithValues: successfulURLs.map { ($0, data) }
        )
    }

    init(responses: [URL: Data]) {
        self.responses = responses
    }

    func load(url: URL, maximumBytes: Int) throws -> Data {
        requests.append(url)
        guard let data = responses[url] else { throw URLError(.cannotConnectToHost) }
        guard data.count <= maximumBytes else { throw DownloadError.tooLarge(maximumBytes) }
        return data
    }

    func requestedURLs() -> [URL] { requests }
}

private struct EmptyFavoriteRenditionDiscoveryFeed: DiscoveryFeedProviding {
    func page(generation: UInt64?, page: Int, pageSize: Int) async throws -> DiscoveryFeedPage {
        DiscoveryFeedPage(
            generation: generation ?? 1,
            records: [],
            nextPage: nil,
            didMutateSnapshot: false
        )
    }
}

private struct EmptyFavoriteAvatarProvider: AvatarProviding {
    func currentGenerationDay() async -> AvatarGenerationDay {
        AvatarGenerationDay(date: Date(timeIntervalSince1970: 0))
    }

    func avatars(
        query: String,
        offset: Int,
        count: Int,
        generationDay: AvatarGenerationDay
    ) async -> [RemoteImageRecord] {
        []
    }
}
