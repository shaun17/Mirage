import XCTest
@testable import MirageCore

final class QueryAndIdentifierTests: XCTestCase {
    /// 中文头像前缀应被移除，并保留清理后的查询文字。
    func testChineseAvatarPrefix() {
        XCTAssertEqual(SearchQueryParser.parse("  头像:  小猫  "), ParsedSearchQuery(text: "小猫", scope: .avatar))
    }

    /// 英文前缀不区分大小写，photo 仅选择照片来源。
    func testEnglishPhotoPrefixIsCaseInsensitive() {
        XCTAssertEqual(SearchQueryParser.parse("PHOTO: Ocean"), ParsedSearchQuery(text: "Ocean", scope: .photo))
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

    /// DiceBear 使用标准 SHA-256，确保跨设备、跨进程结果一致。
    func testDiceBearStableID() {
        XCTAssertEqual(
            StableImageID.diceBear(style: "lorelei", seedMaterial: "abc"),
            "db:v10:lorelei:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// DiceBear 地址固定为 10.x PNG，使用公共接口真实支持的256像素且不包含原始查询。
    func testDiceBearUsesHashedSeedAndRasterLimit() async throws {
        let records = await DiceBearClient(styles: [.pixelArt]).avatars(query: "Private Name", count: 2)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.id.hasPrefix("db:v10:pixel-art:") })
        XCTAssertTrue(records.allSatisfy { $0.imageURL.path == "/10.x/pixel-art/png" })
        XCTAssertTrue(records.allSatisfy { !$0.imageURL.absoluteString.localizedCaseInsensitiveContains("Private") })
        XCTAssertTrue(records.allSatisfy { $0.width == 256 && $0.height == 256 })
        XCTAssertTrue(records.allSatisfy { record in
            URLComponents(url: record.imageURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "size" })?.value == "256"
        })
    }

    /// Mirage 命名空间必须保持稳定，避免升级后同一查询产生另一组头像。
    func testDiceBearMirageNamespaceIsStable() async throws {
        let records = await DiceBearClient(styles: [.pixelArt]).avatars(query: "Private Name", count: 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(
            record.id,
            "db:v10:pixel-art:f9219cd959300e7a13b7702df1bb1e1b31a38720c8e4ef52d304d5542b5d38aa"
        )
    }

    /// 头像分页必须使用绝对偏移，保证前后两页不会生成相同记录。
    func testDiceBearPaginationUsesDistinctOffsets() async {
        let client = DiceBearClient(styles: [.pixelArt])
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

    /// 默认客户端按摘要稳定随机，并应在足够大的确定性样本中覆盖全部官方风格。
    func testDiceBearDefaultClientStablyUsesAllStyles() async {
        let client = DiceBearClient()
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
        XCTAssertEqual(observedStyles, Set(DiceBearStyle.allCases.map(\.rawValue)))
    }

    /// 调整候选目录顺序不能改变同一查询的稳定随机结果。
    func testDiceBearStyleSelectionDoesNotDependOnCatalogOrder() async {
        let styles: [DiceBearStyle] = [.adventurer, .icons, .pixelArt, .lorelei]
        let forward = await DiceBearClient(styles: styles).avatars(query: "cat", count: 20)
        let reversed = await DiceBearClient(styles: Array(styles.reversed())).avatars(query: "cat", count: 20)
        XCTAssertEqual(forward, reversed)
    }

    /// 非CC0风格必须携带真实许可证与作者，不能继续被统一标记为DiceBear CC0。
    func testDiceBearUsesStyleSpecificAttribution() async throws {
        let ccByRecords = await DiceBearClient(styles: [.adventurer]).avatars(query: "a", count: 1)
        let mitRecords = await DiceBearClient(styles: [.icons]).avatars(query: "a", count: 1)
        let freeUseRecords = await DiceBearClient(styles: [.avataaars]).avatars(query: "a", count: 1)
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
}
