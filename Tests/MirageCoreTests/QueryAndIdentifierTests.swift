import XCTest
@testable import MirageCore

final class QueryAndIdentifierTests: XCTestCase {
    private static let fixedNow = utcDate(year: 2026, month: 8, day: 2, hour: 12)

    /// 中文头像前缀应被移除，并保留清理后的查询文字。
    func testChineseAvatarPrefix() {
        XCTAssertEqual(SearchQueryParser.parse("  头像:  小猫  "), ParsedSearchQuery(text: "小猫", scope: .avatar))
    }

    /// 英文前缀不区分大小写，photo 仅选择照片来源。
    func testEnglishPhotoPrefixIsCaseInsensitive() {
        XCTAssertEqual(SearchQueryParser.parse("PHOTO: Ocean"), ParsedSearchQuery(text: "Ocean", scope: .photo))
    }

    /// GIPHY 不使用可输入的字符串前缀，避免普通搜索误进隔离目录。
    func testEmojiLikePrefixesRemainOrdinarySearchText() {
        XCTAssertEqual(
            SearchQueryParser.parse("EMOJI: catalog"),
            ParsedSearchQuery(text: "EMOJI: catalog", scope: .automatic)
        )
        XCTAssertEqual(
            SearchQueryParser.parse(" 表情: giphy "),
            ParsedSearchQuery(text: "表情: giphy", scope: .automatic)
        )
    }

    /// 无前缀查询默认聚合两个来源。
    func testAutomaticQuery() {
        XCTAssertEqual(SearchQueryParser.parse("  flower "), ParsedSearchQuery(text: "flower", scope: .automatic))
    }

