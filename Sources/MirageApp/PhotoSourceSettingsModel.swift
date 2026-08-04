import Foundation
import MirageCore

/// 设置页维护每个供应商的独立草稿；只有底部保存操作才会写入生产配置。
@MainActor
final class PhotoSourceSettingsModel: ObservableObject {
    typealias ConfigurationDidChange = @MainActor @Sendable (PhotoSourceID) async -> Void

    @Published private(set) var snapshot = PhotoSourcePreferencesSnapshot()
    @Published private(set) var configuredCredentialSourceIDs = Set<PhotoSourceID>()
    @Published private(set) var workingSourceIDs = Set<PhotoSourceID>()
    @Published private(set) var scheduledSourceIDs = Set<PhotoSourceID>()
    @Published private(set) var connectionMessages: [PhotoSourceID: String] = [:]
    @Published private(set) var successfulConnectionSourceIDs = Set<PhotoSourceID>()
    @Published var credentialDrafts: [PhotoSourceID: String] = [:]
    @Published var notice: String?
    @Published private var enabledSurfaceDrafts: [PhotoSourceID: Set<PhotoSourceSurface>] = [:]
    @Published private(set) var isLoading = false

    let descriptors = PhotoSourceRegistry.descriptors

    private let preferences: PhotoSourcePreferencesStore
    private let credentials: any PhotoSourceCredentialStoring
    private let environment: PhotoSearchEnvironment
    private let configurationDidChange: ConfigurationDidChange
    private var savedCredentials: [PhotoSourceID: String] = [:]
    private var hasLoaded = false
    private var scheduledOperationCount = 0
    private var shouldDiscardWhenIdle = false

    init(
        environment: PhotoSearchEnvironment,
        configurationDidChange: @escaping ConfigurationDidChange = { _ in }
    ) {
        self.environment = environment
        preferences = environment.preferences
        credentials = environment.credentials
        self.configurationDidChange = configurationDidChange
    }

    /// 打开设置时读取已保存配置，并把 API Key 回填到 SecureField 作为掩码内容。
    func load() async {
        // 新一轮展示接管当前状态，旧窗口留下的延迟清理不得作用到新窗口。
        shouldDiscardWhenIdle = false
        while isLoading {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
        }
        guard !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }

