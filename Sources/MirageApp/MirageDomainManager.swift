import FileProvider
import Foundation
import MirageCore
import OSLog

/// 负责幂等安装、修复和刷新 Mirage 的 File Provider 域。
struct MirageDomainManager: Sendable {
    private static let logger = Logger(subsystem: "com.wenren.Mirage", category: "Domain")
    private static let displayName = "Mirage"
    private static let avatarCatalogRefreshVersion = 3
    private static let avatarCatalogRefreshVersionKey =
        "finder-avatar-catalog-refresh-version-v1"
    enum RegistrationResult: Sendable {
        case installed
        case alreadyInstalled
        case repaired
    }

    private static let maximumRegistrationAttempts = 5

    /// 只把用户明确关闭扩展归为待启用，其余异常保留为可诊断错误。
    enum Availability: Sendable {
        case ready
        case needsActivation
    }

    /// 域标识跨 App 版本保持稳定；仅在首次迁移时移除历史版本域及其 Finder 副本。
    func registerIfNeeded() async throws -> RegistrationResult {
        // 必须在任何 remove/add 前验证宿主与内嵌扩展来自同一构建，防止混合产物误删有效域。
        let domainIdentifier = try synchronizedDomainIdentifier()
        var repaired = false

        for attempt in 1...Self.maximumRegistrationAttempts {
            do {
                let domains = try await installedDomains()
                repaired = try await removeOutdatedDomains(
                    from: domains,
                    desiredIdentifier: domainIdentifier
                ) || repaired

                if let existing = domains.first(where: { $0.identifier == domainIdentifier }) {
                    logCapabilities(of: existing)
                    guard !hasRequiredCapabilities(existing) else {
                        return repaired ? .repaired : .alreadyInstalled
                    }
                    Self.logger.notice(
                        "原位更新 Mirage 文件域：\(domainIdentifier.rawValue, privacy: .public)"
                    )
                    try await add(configuredDomain(identifier: domainIdentifier))
                    return .repaired
                }

                let resetAnchor = try await resetProviderPublicationState()
                Self.logger.notice(
                    "已为新文件域重置发布索引，新锚点：\(resetAnchor, privacy: .public)"
                )
                Self.logger.notice(
                    "安装 Mirage 文件域：\(domainIdentifier.rawValue, privacy: .public)"
                )
                try await add(configuredDomain(identifier: domainIdentifier))
                return repaired ? .repaired : .installed
            } catch {
                guard attempt < Self.maximumRegistrationAttempts,
                      isRecoverableRegistrationRace(error) else {
                    throw error
                }
                // 另一个 App 实例可能刚完成注册，或 removeAll 的挂载点仍在异步收尾。
                // 用递增退避重新读取完整系统状态，也覆盖重复 remove 时的 noSuchItem 竞态。
                let retryDelayMilliseconds = 250 << (attempt - 1)
                Self.logger.notice(
                    "Finder 域状态发生竞态，等待 \(retryDelayMilliseconds, privacy: .public)ms 后重新同步"
                )
                try await Task.sleep(for: .milliseconds(retryDelayMilliseconds))
            }
        }

        throw CocoaError(.fileWriteFileExists)
    }

    /// 旧域已经缓存了过时目录结构；只删除系统占位符，App Group 内容资料库保持不变。
    private func removeOutdatedDomains(
        from domains: [NSFileProviderDomain],
        desiredIdentifier: NSFileProviderDomainIdentifier
    ) async throws -> Bool {
        var removedDomain = false
        for domain in domains where domain.identifier != desiredIdentifier
            && MirageSystemIntegration.isManagedFileProviderDomainIdentifier(
                domain.identifier.rawValue
            ) {
            Self.logger.notice(
                "迁移不匹配的 Mirage 文件域：\(domain.identifier.rawValue, privacy: .public)"
            )
            try await remove(domain)
            removedDomain = true
        }
        return removedDomain
    }

