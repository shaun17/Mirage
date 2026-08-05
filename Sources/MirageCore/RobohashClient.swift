import Foundation

/// Robohash 产品目录保留的五个固定图集；生产地址不使用会随新增图集漂移的 `any`。
public enum RobohashSet: String, CaseIterable, Codable, Sendable {
    case classicRobots = "set1"
    case monsters = "set2"
    case robotHeads = "set3"
    case cats = "set4"
    case cosmicApes = "set6"

    public var displayName: String {
        switch self {
        case .classicRobots: return "Classic Robots"
        case .monsters: return "Monsters"
        case .robotHeads: return "Robot Heads"
        case .cats: return "Cats"
        case .cosmicApes: return "Cosmic Apes"
        }
    }

    public var avatarType: AvatarType {
        switch self {
        case .classicRobots, .robotHeads: return .robot
        case .monsters: return .monster
        case .cats, .cosmicApes: return .animal
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
        case .cosmicApes: return "OceanSlim"
        }
    }

    public var creatorURL: URL? {
        switch self {
        case .cats: return URL(string: "https://www.peppercarrot.com/")
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

    let avatarCatalogIdentifier = ImageSource.robohash.rawValue
    var supportedAvatarTypes: Set<AvatarType> { Set(sets.map(\.avatarType)) }

    func avatar(
        seedMaterial: String,
        generationDay: AvatarGenerationDay
    ) async -> RemoteImageRecord? {
        record(
            seedMaterial: seedMaterial,
            generationDay: generationDay,
            candidateSets: sets
        )
    }

    func avatar(
        seedMaterial: String,
        generationDay: AvatarGenerationDay,
        allowedTypes: Set<AvatarType>
    ) async -> RemoteImageRecord? {
        record(
            seedMaterial: seedMaterial,
            generationDay: generationDay,
            candidateSets: sets.filter { allowedTypes.contains($0.avatarType) }
        )
    }

    private func record(
        seedMaterial: String,
        generationDay: AvatarGenerationDay,
        candidateSets: [RobohashSet]
    ) -> RemoteImageRecord? {
        guard let set = selectedSet(
            seedMaterial: seedMaterial,
            candidateSets: candidateSets
        ) else { return nil }
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
            avatarType: set.avatarType,
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

    private func selectedSet(
        seedMaterial: String,
        candidateSets: [RobohashSet]
    ) -> RobohashSet? {
        guard var selected = candidateSets.first else { return nil }
        var selectedRank = setRank(selected, seedMaterial: seedMaterial)
        for set in candidateSets.dropFirst() {
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
