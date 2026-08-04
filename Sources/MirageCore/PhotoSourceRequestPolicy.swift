import Foundation

/// 供应商返回的通用额度快照；只有服务端明确提供的字段才会有值。
public struct PhotoSourceQuotaSnapshot: Codable, Equatable, Sendable {
    public let limit: Int?
    public let remaining: Int?
    public let resetAt: Date?

    public init(limit: Int? = nil, remaining: Int? = nil, resetAt: Date? = nil) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
    }
}

/// 将消费者页大小与上游批次大小解耦；新增供应商只需声明策略，不需要修改聚合器。
public struct PhotoSourceRequestPolicy: Equatable, Sendable {
    public let version: UInt16
    public let preferredBatchSize: Int
    public let maximumBatchSize: Int
    public let connectionTestBatchSize: Int
    public let maximumQueryCharacters: Int?
    public let metadataTimeToLive: TimeInterval
    /// 有用户凭据或严格额度的来源不能在共享存储失效时退化成各进程独立请求。
    public let requiresPersistentCoordination: Bool
    public let rateLimitFallback: TimeInterval
    public let transientBackoffMaximum: TimeInterval

    public init(
        version: UInt16,
        preferredBatchSize: Int,
        maximumBatchSize: Int,
        connectionTestBatchSize: Int = 1,
        maximumQueryCharacters: Int? = nil,
        metadataTimeToLive: TimeInterval,
        requiresPersistentCoordination: Bool = false,
        rateLimitFallback: TimeInterval = 60,
        transientBackoffMaximum: TimeInterval = 60
    ) {
        self.version = version
        self.preferredBatchSize = preferredBatchSize
        self.maximumBatchSize = maximumBatchSize
        self.connectionTestBatchSize = min(max(connectionTestBatchSize, 1), maximumBatchSize)
        self.maximumQueryCharacters = maximumQueryCharacters.map { max($0, 1) }
        self.metadataTimeToLive = metadataTimeToLive
        self.requiresPersistentCoordination = requiresPersistentCoordination
        self.rateLimitFallback = rateLimitFallback
        self.transientBackoffMaximum = transientBackoffMaximum
    }

    func batchSize(for consumerPageSize: Int) -> Int {
        min(max(consumerPageSize, preferredBatchSize), maximumBatchSize)
    }

    func requestQuery(_ query: String) -> String {
        guard let maximumQueryCharacters else { return query }
        return String(query.prefix(maximumQueryCharacters))
    }

    func connectionTestPolicy() -> PhotoSourceRequestPolicy {
        PhotoSourceRequestPolicy(
            version: version,
            preferredBatchSize: connectionTestBatchSize,
            maximumBatchSize: connectionTestBatchSize,
            connectionTestBatchSize: connectionTestBatchSize,
            maximumQueryCharacters: maximumQueryCharacters,
            metadataTimeToLive: metadataTimeToLive,
            requiresPersistentCoordination: requiresPersistentCoordination,
            rateLimitFallback: rateLimitFallback,
            transientBackoffMaximum: transientBackoffMaximum
        )
    }
}

public enum PhotoSourceRequestPolicies {
    /// 修改任何会改变上游分页边界的策略时必须推进，令旧 Finder token 明确失效。
    public static let catalogVersion: UInt16 = 2

    public static func policy(for sourceID: PhotoSourceID) -> PhotoSourceRequestPolicy {
        switch sourceID {
        case .openverse:
            return PhotoSourceRequestPolicy(
                version: 1,
                preferredBatchSize: 40,
                maximumBatchSize: 50,
                metadataTimeToLive: 60 * 60
            )
        case .pexels:
            return PhotoSourceRequestPolicy(
                version: 1,
                preferredBatchSize: 80,
                maximumBatchSize: 80,
                metadataTimeToLive: 24 * 60 * 60,
                requiresPersistentCoordination: true
            )
        case .pixabay:
            return PhotoSourceRequestPolicy(
                version: 1,
                preferredBatchSize: 40,
                maximumBatchSize: 200,
                connectionTestBatchSize: 3,
                maximumQueryCharacters: 100,
                metadataTimeToLive: 24 * 60 * 60,
                requiresPersistentCoordination: true
            )
        }
    }
}

