import FileProvider
import MirageCore
import XCTest

final class ProviderSourcePolicyTests: XCTestCase {
    func testEveryVisibleSourceSupportsAppFavoritesWithoutChangingCachePolicy() {
        XCTAssertTrue(ImageSource.thisPersonDoesNotExist.isAvatarSource)
        XCTAssertNil(ImageSource.thisPersonDoesNotExist.photoSourceID)
        XCTAssertTrue(ImageSource.thisPersonDoesNotExist.allowsPersistentLibraryStorage)
        XCTAssertTrue(ImageSource.thisPersonDoesNotExist.allowsMediaCaching)
        XCTAssertTrue(ImageSource.picrew.isAvatarSource)
        XCTAssertNil(ImageSource.picrew.photoSourceID)
        XCTAssertTrue(ImageSource.picrew.allowsPersistentLibraryStorage)
        XCTAssertTrue(ImageSource.picrew.allowsMediaCaching)
        XCTAssertTrue(ImageSource.giphy.allowsPersistentLibraryStorage)
        XCTAssertFalse(ImageSource.giphy.allowsMediaCaching)
        XCTAssertFalse(PhotoSourceRegistry.descriptor(for: .giphy)?.supports(.fileProvider) == true)
    }

    func testFinderRejectsPicrewPreviewFromLegacyStorage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageProviderSourcePolicy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storage = try AppGroupStorage(baseURL: directory)
        let picrew = Self.record(
            id: "picrew:discovery:v1:\(String(repeating: "a", count: 64))",
            source: .picrew
        )
        _ = try await storage.toggleFavorite(picrew)
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: EmptyPolicyDiscoveryFeed(),
            sourcePreferences: OpenverseOnlyPolicyPreferences()
        )

        let favorites = try await repository.favoriteItems()
        let identifier = RecordReference(
            recordID: picrew.id,
            view: .favorite
        ).itemIdentifier
        let occurrence = try await repository.occurrence(for: identifier)
        let library = try await storage.readLibrarySnapshot()
        XCTAssertTrue(library.favoriteIDs.contains(picrew.id))
        XCTAssertTrue(picrew.source.allowsPersistentLibraryStorage)
        XCTAssertTrue(favorites.isEmpty)
        XCTAssertNil(occurrence)
    }

    func testFinderHidesIDOnlyGiphyFavorite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageProviderSourcePolicy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storage = try AppGroupStorage(baseURL: directory)
        let giphy = Self.record(
            id: StableImageID.giphy(id: "favorite"),
            source: .giphy
        )
        _ = try await storage.toggleFavorite(giphy)
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: EmptyPolicyDiscoveryFeed(),
            sourcePreferences: OpenverseOnlyPolicyPreferences()
        )

        let favorites = try await repository.favoriteItems()
        let identifier = RecordReference(recordID: giphy.id, view: .favorite).itemIdentifier
        let occurrence = try await repository.occurrence(for: identifier)
        let library = try await storage.readLibrarySnapshot()
        XCTAssertTrue(library.favoriteIDs.contains(giphy.id))
        XCTAssertTrue(giphy.source.allowsPersistentLibraryStorage)
        XCTAssertTrue(favorites.isEmpty)
        XCTAssertNil(occurrence)
        XCTAssertTrue(library.favorites.first?.isGiphyFavoriteReference == true)
    }

    /// 普通图片来源失败时，头像与资料库目录仍必须组成可枚举根目录。
    func testRootStillPublishesLibrariesWhenPhotoDiscoveryIsUnavailable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageProviderSourcePolicy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try AppGroupStorage(baseURL: directory)
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: FailingPolicyDiscoveryFeed(),
            sourcePreferences: OpenverseOnlyPolicyPreferences()
        )
        let catalog = ProviderCatalog(repository: repository)

        let first = try await catalog.preparedItems(for: .root)
        let expectedDirectories: Set<NSFileProviderItemIdentifier> = [
            ProviderIdentifiers.avatars,
            ProviderIdentifiers.recent,
            ProviderIdentifiers.favorites,
            ProviderIdentifiers.searchBacking
        ]
        XCTAssertEqual(Set(first.map(\.itemIdentifier)), expectedDirectories)
        XCTAssertTrue(first.allSatisfy { $0.contentType == .folder })
        let firstGeneration = try XCTUnwrap(first.first?.discoveryGeneration)

        let repeated = try await catalog.preparedItems(for: .root)
        XCTAssertEqual(repeated.map(\.itemIdentifier), first.map(\.itemIdentifier))
        XCTAssertTrue(repeated.allSatisfy { $0.discoveryGeneration == firstGeneration })
        let fallback = try await storage.readDiscoveryFeedSnapshot()
        XCTAssertEqual(fallback?.source, .fallback)
        XCTAssertTrue(fallback?.records.isEmpty == true)
        XCTAssertNil(fallback?.nextPage)
    }

    func testFinderHidesPexelsFromFavoritesAndDirectOccurrence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageProviderSourcePolicy-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let storage = try AppGroupStorage(baseURL: directory)
        let openverse = Self.record(id: "ov:allowed", source: .openverse)
        let pexels = Self.record(id: "px:blocked", source: .pexels)
        _ = try await storage.toggleFavorite(openverse)
        _ = try await storage.toggleFavorite(pexels)

        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: EmptyPolicyDiscoveryFeed(),
            sourcePreferences: OpenverseOnlyPolicyPreferences()
        )

        let favorites = try await repository.favoriteItems()
        XCTAssertEqual(favorites.map(\.itemIdentifier), [
            RecordReference(recordID: openverse.id, view: .favorite).itemIdentifier
        ])

        let blockedIdentifier = RecordReference(
            recordID: pexels.id,
            view: .favorite
        ).itemIdentifier
        let blockedOccurrence = try await repository.occurrence(for: blockedIdentifier)
        XCTAssertNil(blockedOccurrence)
    }

    func testFinderShowsPexelsWhenEnabledForFileProvider() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageProviderSourcePolicy-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let storage = try AppGroupStorage(baseURL: directory)
        let pexels = Self.record(id: "px:allowed", source: .pexels)
        _ = try await storage.toggleFavorite(pexels)

        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: EmptyPolicyDiscoveryFeed(),
            sourcePreferences: PexelsEnabledPolicyPreferences()
        )

        let favorites = try await repository.favoriteItems()
        XCTAssertEqual(favorites.map(\.itemIdentifier), [
            RecordReference(recordID: pexels.id, view: .favorite).itemIdentifier
        ])

        let identifier = RecordReference(recordID: pexels.id, view: .favorite).itemIdentifier
        let occurrence = try await repository.occurrence(for: identifier)
        XCTAssertEqual(occurrence?.record, pexels)
    }

    /// Pixabay 当前只有 App 搜索能力；即使旧配置请求 Finder，也必须在快照归一化时过滤。
    func testFinderHidesAppOnlyPixabay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageProviderSourcePolicy-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let storage = try AppGroupStorage(baseURL: directory)
        let pixabay = Self.record(id: "pb:app-only", source: .pixabay)
        _ = try await storage.toggleFavorite(pixabay)
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: EmptyPolicyDiscoveryFeed(),
            sourcePreferences: PixabayRequestedPolicyPreferences()
        )

        let favorites = try await repository.favoriteItems()
        let identifier = RecordReference(recordID: pixabay.id, view: .favorite).itemIdentifier
        let occurrence = try await repository.occurrence(for: identifier)
        let library = try await storage.readLibrarySnapshot()
        XCTAssertTrue(library.favoriteIDs.contains(pixabay.id))
        XCTAssertTrue(pixabay.source.allowsPersistentLibraryStorage)
        XCTAssertTrue(favorites.isEmpty)
        XCTAssertNil(occurrence)
    }

    private static func record(id: String, source: ImageSource) -> RemoteImageRecord {
        let license: LicenseInfo
        switch source {
        case .pexels: license = .pexels
        case .pixabay: license = .pixabay
        case .nasa: license = .nasaMediaUsage
        case .giphy: license = .giphy
        case .picrew: license = .picrewUsage
        case .gravatar: license = .gravatarUsage
        case .thisPersonDoesNotExist: license = .thisPersonDoesNotExistUsage
        case .openverse, .metMuseum, .diceBear, .robohash: license = .cc0
        }
        let isGiphy = source == .giphy
        let imageURL = isGiphy
            ? URL(string: "https://media.giphy.com/media/favorite/giphy.gif")!
            : URL(string: "https://example.com/\(id).jpg")!
        let thumbnailURL = isGiphy
            ? URL(string: "https://media.giphy.com/media/favorite/200w.gif")!
            : URL(string: "https://example.com/\(id)-thumb.jpg")!
        return RemoteImageRecord(
            id: id,
            title: id,
            source: source,
            giphyContentType: isGiphy ? .gif : nil,
            giphyID: source == .giphy ? "favorite" : nil,
            imageURL: imageURL,
            thumbnailURL: thumbnailURL,
            license: license,
            mimeType: isGiphy ? "image/gif" : "image/jpeg"
        )
    }

}

