import FileProvider
import Foundation
import MirageCore
import UniformTypeIdentifiers
import XCTest

final class ProviderDiscoveryTreePlannerTests: XCTestCase {
    /// v3 目录与分页图片都能无损往返，远程 ID 中的冒号不会被误当成截断点。
    func testVersionThreeIdentifiersRoundTripColonRecordID() throws {
        let page = try XCTUnwrap(DiscoveryPageReference(page: 27))
        XCTAssertEqual(page.itemIdentifier.rawValue, "discover-page:v3:27")
        XCTAssertEqual(
            ProviderIdentifiers.discoveryPageReference(from: page.itemIdentifier),
            page
        )

        let original = RecordReference(recordID: "ov:alpha:beta:42", discoveryPage: page)
        XCTAssertEqual(
            original.itemIdentifier.rawValue,
            "discover-page-item:v3:27:ov:alpha:beta:42"
        )
        let decoded = try XCTUnwrap(
            ProviderIdentifiers.recordReference(from: original.itemIdentifier)
        )
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.view, .discover)
        XCTAssertEqual(decoded.discoveryPage, page)
        XCTAssertEqual(decoded.parentItemIdentifier, page.itemIdentifier)
    }

    /// 根推荐仍使用原有 discover occurrence，其他普通视图的父目录语义也不受分页改造影响。
    func testOrdinaryViewReferencesKeepExistingIdentityAndParents() {
        let expectations: [(ProviderView, NSFileProviderItemIdentifier)] = [
            (.discover, .rootContainer),
            (.avatar, ProviderIdentifiers.avatars),
            (.search, ProviderIdentifiers.searchBacking),
            (.recent, ProviderIdentifiers.recent),
            (.favorite, ProviderIdentifiers.favorites)
        ]

        for (view, parent) in expectations {
            let reference = RecordReference(recordID: "source:item:1", view: view)
            XCTAssertEqual(reference.itemIdentifier.rawValue, "\(view.rawValue):source:item:1")
            XCTAssertEqual(reference.parentItemIdentifier, parent)
            XCTAssertEqual(reference.view, view)
            XCTAssertNil(reference.avatarPage)
            XCTAssertNil(reference.discoveryPage)
            XCTAssertEqual(
                ProviderIdentifiers.recordReference(from: reference.itemIdentifier),
                reference
            )
        }
    }

    /// 头像续页 ID、父级和 scope 必须独立于推荐流，并严格拒绝非 canonical 页码。
    func testAvatarPageIdentifiersRoundTripAndUseIsolatedScopes() throws {
        let second = try XCTUnwrap(AvatarPageReference(page: 2))
        let third = try XCTUnwrap(AvatarPageReference(page: 3))
        XCTAssertEqual(second.itemIdentifier.rawValue, "avatar-page:v1:2")
        XCTAssertEqual(second.parentItemIdentifier, ProviderIdentifiers.avatars)
        XCTAssertEqual(third.parentItemIdentifier, second.itemIdentifier)
        XCTAssertEqual(ProviderIdentifiers.avatarPageReference(from: second.itemIdentifier), second)

        let original = RecordReference(recordID: "db:v10:style:hash", avatarPage: second)
        XCTAssertEqual(
            original.itemIdentifier.rawValue,
            "avatar-page-item:v1:2:db:v10:style:hash"
        )
        let decoded = try XCTUnwrap(
            ProviderIdentifiers.recordReference(from: original.itemIdentifier)
        )
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.view, .avatar)
        XCTAssertEqual(decoded.avatarPage, second)
        XCTAssertNil(decoded.discoveryPage)
        XCTAssertEqual(decoded.parentItemIdentifier, second.itemIdentifier)
        XCTAssertEqual(ProviderEnumerationScope.avatars.storageKey, "avatars:v2")
        XCTAssertEqual(
            ProviderEnumerationScope.avatarPage(second).storageKey,
            "avatars:v2:2"
        )

        let invalidDirectories = [
            "avatar-page:v0:2",
            "avatar-page:v1:1",
            "avatar-page:v1:02",
            "avatar-page:v1:-2",
            "avatar-page:v1:\(AvatarPageReference.maximumPage + 1)",
            "avatar-page:v1:999999999999999999999999999999999999",
            "avatar-page:v1:2:extra"
        ]
        for rawValue in invalidDirectories {
            XCTAssertNil(
                ProviderIdentifiers.avatarPageReference(
                    from: NSFileProviderItemIdentifier(rawValue)
                ),
                rawValue
            )
        }

        let invalidItems = [
            "avatar-page-item:v0:2:record",
            "avatar-page-item:v1:1:record",
            "avatar-page-item:v1:02:record",
            "avatar-page-item:v1:2:",
            "avatar-page-item:v1:999999999999999999999999:record"
        ]
        for rawValue in invalidItems {
            XCTAssertNil(
                ProviderIdentifiers.recordReference(
                    from: NSFileProviderItemIdentifier(rawValue)
                ),
                rawValue
            )
        }
    }

    /// 头像首页和递归页都固定 50 张，并在末尾发布唯一“加载更多”目录。
    func testAvatarTreePublishesRecursiveLoadMoreDirectories() throws {
        let first = ProviderAvatarBatch(
            page: 1,
            records: Self.records(prefix: "avatar-first", count: 50),
            hasMore: true
        )
        let firstItems = try ProviderAvatarTreePlanner.items(for: first)
        XCTAssertEqual(firstItems.count, 51)
        XCTAssertTrue(firstItems.dropLast().allSatisfy {
            $0.parentItemIdentifier == ProviderIdentifiers.avatars
                && $0.itemIdentifier.rawValue.hasPrefix("avatar:")
        })
        let secondDirectory = try XCTUnwrap(firstItems.last)
        XCTAssertEqual(secondDirectory.filename, "加载更多")
        XCTAssertEqual(secondDirectory.itemIdentifier.rawValue, "avatar-page:v1:2")
        XCTAssertEqual(secondDirectory.parentItemIdentifier, ProviderIdentifiers.avatars)

        let second = ProviderAvatarBatch(
            page: 2,
            records: Self.records(prefix: "avatar-second", count: 50),
            hasMore: true
        )
        let secondItems = try ProviderAvatarTreePlanner.items(for: second)
        XCTAssertEqual(secondItems.count, 51)
        XCTAssertTrue(secondItems.dropLast().allSatisfy {
            $0.parentItemIdentifier == secondDirectory.itemIdentifier
                && $0.itemIdentifier.rawValue.hasPrefix("avatar-page-item:v1:2:")
        })
        let thirdDirectory = try XCTUnwrap(secondItems.last)
        XCTAssertEqual(thirdDirectory.filename, ProviderAvatarTreePlanner.continuationFolderName)
        XCTAssertEqual(thirdDirectory.itemIdentifier.rawValue, "avatar-page:v1:3")
        XCTAssertEqual(thirdDirectory.parentItemIdentifier, secondDirectory.itemIdentifier)

        XCTAssertEqual(try ProviderAvatarTreePlanner.recordRange(for: 1), 0..<50)
        XCTAssertEqual(try ProviderAvatarTreePlanner.recordRange(for: 2), 50..<100)
        XCTAssertEqual(
            try ProviderAvatarTreePlanner.recordRange(for: AvatarPageReference.maximumPage),
            199_950..<200_000
        )
        XCTAssertThrowsError(try ProviderAvatarTreePlanner.recordRange(for: 0))
        XCTAssertThrowsError(try ProviderAvatarTreePlanner.recordRange(for: Int.max))
        XCTAssertThrowsError(
            try ProviderAvatarTreePlanner.items(
                for: ProviderAvatarBatch(
                    page: 1,
                    records: Self.records(prefix: "too-many", count: 51),
                    hasMore: false
                )
            )
        ) { error in
            XCTAssertEqual(error as? ProviderAvatarTreeError, .tooManyRecords(51))
        }
        XCTAssertThrowsError(
            try ProviderAvatarTreePlanner.continuationItem(
                after: ProviderAvatarBatch(
                    page: AvatarPageReference.maximumPage,
                    records: [],
                    hasMore: true
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderAvatarTreeError,
                .pageOverflow(AvatarPageReference.maximumPage)
            )
        }
    }

    /// 旧 schema、根页、非 canonical 数字、越界数字和缺失记录 ID 都不能进入公开树。
    func testMalformedAndOutOfRangeIdentifiersAreRejected() {
        let invalidDirectoryIDs = [
            "discover-page:v2:2",
            "discover-page:v3:1",
            "discover-page:v3:02",
            "discover-page:v3:-2",
            "discover-page:v3:\(DiscoveryPageReference.maximumPage + 1)",
            "discover-page:v3:999999999999999999999999999999999999",
            "discover-page:v3:2:extra"
        ]
        for rawValue in invalidDirectoryIDs {
            XCTAssertNil(
                ProviderIdentifiers.discoveryPageReference(
                    from: NSFileProviderItemIdentifier(rawValue)
                ),
                rawValue
            )
        }

        let invalidItemIDs = [
            "discover-page-item:v2:2:record",
            "discover-page-item:v3:1:record",
            "discover-page-item:v3:02:record",
            "discover-page-item:v3:2:",
            "discover-page-item:v3:999999999999999999999999999999:record"
        ]
        for rawValue in invalidItemIDs {
            XCTAssertNil(
                ProviderIdentifiers.recordReference(
                    from: NSFileProviderItemIdentifier(rawValue)
                ),
                rawValue
            )
        }
    }

    /// 根目录固定展示 40 张，唯一“更多图片”目录在返回数组末尾且指向第 2 批。
    func testRootBatchPublishesFortyImagesThenOneContinuationDirectory() throws {
        let fixed = [
            ProviderItem(
                directory: ProviderIdentifiers.recent,
                parent: .rootContainer,
                name: "最近使用"
            )
        ]
        let batch = ProviderDiscoveryBatch(
            page: 1,
            generation: 7,
            records: Self.records(count: 40),
            hasMore: true
        )

        let items = try ProviderDiscoveryTreePlanner.items(
            for: batch,
            fixedDirectories: fixed
        )
        XCTAssertEqual(items.filter { $0.contentType == .png }.count, 40)
        XCTAssertTrue(
            items.filter { $0.contentType == .png }
                .allSatisfy { $0.parentItemIdentifier == .rootContainer }
        )
        let continuation = try XCTUnwrap(items.last)
        XCTAssertEqual(continuation.filename, "更多图片")
        XCTAssertEqual(continuation.itemIdentifier.rawValue, "discover-page:v3:2")
        XCTAssertEqual(continuation.parentItemIdentifier, .rootContainer)
        XCTAssertEqual(continuation.discoveryGeneration, 7)
        XCTAssertTrue(
            items.filter { $0.contentType == .png }
                .allSatisfy { $0.discoveryGeneration == 7 }
        )
        XCTAssertEqual(
            items.filter { $0.itemIdentifier == continuation.itemIdentifier }.count,
            1
        )
    }

    /// 每个子目录也只投影自己的 40 张，图片挂在当前页，下一层目录挂在当前目录。
    func testRecursiveBatchUsesPageScopedOccurrencesAndAppendsNextDirectory() throws {
        let batch = ProviderDiscoveryBatch(
            page: 2,
            generation: 11,
            records: Self.records(prefix: "second", count: 40),
            hasMore: true
        )

        let items = try ProviderDiscoveryTreePlanner.items(for: batch)
        XCTAssertEqual(items.count, 41)
        let images = items.filter { $0.contentType == .png }
        XCTAssertEqual(images.count, 40)
        XCTAssertTrue(images.allSatisfy {
            $0.parentItemIdentifier.rawValue == "discover-page:v3:2"
                && $0.itemIdentifier.rawValue.hasPrefix("discover-page-item:v3:2:")
        })
        let continuation = try XCTUnwrap(items.last)
        XCTAssertEqual(continuation.filename, ProviderDiscoveryTreePlanner.continuationFolderName)
        XCTAssertEqual(continuation.itemIdentifier.rawValue, "discover-page:v3:3")
        XCTAssertEqual(continuation.parentItemIdentifier.rawValue, "discover-page:v3:2")
        XCTAssertEqual(continuation.discoveryGeneration, 11)
        XCTAssertTrue(images.allSatisfy { $0.discoveryGeneration == 11 })
    }

    /// 末批可以少于 40 张；hasMore 为 false 时不制造空的下一层目录。
    func testTerminalPartialBatchHasNoContinuationDirectory() throws {
        let batch = ProviderDiscoveryBatch(
            page: DiscoveryPageReference.maximumPage,
            generation: 19,
            records: Self.records(prefix: "last", count: 7),
            hasMore: false
        )

        let items = try ProviderDiscoveryTreePlanner.items(for: batch)
        XCTAssertEqual(items.count, 7)
        XCTAssertTrue(items.allSatisfy { $0.contentType == .png })
        XCTAssertNil(try ProviderDiscoveryTreePlanner.continuationItem(after: batch))
    }

    /// 目录 ID 不随 generation 改变，但元数据版本会改变，Finder 因此更新同一个占位符。
    func testContinuationIdentityIsStableAcrossGenerations() throws {
        let first = ProviderDiscoveryBatch(page: 1, generation: 41, records: [], hasMore: true)
        let refreshed = ProviderDiscoveryBatch(page: 1, generation: 42, records: [], hasMore: true)

        let firstItem = try XCTUnwrap(
            ProviderDiscoveryTreePlanner.continuationItem(after: first)
        )
        let refreshedItem = try XCTUnwrap(
            ProviderDiscoveryTreePlanner.continuationItem(after: refreshed)
        )
        XCTAssertEqual(firstItem.itemIdentifier, refreshedItem.itemIdentifier)
        XCTAssertEqual(
            firstItem.itemVersion.contentVersion,
            refreshedItem.itemVersion.contentVersion
        )
        XCTAssertNotEqual(
            firstItem.itemVersion.metadataVersion,
            refreshedItem.itemVersion.metadataVersion
        )
    }

    /// 40 张批次仍覆盖底层 20 万条推荐容量，边界外与超长批次必须明确失败。
    func testRangeAndBatchValidationRejectOverflowAndInvalidSizes() throws {
        XCTAssertEqual(DiscoveryPageReference.maximumPage, 5_000)
        XCTAssertEqual(
            try ProviderDiscoveryTreePlanner.recordRange(for: 1),
            0..<40
        )
        XCTAssertEqual(
            try ProviderDiscoveryTreePlanner.recordRange(
                for: DiscoveryPageReference.maximumPage
            ),
            199_960..<200_000
        )
        XCTAssertThrowsError(try ProviderDiscoveryTreePlanner.recordRange(for: 0))
        XCTAssertThrowsError(try ProviderDiscoveryTreePlanner.recordRange(for: Int.max))

        let oversized = ProviderDiscoveryBatch(
            page: 1,
            generation: 1,
            records: Self.records(count: 41),
            hasMore: false
        )
        XCTAssertThrowsError(try ProviderDiscoveryTreePlanner.items(for: oversized)) { error in
            XCTAssertEqual(error as? ProviderDiscoveryTreeError, .tooManyRecords(41))
        }

        let impossibleContinuation = ProviderDiscoveryBatch(
            page: DiscoveryPageReference.maximumPage,
            generation: 1,
            records: [],
            hasMore: true
        )
        XCTAssertThrowsError(
            try ProviderDiscoveryTreePlanner.continuationItem(after: impossibleContinuation)
        ) { error in
            XCTAssertEqual(
                error as? ProviderDiscoveryTreeError,
                .pageOverflow(DiscoveryPageReference.maximumPage)
            )
        }
    }

    private static func records(
        prefix: String = "record",
        count: Int
    ) -> [RemoteImageRecord] {
        (0..<count).map { index in
            let url = URL(string: "https://example.com/\(prefix)-\(index).png")!
            return RemoteImageRecord(
                id: "\(prefix):namespace:\(index)",
                title: "Image \(index)",
                source: .openverse,
                imageURL: url,
                thumbnailURL: url,
                license: .cc0
            )
        }
    }
}
