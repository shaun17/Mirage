@preconcurrency import FileProvider
import Foundation

/// File Provider 可能同时发起多批缩略图请求；所有批次共用这个取消安全许可池。
///
/// 单个 `ProviderThumbnailBatch` 的并发上限只约束一批请求。Finder 冷启动且没有缩略图缓存时，
/// 会并行提交多批请求，如果没有跨批次上限，扩展会瞬间建立几十条独立网络连接。
actor ProviderThumbnailLoadGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let maximumConcurrentLoads: Int
    private var activeLoads = 0
    private var waiters: [Waiter] = []

    init(maximumConcurrentLoads: Int) {
        self.maximumConcurrentLoads = max(maximumConcurrentLoads, 1)
    }

    func withPermit<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard activeLoads >= maximumConcurrentLoads else {
            activeLoads += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume()
        } else {
            activeLoads = max(activeLoads - 1, 0)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// 把一批缩略图请求变成有界并发的下载。
///
/// 系统每批请求约 8 张可见项的缩略图：串行逐张会让一整行图标等满一轮轮网络往返，
/// 无界并发又会在快速滚动时同时打开几十条连接。这里以固定并发宽度消费队列，
/// 每个标识恰好回调一次；任务取消后，仍未完成的标识统一以 `CancellationError` 收尾。
enum ProviderThumbnailBatch {
    /// 返回 false 表示批次因取消提前收尾，调用方据此回调整体取消错误。
    @discardableResult
    static func run(
        identifiers: [NSFileProviderItemIdentifier],
        maximumConcurrency: Int,
        fetch: @escaping @Sendable (NSFileProviderItemIdentifier) async throws -> Data,
        deliver: @escaping @Sendable (NSFileProviderItemIdentifier, Result<Data, any Error>) -> Void
    ) async -> Bool {
        let width = max(maximumConcurrency, 1)
        var nextIndex = 0
        await withTaskGroup(of: Void.self) { group in
            while nextIndex < min(width, identifiers.count) {
                let identifier = identifiers[nextIndex]
                nextIndex += 1
                group.addTask { await fetchOne(identifier, fetch: fetch, deliver: deliver) }
            }
            for await _ in group {
                guard !Task.isCancelled, nextIndex < identifiers.count else { continue }
                let identifier = identifiers[nextIndex]
                nextIndex += 1
                group.addTask { await fetchOne(identifier, fetch: fetch, deliver: deliver) }
            }
        }
        guard !Task.isCancelled else {
            // 取消后停止派发，尚未开始的标识也必须逐一收尾，系统才能对齐每张图的回调。
            identifiers[nextIndex...].forEach { deliver($0, .failure(CancellationError())) }
            return false
        }
        return true
    }

    /// 单个条目的失败只属于它自己；取消与网络错误都转成该标识的一次失败回调。
    private static func fetchOne(
        _ identifier: NSFileProviderItemIdentifier,
        fetch: (NSFileProviderItemIdentifier) async throws -> Data,
        deliver: (NSFileProviderItemIdentifier, Result<Data, any Error>) -> Void
    ) async {
        do {
            try Task.checkCancellation()
            let data = try await fetch(identifier)
            try Task.checkCancellation()
            deliver(identifier, .success(data))
        } catch {
            deliver(identifier, .failure(error))
        }
    }
}
