import MirageCore
import FileProvider
import Foundation

/// 将扩展需要的数据视图隔离在单一适配器中，并复用 Core 的共享推荐仓库。
actor ProviderRepository: ProviderSearchResultStoring {
    private let storage: AppGroupStorage?
    private let manager: NSFileProviderManager?
    private let discoveryFeed: (any DiscoveryFeedProviding)?
    private let avatarProvider: any AvatarProviding
    private let sourcePreferences: (any PhotoSourcePreferencesReading)?
    private let photoEnvironment: PhotoSearchEnvironment?
    private let filterPreferences: DiscoveryFilterPreferencesStore?
    private var filteredDiscoveryFeeds: [String: DiscoveryFeedRepository] = [:]

    /// Finder 头像分页按绝对 offset 生成；每次调用仍受头像协议单次 20 条限制。
    private static let avatarChunkSize = 20

    /// App Group 不可用时保留实例，具体请求再返回稳定错误而不是让扩展崩溃。
    init(
        manager: NSFileProviderManager?,
        environment: PhotoSearchEnvironment = .production(),
        diceBear: any AvatarProviding = AvatarCatalogClient(includesPicrewDiscovery: true),
        filterPreferences: DiscoveryFilterPreferencesStore = .production()
    ) {
        let storage = try? AppGroupStorage()
        self.storage = storage
        self.manager = manager
        self.avatarProvider = diceBear
        self.sourcePreferences = environment.preferences
        self.discoveryFeed = nil
        self.photoEnvironment = environment
        self.filterPreferences = filterPreferences
    }

    /// 测试注入共享存储与推荐仓库，验证 File Provider 位置语义而不访问真实 App Group。
    init(
        manager: NSFileProviderManager?,
        storage: AppGroupStorage,
        discoveryFeed: any DiscoveryFeedProviding,
        diceBear: any AvatarProviding = AvatarCatalogClient(includesPicrewDiscovery: true),
        sourcePreferences: (any PhotoSourcePreferencesReading)? = nil,
        filterPreferences: DiscoveryFilterPreferencesStore? = nil
    ) {
        self.storage = storage
        self.manager = manager
        self.discoveryFeed = discoveryFeed
        self.avatarProvider = diceBear
        self.sourcePreferences = sourcePreferences
        self.photoEnvironment = nil
        self.filterPreferences = filterPreferences
    }

    /// 推荐仓库只运行结构化调用任务，扩展失效时无需维护额外游离任务。
    func invalidate() {}

    /// “头像”首页固定发布 40 个 occurrence，并追加一个真实的“加载更多”目录。
    func avatarItems() async throws -> [ProviderItem] {
        try await avatarItems(page: 1)
    }

    /// 头像续页只有被父 scope 公开后才能打开，避免构造 ID 提前生成任意深度数据。
    func avatarItems(for reference: AvatarPageReference) async throws -> [ProviderItem] {
        guard try await isAvatarPagePublished(reference) else {
            throw ProviderError.noSuchItem(reference.itemIdentifier)
        }
        return try await avatarItems(page: reference.page)
    }

    /// 回查分页目录只验证父 scope 中已经提交的入口，不生成该页的 40 个头像。
    func isAvatarPagePublished(_ reference: AvatarPageReference) async throws -> Bool {
        let storage = try requireStorage()
        let parentScope: ProviderEnumerationScope
        if reference.page == 2 {
            parentScope = .avatars
        } else {
            parentScope = .avatarPage(try AvatarPageReference(validating: reference.page - 1))
        }
        return try await storage.providerScope(
            parentScope.storageKey,
            contains: reference.itemIdentifier.rawValue
        )
    }

    /// 回查分页目录时使用当前筛选 token 构造版本，避免 Finder 复用上一个类型范围的目录元数据。
    func avatarContinuationItem(
        for reference: AvatarPageReference
    ) async throws -> ProviderItem? {
        guard try await isAvatarPagePublished(reference) else { return nil }
        let avatarFilter = currentFileProviderAvatarFilter()
        return try ProviderAvatarTreePlanner.continuationItem(
            after: ProviderAvatarBatch(
                page: reference.page - 1,
                records: [],
                hasMore: true,
                filterKey: avatarFilter.key
            )
        )
    }

    /// 每个可见目录最多生成 40 个头像；低频动态来源不足一页时仍发布可用结果。
    private func avatarItems(page: Int) async throws -> [ProviderItem] {
        let storage = try requireStorage()
        let avatarFilter = currentFileProviderAvatarFilter()
        // 一批头像可能跨越多个 20 条分段；日期必须只捕获一次，避免午夜混入两天 seed。
        let generationDay = await avatarProvider.currentGenerationDay()
        if let cached = try await cachedAvatarItems(
            in: storage,
            page: page,
            generationDay: generationDay,
            allowedTypes: avatarFilter.types,
            filterKey: avatarFilter.key
        ) {
            return cached
        }

        let range = try ProviderAvatarTreePlanner.recordRange(for: page)

        var seen = Set<String>()
        var generatedRecords: [RemoteImageRecord] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            try Task.checkCancellation()
            let count = min(Self.avatarChunkSize, range.upperBound - offset)
            let generated = await avatarProvider.avatars(
                query: DiscoveryRecommendation.query,
                offset: offset,
                count: count,
                generationDay: generationDay,
                allowedTypes: avatarFilter.types
            )
            for record in generated
                where Self.isCurrentAvatarRecord(record, generationDay: generationDay)
                    && record.matchesAvatarTypes(avatarFilter.types)
                    && seen.insert(record.id).inserted {
                generatedRecords.append(record)
            }
            offset += count
        }
        guard !generatedRecords.isEmpty else {
            throw ProviderError.serverUnreachable("当前头像类型暂时没有可用图片。")
        }
        try Task.checkCancellation()
        for record in generatedRecords {
            try await storage.writeItem(record)
        }
        try Task.checkCancellation()
        return try ProviderAvatarTreePlanner.items(
            for: ProviderAvatarBatch(
                page: page,
                records: generatedRecords,
                hasMore: page < AvatarPageReference.maximumPage,
                filterKey: avatarFilter.key
            )
        )
    }

    /// 已提交 scope、逐条元数据、分页入口和指纹一致时直接复用，避免重复生成与写盘。
    private func cachedAvatarItems(
        in storage: AppGroupStorage,
        page: Int,
        generationDay: AvatarGenerationDay,
        allowedTypes: Set<AvatarType>,
        filterKey: String
    ) async throws -> [ProviderItem]? {
        let scope: ProviderEnumerationScope
        let expectedPage: AvatarPageReference?
        if page == 1 {
            scope = .avatars
            expectedPage = nil
        } else {
            let reference = try AvatarPageReference(validating: page)
            scope = .avatarPage(reference)
            expectedPage = reference
        }
        let hasMore = page < AvatarPageReference.maximumPage
        let emptyBatch = ProviderAvatarBatch(
            page: page,
            records: [],
            hasMore: hasMore,
            filterKey: filterKey
        )
        let expectedContinuation = try ProviderAvatarTreePlanner.continuationItem(after: emptyBatch)
        guard let states = try await storage.providerScopeSnapshot(scope.storageKey),
              states.count <= ProviderAvatarTreePlanner.batchSize
                + (expectedContinuation == nil ? 0 : 1) else {
            return nil
        }
        let imageStates: ArraySlice<ProviderStoredItemState>
        if let expectedContinuation {
            guard let continuationState = states.last,
                  continuationState.identifier == expectedContinuation.itemIdentifier.rawValue,
                  continuationState.fingerprint == expectedContinuation.changeFingerprint else {
                return nil
            }
            imageStates = states.dropLast()
        } else {
            imageStates = states[...]
        }

        var records: [RemoteImageRecord] = []
        records.reserveCapacity(imageStates.count)
        for state in imageStates {
            try Task.checkCancellation()
            let identifier = NSFileProviderItemIdentifier(state.identifier)
            guard let reference = ProviderIdentifiers.recordReference(from: identifier),
                  reference.view == .avatar,
                  reference.discoveryPage == nil,
                  reference.avatarPage == expectedPage else {
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
            guard Self.isCurrentAvatarRecord(record, generationDay: generationDay),
                  record.matchesAvatarTypes(allowedTypes) else {
                return nil
            }
            guard try await hasAvailableAvatarContent(record, in: storage) else {
                return nil
            }
            let item: ProviderItem
            if expectedPage != nil {
                item = ProviderItem(record: record, reference: reference)
            } else {
                item = ProviderItem(record: record, view: .avatar)
            }
            guard item.itemIdentifier == identifier,
                  item.changeFingerprint == state.fingerprint else {
                return nil
            }
            records.append(record)
        }
        return try ProviderAvatarTreePlanner.items(
            for: ProviderAvatarBatch(
                page: page,
                records: records,
                hasMore: hasMore,
                filterKey: filterKey
            )
        )
    }

    /// 根目录固定公开推荐流的首个 40 张批次；底层仍按 Mirage 的 20 张共享页读取。
    func discoveryRootBatch() async throws -> ProviderDiscoveryBatch {
        try await resolveDiscoveryBatch(page: 1, generation: nil)
    }

    /// 普通图片没有可用来源或首次联网失败时，仍以持久稳定的空 generation 发布固定资料库目录。
    /// fallback 使用独立 catalog key，确保照片来源恢复后仍会重新尝试真实推荐，而不是长期命中空缓存。
    func fallbackDiscoveryRootBatch() async throws -> ProviderDiscoveryBatch {
        try Task.checkCancellation()
        let storage = try requireStorage()
        let photoFilter = await currentFileProviderPhotoFilter()
        let sourceKey = await sourcePreferences?.configurationKey(for: .app)
            ?? "photo-sources:test"
        let catalogKey = "provider-fixed-root-fallback-v1:\(sourceKey):\(photoFilter.key)"
        if let current = try await storage.readDiscoveryFeedSnapshot(),
           current.source == .fallback,
           current.catalogKey == catalogKey,
           current.queryKey == DiscoveryRecommendation.query,
           current.records.isEmpty,
           current.nextPage == nil {
            return ProviderDiscoveryBatch(
                page: 1,
                generation: current.generation,
                records: [],
                hasMore: false
            )
        }
        try Task.checkCancellation()
        let committed = try await storage.commitDiscoveryFeed(
            records: [],
            refreshedAt: Date(),
            source: .fallback,
            catalogKey: catalogKey,
            queryKey: DiscoveryRecommendation.query,
            pageSize: DiscoveryRecommendation.pageSize,
            nextPage: nil
        )
        try Task.checkCancellation()
        return ProviderDiscoveryBatch(
            page: 1,
            generation: committed.generation,
            records: [],
            hasMore: false
        )
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
        guard snapshot.generation == first.generation else {
            throw ProviderError.expiredDiscoveryPage()
        }
        if bounds.lowerBound >= snapshot.records.count {
            guard page == 1, snapshot.records.isEmpty, snapshot.nextPage == nil else {
                throw ProviderError.expiredDiscoveryPage()
            }
            return ProviderDiscoveryBatch(
                page: page,
                generation: snapshot.generation,
                records: [],
                hasMore: false
            )
        }
        let upperBound = min(bounds.upperBound, snapshot.records.count)
        let slicedRecords = Array(snapshot.records[bounds.lowerBound..<upperBound])
        let records: [RemoteImageRecord]
        if filterPreferences == nil {
            // 测试可注入历史混合推荐流；生产扩展始终具备共享筛选并严格投影 Finder 能力。
            records = slicedRecords
        } else {
            let photoFilter = await currentFileProviderPhotoFilter()
            records = slicedRecords.filter {
                Self.isAllowedDiscoveryPhoto($0, filter: photoFilter)
            }
        }
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
            guard fallback.generation == generation,
                  !fallback.records.isEmpty || fallback.nextPage == nil else {
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
        var scopes: [ProviderScopeSnapshot] = []
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
            scopes.append(
                ProviderScopeSnapshot(
                    storageKey: ProviderEnumerationScope.discoveryPage(reference).storageKey,
                    items: items
                )
            )
            guard batch.hasMore else { break }
        }
        return ProviderRecursiveWorkingSetSnapshot(items: flattened, scopes: scopes)
    }

    /// Replicated File Provider 只消费 working set 通知；重建已发布头像 scope 才能把筛选差异投影到 Finder。
    func rebuiltPublishedAvatarScopes() async throws -> ProviderRecursiveWorkingSetSnapshot {
        let storage = try requireStorage()
        let rootKey = ProviderEnumerationScope.avatars.storageKey
        guard try await storage.providerScopeSnapshot(rootKey) != nil else {
            return ProviderRecursiveWorkingSetSnapshot(items: [], scopes: [])
        }

        let rootItems = try await avatarItems(page: 1)
        var flattened = rootItems
        var scopes = [ProviderScopeSnapshot(storageKey: rootKey, items: rootItems)]
        let pageIdentifiers = try await storage.providerItemIdentifiers(
            matchingPrefix: MirageSystemIntegration.fileProviderAvatarPageIdentifierPrefix
        )
        let references = pageIdentifiers
            .compactMap {
                ProviderIdentifiers.avatarPageReference(
                    from: NSFileProviderItemIdentifier($0)
                )
            }
            .sorted { $0.page < $1.page }

        for reference in references {
            try Task.checkCancellation()
            let scopeKey = ProviderEnumerationScope.avatarPage(reference).storageKey
            guard try await storage.providerScopeSnapshot(scopeKey) != nil else { continue }
            let items = try await avatarItems(page: reference.page)
            flattened.append(contentsOf: items)
            scopes.append(ProviderScopeSnapshot(storageKey: scopeKey, items: items))
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
            let feed = try await requireDiscoveryFeed()
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

    /// 推荐快照换代后通知 working set，系统再把差异投影到已枚举目录。
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
        if let avatarPage = reference.avatarPage {
            guard try await storage.providerScope(
                ProviderEnumerationScope.avatarPage(avatarPage).storageKey,
                contains: identifier.rawValue
            ), let record = try await storage.readItem(id: reference.recordID),
               Self.isCurrentAvatarRecord(record),
               record.matchesAvatarTypes(currentFileProviderAvatarFilter().types),
               try await hasAvailableAvatarContent(record, in: storage) else {
                return nil
            }
            try Task.checkCancellation()
            return ProviderOccurrence(reference: reference, record: record)
        }
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
            guard let record, await isAllowedInCurrentDiscoveryFilter(record),
                  await isAllowedInFileProvider(record) else { return nil }
            return ProviderOccurrence(
                reference: reference,
                record: record,
                discoveryGeneration: generation
            )
        }
        let occurrence: ProviderOccurrence?
        switch reference.view {
        case .discover:
            let record = try await storage.readDiscoveryRecord(id: reference.recordID)
            if let record, await isAllowedInCurrentDiscoveryFilter(record) {
                occurrence = ProviderOccurrence(reference: reference, record: record)
            } else {
                occurrence = nil
            }
        case .avatar:
            guard try await storage.providerScope(
                ProviderEnumerationScope.avatars.storageKey,
                contains: identifier.rawValue
            ), let record = try await storage.readItem(id: reference.recordID),
               Self.isCurrentAvatarRecord(record),
               record.matchesAvatarTypes(currentFileProviderAvatarFilter().types),
               try await hasAvailableAvatarContent(record, in: storage) else {
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
            occurrence = records.first(where: { $0.id == reference.recordID }).map {
                ProviderOccurrence(reference: reference, record: $0)
            }
        }
        try Task.checkCancellation()
        guard let occurrence else { return nil }
        if reference.view == .favorite {
            return await isAvailableFavoriteInFileProvider(occurrence.record) ? occurrence : nil
        }
        // 头像 scope 已由当前筛选、来源命名空间和已发布成员共同授权；Picrew 仍不进入
        // 普通图片、搜索或最近使用目录。
        if reference.view != .avatar {
            guard await isAllowedInFileProvider(occurrence.record) else { return nil }
        }
        if occurrence.record.source == .thisPersonDoesNotExist {
            guard (try? await hasAvailableAvatarContent(occurrence.record, in: storage)) == true else {
                return nil
            }
        }
        return occurrence
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
        let enabledSourceIDs = await enabledFinderPhotoSourceIDs()
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

    /// 收藏不再受来源开关过滤；只排除无法在 Finder 中合法、稳定物化的内容。
    func favoriteItems() async throws -> [ProviderItem] {
        try Task.checkCancellation()
        let records = try await requireStorage().readFavoriteRecords()
        try Task.checkCancellation()
        var available: [RemoteImageRecord] = []
        available.reserveCapacity(records.count)
        for record in records where await isAvailableFavoriteInFileProvider(record) {
            available.append(record)
        }
        return available.map { ProviderItem(record: $0, view: .favorite) }
    }

    /// 测试注入未提供设置时保持历史语义；生产环境严格隐藏未获 File Provider 授权的来源。
    private func isAllowedInFileProvider(_ record: RemoteImageRecord) async -> Bool {
        Self.isAllowed(record, enabledSourceIDs: await enabledFinderPhotoSourceIDs())
    }

    private func allowedFileProviderRecords(
        _ records: [RemoteImageRecord]
    ) async -> [RemoteImageRecord] {
        let enabledSourceIDs = await enabledFinderPhotoSourceIDs()
        var allowed: [RemoteImageRecord] = []
        allowed.reserveCapacity(records.count)
        for record in records where Self.isAllowed(record, enabledSourceIDs: enabledSourceIDs) {
            if record.source == .thisPersonDoesNotExist {
                guard let storage,
                      (try? await hasAvailableAvatarContent(record, in: storage)) == true else {
                    continue
                }
            }
            allowed.append(record)
        }
        return allowed
    }

    /// Finder 图片范围以 App 的统一来源开关为准，不再读取独立的 File Provider 来源列表。
    private func enabledFinderPhotoSourceIDs() async -> Set<PhotoSourceID>? {
        guard let sourcePreferences else { return nil }
        let snapshot = await sourcePreferences.snapshot()
        return Set(snapshot.sourceIDs(for: .app))
    }

    /// GIPHY 收藏只有对象 ID，且其条款禁止构建 Finder 目录；动态真人头像则必须仍有冻结内容。
    private func isAvailableFavoriteInFileProvider(
        _ record: RemoteImageRecord
    ) async -> Bool {
        guard record.source != .giphy else { return false }
        guard record.source == .thisPersonDoesNotExist else { return true }
        guard let storage else { return false }
        return (try? await hasAvailableAvatarContent(record, in: storage)) == true
    }

    private static func isAllowed(
        _ record: RemoteImageRecord,
        enabledSourceIDs: Set<PhotoSourceID>?
    ) -> Bool {
        guard record.source != .picrew else { return false }
        guard let sourceID = record.source.photoSourceID else { return record.source.isAvatarSource }
        guard PhotoSourceRegistry.descriptor(for: sourceID)?.supports(.fileProvider) == true else {
            return false
        }
        return enabledSourceIDs?.contains(sourceID) ?? true
    }

    /// 根推荐严格属于 Finder 图片能力的交集，并匹配当前实际可生效的单一来源。
    private func isAllowedInCurrentDiscoveryFilter(_ record: RemoteImageRecord) async -> Bool {
        Self.isAllowedDiscoveryPhoto(
            record,
            filter: await currentFileProviderPhotoFilter()
        )
    }

    private static func isAllowedDiscoveryPhoto(
        _ record: RemoteImageRecord,
        filter: FileProviderPhotoFilter
    ) -> Bool {
        guard !record.source.isAvatarSource, record.source != .giphy,
              isAllowed(record, enabledSourceIDs: filter.enabledSourceIDs) else {
            return false
        }
        guard let selectedSourceID = filter.sourceID else { return true }
        return record.source.photoSourceID == selectedSourceID
    }

    /// 头像树只接受当前命名空间，且记录来源必须与 ID 前缀一致。
    private static func isCurrentAvatarRecord(
        _ record: RemoteImageRecord,
        generationDay expectedGenerationDay: AvatarGenerationDay? = nil
    ) -> Bool {
        guard record.source.isAvatarSource,
              StableImageID.avatarSource(from: record.id) == record.source else {
            return false
        }
        // Picrew 的公开作品 ID 绑定 Maker 与缩略图路径，不属于每日生成命名空间。
        if record.source == .picrew { return true }
        guard let generationDay = StableImageID.avatarGenerationDay(from: record.id) else {
            return false
        }
        return expectedGenerationDay.map { $0 == generationDay } ?? true
    }

    /// 动态端点的元数据只有在冻结 PNG 仍存在且摘要一致时才算可复用缓存。
    private func hasAvailableAvatarContent(
        _ record: RemoteImageRecord,
        in storage: AppGroupStorage
    ) async throws -> Bool {
        guard record.source == .thisPersonDoesNotExist else { return true }
        guard record.imageURL == record.thumbnailURL,
              let reference = AvatarSnapshotReference(url: record.imageURL),
              let expectedHash = StableImageID.thisPersonDoesNotExistSnapshotHash(
                  from: record.id
              ) else {
            return false
        }
        do {
            guard let data = try await storage.readAvatarSnapshot(key: reference.key) else {
                return false
            }
            return StableImageID.dataHash(data) == expectedHash
        } catch is AvatarSnapshotStorageError {
            return false
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }

    /// 远程来源继续走有界 HTTPS 下载；动态人像只能从已冻结的 App Group 快照读取。
    func imageData(at url: URL, maximumBytes: Int) async throws -> Data {
        if url.scheme == AvatarSnapshotReference.scheme {
            guard let reference = AvatarSnapshotReference(url: url) else {
                throw DownloadError.invalidResponse
            }
            do {
                guard let data = try await requireStorage().readAvatarSnapshot(
                    key: reference.key,
                    maximumBytes: maximumBytes
                ) else {
                    throw DownloadError.invalidResponse
                }
                return data
            } catch is AvatarSnapshotStorageError {
                throw DownloadError.invalidResponse
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                throw DownloadError.invalidResponse
            }
        }
        return try await BoundedDownloader(url: url, maximumBytes: maximumBytes).download()
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
        migratesLegacySearch: Bool,
        expectedPublicationEpoch: UInt64
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
                    ),
                    expectedPublicationEpoch: expectedPublicationEpoch
                )
            case let .discoveryPage(reference):
                let generation = try Self.singleDiscoveryGeneration(in: items)
                return try await storage.commitProviderScopes(
                    [commit],
                    requiring: Self.publicationRequirements(
                        for: reference,
                        generation: generation
                    ),
                    openedDiscoveryPage: reference.page,
                    expectedPublicationEpoch: expectedPublicationEpoch
                )
            case .avatars, .avatarPage, .search, .recent, .favorites, .workingSet, .single:
                return try await storage.commitProviderScopes(
                    [commit],
                    expectedPublicationEpoch: expectedPublicationEpoch
                )
            }
        } catch is ProviderPublicationError {
            throw ProviderError.expiredDiscoveryPage()
        }
    }

    /// 当前代次的递归 scope 与 working set 必须一次提交，系统永远看不到“目录尚在但 children 被清空”的中间态。
    func commitWorkingSet(
        items: [ProviderItem],
        recursiveScopes: [ProviderScopeSnapshot],
        rootGeneration: UInt64,
        migratesLegacySearch: Bool,
        expectedPublicationEpoch: UInt64
    ) async throws -> UInt64 {
        try Task.checkCancellation()
        let storage = try requireStorage()
        let legacyDeleted = try await legacyDeletedIdentifiers(
            migratesLegacySearch: migratesLegacySearch,
            storage: storage
        )
        var projectedDeletedIdentifiers = Set<String>()
        for scope in recursiveScopes {
            let newIdentifiers = Set(scope.items.map { $0.itemIdentifier.rawValue })
            let previous = try await storage.providerScopeSnapshot(scope.storageKey) ?? []
            projectedDeletedIdentifiers.formUnion(
                previous.lazy.map(\.identifier).filter { !newIdentifiers.contains($0) }
            )
        }
        var commits = recursiveScopes.map {
            ProviderStoredScopeCommit(
                scope: $0.storageKey,
                items: Self.storedStates(from: $0.items)
            )
        }
        commits.append(
            ProviderStoredScopeCommit(
                scope: ProviderEnumerationScope.workingSet.storageKey,
                items: Self.storedStates(from: items),
                initialDeletedIdentifiers: legacyDeleted,
                additionalDeletedIdentifiers: projectedDeletedIdentifiers.sorted()
            )
        )
        do {
            return try await storage.commitProviderScopes(
                commits,
                generationCeiling: ProviderGenerationCeiling(
                    authorityScopes: Self.rootAuthorityScopes,
                    maximumDiscoveryGeneration: rootGeneration
                ),
                expectedPublicationEpoch: expectedPublicationEpoch
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

    /// 构造发布快照前捕获文件域纪元，提交时由存储事务做原子复核。
    func currentPublicationEpoch() async throws -> UInt64 {
        try Task.checkCancellation()
        let epoch = try await requireStorage().currentProviderPublicationEpoch()
        try Task.checkCancellation()
        return epoch
    }

    /// root 与 working set 任一权威范围已经发布过照片时，联网失败都必须保留旧快照。
    /// File Provider 可能先提交 working set，因此不能只检查 root scope。
    func hasPublishedDiscoveryItemsInRootAuthorityScopes() async throws -> Bool {
        let storage = try requireStorage()
        let prefix = ProviderView.discover.rawValue + ":"
        for scope in Self.rootAuthorityScopes {
            let snapshot = try await storage.providerScopeSnapshot(scope)
            if snapshot?.contains(where: { $0.identifier.hasPrefix(prefix) }) == true {
                return true
            }
        }
        return false
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

    /// 生产环境按当前图片来源筛选复用独立照片快照；测试仍可注入固定推荐仓库。
    private func requireDiscoveryFeed() async throws -> any DiscoveryFeedProviding {
        if let discoveryFeed { return discoveryFeed }
        guard let storage, let photoEnvironment else {
            throw ProviderError.serverUnreachable("无法访问 Mirage 推荐存储。")
        }

        let photoFilter = await currentFileProviderPhotoFilter()
        let filterKey = photoFilter.key
        if let cached = filteredDiscoveryFeeds[filterKey] { return cached }

        let service = photoEnvironment.imageSearchService(
            for: .fileProvider,
            purpose: .recommendation,
            selectedSourceID: photoFilter.sourceID,
            diceBear: avatarProvider
        )
        let feed = DiscoveryFeedRepository(
            storage: storage,
            service: service,
            diceBear: avatarProvider,
            // The Met 需要先查 ID、再并发读取作品详情；给单页完整预算，避免合法来源被短超时误判为空。
            networkTimeout: .seconds(15),
            catalogKey: { [photoEnvironment, filterKey] in
                let sourceKey = await photoEnvironment.recommendationCatalogKey(
                    for: .fileProvider
                )
                return "\(sourceKey):\(filterKey):content-scope:photos-v2"
            },
            contentScope: .photos
        )
        filteredDiscoveryFeeds[filterKey] = feed
        return feed
    }

    private func currentFilterSnapshot() -> DiscoveryFilterPreferencesSnapshot {
        filterPreferences?.snapshot() ?? DiscoveryFilterPreferencesSnapshot()
    }

    /// Finder 严格采用 App 图片筛选，并用 App 的统一来源开关校验该筛选仍然可用。
    private func currentFileProviderPhotoFilter() async -> FileProviderPhotoFilter {
        let enabledSourceIDs = await enabledFinderPhotoSourceIDs()
        let snapshot = currentFilterSnapshot()
        return FileProviderPhotoFilter(
            sourceID: snapshot.fileProviderPhotoSourceID(
                enabledSourceIDs: enabledSourceIDs
            ),
            enabledSourceIDs: enabledSourceIDs,
            key: snapshot.fileProviderPhotoCatalogKey(
                enabledSourceIDs: enabledSourceIDs
            )
        )
    }

    /// Finder 与 App 使用同一头像类型集合；缓存 key 随实际类型变化，禁止回退到未选择的类型。
    private func currentFileProviderAvatarFilter() -> FileProviderAvatarFilter {
        let effectiveTypes = currentFilterSnapshot().avatarTypes
        let values = AvatarType.allCases
            .filter(effectiveTypes.contains)
            .map(\.rawValue)
            .joined(separator: ",")
        return FileProviderAvatarFilter(
            types: effectiveTypes,
            key: "provider-avatar-filter-v3:\(values)"
        )
    }
}

private struct FileProviderPhotoFilter: Sendable {
    let sourceID: PhotoSourceID?
    let enabledSourceIDs: Set<PhotoSourceID>?
    let key: String
}

private struct FileProviderAvatarFilter: Sendable {
    let types: Set<AvatarType>
    let key: String
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

/// working set 为某个已发布目录重建的完整快照。
struct ProviderScopeSnapshot: Sendable {
    let storageKey: String
    let items: [ProviderItem]
}

/// working set 一次枚举中要交付的递归成员及其逐目录发布边界。
struct ProviderRecursiveWorkingSetSnapshot: Sendable {
    let items: [ProviderItem]
    let scopes: [ProviderScopeSnapshot]
}

/// 根目录当前可发布的完整推荐序列；`nextPage` 为空表示远端已无更多内容。
struct DiscoveryRootFeed: Sendable {
    let generation: UInt64
    let records: [RemoteImageRecord]
    let nextPage: Int?
}
