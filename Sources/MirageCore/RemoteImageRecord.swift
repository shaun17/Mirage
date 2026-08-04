import CryptoKit
import Foundation

/// 图片来自哪个远程服务。
public enum ImageSource: String, Codable, CaseIterable, Sendable {
    case openverse
    case metMuseum = "met_museum"
    case nasa
    case pexels
    case pixabay
    case giphy
    case diceBear = "dice_bear"

    public var displayName: String {
        switch self {
        case .openverse: return "Openverse"
        case .metMuseum: return "The Met"
        case .nasa: return "NASA"
        case .pexels: return "Pexels"
        case .pixabay: return "Pixabay"
        case .giphy: return "GIPHY"
        case .diceBear: return "DiceBear"
        }
    }
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

    public static let pexels = LicenseInfo(
        identifier: "pexels",
        displayName: "Pexels License",
        url: URL(string: "https://www.pexels.com/license/")
    )

    public static let pixabay = LicenseInfo(
        identifier: "pixabay",
        displayName: "Pixabay Content License",
        url: URL(string: "https://pixabay.com/service/license-summary/")
    )

    public static let nasaMediaUsage = LicenseInfo(
        identifier: "nasa-media",
        displayName: "NASA Media Usage Guidelines",
        url: URL(string: "https://www.nasa.gov/nasa-brand-center/images-and-media/")
    )

    public static let giphy = LicenseInfo(
        identifier: "giphy-api",
        displayName: "GIPHY API Terms",
        url: URL(string: "https://support.giphy.com/hc/en-us/articles/360028134111-GIPHY-API-Terms-of-Service")
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

    public static func pexels(id: Int) -> String {
        "px:\(id)"
    }

    public static func pixabay(id: Int) -> String {
        "pb:\(id)"
    }

    public static func metMuseum(objectID: Int) -> String {
        "met:\(objectID)"
    }

    /// NASA ID 可能包含空格或标点；使用摘要保持跨进程标识安全且稳定。
    public static func nasa(nasaID: String) -> String {
        "nasa:\(seedHash(nasaID))"
    }

    /// 保留既有 `giphy:emoji:` 线格式兼容当前会话；三类 GIPHY 内容共用原始 ID 去重。
    public static func giphy(id: String) -> String {
        "giphy:emoji:\(seedHash(id))"
    }

    /// DiceBear 不暴露查询词，只把不可逆摘要放进 ID 与远程 seed。
    public static func diceBear(style: String, seedMaterial: String) -> String {
        "db:v10:\(style):\(seedHash(seedMaterial))"
    }

    /// 每日头像在不可逆摘要之外保留 UTC 生成日，供持久缓存准确判断是否跨日。
    public static func dailyDiceBear(
        style: String,
        generationDay: DiceBearGenerationDay,
        seedMaterial: String
    ) -> String {
        "db:v10:\(style):\(generationDay.identifier):\(seedHash(seedMaterial))"
    }

    /// 只从 Mirage 每日 DiceBear ID 恢复日期；旧 ID 或损坏摘要不会被误判为当天缓存。
    public static func diceBearGenerationDay(from identifier: String) -> DiceBearGenerationDay? {
        let fields = identifier.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 5,
              fields[0] == "db",
              fields[1] == "v10",
              !fields[2].isEmpty,
              fields[4].count == 64,
              fields[4].allSatisfy(\.isHexDigit) else {
            return nil
        }
        return DiceBearGenerationDay(identifier: String(fields[3]))
    }

    /// 生成固定长度 SHA-256 小写十六进制摘要。
    public static func seedHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
