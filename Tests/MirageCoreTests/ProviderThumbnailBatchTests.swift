@preconcurrency import FileProvider
import XCTest

/// 缩略图批次的有界并发语义：每个标识恰好回调一次，单张失败不拖垮整批，取消后余量统一收尾。
/// Finder 一批请求约 8 张，串行下载会让一整行图标等满一轮轮网络往返，这组测试锁定并行交付的边界。
final class ProviderThumbnailBatchTests: XCTestCase {
    /// 成功批次为每个标识各回调一次，并携带对应标识自己的数据。
    func testDeliversEveryIdentifierExactlyOnce() async {
        let identifiers = Self.identifiers(0..<9)
        let recorder = DeliveryRecorder()

        let finished = await ProviderThumbnailBatch.run(
            identifiers: identifiers,
            maximumConcurrency: 3,
            fetch: { Data($0.rawValue.utf8) },
            deliver: { recorder.record($0, $1) }
        )

        XCTAssertTrue(finished)
        XCTAssertEqual(recorder.totalDeliveries, 9)
        XCTAssertEqual(recorder.successCount, 9)
        for identifier in identifiers {
            XCTAssertEqual(recorder.data(for: identifier), Data(identifier.rawValue.utf8))
        }
    }

    /// 并发既要真的发生（否则回到串行的等待），又不能超过上限（否则快速滚动打开几十条连接）。
    func testConcurrencyIsParallelYetBounded() async {
        let gauge = ConcurrencyGauge()

        _ = await ProviderThumbnailBatch.run(
            identifiers: Self.identifiers(0..<8),
            maximumConcurrency: 4,
            fetch: { identifier in
                gauge.enter()
                defer { gauge.exit() }
                try await Task.sleep(for: .milliseconds(80))
                return Data(identifier.rawValue.utf8)
            },
            deliver: { _, _ in }
        )

        XCTAssertLessThanOrEqual(gauge.maxObserved, 4, "同时在途的抓取不能超过并发上限")
        XCTAssertGreaterThanOrEqual(gauge.maxObserved, 2, "批次必须真正并行")
    }

    /// Finder 冷启动会并行提交多批请求；跨批次也必须共享同一个总并发上限。
    func testSharedLoadGateBoundsConcurrentBatches() async {
        let gate = ProviderThumbnailLoadGate(maximumConcurrentLoads: 4)
        let gauge = ConcurrencyGauge()

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for batch in 0..<3 {
                group.addTask {
                    await ProviderThumbnailBatch.run(
                        identifiers: Self.identifiers((batch * 8)..<((batch + 1) * 8)),
                        maximumConcurrency: 4,
                        fetch: { identifier in
                            try await gate.withPermit {
                                gauge.enter()
                                defer { gauge.exit() }
                                try await Task.sleep(for: .milliseconds(60))
                                return Data(identifier.rawValue.utf8)
                            }
                        },
                        deliver: { _, _ in }
                    )
                }
            }

            var values: [Bool] = []
            for await result in group { values.append(result) }
            return values
        }

