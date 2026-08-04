import Foundation
import XCTest
@testable import MirageCore

final class AggregatedPhotoSearcherConcurrencyTests: XCTestCase {
    /// Provider 请求必须并发启动，新增第三个来源后延迟也不能串行累加。
    func testRequestsEnabledSourcesConcurrently() async throws {
        let probe = SourceConcurrencyProbe()
        let searcher = AggregatedPhotoSearcher(
            sources: [
                ProbedPhotoSource(sourceID: .openverse, probe: probe),
                ProbedPhotoSource(sourceID: .pexels, probe: probe),
                ProbedPhotoSource(sourceID: .pixabay, probe: probe)
            ],
            configurationRevision: 1
        )

        _ = try await searcher.search(query: "cat", cursor: nil, pageSize: 3)
        let maximum = await probe.maximumConcurrentRequests()
        XCTAssertEqual(maximum, 3)
    }
}

private actor SourceConcurrencyProbe {
    private var active = 0
    private var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() { active -= 1 }
    func maximumConcurrentRequests() -> Int { maximum }
}

private struct ProbedPhotoSource: PhotoSourceSearching {
    let sourceID: PhotoSourceID
    let probe: SourceConcurrencyProbe

    func search(query: String, cursor: PhotoSourceCursor?, pageSize: Int) async throws -> PhotoSourcePage {
        await probe.enter()
        do {
            try await Task.sleep(for: .milliseconds(50))
            await probe.leave()
            return PhotoSourcePage(records: [], nextCursor: nil)
        } catch {
            await probe.leave()
            throw error
        }
    }
}
