import Foundation

/// App 与 Finder 读取推荐流时得到的冻结页面。
public struct DiscoveryFeedPage: Sendable {
    public let generation: UInt64
    public let records: [RemoteImageRecord]
    public let nextPage: Int?
    public let didMutateSnapshot: Bool

    public init(
        generation: UInt64,
        records: [RemoteImageRecord],
        nextPage: Int?,
        didMutateSnapshot: Bool
    ) {
        self.generation = generation
        self.records = records
        self.nextPage = nextPage
        self.didMutateSnapshot = didMutateSnapshot
    }
}

/// 推荐流抽象允许 App 状态机和 File Provider 共用实现并注入确定性测试替身。
public protocol DiscoveryFeedProviding: Sendable {
    /// generation 为空时读取当前推荐，非空时严格续读指定冻结代次。
    func page(
        generation: UInt64?,
        page: Int,
        pageSize: Int
    ) async throws -> DiscoveryFeedPage
}

/// App 的混合推荐允许头像兜底；Finder 图片根目录只接受真实照片记录。
public enum DiscoveryFeedContentScope: Sendable {
    case mixed
    case photos
}

/// 推荐页参数不合法或冻结快照已经被历史窗口淘汰。
public enum DiscoveryFeedError: Error, LocalizedError, Equatable, Sendable {
    case invalidPage
    case snapshotExpired

    public var errorDescription: String? {
        switch self {
        case .invalidPage:
            return "推荐分页位置无效。"
        case .snapshotExpired:
            return "推荐内容已经刷新，请从第一页重新加载。"
        }
    }
}