    /// Openverse UUID 大小写变化不能改变最终 ID。
    func testOpenverseStableID() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "A0B1C2D3-E4F5-4678-9012-3456789ABCDE"))
        XCTAssertEqual(StableImageID.openverse(uuid: uuid), "ov:a0b1c2d3-e4f5-4678-9012-3456789abcde")
    }

    func testMuseumAndNASAStableIDs() {
        XCTAssertEqual(StableImageID.metMuseum(objectID: 42), "met:42")
        XCTAssertEqual(
            StableImageID.nasa(nasaID: "PIA 123/ABC"),
            "nasa:e14bc80af1414cbd952fbf06368dc2f1cf7193512f1d8e353c7c2c5718fc8db9"
        )
    }

    /// GIPHY 原始 ID 只参与摘要，应用持久标识不会直接暴露上游字符。
    func testGiphyStableID() {
        XCTAssertEqual(
            StableImageID.giphy(id: "abc"),
            "giphy:emoji:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// DiceBear 使用标准 SHA-256，确保跨设备、跨进程结果一致。
    func testDiceBearStableID() {
        XCTAssertEqual(
            StableImageID.diceBear(style: "lorelei", seedMaterial: "abc"),
            "db:v10:lorelei:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// DiceBear 地址固定为 10.x PNG，使用公共接口真实支持的256像素且不包含原始查询。
    func testDiceBearUsesHashedSeedAndRasterLimit() async throws {
        let records = await DiceBearClient(styles: [.pixelArt], now: { Self.fixedNow })
            .avatars(query: "Private Name", count: 2)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.id.hasPrefix("db:v13:pixel-art:") })
        XCTAssertTrue(records.allSatisfy { $0.imageURL.path == "/10.x/pixel-art/png" })
        XCTAssertTrue(records.allSatisfy { !$0.imageURL.absoluteString.localizedCaseInsensitiveContains("Private") })
        XCTAssertTrue(records.allSatisfy { $0.width == 256 && $0.height == 256 })
        XCTAssertTrue(records.allSatisfy { record in
            URLComponents(url: record.imageURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "size" })?.value == "256"
        })
    }

    /// Mirage 每日命名空间必须保持稳定，避免同一 UTC 日内结果漂移。
    func testDiceBearMirageNamespaceIsStable() async throws {
        let records = await DiceBearClient(styles: [.pixelArt], now: { Self.fixedNow })
            .avatars(query: "Private Name", count: 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(
            record.id,
            "db:v13:pixel-art:2026-08-02:6c3ac86e5af04d9503e81d9448f126ae66f1b3cd3a732cde427eb7af2b32f285"
        )
        XCTAssertEqual(StableImageID.diceBearGenerationDay(from: record.id)?.identifier, "2026-08-02")
        XCTAssertNil(
            StableImageID.diceBearGenerationDay(
                from: "db:v10:pixel-art:5f195348707c9fa3e4de12357db16055570e8d26013f53a5a99e4dbb9a044e23"
            )
        )
        XCTAssertNil(
            StableImageID.diceBearGenerationDay(
                from: "db:v11:pixel-art:2026-08-02:5f195348707c9fa3e4de12357db16055570e8d26013f53a5a99e4dbb9a044e23"
            )
        )
        XCTAssertNil(
            StableImageID.diceBearGenerationDay(
                from: "db:v12:pixel-art:2026-08-02:5f195348707c9fa3e4de12357db16055570e8d26013f53a5a99e4dbb9a044e23"
            )
        )
    }

    /// 生成日始终按 UTC 公历输出 canonical yyyy-MM-dd，不受本机时区影响。
    func testDiceBearGenerationDayUsesUTCGregorianIdentifier() {
        let beforeMidnight = Self.utcDate(year: 2026, month: 8, day: 2, hour: 23, minute: 59)
        let afterMidnight = Self.utcDate(year: 2026, month: 8, day: 3, hour: 0)

        XCTAssertEqual(DiceBearGenerationDay(date: beforeMidnight).identifier, "2026-08-02")
        XCTAssertEqual(DiceBearGenerationDay(date: afterMidnight).identifier, "2026-08-03")
    }

    /// 同一 UTC 日内不同时刻必须生成完全相同的头像记录。
    func testDiceBearIsStableWithinSameUTCDay() async {
        let morning = Self.utcDate(year: 2026, month: 8, day: 2, hour: 0, minute: 1)
        let evening = Self.utcDate(year: 2026, month: 8, day: 2, hour: 23, minute: 59)
        let first = await DiceBearClient(now: { morning }).avatars(query: " cat ", count: 20)
        let later = await DiceBearClient(now: { evening }).avatars(query: "CAT", count: 20)

        XCTAssertEqual(first, later)
    }

    /// 跨过 UTC 午夜后 seed、ID 与 URL 都必须切换，两日记录不得重叠。
    func testDiceBearChangesAcrossUTCMidnight() async {
        let beforeMidnight = Self.utcDate(year: 2026, month: 8, day: 2, hour: 23, minute: 59)
        let afterMidnight = Self.utcDate(year: 2026, month: 8, day: 3, hour: 0)
        let firstDay = await DiceBearClient(now: { beforeMidnight }).avatars(query: "cat", count: 20)
        let secondDay = await DiceBearClient(now: { afterMidnight }).avatars(query: "cat", count: 20)

        XCTAssertTrue(Set(firstDay.map(\.id)).isDisjoint(with: Set(secondDay.map(\.id))))
        XCTAssertTrue(Set(firstDay.map(\.imageURL)).isDisjoint(with: Set(secondDay.map(\.imageURL))))
    }

    /// 头像分页必须使用绝对偏移，保证前后两页不会生成相同记录。
    func testDiceBearPaginationUsesDistinctOffsets() async {
        let client = DiceBearClient(styles: [.pixelArt], now: { Self.fixedNow })
        let firstPage = await client.avatars(query: "cat", offset: 0, count: 20)
        let secondPage = await client.avatars(query: "cat", offset: 20, count: 20)
        XCTAssertEqual(firstPage.count, 20)
        XCTAssertEqual(secondPage.count, 20)
        XCTAssertTrue(Set(firstPage.map(\.id)).isDisjoint(with: Set(secondPage.map(\.id))))
    }

    /// 本地目录必须覆盖 DiceBear 10.x 公共实例当前提供的全部37种官方风格。
    func testDiceBearCatalogContainsEveryOfficialStyle() {
        let expected: Set<String> = [
            "adventurer", "adventurer-neutral", "avataaars", "avataaars-neutral",
            "big-ears", "big-ears-neutral", "big-smile", "bottts", "bottts-neutral",
            "croodles", "croodles-neutral", "disco", "dylan", "fun-emoji", "glass",
            "glyphs", "icons", "identicon", "initial-face", "initials", "lorelei",
            "lorelei-neutral", "micah", "miniavs", "notionists", "notionists-neutral",
            "open-peeps", "personas", "pixel-art", "pixel-art-neutral", "rings",
            "shape-grid", "shapes", "stripes", "thumbs", "toon-head", "triangles"
        ]
        XCTAssertEqual(Set(DiceBearStyle.allCases.map(\.rawValue)), expected)
        XCTAssertEqual(DiceBearStyle.allCases.count, 37)
    }

    /// Mirage 生产目录只允许用户选定的五种人物头像风格。
    func testDiceBearMirageCatalogContainsOnlySelectedStyles() {
        XCTAssertEqual(
            DiceBearStyle.mirageCatalog.map(\.rawValue),
            ["notionists-neutral", "lorelei", "croodles", "adventurer", "micah"]
        )
    }

    /// 默认客户端按摘要稳定随机，并应在足够大的确定性样本中覆盖 Mirage 精简目录。
    func testDiceBearDefaultClientStablyUsesOnlyMirageCatalogStyles() async {
        let client = DiceBearClient(now: { Self.fixedNow })
        let first = await client.avatars(query: " cat ", offset: 0, count: 20)
        let repeated = await client.avatars(query: "CAT", offset: 0, count: 20)
        XCTAssertEqual(first, repeated)

        var observedStyles = Set<String>()
        for offset in stride(from: 0, to: 2_000, by: 20) {
            let records = await client.avatars(query: "cat", offset: offset, count: 20)
            observedStyles.formUnion(records.map {
                $0.imageURL.deletingLastPathComponent().lastPathComponent
            })
        }
        XCTAssertEqual(observedStyles, Set(DiceBearStyle.mirageCatalog.map(\.rawValue)))
    }

    /// 调整候选目录顺序不能改变同一查询的稳定随机结果。
    func testDiceBearStyleSelectionDoesNotDependOnCatalogOrder() async {
        let styles: [DiceBearStyle] = [.adventurer, .icons, .pixelArt, .lorelei]
        let forward = await DiceBearClient(styles: styles, now: { Self.fixedNow })
            .avatars(query: "cat", count: 20)
        let reversed = await DiceBearClient(styles: Array(styles.reversed()), now: { Self.fixedNow })
            .avatars(query: "cat", count: 20)
        XCTAssertEqual(forward, reversed)
    }

    /// 非CC0风格必须携带真实许可证与作者，不能继续被统一标记为DiceBear CC0。
    func testDiceBearUsesStyleSpecificAttribution() async throws {
        let ccByRecords = await DiceBearClient(styles: [.adventurer], now: { Self.fixedNow })
            .avatars(query: "a", count: 1)
        let mitRecords = await DiceBearClient(styles: [.icons], now: { Self.fixedNow })
            .avatars(query: "a", count: 1)
        let freeUseRecords = await DiceBearClient(styles: [.avataaars], now: { Self.fixedNow })
            .avatars(query: "a", count: 1)
        let ccBy = try XCTUnwrap(ccByRecords.first)
        let mit = try XCTUnwrap(mitRecords.first)
        let freeUse = try XCTUnwrap(freeUseRecords.first)

        XCTAssertEqual(ccBy.license.identifier, "cc-by-4.0")
        XCTAssertEqual(ccBy.creator, "Lisa Wischofsky")
        XCTAssertEqual(mit.license.identifier, "mit")
        XCTAssertEqual(mit.creator, "The Bootstrap Authors")
        XCTAssertEqual(freeUse.license.identifier, "avataaars-free-use")
        XCTAssertEqual(freeUse.creator, "Pablo Stanley")
        XCTAssertEqual(freeUse.license.url?.host, "www.dicebear.com")
    }

    /// Finder 域必须由 App 构建号生成，防止新构建继续复用旧目录副本。
    func testFileProviderDomainFollowsAppBuildVersion() {
        XCTAssertEqual(
            MirageSystemIntegration.fileProviderDomainIdentifier(buildVersion: "16"),
            "mirage-default-v16"
        )
        XCTAssertEqual(
            MirageSystemIntegration.fileProviderDomainIdentifier(buildVersion: " 16.2 "),
            "mirage-default-v16.2"
        )
        XCTAssertNil(MirageSystemIntegration.fileProviderDomainIdentifier(buildVersion: nil))
        XCTAssertNil(MirageSystemIntegration.fileProviderDomainIdentifier(buildVersion: "16 beta"))
        XCTAssertNil(MirageSystemIntegration.fileProviderDomainIdentifier(buildVersion: "16..2"))
        XCTAssertNil(MirageSystemIntegration.fileProviderDomainIdentifier(buildVersion: "１６"))
        XCTAssertEqual(
            MirageSystemIntegration.synchronizedFileProviderDomainIdentifier(
                appBuildVersion: "16",
                fileProviderBuildVersion: "16"
            ),
            "mirage-default-v16"
        )
        XCTAssertNil(
            MirageSystemIntegration.synchronizedFileProviderDomainIdentifier(
                appBuildVersion: "16",
                fileProviderBuildVersion: "17"
            )
        )
    }

    /// 迁移范围不能只列举历史版本；升级和回退都要识别所有 Mirage 域。
    func testFileProviderManagedDomainRecognitionCoversUpgradeAndRollback() {
        XCTAssertTrue(MirageSystemIntegration.isManagedFileProviderDomainIdentifier("mirage-default"))
        XCTAssertTrue(MirageSystemIntegration.isManagedFileProviderDomainIdentifier("mirage-default-v12"))
        XCTAssertTrue(MirageSystemIntegration.isManagedFileProviderDomainIdentifier("mirage-default-v99"))
        XCTAssertFalse(MirageSystemIntegration.isManagedFileProviderDomainIdentifier("another-provider-v16"))
    }

    private static func utcDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}
