import Foundation

/// 单个头像供应商只负责把已去标识化的稳定 seed 转成一条元数据记录。
protocol AvatarSourceGenerating: Sendable {
    var avatarCatalogIdentifier: String { get }

    func avatar(
        seedMaterial: String,
        generationDay: AvatarGenerationDay
    ) -> RemoteImageRecord?
}

/// 集中冻结查询归一化、绝对 offset 与每日命名空间，确保所有供应商遵循同一分页语义。
enum AvatarSeed {
    struct Value: Sendable {
        let material: String
    }

    static func batch(
        query: String,
        offset: Int,
        count: Int,
        generationDay: AvatarGenerationDay
    ) -> [Value] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let safeOffset = max(offset, 0)
        let safeCount = min(max(count, 0), 20)
        let end = safeOffset.addingReportingOverflow(safeCount)
        guard !end.overflow else { return [] }
        return (safeOffset..<end.partialValue).map { index in
            Value(
                material: "mirage-avatar-daily-v2|\(generationDay.identifier)|\(normalized)|\(index)"
            )
        }
    }
}

/// 生产头像目录在 DiceBear、Gravatar 与 Robohash 之间做稳定的一致性选择。
public struct AvatarCatalogClient: AvatarProviding, Sendable {
    private let providers: [any AvatarSourceGenerating]
    private let now: @Sendable () -> Date

    public init(
        diceBear: DiceBearClient = DiceBearClient(),
        gravatar: GravatarClient = GravatarClient(),
        robohash: RobohashClient = RobohashClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        providers = [diceBear, gravatar, robohash]
        self.now = now
    }

    init(
        providers: [any AvatarSourceGenerating],
        now: @escaping @Sendable () -> Date
    ) {
        self.providers = providers
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
        guard !providers.isEmpty else { return [] }
        return AvatarSeed.batch(
            query: query,
            offset: offset,
            count: count,
            generationDay: generationDay
        ).compactMap { value in
            rankedProviders(seedMaterial: value.material).lazy.compactMap {
                $0.avatar(seedMaterial: value.material, generationDay: generationDay)
            }.first
        }
    }

    /// Rendezvous hash 让供应商数组重排不改变结果；某一来源构造失败时按稳定次序降级。
    private func rankedProviders(seedMaterial: String) -> [any AvatarSourceGenerating] {
        providers.sorted { left, right in
            let leftRank = providerRank(left, seedMaterial: seedMaterial)
            let rightRank = providerRank(right, seedMaterial: seedMaterial)
            if leftRank == rightRank {
                return left.avatarCatalogIdentifier > right.avatarCatalogIdentifier
            }
            return leftRank > rightRank
        }
    }

    private func providerRank(
        _ provider: any AvatarSourceGenerating,
        seedMaterial: String
    ) -> UInt64 {
        let digest = StableImageID.seedHash(
            "mirage-avatar-provider-v1|\(seedMaterial)|\(provider.avatarCatalogIdentifier)"
        )
        return UInt64(String(digest.prefix(16)), radix: 16) ?? 0
    }
}
