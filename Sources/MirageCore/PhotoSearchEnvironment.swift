import Foundation

typealias CredentialedPhotoSourceFactory = @Sendable (
    _ sourceID: PhotoSourceID,
    _ credential: String
) throws -> any PhotoSourceSearching

typealias UncredentialedPhotoSourceFactory = @Sendable (
    _ sourceID: PhotoSourceID
) throws -> any PhotoSourceSearching

/// 两个进程各自创建环境，但通过 App Group 读取同一份配置与应用持久数据。
public struct PhotoSearchEnvironment: Sendable {
    public let preferences: PhotoSourcePreferencesStore
    public let credentials: any PhotoSourceCredentialStoring
    private let openverse: any PhotoSourceSearching
    private let requestCoordinator: PhotoSourceRequestCoordinator
    private let uncredentialedSourceFactory: UncredentialedPhotoSourceFactory
    private let credentialedSourceFactory: CredentialedPhotoSourceFactory

    public init(
        preferences: PhotoSourcePreferencesStore,
        credentials: any PhotoSourceCredentialStoring,
        openverse: any PhotoSourceSearching = OpenversePhotoSource()
    ) {
        self.preferences = preferences
        self.credentials = credentials
        self.openverse = openverse
        self.requestCoordinator = PhotoSourceRequestCoordinator()
        self.uncredentialedSourceFactory = uncredentialedPhotoSource
        self.credentialedSourceFactory = credentialedPhotoSource
    }

    init(
        preferences: PhotoSourcePreferencesStore,
        credentials: any PhotoSourceCredentialStoring,
        openverse: any PhotoSourceSearching,
        requestCoordinator: PhotoSourceRequestCoordinator,
        uncredentialedSourceFactory: @escaping UncredentialedPhotoSourceFactory = uncredentialedPhotoSource,
        credentialedSourceFactory: @escaping CredentialedPhotoSourceFactory = credentialedPhotoSource
    ) {
        self.preferences = preferences
        self.credentials = credentials
        self.openverse = openverse
        self.requestCoordinator = requestCoordinator
        self.uncredentialedSourceFactory = uncredentialedSourceFactory
        self.credentialedSourceFactory = credentialedSourceFactory
    }

    public static func production() -> PhotoSearchEnvironment {
        let defaults = UserDefaults(suiteName: AppGroupStorage.appGroupIdentifier) ?? .standard
        return PhotoSearchEnvironment(
            preferences: PhotoSourcePreferencesStore(userDefaults: defaults),
            credentials: AppGroupPhotoSourceCredentialStore(),
            openverse: OpenversePhotoSource(),
            requestCoordinator: .production()
        )
    }

    public func imageSearchService(
        for surface: PhotoSourceSurface,
        purpose: PhotoSearchPurpose = .interactive,
        diceBear: any DiceBearProviding = DiceBearClient()
    ) -> ImageSearchService {
        let giphySource: (any PhotoSourceSearching)? = surface == .app && purpose == .interactive
            ? ConfiguredGiphyCatalogSearcher(
                preferences: preferences,
                credentials: credentials,
                credentialedSourceFactory: credentialedSourceFactory
            )
            : nil
        return ImageSearchService(
            photos: ConfiguredPhotoSearcher(
                surface: surface,
                purpose: purpose,
                preferences: preferences,
                credentials: credentials,
                openverse: openverse,
                requestCoordinator: requestCoordinator,
                uncredentialedSourceFactory: uncredentialedSourceFactory,
                credentialedSourceFactory: credentialedSourceFactory
            ),
            giphy: giphySource,
            diceBear: diceBear,
            maximumPageSize: surface == .fileProvider
                ? DiscoveryRecommendation.fileProviderPageSize
                : DiscoveryRecommendation.pageSize
        )
    }

