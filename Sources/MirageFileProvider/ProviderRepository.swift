import MirageCore
import FileProvider
import Foundation

/// 将扩展需要的数据视图隔离在单一适配器中，并复用 Core 的共享推荐仓库。
actor ProviderRepository: ProviderSearchResultStoring {
    private let storage: AppGroupStorage?
    private let manager: NSFileProviderManager?
    private let discoveryFeed: (any DiscoveryFeedProviding)?
    private let diceBear: any DiceBearProviding
    private let sourcePreferences: (any PhotoSourcePreferencesReading)?

    /// Finder 的头像分类与 Mirage App 默认头像使用同一固定查询；分段大小受 DiceBear 单次 20 条限制。
    private static let avatarChunks = [(offset: 0, count: 20), (offset: 20, count: 20), (offset: 40, count: 10)]
    private static let avatarItemCount = 50

    /// App Group 不可用时保留实例，具体请求再返回稳定错误而不是让扩展崩溃。
    init(
        manager: NSFileProviderManager?,
        environment: PhotoSearchEnvironment = .production(),
        diceBear: any DiceBearProviding = DiceBearClient()
    ) {
        let storage = try? AppGroupStorage()
        let service = environment.imageSearchService(
            for: .fileProvider,
            purpose: .recommendation,
            diceBear: diceBear
        )
        self.storage = storage
        self.manager = manager
        self.diceBear = diceBear
        self.sourcePreferences = environment.preferences
        self.discoveryFeed = storage.map {
            DiscoveryFeedRepository(
                storage: $0,
                service: service,
                diceBear: diceBear,
                // 一层最多补 3 个底层页；单页 1.5 秒使 Finder 枚举总等待仍控制在数秒内。
                networkTimeout: .milliseconds(1_500),
                catalogKey: { [environment] in
                    await environment.recommendationCatalogKey(for: .fileProvider)
                }
            )
        }
    }

    /// 测试注入共享存储与推荐仓库，验证 File Provider 位置语义而不访问真实 App Group。
    init(
        manager: NSFileProviderManager?,
        storage: AppGroupStorage,
        discoveryFeed: any DiscoveryFeedProviding,
        diceBear: any DiceBearProviding = DiceBearClient(),
        sourcePreferences: (any PhotoSourcePreferencesReading)? = nil
    ) {
        self.storage = storage
        self.manager = manager
        self.discoveryFeed = discoveryFeed
        self.diceBear = diceBear
        self.sourcePreferences = sourcePreferences
    }

    /// 推荐仓库只运行结构化调用任务，扩展失效时无需维护额外游离任务。
    func invalidate() {}

    /// 只有用户进入“头像”目录时才生成独立的前 50 个 DiceBear 头像，不读取混合推荐流。
    func avatarItems() async throws -> [ProviderItem] {
        let storage = try requireStorage()
        if let cached = try await cachedAvatarItems(in: storage) { return cached }

        var seen = Set<String>()
        var records: [RemoteImageRecord] = []
        for chunk in Self.avatarChunks {
            try Task.checkCancellation()
            let generated = await diceBear.avatars(
                query: DiscoveryRecommendation.query,
                offset: chunk.offset,
                count: chunk.count
            )
            for record in generated
                where record.source == .diceBear && seen.insert(record.id).inserted {
                records.append(record)
            }
        }
        try Task.checkCancellation()
        for record in records {
            try await storage.writeItem(record)
        }
        try Task.checkCancellation()
        return records.map { ProviderItem(record: $0, view: .avatar) }
    }

    /// 已提交 scope、逐条元数据和当前 ProviderItem 指纹全部一致时直接复用，避免锚点轮询重复写盘。
    private func cachedAvatarItems(in storage: AppGroupStorage) async throws -> [ProviderItem]? {
        guard let states = try await storage.providerScopeSnapshot(
            ProviderEnumerationScope.avatars.storageKey
        ), states.count == Self.avatarItemCount else {
            return nil
        }
        var items: [ProviderItem] = []
        items.reserveCapacity(states.count)
        for state in states {
            try Task.checkCancellation()
            let identifier = NSFileProviderItemIdentifier(state.identifier)
            guard let reference = ProviderIdentifiers.recordReference(from: identifier),
                  reference.view == .avatar,
                  reference.discoveryPage == nil else {
                return nil
            }
            let record: RemoteImageRecord
            do {
                guard let cachedRecord = try await storage.readItem(id: reference.recordID) else {
                    return nil
                }
                record = cachedRecord
            } catch is DecodingError {
                // 单条缓存损坏不应让目录永久不可枚举；重新生成会原子覆盖该文件。
                return nil
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // fileExists 与实际读取之间若被清理，按普通 cache miss 自愈。
                return nil
            }
            guard record.source == .diceBear else { return nil }
            let item = ProviderItem(record: record, view: .avatar)
            guard item.itemIdentifier == identifier,
                  item.changeFingerprint == state.fingerprint else {
                return nil
            }
            items.append(item)
        }
        return items
    }

    /// 根目录固定公开推荐流的首个 40 张批次；底层仍按 Mirage 的 20 张共享页读取。
    func discoveryRootBatch() async throws -> ProviderDiscoveryBatch {
        try await resolveDiscoveryBatch(page: 1, generation: nil)
    }

    /// 下一批严格继承父入口发布时的代次；祖先断链或换代后不能借旧 scope 继续联网。
    func discoveryBatch(for reference: DiscoveryPageReference) async throws -> ProviderDiscoveryBatch {
        guard let generation = try await publishedGeneration(for: reference) else {
            throw ProviderError.noSuchItem(reference.itemIdentifier)
        }
        return try await resolveDiscoveryBatch(page: reference.page, generation: generation)
    }

    /// 回查分页目录本身时只解析父批次；不会提前加载该目录中的下一批图片。
    func parentBatch(
        publishing reference: DiscoveryPageReference
    ) async throws -> ProviderDiscoveryBatch? {
        guard let generation = try await publishedGeneration(for: reference) else { return nil }
        let parentPage = reference.page - 1
        let parent = try await resolveDiscoveryBatch(page: parentPage, generation: generation)
        return parent.hasMore ? parent : nil
    }

    /// generation 为空时只在根入口冻结当前代次；子目录永远沿父入口的持久化代次续读。
    private func resolveDiscoveryBatch(
        page: Int,
        generation requestedGeneration: UInt64?
    ) async throws -> ProviderDiscoveryBatch {
        guard (1...ProviderDiscoveryTreePlanner.maximumPage).contains(page) else {
            throw ProviderError.expiredDiscoveryPage()
        }
        let bounds = try ProviderDiscoveryTreePlanner.recordBounds(for: page)
        let first = try await loadDiscoveryPage(generation: requestedGeneration, page: 1)
        try Task.checkCancellation()
        var snapshot = try await discoverySnapshot(
            generation: first.generation,
            fallback: first
        )
        while snapshot.records.count < bounds.upperBound,
              let nextPage = snapshot.nextPage {
            try Task.checkCancellation()
            let previousRecordCount = snapshot.records.count
            let previousNextPage = snapshot.nextPage
            _ = try await loadDiscoveryPage(generation: first.generation, page: nextPage)
            snapshot = try await discoverySnapshot(
                generation: first.generation,
                fallback: first
            )
            guard snapshot.records.count > previousRecordCount
                    || snapshot.nextPage != previousNextPage else {
                // 完整 generation 已被裁剪、但单页 sidecar 尚在时不能原地循环或切到当前代次。
                throw ProviderError.expiredDiscoveryPage()
            }
        }
        try Task.checkCancellation()
        guard snapshot.generation == first.generation,
              bounds.lowerBound < snapshot.records.count else {
            throw ProviderError.expiredDiscoveryPage()
        }
        let upperBound = min(bounds.upperBound, snapshot.records.count)
        let records = Array(snapshot.records[bounds.lowerBound..<upperBound])
        let hasMore = upperBound < snapshot.records.count || snapshot.nextPage != nil
        return ProviderDiscoveryBatch(
            page: page,
            generation: snapshot.generation,
            records: records,
            hasMore: hasMore
        )
    }

    /// 从完整代次快照恢复累积顺序；首页刚提交但归档尚未可见时使用该页作安全回退。
    private func discoverySnapshot(
        generation: UInt64,
        fallback: DiscoveryFeedPage
    ) async throws -> DiscoveryRootFeed {
        let storage = try requireStorage()
        guard let snapshot = try await storage.readDiscoveryFeedSnapshot(generation: generation) else {
            guard fallback.generation == generation, !fallback.records.isEmpty else {
                throw ProviderError.expiredDiscoveryPage()
            }
            return DiscoveryRootFeed(
                generation: generation,
                records: fallback.records,
                nextPage: fallback.nextPage
            )
        }
        return DiscoveryRootFeed(
            generation: snapshot.generation,
            records: snapshot.records,
            nextPage: snapshot.nextPage
        )
    }

    /// 从目标入口逐层回溯到根；每一层都必须已提交且属于同一个冻结 generation。
    private func publishedGeneration(
        for reference: DiscoveryPageReference
    ) async throws -> UInt64? {
        let storage = try requireStorage()
        var expectedGeneration: UInt64?
        for page in stride(from: reference.page, through: 2, by: -1) {
            let ancestor = try DiscoveryPageReference(validating: page)
            guard let state = try await publishedDirectoryState(
                ancestor,
                storage: storage
            ), let generation = state.discoveryGeneration else {
                return nil
            }
            if let expectedGeneration, expectedGeneration != generation {
                return nil
            }
            expectedGeneration = generation
        }
        return expectedGeneration
    }

    /// 第 2 层可能由 root 或 working set 首次发布；选择代次较新的已提交根快照。
    private func publishedDirectoryState(
        _ reference: DiscoveryPageReference,
        storage: AppGroupStorage
    ) async throws -> ProviderStoredItemState? {
        if reference.page == 2 {
            let root = try await storage.providerScopeSnapshot(
                ProviderEnumerationScope.root.storageKey
            )
            let workingSet = try await storage.providerScopeSnapshot(
                ProviderEnumerationScope.workingSet.storageKey
            )
            let candidates = [root, workingSet].compactMap { snapshot -> (
                generation: UInt64,
                state: ProviderStoredItemState?
            )? in
                guard let snapshot,
                      let generation = snapshot.compactMap(\.discoveryGeneration).max() else {
                    return nil
                }
                return (
                    generation,
                    snapshot.first { $0.identifier == reference.itemIdentifier.rawValue }
                )
            }
            return candidates.max { $0.generation < $1.generation }?.state
        }
        let parent = try DiscoveryPageReference(validating: reference.page - 1)
        let snapshot = try await storage.providerScopeSnapshot(
            ProviderEnumerationScope.discoveryPage(parent).storageKey
        )
        return snapshot?.first { $0.identifier == reference.itemIdentifier.rawValue }
    }

    /// 以持久化的已打开深度直接重建当前 generation；不依赖仍停留在旧代次的父 scope。
    func rebuiltOpenedDiscoveryScopes(
        rootGeneration: UInt64
    ) async throws -> ProviderRecursiveWorkingSetSnapshot {
        let storage = try requireStorage()
        guard let maximumPage = try await storage.maximumOpenedProviderDiscoveryPage(),
              maximumPage >= 2 else {
            return ProviderRecursiveWorkingSetSnapshot(items: [], scopes: [])
        }

        var flattened: [ProviderItem] = []
        var scopes: [ProviderDiscoveryScopeSnapshot] = []
        for page in 2...min(maximumPage, ProviderDiscoveryTreePlanner.maximumPage) {
            try Task.checkCancellation()
            let reference = try DiscoveryPageReference(validating: page)
            let batch = try await resolveDiscoveryBatch(
                page: page,
                generation: rootGeneration
            )
            try Task.checkCancellation()
            let items = try ProviderDiscoveryTreePlanner.items(for: batch)
            flattened.append(contentsOf: items)
            scopes.append(ProviderDiscoveryScopeSnapshot(reference: reference, items: items))
            guard batch.hasMore else { break }
        }
        return ProviderRecursiveWorkingSetSnapshot(items: flattened, scopes: scopes)
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
                await signalWorkingSet()
            }
            return result
        } catch is DiscoveryFeedError {
            throw ProviderError.expiredDiscoveryPage()
        } catch is DiscoveryFeedStorageError {
            throw ProviderError.expiredDiscoveryPage()
        }
    }

    /// Replicated File Provider 只接受 working set signal；系统再把差异投影到各已枚举目录。
    func signalWorkingSet() async {
        guard let manager else { return }
        try? await manager.signalEnumerator(for: .workingSet)
    }

    /// 持久化搜索结果及顺序，扩展重启后隐藏 backing 和 item(for:) 都能恢复。
    func storeSearchResults(
        _ records: [RemoteImageRecord],
        queryKey: String,
        appending: Bool = false
    ) async throws {
        try Task.checkCancellation()
        let storage = try requireStorage()
        let allowedRecords = await allowedFileProviderRecords(records)
        try await storage.commitSearchBacking(
            queryKey: Self.normalizedQuery(queryKey),
            records: allowedRecords,
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
        if let discoveryPage = reference.discoveryPage {
            let state = try await storage.providerScopeSnapshot(
                ProviderEnumerationScope.discoveryPage(discoveryPage).storageKey
            )?.first { $0.identifier == identifier.rawValue }
            guard let generation = state?.discoveryGeneration,
                  try await publishedGeneration(for: discoveryPage) == generation else {
                return nil
            }
            let record = try await storage.readDiscoveryRecord(id: reference.recordID)
            try Task.checkCancellation()
            guard let record, await isAllowedInFileProvider(record) else { return nil }
            return ProviderOccurrence(
                reference: reference,
                record: record,
                discoveryGeneration: generation
            )
        }
        let occurrence: ProviderOccurrence?
        switch reference.view {
        case .discover:
            occurrence = try await storage.readDiscoveryRecord(id: reference.recordID).map {
                ProviderOccurrence(reference: reference, record: $0)
            }
        case .avatar:
            guard try await storage.providerScope(
                ProviderEnumerationScope.avatars.storageKey,
                contains: identifier.rawValue
            ), let record = try await storage.readItem(id: reference.recordID),
               record.source == .diceBear else {
                return nil
            }
            occurrence = ProviderOccurrence(reference: reference, record: record)
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
        guard let occurrence else { return nil }
        return await isAllowedInFileProvider(occurrence.record) ? occurrence : nil
    }

    /// 每次从持久化搜索快照恢复，确保其他扩展进程的最新原子提交不会被内存缓存遮蔽。
    func cachedSearchItems() async throws -> [ProviderItem] {
        try Task.checkCancellation()
        let records = try await requireStorage().readSearchBackingRecords()
        try Task.checkCancellation()
        let allowed = await allowedFileProviderRecords(records)
        return allowed.map { ProviderItem(record: $0, view: .search) }
    }

    /// 最近使用条目保持 Core 中的访问时间倒序。
    func recentItems() async throws -> [ProviderItem] {
        try Task.checkCancellation()
        let records = try await requireStorage().readRecent()
        try Task.checkCancellation()
        let enabledSourceIDs = await enabledFileProviderSourceIDs()
        var items: [ProviderItem] = []
        for record in records {
            guard Self.isAllowed(record.image, enabledSourceIDs: enabledSourceIDs) else { continue }
            items.append(
                ProviderItem(
                    record: record.image,
                    view: .recent,
                    lastUsedDate: record.accessedAt
                )
            )
        }
        return items
    }

    /// 收藏顺序和内容都来自 favorites 内嵌快照，不再回退到可被其他视图改写的全局 items。
    func favoriteItems() async throws -> [ProviderItem] {
        try Task.checkCancellation()
        let records = try await requireStorage().readFavoriteRecords()
        try Task.checkCancellation()
        let allowed = await allowedFileProviderRecords(records)
        return allowed.map { ProviderItem(record: $0, view: .favorite) }
    }

    /// 测试注入未提供设置时保持历史语义；生产环境严格隐藏未获 File Provider 授权的来源。
    private func isAllowedInFileProvider(_ record: RemoteImageRecord) async -> Bool {
        Self.isAllowed(record, enabledSourceIDs: await enabledFileProviderSourceIDs())
    }

    private func allowedFileProviderRecords(
        _ records: [RemoteImageRecord]
    ) async -> [RemoteImageRecord] {
        let enabledSourceIDs = await enabledFileProviderSourceIDs()
        return records.filter { Self.isAllowed($0, enabledSourceIDs: enabledSourceIDs) }
    }

    private func enabledFileProviderSourceIDs() async -> Set<PhotoSourceID>? {
        guard let sourcePreferences else { return nil }
        let snapshot = await sourcePreferences.snapshot()
        return Set(snapshot.sourceIDs(for: .fileProvider))
    }

    private static func isAllowed(
        _ record: RemoteImageRecord,
        enabledSourceIDs: Set<PhotoSourceID>?
    ) -> Bool {
        guard let sourceID = record.source.photoSourceID else { return record.source == .diceBear }
        return enabledSourceIDs?.contains(sourceID) ?? true
    }

    /// 成功物化图片后记录最近使用，底层元数据继续保留供其他 occurrence 和在途请求使用。
    func markRecent(_ record: RemoteImageRecord) async throws {
        try Task.checkCancellation()
        try await requireStorage().writeRecent(record)
        try Task.checkCancellation()
    }

    /// 将当前 scope 的 occurrence 版本提交到持久化差异日志。
    /// 子目录把 lineage 复核与写入合并在同一跨进程锁事务，拒绝联网期间发生的换代。
    func commitScope(
        _ scope: ProviderEnumerationScope,
        items: [ProviderItem],
        migratesLegacySearch: Bool
    ) async throws -> UInt64 {
        try Task.checkCancellation()
        let storage = try requireStorage()
        let legacyDeleted = try await legacyDeletedIdentifiers(
            migratesLegacySearch: migratesLegacySearch,
            storage: storage
        )
        try Task.checkCancellation()
        let commit = ProviderStoredScopeCommit(
            scope: scope.storageKey,
            items: Self.storedStates(from: items),
            initialDeletedIdentifiers: legacyDeleted
        )
        do {
            switch scope {
            case .root:
                let generation = try Self.singleDiscoveryGeneration(in: items)
                return try await storage.commitProviderScopes(
                    [commit],
                    generationCeiling: ProviderGenerationCeiling(
                        authorityScopes: Self.rootAuthorityScopes,
                        maximumDiscoveryGeneration: generation
                    )
                )
            case let .discoveryPage(reference):
                let generation = try Self.singleDiscoveryGeneration(in: items)
                return try await storage.commitProviderScopes(
                    [commit],
                    requiring: Self.publicationRequirements(
                        for: reference,
                        generation: generation
                    ),
                    openedDiscoveryPage: reference.page
                )
            case .avatars, .search, .recent, .favorites, .workingSet, .single:
                return try await storage.commitProviderScopes([commit])
            }
        } catch is ProviderPublicationError {
            throw ProviderError.expiredDiscoveryPage()
        }
    }

    /// 当前代次的递归 scope 与 working set 必须一次提交，系统永远看不到“目录尚在但 children 被清空”的中间态。
    func commitWorkingSet(
        items: [ProviderItem],
        recursiveScopes: [ProviderDiscoveryScopeSnapshot],
        rootGeneration: UInt64,
        migratesLegacySearch: Bool
    ) async throws -> UInt64 {
        try Task.checkCancellation()
        let storage = try requireStorage()
        let legacyDeleted = try await legacyDeletedIdentifiers(
            migratesLegacySearch: migratesLegacySearch,
            storage: storage
        )
        var commits = recursiveScopes.map {
            ProviderStoredScopeCommit(
                scope: ProviderEnumerationScope.discoveryPage($0.reference).storageKey,
                items: Self.storedStates(from: $0.items)
            )
        }
        commits.append(
            ProviderStoredScopeCommit(
                scope: ProviderEnumerationScope.workingSet.storageKey,
                items: Self.storedStates(from: items),
                initialDeletedIdentifiers: legacyDeleted
            )
        )
        do {
            return try await storage.commitProviderScopes(
                commits,
                generationCeiling: ProviderGenerationCeiling(
                    authorityScopes: Self.rootAuthorityScopes,
                    maximumDiscoveryGeneration: rootGeneration
                )
            )
        } catch is ProviderPublicationError {
            throw ProviderError.expiredDiscoveryPage()
        }
    }

    /// 首次迁移的旧搜索 occurrence 只在需要它的 scope 提交前扫描一次。
    private func legacyDeletedIdentifiers(
        migratesLegacySearch: Bool,
        storage: AppGroupStorage
    ) async throws -> [String] {
        guard migratesLegacySearch else { return [] }
        return try await storage.readRecoverableItemIDs().map {
            ProviderIdentifiers.itemIdentifier(recordID: $0, view: .search).rawValue
        }
    }

    private static let rootAuthorityScopes = [
        ProviderEnumerationScope.root.storageKey,
        ProviderEnumerationScope.workingSet.storageKey
    ]

    /// 同一推荐 scope 的所有图片和 continuation 必须绑定唯一 generation。
    private static func singleDiscoveryGeneration(in items: [ProviderItem]) throws -> UInt64 {
        let generations = Set(items.compactMap(\.discoveryGeneration))
        guard generations.count == 1, let generation = generations.first else {
            throw ProviderError.expiredDiscoveryPage()
        }
        return generation
    }

    private static func storedStates(from items: [ProviderItem]) -> [ProviderStoredItemState] {
        items.map {
            ProviderStoredItemState(
                identifier: $0.itemIdentifier.rawValue,
                fingerprint: $0.changeFingerprint,
                discoveryGeneration: $0.discoveryGeneration
            )
        }
    }

    /// 从 page 2 回溯到目标页；第一层由 root/working set 较新者授权，其余层由直接父 scope 授权。
    private static func publicationRequirements(
        for reference: DiscoveryPageReference,
        generation: UInt64
    ) -> [ProviderPublicationRequirement] {
        (2...reference.page).map { page in
            let current = DiscoveryPageReference(page: page)!
            let candidateScopes: [String]
            if page == 2 {
                candidateScopes = rootAuthorityScopes
            } else {
                let parent = DiscoveryPageReference(page: page - 1)!
                candidateScopes = [ProviderEnumerationScope.discoveryPage(parent).storageKey]
            }
            return ProviderPublicationRequirement(
                candidateScopes: candidateScopes,
                itemIdentifier: current.itemIdentifier.rawValue,
                expectedDiscoveryGeneration: generation
            )
        }
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
    let discoveryGeneration: UInt64?

    /// 非 recent 视图没有独立的最近使用时间。
    init(
        reference: RecordReference,
        record: RemoteImageRecord,
        lastUsedDate: Date? = nil,
        discoveryGeneration: UInt64? = nil
    ) {
        self.reference = reference
        self.record = record
        self.lastUsedDate = lastUsedDate
        self.discoveryGeneration = discoveryGeneration
    }
}

/// working set 为某个已打开目录重建的当前代次完整快照。
struct ProviderDiscoveryScopeSnapshot: Sendable {
    let reference: DiscoveryPageReference
    let items: [ProviderItem]
}

/// working set 一次枚举中要交付的递归成员及其逐目录发布边界。
struct ProviderRecursiveWorkingSetSnapshot: Sendable {
    let items: [ProviderItem]
    let scopes: [ProviderDiscoveryScopeSnapshot]
}

/// 根目录当前可发布的完整推荐序列；`nextPage` 为空表示远端已无更多内容。
struct DiscoveryRootFeed: Sendable {
    let generation: UInt64
    let records: [RemoteImageRecord]
    let nextPage: Int?
}
