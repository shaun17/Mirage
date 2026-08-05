import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MirageCore

final class AvatarProviderTests: XCTestCase {
    private static let fixedNow = utcDate(year: 2026, month: 8, day: 5, hour: 12)
    private static let generationDay = AvatarGenerationDay(date: fixedNow)

    /// Gravatar 只请求强制默认头像，不能因摘要碰撞展示真实用户内容。
    func testGravatarUsesForcedGeneratedDefaultWithoutRawQuery() async throws {
        let records = await GravatarClient(styles: [.monsterID], now: { Self.fixedNow })
            .avatars(query: "Private Name", count: 1)
        let record = try XCTUnwrap(records.first)
        let components = try XCTUnwrap(URLComponents(url: record.imageURL, resolvingAgainstBaseURL: false))
        let parameters = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        XCTAssertEqual(record.source, .gravatar)
        XCTAssertEqual(record.avatarType, .monster)
        XCTAssertTrue(record.id.hasPrefix("gravatar:v2:monsterid:2026-08-05:"))
        XCTAssertEqual(record.imageURL.host, "gravatar.com")
        XCTAssertEqual(record.imageURL.lastPathComponent.count, 64)
        XCTAssertEqual(parameters["s"], "256")
        XCTAssertEqual(parameters["d"], "monsterid")
        XCTAssertEqual(parameters["f"], "y")
        XCTAssertEqual(parameters["r"], "g")
        XCTAssertFalse(record.imageURL.absoluteString.localizedCaseInsensitiveContains("Private"))
        XCTAssertEqual(record.license.identifier, "gravatar-usage")
        XCTAssertEqual(StableImageID.avatarGenerationDay(from: record.id), Self.generationDay)
    }

    /// 产品目录只保留用户选定的 Monster ID。
    func testGravatarCatalogContainsMonsterIDOnly() {
        XCTAssertEqual(GravatarStyle.allCases.map(\.rawValue), ["monsterid"])
    }

    /// Robohash 固定 set 与尺寸，避免 `any` 在服务新增图集后改变既有头像。
    func testRobohashUsesHashedSeedAndExplicitSet() async throws {
        let records = await RobohashClient(sets: [.robotHeads], now: { Self.fixedNow })
            .avatars(query: "Private Name", count: 1)
        let record = try XCTUnwrap(records.first)
        let components = try XCTUnwrap(URLComponents(url: record.imageURL, resolvingAgainstBaseURL: false))
        let parameters = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        XCTAssertEqual(record.source, .robohash)
        XCTAssertEqual(record.avatarType, .robot)
        XCTAssertTrue(record.id.hasPrefix("robohash:v2:set3:2026-08-05:"))
        XCTAssertEqual(record.imageURL.host, "robohash.org")
        XCTAssertEqual(record.imageURL.pathExtension, "png")
        XCTAssertEqual(parameters["size"], "256x256")
        XCTAssertEqual(parameters["set"], "set3")
        XCTAssertFalse(record.imageURL.absoluteString.localizedCaseInsensitiveContains("Private"))
        XCTAssertEqual(record.license.identifier, "cc-by-3.0")
        XCTAssertEqual(record.creator, "Julian Peter Arias")
        XCTAssertEqual(StableImageID.avatarGenerationDay(from: record.id), Self.generationDay)
    }

    /// 产品目录移除 human set5，其余五个固定图集保留各自归属。
    func testRobohashCatalogExcludesHumanAvatars() {
        XCTAssertEqual(RobohashSet.allCases.map(\.rawValue), ["set1", "set2", "set3", "set4", "set6"])
        XCTAssertEqual(RobohashSet.classicRobots.creator, "Zikri Kader")
        XCTAssertEqual(RobohashSet.classicRobots.license.identifier, "cc-by-3.0-or-4.0")
        XCTAssertEqual(RobohashSet.cats.license.identifier, "cc-by-4.0")
        XCTAssertEqual(RobohashSet.cosmicApes.license.identifier, "cc0")
        XCTAssertEqual(RobohashSet.classicRobots.avatarType, .robot)
        XCTAssertEqual(RobohashSet.robotHeads.avatarType, .robot)
        XCTAssertEqual(RobohashSet.monsters.avatarType, .monster)
        XCTAssertEqual(RobohashSet.cats.avatarType, .animal)
        XCTAssertEqual(RobohashSet.cosmicApes.avatarType, .animal)
    }