    public func recommendationCatalogKey(for surface: PhotoSourceSurface) async -> String {
        let snapshot = await preferences.snapshot()
        let sourceIDs = snapshot.sourceIDs(for: surface)
            .filter {
                PhotoSourceRegistry.descriptor(for: $0)?.supportsAggregatedSearch(
                    on: surface,
                    purpose: .recommendation
                ) == true
            }
            .map(\.rawValue)
            .joined(separator: ",")
        // App 与 Finder 的有效来源相同时继续共享同一 generation；只有来源集合真正分叉才隔离。
        return "\(DiscoveryRecommendation.catalogKey):photo-sources:\(snapshot.revision):\(sourceIDs)"
    }

    /// 设置页用供应商最小合法批次验证凭据，并复用 App 与 Finder 共用的缓存和预算层。
    public func testConnection(sourceID: PhotoSourceID, credential: String) async throws {
        switch sourceID {
        case .openverse, .metMuseum, .nasa:
            return
        case .pexels, .pixabay:
            let normalized = credential.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = try credentialedSourceFactory(sourceID, normalized)
            try await requestCoordinator.testConnection(
                source: source,
                policy: PhotoSourceRequestPolicies.policy(for: sourceID),
                query: "nature",
                configurationPartition: Self.requestPartition(
                    sourceID: sourceID,
                    credential: normalized
                )
            )
        case .giphy:
            // 每个子流各取一个对象，验证 Emoji、GIF 与 Sticker 三个端点及同一把 Key。
            let normalized = credential.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = try credentialedSourceFactory(sourceID, normalized)
            let page = try await source.search(query: "", cursor: nil, pageSize: 3)
            guard page.issues.isEmpty else {
                // 浏览页允许三路中的部分数据先展示；设置页的连接测试必须确认三端点都可用。
                throw PhotoSearchError.allSourcesFailed(page.issues)
            }
        }
    }

    /// 凭据只以摘要参与缓存与预算分区；无关供应商设置变化不会重置当前来源的退避。
    static func requestPartition(sourceID: PhotoSourceID, credential: String?) -> String {
        let credentialFingerprint = credential.map {
            StableImageID.seedHash("photo-source-credential-v1|\($0)")
        } ?? "none"
        return "photo-source-partition-v1:\(sourceID.rawValue):\(credentialFingerprint)"
    }
}

/// 每次查询读取设置快照；续页由 revision 拒绝跨设置混读。
public struct ConfiguredPhotoSearcher: PhotoSearching, Sendable {
    private let surface: PhotoSourceSurface
    private let purpose: PhotoSearchPurpose
    private let preferences: any PhotoSourcePreferencesReading
    private let credentials: any PhotoSourceCredentialReading
    private let openverse: any PhotoSourceSearching
    private let requestCoordinator: PhotoSourceRequestCoordinator
    private let uncredentialedSourceFactory: UncredentialedPhotoSourceFactory
    private let credentialedSourceFactory: CredentialedPhotoSourceFactory

    public init(
        surface: PhotoSourceSurface,
        purpose: PhotoSearchPurpose = .interactive,
        preferences: any PhotoSourcePreferencesReading,
        credentials: any PhotoSourceCredentialReading,
        openverse: any PhotoSourceSearching = OpenversePhotoSource()
    ) {
        self.surface = surface
        self.purpose = purpose
        self.preferences = preferences
        self.credentials = credentials
        self.openverse = openverse
        self.requestCoordinator = PhotoSourceRequestCoordinator()
        self.uncredentialedSourceFactory = uncredentialedPhotoSource
        self.credentialedSourceFactory = credentialedPhotoSource
    }

    init(
        surface: PhotoSourceSurface,
        purpose: PhotoSearchPurpose = .interactive,
        preferences: any PhotoSourcePreferencesReading,
        credentials: any PhotoSourceCredentialReading,
        openverse: any PhotoSourceSearching,
        requestCoordinator: PhotoSourceRequestCoordinator,
        uncredentialedSourceFactory: @escaping UncredentialedPhotoSourceFactory = uncredentialedPhotoSource,
        credentialedSourceFactory: @escaping CredentialedPhotoSourceFactory = credentialedPhotoSource
    ) {
        self.surface = surface
        self.purpose = purpose
        self.preferences = preferences
        self.credentials = credentials
        self.openverse = openverse
        self.requestCoordinator = requestCoordinator
        self.uncredentialedSourceFactory = uncredentialedSourceFactory
        self.credentialedSourceFactory = credentialedSourceFactory
    }