/// 页令牌只保存当前上游批次及本地 offset，不把几十条图片元数据塞进系统游标。
struct PhotoSourceBatchPosition: Codable, Equatable, Sendable {
    private static let envelopePrefix = "b2:"
    private static let schemaVersion: UInt8 = 2

    let schemaVersion: UInt8
    let policyVersion: UInt16
    let batchSize: Int
    let offset: Int
    let upstreamCursor: PhotoSourceCursor?
    let requestFingerprint: String
    let batchID: UUID?

    init(
        policyVersion: UInt16,
        batchSize: Int,
        offset: Int = 0,
        upstreamCursor: PhotoSourceCursor? = nil,
        requestFingerprint: String,
        batchID: UUID? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.policyVersion = policyVersion
        self.batchSize = batchSize
        self.offset = offset
        self.upstreamCursor = upstreamCursor
        self.requestFingerprint = requestFingerprint
        self.batchID = batchID
    }

    static func resolve(
        _ cursor: PhotoSourceCursor?,
        policy: PhotoSourceRequestPolicy,
        consumerPageSize: Int,
        requestFingerprint: String
    ) throws -> PhotoSourceBatchPosition {
        guard let cursor else {
            return PhotoSourceBatchPosition(
                policyVersion: policy.version,
                batchSize: policy.batchSize(for: consumerPageSize),
                requestFingerprint: requestFingerprint
            )
        }
        guard cursor.rawValue.hasPrefix(envelopePrefix) else {
            throw PhotoSearchError.invalidCursor
        }
        let encoded = String(cursor.rawValue.dropFirst(envelopePrefix.count))
        guard let data = Data(base64URLEncoded: encoded),
              let value = try? JSONDecoder().decode(PhotoSourceBatchPosition.self, from: data),
              value.schemaVersion == schemaVersion,
              value.policyVersion == policy.version,
              value.batchSize == policy.batchSize(for: consumerPageSize),
              value.offset >= 0,
              value.offset < value.batchSize,
              value.requestFingerprint == requestFingerprint,
              value.requestFingerprint.count == 64,
              (value.upstreamCursor?.rawValue.utf8.count ?? 0) <= 512 else {
            throw PhotoSearchError.invalidCursor
        }
        return value
    }

    func cursor() throws -> PhotoSourceCursor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rawValue = Self.envelopePrefix + (try encoder.encode(self)).base64URLEncodedString()
        guard rawValue.utf8.count <= 1_024 else { throw PhotoSearchError.invalidCursor }
        return PhotoSourceCursor(rawValue: rawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "v"
        case policyVersion = "p"
        case batchSize = "z"
        case offset = "o"
        case upstreamCursor = "c"
        case requestFingerprint = "f"
        case batchID = "b"
    }
}

struct PhotoSourceBatchKey: Hashable, Sendable {
    let rawValue: String

    init(
        sourceID: PhotoSourceID,
        query: String,
        upstreamCursor: PhotoSourceCursor?,
        batchSize: Int,
        policyVersion: UInt16,
        configurationPartition: String
    ) {
        let requestFingerprint = Self.requestFingerprint(
            sourceID: sourceID,
            query: query,
            batchSize: batchSize,
            policyVersion: policyVersion,
            configurationPartition: configurationPartition
        )
        let cursor = upstreamCursor?.rawValue ?? "initial"
        rawValue = StableImageID.seedHash(
            "photo-source-batch-v2|\(requestFingerprint)|\(cursor)"
        )
    }

    static func requestFingerprint(
        sourceID: PhotoSourceID,
        query: String,
        batchSize: Int,
        policyVersion: UInt16,
        configurationPartition: String
    ) -> String {
        let normalized = normalizedQuery(query)
        let queryFingerprint = StableImageID.seedHash("photo-source-query|\(normalized)")
        return StableImageID.seedHash(
            "photo-source-request-v1|\(sourceID.rawValue)|\(queryFingerprint)|\(batchSize)|\(policyVersion)|\(configurationPartition)"
        )
    }

