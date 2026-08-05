import Foundation

/// Gravatar 中会随摘要变化、且不依赖真实用户资料的内建默认头像。
public enum GravatarStyle: String, CaseIterable, Codable, Sendable {
    case monsterID = "monsterid"

    public var displayName: String {
        switch self {
        case .monsterID: return "Monster ID"
        }
    }
}

/// 只使用 Gravatar 的强制默认头像，不查询用户资料，也不会命中真实用户上传的头像。
public struct GravatarClient: AvatarProviding, AvatarSourceGenerating, Sendable {
    private let endpoint: URL
    private let styles: [GravatarStyle]
    private let now: @Sendable () -> Date

    public init(
        endpoint: URL = URL(string: "https://gravatar.com/avatar")!,
        styles: [GravatarStyle] = GravatarStyle.allCases,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.styles = styles.isEmpty ? GravatarStyle.allCases : styles
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

    let avatarCatalogIdentifier = ImageSource.gravatar.rawValue
    let supportedAvatarTypes: Set<AvatarType> = [.monster]

    func avatar(
        seedMaterial: String,
        generationDay: AvatarGenerationDay
    ) async -> RemoteImageRecord? {
        let style = selectedStyle(seedMaterial: seedMaterial)
        let hash = StableImageID.seedHash("mirage-gravatar-seed-v1|\(seedMaterial)")
        guard let url = imageURL(style: style, hash: hash) else { return nil }
        return RemoteImageRecord(
            id: StableImageID.dailyGravatar(
                style: style.rawValue,
                generationDay: generationDay,
                seedMaterial: seedMaterial
            ),
            title: "Gravatar \(style.displayName) avatar",
            source: .gravatar,
            avatarType: .monster,
            imageURL: url,
            thumbnailURL: url,
            sourcePageURL: URL(string: "https://docs.gravatar.com/sdk/images/"),
            license: .gravatarUsage,
            creator: "Gravatar",
            creatorURL: URL(string: "https://gravatar.com"),
            width: 256,
            height: 256,
            mimeType: "image/png"
        )
    }

    private func selectedStyle(seedMaterial: String) -> GravatarStyle {
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

    private func styleRank(_ style: GravatarStyle, seedMaterial: String) -> UInt64 {
        let digest = StableImageID.seedHash(
            "mirage-gravatar-style-v1|\(seedMaterial)|\(style.rawValue)"
        )
        return UInt64(String(digest.prefix(16)), radix: 16) ?? 0
    }

    private func imageURL(style: GravatarStyle, hash: String) -> URL? {
        let path = endpoint.appendingPathComponent(hash, isDirectory: false)
        var components = URLComponents(url: path, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "s", value: "256"),
            URLQueryItem(name: "d", value: style.rawValue),
            URLQueryItem(name: "f", value: "y"),
            URLQueryItem(name: "r", value: "g"),
        ]
        guard let url = components?.url, url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