    /// Picrew 首屏与 score 续页必须组成同一个稳定目录，并按需各抓取一次。
    func testPicrewDiscoveryProducesPaginatedAvatarGridRecords() async throws {
        let fetcher = PicrewPageFetcher(
            initialData: try Self.picrewDiscoveryHTML(count: 40),
            continuationData: try Self.picrewDiscoveryJSON(startIndex: 40, count: 40)
        )
        let client = PicrewDiscoveryClient(fetch: { try await fetcher.fetch($0) })
        let first = await client.avatar(
            seedMaterial: "mirage-avatar-daily-v2|2026-08-05|cat|0",
            generationDay: Self.generationDay
        )
        let repeated = await client.avatar(
            seedMaterial: "mirage-avatar-daily-v2|2026-08-05|CAT|0",
            generationDay: Self.generationDay
        )
        let firstContinuation = await client.avatar(
            seedMaterial: "mirage-avatar-daily-v2|2026-08-05|cat|40",
            generationDay: Self.generationDay
        )
        let laterContinuation = await client.avatar(
            seedMaterial: "mirage-avatar-daily-v2|2026-08-05|cat|59",
            generationDay: Self.generationDay
        )
        let beyondPublicLimit = await client.avatar(
            seedMaterial: "mirage-avatar-daily-v2|2026-08-05|cat|400",
            generationDay: Self.generationDay
        )
        let record = try XCTUnwrap(first)
        let fetchCount = await fetcher.callCount
        let requestedURLs = await fetcher.requestedURLs

        XCTAssertEqual(first, repeated)
        XCTAssertEqual(firstContinuation?.sourcePageURL?.path, "/en/image_maker/2000040")
        XCTAssertEqual(laterContinuation?.sourcePageURL?.path, "/en/image_maker/2000059")
        XCTAssertNil(beyondPublicLimit)
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(requestedURLs.map(\.host), ["picrew.me", "api.picrew.me"])
        XCTAssertEqual(
            URLComponents(url: requestedURLs[1], resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "score" })?.value,
            "999961"
        )
        XCTAssertEqual(record.source, .picrew)
        XCTAssertEqual(record.avatarType, .anime)
        XCTAssertEqual(record.thumbnailURL.host, "cdn.picrew.me")
        XCTAssertEqual(record.sourcePageURL?.path, "/en/image_maker/2000000")
        XCTAssertEqual(record.license.identifier, "picrew-maker-specific")
        XCTAssertTrue(record.source.allowsPersistentLibraryStorage)
        XCTAssertNil(StableImageID.avatarSource(from: record.id))

