import Foundation
import OSLog

/// 把持久化推荐变更合并成独立 signal；调用方取消不会撤销通知，瞬时失败会退避重试。
actor DiscoveryFeedSnapshotMutationNotifier {
    private static let logger = Logger(
        subsystem: "com.wenren.Mirage",
        category: "DiscoverySnapshotSignal"
    )
    private static let maximumRetryDelay: Duration = .seconds(30)

    private let signal: @Sendable () async throws -> Void
    private let initialRetryDelay: Duration
    private var retryDelay: Duration
    private var needsSignal = false
    private var attemptTask: Task<Void, Never>?

    init(
        signal: @escaping @Sendable () async throws -> Void,
        initialRetryDelay: Duration
    ) {
        self.signal = signal
        let normalizedDelay = min(
            max(initialRetryDelay, .milliseconds(10)),
            Self.maximumRetryDelay
        )
        self.initialRetryDelay = normalizedDelay
        self.retryDelay = normalizedDelay
    }

    /// 多次 mutation 在 worker 启动前只产生一次 signal；进行中出现的新 mutation 会再补一次。
    func setNeedsSignal() {
        needsSignal = true
        scheduleAttempt(after: nil)
    }

    /// 延迟任务只弱持有 actor，仓库释放后不会因无限重试延长生命周期。
    private func scheduleAttempt(after delay: Duration?) {
        guard attemptTask == nil else { return }
        attemptTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard let self else { return }
            await self.performAttempt()
        }
    }

    /// 成功后立即处理 signal 期间合并进来的新变更；失败则保留 dirty 状态并指数退避。
    private func performAttempt() async {
        guard needsSignal else {
            attemptTask = nil
            return
        }
        needsSignal = false
        let nextDelay: Duration?
        do {
            try await signal()
            retryDelay = initialRetryDelay
            nextDelay = nil
        } catch {
            needsSignal = true
            nextDelay = retryDelay
            retryDelay = min(retryDelay * 2, Self.maximumRetryDelay)
            Self.logger.error(
                "推荐快照刷新 signal 失败，将重试：\(error.localizedDescription, privacy: .public)"
            )
        }

        attemptTask = nil
        guard needsSignal else { return }
        scheduleAttempt(after: nextDelay)
    }
}
