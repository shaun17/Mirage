import Foundation

typealias CredentialedPhotoSourceFactory = @Sendable (
    _ sourceID: PhotoSourceID,
    _ credential: String
) throws -> any PhotoSourceSearching

/// 两个进程各自创建环境，但通过 App Group 读取同一份配置与应用持久数据。
public struct PhotoSearchEnvironment: Sendable {
    public let preferences: PhotoSourcePreferencesStore
    public let credentials: any PhotoSourceCredentialStoring
    private let openverse: any PhotoSourceSearching
    private let requestCoordinator: PhotoSourceRequestCoordinator
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
        self.credentialedSourceFactory = credentialedPhotoSource
    }

    init(
        preferences: PhotoSourcePreferencesStore,
        credentials: any PhotoSourceCredentialStoring,
        openverse: any PhotoSourceSearching,
        requestCoordinator: PhotoSourceRequestCoordinator,
        credentialedSourceFactory: @escaping CredentialedPhotoSourceFactory = credentialedPhotoSource
    ) {
        self.preferences = preferences
        self.credentials = credentials
        self.openverse = openverse
        self.requestCoordinator = requestCoordinator
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
        ImageSearchService(
            photos: ConfiguredPhotoSearcher(
                surface: surface,
                purpose: purpose,
                preferences: preferences,
                credentials: credentials,
                openverse: openverse,
                requestCoordinator: requestCoordinator,
                credentialedSourceFactory: credentialedSourceFactory
            ),
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
                PhotoSourceRegistry.descriptor(for: $0)?.supports(surface, purpose: .recommendation) == true
            }
            .map(\.rawValue)
            .joined(separator: ",")
        // App 与 Finder 的有效来源相同时继续共享同一 generation；只有来源集合真正分叉才隔离。
        return "\(DiscoveryRecommendation.catalogKey):photo-sources:\(snapshot.revision):\(sourceIDs)"
    }

    /// 设置页用供应商最小合法批次验证凭据，并复用 App 与 Finder 共用的缓存和预算层。
    public func testConnection(sourceID: PhotoSourceID, credential: String) async throws {
        switch sourceID {
        case .openverse:
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
        self.credentialedSourceFactory = credentialedPhotoSource
    }

    init(
        surface: PhotoSourceSurface,
        purpose: PhotoSearchPurpose = .interactive,
        preferences: any PhotoSourcePreferencesReading,
        credentials: any PhotoSourceCredentialReading,
        openverse: any PhotoSourceSearching,
        requestCoordinator: PhotoSourceRequestCoordinator,
        credentialedSourceFactory: @escaping CredentialedPhotoSourceFactory = credentialedPhotoSource
    ) {
        self.surface = surface
        self.purpose = purpose
        self.preferences = preferences
        self.credentials = credentials
        self.openverse = openverse
        self.requestCoordinator = requestCoordinator
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

    public func search(query: String, page: Int, pageSize: Int) async throws -> PhotoSearchPage {
        let searcher = try await makeSearcher()
        return try await searcher.search(query: query, page: page, pageSize: pageSize)
    }

    private func makeSearcher() async throws -> AggregatedPhotoSearcher {
        let snapshot = await preferences.snapshot()
        var sources: [any PhotoSourceSearching] = []
        var issues: [PhotoSourceIssue] = []
        for sourceID in snapshot.sourceIDs(for: surface)
        where PhotoSourceRegistry.descriptor(for: sourceID)?.supports(surface, purpose: purpose) == true {
            switch sourceID {
            case .openverse:
                sources.append(coordinated(
                    openverse,
                    partition: PhotoSearchEnvironment.requestPartition(
                        sourceID: sourceID,
                        credential: nil
                    )
                ))
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
    case .openverse:
        throw PhotoSourcePreferencesError.sourceUnavailable
    }
}
