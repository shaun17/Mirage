import Foundation
import MirageCore
import XCTest

@MainActor
final class PhotoSourceSettingsModelTests: XCTestCase {
    /// 已保存 Key 应在打开设置时回填，并且开关只在点击当前供应商的保存后才生效。
    func testLoadsSavedKeyAndStagesProviderConfigurationUntilSave() async throws {
        let preferences = makePreferences()
        let credentials = InMemoryPhotoSourceCredentialStore(values: [.pexels: "saved-key"])
        let model = makeModel(preferences: preferences, credentials: credentials)

        await model.load()

        XCTAssertEqual(model.credentialDrafts[.pexels], "saved-key")
        XCTAssertFalse(model.isEnabled(.pexels))
        model.setEnabled(true, sourceID: .pexels)
        XCTAssertTrue(model.isEnabled(.pexels))
        XCTAssertTrue(model.hasUnsavedChanges(for: .pexels))
        let stagedSnapshot = await preferences.snapshot()
        XCTAssertEqual(stagedSnapshot.appSourceIDs, [.openverse])
        XCTAssertEqual(stagedSnapshot.fileProviderSourceIDs, [.openverse])

        await model.saveConfiguration(for: .pexels)

        let savedSnapshot = await preferences.snapshot()
        XCTAssertEqual(savedSnapshot.appSourceIDs, [.openverse, .pexels])
        XCTAssertEqual(savedSnapshot.fileProviderSourceIDs, [.openverse, .pexels])
        XCTAssertEqual(model.credentialDrafts[.pexels], "saved-key")
        XCTAssertEqual(model.connectionMessages[.pexels], "设置已保存")
        XCTAssertFalse(model.hasUnsavedChanges(for: .pexels))
        let storeCalls = await credentials.storeCallCount()
        XCTAssertEqual(storeCalls, 0)
    }

    /// 需要 Key 的来源必须先填写草稿才能开启；无 Key 来源仍可直接切换。
    func testCredentialRequirementControlsOnlyTurningSourceOn() async {
        let preferences = makePreferences()
        let credentials = InMemoryPhotoSourceCredentialStore()
        let model = makeModel(preferences: preferences, credentials: credentials)
        await model.load()

        XCTAssertFalse(model.canEnable(.pexels))
        model.setEnabled(true, sourceID: .pexels)
        XCTAssertFalse(model.isEnabled(.pexels))

        model.setEnabled(false, sourceID: .openverse)
        model.setEnabled(true, sourceID: .openverse)
        XCTAssertTrue(model.isEnabled(.openverse))

        model.setCredentialDraft("  pexels-key  ", for: .pexels)
        XCTAssertTrue(model.canEnable(.pexels))
        model.setEnabled(true, sourceID: .pexels)
        XCTAssertTrue(model.isEnabled(.pexels))

        model.setCredentialDraft("   ", for: .pexels)
        XCTAssertFalse(model.canEnable(.pexels))
        XCTAssertTrue(model.isEnabled(.pexels))
        model.setEnabled(false, sourceID: .pexels)
        XCTAssertFalse(model.isEnabled(.pexels))
    }

    /// 页面级保存一次提交所有供应商草稿，而不是只保存当前标签页。
    func testSaveAllConfigurationsPersistsEveryModifiedProvider() async throws {
        let preferences = makePreferences()
        let credentials = InMemoryPhotoSourceCredentialStore()
        var changedSourceIDs: [PhotoSourceID] = []
        let model = makeModel(
            preferences: preferences,
            credentials: credentials,
            configurationDidChange: { changedSourceIDs.append($0) }
        )
        await model.load()

        model.setCredentialDraft("pexels-key", for: .pexels)
        model.setEnabled(true, sourceID: .pexels)
        model.setCredentialDraft("pixabay-key", for: .pixabay)
        model.setEnabled(true, sourceID: .pixabay)
        XCTAssertEqual(model.unsavedSourceIDs, [.pexels, .pixabay])

        await model.saveAllConfigurations()

        let snapshot = await preferences.snapshot()
        let storedPexelsKey = try await credentials.credential(for: .pexels)
        let storedPixabayKey = try await credentials.credential(for: .pixabay)
        XCTAssertEqual(snapshot.appSourceIDs, [.openverse, .pexels, .pixabay])
        XCTAssertEqual(snapshot.fileProviderSourceIDs, [.openverse, .pexels])
        XCTAssertEqual(storedPexelsKey, "pexels-key")
        XCTAssertEqual(storedPixabayKey, "pixabay-key")
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(changedSourceIDs, [.pexels, .pixabay])
    }