/// 共享推荐仓库负责 TTL、网络超时、离线兜底、分页追加和 generation 冻结。
public actor DiscoveryFeedRepository: DiscoveryFeedProviding {
    private let storage: AppGroupStorage
    private let service: ImageSearchService
    private let avatarProvider: any AvatarProviding
    private let networkTimeout: Duration
    private let now: @Sendable () -> Date
    private let catalogKey: @Sendable () async -> String
    private let contentScope: DiscoveryFeedContentScope
    private let snapshotMutationNotifier: DiscoveryFeedSnapshotMutationNotifier?
    private var inFlightPages: [DiscoveryFeedRequestKey: Task<DiscoveryFeedPage, Error>] = [:]

    public init(
        storage: AppGroupStorage,
        service: ImageSearchService = ImageSearchService(),
        diceBear: any AvatarProviding = AvatarCatalogClient(),
        networkTimeout: Duration = .seconds(6),
        now: @escaping @Sendable () -> Date = Date.init,
        catalogKey: @escaping @Sendable () async -> String = { DiscoveryRecommendation.catalogKey },
        contentScope: DiscoveryFeedContentScope = .mixed,
        snapshotDidChange: (@Sendable () async throws -> Void)? = nil,
        snapshotNotificationRetryDelay: Duration = .seconds(1)
    ) {
        self.storage = storage
        self.service = service
        self.avatarProvider = diceBear
        self.networkTimeout = networkTimeout
        self.now = now
        self.catalogKey = catalogKey
        self.contentScope = contentScope
        self.snapshotMutationNotifier = snapshotDidChange.map {
            DiscoveryFeedSnapshotMutationNotifier(
                signal: $0,
                initialRetryDelay: snapshotNotificationRetryDelay
            )
        }
    }

    /// 生产环境直接打开固定 App Group；失败由调用方决定是否降级为普通搜索。
    public init(
        service: ImageSearchService = ImageSearchService(),
        diceBear: any AvatarProviding = AvatarCatalogClient(),
        networkTimeout: Duration = .seconds(6),
        now: @escaping @Sendable () -> Date = Date.init,
        catalogKey: @escaping @Sendable () async -> String = { DiscoveryRecommendation.catalogKey },
        contentScope: DiscoveryFeedContentScope = .mixed,
        snapshotDidChange: (@Sendable () async throws -> Void)? = nil,
        snapshotNotificationRetryDelay: Duration = .seconds(1)
    ) throws {
        self.storage = try AppGroupStorage()
        self.service = service
        self.avatarProvider = diceBear
        self.networkTimeout = networkTimeout
        self.now = now
        self.catalogKey = catalogKey
        self.contentScope = contentScope
        self.snapshotMutationNotifier = snapshotDidChange.map {
            DiscoveryFeedSnapshotMutationNotifier(
                signal: $0,
                initialRetryDelay: snapshotNotificationRetryDelay
            )
        }
    }

    /// 优先切出已缓存页面；只有走到当前快照尾部时才发起下一次网络请求。
    public func page(
        generation requestedGeneration: UInt64?,
        page requestedPage: Int,
        pageSize: Int
    ) async throws -> DiscoveryFeedPage {
        let expectedCatalogKey = await catalogKey()
        let key = DiscoveryFeedRequestKey(
            generation: requestedGeneration,
            page: requestedPage,
            pageSize: pageSize,
            catalogKey: expectedCatalogKey
        )
        if let existing = inFlightPages[key] {
            let result = try await existing.value
            try Task.checkCancellation()
            return result
        }
        let task = Task { [self] in
            try await resolvePage(
                generation: requestedGeneration,
                page: requestedPage,
                pageSize: pageSize,
                catalogKey: expectedCatalogKey
            )
        }
        inFlightPages[key] = task
        do {
            let result = try await task.value
            inFlightPages[key] = nil
            try Task.checkCancellation()
            return result
        } catch {
            inFlightPages[key] = nil
            throw error
        }
    }

    /// 同一请求的实际解析只由 single-flight 任务执行一次，避免锚点与枚举并发重复联网。
    private func resolvePage(
        generation requestedGeneration: UInt64?,
        page requestedPage: Int,
        pageSize: Int,
        catalogKey expectedCatalogKey: String
    ) async throws -> DiscoveryFeedPage {
        try Self.validate(page: requestedPage, pageSize: pageSize)
        let snapshot: DiscoveryFeedSnapshot
        let initialMutation: Bool
        if let requestedGeneration {
            guard let frozen = try await storage.readDiscoveryFeedSnapshot(
                generation: requestedGeneration
            ) else {
                throw DiscoveryFeedError.snapshotExpired
            }
            snapshot = try Self.validated(
                frozen,
                pageSize: pageSize,
                catalogKey: expectedCatalogKey
            )
            initialMutation = false
        } else {
            let current = try await currentSnapshot(
                pageSize: pageSize,
                catalogKey: expectedCatalogKey
            )
            snapshot = current.snapshot
            initialMutation = current.didMutate
        }

        if let cached = try Self.cachedPage(
            in: snapshot,
            page: requestedPage,
            pageSize: pageSize,
            didMutate: initialMutation
        ) {
            return cached
        }

        guard snapshot.nextPage == requestedPage else {
            throw DiscoveryFeedError.invalidPage
        }
        let offset = try Self.offset(page: requestedPage, pageSize: pageSize)
        let loaded = try await loadPage(
            at: Self.remoteCursor(for: snapshot),
            logicalPage: requestedPage,
            pageSize: pageSize,
            excluding: Set(snapshot.records.map(\.id))
        )
        try Task.checkCancellation()
        let updated = try await storage.appendDiscoveryFeed(
            generation: snapshot.generation,
            expectedNextPage: requestedPage,
            expectedRecordCount: offset,
            records: loaded.records,
            nextPage: Self.logicalNextPage(after: requestedPage, hasMore: loaded.nextCursor != nil),
            remoteCursor: loaded.nextCursor
        )
        let didMutateSnapshot = updated != snapshot
        if didMutateSnapshot {
            await snapshotMutationNotifier?.setNeedsSignal()
        }
        // CAS 输家必须从赢家快照取页和游标，不能泄漏自己已被拒绝的网络结果。
        guard let resolved = try Self.cachedPage(
            in: updated,
            page: requestedPage,
            pageSize: pageSize,
            didMutate: didMutateSnapshot
        ) else {
            throw DiscoveryFeedError.invalidPage
        }
        return resolved
    }

    /// 新鲜且版本匹配的当前快照直接复用，否则同步创建新的第一页 generation。
    private func currentSnapshot(
        pageSize: Int,
        catalogKey expectedCatalogKey: String
    ) async throws -> (snapshot: DiscoveryFeedSnapshot, didMutate: Bool) {
        let observed = try await storage.readDiscoveryFeedSnapshot()
        if let observed,
           Self.isReusable(
               observed,
               now: now(),
               pageSize: pageSize,
               catalogKey: expectedCatalogKey
           ) {
            return (observed, false)
        }

        let loaded = try await loadPage(
            at: DiscoveryRemoteCursor(queryIndex: 0, remotePage: 1),
            logicalPage: 1,
            pageSize: pageSize,
            excluding: []
        )
        try Task.checkCancellation()
        let result = try await storage.commitDiscoveryFeedIfCurrent(
            expectedGeneration: observed?.generation,
            records: loaded.records,
            refreshedAt: now(),
            source: loaded.source,
            catalogKey: expectedCatalogKey,
            queryKey: DiscoveryRecommendation.query,
            pageSize: pageSize,
            nextPage: Self.logicalNextPage(after: 1, hasMore: loaded.nextCursor != nil),
            remoteCursor: loaded.nextCursor
        )
        switch result {
        case let .committed(committed):
            await snapshotMutationNotifier?.setNeedsSignal()
            return (committed, true)
        case let .superseded(current):
            // 跨进程竞速输家必须直接采用胜者首页，不能把自己的迟到网络结果再次提交。
            guard let current,
                  Self.isReusable(
                      current,
                      now: now(),
                      pageSize: pageSize,
                      catalogKey: expectedCatalogKey
                  ) else {
                throw DiscoveryFeedError.snapshotExpired
            }
            return (current, false)
        }
    }

    /// 网络页必须在调用方预算内完成；只有混合推荐允许用头像补齐或兜底。
    /// 游标决定「向哪个关键词的第几页」抓取；逻辑页只用于混合流的稳定 seed 区间。
    private func loadPage(
        at cursor: DiscoveryRemoteCursor,
        logicalPage: Int,
        pageSize: Int,
        excluding existingIDs: Set<String>
    ) async throws -> LoadedDiscoveryPage {
        let catalog = DiscoveryRecommendation.queries
        guard catalog.indices.contains(cursor.queryIndex), cursor.remotePage >= 1 else {
            guard contentScope == .mixed else {
                throw DiscoveryFeedError.snapshotExpired
            }
            // 目录跨版本收缩或游标损坏：用兜底头像收满本页并终结推荐流，而不是崩溃或重放。
            let records = await fallbackRecords(
                page: logicalPage,
                pageSize: pageSize,
                excluding: existingIDs
            )
            return LoadedDiscoveryPage(records: records, nextCursor: nil, source: .fallback)
        }
        do {
            let response = try await Self.searchWithTimeout(
                service: service,
                query: serviceQuery(for: catalog[cursor.queryIndex]),
                cursor: cursor,
                pageSize: pageSize,
                timeout: networkTimeout
            )
            try Task.checkCancellation()
            let records = await completePage(
                response.records,
                page: logicalPage,
                pageSize: pageSize,
                excluding: existingIDs
            )
            let nextCursor = contentScope == .photos && records.count < pageSize
                ? nil
                : Self.advancedCursor(
                    after: cursor,
                    nextImageCursor: response.nextCursor,
                    catalogCount: catalog.count
                )
            return LoadedDiscoveryPage(
                records: records,
                nextCursor: nextCursor,
                source: .network
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error {
            guard contentScope == .mixed else { throw error }
            // 远端失败只影响本逻辑页：兜底头像保持流动，远端位置不被消费，下一页原地重试。
            let records = await fallbackRecords(
                page: logicalPage,
                pageSize: pageSize,
                excluding: existingIDs
            )
            return LoadedDiscoveryPage(records: records, nextCursor: cursor, source: .fallback)
        }
    }

    /// 当前关键词还有远端续页就前进一页，否则切到下一关键词的第一页；目录耗尽即整条流耗尽。
    private static func advancedCursor(
        after cursor: DiscoveryRemoteCursor,
        nextImageCursor: ImageSearchCursor?,
        catalogCount: Int
    ) -> DiscoveryRemoteCursor? {
        if let nextImageCursor {
            return DiscoveryRemoteCursor(
                queryIndex: cursor.queryIndex,
                remotePage: nextImageCursor.page,
                imageCursor: nextImageCursor
            )
        }
        let nextIndex = cursor.queryIndex + 1
        guard nextIndex < catalogCount else { return nil }
        return DiscoveryRemoteCursor(queryIndex: nextIndex, remotePage: 1)
    }

    /// v3 及更早的快照没有游标；退化为「单关键词、逻辑页=远端页」的旧语义继续续读。
    private static func remoteCursor(for snapshot: DiscoveryFeedSnapshot) -> DiscoveryRemoteCursor {
        snapshot.remoteCursor
            ?? DiscoveryRemoteCursor(queryIndex: 0, remotePage: snapshot.nextPage ?? 1)
    }

    /// 安全过滤或跨页重复造成不足时，用不同 seed 区间补齐到 20 条。
    private func completePage(
        _ candidates: [RemoteImageRecord],
        page: Int,
        pageSize: Int,
        excluding existingIDs: Set<String>
    ) async -> [RemoteImageRecord] {
        var seen = existingIDs
        var records = candidates.filter {
            let isAllowed = contentScope == .mixed
                || (!$0.source.isAvatarSource && $0.source != .giphy)
            return isAllowed && seen.insert($0.id).inserted
        }
        guard records.count < pageSize else { return Array(records.prefix(pageSize)) }
        guard contentScope == .mixed else { return records }
        let fillers = await fallbackRecords(
            page: page,
            pageSize: pageSize,
            excluding: seen
        )
        for record in fillers where records.count < pageSize && seen.insert(record.id).inserted {
            records.append(record)
        }
        return records
    }

    /// 显式图片前缀使统一搜索服务跳过 automatic 分支，根目录不会混入头像补位。
    private func serviceQuery(for query: String) -> String {
        contentScope == .photos ? "图片:\(query)" : query
    }

    /// 本地兜底根据绝对页偏移生成稳定且跨页不重复的头像记录。
    private func fallbackRecords(
        page: Int,
        pageSize: Int,
        excluding existingIDs: Set<String>
    ) async -> [RemoteImageRecord] {
        let pageOffset = (try? Self.offset(page: page, pageSize: pageSize)) ?? 0
        let candidates = await avatarProvider.avatars(
            query: DiscoveryRecommendation.fallbackSeed,
            offset: pageOffset,
            count: pageSize
        )
        var seen = existingIDs
        return candidates.filter { seen.insert($0.id).inserted }
    }

    /// 从冻结记录数组切出指定页，并根据缓存尾部和远端游标计算下一页。
    private static func cachedPage(
        in snapshot: DiscoveryFeedSnapshot,
        page: Int,
        pageSize: Int,
        didMutate: Bool
    ) throws -> DiscoveryFeedPage? {
        let lowerBound = try offset(page: page, pageSize: pageSize)
        guard lowerBound < snapshot.records.count else { return nil }
        let upperBound = min(lowerBound + pageSize, snapshot.records.count)
        let nextPage = upperBound < snapshot.records.count ? page + 1 : snapshot.nextPage
        return DiscoveryFeedPage(
            generation: snapshot.generation,
            records: Array(snapshot.records[lowerBound..<upperBound]),
            nextPage: nextPage,
            didMutateSnapshot: didMutate
        )
    }

    /// 只有当前 schema、固定查询、固定页大小和一小时 TTL 全部匹配才复用。
    private static func isReusable(
        _ snapshot: DiscoveryFeedSnapshot,
        now: Date,
        pageSize: Int,
        catalogKey expectedCatalogKey: String
    ) -> Bool {
        let age = now.timeIntervalSince(snapshot.refreshedAt)
        return snapshot.catalogKey == expectedCatalogKey
            && snapshot.queryKey == DiscoveryRecommendation.query
            && snapshot.pageSize == pageSize
            && !snapshot.records.isEmpty
            && age >= -30
            && age < DiscoveryRecommendation.refreshInterval
    }

    /// 冻结续页不再检查 TTL，但必须属于当前推荐 schema 与固定页大小。
    private static func validated(
        _ snapshot: DiscoveryFeedSnapshot,
        pageSize: Int,
        catalogKey expectedCatalogKey: String
    ) throws -> DiscoveryFeedSnapshot {
        guard snapshot.catalogKey == expectedCatalogKey,
              snapshot.queryKey == DiscoveryRecommendation.query,
              snapshot.pageSize == pageSize else {
            throw DiscoveryFeedError.snapshotExpired
        }
        return snapshot
    }

    /// 计算页在累计记录中的绝对偏移，拒绝整数溢出。
    private static func offset(page: Int, pageSize: Int) throws -> Int {
        let value = (page - 1).multipliedReportingOverflow(by: pageSize)
        guard !value.overflow else { throw DiscoveryFeedError.invalidPage }
        return value.partialValue
    }

    /// 目录树使用连续逻辑页；游标只决定是否还有内容，不能跳过本地父目录层级。
    private static func logicalNextPage(after page: Int, hasMore: Bool) -> Int? {
        guard hasMore, page < SearchPaginationCursor.maximumPage else { return nil }
        return page + 1
    }

    /// 所有入口统一限制为产品定义的 20 张页面和安全页码范围。
    private static func validate(page: Int, pageSize: Int) throws {
        guard (1...SearchPaginationCursor.maximumPage).contains(page),
              pageSize == DiscoveryRecommendation.pageSize else {
            throw DiscoveryFeedError.invalidPage
        }
    }

    /// 竞速远端请求与硬超时，首个完成分支决定本页是否采用离线兜底。
    private static func searchWithTimeout(
        service: ImageSearchService,
        query: String,
        cursor: DiscoveryRemoteCursor,
        pageSize: Int,
        timeout: Duration
    ) async throws -> ImageSearchPage {
        try await withThrowingTaskGroup(of: ImageSearchPage.self) { group in
            group.addTask {
                if let imageCursor = cursor.imageCursor {
                    return try await service.search(query, cursor: imageCursor, pageSize: pageSize)
                }
                if cursor.remotePage == 1 {
                    return try await service.search(query, cursor: nil, pageSize: pageSize)
                }
                // 兼容 v5 及更早只保存远端页码的快照；新快照始终走完整游标。
                return try await service.search(query, page: cursor.remotePage, pageSize: pageSize)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DiscoveryFeedNetworkError.timedOut
            }
            guard let first = try await group.next() else {
                throw DiscoveryFeedNetworkError.emptyResponse
            }
            group.cancelAll()
            return first
        }
    }
}

/// 推荐页 single-flight 键同时包含 generation 与页大小，测试替身不会误共享不同请求。
private struct DiscoveryFeedRequestKey: Hashable, Sendable {
    let generation: UInt64?
    let page: Int
    let pageSize: Int
    let catalogKey: String
}

/// 仓库内部保留本页来源与下一次远端抓取位置；游标为空表示整个关键词目录耗尽。
private struct LoadedDiscoveryPage {
    let records: [RemoteImageRecord]
    let nextCursor: DiscoveryRemoteCursor?
    let source: DiscoveryFeedSource
}

/// 远端请求在推荐流的有界时间内未给出可用响应。
private enum DiscoveryFeedNetworkError: Error {
    case timedOut
    case emptyResponse
}
