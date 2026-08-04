import Foundation
import XCTest
@testable import MirageCore

final class AggregatedPhotoSearcherTests: XCTestCase {
    /// 初页配额会被冻结进游标；后续请求分别续接每个 provider，并保持来源顺序交错。
    func testFixedQuotaIndependentCursorsAndStableRoundRobin() async throws {
        let openverse = ScriptedPhotoSource(
            id: .openverse,
            steps: [
                .page(Self.records("o", count: 3, source: .openverse), "o-next"),
                .page(Self.records("o2-", count: 3, source: .openverse), nil)
            ]
        )
        let pexels = ScriptedPhotoSource(
            id: .pexels,
            steps: [
                .page(Self.records("p", count: 2, source: .pexels), "p-next"),
                .page(Self.records("p2-", count: 2, source: .pexels), nil)
            ]
        )
        let searcher = AggregatedPhotoSearcher(
            sources: [openverse, pexels],
            configurationRevision: 7
        )

        let first = try await searcher.search(query: "cat", cursor: nil, pageSize: 5)
        XCTAssertEqual(first.records.map(\.id), ["o0", "p0", "o1", "p1", "o2"])
        XCTAssertEqual(first.nextCursor?.configurationRevision, 7)
        XCTAssertEqual(first.nextCursor?.states.map(\.pageSize), [3, 2])

        let second = try await searcher.search(query: "cat", cursor: first.nextCursor, pageSize: 5)
        XCTAssertEqual(second.records.map(\.id), ["o2-0", "p2-0", "o2-1", "p2-1", "o2-2"])
        XCTAssertNil(second.nextCursor)
        let openverseCalls = await openverse.calls()
        let pexelsCalls = await pexels.calls()
        XCTAssertEqual(openverseCalls, [
            SourceCall(cursor: nil, pageSize: 3),
            SourceCall(cursor: "o-next", pageSize: 3)
        ])
        XCTAssertEqual(pexelsCalls, [
            SourceCall(cursor: nil, pageSize: 2),
            SourceCall(cursor: "p-next", pageSize: 2)
        ])
    }

    /// 一个来源失败时仍返回其他来源；失败来源的游标必须保留，下一页从原位置重试。
    func testPartialFailureDoesNotConsumeFailedSourceCursor() async throws {
        let openverse = ScriptedPhotoSource(id: .openverse, steps: [
            .page(Self.records("o", count: 2, source: .openverse), "o-next"),
            .page(Self.records("o2-", count: 2, source: .openverse), nil)
        ])
        let pexels = ScriptedPhotoSource(id: .pexels, steps: [
            .failure(.invalidCredential),
            .page(Self.records("p", count: 2, source: .pexels), nil)
        ])
        let searcher = AggregatedPhotoSearcher(
            sources: [openverse, pexels],
            configurationRevision: 3
        )

        let first = try await searcher.search(query: "cat", cursor: nil, pageSize: 4)
        XCTAssertEqual(first.records.map(\.id), ["o0", "o1"])
        XCTAssertEqual(first.issues.map(\.kind), [.invalidCredential])
        XCTAssertEqual(first.nextCursor?.states.last?.cursor, nil)
        XCTAssertEqual(first.nextCursor?.states.last?.exhausted, false)

        let second = try await searcher.search(query: "cat", cursor: first.nextCursor, pageSize: 4)
        XCTAssertEqual(second.records.map(\.id), ["o2-0", "p0", "o2-1", "p1"])
        let pexelsCalls = await pexels.calls()
        XCTAssertEqual(pexelsCalls.map(\.cursor), [nil, nil])
    }

    /// 只有全部活动来源都失败时，聚合页才整体失败，并保留每个来源的问题。
    func testAllSourcesFailedThrowsTypedIssues() async {
        let first = ScriptedPhotoSource(id: .openverse, steps: [.failure(.network)])
        let second = ScriptedPhotoSource(id: .pexels, steps: [.failure(.rateLimited)])
        let searcher = AggregatedPhotoSearcher(sources: [first, second], configurationRevision: 1)

        do {
            _ = try await searcher.search(query: "cat", cursor: nil, pageSize: 4)
            XCTFail("全部失败时应抛错")
        } catch let PhotoSearchError.allSourcesFailed(issues) {
            XCTAssertEqual(Set(issues.map(\.sourceID)), Set([.openverse, .pexels]))
            XCTAssertEqual(Set(issues.map(\.kind)), Set([.network, .rateLimited]))
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }

    /// 设置 revision 变化后旧游标必须失效，且不同来源返回的相同稳定 ID 只发布一次。
    func testConfigurationRevisionAndRecordIDDeduplication() async throws {
        let first = ScriptedPhotoSource(id: .openverse, steps: [
            .page([Self.record(id: "same", source: .openverse)], "next")
        ])
        let second = ScriptedPhotoSource(id: .pexels, steps: [
            .page([Self.record(id: "same", source: .pexels)], "next")
        ])
        let original = AggregatedPhotoSearcher(sources: [first, second], configurationRevision: 9)
        let page = try await original.search(query: "cat", cursor: nil, pageSize: 2)
        XCTAssertEqual(page.records.map(\.id), ["same"])

        let changed = AggregatedPhotoSearcher(sources: [first, second], configurationRevision: 10)
        do {
            _ = try await changed.search(query: "cat", cursor: page.nextCursor, pageSize: 2)
            XCTFail("旧配置游标应失效")
        } catch {
            XCTAssertEqual(error as? PhotoSearchError, .configurationChanged)
        }
    }

    private static func records(_ prefix: String, count: Int, source: ImageSource) -> [RemoteImageRecord] {
        (0..<count).map { record(id: "\(prefix)\($0)", source: source) }
    }

    private static func record(id: String, source: ImageSource) -> RemoteImageRecord {
        let url = URL(string: "https://example.com/\(id).jpg")!
        return RemoteImageRecord(
            id: id,
            title: id,
            source: source,
            imageURL: url,
            thumbnailURL: url,
            license: source == .pexels ? .pexels : .cc0
        )
    }
}

private struct SourceCall: Equatable, Sendable {
    let cursor: String?
    let pageSize: Int
}

private enum ScriptedStep: Sendable {
    case page([RemoteImageRecord], String?)
    case failure(PhotoSourceIssueKind)
}

private actor ScriptedPhotoSource: PhotoSourceSearching {
    nonisolated let sourceID: PhotoSourceID
    private var steps: [ScriptedStep]
    private var recordedCalls: [SourceCall] = []

    init(id: PhotoSourceID, steps: [ScriptedStep]) {
        sourceID = id
        self.steps = steps
    }

    func search(query: String, cursor: PhotoSourceCursor?, pageSize: Int) async throws -> PhotoSourcePage {
        recordedCalls.append(SourceCall(cursor: cursor?.rawValue, pageSize: pageSize))
        guard !steps.isEmpty else { throw StubPhotoFailure(sourceID: sourceID, issueKind: .unavailable) }
        switch steps.removeFirst() {
        case let .page(records, next):
            return PhotoSourcePage(
                records: records,
                nextCursor: next.map { PhotoSourceCursor(rawValue: $0) }
            )
        case let .failure(kind):
            throw StubPhotoFailure(sourceID: sourceID, issueKind: kind)
        }
    }

    func calls() -> [SourceCall] { recordedCalls }
}

private struct StubPhotoFailure: PhotoSourceFailure, LocalizedError {
    let sourceID: PhotoSourceID
    let issueKind: PhotoSourceIssueKind
    let retryAt: Date? = nil
    var errorDescription: String? { "stub failure" }
}
