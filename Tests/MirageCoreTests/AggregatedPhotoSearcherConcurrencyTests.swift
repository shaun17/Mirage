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

    /// 单个来源完成后立即发出批次，但最终页与游标仍保持配置顺序。
    func testEmitsFastSourceBeforeSlowSourceWhileKeepingFinalPageStable() async throws {
        let gate = ProgressiveSourceGate()
        let batchProbe = ProgressiveBatchProbe()
        let completionProbe = SearchCompletionProbe()
        let firstBatchReceived = expectation(description: "NASA 增量批次先到达")
        let searcher = AggregatedPhotoSearcher(
            sources: [
                GatedPhotoSource(sourceID: .openverse, gate: gate),
                GatedPhotoSource(sourceID: .nasa, gate: gate)
            ],
            configurationRevision: 7
        )

        let searchTask = Task {
            let page = try await searcher.search(query: "moon", cursor: nil, pageSize: 2) { batch in
                if await batchProbe.record(batch) {
                    firstBatchReceived.fulfill()
                }
            }
            await completionProbe.markCompleted()
            return page
        }

        await gate.waitUntilRequested([.openverse, .nasa])
        await gate.release(
            .nasa,
            page: PhotoSourcePage(
                records: [makeRecord(id: "fast-nasa", source: .nasa)],
                nextCursor: PhotoSourceCursor(rawValue: "nasa-next")
            )
        )

        await fulfillment(of: [firstBatchReceived], timeout: 2)
        let earlyBatches = await batchProbe.snapshot()
        let completedBeforeSlowSource = await completionProbe.isCompleted()
        XCTAssertEqual(earlyBatches.map(\.sourceID), [.nasa])
        XCTAssertEqual(earlyBatches.flatMap(\.records).map(\.id), ["fast-nasa"])
        XCTAssertFalse(completedBeforeSlowSource)

        await gate.release(
            .openverse,
            page: PhotoSourcePage(
                records: [makeRecord(id: "slow-openverse", source: .openverse)],
                nextCursor: PhotoSourceCursor(rawValue: "openverse-next")
            )
        )

        let finalPage = try await searchTask.value
        let allBatches = await batchProbe.snapshot()
        XCTAssertEqual(allBatches.map(\.sourceID), [.nasa, .openverse])
        XCTAssertEqual(finalPage.records.map(\.id), ["slow-openverse", "fast-nasa"])

        let states = try XCTUnwrap(finalPage.nextCursor?.states)
        XCTAssertEqual(states.map(\.sourceID), [.openverse, .nasa])
        XCTAssertEqual(states.map { $0.cursor?.rawValue }, ["openverse-next", "nasa-next"])
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

private actor ProgressiveSourceGate {
    private var requested: Set<PhotoSourceID> = []
    private var pending: [PhotoSourceID: CheckedContinuation<PhotoSourcePage, Never>] = [:]
    private var requestWaiters: [(
        expected: Set<PhotoSourceID>,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    func waitForRelease(_ sourceID: PhotoSourceID) async -> PhotoSourcePage {
        await withCheckedContinuation { continuation in
            precondition(pending[sourceID] == nil, "同一来源不应重复进入门闩")
            requested.insert(sourceID)
            pending[sourceID] = continuation
            resumeSatisfiedRequestWaiters()
        }
    }

    func waitUntilRequested(_ expected: Set<PhotoSourceID>) async {
        guard !expected.isSubset(of: requested) else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((expected: expected, continuation: continuation))
        }
    }

    func release(_ sourceID: PhotoSourceID, page: PhotoSourcePage) {
        guard let continuation = pending.removeValue(forKey: sourceID) else {
            preconditionFailure("来源必须先发起请求才能释放")
        }
        continuation.resume(returning: page)
    }

    private func resumeSatisfiedRequestWaiters() {
        var remaining: [(
            expected: Set<PhotoSourceID>,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        for waiter in requestWaiters {
            if waiter.expected.isSubset(of: requested) {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestWaiters = remaining
    }
}

private struct GatedPhotoSource: PhotoSourceSearching {
    let sourceID: PhotoSourceID
    let gate: ProgressiveSourceGate

    func search(query: String, cursor: PhotoSourceCursor?, pageSize: Int) async throws -> PhotoSourcePage {
        await gate.waitForRelease(sourceID)
    }
}

private actor ProgressiveBatchProbe {
    private var batches: [PhotoSearchBatch] = []

    func record(_ batch: PhotoSearchBatch) -> Bool {
        batches.append(batch)
        return batches.count == 1
    }

    func snapshot() -> [PhotoSearchBatch] {
        batches
    }
}

private actor SearchCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private func makeRecord(id: String, source: ImageSource) -> RemoteImageRecord {
    let url = URL(string: "https://example.com/\(id).jpg")!
    return RemoteImageRecord(
        id: id,
        title: id,
        source: source,
        imageURL: url,
        thumbnailURL: url,
        license: source == .nasa ? .nasaMediaUsage : .cc0
    )
}
