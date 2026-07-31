import Foundation

/// 主 App 与 File Provider 共用的系统集成身份，避免两个进程各自硬编码后发生漂移。
public enum MirageSystemIntegration {
    /// File Provider 域标识必须跨进程稳定；修改时需要由主 App 负责迁移旧域。
    public static let fileProviderDomainIdentifier = "mirage-default-v11"
}
