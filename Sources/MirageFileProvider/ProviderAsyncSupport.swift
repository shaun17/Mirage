import FileProvider
import Foundation

/// 在线程安全边界内持有结构化并发任务，供 NSProgress 与 invalidate 取消。
final class ProviderTaskRelay: @unchecked Sendable {
    /// 终止状态由同一把锁推进，保证取消与正常完成只能有一方获胜。
    private enum State {
        case active
        case cancelled
        case committing
        case finished
    }

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var state = State.active

    /// 安装任务；如果取消先到达，则立即把取消传递给任务。
    func install(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard state != .finished else { return false }
            self.task = task
            return state == .cancelled
        }
        if shouldCancel { task.cancel() }
    }

    /// 幂等取消当前任务；不可逆提交已经开始时，迟到取消不再改变已确定的结果。
    func cancel() {
        let task: Task<Void, Never>? = lock.withLock {
            guard state == .active else { return nil }
            state = .cancelled
            return self.task
        }
        task?.cancel()
    }

    /// 在交付完整文件前原子取得提交权，确保取消若先发生就不会回调成功。
    func beginNonCancellableCompletion() -> Bool {
        lock.withLock {
            guard state == .active else { return false }
            state = .committing
            return true
        }
    }

    /// exactly-once 地执行终止回调；若取消先获胜，则只执行取消分支。
    func finish(_ completion: () -> Void, ifCancelled cancellation: () -> Void) {
        let wasCancelled: Bool? = lock.withLock {
            switch state {
            case .active, .committing:
                state = .finished
                task = nil
                return false
            case .cancelled:
                state = .finished
                task = nil
                return true
            case .finished:
                return nil
            }
        }
        guard let wasCancelled else { return }
        wasCancelled ? cancellation() : completion()
    }
}

/// 把 ObjC 回调安全封装为可跨 Swift 并发任务持有的不可变值。
final class ProviderCallbackBox<Value>: @unchecked Sendable {
    let value: Value

    /// 回调本身不跨扩展边界泄漏，只由所属任务调用。
    init(_ value: Value) {
        self.value = value
    }
}

/// 跟踪扩展实例内所有并发操作，invalidate 时统一取消。
final class ProviderTaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var relays: [UUID: ProviderTaskRelay] = [:]

    /// 在创建任务前注册中继，消除极短任务先结束、后写入任务袋造成的泄漏竞态。
    func insert(_ relay: ProviderTaskRelay, id: UUID) {
        lock.withLock { relays[id] = relay }
    }

    /// 操作结束后移除任务，防止扩展实例长期持有。
    func remove(id: UUID) {
        lock.withLock { relays[id] = nil }
    }

    /// 取消扩展实例中的所有网络和磁盘任务。
    func cancelAll() {
        let current = lock.withLock {
            let values = Array(relays.values)
            relays.removeAll()
            return values
        }
        current.forEach { $0.cancel() }
    }
}
