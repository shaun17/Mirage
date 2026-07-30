import MirageCore
import FileProvider
import Foundation

/// 将扩展需要的数据视图隔离在单一适配器中，并持有根 feed 的单飞刷新状态。
actor ProviderRepository {
    private static let discoveryCatalogKey = "finder-root-discovery-v1"
    private static let fallbackQueryKey = "mirage-discovery-fallback-v1"
    private static let discoveryTTL: TimeInterval = 60 * 60
    private static let networkTimeout: Duration = .seconds(6)
    private static let discoveryCount = 12
    private static let photoCount = 8
    private static let safeQueries = [
        "portrait person",
        "animal portrait",
        "vintage portrait",
        "botanical portrait"
    ]

    private let storage: AppGroupStorage?
    private let manager: NSFileProviderManager?
    private let openverse: any OpenverseSearching
    private let diceBear: any DiceBearProviding
    private var discoveryRefreshTask: Task<Void, Never>?
    private var discoveryRefreshID: UUID?

    /// App Group 不可用时保留实例，具体请求再返回稳定错误而不是让扩展崩溃。
    init(
        manager: NSFileProviderManager?,
        openverse: any OpenverseSearching = OpenverseClient(),
        diceBear: any DiceBearProviding = DiceBearClient()
    ) {
        storage = try? AppGroupStorage()
        self.manager = manager
        self.openverse = openverse
        self.diceBear = diceBear
    }

    /// 扩展失效时立即取消单飞网络任务，避免旧实例在后台提交迟到快照或发送 signal。
    func invalidate() {
        discoveryRefreshTask?.cancel()
        discoveryRefreshTask = nil
        discoveryRefreshID = nil
    }

    /// 新鲜快照直接返回；旧快照立即返回并在后台单飞刷新；冷启动先提交稳定兜底。
    func discoveryItems(now: Date = Date()) async throws -> [ProviderItem] {
        try Task.checkCancellation()
        let storage = try requireStorage()
        if let snapshot = try await storage.readDiscoveryFeedSnapshot() {
            try Task.checkCancellation()
            if now.timeIntervalSince(snapshot.refreshedAt) >= Self.discoveryTTL {
                startDiscoveryRefresh(previous: snapshot)
            }
            return snapshot.records.map { ProviderItem(record: $0, view: .discover) }
        }

        let records = await Self.fallbackRecords(using: diceBear)
        try Task.checkCancellation()
        let snapshot = try await storage.commitDiscoveryFeed(
            records: records,
            refreshedAt: now,
            source: .fallback,
            catalogKey: Self.discoveryCatalogKey,
            queryKey: Self.fallbackQueryKey
        )
        try Task.checkCancellation()
        // 冷启动不等待网络，Finder 可立即得到固定数量头像；后台请求仍受六秒硬超时约束。
        startDiscoveryRefresh(previous: snapshot)
        return records.map { ProviderItem(record: $0, view: .discover) }
    }

    /// 持久化搜索结果及顺序，扩展重启后隐藏 backing 和 item(for:) 都能恢复。
    func storeSearchResults(_ records: [RemoteImageRecord], queryKey: String) async throws {
        try Task.checkCancellation()
        let storage = try requireStorage()
        try await storage.commitSearchBacking(queryKey: Self.normalizedQuery(queryKey), records: records)
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
            let records = try await storage.readDiscoveryFeedSnapshot()?.records ?? []
            occurrence = records.first { $0.id == reference.recordID }.map {
                ProviderOccurrence(reference: reference, record: $0)
            }
        case .search:
            occurrence = try await storage.readSearchRecord(id: reference.recordID).map {
                ProviderOccurrence(reference: reference, record: $0)
            }
        case .recent:
            let recent = try await storage.readRecent().first { $0.id == reference.recordID }
            occurrence = recent.map {
                ProviderOccurrence(reference: reference, record: $0.image, lastUsedDate: $0.accessedAt)
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

    /// 同一时刻只允许一个根 feed 网络刷新；signal 触发的后续枚举会命中新 TTL。
    private func startDiscoveryRefresh(previous: DiscoveryFeedSnapshot) {
        guard discoveryRefreshTask == nil else { return }
        let refreshID = UUID()
        discoveryRefreshID = refreshID
        discoveryRefreshTask = Task { [self] in
            await performDiscoveryRefresh(previous: previous, refreshID: refreshID)
        }
    }

    /// 在 actor 隔离域内完成刷新与 signal，避免非 Sendable 的系统 manager 跨任务捕获。
    private func performDiscoveryRefresh(previous: DiscoveryFeedSnapshot, refreshID: UUID) async {
        defer {
            if discoveryRefreshID == refreshID {
                discoveryRefreshTask = nil
                discoveryRefreshID = nil
            }
        }
        guard let storage else { return }
        let query = Self.query(after: previous)
        do {
            try Task.checkCancellation()
            let photos = try await Self.searchWithTimeout(
                openverse: openverse,
                query: query,
                count: Self.photoCount
            )
            let accents = await Self.fallbackRecords(using: diceBear)
            try Task.checkCancellation()
            let records = Self.unique(Array(photos.prefix(Self.photoCount)) + accents)
            guard !records.isEmpty else { throw DiscoveryRefreshError.emptyResponse }
            try Task.checkCancellation()
            _ = try await storage.commitDiscoveryFeed(
                records: Array(records.prefix(Self.discoveryCount)),
                refreshedAt: Date(),
                source: .network,
                catalogKey: Self.discoveryCatalogKey,
                queryKey: query
            )
            try Task.checkCancellation()
            try await signalRootAndWorkingSet()
        } catch is CancellationError {
            return
        } catch {
            // 过期网络快照失败时切到固定 fallback；冷启动已是新鲜 fallback，不重复提交或 signal。
            guard !Task.isCancelled else { return }
            guard previous.source != .fallback
                || Date().timeIntervalSince(previous.refreshedAt) >= Self.discoveryTTL else { return }
            let fallback = await Self.fallbackRecords(using: diceBear)
            guard !Task.isCancelled else { return }
            guard (try? await storage.commitDiscoveryFeed(
                records: fallback,
                refreshedAt: Date(),
                source: .fallback,
                catalogKey: Self.discoveryCatalogKey,
                queryKey: Self.fallbackQueryKey
            )) != nil else { return }
            guard !Task.isCancelled else { return }
            try? await signalRootAndWorkingSet()
        }
    }

    /// 用固定 key 生成跨启动完全相同的 fallback occurrence。
    private static func fallbackRecords(using diceBear: any DiceBearProviding) async -> [RemoteImageRecord] {
        await diceBear.avatars(query: fallbackQueryKey, count: discoveryCount)
    }

    /// 每个过期周期只选择一个安全词，因此一次刷新最多一个 Openverse 请求。
    private static func query(after snapshot: DiscoveryFeedSnapshot) -> String {
        safeQueries[Int(snapshot.generation % UInt64(safeQueries.count))]
    }

    /// 竞速网络请求与硬超时，结束后取消另一分支。
    private static func searchWithTimeout(
        openverse: any OpenverseSearching,
        query: String,
        count: Int
    ) async throws -> [RemoteImageRecord] {
        try await withThrowingTaskGroup(of: [RemoteImageRecord].self) { group in
            group.addTask { try await openverse.search(query: query, pageSize: count) }
            group.addTask {
                try await Task.sleep(for: networkTimeout)
                throw DiscoveryRefreshError.timedOut
            }
            guard let first = try await group.next() else { throw DiscoveryRefreshError.emptyResponse }
            group.cancelAll()
            return first
        }
    }

    /// 去重时保留首次出现顺序，避免同一底层记录在一个视图中出现两次。
    private static func unique(_ records: [RemoteImageRecord]) -> [RemoteImageRecord] {
        var seen = Set<String>()
        return records.filter { seen.insert($0.id).inserted }
    }

    /// 根 feed 提交完成后同时唤醒根目录与 working set。
    private func signalRootAndWorkingSet() async throws {
        try Task.checkCancellation()
        guard let manager else { return }
        try? await manager.signalEnumerator(for: .rootContainer)
        try Task.checkCancellation()
        try? await manager.signalEnumerator(for: .workingSet)
        try Task.checkCancellation()
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
}

/// 根 feed 刷新的内部终止原因，外部统一回退到稳定 DiceBear 数据。
private enum DiscoveryRefreshError: Error {
    case timedOut
    case emptyResponse
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
