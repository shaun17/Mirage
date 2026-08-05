import Foundation

/// Robohash 官方公共实例当前公开的六个固定图集；生产地址不使用会随新增图集漂移的 `any`。
public enum RobohashSet: String, CaseIterable, Codable, Sendable {
    case classicRobots = "set1"
    case monsters = "set2"
    case robotHeads = "set3"
    case cats = "set4"
    case humanAvatars = "set5"
    case cosmicApes = "set6"

    public var displayName: String {
        switch self {
        case .classicRobots: return "Classic Robots"
        case .monsters: return "Monsters"
        case .robotHeads: return "Robot Heads"
        case .cats: return "Cats"
        case .humanAvatars: return "Human Avatars"
        case .cosmicApes: return "Cosmic Apes"
        }
    }

    public var license: LicenseInfo {
        switch self {
        case .classicRobots:
            return LicenseInfo(
                identifier: "cc-by-3.0-or-4.0",
                displayName: "CC BY 3.0 / 4.0",
                url: URL(string: "https://github.com/e1ven/Robohash#robosets")
            )
        case .monsters, .robotHeads:
            return LicenseInfo(
                identifier: "cc-by-3.0",
                displayName: "CC BY 3.0",
                url: URL(string: "https://creativecommons.org/licenses/by/3.0/")
            )
        case .cats:
            return LicenseInfo(
                identifier: "cc-by-4.0",
                displayName: "CC BY 4.0",
                url: URL(string: "https://creativecommons.org/licenses/by/4.0/")
            )
        case .humanAvatars:
            return LicenseInfo(
                identifier: "avataaars-free-use",
                displayName: "Free for personal and commercial use",
                url: URL(string: "https://avataaars.com/")
            )
        case .cosmicApes:
            return .cc0
        }
    }

    public var creator: String {
        switch self {
        case .classicRobots: return "Zikri Kader"
        case .monsters: return "Hrvoje Novakovic"
        case .robotHeads: return "Julian Peter Arias"
        case .cats: return "David Revoy"
        case .humanAvatars: return "Pablo Stanley"
        case .cosmicApes: return "OceanSlim"
        }
    }

    public var creatorURL: URL? {
        switch self {
        case .cats: return URL(string: "https://www.peppercarrot.com/")
        case .humanAvatars: return URL(string: "https://avataaars.com/")
        case .cosmicApes: return URL(string: "https://github.com/OceanSlim")
        case .classicRobots, .monsters, .robotHeads: return nil
        }
    }
}

/// 构造固定图集的 Robohash PNG 地址；原始查询只在本地参与 SHA-256。
public struct RobohashClient: AvatarProviding, AvatarSourceGenerating, Sendable {
    private let endpoint: URL
    private let sets: [RobohashSet]
    private let now: @Sendable () -> Date

    public init(
        endpoint: URL = URL(string: "https://robohash.org")!,
        sets: [RobohashSet] = RobohashSet.allCases,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.sets = sets.isEmpty ? RobohashSet.allCases : sets
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
        AvatarSeed.batch(
            query: query,
            offset: offset,
            count: count,
            generationDay: generationDay
        ).compactMap { avatar(seedMaterial: $0.material, generationDay: generationDay) }
    }

    let avatarCatalogIdentifier = ImageSource.robohash.rawValue

    func avatar(
        seedMaterial: String,
        generationDay: AvatarGenerationDay
    ) -> RemoteImageRecord? {
        let set = selectedSet(seedMaterial: seedMaterial)
        let hash = StableImageID.seedHash("mirage-robohash-seed-v1|\(seedMaterial)")
        guard let url = imageURL(set: set, hash: hash) else { return nil }
        return RemoteImageRecord(
            id: StableImageID.dailyRobohash(
                set: set.rawValue,
                generationDay: generationDay,
                seedMaterial: seedMaterial
            ),
            title: "Robohash \(set.displayName) avatar",
            source: .robohash,
            imageURL: url,
            thumbnailURL: url,
            sourcePageURL: URL(string: "https://robohash.org/"),
            license: set.license,
            creator: set.creator,
            creatorURL: set.creatorURL,
            width: 256,
            height: 256,
            mimeType: "image/png"
        )
    }

    private func selectedSet(seedMaterial: String) -> RobohashSet {
        var selected = sets[0]
        var selectedRank = setRank(selected, seedMaterial: seedMaterial)
        for set in sets.dropFirst() {
            let rank = setRank(set, seedMaterial: seedMaterial)
            if rank > selectedRank || (rank == selectedRank && set.rawValue > selected.rawValue) {
                selected = set
                selectedRank = rank
            }
        }
        return selected
    }

    private func setRank(_ set: RobohashSet, seedMaterial: String) -> UInt64 {
        let digest = StableImageID.seedHash(
            "mirage-robohash-set-v1|\(seedMaterial)|\(set.rawValue)"
        )
        return UInt64(String(digest.prefix(16)), radix: 16) ?? 0
    }

    private func imageURL(set: RobohashSet, hash: String) -> URL? {
        let path = endpoint.appendingPathComponent("\(hash).png", isDirectory: false)
        var components = URLComponents(url: path, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "size", value: "256x256"),
            URLQueryItem(name: "set", value: set.rawValue),
        ]
        guard let url = components?.url, url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
