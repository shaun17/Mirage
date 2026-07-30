import MirageCore
@preconcurrency import FileProvider
import Foundation

/// 以全量快照实现普通枚举与保守变更枚举。
final class ProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let scope: ProviderEnumerationScope
    private let catalog: ProviderCatalog
    private let tasks = ProviderTaskBag()

    init(scope: ProviderEnumerationScope, catalog: ProviderCatalog) {
        self.scope = scope
        self.catalog = catalog
        super.init()
    }

    /// 系统不再需要枚举结果时取消尚未完成的磁盘读取。
    func invalidate() {
        tasks.cancelAll()
    }

    /// 数据量受控，单页返回当前目录的完整快照。
    func enumerateItems(
        for observer: any NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let relay = ProviderTaskRelay()
        let operationID = UUID()
        tasks.insert(relay, id: operationID)
        let task = Task { [catalog, scope, tasks, relay] in
            defer { tasks.remove(id: operationID) }
            do {
                try Task.checkCancellation()
                let items = try await catalog.preparedItems(for: scope)
                try Task.checkCancellation()
                relay.finish({
                    observer.didEnumerate(items)
                    observer.finishEnumerating(upTo: nil)
                }, ifCancelled: {
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                })
            } catch is CancellationError {
                relay.finish({
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                }, ifCancelled: {
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                })
            } catch {
                relay.finish({
                    observer.finishEnumeratingWithError(error)
                }, ifCancelled: {
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                })
            }
        }
        relay.install(task)
    }

    /// 按 scope 发布持久化 old-new 差异，删除与更新分别交给系统处理。
    func enumerateChanges(
        for observer: any NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    ) {
        let relay = ProviderTaskRelay()
        let operationID = UUID()
        tasks.insert(relay, id: operationID)
        let task = Task { [catalog, scope, tasks, relay] in
            defer { tasks.remove(id: operationID) }
            do {
                try Task.checkCancellation()
                let anchor = try Self.decode(syncAnchor)
                let changes = try await catalog.changes(for: scope, after: anchor)
                try Task.checkCancellation()
                relay.finish({
                    if !changes.deleted.isEmpty {
                        observer.didDeleteItems(withIdentifiers: changes.deleted)
                    }
                    if !changes.updated.isEmpty { observer.didUpdate(changes.updated) }
                    observer.finishEnumeratingChanges(
                        upTo: Self.encode(changes.anchor),
                        moreComing: false
                    )
                }, ifCancelled: {
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                })
            } catch is CancellationError {
                relay.finish({
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                }, ifCancelled: {
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                })
            } catch is ProviderChangeStorageError {
                relay.finish({
                    observer.finishEnumeratingWithError(ProviderError.syncAnchorExpired())
                }, ifCancelled: {
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                })
            } catch {
                relay.finish({
                    observer.finishEnumeratingWithError(error)
                }, ifCancelled: {
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                })
            }
        }
        relay.install(task)
    }

    /// 返回当前版本，供系统在目录枚举前建立一致性边界。
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let callback = ProviderCallbackBox(completionHandler)
        let relay = ProviderTaskRelay()
        let operationID = UUID()
        tasks.insert(relay, id: operationID)
        let task = Task { [catalog, scope, tasks, relay] in
            defer { tasks.remove(id: operationID) }
            do {
                let anchor = try await catalog.currentAnchor(for: scope)
                try Task.checkCancellation()
                relay.finish({
                    callback.value(Self.encode(anchor))
                }, ifCancelled: {
                    callback.value(nil)
                })
            } catch {
                // 该系统回调没有错误参数，读取失败或取消都只能返回 nil 促使系统重新枚举。
                relay.finish({
                    callback.value(nil)
                }, ifCancelled: {
                    callback.value(nil)
                })
            }
        }
        relay.install(task)
    }

    /// v2 前缀隔离旧进程内时钟，旧纯数字锚点会过期并触发系统全量清理幽灵项。
    private static func encode(_ value: UInt64) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(rawValue: Data("v2:\(value)".utf8))
    }

    /// 严格拒绝损坏锚点，避免错误地把未知状态当成首次同步。
    private static func decode(_ anchor: NSFileProviderSyncAnchor) throws -> UInt64 {
        guard let text = String(data: anchor.rawValue, encoding: .utf8),
              text.hasPrefix("v2:"),
              let value = UInt64(text.dropFirst(3)) else {
            throw ProviderChangeStorageError.invalidAnchor
        }
        return value
    }
}
