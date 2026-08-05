import Foundation

/// 可持久化的照片提供方标识；新增来源只需注册 descriptor 与适配器。
public enum PhotoSourceID: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case openverse
    case metMuseum = "met_museum"
    case nasa
    case pexels
    case pixabay
    case giphy

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

/// 聚合来源可以同页交错；隔离来源必须由独立内容入口单独展示。
public enum PhotoSourceResultPresentation: String, Codable, Hashable, Sendable {
    case aggregated
    case isolated
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
    public let allowsMediaCaching: Bool
    public let resultPresentation: PhotoSourceResultPresentation
    public let credentialURL: URL?
    /// Settings 中用于说明凭据获取方式；为空时沿用通用“获取 API Key”文案。
    public let credentialAcquisitionLabel: String?
    public let termsURL: URL
    public let searchResultAttribution: PhotoSourceAttribution?

    public func supports(_ surface: PhotoSourceSurface) -> Bool {
        supportedSurfaces.contains(surface)
    }

    public func supports(_ surface: PhotoSourceSurface, purpose: PhotoSearchPurpose) -> Bool {
        supports(surface) && (purpose == .interactive || allowsAutomatedRecommendations)
    }

    public func supportsAggregatedSearch(
        on surface: PhotoSourceSurface,
        purpose: PhotoSearchPurpose
    ) -> Bool {
        resultPresentation == .aggregated && supports(surface, purpose: purpose)
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
            allowsMediaCaching: true,
            resultPresentation: .aggregated,
            credentialURL: nil,
            credentialAcquisitionLabel: nil,
            termsURL: URL(string: "https://docs.openverse.org/terms_of_use.html")!,
            searchResultAttribution: nil
        ),
        PhotoSourceDescriptor(
            id: .metMuseum,
            displayName: "The Met",
            summary: "无需密钥的博物馆 CC0 公版艺术作品",
            availability: .available,
            credentialRequirement: .none,
            supportedSurfaces: [.app],
            allowsAutomatedRecommendations: false,
            allowsPersistentLibraryStorage: true,
            allowsMediaCaching: true,
            resultPresentation: .aggregated,
            credentialURL: nil,
            credentialAcquisitionLabel: nil,
            termsURL: URL(string: "https://www.metmuseum.org/policies/terms-and-conditions")!,
            searchResultAttribution: PhotoSourceAttribution(
                text: "Images provided by The Metropolitan Museum of Art",
                url: URL(string: "https://www.metmuseum.org")!,
                note: "仅展示开放获取（CC0）作品；暂不用于 Finder 或自动推荐"
            )
        ),
        PhotoSourceDescriptor(
            id: .nasa,
            displayName: "NASA",
            summary: "无需密钥的 NASA Image and Video Library 图片",
            availability: .available,
            credentialRequirement: .none,
            supportedSurfaces: [.app],
            allowsAutomatedRecommendations: false,
            allowsPersistentLibraryStorage: true,
            allowsMediaCaching: true,
            resultPresentation: .aggregated,
            credentialURL: nil,
            credentialAcquisitionLabel: nil,
            termsURL: URL(string: "https://www.nasa.gov/nasa-brand-center/images-and-media/")!,
            searchResultAttribution: PhotoSourceAttribution(
                text: "Images provided by NASA Image and Video Library",
                url: URL(string: "https://images.nasa.gov")!,
                note: "使用前请核对 NASA Media Usage Guidelines；可在 App 内收藏，暂不用于 Finder"
            )
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
            allowsMediaCaching: true,
            resultPresentation: .aggregated,
            credentialURL: URL(string: "https://www.pexels.com/api/new/")!,
            credentialAcquisitionLabel: "免费使用 · 注册即可获取 API Key",
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
            allowsPersistentLibraryStorage: true,
            allowsMediaCaching: true,
            resultPresentation: .aggregated,
            credentialURL: URL(string: "https://pixabay.com/api/docs/")!,
            credentialAcquisitionLabel: "免费使用 · 注册即可获取 API Key",
            termsURL: URL(string: "https://pixabay.com/service/terms/")!,
            searchResultAttribution: PhotoSourceAttribution(
                text: "Images provided by Pixabay",
                url: URL(string: "https://pixabay.com")!,
                note: "可在 App 内收藏，暂不用于 Finder 或自动推荐"
            )
        ),
        PhotoSourceDescriptor(
            id: .giphy,
            displayName: "GIPHY",
            summary: "使用你自己的 GIPHY API Key 浏览 Emoji，并搜索 GIF 与 Sticker",
            availability: .available,
            credentialRequirement: .apiKey,
            supportedSurfaces: [.app],
            allowsAutomatedRecommendations: false,
            allowsPersistentLibraryStorage: false,
            allowsMediaCaching: false,
            resultPresentation: .isolated,
            credentialURL: URL(string: "https://developers.giphy.com/dashboard/")!,
            credentialAcquisitionLabel: "注册并创建 GIPHY API Key",
            termsURL: URL(string: "https://support.giphy.com/hc/en-us/articles/360028134111-GIPHY-API-Terms-of-Service")!,
            searchResultAttribution: PhotoSourceAttribution(
                text: "Powered by GIPHY",
                url: URL(string: "https://giphy.com")!,
                note: "仅在 App 内浏览与搜索；不进入 Finder、推荐或收藏"
            )
        )
    ]

    public static func descriptor(for id: PhotoSourceID) -> PhotoSourceDescriptor? {
        descriptors.first { $0.id == id }
    }
}