    /// 替换唯一来源时必须先保存新来源，再停用旧来源，不能被中间空状态拦截。
    func testSaveAllConfigurationsEnablesReplacementBeforeDisablingCurrentSource() async {
        let preferences = makePreferences()
        let credentials = InMemoryPhotoSourceCredentialStore()
        let model = makeModel(preferences: preferences, credentials: credentials)
        await model.load()

        model.setCredentialDraft("pexels-key", for: .pexels)
        model.setEnabled(true, sourceID: .pexels)
        model.setEnabled(false, sourceID: .openverse)

        await model.saveAllConfigurations()

        let snapshot = await preferences.snapshot()
        XCTAssertEqual(snapshot.appSourceIDs, [.pexels])
        XCTAssertEqual(snapshot.fileProviderSourceIDs, [.pexels])
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNil(model.notice)
    }

    /// Pixabay 使用独立 Key 与草稿，只能启用到主 App，不会越过 registry 写入 Finder。
    func testSavesPixabayForAppWithoutEnablingFinder() async throws {
        let preferences = makePreferences()
        let credentials = InMemoryPhotoSourceCredentialStore()
        var changedSourceIDs: [PhotoSourceID] = []
        let model = makeModel(
            preferences: preferences,
            credentials: credentials,
            configurationDidChange: { changedSourceIDs.append($0) }
        )
        await model.load()

        model.setCredentialDraft("pixabay-key", for: .pixabay)
        model.setEnabled(true, sourceID: .pixabay)
        await model.saveConfiguration(for: .pixabay)

        let snapshot = await preferences.snapshot()
        let storedKey = try await credentials.credential(for: .pixabay)
        XCTAssertEqual(snapshot.appSourceIDs, [.openverse, .pixabay])
        XCTAssertEqual(snapshot.fileProviderSourceIDs, [.openverse])
        XCTAssertEqual(storedKey, "pixabay-key")
        XCTAssertEqual(model.connectionMessages[.pixabay], "设置已保存")
        XCTAssertTrue(model.isEnabled(.pixabay))
        XCTAssertEqual(changedSourceIDs, [.pixabay])
    }

    /// 旧版本若只启用了部分范围，应保留为“已开启”草稿，并提示保存以补齐该供应商全部范围。
    func testPartialLegacyConfigurationLoadsEnabledAndStagesAllSupportedSurfaces() async throws {
        let preferences = makePreferences()
        _ = try await preferences.setEnabled(true, sourceID: .pexels, surface: .app)
        let credentials = InMemoryPhotoSourceCredentialStore(values: [.pexels: "saved-key"])
        let model = makeModel(preferences: preferences, credentials: credentials)

        await model.load()

        XCTAssertTrue(model.isEnabled(.pexels))
        XCTAssertTrue(model.hasUnsavedChanges(for: .pexels))
        let legacySnapshot = await preferences.snapshot()
        XCTAssertTrue(legacySnapshot.appSourceIDs.contains(.pexels))
        XCTAssertFalse(legacySnapshot.fileProviderSourceIDs.contains(.pexels))

        await model.saveConfiguration(for: .pexels)

        let normalizedSnapshot = await preferences.snapshot()
        XCTAssertTrue(normalizedSnapshot.appSourceIDs.contains(.pexels))
        XCTAssertTrue(normalizedSnapshot.fileProviderSourceIDs.contains(.pexels))
        XCTAssertFalse(model.hasUnsavedChanges(for: .pexels))
    }