        // 关闭设置后仍在完成的保存/移除必须先落稳；快速重开只读取最终持久状态。
        while !workingSourceIDs.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
        }

        let loadedSnapshot = await preferences.snapshot()
        var loadedCredentials: [PhotoSourceID: String] = [:]
        var didFail = false
        for descriptor in descriptors
        where descriptor.availability == .available
            && descriptor.credentialRequirement == .apiKey {
            do {
                if let value = try await credentials.credential(for: descriptor.id), !value.isEmpty {
                    loadedCredentials[descriptor.id] = value
                }
            } catch {
                didFail = true
                notice = "无法读取 \(descriptor.displayName) API Key：\(error.localizedDescription)"
            }
        }
        guard !Task.isCancelled else { return }

        snapshot = loadedSnapshot
        enabledSurfaceDrafts = Self.surfaceDrafts(from: loadedSnapshot, descriptors: descriptors)
        savedCredentials = loadedCredentials
        credentialDrafts = loadedCredentials
        configuredCredentialSourceIDs = Set(loadedCredentials.keys)
        hasLoaded = !didFail
    }

    func isEnabled(_ sourceID: PhotoSourceID) -> Bool {
        guard let descriptor = PhotoSourceRegistry.descriptor(for: sourceID),
              !descriptor.supportedSurfaces.isEmpty else { return false }
        return enabledSurfaceDrafts[sourceID, default: []] == descriptor.supportedSurfaces
    }

    /// 一个供应商只显示一个开关；开启时覆盖其全部受支持范围，关闭时全部停用。
    func setEnabled(_ enabled: Bool, sourceID: PhotoSourceID) {
        guard !isLoading else { return }
        guard let descriptor = PhotoSourceRegistry.descriptor(for: sourceID),
              descriptor.availability == .available else { return }
        enabledSurfaceDrafts[sourceID] = enabled ? descriptor.supportedSurfaces : []
        clearStatus(for: sourceID)
    }

    func hasUnsavedChanges(for sourceID: PhotoSourceID) -> Bool {
        let savedSurfaces = Self.surfaces(for: sourceID, in: snapshot)
        if enabledSurfaceDrafts[sourceID, default: []] != savedSurfaces { return true }
        guard PhotoSourceRegistry.descriptor(for: sourceID)?.credentialRequirement == .apiKey else {
            return false
        }
        let draft = normalizedCredentialDraft(for: sourceID)
        // 停用状态下的空输入不代表删除凭据；设置页没有“移除 Key”语义。
        if !isEnabled(sourceID), draft.isEmpty { return false }
        return draft != savedCredentials[sourceID, default: ""]
    }

    /// 一次保存当前供应商的 API Key 与全部使用范围，并只触发一次配置刷新。
    func saveConfiguration(for sourceID: PhotoSourceID) async {
        guard !isLoading, workingSourceIDs.isEmpty else { return }
        guard let descriptor = PhotoSourceRegistry.descriptor(for: sourceID),
              descriptor.availability == .available else {
            notice = "\(sourceName(sourceID)) 正在适配。"
            return
        }

        let draft = normalizedCredentialDraft(for: sourceID)
        let requiresCredential = descriptor.credentialRequirement == .apiKey
        let shouldPersistCredential = requiresCredential && !draft.isEmpty
        if requiresCredential, isEnabled(sourceID), draft.isEmpty {
            notice = "API Key 不能为空。"
            return
        }
        do {
            try validateDraftConfiguration(for: descriptor)
        } catch {
            notice = error.localizedDescription
            return
        }

        workingSourceIDs.insert(sourceID)
        defer { finishWorking(on: sourceID) }
        do {
            // 停用且 Key 不可读时仍应能保存关闭状态；非空草稿则继续支持直接覆盖旧 Key。
            let previousCredential = shouldPersistCredential
                ? try await credentials.credential(for: sourceID)
                : nil
            let credentialChanged = shouldPersistCredential && draft != previousCredential
            if credentialChanged {
                try await credentials.store(draft, for: sourceID)
            }

            let previousRevision = snapshot.revision
            do {
                snapshot = try await preferences.saveConfiguration(
                    for: sourceID,
                    enabledSurfaces: enabledSurfaceDrafts[sourceID, default: []],
                    invalidateConfiguration: credentialChanged
                )
            } catch let preferenceError {
                if credentialChanged {
                    do {
                        try await restoreCredential(previousCredential, for: sourceID)
                    } catch let restorationError {
                        let didReload = await reloadCredentialState(for: sourceID)
                        notice = didReload
                            ? "设置未保存，API Key 也无法恢复；已重新载入当前实际状态：\(restorationError.localizedDescription)"
                            : "设置未保存，API Key 无法恢复且状态无法重新读取；请关闭设置后重试。"
                        return
                    }
                }
                throw preferenceError
            }
            enabledSurfaceDrafts[sourceID] = Self.surfaces(for: sourceID, in: snapshot)
            if shouldPersistCredential {
                savedCredentials[sourceID] = draft
                credentialDrafts[sourceID] = draft
                configuredCredentialSourceIDs.insert(sourceID)
            }
            successfulConnectionSourceIDs.remove(sourceID)
            connectionMessages[sourceID] = "设置已保存"
            if snapshot.revision != previousRevision {
                await configurationDidChange(sourceID)
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func removeCredential(for sourceID: PhotoSourceID) async {
        guard !isLoading, workingSourceIDs.isEmpty else { return }
        workingSourceIDs.insert(sourceID)
        defer { finishWorking(on: sourceID) }
        do {
            let previousRevision = snapshot.revision
            snapshot = try await preferences.disableEverywhere(sourceID)
            enabledSurfaceDrafts[sourceID] = Self.surfaces(for: sourceID, in: snapshot)
            let configurationChanged = snapshot.revision != previousRevision
            do {
                try await credentials.removeCredential(for: sourceID)
            } catch {
                successfulConnectionSourceIDs.remove(sourceID)
                connectionMessages[sourceID] = "数据源已停用，API Key 未移除"
                if configurationChanged {
                    await configurationDidChange(sourceID)
                }
                notice = "\(sourceName(sourceID)) 已停用，但 API Key 未能移除：\(error.localizedDescription)"
                return
            }
            configuredCredentialSourceIDs.remove(sourceID)
            successfulConnectionSourceIDs.remove(sourceID)
            savedCredentials[sourceID] = nil
            credentialDrafts[sourceID] = ""
            connectionMessages[sourceID] = "API Key 已移除，数据源已停用"
            if configurationChanged {
                await configurationDidChange(sourceID)
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    /// 测试始终使用当前输入框内容，不保存，也不改变已生效的搜索配置。
    func testConnection(for sourceID: PhotoSourceID) async {
        guard !Task.isCancelled,
              !isLoading,
              workingSourceIDs.isEmpty,
              scheduledSourceIDs.isEmpty else { return }
        guard PhotoSourceRegistry.descriptor(for: sourceID)?.availability == .available else {
            notice = "\(sourceName(sourceID)) 正在适配。"
            return
        }
        let draft = normalizedCredentialDraft(for: sourceID)
        guard !draft.isEmpty else {
            notice = "API Key 不能为空。"
            return
        }

        clearStatus(for: sourceID)
        workingSourceIDs.insert(sourceID)
        defer { finishWorking(on: sourceID) }
        do {
            try Task.checkCancellation()
            try await environment.testConnection(sourceID: sourceID, credential: draft)
            guard shouldPublishTestResult(for: sourceID, testedDraft: draft) else { return }
            successfulConnectionSourceIDs.insert(sourceID)
            connectionMessages[sourceID] = hasUnsavedChanges(for: sourceID)
                ? "连接成功；保存后生效"
                : "连接成功"
        } catch {
            guard shouldPublishTestResult(for: sourceID, testedDraft: draft) else { return }
            successfulConnectionSourceIDs.remove(sourceID)
            connectionMessages[sourceID] = error.localizedDescription
        }
    }

    func dismissNotice() {
        notice = nil
    }

    func setCredentialDraft(_ value: String, for sourceID: PhotoSourceID) {
        guard !isLoading else { return }
        credentialDrafts[sourceID] = value
        clearStatus(for: sourceID)
    }

    /// 按钮事件同步登记操作，窗口立即关闭时不会先清空尚待保存的草稿。
    func scheduleSaveConfiguration(for sourceID: PhotoSourceID) {
        guard scheduledOperationCount == 0, workingSourceIDs.isEmpty else { return }
        scheduledOperationCount += 1
        scheduledSourceIDs.insert(sourceID)
        Task { [self] in
            await saveConfiguration(for: sourceID)
            finishScheduledOperation(for: sourceID)
        }
    }

    func scheduleCredentialRemoval(for sourceID: PhotoSourceID) {
        guard scheduledOperationCount == 0, workingSourceIDs.isEmpty else { return }
        scheduledOperationCount += 1
        scheduledSourceIDs.insert(sourceID)
        Task { [self] in
            await removeCredential(for: sourceID)
            finishScheduledOperation(for: sourceID)
        }
    }

    /// 关闭窗口时丢弃未保存草稿；下次打开会重新读取并回填已保存的 Key。
    func discardDrafts() {
        guard scheduledOperationCount == 0, workingSourceIDs.isEmpty else {
            shouldDiscardWhenIdle = true
            return
        }
        resetDrafts()
    }

    private func resetDrafts() {
        credentialDrafts = [:]
        savedCredentials = [:]
        configuredCredentialSourceIDs = []
        enabledSurfaceDrafts = Self.surfaceDrafts(from: snapshot, descriptors: descriptors)
        connectionMessages = [:]
        successfulConnectionSourceIDs = []
        scheduledSourceIDs = []
        notice = nil
        hasLoaded = false
        shouldDiscardWhenIdle = false
    }

    private func finishWorking(on sourceID: PhotoSourceID) {
        workingSourceIDs.remove(sourceID)
        discardWhenIdleIfNeeded()
    }

    private func finishScheduledOperation(for sourceID: PhotoSourceID) {
        scheduledOperationCount = max(scheduledOperationCount - 1, 0)
        scheduledSourceIDs.remove(sourceID)
        discardWhenIdleIfNeeded()
    }

    private func discardWhenIdleIfNeeded() {
        guard shouldDiscardWhenIdle,
              scheduledOperationCount == 0,
              workingSourceIDs.isEmpty else { return }
        resetDrafts()
    }

    private func clearStatus(for sourceID: PhotoSourceID) {
        connectionMessages[sourceID] = nil
        successfulConnectionSourceIDs.remove(sourceID)
    }

    /// 凭据与共享偏好分属两个系统存储；第二步失败时补偿恢复第一步，保持一次保存的语义。
    private func restoreCredential(_ credential: String?, for sourceID: PhotoSourceID) async throws {
        if let credential, !credential.isEmpty {
            try await credentials.store(credential, for: sourceID)
        } else {
            try await credentials.removeCredential(for: sourceID)
        }
    }

    /// 补偿恢复也失败时，以持久存储的真实值重新校准 UI，避免继续显示旧状态。
    private func reloadCredentialState(for sourceID: PhotoSourceID) async -> Bool {
        do {
            if let credential = try await credentials.credential(for: sourceID), !credential.isEmpty {
                savedCredentials[sourceID] = credential
                credentialDrafts[sourceID] = credential
                configuredCredentialSourceIDs.insert(sourceID)
            } else {
                savedCredentials[sourceID] = nil
                credentialDrafts[sourceID] = ""
                configuredCredentialSourceIDs.remove(sourceID)
            }
            successfulConnectionSourceIDs.remove(sourceID)
            return true
        } catch {
            savedCredentials[sourceID] = nil
            credentialDrafts[sourceID] = ""
            configuredCredentialSourceIDs.remove(sourceID)
            successfulConnectionSourceIDs.remove(sourceID)
            hasLoaded = false
            return false
        }
    }

    private func validateDraftConfiguration(for descriptor: PhotoSourceDescriptor) throws {
        let selectedSurfaces = enabledSurfaceDrafts[descriptor.id, default: []]
        for surface in PhotoSourceSurface.allCases where descriptor.supports(surface) {
            var sourceIDs = snapshot.sourceIDs(for: surface).filter { $0 != descriptor.id }
            if selectedSurfaces.contains(surface) {
                sourceIDs.append(descriptor.id)
            }
            guard !sourceIDs.isEmpty else {
                throw PhotoSourcePreferencesError.noEnabledSources(surface)
            }
        }
    }

    private func normalizedCredentialDraft(for sourceID: PhotoSourceID) -> String {
        credentialDrafts[sourceID, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sourceName(_ sourceID: PhotoSourceID) -> String {
        PhotoSourceRegistry.descriptor(for: sourceID)?.displayName ?? sourceID.rawValue
    }

    private func shouldPublishTestResult(for sourceID: PhotoSourceID, testedDraft: String) -> Bool {
        guard !Task.isCancelled else { return false }
        return normalizedCredentialDraft(for: sourceID) == testedDraft
    }

    private static func surfaceDrafts(
        from snapshot: PhotoSourcePreferencesSnapshot,
        descriptors: [PhotoSourceDescriptor]
    ) -> [PhotoSourceID: Set<PhotoSourceSurface>] {
        Dictionary(uniqueKeysWithValues: descriptors.map { descriptor in
            let savedSurfaces = surfaces(for: descriptor.id, in: snapshot)
            let isEnabled = !savedSurfaces.isDisjoint(with: descriptor.supportedSurfaces)
            return (descriptor.id, isEnabled ? descriptor.supportedSurfaces : [])
        })
    }

    private static func surfaces(
        for sourceID: PhotoSourceID,
        in snapshot: PhotoSourcePreferencesSnapshot
    ) -> Set<PhotoSourceSurface> {
        Set(PhotoSourceSurface.allCases.filter { snapshot.sourceIDs(for: $0).contains(sourceID) })
    }
}
