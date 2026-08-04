import Foundation

/// 可持久化的照片提供方标识；新增来源只需注册 descriptor 与适配器。
public enum PhotoSourceID: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case openverse
    case pexels
    case pixabay

    public var id: Self { self }
}

/// 同一个来源可以按产品政策分别开放给主 App 与 File Provider。
public enum PhotoSourceSurface: String, Codable, CaseIterable, Hashable, Sendable {
    case app
    case fileProvider = "file_provider"
}

/// 交互搜索与自动推荐分开声明能力，避免只允许临时搜索的来源被后台推荐流持久化。
public enum PhotoSearchPurpose: String, Codable, Hashable, Sendable {
    case interactive
    case recommendation
}

public enum PhotoSourceCredentialRequirement: String, Codable, Sendable {
    case none
    case apiKey = "api_key"
}

public enum PhotoSourceAvailability: String, Codable, Hashable, Sendable {
    case available
    case adapting
}

/// 搜索结果页所需的平台归属由注册表声明，UI 无需认识具体供应商。
public struct PhotoSourceAttribution: Hashable, Sendable {
    public let text: String
    public let url: URL
    public let note: String?

    public init(text: String, url: URL, note: String? = nil) {
        self.text = text
        self.url = url
        self.note = note
    }
}

/// Settings 只读取描述信息，不感知任何具体网络客户端。
public struct PhotoSourceDescriptor: Identifiable, Hashable, Sendable {
    public let id: PhotoSourceID
    public let displayName: String
    public let summary: String
    public let availability: PhotoSourceAvailability
    public let credentialRequirement: PhotoSourceCredentialRequirement
    public let supportedSurfaces: Set<PhotoSourceSurface>
    public let allowsAutomatedRecommendations: Bool
    public let allowsPersistentLibraryStorage: Bool
    public let credentialURL: URL?
    public let termsURL: URL
    public let searchResultAttribution: PhotoSourceAttribution?

    public func supports(_ surface: PhotoSourceSurface) -> Bool {
        supportedSurfaces.contains(surface)
    }

    public func supports(_ surface: PhotoSourceSurface, purpose: PhotoSearchPurpose) -> Bool {
        supports(surface) && (purpose == .interactive || allowsAutomatedRecommendations)
    }
}

public enum PhotoSourceRegistry {
    public static let descriptors: [PhotoSourceDescriptor] = [
        PhotoSourceDescriptor(
            id: .openverse,
            displayName: "Openverse",
            summary: "无需密钥的 CC0 与公版照片",
            availability: .available,
            credentialRequirement: .none,
            supportedSurfaces: [.app, .fileProvider],
            allowsAutomatedRecommendations: true,
            allowsPersistentLibraryStorage: true,
            credentialURL: nil,
            termsURL: URL(string: "https://docs.openverse.org/terms_of_use.html")!,
            searchResultAttribution: nil
        ),
        PhotoSourceDescriptor(
            id: .pexels,
            displayName: "Pexels",
            summary: "使用你自己的 Pexels API Key",
            availability: .available,
            credentialRequirement: .apiKey,
            supportedSurfaces: [.app, .fileProvider],
            allowsAutomatedRecommendations: true,
            allowsPersistentLibraryStorage: true,
            credentialURL: URL(string: "https://www.pexels.com/api/new/")!,
            termsURL: URL(string: "https://www.pexels.com/terms-of-service/")!,
            searchResultAttribution: PhotoSourceAttribution(
                text: "Photos provided by Pexels",
                url: URL(string: "https://www.pexels.com")!
            )
        ),
        PhotoSourceDescriptor(
            id: .pixabay,
            displayName: "Pixabay",
            summary: "使用你自己的 Pixabay API Key（App 搜索，普通权限最高 1280px）",
            availability: .available,
            credentialRequirement: .apiKey,
            supportedSurfaces: [.app],
            allowsAutomatedRecommendations: false,
            allowsPersistentLibraryStorage: false,
            credentialURL: URL(string: "https://pixabay.com/api/docs/")!,
            termsURL: URL(string: "https://pixabay.com/service/terms/")!,
            searchResultAttribution: PhotoSourceAttribution(
                text: "Images provided by Pixabay",
                url: URL(string: "https://pixabay.com")!,
                note: "仅支持 App 搜索预览，暂不可收藏或用于 Finder"
            )
        )
    ]

    public static func descriptor(for id: PhotoSourceID) -> PhotoSourceDescriptor? {
        descriptors.first { $0.id == id }
    }
}

