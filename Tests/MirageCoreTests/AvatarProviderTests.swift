import XCTest
@testable import MirageCore

final class AvatarProviderTests: XCTestCase {
    private static let fixedNow = utcDate(year: 2026, month: 8, day: 5, hour: 12)
    private static let generationDay = AvatarGenerationDay(date: fixedNow)

    /// Gravatar 只请求强制默认头像，不能因摘要碰撞展示真实用户内容。
    func testGravatarUsesForcedGeneratedDefaultWithoutRawQuery() async throws {
        let records = await GravatarClient(styles: [.retro], now: { Self.fixedNow })
            .avatars(query: "Private Name", count: 1)
        let record = try XCTUnwrap(records.first)
        let components = try XCTUnwrap(URLComponents(url: record.imageURL, resolvingAgainstBaseURL: false))
        let parameters = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        XCTAssertEqual(record.source, .gravatar)
        XCTAssertTrue(record.id.hasPrefix("gravatar:v1:retro:2026-08-05:"))
        XCTAssertEqual(record.imageURL.host, "gravatar.com")
        XCTAssertEqual(record.imageURL.lastPathComponent.count, 64)
        XCTAssertEqual(parameters["s"], "256")
        XCTAssertEqual(parameters["d"], "retro")
        XCTAssertEqual(parameters["f"], "y")
        XCTAssertEqual(parameters["r"], "g")
        XCTAssertFalse(record.imageURL.absoluteString.localizedCaseInsensitiveContains("Private"))
        XCTAssertEqual(record.license.identifier, "gravatar-usage")
        XCTAssertEqual(StableImageID.avatarGenerationDay(from: record.id), Self.generationDay)
    }

    /// 只保留会随摘要生成内容的四种 Gravatar 默认风格。
    func testGravatarCatalogContainsGeneratedAvatarStylesOnly() {
        XCTAssertEqual(
            GravatarStyle.allCases.map(\.rawValue),
            ["identicon", "monsterid", "wavatar", "retro"]
        )
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
        XCTAssertTrue(record.id.hasPrefix("robohash:v1:set3:2026-08-05:"))
        XCTAssertEqual(record.imageURL.host, "robohash.org")
        XCTAssertEqual(record.imageURL.pathExtension, "png")
        XCTAssertEqual(parameters["size"], "256x256")
        XCTAssertEqual(parameters["set"], "set3")
        XCTAssertFalse(record.imageURL.absoluteString.localizedCaseInsensitiveContains("Private"))
        XCTAssertEqual(record.license.identifier, "cc-by-3.0")
        XCTAssertEqual(record.creator, "Julian Peter Arias")
        XCTAssertEqual(StableImageID.avatarGenerationDay(from: record.id), Self.generationDay)
    }

    /// 官方六个固定图集都携带各自的作者和作品许可证。
    func testRobohashCatalogContainsAllLicensedSets() {
        XCTAssertEqual(RobohashSet.allCases.map(\.rawValue), ["set1", "set2", "set3", "set4", "set5", "set6"])
        XCTAssertEqual(RobohashSet.classicRobots.creator, "Zikri Kader")
        XCTAssertEqual(RobohashSet.classicRobots.license.identifier, "cc-by-3.0-or-4.0")
        XCTAssertEqual(RobohashSet.cats.license.identifier, "cc-by-4.0")
        XCTAssertEqual(RobohashSet.humanAvatars.license.identifier, "avataaars-free-use")
        XCTAssertEqual(RobohashSet.cosmicApes.license.identifier, "cc0")
    }

    /// 统一目录的供应商选择与数组顺序无关，并在确定性样本中覆盖三个来源。
    func testAvatarCatalogStablyMixesAllProviders() async {
        let providers: [any AvatarSourceGenerating] = [
            DiceBearClient(styles: [.micah], now: { Self.fixedNow }),
            GravatarClient(styles: [.retro], now: { Self.fixedNow }),
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
        XCTAssertTrue(firstRecords.allSatisfy { $0.source.isAvatarSource })
    }

    /// 三种来源都按统一 UTC 日期旋转，昨天的持久缓存不能冒充当天记录。
    func testAvatarGenerationDayParserAcceptsCurrentProvidersOnly() async {
        let records = await AvatarCatalogClient(now: { Self.fixedNow })
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
                from: "robohash:v2:set1:2026-08-05:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            )
        )
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