    private func logCapabilities(of domain: NSFileProviderDomain) {
        if #available(macOS 26.0, *) {
            Self.logger.notice(
                "读取现有域，字符串搜索：\(domain.supportsStringSearchRequest, privacy: .public)"
            )
        } else {
            Self.logger.notice("读取现有域；当前系统使用本地索引搜索")
        }
    }

    /// add/remove 的系统回调可能多层包装 Cocoa 516 或并发清理产生的 noSuchItem。
    private func isRecoverableRegistrationRace(_ error: Error) -> Bool {
        errorChainContains(error) { candidate in
            if candidate.domain == NSCocoaErrorDomain {
                return candidate.code == CocoaError.fileWriteFileExists.rawValue
                    || candidate.code == CocoaError.fileNoSuchFile.rawValue
            }
            return candidate.domain == NSFileProviderErrorDomain
                && candidate.code == NSFileProviderError.Code.noSuchItem.rawValue
        }
    }

    /// 限制最多检查八层 underlying error，既覆盖系统包装也避免异常错误链循环。
    private func errorChainContains(
        _ error: Error,
        matching predicate: (NSError) -> Bool
    ) -> Bool {
        var candidate: NSError? = error as NSError
        for _ in 0..<8 {
            guard let currentError = candidate else { return false }
            if predicate(currentError) { return true }
            candidate = currentError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Replicated File Provider 只接受 working set signal，系统会把收藏差异投影到目录。
    func signalFavoritesChanged() async throws {
        try await signalWorkingSet()
    }

    /// 主 App 持久化推荐快照变更后主动唤醒扩展，避免 Finder 长期停留在旧批次。
    func signalDiscoveryChanged() async throws {
        try await signalWorkingSet()
    }

    /// 图片来源变化先让在途旧枚举失效，再同步唤醒根目录和 working set。
    func signalPhotoFilterChanged() async throws {
        let manager = try await currentManager()
        let storage = try AppGroupStorage()
        _ = try await storage.advanceProviderPublicationEpoch()
        try await signalEnumerators(
            [.rootContainer, .workingSet],
            using: manager
        )
    }

    /// Replicated File Provider 只接受 working set signal；扩展会在该快照中原子重建已发布头像 scope。
    func signalAvatarFilterChanged() async throws {
        let manager = try await currentManager()
        let storage = try AppGroupStorage()
        _ = try await storage.advanceProviderPublicationEpoch()
        try await manager.signalEnumerator(for: .workingSet)
    }

    /// 首次运行支持完整头像类型的版本时主动淘汰旧 Finder 树；成功后不再重复刷新。
    func refreshAvatarCatalogAfterUpgradeIfNeeded() async throws {
        guard let defaults = UserDefaults(suiteName: AppGroupStorage.appGroupIdentifier) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard defaults.integer(forKey: Self.avatarCatalogRefreshVersionKey)
                < Self.avatarCatalogRefreshVersion else {
            return
        }
        try await signalAvatarFilterChanged()
        defaults.set(
            Self.avatarCatalogRefreshVersion,
            forKey: Self.avatarCatalogRefreshVersionKey
        )
    }

    /// 其他 App 侧变更沿用 working set 全局刷新入口。
    private func signalWorkingSet() async throws {
        try await signalEnumerators([.workingSet])
    }

    /// Apple 允许按具体文件夹通知；同一批标识依次完成，避免系统收到失序刷新。
    private func signalEnumerators(
        _ identifiers: [NSFileProviderItemIdentifier]
    ) async throws {
        let manager = try await currentManager()
        try await signalEnumerators(identifiers, using: manager)
    }

    private func signalEnumerators(
        _ identifiers: [NSFileProviderItemIdentifier],
        using manager: NSFileProviderManager
    ) async throws {
        for identifier in identifiers {
            try await manager.signalEnumerator(for: identifier)
        }
    }

    private func currentManager() async throws -> NSFileProviderManager {
        let domainIdentifier = try synchronizedDomainIdentifier()
        guard let domain = try await installedDomains().first(where: {
            $0.identifier == domainIdentifier
        }), let manager = NSFileProviderManager(for: domain) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return manager
    }

    /// 先读取系统公开的启用/断开状态，再以 URL 与 signal 验证完整运行链路。
    func refreshDiscoveryAndCheckAvailability() async throws -> Availability {
        let domainIdentifier = try synchronizedDomainIdentifier()
        guard let domain = try await installedDomains().first(where: {
            $0.identifier == domainIdentifier
        }) else {
            throw ProviderAvailabilityError.missingDomain
        }
        guard domain.userEnabled else { return .needsActivation }
        guard !domain.isDisconnected else { throw ProviderAvailabilityError.disconnected }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw ProviderAvailabilityError.managerUnavailable
        }
        _ = try await manager.getUserVisibleURL(for: .rootContainer)
        // 只发系统支持的 working set signal；每个推荐目录都是固定批次，
        // 后续 40 张仅在用户显式打开“更多图片”目录时发布。
        try await manager.signalEnumerator(for: .workingSet)
        return .ready
    }

    /// 域只声明字符串搜索，不同步系统废纸篓。
    private func configuredDomain(
        identifier: NSFileProviderDomainIdentifier
    ) -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(
            identifier: identifier,
            displayName: Self.displayName
        )
        domain.isHidden = false
        if #available(macOS 26.0, *) {
            domain.supportsStringSearchRequest = true
        }
        domain.supportsSyncingTrash = false
        return domain
    }

    /// 名称、可见性或能力不一致时原位更新域，保留 Finder 对稳定域的引用。
    private func hasRequiredCapabilities(_ domain: NSFileProviderDomain) -> Bool {
        guard domain.displayName == Self.displayName else { return false }
        guard !domain.isHidden else { return false }
        guard !domain.supportsSyncingTrash else { return false }
        if #available(macOS 26.0, *) {
            return domain.supportsStringSearchRequest
        }
        return true
    }

    /// App 与 appex 的 CFBundleVersion 必须相同，且必须先于任何系统域变更完成验证。
    private func synchronizedDomainIdentifier() throws -> NSFileProviderDomainIdentifier {
        let appBuildVersion = try buildVersion(
            in: Bundle.main,
            missingError: .invalidAppBuildVersion
        )
        guard let plugInsURL = Bundle.main.builtInPlugInsURL,
              let extensionBundle = Bundle(
                  url: plugInsURL.appendingPathComponent(
                      MirageSystemIntegration.fileProviderExtensionBundleName,
                      isDirectory: true
                  )
              ) else {
            throw DomainVersionError.missingEmbeddedExtension
        }
        let extensionBuildVersion = try buildVersion(
            in: extensionBundle,
            missingError: .invalidExtensionBuildVersion
        )
        guard let rawIdentifier = MirageSystemIntegration.synchronizedFileProviderDomainIdentifier(
            appBuildVersion: appBuildVersion,
            fileProviderBuildVersion: extensionBuildVersion
        ) else {
            throw DomainVersionError.buildVersionMismatch(
                app: appBuildVersion,
                fileProvider: extensionBuildVersion
            )
        }
        return NSFileProviderDomainIdentifier(rawIdentifier)
    }

    private func buildVersion(
        in bundle: Bundle,
        missingError: DomainVersionError
    ) throws -> String {
        let rawVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let normalized = MirageSystemIntegration.normalizedBuildVersion(rawVersion) else {
            throw missingError
        }
        return normalized
    }

    /// 使用系统原生异步接口查询所有已注册域。
    private func installedDomains() async throws -> [NSFileProviderDomain] {
        try await NSFileProviderManager.domains()
    }

    /// 等待系统完成域安装，避免界面提前显示成功。
    private func add(_ domain: NSFileProviderDomain) async throws {
        try await NSFileProviderManager.add(domain)
    }

    /// 新系统域不能复用旧域的 scope、差异历史和已打开深度，否则会立即重建历史占位树。
    private func resetProviderPublicationState() async throws -> UInt64 {
        let storage = try AppGroupStorage()
        return try await storage.resetProviderPublicationState()
    }

    /// 等待系统完成单个域卸载，并连同本地副本一起清除。
    ///
    /// 必须显式指定 `.removeAll`：单参数版本会把已下载和占位文件留在挂载路径上。
    /// 下一个域挂到同一路径后会把这些遗留当成「用户新建的本地文件」反复尝试上传，
    /// 而只读 provider 一律拒绝，于是陷入每秒数次的 createItem 重试风暴，
    /// 把缩略图请求彻底饿死——表现就是目录里的图片全部显示不出来。
    private func remove(_ domain: NSFileProviderDomain) async throws {
        try await NSFileProviderManager.remove(domain, mode: .removeAll)
    }

}

