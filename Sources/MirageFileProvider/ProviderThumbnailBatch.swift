@preconcurrency import FileProvider
import Foundation

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
