import MirageCore
@preconcurrency import FileProvider
import Foundation
import OSLog

/// Mirage 的 macOS replicated File Provider 主入口。
@objc(FileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension,
    NSFileProviderThumbnailing, @unchecked Sendable {
    static let logger = Logger(
        subsystem: "com.wenren.Mirage.FileProvider",
        category: "Extension"
    )

    let domain: NSFileProviderDomain
    let manager: NSFileProviderManager?
    let repository: ProviderRepository
    let catalog: ProviderCatalog
    let tasks = ProviderTaskBag()
    let searchService: ImageSearchService
    let searchCache = ProviderSearchCache()

    /// 每个系统域建立独立扩展实例，并保存对应 manager。
    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let manager = NSFileProviderManager(for: domain)
        self.manager = manager
        let environment = PhotoSearchEnvironment.production()
        self.searchService = environment.imageSearchService(for: .fileProvider)
        let repository = ProviderRepository(manager: manager, environment: environment)
        self.repository = repository
        catalog = ProviderCatalog(repository: repository)
        super.init()
    }

    /// 扩展实例被系统释放前取消所有仍在执行的操作。
    func invalidate() {
        tasks.cancelAll()
        Task { [repository] in await repository.invalidate() }
    }

    /// 为目录、工作集及单条文件订阅创建统一枚举器。
    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> any NSFileProviderEnumerator {
        let scope: ProviderEnumerationScope
        switch containerItemIdentifier {
        case .rootContainer: scope = .root
        case ProviderIdentifiers.avatars: scope = .avatars
        case ProviderIdentifiers.searchBacking: scope = .search
        case ProviderIdentifiers.recent: scope = .recent
        case ProviderIdentifiers.favorites: scope = .favorites
        case .trashContainer:
            // 只读域不支持废纸篓；按 File Provider 契约返回终态 unsupported，不能误报条目已删除。
            throw ProviderError.trashUnsupported()
        case .workingSet: scope = .workingSet
        default:
            if let reference = ProviderIdentifiers.avatarPageReference(
                from: containerItemIdentifier
            ) {
                scope = .avatarPage(reference)
            } else if let reference = ProviderIdentifiers.discoveryPageReference(
                from: containerItemIdentifier
            ) {
                scope = .discoveryPage(reference)
            } else {
                guard ProviderIdentifiers.recordReference(from: containerItemIdentifier) != nil else {
                    throw ProviderError.noSuchItem(containerItemIdentifier)
                }
                scope = .single(containerItemIdentifier)
            }
        }
        return ProviderEnumerator(scope: scope, catalog: catalog)
    }

    /// 查询完整元数据；搜索 ID 会在这里补上隐藏 backing 父目录。
    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let callback = ProviderCallbackBox(completionHandler)
        let relay = ProviderTaskRelay()
        let operationID = UUID()
        tasks.insert(relay, id: operationID)
        let task = Task { [catalog, tasks, relay] in
            defer { tasks.remove(id: operationID) }
            do {
                try Task.checkCancellation()
                guard let item = try await catalog.item(for: identifier) else {
                    throw ProviderError.noSuchItem(identifier)
                }
                try Task.checkCancellation()
                relay.finish({
                    progress.completedUnitCount = 1
                    callback.value(item, nil)
                }, ifCancelled: {
                    callback.value(nil, ProviderError.cancelled())
                })
            } catch is CancellationError {
                relay.finish({
                    callback.value(nil, ProviderError.cancelled())
                }, ifCancelled: {
                    callback.value(nil, ProviderError.cancelled())
                })
            } catch {
                relay.finish({
                    callback.value(nil, error)
                }, ifCancelled: {
                    callback.value(nil, ProviderError.cancelled())
                })
            }
        }
        progress.cancellationHandler = { relay.cancel() }
        relay.install(task)
        return progress
    }

    /// 只读 provider 明确拒绝本地创建，不留下待处理字段。
    func createItem(
        basedOn itemTemplate: any NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Self.logger.error(
            "拒绝创建：name=\(itemTemplate.filename, privacy: .public) parent=\(itemTemplate.parentItemIdentifier.rawValue, privacy: .public) type=\(itemTemplate.contentType?.identifier ?? "-", privacy: .public) requester=\(request.requestingExecutable?.lastPathComponent ?? "-", privacy: .public)"
        )
        completionHandler(nil, [], false, ProviderError.readOnly("创建条目"))
        progress.completedUnitCount = 1
        return progress
    }

    /// 只读 provider 明确拒绝内容、名称与层级修改。
    func modifyItem(
        _ item: any NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        completionHandler(nil, [], false, ProviderError.readOnly("修改条目"))
        progress.completedUnitCount = 1
        return progress
    }

    /// 只读 provider 明确拒绝删除，系统可据此恢复远程版本。
    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        completionHandler(ProviderError.readOnly("删除条目"))
        progress.completedUnitCount = 1
        return progress
    }
}

/// macOS 26 起系统才开放 File Provider 云端字符串搜索；旧系统继续使用已索引根 feed。
@available(macOS 26.0, *)
extension FileProviderExtension: NSFileProviderSearching {
    /// 每次系统字符串请求使用独立枚举器，查询变化即可取消旧任务。
    func searchEnumerator(
        for request: NSFileProviderStringSearchRequest
    ) -> any NSFileProviderSearchEnumerator {
        SearchEnumerator(
            request: request,
            service: searchService,
            repository: repository,
            cache: searchCache,
            manager: manager
        )
    }
}
