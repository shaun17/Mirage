import Foundation

/// 头像生成批次所属的 UTC 公历日；标识可直接参与稳定 seed 计算。
public struct AvatarGenerationDay: Hashable, Sendable {
    public let identifier: String

    public init(date: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        identifier = String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year!,
            components.month!,
            components.day!
        )
    }

    /// 从持久化头像 ID 恢复生成日；只接受真实且 canonical 的 UTC 公历日期。
    public init?(identifier: String) {
        let fields = identifier.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0].count == 4,
              fields[1].count == 2,
              fields[2].count == 2,
              let year = Int(fields[0]),
              let month = Int(fields[1]),
              let day = Int(fields[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        self.init(date: date)
        guard self.identifier == identifier else { return nil }
    }
}

/// 保留旧名称供现有注入点和外部调用平滑迁移。
public typealias DiceBearGenerationDay = AvatarGenerationDay

public protocol AvatarProviding: Sendable {
    /// 生成无个人信息的头像元数据；动态来源会在此阶段先冻结远程内容。
    func avatars(
        query: String,
        offset: Int,
        count: Int,
        generationDay: AvatarGenerationDay
    ) async -> [RemoteImageRecord]

    /// 按内容类型在生成边界选源，避免先生成混合目录再过滤出稀疏、不可续页的结果。
    func avatars(
        query: String,
        offset: Int,
        count: Int,
        generationDay: AvatarGenerationDay,
        allowedTypes: Set<AvatarType>
    ) async -> [RemoteImageRecord]

    /// 获取当前生成日，供跨分页调用在开始时冻结同一日批次。
    func currentGenerationDay() async -> AvatarGenerationDay
}

/// 保留旧协议名，测试替身和调用方无需与本次多供应商接入同时迁移。
public typealias DiceBearProviding = AvatarProviding

public extension AvatarProviding {
    /// 旧供应商默认保持兼容；统一目录会覆盖此入口，在生成前完成类型约束。
    func avatars(
        query: String,
        offset: Int,
        count: Int,
        generationDay: AvatarGenerationDay,
        allowedTypes: Set<AvatarType>
    ) async -> [RemoteImageRecord] {
        let supportedTypes = allowedTypes.intersection(Set(AvatarType.allCases))
        guard !supportedTypes.isEmpty else { return [] }
        return await avatars(
            query: query,
            offset: offset,
            count: count,
            generationDay: generationDay
        )
        .filter { $0.matchesAvatarTypes(supportedTypes) }
    }

    /// 旧调用入口每次只读取一次日期，再交给显式生成方法。
    func avatars(query: String, offset: Int = 0, count: Int) async -> [RemoteImageRecord] {
        let generationDay = await currentGenerationDay()
        return await avatars(
            query: query,
            offset: offset,
            count: count,
            generationDay: generationDay
        )
    }

    /// 类型筛选调用同样只读取一次日期，保证首批内部使用同一个 UTC 生成日。
    func avatars(
        query: String,
        offset: Int = 0,
        count: Int,
        allowedTypes: Set<AvatarType>
    ) async -> [RemoteImageRecord] {
        let generationDay = await currentGenerationDay()
        return await avatars(
            query: query,
            offset: offset,
            count: count,
            generationDay: generationDay,
            allowedTypes: allowedTypes
        )
    }

    /// 不需要分页的调用统一从第一个头像开始，保持发现页等旧调用语义。
    func avatars(query: String, count: Int) async -> [RemoteImageRecord] {
        await avatars(query: query, offset: 0, count: count)
    }
}

/// 构造 DiceBear 10.x PNG 地址；真正的图片下载由消费方按需进行。
public struct DiceBearClient: AvatarProviding, AvatarSourceGenerating, Sendable {
    private let endpoint: URL
    private let styles: [DiceBearStyle]
    private let now: @Sendable () -> Date

    public init(
        endpoint: URL = URL(string: "https://api.dicebear.com")!,
        styles: [DiceBearStyle] = DiceBearStyle.mirageCatalog,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.styles = styles.isEmpty ? DiceBearStyle.mirageCatalog : styles
        self.now = now
    }

    public func currentGenerationDay() async -> AvatarGenerationDay {
        AvatarGenerationDay(date: now())
    }

    /// 查询文字只参与本地 SHA-256；风格按摘要稳定随机，原始文字不会进入远程 URL。
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

    let avatarCatalogIdentifier = ImageSource.diceBear.rawValue
    let supportedAvatarTypes: Set<AvatarType> = [.cartoonCharacter]

    func avatar(
        seedMaterial: String,
        generationDay: AvatarGenerationDay
    ) async -> RemoteImageRecord? {
        let seedHash = StableImageID.seedHash("mirage-dicebear-seed-v1|\(seedMaterial)")
        let style = selectedStyle(seedMaterial: seedMaterial)
        guard let url = imageURL(style: style, seed: seedHash) else { return nil }
        return RemoteImageRecord(
            id: StableImageID.dailyDiceBear(
                style: style.rawValue,
                generationDay: generationDay,
                seedMaterial: seedMaterial
            ),
            title: "\(style.displayName) avatar",
            source: .diceBear,
            avatarType: .cartoonCharacter,
            imageURL: url,
            thumbnailURL: url,
            sourcePageURL: URL(string: "https://www.dicebear.com/styles/\(style.rawValue)/"),
            license: style.license,
            creator: style.creator,
            creatorURL: style.creatorURL,
            width: 256,
            height: 256,
            mimeType: "image/png"
        )
    }

    /// 对每个候选风格独立打分并取最高值；目录重排不改变结果，新增风格也只影响少量记录。
    private func selectedStyle(seedMaterial: String) -> DiceBearStyle {
        var selected = styles[0]
        var selectedRank = styleRank(selected, seedMaterial: seedMaterial)
        for style in styles.dropFirst() {
            let rank = styleRank(style, seedMaterial: seedMaterial)
            if rank > selectedRank || (rank == selectedRank && style.rawValue > selected.rawValue) {
                selected = style
                selectedRank = rank
            }
        }
        return selected
    }

    /// 只取摘要前 64 位即可均匀排序；风格名参与摘要，使各候选得到彼此独立的稳定分数。
    private func styleRank(_ style: DiceBearStyle, seedMaterial: String) -> UInt64 {
        let digest = StableImageID.seedHash("mirage-style-v1|\(seedMaterial)|\(style.rawValue)")
        return UInt64(String(digest.prefix(16)), radix: 16) ?? 0
    }

    /// 公共 HTTP API 的光栅输出上限为 256 像素；固定版本与尺寸保持记录可复现。
    private func imageURL(style: DiceBearStyle, seed: String) -> URL? {
        let path = endpoint
            .appendingPathComponent("10.x", isDirectory: true)
            .appendingPathComponent(style.rawValue, isDirectory: true)
            .appendingPathComponent("png", isDirectory: false)
        var components = URLComponents(url: path, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "seed", value: seed),
            URLQueryItem(name: "size", value: "256")
        ]
        guard let url = components?.url, url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
