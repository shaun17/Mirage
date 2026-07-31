import MirageCore
@preconcurrency import FileProvider
import Foundation
import OSLog

/// 为一次系统字符串请求执行防抖搜索并缓存结果。
@available(macOS 26.0, *)
final class SearchEnumerator: NSObject, NSFileProviderSearchEnumerator, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.wenren.Mirage.FileProvider",
        category: "Search"
    )
    private let request: NSFileProviderStringSearchRequest
    private let service: ImageSearchService
    private let repository: any ProviderSearchResultStoring
    private let cache: ProviderSearchCache
    private let manager: NSFileProviderManager?
    private let tasks = ProviderTaskBag()

    init(
        request: NSFileProviderStringSearchRequest,
        service: ImageSearchService,
        repository: any ProviderSearchResultStoring,
        cache: ProviderSearchCache,
        manager: NSFileProviderManager?
    ) {
        self.request = request
        self.service = service
        self.repository = repository
        self.cache = cache
        self.manager = manager
        super.init()
    }

    /// 用户修改查询或关闭搜索时取消防抖与网络任务。
    func invalidate() {
        tasks.cancelAll()
    }

    /// 查询前缀后的正文非空才访问服务，约 400ms 防抖避免每个按键都发请求。
    func enumerateSearchResults(
        for observer: any NSFileProviderSearchEnumerationObserver,
        startingAt page: NSFileProviderPage?
    ) {
        let relay = ProviderTaskRelay()
        let taskID = UUID()
        tasks.insert(relay, id: taskID)
        let task = Task { [request, service, repository, cache, manager, relay, tasks] in
            defer { tasks.remove(id: taskID) }
            do {
                try Task.checkCancellation()
                let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsedQuery = SearchQueryParser.parse(query)
                Self.logger.notice(
                    "收到系统搜索请求，有效长度：\(parsedQuery.text.count, privacy: .public)"
                )
                // 必须检查解析后的正文，避免拒绝“猫”或把仅有“图片:”前缀误当成有效查询。
                guard !parsedQuery.text.isEmpty else {
                    try Task.checkCancellation()
                    relay.finish({
                        observer.didEnumerate([])
                        observer.finishEnumerating(upTo: nil)
                    }, ifCancelled: {
                        observer.finishEnumeratingWithError(ProviderError.cancelled())
                    })
                    return
                }
                let cursor = try SearchPagePlanner.cursor(startingAt: page, request: request, observer: observer)
                let pageResult: ImageSearchPage
                if let cached = await cache.page(
                    for: query,
                    page: cursor.page,
                    pageSize: cursor.pageSize
                ) {
                    try Task.checkCancellation()
                    pageResult = cached
                } else {
                    if let remaining = await cache.remainingRateLimit() {
                        try Task.checkCancellation()
                        throw ProviderError.serverUnreachable(
                            "搜索请求正在退避，请在约 \(Int(ceil(remaining))) 秒后重试。"
                        )
                    }
                    try Task.checkCancellation()
                    if cursor.delivered == 0 {
                        try await Task.sleep(for: .milliseconds(400))
                    }
                    pageResult = try await service.search(
                        query,
                        page: cursor.page,
                        pageSize: cursor.pageSize
                    )
                    try Task.checkCancellation()
                    await cache.store(
                        pageResult,
                        for: query,
                        page: cursor.page,
                        pageSize: cursor.pageSize
                    )
                    try Task.checkCancellation()
                }
                try Task.checkCancellation()
                let visibleRecords = Array(pageResult.records.prefix(cursor.pageSize))
                let delivered = try SearchPagePlanner.deliveredCount(
                    after: cursor,
                    adding: visibleRecords.count
                )
                let nextPage = try SearchPagePlanner.nextPage(
                    after: pageResult,
                    cursor: cursor,
                    delivered: delivered
                )
                // 搜索 backing 是后续 item(for:) 的权威来源；取消与提交必须原子二选一。
                try Task.checkCancellation()
                guard relay.beginNonCancellableCompletion() else { throw CancellationError() }
                // 从这里起迟到取消不会再终止任务，保证不会出现“已写 backing 却回调取消”。
                try await repository.storeSearchResults(
                    visibleRecords,
                    queryKey: query,
                    appending: cursor.delivered > 0
                )
                if let manager {
                    try? await manager.signalEnumerator(for: .workingSet)
                }
                Self.logger.notice("搜索完成，返回：\(visibleRecords.count, privacy: .public)")
                let results = visibleRecords.map(SearchResult.init)
                relay.finish({
                    observer.didEnumerate(results)
                    observer.finishEnumerating(upTo: nextPage)
                }, ifCancelled: {
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                })
            } catch is CancellationError {
                Self.logger.notice("系统搜索请求已取消")
                relay.finish({
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                }, ifCancelled: {
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                })
            } catch let error as OpenverseError {
                if case let .rateLimited(retryAfter) = error {
                    await cache.recordRateLimit(retryAfter: retryAfter)
                }
                Self.logger.error("搜索服务错误：\(error.localizedDescription, privacy: .public)")
                relay.finish({
                    observer.finishEnumeratingWithError(Self.searchError(error))
                }, ifCancelled: {
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                })
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled {
                    relay.finish({
                        observer.finishEnumeratingWithError(ProviderError.cancelled())
                    }, ifCancelled: {
                        observer.finishEnumeratingWithError(ProviderError.cancelled())
                    })
                    return
                }
                Self.logger.error("搜索网络错误：\(error.localizedDescription, privacy: .public)")
                relay.finish({
                    observer.finishEnumeratingWithError(
                        ProviderError.serverUnreachable("搜索网络错误：\(error.localizedDescription)")
                    )
                }, ifCancelled: {
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                })
            } catch {
                if Task.isCancelled {
                    relay.finish({
                        observer.finishEnumeratingWithError(ProviderError.cancelled())
                    }, ifCancelled: {
                        observer.finishEnumeratingWithError(ProviderError.cancelled())
                    })
                    return
                }
                Self.logger.error("搜索失败：\(error.localizedDescription, privacy: .public)")
                relay.finish({
                    observer.finishEnumeratingWithError(error)
                }, ifCancelled: {
                    observer.finishEnumeratingWithError(ProviderError.cancelled())
                })
            }
        }
        relay.install(task)
    }

    /// 限流保留具体提示，其余远端错误统一允许系统稍后重试。
    private static func searchError(_ error: OpenverseError) -> Error {
        switch error {
        case let .rateLimited(retryAfter):
            let suffix = retryAfter.map { "，约 \(Int($0)) 秒后可重试" } ?? ""
            return ProviderError.serverUnreachable("搜索请求过于频繁\(suffix)。")
        case let .network(message):
            return ProviderError.serverUnreachable(message)
        case let .invalidResponse(statusCode):
            return ProviderError.serverUnreachable("搜索服务返回 HTTP \(statusCode)。")
        case let .decoding(message):
            return ProviderError.serverUnreachable("搜索结果无法解析：\(message)")
        }
    }
}