    private static func normalizedQuery(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

struct CachedPhotoSourceBatch: Codable, Equatable, Sendable {
    static let schemaVersion: UInt8 = 2

    let schemaVersion: UInt8
    let batchID: UUID
    let keyFingerprint: String
    let sourceID: PhotoSourceID
    let policyVersion: UInt16
    let upstreamPageSize: Int
    let records: [RemoteImageRecord]
    let upstreamNextCursor: PhotoSourceCursor?
    let fetchedAt: Date
    let expiresAt: Date
    let quota: PhotoSourceQuotaSnapshot?

    init(
        key: PhotoSourceBatchKey,
        sourceID: PhotoSourceID,
        policyVersion: UInt16,
        upstreamPageSize: Int,
        page: PhotoSourcePage,
        fetchedAt: Date,
        expiresAt: Date
    ) {
        var seen = Set<String>()
        self.schemaVersion = Self.schemaVersion
        self.batchID = UUID()
        self.keyFingerprint = key.rawValue
        self.sourceID = sourceID
        self.policyVersion = policyVersion
        self.upstreamPageSize = upstreamPageSize
        self.records = Array(page.records
            .filter { seen.insert($0.id).inserted }
            .prefix(upstreamPageSize))
        self.upstreamNextCursor = page.nextCursor
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.quota = page.quota
    }
}

struct PhotoSourceBatchLease: Codable, Equatable, Sendable {
    let owner: UUID
    let expiresAt: Date
}

enum PhotoSourceBatchClaim: Sendable {
    case cached(CachedPhotoSourceBatch)
    case owned
    case waiting(until: Date)
}

struct PhotoSourceBudgetKey: Hashable, Sendable {
    let rawValue: String

    init(sourceID: PhotoSourceID, configurationPartition: String, policyVersion: UInt16) {
        rawValue = StableImageID.seedHash(
            "photo-source-budget-v1|\(sourceID.rawValue)|\(configurationPartition)|\(policyVersion)"
        )
    }
}

struct PhotoSourceBudgetState: Codable, Equatable, Sendable {
    static let schemaVersion: UInt8 = 1

    let schemaVersion: UInt8
    let keyFingerprint: String
    let sourceID: PhotoSourceID
    let blockedUntil: Date?
    let issueKind: PhotoSourceIssueKind?
    let consecutiveFailures: Int
    let quota: PhotoSourceQuotaSnapshot?
    let updatedAt: Date

    init(
        key: PhotoSourceBudgetKey,
        sourceID: PhotoSourceID,
        blockedUntil: Date?,
        issueKind: PhotoSourceIssueKind?,
        consecutiveFailures: Int,
        quota: PhotoSourceQuotaSnapshot?,
        updatedAt: Date
    ) {
        self.schemaVersion = Self.schemaVersion
        self.keyFingerprint = key.rawValue
        self.sourceID = sourceID
        self.blockedUntil = blockedUntil
        self.issueKind = issueKind
        self.consecutiveFailures = consecutiveFailures
        self.quota = quota
        self.updatedAt = updatedAt
    }
}

struct PhotoSourceDeferredError: PhotoSourceFailure, LocalizedError, Sendable {
    let sourceID: PhotoSourceID
    let issueKind: PhotoSourceIssueKind
    let retryAt: Date?

    var errorDescription: String? {
        let name = PhotoSourceRegistry.descriptor(for: sourceID)?.displayName ?? sourceID.rawValue
        switch issueKind {
        case .invalidCredential, .missingCredential:
            return "\(name) API Key 无效或未配置。"
        case .rateLimited:
            return "\(name) 请求额度正在退避，请稍后重试。"
        case .network:
            return "\(name) 网络请求正在短暂退避。"
        case .decoding, .invalidResponse:
            return "\(name) 响应异常，正在短暂退避。"
        case .unavailable:
            return "\(name) 暂时不可用。"
        }
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
