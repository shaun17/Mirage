import Foundation

private actor ThisPersonDoesNotExistAvailability {
    static let shared = ThisPersonDoesNotExistAvailability()

    private var retryAfter: Date?

    func shouldAttemptRequest() -> Bool {
        retryAfter.map { Date() >= $0 } ?? true
    }

    func recordSuccess() {
        retryAfter = nil
    }

    func recordFailure() {
        retryAfter = Date().addingTimeInterval(30)
    }
}

struct ThisPersonDoesNotExistPayload: Sendable {
    let data: Data
    let mimeType: String
}

/// 把每次都会变化的上游响应先转码、冻结到 App Group，再发布稳定的本地内容引用。
public struct ThisPersonDoesNotExistClient: AvatarProviding, AvatarSourceGenerating, Sendable {
    private static let maximumDownloadBytes = 2 * 1024 * 1024
    private static let maximumPixels = 4_194_304

    private let endpoint: URL
    private let storage: AppGroupStorage?
    private let fetch: @Sendable (URL) async throws -> ThisPersonDoesNotExistPayload
    private let now: @Sendable () -> Date
    private let availability = ThisPersonDoesNotExistAvailability.shared

    public init(
        endpoint: URL = URL(string: "https://thispersondoesnotexist.com/random-person.jpeg")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            endpoint: endpoint,
            storage: try? AppGroupStorage(),
            fetch: { try await Self.fetchPayload(from: $0) },
            now: now
        )
    }

    init(
        endpoint: URL,
        storage: AppGroupStorage?,
        fetch: @escaping @Sendable (URL) async throws -> ThisPersonDoesNotExistPayload,
        now: @escaping @Sendable () -> Date
    ) {
        self.endpoint = endpoint
        self.storage = storage
        self.fetch = fetch
        self.now = now
    }

    public func currentGenerationDay() async -> AvatarGenerationDay {
        AvatarGenerationDay(date: now())
    }

    public func avatars(
        query: String,
        offset: Int,
        count: Int,
        generationDay: AvatarGenerationDay
    ) async -> [RemoteImageRecord] {
        var records: [RemoteImageRecord] = []
        for seed in AvatarSeed.batch(
            query: query,
            offset: offset,
            count: count,
            generationDay: generationDay
        ) {
            if let record = await avatar(
                seedMaterial: seed.material,
                generationDay: generationDay
            ) {
                records.append(record)
            }
        }
        return records
    }

    let avatarCatalogIdentifier = ImageSource.thisPersonDoesNotExist.rawValue
    let supportedAvatarTypes: Set<AvatarType> = [.aiRealistic]

    /// 未公开 API 合约与限流策略，因此生产混合目录只让约四分之一的候选进入排名。
    let avatarCatalogEligibilityDivisor: UInt64 = 4

    func avatar(
        seedMaterial: String,
        generationDay: AvatarGenerationDay
    ) async -> RemoteImageRecord? {
        guard Self.isAllowedEndpoint(endpoint), let storage else { return nil }
        let snapshotKey = StableImageID.seedHash(
            "mirage-tpdne-snapshot-v1|\(seedMaterial)"
        )
        do {
            let snapshot: Data
            if let cached = try await storage.readAvatarSnapshot(key: snapshotKey) {
                snapshot = cached
            } else {
                guard await availability.shouldAttemptRequest() else { return nil }
                do {
                    let payload = try await fetch(endpoint)
                    let normalized = try ImageTranscoder(
                        maximumBytes: Self.maximumDownloadBytes,
                        maximumPixels: Self.maximumPixels
                    ).transcode(payload.data, declaredMIMEType: payload.mimeType)
                    snapshot = try await storage.commitAvatarSnapshotIfAbsent(
                        normalized,
                        key: snapshotKey
                    )
                    await availability.recordSuccess()
                } catch {
                    await availability.recordFailure()
                    throw error
                }
            }
            return record(
                snapshot: snapshot,
                snapshotKey: snapshotKey,
                generationDay: generationDay
            )
        } catch {
            // 动态来源失败时由统一目录继续尝试下一个确定性来源，不能拖垮整页枚举。
            return nil
        }
    }

    private func record(
        snapshot: Data,
        snapshotKey: String,
        generationDay: AvatarGenerationDay
    ) -> RemoteImageRecord? {
        guard let reference = AvatarSnapshotReference(key: snapshotKey) else { return nil }
        return RemoteImageRecord(
            id: StableImageID.dailyThisPersonDoesNotExist(
                generationDay: generationDay,
                seedMaterial: snapshotKey,
                snapshot: snapshot
            ),
            title: "AI-generated person avatar",
            source: .thisPersonDoesNotExist,
            avatarType: .aiRealistic,
            imageURL: reference.url,
            thumbnailURL: reference.url,
            sourcePageURL: URL(string: "https://thispersondoesnotexist.com/"),
            license: .thisPersonDoesNotExistUsage,
            creator: "This Person Does Not Exist",
            creatorURL: URL(string: "https://thispersondoesnotexist.com/"),
            width: ImageTranscoder.outputSize,
            height: ImageTranscoder.outputSize,
            mimeType: "image/png"
        )
    }

    private static func fetchPayload(from url: URL) async throws -> ThisPersonDoesNotExistPayload {
        guard isAllowedEndpoint(url) else { throw URLError(.unsupportedURL) }
        let data = try await BoundedDownloader(
            url: url,
            maximumBytes: maximumDownloadBytes,
            timeoutInterval: 12,
            allowedHosts: ["thispersondoesnotexist.com", "www.thispersondoesnotexist.com"],
            acceptedMIMETypes: ["image/jpeg", "image/jpg"]
        ).download()
        return ThisPersonDoesNotExistPayload(
            data: data,
            mimeType: "image/jpeg"
        )
    }

    private static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "thispersondoesnotexist.com"
            || host == "www.thispersondoesnotexist.com"
    }
}