    /// 单一开关关闭后应移除全部支持范围；即使 Key 已丢失也不能阻止停用。
    func testUnifiedToggleDisablesAllSupportedSurfacesWithoutCredential() async throws {
        let preferences = makePreferences()
        _ = try await preferences.setEnabled(true, sourceID: .pexels, surface: .app)
        _ = try await preferences.setEnabled(true, sourceID: .pexels, surface: .fileProvider)
        let credentials = InMemoryPhotoSourceCredentialStore()
        let model = makeModel(preferences: preferences, credentials: credentials)
        await model.load()

        XCTAssertTrue(model.isEnabled(.pexels))
        model.setEnabled(false, sourceID: .pexels)
        await model.saveConfiguration(for: .pexels)

        let snapshot = await preferences.snapshot()
        XCTAssertFalse(snapshot.appSourceIDs.contains(.pexels))
        XCTAssertFalse(snapshot.fileProviderSourceIDs.contains(.pexels))
        XCTAssertFalse(model.isEnabled(.pexels))
        XCTAssertFalse(model.hasUnsavedChanges(for: .pexels))
        let storedCredential = try await credentials.credential(for: .pexels)
        XCTAssertNil(storedCredential)
        XCTAssertNil(model.notice)
    }

    /// 新 Key 保存后继续作为 SecureField 内容；关闭重开会从持久存储恢复，而不是进入替换模式。
    func testSavedKeyRemainsVisibleAndReloadsAfterDraftDiscard() async throws {
        let preferences = makePreferences()
        let credentials = InMemoryPhotoSourceCredentialStore()
        let model = makeModel(preferences: preferences, credentials: credentials)
        await model.load()

        model.setCredentialDraft("new-key", for: .pexels)
        await model.saveConfiguration(for: .pexels)

        XCTAssertEqual(model.credentialDrafts[.pexels], "new-key")
        let storedCredential = try await credentials.credential(for: .pexels)
        XCTAssertEqual(storedCredential, "new-key")
        XCTAssertEqual(model.connectionMessages[.pexels], "设置已保存")

        model.discardDrafts()
        XCTAssertNil(model.credentialDrafts[.pexels])
        await model.load()
        XCTAssertEqual(model.credentialDrafts[.pexels], "new-key")
    }

    /// 已配置供应商输入新 Key 并保存后，应覆盖持久存储中的旧值。
    func testSavingNewCredentialOverwritesExistingCredential() async throws {
        let preferences = makePreferences()
        let credentials = InMemoryPhotoSourceCredentialStore(values: [.pexels: "old-key"])
        let model = makeModel(preferences: preferences, credentials: credentials)
        await model.load()

        model.setCredentialDraft("new-key", for: .pexels)
        XCTAssertTrue(model.hasUnsavedChanges(for: .pexels))

        await model.saveConfiguration(for: .pexels)

        let storedCredential = try await credentials.credential(for: .pexels)
        XCTAssertEqual(storedCredential, "new-key")
        XCTAssertEqual(model.credentialDrafts[.pexels], "new-key")
        XCTAssertTrue(model.configuredCredentialSourceIDs.contains(.pexels))
        XCTAssertFalse(model.hasUnsavedChanges(for: .pexels))
        let storeCalls = await credentials.storeCallCount()
        XCTAssertEqual(storeCalls, 1)
    }

    /// 若共享偏好提交失败，已经写入的 Key 必须恢复，不能留下半完成配置。
    func testPreferenceFailureRestoresPreviousCredential() async throws {
        let preferences = makePreferences()
        let credentials = InMemoryPhotoSourceCredentialStore(values: [.pexels: "saved-key"])
        let model = makeModel(preferences: preferences, credentials: credentials)
        await model.load()

        _ = try await preferences.setEnabled(true, sourceID: .pexels, surface: .app)
        _ = try await preferences.setEnabled(false, sourceID: .openverse, surface: .app)
        model.setCredentialDraft("new-key", for: .pexels)

        await model.saveConfiguration(for: .pexels)

        let storedCredential = try await credentials.credential(for: .pexels)
        XCTAssertEqual(storedCredential, "saved-key")
        XCTAssertEqual(model.credentialDrafts[.pexels], "new-key")
        XCTAssertNotNil(model.notice)
        let storeCalls = await credentials.storeCallCount()
        XCTAssertEqual(storeCalls, 2)
    }

