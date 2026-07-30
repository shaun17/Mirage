import CryptoKit
import Foundation

/// 图片来自哪个远程服务。
public enum ImageSource: String, Codable, CaseIterable, Sendable {
    case openverse
    case diceBear = "dice_bear"
}

/// 图片授权信息。`url` 指向服务方公开的许可证说明。
public struct LicenseInfo: Codable, Equatable, Hashable, Sendable {
    public let identifier: String
    public let displayName: String
    public let url: URL?

    public init(identifier: String, displayName: String, url: URL? = nil) {
        self.identifier = identifier.lowercased()
        self.displayName = displayName
        self.url = url
    }

    public static let cc0 = LicenseInfo(
        identifier: "cc0",
        displayName: "CC0 1.0",
        url: URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")
    )

    public static let publicDomain = LicenseInfo(
        identifier: "pdm",
        displayName: "Public Domain Mark",
        url: URL(string: "https://creativecommons.org/publicdomain/mark/1.0/")
    )
}

/// 可供 UI、收藏与 File Provider 共用的远程图片元数据。
public struct RemoteImageRecord: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let source: ImageSource
    public let imageURL: URL
    public let thumbnailURL: URL
    public let sourcePageURL: URL?
    public let license: LicenseInfo
    public let creator: String?
    public let creatorURL: URL?
    public let width: Int?
    public let height: Int?
    public let mimeType: String?

    public init(
        id: String,
        title: String,
        source: ImageSource,
        imageURL: URL,
        thumbnailURL: URL,
        sourcePageURL: URL? = nil,
        license: LicenseInfo,
        creator: String? = nil,
        creatorURL: URL? = nil,
        width: Int? = nil,
        height: Int? = nil,
        mimeType: String? = nil
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.imageURL = imageURL
        self.thumbnailURL = thumbnailURL
        self.sourcePageURL = sourcePageURL
        self.license = license
        self.creator = creator
        self.creatorURL = creatorURL
        self.width = width
        self.height = height
        self.mimeType = mimeType
    }
}

/// 集中生成跨进程、跨启动都不变化的标识符。
public enum StableImageID {
    /// Openverse 的 UUID 在统一大小写后直接组成稳定 ID。
    public static func openverse(uuid: UUID) -> String {
        "ov:\(uuid.uuidString.lowercased())"
    }

    /// DiceBear 不暴露查询词，只把不可逆摘要放进 ID 与远程 seed。
    public static func diceBear(style: String, seedMaterial: String) -> String {
        "db:v10:\(style):\(seedHash(seedMaterial))"
    }

    /// 生成固定长度 SHA-256 小写十六进制摘要。
    public static func seedHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
