import Foundation
import XCTest
@testable import MirageCore

final class PhotoSourcePreferencesStoreTests: XCTestCase {
    /// 没有持久化值时，App 与 File Provider 都应以 Openverse 作为安全默认来源。
    func testDefaultSnapshotEnablesOpenverseForBothSurfaces() async {
        let store = makeStore()
        let snapshot = await store.snapshot()
        let configurationKey = await store.configurationKey(for: .app)

        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertEqual(snapshot.sourceIDs(for: .app), [.openverse])
        XCTAssertEqual(snapshot.sourceIDs(for: .fileProvider), [.openverse])
        XCTAssertEqual(configurationKey, "photo-sources-v1:app:1:openverse")
    }

    /// Snapshot 会去重并按 registry 稳定排序，同时过滤当前 surface 不支持的来源。
    func testSnapshotNormalizesOrderDuplicatesAndSurfaceSupport() {
        let snapshot = PhotoSourcePreferencesSnapshot(
            revision: 4,
            appSourceIDs: [.pixabay, .pexels, .openverse, .pexels],
            fileProviderSourceIDs: [.pixabay, .pexels, .openverse]
        )

        XCTAssertEqual(snapshot.appSourceIDs, [.openverse, .pexels, .pixabay])
        XCTAssertEqual(snapshot.fileProviderSourceIDs, [.openverse, .pexels, .pixabay])
    }

    /// Settings 按稳定顺序展示六个入口，并明确声明各来源的使用边界。
    func testRegistryIncludesMetNASAAndAppOnlyGiphy() {
        XCTAssertEqual(
            PhotoSourceRegistry.descriptors.map(\.id),
            [.openverse, .metMuseum, .nasa, .pexels, .pixabay, .giphy]
        )
        let openverse = PhotoSourceRegistry.descriptor(for: .openverse)
        let metMuseum = PhotoSourceRegistry.descriptor(for: .metMuseum)
        let nasa = PhotoSourceRegistry.descriptor(for: .nasa)
        let pixabay = PhotoSourceRegistry.descriptor(for: .pixabay)
        let pexels = PhotoSourceRegistry.descriptor(for: .pexels)
        let giphy = PhotoSourceRegistry.descriptor(for: .giphy)
        let freeRegistrationLabel = "免费使用 · 注册即可获取 API Key"
        XCTAssertEqual(pexels?.supportedSurfaces, [.app, .fileProvider])
        XCTAssertEqual(pexels?.credentialAcquisitionLabel, freeRegistrationLabel)
        XCTAssertEqual(pixabay?.availability, .available)
        XCTAssertEqual(pixabay?.supportedSurfaces, [.app, .fileProvider])
        XCTAssertEqual(pixabay?.credentialAcquisitionLabel, freeRegistrationLabel)
        XCTAssertNil(openverse?.credentialAcquisitionLabel)
        XCTAssertEqual(metMuseum?.credentialRequirement, PhotoSourceCredentialRequirement.none)
        XCTAssertEqual(metMuseum?.supportedSurfaces, [.app, .fileProvider])
        XCTAssertTrue(metMuseum?.allowsAutomatedRecommendations ?? false)
        XCTAssertTrue(metMuseum?.allowsPersistentLibraryStorage ?? false)
        XCTAssertEqual(nasa?.credentialRequirement, PhotoSourceCredentialRequirement.none)
        XCTAssertEqual(nasa?.supportedSurfaces, [.app, .fileProvider])
        XCTAssertTrue(nasa?.allowsAutomatedRecommendations ?? false)
        XCTAssertTrue(nasa?.allowsPersistentLibraryStorage ?? false)
        XCTAssertEqual(ImageSource.metMuseum.photoSourceID, .metMuseum)
        XCTAssertTrue(ImageSource.metMuseum.allowsPersistentLibraryStorage)
        XCTAssertEqual(ImageSource.nasa.photoSourceID, .nasa)
        XCTAssertTrue(ImageSource.nasa.allowsPersistentLibraryStorage)
        XCTAssertEqual(pixabay?.allowsAutomatedRecommendations, true)
        XCTAssertEqual(pixabay?.allowsPersistentLibraryStorage, true)
        XCTAssertTrue(ImageSource.pixabay.allowsPersistentLibraryStorage)
        XCTAssertEqual(pixabay?.searchResultAttribution?.text, "Images provided by Pixabay")
        XCTAssertEqual(pixabay?.searchResultAttribution?.url.host, "pixabay.com")
        XCTAssertEqual(
            pixabay?.searchResultAttribution?.note,
            "支持 App 收藏、Finder 与自动推荐"
        )
        XCTAssertEqual(giphy?.supportedSurfaces, [.app])
        XCTAssertEqual(
            giphy?.summary,
            "使用你自己的 GIPHY API Key 浏览 Emoji，并搜索 GIF 与 Sticker"
        )
        XCTAssertEqual(giphy?.resultPresentation, .isolated)
        XCTAssertFalse(giphy?.allowsAutomatedRecommendations ?? true)
        XCTAssertTrue(giphy?.allowsPersistentLibraryStorage ?? false)
        XCTAssertFalse(giphy?.allowsMediaCaching ?? true)
        XCTAssertEqual(giphy?.searchResultAttribution?.text, "Powered by GIPHY")
        XCTAssertEqual(ImageSource.giphy.photoSourceID, .giphy)
        XCTAssertTrue(ImageSource.giphy.allowsPersistentLibraryStorage)
        XCTAssertFalse(ImageSource.giphy.allowsMediaCaching)
    }

