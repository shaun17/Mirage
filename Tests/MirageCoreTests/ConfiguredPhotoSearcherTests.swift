import Foundation
import XCTest
@testable import MirageCore

final class ConfiguredPhotoSearcherTests: XCTestCase {
    /// 无密钥来源应从独立工厂创建，并与默认 Openverse 一起参与 App 交互搜索。
    func testAppSearchBuildsMetAndNASAWithoutCredentials() async throws {
        let preferences = makePreferences()
        _ = try await preferences.saveConfiguration(for: .metMuseum, enabledSurfaces: [.app])
        _ = try await preferences.saveConfiguration(for: .nasa, enabledSurfaces: [.app])
        let probe = UncredentialedSourceFactoryProbe()
        let searcher = ConfiguredPhotoSearcher(
            surface: .app,
            preferences: preferences,
            credentials: ConfiguredCredentialStore(values: [:]),
            openverse: ConfiguredFixtureSource(sourceID: .openverse),
            requestCoordinator: PhotoSourceRequestCoordinator(),
            uncredentialedSourceFactory: { sourceID in
                probe.makeSource(sourceID: sourceID)
            }
        )

        let page = try await searcher.search(query: "space art", cursor: nil, pageSize: 3)

        XCTAssertEqual(page.records.map(\.source), [.openverse, .metMuseum, .nasa])
        XCTAssertEqual(probe.requests, [.metMuseum, .nasa])
    }

    /// Met 与 NASA 当前只响应用户交互搜索，不能进入后台推荐快照。
    func testRecommendationDoesNotBuildMetOrNASA() async throws {
        let preferences = makePreferences()
        _ = try await preferences.saveConfiguration(for: .metMuseum, enabledSurfaces: [.app])
        _ = try await preferences.saveConfiguration(for: .nasa, enabledSurfaces: [.app])
        let probe = UncredentialedSourceFactoryProbe()
        let searcher = ConfiguredPhotoSearcher(
            surface: .app,
            purpose: .recommendation,
            preferences: preferences,
            credentials: ConfiguredCredentialStore(values: [:]),
            openverse: ConfiguredFixtureSource(sourceID: .openverse),
            requestCoordinator: PhotoSourceRequestCoordinator(),
            uncredentialedSourceFactory: { sourceID in
                probe.makeSource(sourceID: sourceID)
            }
        )

        let page = try await searcher.search(query: "space art", cursor: nil, pageSize: 3)

        XCTAssertEqual(page.records.map(\.source), [.openverse])
        XCTAssertTrue(probe.requests.isEmpty)
    }

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

    /// GIPHY 只能从 App 交互 GIF 范围进入；普通图片、推荐与 Finder 都不得构造它。
    func testEnvironmentRoutesGiphyOnlyToAppInteractiveGIFScope() async throws {
        let preferences = makePreferences()
        _ = try await preferences.saveConfiguration(for: .giphy, enabledSurfaces: [.app])
        let credentials = ConfiguredCredentialStore(values: [.giphy: "giphy-test-key"])
        let probe = CredentialedSourceFactoryProbe()
        let environment = PhotoSearchEnvironment(
            preferences: preferences,
            credentials: credentials,
            openverse: ConfiguredFixtureSource(sourceID: .openverse),
            requestCoordinator: PhotoSourceRequestCoordinator(),
            credentialedSourceFactory: { sourceID, credential in
                probe.makeSource(sourceID: sourceID, credential: credential)
            }
        )

        let app = environment.imageSearchService(for: .app, purpose: .interactive)
        let giphyPage = try await app.giphyCatalog(cursor: nil, pageSize: 40)
        let photoPage = try await app.search("图片:giphy", cursor: nil, pageSize: 20)

        XCTAssertEqual(giphyPage.records.map(\.source), [.giphy])
        XCTAssertEqual(photoPage.records.map(\.source), [.openverse])
        XCTAssertEqual(probe.requests, [
            .init(sourceID: .giphy, credential: "giphy-test-key")
        ])

        for service in [
            environment.imageSearchService(for: .app, purpose: .recommendation),
            environment.imageSearchService(for: .fileProvider, purpose: .interactive)
        ] {
            do {
                _ = try await service.giphyCatalog(cursor: nil, pageSize: 40)
                XCTFail("非 App 交互服务不应装配 GIPHY")
            } catch let PhotoSearchError.allSourcesFailed(issues) {
                XCTAssertEqual(issues.map(\.sourceID), [.giphy])
                XCTAssertEqual(issues.map(\.kind), [.unavailable])
            }
        }
        XCTAssertEqual(probe.requests.count, 1)
    }

    /// 浏览可以降级显示部分 GIPHY 内容，但设置页连接测试必须覆盖 Emoji、GIF、Sticker 三个端点。
    func testGiphyConnectionTestRejectsPartialEndpointFailure() async throws {
        let issue = PhotoSourceIssue(
            sourceID: .giphy,
            kind: .invalidCredential,
            message: "GIPHY Sticker 端点拒绝了当前 API Key。"
        )
        let environment = PhotoSearchEnvironment(
            preferences: makePreferences(),
            credentials: ConfiguredCredentialStore(values: [:]),
            openverse: ConfiguredFixtureSource(sourceID: .openverse),
            requestCoordinator: PhotoSourceRequestCoordinator(),
            credentialedSourceFactory: { sourceID, _ in
                XCTAssertEqual(sourceID, .giphy)
                return GiphyPartialConnectionSource(issue: issue)
            }
        )

        do {
            try await environment.testConnection(sourceID: .giphy, credential: "test-key")
            XCTFail("任一必需 GIPHY 端点失败时不应通过连接测试")
        } catch let PhotoSearchError.allSourcesFailed(issues) {
            XCTAssertEqual(issues, [issue])
        }
    }

    private func makePreferences() -> PhotoSourcePreferencesStore {
        let suiteName = "MirageCoreTests.ConfiguredPhotoSearcher.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PhotoSourcePreferencesStore(userDefaults: defaults)
    }
}

private struct GiphyPartialConnectionSource: PhotoSourceSearching {
    let sourceID = PhotoSourceID.giphy
    let issue: PhotoSourceIssue

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        PhotoSourcePage(records: [], nextCursor: nil, issues: [issue])
    }
}

private final class UncredentialedSourceFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [PhotoSourceID] = []

    var requests: [PhotoSourceID] {
        lock.withLock { recordedRequests }
    }

    func makeSource(sourceID: PhotoSourceID) -> any PhotoSourceSearching {
        lock.withLock {
            recordedRequests.append(sourceID)
        }
        return ConfiguredFixtureSource(sourceID: sourceID)
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
        case .metMuseum: metadata = (.metMuseum, .cc0)
        case .nasa: metadata = (.nasa, .nasaMediaUsage)
        case .pexels: metadata = (.pexels, .pexels)
        case .pixabay: metadata = (.pixabay, .pixabay)
        case .giphy: metadata = (.giphy, .giphy)
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