    /// 补偿恢复也失败时，Model 应重新读取实际 Key，而不是继续声称旧 Key 已保存。
    func testCredentialRollbackFailureReloadsActualCredentialState() async throws {
        let preferences = makePreferences()
        let credentials = InMemoryPhotoSourceCredentialStore(
            values: [.pexels: "saved-key"],
            failingStoreCalls: [2]
        )
        let model = makeModel(preferences: preferences, credentials: credentials)
        await model.load()

        _ = try await preferences.setEnabled(true, sourceID: .pexels, surface: .app)
        _ = try await preferences.setEnabled(false, sourceID: .openverse, surface: .app)
        model.setCredentialDraft("new-key", for: .pexels)

        await model.saveConfiguration(for: .pexels)

        let storedCredential = try await credentials.credential(for: .pexels)
        XCTAssertEqual(storedCredential, "new-key")
        XCTAssertEqual(model.credentialDrafts[.pexels], "new-key")
        XCTAssertTrue(model.configuredCredentialSourceIDs.contains(.pexels))
        XCTAssertTrue(model.notice?.contains("无法恢复") == true)
    }

    /// 移除失败时先停用数据源并保留 Key，避免生产配置继续启用一个无凭据的数据源。
    func testCredentialRemovalFailureLeavesSourceDisabledAndCredentialIntact() async throws {
        let preferences = makePreferences()
        _ = try await preferences.setEnabled(true, sourceID: .pexels, surface: .app)
        let credentials = InMemoryPhotoSourceCredentialStore(
            values: [.pexels: "saved-key"],
            removalError: TestCredentialError.removalFailed
        )
        let model = makeModel(preferences: preferences, credentials: credentials)
        await model.load()

        await model.removeCredential(for: .pexels)

        let savedSnapshot = await preferences.snapshot()
        XCTAssertFalse(savedSnapshot.appSourceIDs.contains(.pexels))
        let storedCredential = try await credentials.credential(for: .pexels)
        XCTAssertEqual(storedCredential, "saved-key")
        XCTAssertTrue(model.configuredCredentialSourceIDs.contains(.pexels))
        XCTAssertEqual(model.connectionMessages[.pexels], "数据源已停用，API Key 未移除")
        XCTAssertNotNil(model.notice)
    }

    /// 移除一个供应商的 Key 只能重置该供应商，不能覆盖其他供应商尚未保存的草稿。
    func testCredentialRemovalPreservesOtherProviderDrafts() async throws {
        let preferences = makePreferences()
        _ = try await preferences.setEnabled(true, sourceID: .pexels, surface: .app)
        _ = try await preferences.setEnabled(true, sourceID: .pexels, surface: .fileProvider)
        let credentials = InMemoryPhotoSourceCredentialStore(values: [.pexels: "saved-key"])
        let model = makeModel(preferences: preferences, credentials: credentials)
        await model.load()
        model.setEnabled(false, sourceID: .openverse)
        XCTAssertTrue(model.hasUnsavedChanges(for: .openverse))

        await model.removeCredential(for: .pexels)

        XCTAssertFalse(model.isEnabled(.openverse))
        XCTAssertTrue(model.hasUnsavedChanges(for: .openverse))
        XCTAssertFalse(model.isEnabled(.pexels))
    }

    /// 分段切换或窗口关闭若先取消测试任务，Model 不应再写状态或启动请求。
    func testConnectionCancelledBeforeEntryDoesNotPublishState() async {
        let preferences = makePreferences()
        let credentials = InMemoryPhotoSourceCredentialStore()
        let model = makeModel(preferences: preferences, credentials: credentials)
        await model.load()

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.testConnection(for: .pexels)
        }
        await task.value

