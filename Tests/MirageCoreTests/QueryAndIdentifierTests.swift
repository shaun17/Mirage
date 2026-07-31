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

    /// DiceBear 地址固定为审查过的 10.x PNG 风格，且不包含原始查询。
    func testDiceBearUsesHashedSeedAndWhitelist() async throws {
        let records = await DiceBearClient(styles: [.pixelArt]).avatars(query: "Private Name", count: 2)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.id.hasPrefix("db:v10:pixel-art:") })
        XCTAssertTrue(records.allSatisfy { $0.imageURL.path == "/10.x/pixel-art/png" })
        XCTAssertTrue(records.allSatisfy { !$0.imageURL.absoluteString.localizedCaseInsensitiveContains("Private") })
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
}