public extension ImageSource {
    /// 头像生成服务不是远程照片 provider；其余图片来源可映射到用户可选的数据源。
    var photoSourceID: PhotoSourceID? {
        switch self {
        case .openverse: return .openverse
        case .metMuseum: return .metMuseum
        case .nasa: return .nasa
        case .pexels: return .pexels
        case .pixabay: return .pixabay
        case .giphy: return .giphy
        case .diceBear, .gravatar, .robohash: return nil
        }
    }

    /// 注册表统一声明能否长期写入资料库；临时预览来源不能把远程 URL 持久化收藏。
    var allowsPersistentLibraryStorage: Bool {
        guard let sourceID = photoSourceID,
              let descriptor = PhotoSourceRegistry.descriptor(for: sourceID) else {
            return true
        }
        return descriptor.allowsPersistentLibraryStorage
    }

    /// 标准 GIPHY 集成不得缓存媒体 URL 或媒体副本；UI 据此改走瞬时直连加载。
    var allowsMediaCaching: Bool {
        guard let sourceID = photoSourceID,
              let descriptor = PhotoSourceRegistry.descriptor(for: sourceID) else {
            return true
        }
        return descriptor.allowsMediaCaching
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
    /// 隔离来源也可以在返回可用记录时报告其内部子流故障。
    public let issues: [PhotoSourceIssue]

    public init(
        records: [RemoteImageRecord],
        nextCursor: PhotoSourceCursor?,
        quota: PhotoSourceQuotaSnapshot? = nil,
        issues: [PhotoSourceIssue] = []
    ) {
        self.records = records
        self.nextCursor = nextCursor
        self.quota = quota
        self.issues = issues
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

/// 单个来源完成后的可见批次；完整分页游标仍只由最终 PhotoSearchPage 提交。
public struct PhotoSearchBatch: Sendable {
    public let sourceID: PhotoSourceID
    public let records: [RemoteImageRecord]

    public init(sourceID: PhotoSourceID, records: [RemoteImageRecord]) {
        self.sourceID = sourceID
        self.records = records
    }
}

public typealias PhotoSearchBatchHandler = @Sendable (PhotoSearchBatch) async -> Void

public protocol PhotoSearching: Sendable {
    func search(query: String, cursor: PhotoSearchCursor?, pageSize: Int) async throws -> PhotoSearchPage
    func search(
        query: String,
        cursor: PhotoSearchCursor?,
        pageSize: Int,
        onBatch: @escaping PhotoSearchBatchHandler
    ) async throws -> PhotoSearchPage
    func search(query: String, page: Int, pageSize: Int) async throws -> PhotoSearchPage
    func configurationKey() async -> String
}

public extension PhotoSearching {
    /// 非聚合实现保持原子返回；调用方仍可统一使用增量入口而不改变既有 conformer。
    func search(
        query: String,
        cursor: PhotoSearchCursor?,
        pageSize: Int,
        onBatch: @escaping PhotoSearchBatchHandler
    ) async throws -> PhotoSearchPage {
        try await search(query: query, cursor: cursor, pageSize: pageSize)
    }
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
