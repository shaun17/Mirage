import FileProvider
import Foundation
import MirageCore
import OSLog

/// 负责幂等安装、修复和刷新 Mirage 的 File Provider 域。
struct MirageDomainManager: Sendable {
    private static let logger = Logger(subsystem: "com.wenren.Mirage", category: "Domain")
    private static let displayName = "Mirage"
    enum RegistrationResult: Sendable {
        case installed
        case alreadyInstalled
        case repaired
    }

    static let domainIdentifier = NSFileProviderDomainIdentifier(
        MirageSystemIntegration.fileProviderDomainIdentifier
    )
    private static let legacyDomainIdentifiers = [
        NSFileProviderDomainIdentifier("mirage-default"),
        NSFileProviderDomainIdentifier("mirage-default-v2"),
        NSFileProviderDomainIdentifier("mirage-default-v3"),
        // v4 使用嵌套分页目录与 discover-page 条目 ID；扁平推荐流无法沿用旧系统副本。
        NSFileProviderDomainIdentifier("mirage-default-v4"),
        NSFileProviderDomainIdentifier("mirage-default-v5"),
        NSFileProviderDomainIdentifier("mirage-default-v6"),
        NSFileProviderDomainIdentifier("mirage-default-v7"),
        NSFileProviderDomainIdentifier("mirage-default-v8"),
        NSFileProviderDomainIdentifier("mirage-default-v9"),
        // v10 副本沿用了串行缩略图与无节流重扫时代的目录状态，且实机已出现
        // 「最近使用 2」这类重名残渣；迁移到 v11 由 removeAll 连副本一起清掉。
        NSFileProviderDomainIdentifier("mirage-default-v10")
    ]
    static let favoritesIdentifier = NSFileProviderItemIdentifier("favorites")

    /// 只把用户明确关闭扩展归为待启用，其余异常保留为可诊断错误。
    enum Availability: Sendable {
        case ready
        case needsActivation
    }

    /// 已存在同标识域时不重复添加；首次运行才提交完整能力配置。
    func registerIfNeeded() async throws -> RegistrationResult {
        let domains = try await installedDomains()
        if let existing = domains.first(where: { $0.identifier == Self.domainIdentifier }) {
            try await removeLegacyDomainIfNeeded(from: domains)
            if #available(macOS 26.0, *) {
                Self.logger.notice(
                    "读取现有域，字符串搜索：\(existing.supportsStringSearchRequest, privacy: .public)"
                )
            } else {
                Self.logger.notice("读取现有域；当前系统使用本地索引搜索")
            }
            guard !hasRequiredCapabilities(existing) else { return .alreadyInstalled }
            try await remove(existing)
            try await add(configuredDomain())
            return .repaired
        }
        let migratesLegacyDomain = domains.contains {
            Self.legacyDomainIdentifiers.contains($0.identifier)
        }
        try await removeLegacyDomainIfNeeded(from: domains)
        Self.logger.notice("安装 Mirage 文件域")
        try await add(configuredDomain())
        return migratesLegacyDomain ? .repaired : .installed
    }

    /// 旧域已经缓存了完整推荐流；迁移只删除系统占位符，App Group 资料库保持不变。
    private func removeLegacyDomainIfNeeded(
        from domains: [NSFileProviderDomain]
    ) async throws {
        for domain in domains where Self.legacyDomainIdentifiers.contains(domain.identifier) {
            Self.logger.notice("迁移旧 Mirage 文件域")
            try await remove(domain)
        }
    }

    /// 收藏变化后同时通知收藏目录和工作集，保证 Finder 与文件面板一致。
    func signalFavoritesChanged() async throws {
        guard let domain = try await installedDomains().first(where: {
            $0.identifier == Self.domainIdentifier
        }), let manager = NSFileProviderManager(for: domain) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try await manager.signalEnumerator(for: Self.favoritesIdentifier)
        try await manager.signalEnumerator(for: .workingSet)
    }

    /// 先读取系统公开的启用/断开状态，再以 URL 与 signal 验证完整运行链路。
    func refreshDiscoveryAndCheckAvailability() async throws -> Availability {
        guard let domain = try await installedDomains().first(where: {
            $0.identifier == Self.domainIdentifier
        }) else {
            throw ProviderAvailabilityError.missingDomain
        }
        guard domain.userEnabled else { return .needsActivation }
        guard !domain.isDisconnected else { throw ProviderAvailabilityError.disconnected }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw ProviderAvailabilityError.managerUnavailable
        }
        _ = try await manager.getUserVisibleURL(for: .rootContainer)
        // 只发轻量 signal 促使系统拉取差异。App 侧不再触发 reimportItems：
        // 整树重扫会引发全目录缩略图重放，被扩展的滚动泵误读成触底信号后
        // 会形成补页自激循环；副本真正滞后时由扩展侧泵按需升级重扫修复。
        try await manager.signalEnumerator(for: .rootContainer)
        try await manager.signalEnumerator(for: .workingSet)
        return .ready
    }

    /// 域只声明字符串搜索，不同步系统废纸篓。
    private func configuredDomain() -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.displayName
        )
        if #available(macOS 26.0, *) {
            domain.supportsStringSearchRequest = true
        }
        domain.supportsSyncingTrash = false
        return domain
    }

    /// 名称或能力与当前产品配置不一致时重建域，避免 macOS 长期缓存旧显示名。
    private func hasRequiredCapabilities(_ domain: NSFileProviderDomain) -> Bool {
        guard domain.displayName == Self.displayName else { return false }
        guard !domain.supportsSyncingTrash else { return false }
        if #available(macOS 26.0, *) {
            return domain.supportsStringSearchRequest
        }
        return true
    }

    /// 使用系统原生异步接口查询所有已注册域。
    private func installedDomains() async throws -> [NSFileProviderDomain] {
        try await NSFileProviderManager.domains()
    }

    /// 等待系统完成域安装，避免界面提前显示成功。
    private func add(_ domain: NSFileProviderDomain) async throws {
        try await NSFileProviderManager.add(domain)
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