private struct EmptyPolicyDiscoveryFeed: DiscoveryFeedProviding {
    func page(generation: UInt64?, page: Int, pageSize: Int) async throws -> DiscoveryFeedPage {
        DiscoveryFeedPage(
            generation: generation ?? 1,
            records: [],
            nextPage: nil,
            didMutateSnapshot: false
        )
    }
}

private struct FailingPolicyDiscoveryFeed: DiscoveryFeedProviding {
    func page(generation: UInt64?, page: Int, pageSize: Int) async throws -> DiscoveryFeedPage {
        throw PhotoSearchError.allSourcesFailed([
            PhotoSourceIssue(
                sourceID: .pexels,
                kind: .missingCredential,
                message: "测试用普通图片来源不可用"
            )
        ])
    }
}

private struct OpenverseOnlyPolicyPreferences: PhotoSourcePreferencesReading {
    func snapshot() async -> PhotoSourcePreferencesSnapshot {
        PhotoSourcePreferencesSnapshot()
    }

    func configurationKey(for surface: PhotoSourceSurface) async -> String {
        "policy:\(surface.rawValue):openverse"
    }
}

private struct PexelsEnabledPolicyPreferences: PhotoSourcePreferencesReading {
    func snapshot() async -> PhotoSourcePreferencesSnapshot {
        PhotoSourcePreferencesSnapshot(
            appSourceIDs: [.openverse],
            fileProviderSourceIDs: [.openverse, .pexels]
        )
    }

    func configurationKey(for surface: PhotoSourceSurface) async -> String {
        "policy:\(surface.rawValue):openverse,pexels"
    }
}

private struct PixabayRequestedPolicyPreferences: PhotoSourcePreferencesReading {
    func snapshot() async -> PhotoSourcePreferencesSnapshot {
        PhotoSourcePreferencesSnapshot(
            appSourceIDs: [.openverse, .pixabay],
            fileProviderSourceIDs: [.openverse, .pixabay]
        )
    }

    func configurationKey(for surface: PhotoSourceSurface) async -> String {
        "policy:\(surface.rawValue):openverse,pixabay"
    }
}
