import Foundation

/// 单个头像供应商只负责把已去标识化的稳定 seed 转成一条元数据记录。
protocol AvatarSourceGenerating: Sendable {
    var avatarCatalogIdentifier: String { get }
    var avatarCatalogEligibilityDivisor: UInt64 { get }
    var supportedAvatarTypes: Set<AvatarType> { get }

    func avatar(
        seedMaterial: String,
        generationDay: AvatarGenerationDay
    ) async -> RemoteImageRecord?

    func avatar(
        seedMaterial: String,
        generationDay: AvatarGenerationDay,
        allowedTypes: Set<AvatarType>
    ) async -> RemoteImageRecord?
}

extension AvatarSourceGenerating {
    var avatarCatalogEligibilityDivisor: UInt64 { 1 }

    func avatar(
        seedMaterial: String,
        generationDay: AvatarGenerationDay,
        allowedTypes: Set<AvatarType>
    ) async -> RemoteImageRecord? {
        guard let record = await avatar(
            seedMaterial: seedMaterial,
            generationDay: generationDay
        ), record.avatarType.map(allowedTypes.contains) == true else {
            return nil
        }
        return record
    }
}

/// 集中冻结查询归一化、绝对 offset 与每日命名空间，确保所有供应商遵循同一分页语义。
enum AvatarSeed {
    static let maximumBatchSize = 20

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
        let safeCount = min(max(count, 0), maximumBatchSize)
        let end = safeOffset.addingReportingOverflow(safeCount)
        guard !end.overflow else { return [] }
        return (safeOffset..<end.partialValue).map { index in
            Value(
                material: "mirage-avatar-daily-v2|\(generationDay.identifier)|\(normalized)|\(index)"
            )
        }
    }

    /// Picrew 的公开预览与绝对分页位置一一对应，避免同一页重复映射同一张作品。
    static func absoluteIndex(from seedMaterial: String) -> Int? {
        guard let field = seedMaterial.split(separator: "|", omittingEmptySubsequences: false).last,
              let index = Int(field), index >= 0 else {
            return nil
        }
        return index
    }
}

/// 生产头像目录在确定性服务与已冻结的动态人像之间做稳定的一致性选择。
public struct AvatarCatalogClient: AvatarProviding, Sendable {
    private let providers: [any AvatarSourceGenerating]
    private let now: @Sendable () -> Date

    public init(
        diceBear: DiceBearClient = DiceBearClient(),
        gravatar: GravatarClient = GravatarClient(),
        robohash: RobohashClient = RobohashClient(),
        thisPersonDoesNotExist: ThisPersonDoesNotExistClient = ThisPersonDoesNotExistClient(),
        includesPicrewDiscovery: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        var configuredProviders: [any AvatarSourceGenerating] = [
            diceBear,
            gravatar,
            robohash,
            thisPersonDoesNotExist,
        ]
        if includesPicrewDiscovery {
            configuredProviders.append(PicrewDiscoveryClient())
        }
        providers = configuredProviders
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
        await avatars(
            query: query,
            offset: offset,
            count: count,
            generationDay: generationDay,
            allowedTypes: Set(AvatarType.allCases)
        )
    }

    public func avatars(
        query: String,
        offset: Int,
        count: Int,
        generationDay: AvatarGenerationDay,
        allowedTypes: Set<AvatarType>
    ) async -> [RemoteImageRecord] {
        let effectiveTypes = allowedTypes.intersection(Set(AvatarType.allCases))
        guard !effectiveTypes.isEmpty else { return [] }
        let eligibleProviders = providers.filter {
            !$0.supportedAvatarTypes.isDisjoint(with: effectiveTypes)
        }
        guard !eligibleProviders.isEmpty else { return [] }
        let seeds = AvatarSeed.batch(
            query: query,
            offset: offset,
            count: count,
            generationDay: generationDay
        )
        var records: [RemoteImageRecord] = []
        records.reserveCapacity(seeds.count)
        for value in seeds {
            for provider in rankedProviders(
                eligibleProviders,
                seedMaterial: value.material
            ) where isEligible(
                provider,
                seedMaterial: value.material,
                providerCount: eligibleProviders.count
            ) {
                if let record = await provider.avatar(
                    seedMaterial: value.material,
                    generationDay: generationDay,
                    allowedTypes: effectiveTypes
                ) {
                    records.append(record)
                    break
                }
            }
        }
        return records
    }

    /// Rendezvous hash 让供应商数组重排不改变结果；某一来源构造失败时按稳定次序降级。
    private func rankedProviders(
        _ candidates: [any AvatarSourceGenerating],
        seedMaterial: String
    ) -> [any AvatarSourceGenerating] {
        candidates.sorted { left, right in
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

    /// 无公开批量 API 的来源可稳定降低入选频率，失败后仍由下一确定性来源补足记录。
    private func isEligible(
        _ provider: any AvatarSourceGenerating,
        seedMaterial: String,
        providerCount: Int
    ) -> Bool {
        let divisor = max(provider.avatarCatalogEligibilityDivisor, 1)
        guard divisor > 1 else { return true }
        if providerCount == 1,
           let index = AvatarSeed.absoluteIndex(from: seedMaterial) {
            return UInt64(index).isMultiple(of: divisor)
        }
        let digest = StableImageID.seedHash(
            "mirage-avatar-provider-eligibility-v1|\(seedMaterial)|\(provider.avatarCatalogIdentifier)"
        )
        let value = UInt64(String(digest.prefix(16)), radix: 16) ?? 0
        return value.isMultiple(of: divisor)
    }
}