    public func configurationKey() async -> String {
        let base = await preferences.configurationKey(for: surface)
        return "\(base):purpose:\(purpose.rawValue):request-policy:\(PhotoSourceRequestPolicies.catalogVersion)"
    }

    public func search(query: String, cursor: PhotoSearchCursor?, pageSize: Int) async throws -> PhotoSearchPage {
        let searcher = try await makeSearcher()
        return try await searcher.search(query: query, cursor: cursor, pageSize: pageSize)
    }

    public func search(
        query: String,
        cursor: PhotoSearchCursor?,
        pageSize: Int,
        onBatch: @escaping PhotoSearchBatchHandler
    ) async throws -> PhotoSearchPage {
        let searcher = try await makeSearcher()
        return try await searcher.search(
            query: query,
            cursor: cursor,
            pageSize: pageSize,
            onBatch: onBatch
        )
    }

    public func search(query: String, page: Int, pageSize: Int) async throws -> PhotoSearchPage {
        let searcher = try await makeSearcher()
        return try await searcher.search(query: query, page: page, pageSize: pageSize)
    }

    private func makeSearcher() async throws -> AggregatedPhotoSearcher {
        let snapshot = await preferences.snapshot()
        var sources: [any PhotoSourceSearching] = []
        var issues: [PhotoSourceIssue] = []
        for sourceID in snapshot.sourceIDs(for: surface)
        where PhotoSourceRegistry.descriptor(for: sourceID)?.supportsAggregatedSearch(
            on: surface,
            purpose: purpose
        ) == true {
            switch sourceID {
            case .openverse:
                sources.append(coordinated(
                    openverse,
                    partition: PhotoSearchEnvironment.requestPartition(
                        sourceID: sourceID,
                        credential: nil
                    )
                ))
            case .metMuseum, .nasa:
                do {
                    sources.append(coordinated(
                        try uncredentialedSourceFactory(sourceID),
                        partition: PhotoSearchEnvironment.requestPartition(
                            sourceID: sourceID,
                            credential: nil
                        )
                    ))
                } catch {
                    issues.append(PhotoSourceIssue(
                        sourceID: sourceID,
                        kind: .unavailable,
                        message: "无法创建 \(PhotoSourceRegistry.descriptor(for: sourceID)?.displayName ?? sourceID.rawValue) 图片数据源。"
                    ))
                }
            case .pexels, .pixabay:
                do {
                    guard let key = try await credentials.credential(for: sourceID), !key.isEmpty else {
                        issues.append(Self.missingCredentialIssue(for: sourceID))
                        continue
                    }
                    sources.append(coordinated(
                        try credentialedSourceFactory(sourceID, key),
                        partition: PhotoSearchEnvironment.requestPartition(
                            sourceID: sourceID,
                            credential: key
                        )
                    ))
                } catch {
                    issues.append(PhotoSourceIssue(
                        sourceID: sourceID,
                        kind: .unavailable,
                        message: "无法读取 \(PhotoSourceRegistry.descriptor(for: sourceID)?.displayName ?? sourceID.rawValue) API Key。"
                    ))
                }
            case .giphy:
                // GIPHY 受条款约束只能由独立表情入口读取，永不进入聚合照片网格。
                continue
            }
        }
        if sources.isEmpty, !issues.isEmpty { throw PhotoSearchError.allSourcesFailed(issues) }
        return AggregatedPhotoSearcher(
            sources: sources,
            configurationRevision: snapshot.revision,
            initialIssues: issues
        )
    }

    private func coordinated(
        _ source: any PhotoSourceSearching,
        partition: String
    ) -> any PhotoSourceSearching {
        CoordinatedPhotoSource(
            source: source,
            policy: PhotoSourceRequestPolicies.policy(for: source.sourceID),
            coordinator: requestCoordinator,
            configurationPartition: partition
        )
    }

