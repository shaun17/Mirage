import Foundation
import XCTest
@testable import MirageCore

final class ImageSearchServiceTests: XCTestCase {
    /// 三种筛选都应按20条分页，并把正确页码与页大小传给对应数据源。
    func testAllSearchScopesPaginateWithoutRepeatingAvatars() async throws {
        let openverse = OpenverseSpy()
        let service = ImageSearchService(
            openverse: openverse,
            diceBear: DiceBearClient(styles: [.pixelArt])
        )

        let automaticFirst = try await service.search("cat", page: 1, pageSize: 20)
        let automaticSecond = try await service.search("cat", page: 2, pageSize: 20)
        let photos = try await service.search("图片:cat", page: 2, pageSize: 20)
        let avatarsFirst = try await service.search("头像:cat", page: 1, pageSize: 20)
        let avatarsSecond = try await service.search("头像:cat", page: 2, pageSize: 20)

        XCTAssertEqual(automaticFirst.records.count, 20)
        XCTAssertEqual(automaticFirst.records.prefix(16).map(\.source), Array(repeating: .openverse, count: 16))
        XCTAssertEqual(automaticFirst.records.suffix(4).map(\.source), Array(repeating: .diceBear, count: 4))
        XCTAssertEqual(automaticSecond.nextPage, 3)
        XCTAssertEqual(photos.records.count, 20)
        XCTAssertEqual(photos.nextPage, 3)
        XCTAssertTrue(Set(avatarsFirst.records.map(\.id)).isDisjoint(with: Set(avatarsSecond.records.map(\.id))))

        let calls = await openverse.recordedCalls()
        XCTAssertEqual(calls, [
            OpenverseCall(page: 1, pageSize: 16),
            OpenverseCall(page: 2, pageSize: 16),
            OpenverseCall(page: 2, pageSize: 20)
        ])
    }

    /// 自动模式的小页应优先保留照片，不能让固定头像配额挤掉唯一结果位。
    func testAutomaticSearchWithOneItemPageKeepsPhotoPriority() async throws {
        let openverse = OpenverseSpy()
        let service = ImageSearchService(
            openverse: openverse,
            diceBear: DiceBearClient(styles: [.pixelArt]),
            automaticAvatarCount: 4
        )
        let first = try await service.search("cat", page: 1, pageSize: 1)
        let second = try await service.search("cat", page: 2, pageSize: 1)
        XCTAssertEqual(first.records.map(\.source), [.openverse])
        XCTAssertEqual(second.records.map(\.source), [.openverse])
        XCTAssertNotEqual(first.records.first?.id, second.records.first?.id)
        let calls = await openverse.recordedCalls()
        XCTAssertEqual(calls, [
            OpenverseCall(page: 1, pageSize: 1),
            OpenverseCall(page: 2, pageSize: 1)
        ])
    }

    /// File Provider 页令牌必须完整恢复页码、固定页大小和已交付数量。
    func testSearchPaginationCursorRoundTripAndValidation() throws {
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let cursor = try SearchPaginationCursor(
            page: 3,
            pageSize: 20,
            delivered: 40,
            query: "cat",
            issuedAt: issuedAt
        )
        XCTAssertEqual(try SearchPaginationCursor.decode(cursor.encoded()), cursor)
        XCTAssertNoThrow(try cursor.validate(for: "CAT", now: issuedAt.addingTimeInterval(599)))
        XCTAssertThrowsError(try cursor.validate(for: "dog", now: issuedAt))
        XCTAssertThrowsError(try cursor.validate(for: "cat", now: issuedAt.addingTimeInterval(601)))
        XCTAssertThrowsError(try SearchPaginationCursor(page: 0, pageSize: 20, delivered: 0, query: "cat"))
        XCTAssertThrowsError(try SearchPaginationCursor(page: 1, pageSize: 21, delivered: 0, query: "cat"))
        XCTAssertThrowsError(try SearchPaginationCursor(page: .max, pageSize: 20, delivered: 0, query: "cat"))
        XCTAssertThrowsError(try SearchPaginationCursor(page: 1, pageSize: 20, delivered: .max, query: "cat"))
        XCTAssertThrowsError(try cursor.deliveredCount(adding: .max))
        XCTAssertThrowsError(try cursor.advanced(to: 3, delivered: 40))
    }

    /// 极端页码必须在任何乘法前失败，不能让头像偏移计算造成运行时崩溃。
    func testSearchRejectsOverflowingPageAndStopsAtMaximumAvatarPage() async throws {
        let service = ImageSearchService(
            openverse: OpenverseSpy(),
            diceBear: DiceBearClient(styles: [.pixelArt])
        )
        do {
            _ = try await service.search("头像:cat", page: .max, pageSize: 20)
            XCTFail("极端页码应被拒绝")
        } catch {
            XCTAssertEqual(error as? SearchPaginationCursorError, .invalidValues)
        }
        let lastPage = try await service.search(
            "头像:cat",
            page: SearchPaginationCursor.maximumPage,
            pageSize: 20
        )
        XCTAssertEqual(lastPage.records.count, 20)
        XCTAssertNil(lastPage.nextPage)
        let overflowedClientPage = await DiceBearClient().avatars(query: "cat", offset: .max, count: 20)
        XCTAssertTrue(overflowedClientPage.isEmpty)
    }

    /// 数据源的停滞或倒退页码不能进入下一次滚动请求。
    func testSearchDropsNonForwardContinuation() async throws {
        let service = ImageSearchService(
            openverse: NonForwardOpenverse(),
            diceBear: DiceBearClient(styles: [.pixelArt])
        )
        let page = try await service.search("图片:cat", page: 2, pageSize: 20)
        XCTAssertNil(page.nextPage)
    }
}

private struct NonForwardOpenverse: OpenverseSearching {
    /// 模拟服务端错误地把当前页再次声明成下一页。
    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        ImageSearchPage(records: [], nextPage: page)
    }
}

private struct OpenverseCall: Equatable, Sendable {
    let page: Int
    let pageSize: Int
}

private actor OpenverseSpy: OpenverseSearching {
    private var calls: [OpenverseCall] = []

    /// 记录分页参数并返回数量完全匹配的稳定测试图片。
    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        calls.append(OpenverseCall(page: page, pageSize: pageSize))
        let records = (0..<pageSize).map { index in
            let url = URL(string: "https://example.com/\(page)-\(index).png")!
            return RemoteImageRecord(
                id: "photo-\(page)-\(index)",
                title: "Photo \(index)",
                source: .openverse,
                imageURL: url,
                thumbnailURL: url,
                license: .cc0
            )
        }
        return ImageSearchPage(records: records, nextPage: page + 1)
    }

    /// 返回调用快照，避免测试直接跨 actor 读取可变状态。
    func recordedCalls() -> [OpenverseCall] {
        calls
    }
}
