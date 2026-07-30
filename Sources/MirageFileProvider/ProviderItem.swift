import MirageCore
import CryptoKit
import FileProvider
import Foundation
import UniformTypeIdentifiers

/// File Provider 树中可枚举、可下载但不可修改的条目。
final class ProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    /// 转码规则变化时必须推进内容版本，使 Finder 丢弃旧缩略图与物化文件。
    private static let transcodingAlgorithmVersion = "center-crop-png-512-fixed-1.25m-v4"
    /// 能力变化必须进入元数据版本，系统才能刷新占位文件的可回收标记。
    private static let capabilitySchemaVersion = "read-content-policy-lazy-v1"

    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let contentPolicy: NSFileProviderContentPolicy
    let fileSystemFlags: NSFileProviderFileSystemFlags
    let documentSize: NSNumber?
    let childItemCount: NSNumber?
    let lastUsedDate: Date?
    let itemVersion: NSFileProviderItemVersion

    /// 变更日志同时观察内容与元数据版本，避免只改父级或最近时间时漏报更新。
    var changeFingerprint: String {
        itemVersion.contentVersion.base64EncodedString() + ":"
            + itemVersion.metadataVersion.base64EncodedString()
    }

    /// 构造目录条目；隐藏搜索容器仍保留用户可读权限。
    init(
        directory identifier: NSFileProviderItemIdentifier,
        parent: NSFileProviderItemIdentifier,
        name: String,
        hidden: Bool = false
    ) {
        itemIdentifier = identifier
        parentItemIdentifier = parent
        filename = name
        contentType = .folder
        // 目录必须显式允许枚举，否则 Finder 能显示目录却无法进入。
        capabilities = [.allowsReading, .allowsContentEnumerating]
        contentPolicy = .downloadLazily
        fileSystemFlags = hidden ? [.hidden, .userReadable] : [.userReadable]
        documentSize = nil
        childItemCount = nil
        lastUsedDate = nil
        itemVersion = Self.version(content: identifier.rawValue, metadata: name)
        super.init()
    }

    /// 构造远程图片条目，并把原始格式统一呈现为 PNG。
    init(
        record: RemoteImageRecord,
        view: ProviderView,
        lastUsedDate: Date? = nil,
        documentSize: NSNumber? = nil
    ) {
        itemIdentifier = ProviderIdentifiers.itemIdentifier(recordID: record.id, view: view)
        parentItemIdentifier = Self.parent(for: view)
        filename = Self.filename(for: record)
        contentType = .png
        capabilities = [.allowsReading]
        // 远程内容可随时重新生成；现代内容策略允许系统按磁盘压力回收本地副本。
        contentPolicy = .downloadLazily
        fileSystemFlags = [.userReadable]
        // 固定尺寸 PNG 让系统在尚未下载内容时也能创建正确大小的 dataless 占位文件。
        self.documentSize = documentSize ?? NSNumber(value: ImageTranscoder.outputFileSize)
        childItemCount = nil
        self.lastUsedDate = lastUsedDate
        itemVersion = Self.version(
            content: [
                record.imageURL.absoluteString,
                record.thumbnailURL.absoluteString,
                record.mimeType ?? "",
                record.width.map(String.init) ?? "",
                record.height.map(String.init) ?? "",
                Self.transcodingAlgorithmVersion
            ].joined(separator: "|"),
            metadata: [
                Self.filename(for: record),
                Self.parent(for: view).rawValue,
                view.rawValue,
                lastUsedDate.map { String($0.timeIntervalSince1970) } ?? "",
                Self.capabilitySchemaVersion
            ].joined(separator: "|")
        )
        super.init()
    }

    /// 返回虚拟根目录，父级值会被系统忽略但仍保持协议完整。
    static func root() -> ProviderItem {
        ProviderItem(
            directory: .rootContainer,
            parent: .rootContainer,
            name: "Mirage"
        )
    }

    /// 每个视图的真实父目录必须与枚举树完全一致。
    private static func parent(for view: ProviderView) -> NSFileProviderItemIdentifier {
        switch view {
        case .discover: return .rootContainer
        case .search: return ProviderIdentifiers.searchBacking
        case .recent: return ProviderIdentifiers.recent
        case .favorite: return ProviderIdentifiers.favorites
        }
    }

    /// 清理路径分隔符并附加短摘要，避免同名搜索结果发生文件名碰撞。
    private static func filename(for record: RemoteImageRecord) -> String {
        let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let cleaned = record.title.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = cleaned.isEmpty ? "Avatar" : String(cleaned.prefix(80))
        let suffix = SHA256.hash(data: Data(record.id.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
        return "\(stem)-\(suffix).png"
    }

    /// 使用固定摘要生成内容与元数据版本，跨进程启动保持稳定。
    private static func version(content: String, metadata: String) -> NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data(SHA256.hash(data: Data(content.utf8))),
            metadataVersion: Data(SHA256.hash(data: Data(metadata.utf8)))
        )
    }
}