    private static func missingCredentialIssue(for sourceID: PhotoSourceID) -> PhotoSourceIssue {
        PhotoSourceIssue(
            sourceID: sourceID,
            kind: .missingCredential,
            message: "请先在设置中配置 \(PhotoSourceRegistry.descriptor(for: sourceID)?.displayName ?? sourceID.rawValue) API Key。"
        )
    }
}

/// 每次 GIF 分页都读取当前设置，并直接调用 GIPHY；不复用会持久化媒体 URL 的批次协调器。
private struct ConfiguredGiphyCatalogSearcher: PhotoSourceSearching, Sendable {
    let sourceID = PhotoSourceID.giphy

    private let preferences: any PhotoSourcePreferencesReading
    private let credentials: any PhotoSourceCredentialReading
    private let credentialedSourceFactory: CredentialedPhotoSourceFactory

    init(
        preferences: any PhotoSourcePreferencesReading,
        credentials: any PhotoSourceCredentialReading,
        credentialedSourceFactory: @escaping CredentialedPhotoSourceFactory
    ) {
        self.preferences = preferences
        self.credentials = credentials
        self.credentialedSourceFactory = credentialedSourceFactory
    }

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        let snapshot = await preferences.snapshot()
        guard snapshot.sourceIDs(for: .app).contains(.giphy) else {
            throw Self.failure(
                kind: .unavailable,
                message: "请先在设置中启用 GIPHY 数据源。"
            )
        }

        let credential: String
        do {
            guard let value = try await credentials.credential(for: .giphy), !value.isEmpty else {
                throw Self.failure(
                    kind: .missingCredential,
                    message: "请先在设置中配置 GIPHY API Key。"
                )
            }
            credential = value
        } catch let error as PhotoSearchError {
            throw error
        } catch let error as PhotoSourceCredentialError {
            throw Self.failure(kind: .unavailable, message: error.localizedDescription)
        } catch {
            throw Self.failure(kind: .unavailable, message: "无法读取 GIPHY API Key。")
        }

        let source: any PhotoSourceSearching
        do {
            source = try credentialedSourceFactory(.giphy, credential)
        } catch {
            throw Self.failure(kind: .unavailable, message: "无法创建 GIPHY 数据源。")
        }

        do {
            return try await source.search(query: "", cursor: cursor, pageSize: min(pageSize, 40))
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as any PhotoSourceFailure {
            throw Self.failure(
                kind: failure.issueKind,
                message: (failure as Error).localizedDescription,
                retryAt: failure.retryAt
            )
        }
    }

    private static func failure(
        kind: PhotoSourceIssueKind,
        message: String,
        retryAt: Date? = nil
    ) -> PhotoSearchError {
        .allSourcesFailed([
            PhotoSourceIssue(
                sourceID: .giphy,
                kind: kind,
                message: message,
                retryAt: retryAt
            )
        ])
    }
}

/// 用户凭据来源的具体客户端只在装配边界出现；聚合器与设置模型保持供应商无关。
private func credentialedPhotoSource(
    sourceID: PhotoSourceID,
    credential: String
) throws -> any PhotoSourceSearching {
    switch sourceID {
    case .pexels:
        return PexelsClient(apiKey: credential)
    case .pixabay:
        return PixabayClient(apiKey: credential)
    case .giphy:
        return GiphyCatalogClient(apiKey: credential)
    case .openverse, .metMuseum, .nasa:
        throw PhotoSourcePreferencesError.sourceUnavailable
    }
}

/// 无凭据来源也通过装配边界创建，便于测试与后续替换客户端实现。
private func uncredentialedPhotoSource(
    sourceID: PhotoSourceID
) throws -> any PhotoSourceSearching {
    switch sourceID {
    case .metMuseum:
        return MetMuseumClient()
    case .nasa:
        return NASAImagesClient()
    case .openverse, .pexels, .pixabay, .giphy:
        throw PhotoSourcePreferencesError.sourceUnavailable
    }
}
