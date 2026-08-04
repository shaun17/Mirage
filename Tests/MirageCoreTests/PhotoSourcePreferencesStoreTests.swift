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
        XCTAssertEqual(snapshot.fileProviderSourceIDs, [.openverse, .pexels])
    }

    /// Settings 固定展示三个入口；Pixabay 当前开放 App 搜索，但 Finder 等待条款确认。
    func testRegistryIncludesAppOnlyPixabayAsThirdProvider() {
        XCTAssertEqual(PhotoSourceRegistry.descriptors.map(\.id), [.openverse, .pexels, .pixabay])
        let pixabay = PhotoSourceRegistry.descriptor(for: .pixabay)
        let pexels = PhotoSourceRegistry.descriptor(for: .pexels)
        XCTAssertEqual(pexels?.supportedSurfaces, [.app, .fileProvider])
        XCTAssertEqual(pixabay?.availability, .available)
        XCTAssertEqual(pixabay?.supportedSurfaces, [.app])
        XCTAssertEqual(pixabay?.allowsAutomatedRecommendations, false)
        XCTAssertEqual(pixabay?.allowsPersistentLibraryStorage, false)
        XCTAssertEqual(pixabay?.searchResultAttribution?.text, "Images provided by Pixabay")
        XCTAssertEqual(pixabay?.searchResultAttribution?.url.host, "pixabay.com")
        XCTAssertNotNil(pixabay?.searchResultAttribution?.note)
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

    /// Pixabay 可以进入 App 聚合，但不能越过 registry 开启 Finder File Provider。
    func testPixabayCanEnableAppButRejectsFileProvider() async throws {
        let store = makeStore()

        let updated = try await store.saveConfiguration(
            for: .pixabay,
            enabledSurfaces: [.app]
        )
        XCTAssertEqual(updated.appSourceIDs, [.openverse, .pixabay])
        XCTAssertEqual(updated.fileProviderSourceIDs, [.openverse])

        do {
            _ = try await store.setEnabled(true, sourceID: .pixabay, surface: .fileProvider)
            XCTFail("Pixabay 未获条款确认前不能用于 Finder")
        } catch {
            XCTAssertEqual(error as? PhotoSourcePreferencesError, .unsupportedSurface)
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot, updated)
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

    /// 推荐流在有效来源相同时继续跨进程共享；App 启用独占来源后才分离快照。
    func testRecommendationCatalogKeySeparatesOnlyDifferentSourceSets() async throws {
        let store = makeStore()
        let environment = PhotoSearchEnvironment(
            preferences: store,
            credentials: EmptyPhotoCredentialStore()
        )

        let defaultAppKey = await environment.recommendationCatalogKey(for: .app)
        let defaultFinderKey = await environment.recommendationCatalogKey(for: .fileProvider)
        XCTAssertEqual(defaultAppKey, defaultFinderKey)

        _ = try await store.setEnabled(true, sourceID: .pexels, surface: .app)
        let configuredAppKey = await environment.recommendationCatalogKey(for: .app)
        let configuredFinderKey = await environment.recommendationCatalogKey(for: .fileProvider)
        XCTAssertNotEqual(configuredAppKey, configuredFinderKey)

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
