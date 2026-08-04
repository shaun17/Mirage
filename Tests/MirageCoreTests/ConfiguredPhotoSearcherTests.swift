import Foundation
import XCTest
@testable import MirageCore

final class ConfiguredPhotoSearcherTests: XCTestCase {
    /// App 启用 Pixabay 后应从独立凭据创建适配器，并与 Openverse 进入同一聚合页。
    func testAppSearchBuildsPixabayFromCredentialedFactory() async throws {
        let preferences = makePreferences()
        _ = try await preferences.saveConfiguration(for: .pixabay, enabledSurfaces: [.app])
        let credentials = ConfiguredCredentialStore(values: [.pixabay: "pixabay-test-key"])
        let probe = CredentialedSourceFactoryProbe()
        let searcher = ConfiguredPhotoSearcher(
            surface: .app,
            preferences: preferences,
            credentials: credentials,
            openverse: ConfiguredFixtureSource(sourceID: .openverse),
            requestCoordinator: PhotoSourceRequestCoordinator(),
            credentialedSourceFactory: { sourceID, credential in
                probe.makeSource(sourceID: sourceID, credential: credential)
            }
        )

        let page = try await searcher.search(query: "nature", cursor: nil, pageSize: 2)

        XCTAssertEqual(Set(page.records.map(\.source)), Set([.openverse, .pixabay]))
        XCTAssertEqual(probe.requests, [
            CredentialedSourceFactoryProbe.Request(
                sourceID: .pixabay,
                credential: "pixabay-test-key"
            )
        ])
    }

    /// 三个来源同时启用时必须聚合展示，Pixabay 不能替换已经启用的来源。
    func testAppSearchAggregatesAllThreeConfiguredSources() async throws {
        let preferences = makePreferences()
        _ = try await preferences.saveConfiguration(for: .pexels, enabledSurfaces: [.app])
        _ = try await preferences.saveConfiguration(for: .pixabay, enabledSurfaces: [.app])
        let credentials = ConfiguredCredentialStore(values: [
            .pexels: "pexels-test-key",
            .pixabay: "pixabay-test-key"
        ])
        let probe = CredentialedSourceFactoryProbe()
        let searcher = ConfiguredPhotoSearcher(
            surface: .app,
            preferences: preferences,
            credentials: credentials,
            openverse: ConfiguredFixtureSource(sourceID: .openverse),
            requestCoordinator: PhotoSourceRequestCoordinator(),
            credentialedSourceFactory: { sourceID, credential in
                probe.makeSource(sourceID: sourceID, credential: credential)
            }
        )

        let page = try await searcher.search(query: "nature", cursor: nil, pageSize: 3)

        XCTAssertEqual(page.records.map(\.source), [.openverse, .pexels, .pixabay])
        XCTAssertEqual(probe.requests, [
            .init(sourceID: .pexels, credential: "pexels-test-key"),
            .init(sourceID: .pixabay, credential: "pixabay-test-key")
        ])
    }

    /// Finder 快照会过滤 App-only Pixabay，因此不能构造客户端或读取其内容。
    func testFileProviderDoesNotBuildAppOnlyPixabay() async throws {
        let preferences = makePreferences()
        _ = try await preferences.saveConfiguration(for: .pixabay, enabledSurfaces: [.app])
        let probe = CredentialedSourceFactoryProbe()
        let searcher = ConfiguredPhotoSearcher(
            surface: .fileProvider,
            preferences: preferences,
            credentials: ConfiguredCredentialStore(values: [.pixabay: "pixabay-test-key"]),
            openverse: ConfiguredFixtureSource(sourceID: .openverse),
            requestCoordinator: PhotoSourceRequestCoordinator(),
            credentialedSourceFactory: { sourceID, credential in
                probe.makeSource(sourceID: sourceID, credential: credential)
            }
        )

        let page = try await searcher.search(query: "nature", cursor: nil, pageSize: 2)

        XCTAssertEqual(page.records.map(\.source), [.openverse])
        XCTAssertTrue(probe.requests.isEmpty)
    }

    /// Pixabay 只处理用户明确发起的搜索，不能进入会持久化 URL 的自动推荐流。
    func testRecommendationPurposeDoesNotBuildPixabay() async throws {
        let preferences = makePreferences()
        _ = try await preferences.saveConfiguration(for: .pixabay, enabledSurfaces: [.app])
        let probe = CredentialedSourceFactoryProbe()
        let searcher = ConfiguredPhotoSearcher(
            surface: .app,
            purpose: .recommendation,
            preferences: preferences,
            credentials: ConfiguredCredentialStore(values: [.pixabay: "pixabay-test-key"]),
            openverse: ConfiguredFixtureSource(sourceID: .openverse),
            requestCoordinator: PhotoSourceRequestCoordinator(),
            credentialedSourceFactory: { sourceID, credential in
                probe.makeSource(sourceID: sourceID, credential: credential)
            }
        )

        let page = try await searcher.search(query: "nature", cursor: nil, pageSize: 2)

        XCTAssertEqual(page.records.map(\.source), [.openverse])
        XCTAssertTrue(probe.requests.isEmpty)
    }

    private func makePreferences() -> PhotoSourcePreferencesStore {
        let suiteName = "MirageCoreTests.ConfiguredPhotoSearcher.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PhotoSourcePreferencesStore(userDefaults: defaults)
    }
}

private final class CredentialedSourceFactoryProbe: @unchecked Sendable {
    struct Request: Equatable {
        let sourceID: PhotoSourceID
        let credential: String
    }

    private let lock = NSLock()
    private var recordedRequests: [Request] = []

    var requests: [Request] {
        lock.withLock { recordedRequests }
    }

    func makeSource(
        sourceID: PhotoSourceID,
        credential: String
    ) -> any PhotoSourceSearching {
        lock.withLock {
            recordedRequests.append(Request(sourceID: sourceID, credential: credential))
        }
        return ConfiguredFixtureSource(sourceID: sourceID)
    }
}

private actor ConfiguredCredentialStore: PhotoSourceCredentialStoring {
    private var values: [PhotoSourceID: String]

    init(values: [PhotoSourceID: String]) {
        self.values = values
    }

    func credential(for sourceID: PhotoSourceID) async throws -> String? {
        values[sourceID]
    }

    func store(_ credential: String, for sourceID: PhotoSourceID) async throws {
        values[sourceID] = credential
    }

    func removeCredential(for sourceID: PhotoSourceID) async throws {
        values[sourceID] = nil
    }
}

private struct ConfiguredFixtureSource: PhotoSourceSearching {
    let sourceID: PhotoSourceID

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        let metadata: (ImageSource, LicenseInfo)
        switch sourceID {
        case .openverse: metadata = (.openverse, .cc0)
        case .pexels: metadata = (.pexels, .pexels)
        case .pixabay: metadata = (.pixabay, .pixabay)
        }
        let url = URL(string: "https://example.com/\(sourceID.rawValue).jpg")!
        return PhotoSourcePage(
            records: [RemoteImageRecord(
                id: "fixture:\(sourceID.rawValue)",
                title: sourceID.rawValue,
                source: metadata.0,
                imageURL: url,
                thumbnailURL: url,
                license: metadata.1
            )],
            nextCursor: nil
        )
    }
}
