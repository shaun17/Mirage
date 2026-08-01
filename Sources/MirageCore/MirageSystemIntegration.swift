import Foundation

/// 主 App 与 File Provider 共用的系统集成身份，避免两个进程各自硬编码后发生漂移。
public enum MirageSystemIntegration {
    public static let fileProviderExtensionBundleName = "MirageFileProvider.appex"
    private static let legacyFileProviderDomainIdentifier = "mirage-default"
    private static let versionedFileProviderDomainPrefix = "mirage-default-v"

    /// CFBundleVersion 仅接受数字和最多三个点分段，避免静默清洗造成两个构建号映射到同一域。
    public static func normalizedBuildVersion(_ buildVersion: String?) -> String? {
        let trimmed = buildVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count),
              components.allSatisfy({ component in
                  !component.isEmpty && component.utf8.allSatisfy { (48...57).contains($0) }
              }) else {
            return nil
        }
        return components.joined(separator: ".")
    }

    /// 域版本直接跟随宿主 App 的构建号，避免新 App 继续连接旧 Finder 副本。
    public static func fileProviderDomainIdentifier(buildVersion: String?) -> String? {
        guard let normalized = normalizedBuildVersion(buildVersion) else { return nil }
        return versionedFileProviderDomainPrefix + normalized
    }

    /// 只有宿主与内嵌扩展构建号完全一致时才生成目标域，供注册前的无副作用校验使用。
    public static func synchronizedFileProviderDomainIdentifier(
        appBuildVersion: String?,
        fileProviderBuildVersion: String?
    ) -> String? {
        guard let appBuildVersion = normalizedBuildVersion(appBuildVersion),
              let fileProviderBuildVersion = normalizedBuildVersion(fileProviderBuildVersion),
              appBuildVersion == fileProviderBuildVersion else {
            return nil
        }
        return versionedFileProviderDomainPrefix + appBuildVersion
    }

    /// 识别所有由 Mirage 创建过的域；升级和回退都必须清理与当前构建号不一致的副本。
    public static func isManagedFileProviderDomainIdentifier(_ identifier: String) -> Bool {
        identifier == legacyFileProviderDomainIdentifier
            || identifier.hasPrefix(versionedFileProviderDomainPrefix)
    }
}