    /// GIPHY 只允许 App；保存后不能进入 Finder 配置。
    func testAppOnlyGiphyConfigurationDoesNotEnableFinder() async throws {
        let store = makeStore()

        let saved = try await store.saveConfiguration(
            for: .giphy,
            enabledSurfaces: [.app]
        )

        XCTAssertEqual(saved.appSourceIDs, [.openverse, .giphy])
        XCTAssertEqual(saved.fileProviderSourceIDs, [.openverse])
        let reloaded = await store.snapshot()
        XCTAssertEqual(reloaded, saved)

        do {
            _ = try await store.setEnabled(true, sourceID: .giphy, surface: .fileProvider)
            XCTFail("GIPHY 不应进入 Finder")
        } catch {
            XCTAssertEqual(error as? PhotoSourcePreferencesError, .unsupportedSurface)
        }
    }

    /// Met 与 NASA 都支持 App 与 Finder，两个范围可由统一开关一次提交。
    func testMetAndNASACanEnableAppAndFileProvider() async throws {
        let store = makeStore()

        _ = try await store.saveConfiguration(for: .metMuseum, enabledSurfaces: [.app])
        let updated = try await store.saveConfiguration(for: .nasa, enabledSurfaces: [.app])
        XCTAssertEqual(updated.appSourceIDs, [.openverse, .metMuseum, .nasa])
        XCTAssertEqual(updated.fileProviderSourceIDs, [.openverse])

        for sourceID in [PhotoSourceID.metMuseum, .nasa] {
            _ = try await store.setEnabled(true, sourceID: sourceID, surface: .fileProvider)
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.appSourceIDs, updated.appSourceIDs)
        XCTAssertEqual(snapshot.fileProviderSourceIDs, [.openverse, .metMuseum, .nasa])
    }

    /// 只有真实设置变化才推进 revision；相同设置写入必须保持游标仍可使用。
    func testRevisionOnlyAdvancesForRealChanges() async throws {
        let store = makeStore()

        let unchanged = try await store.setEnabled(true, sourceID: .openverse, surface: .app)
        XCTAssertEqual(unchanged.revision, 1)

        let enabled = try await store.setEnabled(true, sourceID: .pexels, surface: .app)
        XCTAssertEqual(enabled.revision, 2)
        XCTAssertEqual(enabled.appSourceIDs, [.openverse, .pexels])

        let disabled = try await store.setEnabled(false, sourceID: .pexels, surface: .app)
        XCTAssertEqual(disabled.revision, 3)
        XCTAssertEqual(disabled.appSourceIDs, [.openverse])

        let advanced = try await store.advanceRevision()
        XCTAssertEqual(advanced.revision, 4)
        let persisted = await store.snapshot()
        XCTAssertEqual(persisted, advanced)
    }

    /// 单个供应商的全部使用范围应一次提交，并允许凭据变化在来源不变时主动失效旧游标。
    func testSaveConfigurationCommitsOneProviderWithSingleRevision() async throws {
        let store = makeStore()

        let enabled = try await store.saveConfiguration(
            for: .pexels,
            enabledSurfaces: [.app, .fileProvider]
        )
        XCTAssertEqual(enabled.revision, 2)
        XCTAssertEqual(enabled.appSourceIDs, [.openverse, .pexels])
        XCTAssertEqual(enabled.fileProviderSourceIDs, [.openverse, .pexels])

        let unchanged = try await store.saveConfiguration(
            for: .pexels,
            enabledSurfaces: [.app, .fileProvider]
        )
        XCTAssertEqual(unchanged.revision, 2)

        let invalidated = try await store.saveConfiguration(
            for: .pexels,
            enabledSurfaces: [.app, .fileProvider],
            invalidateConfiguration: true
        )
        XCTAssertEqual(invalidated.revision, 3)
    }