        XCTAssertEqual(results, [true, true, true])
        XCTAssertLessThanOrEqual(gauge.maxObserved, 4, "多批请求的总并发不能超过扩展上限")
        XCTAssertGreaterThanOrEqual(gauge.maxObserved, 2, "许可池仍应允许并行下载")
    }

    /// 排队请求被 Finder 取消后必须退出等待，且不能占住后续请求所需的许可。
    func testSharedLoadGateRecoversAfterQueuedRequestIsCancelled() async {
        let gate = ProviderThumbnailLoadGate(maximumConcurrentLoads: 1)
        let holderStarted = AsyncLatch()
        let releaseHolder = AsyncLatch()

        let holder = Task {
            try await gate.withPermit {
                await holderStarted.open()
                await releaseHolder.wait()
                return Data("holder".utf8)
            }
        }
        await holderStarted.wait()

        let queued = Task {
            try await gate.withPermit { Data("queued".utf8) }
        }
        try? await Task.sleep(for: .milliseconds(60))
        queued.cancel()

        do {
            _ = try await queued.value
            XCTFail("排队请求取消后不应执行")
        } catch is CancellationError {
            // 预期路径：取消的 waiter 从队列移除并以取消错误结束。
        } catch {
            XCTFail("排队请求应以 CancellationError 结束：\(error)")
        }

        await releaseHolder.open()
        do {
            _ = try await holder.value
        } catch {
            XCTFail("持有许可的请求不应失败：\(error)")
        }

        let recovered = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                (try? await gate.withPermit { true }) ?? false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }

            let firstResult = await group.next() ?? false
            group.cancelAll()
            return firstResult
        }
        XCTAssertTrue(recovered, "取消 waiter 后许可池必须继续服务后续请求")
    }

    /// 单张图片失败只影响它自己的回调，其余条目照常交付，批次整体仍算完成。
    func testSingleFailureDoesNotStopBatch() async {
        let identifiers = Self.identifiers(0..<6)
        let failing = identifiers[2]
        let recorder = DeliveryRecorder()

        let finished = await ProviderThumbnailBatch.run(
            identifiers: identifiers,
            maximumConcurrency: 2,
            fetch: { identifier in
                if identifier == failing { throw ThumbnailBatchTestError.unavailable }
                return Data(identifier.rawValue.utf8)
            },
            deliver: { recorder.record($0, $1) }
        )

        XCTAssertTrue(finished)
        XCTAssertEqual(recorder.totalDeliveries, 6)
        XCTAssertEqual(recorder.successCount, 5)
        XCTAssertNotNil(recorder.error(for: failing))
    }

    /// 取消后批次不能宣称完成，但每个标识仍要恰好收到一次回调，系统才能对齐收尾。
    func testCancellationDeliversFailureForEveryRemainingIdentifier() async {
        let identifiers = Self.identifiers(0..<8)
        let recorder = DeliveryRecorder()
        let task = Task {
            await ProviderThumbnailBatch.run(
                identifiers: identifiers,
                maximumConcurrency: 2,
                fetch: { identifier in
                    try await Task.sleep(for: .seconds(10))
                    return Data(identifier.rawValue.utf8)
                },
                deliver: { recorder.record($0, $1) }
            )
        }

        try? await Task.sleep(for: .milliseconds(120))
        task.cancel()
        let finished = await task.value

        XCTAssertFalse(finished, "取消的批次不能宣称正常完成")
        XCTAssertEqual(recorder.totalDeliveries, 8, "取消后每个标识仍要恰好收到一次回调")
        XCTAssertEqual(recorder.successCount, 0)
    }

    /// 与生产推荐流一致的稳定标识。
    private static func identifiers(_ range: Range<Int>) -> [NSFileProviderItemIdentifier] {
        range.map { NSFileProviderItemIdentifier("discover:item-\($0)") }
    }
}

/// 单张失败场景使用的确定性错误。
private enum ThumbnailBatchTestError: Error {
    case unavailable
}

/// 线程安全地记录每个标识的回调次数与结果；回调可能来自任意并发子任务。
private final class DeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: Result<Data, any Error>] = [:]
    private var deliveryCount = 0

    func record(_ identifier: NSFileProviderItemIdentifier, _ result: Result<Data, any Error>) {
        lock.withLock {
            deliveryCount += 1
            results[identifier.rawValue] = result
        }
    }

    var totalDeliveries: Int {
        lock.withLock { deliveryCount }
    }

    var successCount: Int {
        lock.withLock {
            results.values.count { if case .success = $0 { return true } else { return false } }
        }
    }

    func data(for identifier: NSFileProviderItemIdentifier) -> Data? {
        lock.withLock { try? results[identifier.rawValue]?.get() }
    }

    func error(for identifier: NSFileProviderItemIdentifier) -> (any Error)? {
        lock.withLock {
            guard case let .failure(error)? = results[identifier.rawValue] else { return nil }
            return error
        }
    }
}

/// 记录同时在途抓取数量的峰值。
private final class ConcurrencyGauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var peak = 0

    func enter() {
        lock.withLock {
            current += 1
            peak = max(peak, current)
        }
    }

    func exit() {
        lock.withLock { current -= 1 }
    }

    var maxObserved: Int {
        lock.withLock { peak }
    }
}

/// 测试用一次性异步门闩，避免依赖生产代码内部计数来协调并发顺序。
private actor AsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