        XCTAssertNil(model.notice)
        XCTAssertNil(model.connectionMessages[.pexels])
        XCTAssertTrue(model.workingSourceIDs.isEmpty)
    }

    /// 点击保存后立即关闭窗口，也必须先完成已登记保存，再丢弃界面草稿。
    func testScheduledSaveSurvivesImmediateDraftDiscard() async throws {
        let preferences = makePreferences()
        let credentials = InMemoryPhotoSourceCredentialStore()
        let model = makeModel(preferences: preferences, credentials: credentials)
        await model.load()
        model.setCredentialDraft("new-key", for: .pexels)

        model.scheduleSaveAllConfigurations()
        model.discardDrafts()
        for _ in 0..<50 {
            let persisted = try await credentials.credential(for: .pexels)
            if persisted == "new-key",
               model.credentialDrafts[.pexels] == nil,
               model.workingSourceIDs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let stored = try await credentials.credential(for: .pexels)
        XCTAssertEqual(stored, "new-key")
        XCTAssertNil(model.credentialDrafts[.pexels])
        await model.load()
        XCTAssertEqual(model.credentialDrafts[.pexels], "new-key")
    }

    /// 保存尚未起跑时快速关闭并重开，新窗口不能被旧窗口的延迟清理清空。
    func testQuickReopenCancelsDeferredDraftDiscard() async throws {
        let preferences = makePreferences()
        let credentials = InMemoryPhotoSourceCredentialStore()
        let model = makeModel(preferences: preferences, credentials: credentials)
        await model.load()
        model.setCredentialDraft("new-key", for: .pexels)

        model.scheduleSaveAllConfigurations()
        model.discardDrafts()
        await model.load()
        XCTAssertTrue(model.scheduledSourceIDs.contains(.pexels))

        for _ in 0..<50 {
            let persisted = try await credentials.credential(for: .pexels)
            if persisted == "new-key",
               model.scheduledSourceIDs.isEmpty,
               model.workingSourceIDs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let persisted = try await credentials.credential(for: .pexels)
        XCTAssertEqual(persisted, "new-key")
        XCTAssertEqual(model.credentialDrafts[.pexels], "new-key")
        XCTAssertEqual(model.connectionMessages[.pexels], "设置已保存")
    }

    private func makePreferences() -> PhotoSourcePreferencesStore {
        let suiteName = "MirageCoreTests.PhotoSourceSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PhotoSourcePreferencesStore(userDefaults: defaults)
    }

    private func makeModel(
        preferences: PhotoSourcePreferencesStore,
        credentials: InMemoryPhotoSourceCredentialStore,
        configurationDidChange: @escaping PhotoSourceSettingsModel.ConfigurationDidChange = { _ in }
    ) -> PhotoSourceSettingsModel {
        PhotoSourceSettingsModel(
            environment: PhotoSearchEnvironment(
                preferences: preferences,
                credentials: credentials
            ),
            configurationDidChange: configurationDidChange
        )
    }
}

private actor InMemoryPhotoSourceCredentialStore: PhotoSourceCredentialStoring {
    private var values: [PhotoSourceID: String]
    private var storeCalls = 0
    private let removalError: TestCredentialError?
    private let failingStoreCalls: Set<Int>

    init(
        values: [PhotoSourceID: String] = [:],
        removalError: TestCredentialError? = nil,
        failingStoreCalls: Set<Int> = []
    ) {
        self.values = values
        self.removalError = removalError
        self.failingStoreCalls = failingStoreCalls
    }

    func credential(for sourceID: PhotoSourceID) async throws -> String? {
        values[sourceID]
    }

    func store(_ credential: String, for sourceID: PhotoSourceID) async throws {
        storeCalls += 1
        if failingStoreCalls.contains(storeCalls) {
            throw TestCredentialError.storeFailed
        }
        values[sourceID] = credential
    }

    func removeCredential(for sourceID: PhotoSourceID) async throws {
        if let removalError { throw removalError }
        values[sourceID] = nil
    }

    func storeCallCount() -> Int { storeCalls }
}

private enum TestCredentialError: Error {
    case removalFailed
    case storeFailed
}