public extension ImageSource {
    /// DiceBear 不是远程照片 provider；其余图片来源可映射到用户可选的数据源。
    var photoSourceID: PhotoSourceID? {
        switch self {
        case .openverse: return .openverse
        case .pexels: return .pexels
        case .pixabay: return .pixabay
        case .diceBear: return nil
        }
    }

    /// Pixabay 只允许临时显示搜索结果；未建立本地媒体缓存前不能把远程 URL 长期收藏。
    var allowsPersistentLibraryStorage: Bool {
        guard let sourceID = photoSourceID,
              let descriptor = PhotoSourceRegistry.descriptor(for: sourceID) else {
            return true
        }
        return descriptor.allowsPersistentLibraryStorage
    }
}

/// 游标内容由对应 provider 解释，聚合层只负责原样保存与回传。
public struct PhotoSourceCursor: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct PhotoSourcePage: Sendable {
    public let records: [RemoteImageRecord]
    public let nextCursor: PhotoSourceCursor?
    public let quota: PhotoSourceQuotaSnapshot?

    public init(
        records: [RemoteImageRecord],
        nextCursor: PhotoSourceCursor?,
        quota: PhotoSourceQuotaSnapshot? = nil
    ) {
        self.records = records
        self.nextCursor = nextCursor
        self.quota = quota
    }
}

public enum PhotoSourceIssueKind: String, Codable, Equatable, Sendable {
    case missingCredential
    case invalidCredential
    case rateLimited
    case network
    case invalidResponse
    case decoding
    case unavailable
}

public struct PhotoSourceIssue: Codable, Equatable, Sendable {
    public let sourceID: PhotoSourceID
    public let kind: PhotoSourceIssueKind
    public let message: String
    public let retryAt: Date?

    public init(sourceID: PhotoSourceID, kind: PhotoSourceIssueKind, message: String, retryAt: Date? = nil) {
        self.sourceID = sourceID
        self.kind = kind
        self.message = message
        self.retryAt = retryAt
    }
}

/// Provider 的类型化错误会在聚合层转成可展示但不泄露凭据的 issue。
public protocol PhotoSourceFailure: Error, Sendable {
    var sourceID: PhotoSourceID { get }
    var issueKind: PhotoSourceIssueKind { get }
    var retryAt: Date? { get }
}

public protocol PhotoSourceSearching: Sendable {
    var sourceID: PhotoSourceID { get }
    func search(query: String, cursor: PhotoSourceCursor?, pageSize: Int) async throws -> PhotoSourcePage
}

public struct PhotoSourceCursorState: Codable, Equatable, Sendable {
    public let sourceID: PhotoSourceID
    public let cursor: PhotoSourceCursor?
    public let pageSize: Int
    public let exhausted: Bool

    public init(sourceID: PhotoSourceID, cursor: PhotoSourceCursor?, pageSize: Int, exhausted: Bool) {
        self.sourceID = sourceID
        self.cursor = cursor
        self.pageSize = pageSize
        self.exhausted = exhausted
    }
}

/// 一次查询冻结的来源集合、配额和各自位置；设置变化后旧游标会明确失效。
public struct PhotoSearchCursor: Codable, Equatable, Sendable {
    public let configurationRevision: UInt64
    public let states: [PhotoSourceCursorState]

    public init(configurationRevision: UInt64, states: [PhotoSourceCursorState]) {
        self.configurationRevision = configurationRevision
        self.states = states
    }
}

public struct PhotoSearchPage: Sendable {
    public let records: [RemoteImageRecord]
    public let nextCursor: PhotoSearchCursor?
    public let issues: [PhotoSourceIssue]

    public init(
        records: [RemoteImageRecord],
        nextCursor: PhotoSearchCursor?,
        issues: [PhotoSourceIssue] = []
    ) {
        self.records = records
        self.nextCursor = nextCursor
        self.issues = issues
    }
}

public protocol PhotoSearching: Sendable {
    func search(query: String, cursor: PhotoSearchCursor?, pageSize: Int) async throws -> PhotoSearchPage
    func search(query: String, page: Int, pageSize: Int) async throws -> PhotoSearchPage
    func configurationKey() async -> String
}

public enum PhotoSearchError: Error, Equatable, Sendable {
    case noEnabledSources
    case invalidCursor
    case configurationChanged
    case allSourcesFailed([PhotoSourceIssue])
}

extension PhotoSearchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noEnabledSources: return "没有启用可用的图片数据源。"
        case .invalidCursor: return "图片分页位置无效，请重新搜索。"
        case .configurationChanged: return "图片数据源设置已变化，请重新搜索。"
        case let .allSourcesFailed(issues): return issues.first?.message ?? "图片数据源暂时不可用。"
        }
    }
}
