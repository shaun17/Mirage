import FileProvider
import MirageCore
import XCTest

final class ProviderSourcePolicyTests: XCTestCase {
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
        case .gravatar: license = .gravatarUsage
        case .openverse, .metMuseum, .diceBear, .robohash: license = .cc0
        }
        return RemoteImageRecord(
            id: id,
            title: id,
            source: source,
            imageURL: URL(string: "https://example.com/\(id).jpg")!,
            thumbnailURL: URL(string: "https://example.com/\(id)-thumb.jpg")!,
            license: license,
            mimeType: "image/jpeg"
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
