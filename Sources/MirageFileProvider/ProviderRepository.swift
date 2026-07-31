import MirageCore
import FileProvider
import Foundation
import OSLog

/// 将扩展需要的数据视图隔离在单一适配器中，并复用 Core 的共享推荐仓库。
actor ProviderRepository: ProviderSearchResultStoring {
    private static let logger = Logger(
        subsystem: "com.wenren.Mirage.FileProvider",
        category: "Repository"
    )

    private let storage: AppGroupStorage?
    private let manager: NSFileProviderManager?
    private let discoveryFeed: (any DiscoveryFeedProviding)?

    /// App Group 不可用时保留实例，具体请求再返回稳定错误而不是让扩展崩溃。
    init(
        manager: NSFileProviderManager?,
        openverse: any OpenverseSearching = OpenverseClient(),
        diceBear: any DiceBearProviding = DiceBearClient()
    ) {
        let storage = try? AppGroupStorage()
        self.storage = storage
        self.manager = manager
        self.discoveryFeed = storage.map {
            DiscoveryFeedRepository(
                storage: $0,
                service: ImageSearchService(openverse: openverse, diceBear: diceBear),
                diceBear: diceBear
            )
        }
    }

    /// 测试注入共享存储与推荐仓库，验证 File Provider 位置语义而不访问真实 App Group。
    init(
        manager: NSFileProviderManager?,
        storage: AppGroupStorage,
        discoveryFeed: any DiscoveryFeedProviding
    ) {
        self.storage = storage
        self.manager = manager
        self.discoveryFeed = discoveryFeed
    }

    /// 推荐仓库只运行结构化调用任务，扩展失效时无需维护额外游离任务。
    func invalidate() {}

    /// 根目录现在投影当前 generation 已累积的全部记录，滚动补页只是把这个数组变长。
    ///
    /// `minimumRecords` 会在本次调用内就地补齐首屏。这是必须的：内容一旦同步进系统副本，
    /// macOS 就不再回问扩展——`signalEnumerator` 之后也等不到新的枚举。
    /// 只有让第一次枚举就返回足够长的列表，用户才有未缓存的条目可滚，
    /// 后续的缩略图水位才能接管并自持地继续增长。
    func discoveryRootFeed(minimumRecords: Int = 0) async throws -> DiscoveryRootFeed {
        // 先确保当前 generation 存在且未过 TTL；首页提交同时负责换代时唤醒系统。
        var feed = try await currentDiscoveryRootFeed()
        var inlinePages = 0
        while feed.records.count < minimumRecords,
              let nextPage = feed.nextPage,
              inlinePages < Self.maximumInlineFillPages {
            try Task.checkCancellation()
            _ = try await loadDiscoveryPage(generation: feed.generation, page: nextPage)
            inlinePages += 1
            feed = try await currentDiscoveryRootFeed()
        }
        return feed
    }

    /// 首屏就地补齐的页数上限。
    ///
    /// 这个值必须足够大：macOS 的 replicated 副本一旦建成就再也无法增长——
    /// `signalEnumerator` 不触发重新枚举，`reimportItems` 报告完成却不回问扩展，
    /// 实测只有重新注册域才会让副本按完整列表重建。
    /// 所以「第一次枚举交付多少」就是用户能看到的全部，必须在这里一次给够。
    /// 代价是首次建域时最多 10 次串行网络请求；这些页随后进快照缓存，之后的枚举只读盘。
    private static let maximumInlineFillPages = 10

    /// 读取当前冻结 generation 的完整累积顺序。
    private func currentDiscoveryRootFeed() async throws -> DiscoveryRootFeed {
        let first = try await loadDiscoveryPage(generation: nil, page: 1)
        try Task.checkCancellation()
        let storage = try requireStorage()
        guard let snapshot = try await storage.readDiscoveryFeedSnapshot(
            generation: first.generation
        ), !snapshot.records.isEmpty else {
            return DiscoveryRootFeed(
                generation: first.generation,
                records: first.records,
                nextPage: first.nextPage
            )
        }
        try Task.checkCancellation()
        return DiscoveryRootFeed(
            generation: snapshot.generation,
            records: snapshot.records,
            nextPage: snapshot.nextPage
        )
    }

    /// 把下一页追加进当前 generation；返回追加后是否仍有后续内容。
    func advanceDiscoveryFeed() async throws -> Bool {
        let feed = try await discoveryRootFeed()
        try Task.checkCancellation()
        guard let nextPage = feed.nextPage else { return false }
        let page = try await loadDiscoveryPage(generation: feed.generation, page: nextPage)
        try Task.checkCancellation()
        return page.nextPage != nil
    }

    /// 轻量通知系统拉取根目录差异：系统走 `enumerateChanges` 原地追加，
    /// 不清缩略图、不闪屏，是常规补页后的唯一发布手段。
    func signalDiscoveryFeedChanged() async {
        guard let manager else { return }
        try? await manager.signalEnumerator(for: .rootContainer)
        try? await manager.signalEnumerator(for: .workingSet)
    }

    /// 要求系统整树重扫。
    ///
    /// 重扫会让系统为整个目录重新请求缩略图（实测冷启动时可扫到第 842 项），
    /// 在把缩略图当滚动信号的架构里，这些请求会被误读成「用户滚到了底部」，
    /// 形成「重扫→全量缩略图→补页→再重扫」的自激循环——Finder 表现为空白页反复闪动。
    /// 因此它绝不能进常规发布路径，只能在增量 signal 反复无效时作为修复手段。
    func rescanDiscoveryFeed() async {
        guard let manager else { return }
        do {
            try manager.reimportItems(below: .rootContainer) { error in
                if let error {
                    Self.logger.error("重扫失败：\(error.localizedDescription, privacy: .public)")
                } else {
                    Self.logger.notice("重扫已完成")
                }
            }
            Self.logger.notice("已请求重扫根目录")
        } catch {
            Self.logger.error("重扫请求被拒绝：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 按指定 generation 读取或补齐单页，并将结果落成可跨进程恢复的页快照。
    private func loadDiscoveryPage(
        generation: UInt64?,
        page: Int
    ) async throws -> DiscoveryFeedPage {
        try Task.checkCancellation()
        let storage = try requireStorage()
        do {
            // 历史空页或残页不能直接呈现；忽略后交给完整 generation 重新补齐为 20 张。
            if let generation,
               let cached = try await storage.readDiscoveryPageSnapshot(
                   generation: generation,
                   page: page
               ),
               cached.records.count == DiscoveryRecommendation.pageSize {
                try Task.checkCancellation()
                return DiscoveryFeedPage(
                    generation: cached.generation,
                    records: cached.records,
                    nextPage: cached.nextPage,
                    didMutateSnapshot: false
                )
            }
            let feed = try requireDiscoveryFeed()
            let result = try await feed.page(
                generation: generation,
                page: page,
                pageSize: DiscoveryRecommendation.pageSize
            )
            try Task.checkCancellation()
            _ = try await storage.commitDiscoveryPageSnapshot(
                generation: result.generation,
                page: page,
                records: result.records,
                nextPage: result.nextPage
            )
            try Task.checkCancellation()
            if page == 1, result.didMutateSnapshot {
                try await signalDiscoverySnapshotChanged(storage: storage)
            }
            return result
        } catch is DiscoveryFeedError {
            throw ProviderError.expiredDiscoveryPage()
        } catch is DiscoveryFeedStorageError {
            throw ProviderError.expiredDiscoveryPage()
        }
    }

    /// 推荐换代后唤醒根目录与工作集，稳定 ID 才能产生正确的更新与删除差异。
    private func signalDiscoverySnapshotChanged(storage: AppGroupStorage) async throws {
        guard let manager else { return }
        try? await manager.signalEnumerator(for: .rootContainer)
        try Task.checkCancellation()
        try? await manager.signalEnumerator(for: .workingSet)
        try Task.checkCancellation()
    }

    /// 持久化搜索结果及顺序，扩展重启后隐藏 backing 和 item(for:) 都能恢复。
    func storeSearchResults(
        _ records: [RemoteImageRecord],
        queryKey: String,
        appending: Bool = false
    ) async throws {
        try Task.checkCancellation()
        let storage = try requireStorage()
        try await storage.commitSearchBacking(
            queryKey: Self.normalizedQuery(queryKey),
            records: records,
            appending: appending
        )
        try Task.checkCancellation()
    }

    /// 根据 occurrence 视图读取对应权威快照，绝不让同 ID 的其他视图元数据覆盖当前条目。
    func record(for identifier: NSFileProviderItemIdentifier) async throws -> RemoteImageRecord? {
        try await occurrence(for: identifier)?.record
    }

    /// 一次读取同时解析记录与最近时间，避免 recent 条目的内容和元数据来自两次不同快照。
    func occurrence(for identifier: NSFileProviderItemIdentifier) async throws -> ProviderOccurrence? {
        try Task.checkCancellation()
        guard let reference = ProviderIdentifiers.recordReference(from: identifier) else { return nil }
        let storage = try requireStorage()
        let occurrence: ProviderOccurrence?
        switch reference.view {
        case .discover:
            occurrence = try await storage.readDiscoveryRecord(id: reference.recordID).map {
                ProviderOccurrence(reference: reference, record: $0)
            }
        case .search:
            occurrence = try await storage.readSearchRecord(id: reference.recordID).map {
                ProviderOccurrence(reference: reference, record: $0)
            }
        case .recent:
            let recent = try await storage.readRecent().first { $0.id == reference.recordID }
            occurrence = recent.map {
                ProviderOccurrence(
                    reference: reference,
                    record: $0.image,
                    lastUsedDate: $0.accessedAt
                )
            }
        case .favorite:
            let records = try await storage.readFavoriteRecords()
            occurrence = records.first { $0.id == reference.recordID }.map {
                ProviderOccurrence(reference: reference, record: $0)
            }
        }
        try Task.checkCancellation()
        return occurrence
    }

    /// 每次从持久化搜索快照恢复，确保其他扩展进程的最新原子提交不会被内存缓存遮蔽。
    func cachedSearchItems() async throws -> [ProviderItem] {
        try Task.checkCancellation()
        let records = try await requireStorage().readSearchBackingRecords()
        try Task.checkCancellation()
        return records.map { ProviderItem(record: $0, view: .search) }
    }

    /// 最近使用条目保持 Core 中的访问时间倒序。
    func recentItems() async throws -> [ProviderItem] {
        try Task.checkCancellation()
        let records = try await requireStorage().readRecent()
        try Task.checkCancellation()
        return records.map {
            ProviderItem(record: $0.image, view: .recent, lastUsedDate: $0.accessedAt)
        }
    }

    /// 收藏顺序和内容都来自 favorites 内嵌快照，不再回退到可被其他视图改写的全局 items。
    func favoriteItems() async throws -> [ProviderItem] {
        try Task.checkCancellation()
        let records = try await requireStorage().readFavoriteRecords()
        try Task.checkCancellation()
        return records.map { ProviderItem(record: $0, view: .favorite) }
    }

    /// 成功物化图片后记录最近使用，底层元数据继续保留供其他 occurrence 和在途请求使用。
    func markRecent(_ record: RemoteImageRecord) async throws {
        try Task.checkCancellation()
        try await requireStorage().writeRecent(record)
        try Task.checkCancellation()
    }

    /// 将当前 scope 的 occurrence 版本提交到持久化差异日志。
    func commitScope(_ scopeKey: String, items: [ProviderItem], migratesLegacySearch: Bool) async throws -> UInt64 {
        try Task.checkCancellation()
        let storage = try requireStorage()
        let legacyDeleted: [String]
        if migratesLegacySearch {
            legacyDeleted = try await storage.readRecoverableItemIDs().map {
                ProviderIdentifiers.itemIdentifier(recordID: $0, view: .search).rawValue
            }
        } else {
            legacyDeleted = []
        }
        try Task.checkCancellation()
        let states = items.map {
            ProviderStoredItemState(identifier: $0.itemIdentifier.rawValue, fingerprint: $0.changeFingerprint)
        }
        let anchor = try await storage.commitProviderScope(
            scopeKey,
            items: states,
            initialDeletedIdentifiers: legacyDeleted
        )
        try Task.checkCancellation()
        return anchor
    }

    /// 从持久化日志读取合并后的 scope 差异。
    func changes(in scopeKey: String, after anchor: UInt64) async throws -> ProviderStoredChanges {
        try Task.checkCancellation()
        let changes = try await requireStorage().providerChanges(in: scopeKey, after: anchor)
        try Task.checkCancellation()
        return changes
    }

    /// 读取跨启动单调递增的全局锚点。
    func currentAnchor() async throws -> UInt64 {
        try Task.checkCancellation()
        let anchor = try await requireStorage().currentProviderAnchor()
        try Task.checkCancellation()
        return anchor
    }

    /// 查询 key 只用于恢复顺序，不保留无意义的空白与大小写差异。
    private static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 把 App Group 初始化失败转换为允许 File Provider 退避重试的错误。
    private func requireStorage() throws -> AppGroupStorage {
        guard let storage else {
            throw ProviderError.serverUnreachable("无法访问 Mirage 共享存储。")
        }
        return storage
    }

    /// 把共享推荐仓库初始化失败转换为 File Provider 可退避的服务错误。
    private func requireDiscoveryFeed() throws -> any DiscoveryFeedProviding {
        guard let discoveryFeed else {
            throw ProviderError.serverUnreachable("无法访问 Mirage 推荐存储。")
        }
        return discoveryFeed
    }
}

/// occurrence 的内容与视图元数据来自同一次权威快照读取。
struct ProviderOccurrence: Sendable {
    let reference: RecordReference
    let record: RemoteImageRecord
    let lastUsedDate: Date?

    /// 非 recent 视图没有独立的最近使用时间。
    init(reference: RecordReference, record: RemoteImageRecord, lastUsedDate: Date? = nil) {
        self.reference = reference
        self.record = record
        self.lastUsedDate = lastUsedDate
    }
}

/// 根目录当前可发布的完整推荐序列；`nextPage` 为空表示远端已无更多内容。
struct DiscoveryRootFeed: Sendable {
    let generation: UInt64
    let records: [RemoteImageRecord]
    let nextPage: Int?

    /// 泵只关心还能不能继续补页，不需要理解具体页码。
    var hasMore: Bool { nextPage != nil }
}
