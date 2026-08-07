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
    case picrew
    case diceBear = "dice_bear"
    case gravatar
    case robohash
    case thisPersonDoesNotExist = "this_person_does_not_exist"

    public var displayName: String {
        switch self {
        case .openverse: return "Openverse"
        case .metMuseum: return "The Met"
        case .nasa: return "NASA"
        case .pexels: return "Pexels"
        case .pixabay: return "Pixabay"
        case .giphy: return "GIPHY"
        case .picrew: return "Picrew Discovery"
        case .diceBear: return "DiceBear"
        case .gravatar: return "Gravatar"
        case .robohash: return "Robohash"
        case .thisPersonDoesNotExist: return "This Person Does Not Exist"
        }
    }

    public var isAvatarSource: Bool {
        switch self {
        case .picrew, .diceBear, .gravatar, .robohash, .thisPersonDoesNotExist: return true
        case .openverse, .metMuseum, .nasa, .pexels, .pixabay, .giphy: return false
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

    public static let picrewUsage = LicenseInfo(
        identifier: "picrew-maker-specific",
        displayName: "按 Maker 单独规定",
        url: URL(string: "https://support.picrew.me/en/about_picrew_player/promise")
    )

    public static let gravatarUsage = LicenseInfo(
        identifier: "gravatar-usage",
        displayName: "Gravatar Usage Guidelines",
        url: URL(string: "https://docs.gravatar.com/pricing/")
    )

    public static let thisPersonDoesNotExistUsage = LicenseInfo(
        identifier: "usage-terms-unavailable",
        displayName: "未提供公开使用许可",
        url: URL(string: "https://thispersondoesnotexist.com/")
    )
}

/// 可供 UI、收藏与 File Provider 共用的远程图片元数据。
public struct RemoteImageRecord: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let source: ImageSource
    public let avatarType: AvatarType?
    public let giphyContentType: GiphyContentType?
    /// GIPHY 内容的公开对象 ID；收藏只持久化该 ID，不保存临时媒体地址。
    public let giphyID: String?
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
        avatarType: AvatarType? = nil,
        giphyContentType: GiphyContentType? = nil,
        giphyID: String? = nil,
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
        self.avatarType = avatarType
        self.giphyContentType = giphyContentType
        self.giphyID = giphyID
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

public extension RemoteImageRecord {
    /// GIPHY 收藏快照以内部占位 URL 和公开对象 ID 表示，不复制目录缓存中的媒体地址。
    var isGiphyFavoriteReference: Bool {
        source == .giphy
            && imageURL.scheme == Self.giphyFavoriteReferenceScheme
            && thumbnailURL.scheme == Self.giphyFavoriteReferenceScheme
    }

    /// 普通来源原样保存；GIPHY 收藏仅保留可回查的对象 ID 与非媒体归属信息。
    func persistentFavoriteRecord() -> RemoteImageRecord? {
        guard source == .giphy else { return self }
        guard let giphyID = giphyID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !giphyID.isEmpty else {
            return nil
        }
        let referenceURL = URL(
            string: "\(Self.giphyFavoriteReferenceScheme)://record/"
                + StableImageID.seedHash(giphyID)
        )!
        return RemoteImageRecord(
            id: id,
            title: title,
            source: source,
            avatarType: avatarType,
            giphyContentType: giphyContentType,
            giphyID: giphyID,
            imageURL: referenceURL,
            thumbnailURL: referenceURL,
            sourcePageURL: sourcePageURL,
            license: license,
            creator: creator,
            creatorURL: creatorURL,
            width: width,
            height: height,
            mimeType: nil
        )
    }

    private static var giphyFavoriteReferenceScheme: String {
        "mirage-giphy-favorite"
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

    /// Discovery 缩略图会滚动更新，使用 Maker 与公开缩略图路径共同形成会话稳定 ID。
    public static func picrewDiscovery(makerID: String, thumbnailPath: String) -> String {
        "picrew:discovery:v1:\(seedHash("\(makerID)|\(thumbnailPath)"))"
    }

    /// DiceBear 不暴露查询词，只把不可逆摘要放进 ID 与远程 seed。
    public static func diceBear(style: String, seedMaterial: String) -> String {
        "db:v10:\(style):\(seedHash(seedMaterial))"
    }

    /// 每日头像在不可逆摘要之外保留 UTC 生成日；v13 使本次供应商调整立即失效。
    public static func dailyDiceBear(
        style: String,
        generationDay: AvatarGenerationDay,
        seedMaterial: String
    ) -> String {
        "db:v13:\(style):\(generationDay.identifier):\(seedHash(seedMaterial))"
    }

    public static func dailyGravatar(
        style: String,
        generationDay: AvatarGenerationDay,
        seedMaterial: String
    ) -> String {
        "gravatar:v2:\(style):\(generationDay.identifier):\(seedHash(seedMaterial))"
    }

    public static func dailyRobohash(
        set: String,
        generationDay: AvatarGenerationDay,
        seedMaterial: String
    ) -> String {
        "robohash:v2:\(set):\(generationDay.identifier):\(seedHash(seedMaterial))"
    }

    /// 动态服务无法由 seed 重放，最终 ID 必须绑定实际冻结内容。
    public static func dailyThisPersonDoesNotExist(
        generationDay: AvatarGenerationDay,
        seedMaterial: String,
        snapshot: Data
    ) -> String {
        "tpdne:v1:ai:\(generationDay.identifier):\(seedHash(seedMaterial)):\(dataHash(snapshot))"
    }

    /// 从当前头像供应商 ID 恢复日期；旧版本或损坏摘要不会被误判为当天缓存。
    public static func avatarGenerationDay(from identifier: String) -> AvatarGenerationDay? {
        avatarIdentifierComponents(from: identifier)?.generationDay
    }

    /// 从当前头像 ID 恢复来源，用于拒绝来源字段与命名空间不一致的损坏缓存。
    public static func avatarSource(from identifier: String) -> ImageSource? {
        if isPicrewDiscovery(identifier) { return .picrew }
        return avatarIdentifierComponents(from: identifier)?.source
    }

    /// Picrew Discovery 没有每日 seed，但公开缩略图路径摘要仍能验证当前命名空间。
    private static func isPicrewDiscovery(_ identifier: String) -> Bool {
        let fields = identifier.split(separator: ":", omittingEmptySubsequences: false)
        return fields.count == 4
            && fields[0] == "picrew"
            && fields[1] == "discovery"
            && fields[2] == "v1"
            && isSHA256(fields[3])
    }

    private static func avatarIdentifierComponents(
        from identifier: String
    ) -> (source: ImageSource, generationDay: AvatarGenerationDay)? {
        let fields = identifier.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count >= 5, !fields[2].isEmpty else { return nil }
        let namespace = (String(fields[0]), String(fields[1]))
        let source: ImageSource
        switch namespace {
        case ("db", "v13"):
            guard fields.count == 5, isSHA256(fields[4]) else { return nil }
            source = .diceBear
        case ("gravatar", "v2"):
            guard fields.count == 5,
                  fields[2] == "monsterid",
                  isSHA256(fields[4]) else { return nil }
            source = .gravatar
        case ("robohash", "v2"):
            let currentSets = ["set1", "set2", "set3", "set4", "set6"]
            guard fields.count == 5,
                  currentSets.contains(String(fields[2])),
                  isSHA256(fields[4]) else { return nil }
            source = .robohash
        case ("tpdne", "v1"):
            guard fields.count == 6,
                  fields[2] == "ai",
                  isSHA256(fields[4]),
                  isSHA256(fields[5]) else { return nil }
            source = .thisPersonDoesNotExist
        default: return nil
        }
        guard let generationDay = AvatarGenerationDay(identifier: String(fields[3])) else { return nil }
        return (source, generationDay)
    }

    /// 兼容旧调用方，但只接受当前 DiceBear 命名空间。
    public static func diceBearGenerationDay(from identifier: String) -> AvatarGenerationDay? {
        guard let components = avatarIdentifierComponents(from: identifier),
              components.source == .diceBear else { return nil }
        return components.generationDay
    }

    /// 生成固定长度 SHA-256 小写十六进制摘要。
    public static func seedHash(_ value: String) -> String {
        dataHash(Data(value.utf8))
    }

    public static func dataHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 动态人像 ID 的最后一段是标准化 PNG 的内容摘要，可用于校验快照未被替换。
    public static func thisPersonDoesNotExistSnapshotHash(from identifier: String) -> String? {
        guard avatarSource(from: identifier) == .thisPersonDoesNotExist else { return nil }
        return identifier.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init)
    }

    private static func isSHA256(_ value: Substring) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character)
        }
    }
}