/// 阻止 App 与内嵌扩展版本漂移时继续修改 Finder 域，并向界面给出明确诊断。
private enum DomainVersionError: LocalizedError {
    case invalidAppBuildVersion
    case missingEmbeddedExtension
    case invalidExtensionBuildVersion
    case buildVersionMismatch(app: String, fileProvider: String)

    var errorDescription: String? {
        switch self {
        case .invalidAppBuildVersion:
            return "Mirage App 缺少有效构建号，未修改 Finder 文件域。"
        case .missingEmbeddedExtension:
            return "Mirage 未包含 File Provider 扩展，未修改 Finder 文件域。"
        case .invalidExtensionBuildVersion:
            return "Mirage File Provider 缺少有效构建号，未修改 Finder 文件域。"
        case let .buildVersionMismatch(app, fileProvider):
            return "Mirage App（\(app)）与 File Provider（\(fileProvider)）构建号不一致，未修改 Finder 文件域。"
        }
    }
}

/// File Provider 已启用但运行状态异常时给出区别于“待启用”的明确错误。
private enum ProviderAvailabilityError: LocalizedError {
    case missingDomain
    case disconnected
    case managerUnavailable

    var errorDescription: String? {
        switch self {
        case .missingDomain: return "Mirage 文件域尚未注册。"
        case .disconnected: return "Mirage 文件域已断开，请稍后重新检查。"
        case .managerUnavailable: return "系统暂时无法打开 Mirage 文件域。"
        }
    }
}
