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

    /// GIF 目录只调用隔离的 GIPHY 混合来源，并保留其不透明复合游标。
    func testGiphyCatalogUsesOnlyGiphyAndAllowsFortyItems() async throws {
        let giphy = GiphyEmojiSpy()
        let service = ImageSearchService(
            photos: BatchForwardingPhotoSearcher(),
            giphy: giphy,
            diceBear: DiceBearClient(styles: [.pixelArt]),
            maximumPageSize: 40
        )

        let first = try await service.giphyCatalog(cursor: nil, pageSize: 40)
        let second = try await service.giphyCatalog(cursor: first.nextCursor, pageSize: 40)

        XCTAssertEqual(first.records.map(\.source), [.giphy])
        XCTAssertEqual(first.nextCursor?.page, 2)
        XCTAssertEqual(first.nextCursor?.giphyCursor, PhotoSourceCursor(rawValue: "40"))
        XCTAssertNil(first.nextCursor?.photoCursor)
        XCTAssertEqual(second.records.map(\.source), [.giphy])
        XCTAssertNil(second.nextCursor)
        let calls = await giphy.recordedCalls()
        XCTAssertEqual(calls, [
            GiphyEmojiCall(query: "", cursor: nil, pageSize: 40),
            GiphyEmojiCall(query: "", cursor: "40", pageSize: 40)
        ])
    }

    /// 未装配 GIPHY 的 Finder/推荐服务必须明确拒绝 GIF 目录。
    func testGiphyCatalogIsUnavailableWithoutAppOnlyGiphySource() async throws {
        let service = ImageSearchService(openverse: OpenverseSpy())
        do {
            _ = try await service.giphyCatalog(cursor: nil)
            XCTFail("未装配 GIPHY 时不应返回 GIF 内容")
        } catch let PhotoSearchError.allSourcesFailed(issues) {
            XCTAssertEqual(issues.map(\.sourceID), [.giphy])
            XCTAssertEqual(issues.map(\.kind), [.unavailable])
        }
    }

    func testGiphyCatalogRejectsFirstPageCursorAndMissingContinuationCursor() async {
        let service = ImageSearchService(
            photos: BatchForwardingPhotoSearcher(),
            giphy: GiphyEmojiSpy()
        )
        let inconsistentCursors = [
            ImageSearchCursor(
                page: 1,
                photoCursor: nil,
                emojiCursor: PhotoSourceCursor(rawValue: "25")
            ),
            ImageSearchCursor(page: 2, photoCursor: nil, emojiCursor: nil)
        ]

        for cursor in inconsistentCursors {
            do {
                _ = try await service.giphyCatalog(cursor: cursor)
                XCTFail("矛盾的 GIPHY 游标应被拒绝")
            } catch {
                XCTAssertEqual(error as? PhotoSearchError, .invalidCursor)
            }
        }
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

    /// “全部”范围也应即时转发照片批次，头像只在完整照片页收敛后用于最终补位。
    func testAutomaticSearchForwardsPhotoBatchBeforeFinalAvatarFill() async throws {
        let probe = ImagePartialResultsProbe()
        let service = ImageSearchService(
            photos: BatchForwardingPhotoSearcher(),
            diceBear: DiceBearClient(styles: [.pixelArt]),
            automaticAvatarCount: 0,
            maximumPageSize: 2
        )

        let page = try await service.search("nebula", cursor: nil, pageSize: 2) { records in
            await probe.record(records)
        }

        let partials = await probe.snapshot()
        XCTAssertEqual(partials.map { $0.map(\.id) }, [["nasa-partial"]])
        XCTAssertEqual(page.records.first?.id, "nasa-partial")
        XCTAssertEqual(page.records.map(\.source), [.nasa, .diceBear])
    }

    /// Finder 逻辑页保持 40，但匿名 Openverse 必须拆成两个 20 条上游请求。
    func testAppDefaultRemainsTwentyWhileFileProviderCanRequestForty() async throws {
        let appOpenverse = OpenverseSpy()
        let app = ImageSearchService(openverse: appOpenverse)
        let appPage = try await app.search("图片:cat", page: 1, pageSize: 40)
        XCTAssertEqual(appPage.records.count, 20)
        let appCalls = await appOpenverse.recordedCalls()
        XCTAssertEqual(appCalls, [OpenverseCall(page: 1, pageSize: 20)])

        let finderOpenverse = OpenverseSpy()
        let finder = ImageSearchService(
            openverse: finderOpenverse,
            maximumPageSize: DiscoveryRecommendation.fileProviderPageSize
        )
        let finderFirst = try await finder.search("图片:cat", page: 1, pageSize: 40)
        let finderSecond = try await finder.search("图片:cat", page: 2, pageSize: 40)
        XCTAssertEqual(finderFirst.records.count, 40)
        XCTAssertEqual(finderSecond.records.count, 40)
        XCTAssertTrue(Set(finderFirst.records.map(\.id)).isDisjoint(
            with: Set(finderSecond.records.map(\.id))
        ))
        let finderCalls = await finderOpenverse.recordedCalls()
        XCTAssertEqual(finderCalls, [
            OpenverseCall(page: 1, pageSize: 20),
            OpenverseCall(page: 2, pageSize: 20),
            OpenverseCall(page: 3, pageSize: 20),
            OpenverseCall(page: 4, pageSize: 20)
        ])
    }

    /// File Provider 页令牌必须完整恢复页码、固定页大小和已交付数量。
    func testSearchPaginationCursorRoundTripAndValidation() throws {
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let searchCursor = ImageSearchCursor(
            page: 3,
            photoCursor: PhotoSearchCursor(
                configurationRevision: 7,
                states: [
                    PhotoSourceCursorState(
                        sourceID: .openverse,
                        cursor: PhotoSourceCursor(rawValue: "3"),
                        pageSize: 10,
                        exhausted: false
                    ),
                    PhotoSourceCursorState(
                        sourceID: .pexels,
                        cursor: PhotoSourceCursor(rawValue: "4"),
                        pageSize: 10,
                        exhausted: false
                    )
                ]
            )
        )
        let cursor = try SearchPaginationCursor(
            page: 3,
            pageSize: 20,
            delivered: 40,
            query: "cat",
            configurationKey: "sources:7:openverse,pexels",
            searchCursor: searchCursor,
            issuedAt: issuedAt
        )
        XCTAssertEqual(try SearchPaginationCursor.decode(cursor.encoded()), cursor)
        XCTAssertNoThrow(
            try cursor.validate(
                for: "CAT",
                configurationKey: "sources:7:openverse,pexels",
                now: issuedAt.addingTimeInterval(599)
            )
        )
        XCTAssertThrowsError(
            try cursor.validate(
                for: "cat",
                configurationKey: "sources:8:openverse",
                now: issuedAt
            )
        )
        XCTAssertThrowsError(try cursor.validate(for: "dog", now: issuedAt))
        XCTAssertThrowsError(try cursor.validate(for: "cat", now: issuedAt.addingTimeInterval(601)))
        XCTAssertThrowsError(try SearchPaginationCursor(page: 0, pageSize: 20, delivered: 0, query: "cat"))
        XCTAssertNoThrow(try SearchPaginationCursor(page: 1, pageSize: 40, delivered: 0, query: "cat"))
        XCTAssertThrowsError(try SearchPaginationCursor(page: 1, pageSize: 41, delivered: 0, query: "cat"))
        XCTAssertThrowsError(try SearchPaginationCursor(page: .max, pageSize: 20, delivered: 0, query: "cat"))
        XCTAssertThrowsError(try SearchPaginationCursor(page: 1, pageSize: 20, delivered: .max, query: "cat"))
        XCTAssertThrowsError(try cursor.deliveredCount(adding: .max))
        XCTAssertThrowsError(try cursor.advanced(to: 3, delivered: 40))

        let oversizedSourceQuota = ImageSearchCursor(
            page: 2,
            photoCursor: PhotoSearchCursor(
                configurationRevision: 7,
                states: [
                    PhotoSourceCursorState(
                        sourceID: .openverse,
                        cursor: PhotoSourceCursor(rawValue: "2"),
                        pageSize: 20,
                        exhausted: false
                    ),
                    PhotoSourceCursorState(
                        sourceID: .pexels,
                        cursor: PhotoSourceCursor(rawValue: "2"),
                        pageSize: 20,
                        exhausted: false
                    )
                ]
            )
        )
        XCTAssertThrowsError(
            try SearchPaginationCursor(
                page: 2,
                pageSize: 20,
                delivered: 20,
                query: "cat",
                configurationKey: "sources:7:openverse,pexels",
                searchCursor: oversizedSourceQuota
            )
        )

        let overflowingSourceQuota = ImageSearchCursor(
            page: 2,
            photoCursor: PhotoSearchCursor(
                configurationRevision: 7,
                states: [
                    PhotoSourceCursorState(
                        sourceID: .openverse,
                        cursor: PhotoSourceCursor(rawValue: "2"),
                        pageSize: .max,
                        exhausted: false
                    )
                ]
            )
        )
        XCTAssertThrowsError(
            try SearchPaginationCursor(
                page: 2,
                pageSize: 20,
                delivered: 20,
                query: "cat",
                configurationKey: "sources:7:openverse",
                searchCursor: overflowingSourceQuota
            )
        )

        let validGiphyCursor = ImageSearchCursor(
            page: 2,
            photoCursor: nil,
            emojiCursor: PhotoSourceCursor(rawValue: "gm1:fixture")
        )
        XCTAssertNoThrow(
            try SearchPaginationCursor(
                page: 2,
                pageSize: 40,
                delivered: 40,
                query: "",
                searchCursor: validGiphyCursor
            )
        )
        let oversizedGiphyCursor = ImageSearchCursor(
            page: 2,
            photoCursor: nil,
            emojiCursor: PhotoSourceCursor(rawValue: String(repeating: "x", count: 1_025))
        )
        XCTAssertThrowsError(
            try SearchPaginationCursor(
                page: 2,
                pageSize: 40,
                delivered: 40,
                query: "",
                searchCursor: oversizedGiphyCursor
            )
        )
        let mixedCursor = ImageSearchCursor(
            page: 2,
            photoCursor: searchCursor.photoCursor,
            emojiCursor: PhotoSourceCursor(rawValue: "gm1:fixture")
        )
        XCTAssertThrowsError(
            try SearchPaginationCursor(
                page: 2,
                pageSize: 40,
                delivered: 40,
                query: "",
                searchCursor: mixedCursor
            )
        )
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

private struct BatchForwardingPhotoSearcher: PhotoSearching {
    func search(query: String, cursor: PhotoSearchCursor?, pageSize: Int) async throws -> PhotoSearchPage {
        PhotoSearchPage(records: [Self.record], nextCursor: nil)
    }

    func search(
        query: String,
        cursor: PhotoSearchCursor?,
        pageSize: Int,
        onBatch: @escaping PhotoSearchBatchHandler
    ) async throws -> PhotoSearchPage {
        await onBatch(PhotoSearchBatch(sourceID: .nasa, records: [Self.record]))
        return PhotoSearchPage(records: [Self.record], nextCursor: nil)
    }

    func search(query: String, page: Int, pageSize: Int) async throws -> PhotoSearchPage {
        try await search(query: query, cursor: nil, pageSize: pageSize)
    }

    func configurationKey() async -> String { "batch-forwarding" }

    private static let record = RemoteImageRecord(
        id: "nasa-partial",
        title: "NASA Partial",
        source: .nasa,
        imageURL: URL(string: "https://example.com/nasa-partial.jpg")!,
        thumbnailURL: URL(string: "https://example.com/nasa-partial-thumb.jpg")!,
        license: .nasaMediaUsage
    )
}

private actor ImagePartialResultsProbe {
    private var batches: [[RemoteImageRecord]] = []

    func record(_ records: [RemoteImageRecord]) {
        batches.append(records)
    }

    func snapshot() -> [[RemoteImageRecord]] {
        batches
    }
}

private struct GiphyEmojiCall: Equatable, Sendable {
    let query: String
    let cursor: String?
    let pageSize: Int
}

private actor GiphyEmojiSpy: PhotoSourceSearching {
    nonisolated let sourceID = PhotoSourceID.giphy
    private var calls: [GiphyEmojiCall] = []

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        calls.append(GiphyEmojiCall(query: query, cursor: cursor?.rawValue, pageSize: pageSize))
        let offset = cursor.flatMap { Int($0.rawValue) } ?? 0
        let url = URL(string: "https://media.giphy.com/media/emoji-(offset)/giphy.gif")!
        return PhotoSourcePage(
            records: [RemoteImageRecord(
                id: "giphy-fixture-(offset)",
                title: "GIPHY Emoji",
                source: .giphy,
                imageURL: url,
                thumbnailURL: url,
                sourcePageURL: URL(string: "https://giphy.com/gifs/emoji-(offset)"),
                license: .giphy,
                mimeType: "image/gif"
            )],
            nextCursor: offset == 0 ? PhotoSourceCursor(rawValue: "40") : nil
        )
    }

    func recordedCalls() -> [GiphyEmojiCall] {
        calls
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