        let catalog = AvatarCatalogClient(
            providers: [DiceBearClient(styles: [.micah], now: { Self.fixedNow }), client],
            now: { Self.fixedNow }
        )
        let records = await catalog.avatars(query: "cat", offset: 0, count: 20)
        XCTAssertEqual(records.count, 20)
        XCTAssertEqual(Set(records.map(\.id)).count, 20)
        XCTAssertTrue(records.contains { $0.source == .picrew })
    }

    func testPicrewThumbnailPolicyRejectsNonDiscoveryURLs() {
        XCTAssertTrue(PicrewDiscoveryMediaPolicy.isAllowedThumbnailURL(
            URL(string: "https://cdn.picrew.me/shareImg/thumb/202608/2000000_preview.jpg")!
        ))
        XCTAssertFalse(PicrewDiscoveryMediaPolicy.isAllowedThumbnailURL(
            URL(string: "https://api.picrew.me/player/api/discovery")!
        ))
        XCTAssertFalse(PicrewDiscoveryMediaPolicy.isAllowedThumbnailURL(
            URL(string: "https://cdn.picrew.me/app/image_maker/2000000/icon.png")!
        ))
    }

    /// 统一目录的供应商选择与数组顺序无关，并在确定性样本中覆盖三个来源。
    func testAvatarCatalogStablyMixesAllProviders() async {
        let providers: [any AvatarSourceGenerating] = [
            DiceBearClient(styles: [.micah], now: { Self.fixedNow }),
            GravatarClient(styles: [.monsterID], now: { Self.fixedNow }),
            RobohashClient(sets: [.classicRobots], now: { Self.fixedNow }),
        ]
        let forward = AvatarCatalogClient(providers: providers, now: { Self.fixedNow })
        let reversed = AvatarCatalogClient(providers: Array(providers.reversed()), now: { Self.fixedNow })

        var firstRecords: [RemoteImageRecord] = []
        var repeatedRecords: [RemoteImageRecord] = []
        for offset in stride(from: 0, to: 200, by: 20) {
            firstRecords += await forward.avatars(query: "cat", offset: offset, count: 20)
            repeatedRecords += await reversed.avatars(query: "CAT", offset: offset, count: 20)
        }

        XCTAssertEqual(firstRecords, repeatedRecords)
        XCTAssertEqual(firstRecords.count, 200)
        XCTAssertEqual(Set(firstRecords.map(\.id)).count, 200)
        XCTAssertEqual(Set(firstRecords.map(\.source)), [.diceBear, .gravatar, .robohash])
        XCTAssertEqual(
            Set(firstRecords.compactMap(\.avatarType)),
            [.cartoonCharacter, .monster, .robot]
        )
        XCTAssertTrue(firstRecords.allSatisfy { $0.source.isAvatarSource })
    }

    /// 单类型目录要在生成前缩小供应商集合；二次元应满页，AI 真人保持每页固定低频而非随机消失。
    func testAvatarCatalogPaginatesAnimeAndAIRealisticAtGenerationBoundary() async {
        let catalog = AvatarCatalogClient(
            providers: [
                AvatarTypeGenerator(type: .anime),
                AvatarTypeGenerator(type: .aiRealistic, eligibilityDivisor: 4),
            ],
            now: { Self.fixedNow }
        )

        let animePageOne = await catalog.avatars(
            query: "cat",
            offset: 0,
            count: 20,
            generationDay: Self.generationDay,
            allowedTypes: [.anime]
        )
        let animePageTwo = await catalog.avatars(
            query: "cat",
            offset: 20,
            count: 20,
            generationDay: Self.generationDay,
            allowedTypes: [.anime]
        )
        let aiPageOne = await catalog.avatars(
            query: "cat",
            offset: 0,
            count: 20,
            generationDay: Self.generationDay,
            allowedTypes: [.aiRealistic]
        )
        let aiPageTwo = await catalog.avatars(
            query: "cat",
            offset: 20,
            count: 20,
            generationDay: Self.generationDay,
            allowedTypes: [.aiRealistic]
        )

        XCTAssertEqual(animePageOne.count, 20)
        XCTAssertEqual(animePageTwo.count, 20)
        XCTAssertEqual(Set((animePageOne + animePageTwo).map(\.id)).count, 40)
        XCTAssertTrue((animePageOne + animePageTwo).allSatisfy { $0.avatarType == .anime })
        XCTAssertEqual(aiPageOne.count, 5)
        XCTAssertEqual(aiPageTwo.count, 5)
        XCTAssertEqual(Set((aiPageOne + aiPageTwo).map(\.id)).count, 10)
        XCTAssertTrue((aiPageOne + aiPageTwo).allSatisfy { $0.avatarType == .aiRealistic })
    }

    /// 当前来源都按统一 UTC 日期旋转，昨天的持久缓存不能冒充当天记录。
    func testAvatarGenerationDayParserAcceptsCurrentProvidersOnly() async {
        // 日期解析不应读取真实 App Group 或触发动态人像网络请求。
        let providers: [any AvatarSourceGenerating] = [
            DiceBearClient(styles: [.micah], now: { Self.fixedNow }),
            GravatarClient(styles: [.monsterID], now: { Self.fixedNow }),
            RobohashClient(sets: [.classicRobots], now: { Self.fixedNow }),
        ]
        let records = await AvatarCatalogClient(
            providers: providers,
            now: { Self.fixedNow }
        )
            .avatars(query: "cat", offset: 0, count: 20)
        XCTAssertEqual(records.count, 20)
        XCTAssertTrue(records.allSatisfy {
            StableImageID.avatarGenerationDay(from: $0.id) == Self.generationDay
                && StableImageID.avatarSource(from: $0.id) == $0.source
        })
        XCTAssertNil(
            StableImageID.avatarGenerationDay(
                from: "db:v11:micah:2026-08-05:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            )
        )
        XCTAssertNil(
            StableImageID.avatarSource(
                from: "robohash:v1:set1:2026-08-05:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            )
        )
        XCTAssertNil(
            StableImageID.avatarSource(
                from: "robohash:v2:set5:2026-08-05:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            )
        )
        XCTAssertNil(
            StableImageID.avatarSource(
                from: "gravatar:v2:retro:2026-08-05:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            )
        )
    }

    /// 动态端点只请求一次；后续预览和下载必须复用同一份标准化 PNG。
    func testThisPersonDoesNotExistFreezesFirstResponseInSharedStorage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageTPDNE-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storage = try AppGroupStorage(baseURL: directory)
        let fetcher = AvatarPayloadFetcher(
            payload: ThisPersonDoesNotExistPayload(
                data: try Self.jpegData(),
                mimeType: "image/jpeg"
            )
        )
        let endpoint = URL(string: "https://thispersondoesnotexist.com/random-person.jpeg")!
        let client = ThisPersonDoesNotExistClient(
            endpoint: endpoint,
            storage: storage,
            fetch: { _ in await fetcher.fetch() },
            now: { Self.fixedNow }
        )

        let first = await client.avatars(query: "person", count: 1)
        let repeated = await client.avatars(query: "PERSON", count: 1)
        let record = try XCTUnwrap(first.first)
        let reference = try XCTUnwrap(AvatarSnapshotReference(url: record.imageURL))
        let storedData = try await storage.readAvatarSnapshot(key: reference.key)
        let stored = try XCTUnwrap(storedData)
        let callCount = await fetcher.callCount

        XCTAssertEqual(first, repeated)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(record.source, .thisPersonDoesNotExist)
        XCTAssertEqual(record.avatarType, .aiRealistic)
        XCTAssertTrue(record.id.hasPrefix("tpdne:v1:ai:2026-08-05:"))
        XCTAssertEqual(record.imageURL.scheme, AvatarSnapshotReference.scheme)
        XCTAssertEqual(record.imageURL, record.thumbnailURL)
        XCTAssertEqual(record.mimeType, "image/png")
        XCTAssertEqual(record.width, 512)
        XCTAssertEqual(StableImageID.dataHash(stored), record.id.split(separator: ":").last.map(String.init))

        let catalog = AvatarCatalogClient(
            providers: [
                DiceBearClient(styles: [.micah], now: { Self.fixedNow }),
                client,
            ],
            now: { Self.fixedNow }
        )
        var catalogRecords: [RemoteImageRecord] = []
        for offset in stride(from: 0, to: 100, by: 20) {
            catalogRecords += await catalog.avatars(
                query: "catalog",
                offset: offset,
                count: 20
            )
        }
        XCTAssertEqual(catalogRecords.count, 100)
        XCTAssertEqual(Set(catalogRecords.map(\.id)).count, 100)
        XCTAssertEqual(
            Set(catalogRecords.map(\.source)),
            [.diceBear, .thisPersonDoesNotExist]
        )
    }

    private static func jpegData() throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func picrewDiscoveryHTML(count: Int) throws -> Data {
        var values: [Any] = ["picrew-discoveries", []]
        var references: [Int] = []
        for index in 0..<count {
            let objectIndex = values.count
            references.append(objectIndex)
            values.append(NSNull())

            let makerIndex = values.count
            values.append(String(2_000_000 + index))
            let pathIndex = values.count
            values.append("shareImg/thumb/202608/\(2_000_000 + index)_preview\(index).jpg")
            let canvasIndex = values.count
            values.append(index.isMultiple(of: 7) ? 100 : 1)
            let scoreIndex = values.count
            values.append(1_000_000 - index)
            values[objectIndex] = [
                "id": makerIndex,
                "url": pathIndex,
                "cs": canvasIndex,
                "score": scoreIndex,
            ]
        }
        values[1] = references

        var html = Data(#"<html><script id="it-astro-state" type="application/json+devalue">"#.utf8)
        html.append(try JSONSerialization.data(withJSONObject: values))
        html.append(Data("</script></html>".utf8))
        return html
    }

    private static func picrewDiscoveryJSON(startIndex: Int, count: Int) throws -> Data {
        let entries: [[String: Any]] = (startIndex..<(startIndex + count)).map { index in
            [
                "id": 2_000_000 + index,
                "url": "shareImg/thumb/202608/\(2_000_000 + index)_preview\(index).jpg",
                "cs": index.isMultiple(of: 7) ? 100 : 1,
                "score": 1_000_000 - index,
            ]
        }
        return try JSONSerialization.data(withJSONObject: entries)
    }

    private static func utcDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}

private struct AvatarTypeGenerator: AvatarSourceGenerating {
    let type: AvatarType
    let eligibilityDivisor: UInt64

    init(type: AvatarType, eligibilityDivisor: UInt64 = 1) {
        self.type = type
        self.eligibilityDivisor = eligibilityDivisor
    }

    var avatarCatalogIdentifier: String { "fixture-\(type.rawValue)" }
    var avatarCatalogEligibilityDivisor: UInt64 { eligibilityDivisor }
    var supportedAvatarTypes: Set<AvatarType> { [type] }

    func avatar(
        seedMaterial: String,
        generationDay _: AvatarGenerationDay
    ) async -> RemoteImageRecord? {
        guard let index = AvatarSeed.absoluteIndex(from: seedMaterial),
              let url = URL(string: "https://example.com/\(type.rawValue)/\(index).png") else {
            return nil
        }
        return RemoteImageRecord(
            id: "fixture-\(type.rawValue)-\(index)",
            title: type.displayName,
            source: .diceBear,
            avatarType: type,
            imageURL: url,
            thumbnailURL: url,
            license: .cc0,
            mimeType: "image/png"
        )
    }
}

private actor AvatarPayloadFetcher {
    private let payload: ThisPersonDoesNotExistPayload
    private(set) var callCount = 0

    init(payload: ThisPersonDoesNotExistPayload) {
        self.payload = payload
    }

    func fetch() -> ThisPersonDoesNotExistPayload {
        callCount += 1
        return payload
    }
}

private actor PicrewPageFetcher {
    private let initialData: Data
    private let continuationData: Data
    private(set) var callCount = 0
    private(set) var requestedURLs: [URL] = []

    init(initialData: Data, continuationData: Data) {
        self.initialData = initialData
        self.continuationData = continuationData
    }

    func fetch(_ url: URL) throws -> Data {
        callCount += 1
        requestedURLs.append(url)
        switch url.host {
        case "picrew.me": return initialData
        case "api.picrew.me": return continuationData
        default: throw URLError(.unsupportedURL)
        }
    }
}