    /// Pixabay 可以进入 App 聚合与 Finder File Provider。
    func testPixabayCanEnableAppAndFileProvider() async throws {
        let store = makeStore()

        let updated = try await store.saveConfiguration(
            for: .pixabay,
            enabledSurfaces: [.app]
        )
        XCTAssertEqual(updated.appSourceIDs, [.openverse, .pixabay])
        XCTAssertEqual(updated.fileProviderSourceIDs, [.openverse])

        let finderEnabled = try await store.setEnabled(
            true,
            sourceID: .pixabay,
            surface: .fileProvider
        )
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.appSourceIDs, updated.appSourceIDs)
        XCTAssertEqual(snapshot.fileProviderSourceIDs, [.openverse, .pixabay])
        XCTAssertEqual(snapshot, finderEnabled)
    }

    /// Pexels 可以单独启用到 Finder，并按 registry 顺序写入共享配置。
    func testEnablesPexelsForFileProvider() async throws {
        let store = makeStore()

        let updated = try await store.setEnabled(
            true,
            sourceID: .pexels,
            surface: .fileProvider
        )

        XCTAssertEqual(updated.revision, 2)
        XCTAssertEqual(updated.fileProviderSourceIDs, [.openverse, .pexels])
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot, updated)
    }

    /// 任一 surface 都必须至少保留一个来源，拒绝操作时配置保持原样。
    func testCannotDisableLastEnabledSource() async throws {
        let store = makeStore()
        _ = try await store.setEnabled(true, sourceID: .pexels, surface: .app)
        _ = try await store.setEnabled(false, sourceID: .openverse, surface: .app)
        let before = await store.snapshot()
        XCTAssertEqual(before.appSourceIDs, [.pexels])

        do {
            _ = try await store.setEnabled(false, sourceID: .pexels, surface: .app)
            XCTFail("不能停用最后一个 App 图片来源")
        } catch {
            XCTAssertEqual(error as? PhotoSourcePreferencesError, .noEnabledSources(.app))
        }
        let after = await store.snapshot()
        XCTAssertEqual(after, before)
    }

    /// 删除凭据触发跨范围停用时，应回退无凭据来源，不能留下空 surface。
    func testDisableEverywherePreservesLastSourceInvariant() async throws {
        let store = makeStore()
        _ = try await store.setEnabled(true, sourceID: .pexels, surface: .app)
        _ = try await store.setEnabled(false, sourceID: .openverse, surface: .app)
        let before = await store.snapshot()

        let updated = try await store.disableEverywhere(.pexels)
        let after = await store.snapshot()
        XCTAssertEqual(updated.revision, before.revision + 1)
        XCTAssertEqual(updated.appSourceIDs, [.openverse])
        XCTAssertEqual(updated.fileProviderSourceIDs, [.openverse])
        XCTAssertEqual(after, updated)
    }

    /// Finder 跟随 App 的来源开关，因此两端推荐键始终使用同一有效来源集合。
    func testRecommendationCatalogKeyUsesAppSourceSetForFinder() async throws {
        let store = makeStore()
        let environment = PhotoSearchEnvironment(
            preferences: store,
            credentials: EmptyPhotoCredentialStore()
        )

        let defaultAppKey = await environment.recommendationCatalogKey(for: .app)
        let defaultFinderKey = await environment.recommendationCatalogKey(for: .fileProvider)
        XCTAssertEqual(defaultAppKey, defaultFinderKey)
        XCTAssertTrue(defaultAppKey.hasSuffix(
            ":request-policy:\(PhotoSourceRequestPolicies.catalogVersion)"
        ))

        _ = try await store.setEnabled(true, sourceID: .pexels, surface: .app)
        let configuredAppKey = await environment.recommendationCatalogKey(for: .app)
        let configuredFinderKey = await environment.recommendationCatalogKey(for: .fileProvider)
        XCTAssertEqual(configuredAppKey, configuredFinderKey)

        _ = try await store.setEnabled(true, sourceID: .pexels, surface: .fileProvider)
        let sharedAppKey = await environment.recommendationCatalogKey(for: .app)
        let sharedFinderKey = await environment.recommendationCatalogKey(for: .fileProvider)
        XCTAssertEqual(sharedAppKey, sharedFinderKey)
    }

    private func makeStore() -> PhotoSourcePreferencesStore {
        let suiteName = "MirageCoreTests.PhotoSources.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PhotoSourcePreferencesStore(userDefaults: defaults)
    }
}

private actor EmptyPhotoCredentialStore: PhotoSourceCredentialStoring {
    func credential(for sourceID: PhotoSourceID) async throws -> String? { nil }
    func store(_ credential: String, for sourceID: PhotoSourceID) async throws {}
    func removeCredential(for sourceID: PhotoSourceID) async throws {}
}
