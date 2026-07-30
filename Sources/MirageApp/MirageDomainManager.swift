import FileProvider
import Foundation
import OSLog

/// 负责幂等安装、修复和刷新 Mirage 的 File Provider 域。
struct MirageDomainManager: Sendable {
    private static let logger = Logger(subsystem: "com.wenren.Mirage", category: "Domain")
    enum RegistrationResult: Sendable {
        case installed
        case alreadyInstalled
        case repaired
    }

    static let domainIdentifier = NSFileProviderDomainIdentifier("mirage-default")
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
        Self.logger.notice("安装 Mirage 文件域")
        try await add(configuredDomain())
        return .installed
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
        try await manager.signalEnumerator(for: .rootContainer)
        try await manager.signalEnumerator(for: .workingSet)
        return .ready
    }

    /// 域只声明字符串搜索，不同步系统废纸篓。
    private func configuredDomain() -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: "Mirage"
        )
        if #available(macOS 26.0, *) {
            domain.supportsStringSearchRequest = true
        }
        domain.supportsSyncingTrash = false
        return domain
    }

    /// 旧版本域若缺少搜索能力或错误同步废纸篓，则启动时自动替换为正确配置。
    private func hasRequiredCapabilities(_ domain: NSFileProviderDomain) -> Bool {
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

    /// 等待系统完成单个域卸载。
    private func remove(_ domain: NSFileProviderDomain) async throws {
        try await NSFileProviderManager.remove(domain)
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
