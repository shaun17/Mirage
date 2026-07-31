import Foundation
import XCTest
@testable import MirageCore

final class DiscoveryFeedSnapshotMutationNotifierTests: XCTestCase {
    /// 首次 signal 进行中出现的多次 mutation 应合并为一次补充 signal，且 worker 不并发。
    func testCoalescesMutationsAndResignalsChangesArrivingDuringSignal() async {
        let probe = BlockingSnapshotSignalProbe()
        let notifier = DiscoveryFeedSnapshotMutationNotifier(
            signal: { try await probe.send() },
            initialRetryDelay: .milliseconds(10)
        )

        await notifier.setNeedsSignal()
        let firstStarted = await probe.waitForAttempts(1)
        XCTAssertTrue(firstStarted)

        await notifier.setNeedsSignal()
        await notifier.setNeedsSignal()
        await probe.releaseFirstAttempt()

        let secondCompleted = await probe.waitForCompletions(2)
        XCTAssertTrue(secondCompleted)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.attempts, 2)
        XCTAssertEqual(snapshot.completions, 2)
        XCTAssertEqual(snapshot.maximumConcurrentAttempts, 1)
    }
}

/// 第一轮 signal 可控阻塞，用于把新 mutation 稳定插入 signal 进行中的窗口。
private actor BlockingSnapshotSignalProbe {
    private var attempts = 0
    private var completions = 0
    private var activeAttempts = 0
    private var maximumConcurrentAttempts = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func send() async throws {
        attempts += 1
        activeAttempts += 1
        maximumConcurrentAttempts = max(maximumConcurrentAttempts, activeAttempts)
        if attempts == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        activeAttempts -= 1
        completions += 1
    }

    func releaseFirstAttempt() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    func waitForAttempts(_ expected: Int) async -> Bool {
        await waitUntil { attempts >= expected }
    }

    func waitForCompletions(_ expected: Int) async -> Bool {
        await waitUntil { completions >= expected }
    }

    func snapshot() -> (attempts: Int, completions: Int, maximumConcurrentAttempts: Int) {
        (attempts, completions, maximumConcurrentAttempts)
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}
