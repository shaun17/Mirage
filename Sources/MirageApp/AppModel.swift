import MirageCore
import Foundation

/// 主窗口的资料库状态源；搜索由独立 SearchModel 管理，本类型负责收藏、最近使用和扩展生命周期。
@MainActor
final class AppModel: ObservableObject {
    @Published var selection: AppSection = .discover
    @Published private(set) var favorites: [RemoteImageRecord] = []
    @Published private(set) var recent: [RecentImageRecord] = []
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var isRefreshingGiphyFavorites = false
    @Published private(set) var unresolvedGiphyFavoriteCount = 0
    @Published private(set) var libraryAvailability: LibraryAvailability = .preparing
    @Published private(set) var providerState: ProviderState = .checking
    @Published var libraryNotice: AppDisplayMessage?

    let searchModel: SearchModel
    lazy var sourceSettingsModel = PhotoSourceSettingsModel(
        environment: photoEnvironment,
        configurationDidChange: { [weak self] sourceID in
            await self?.photoSourceConfigurationDidChange(sourceID: sourceID)
        }
    )
    private let photoEnvironment: PhotoSearchEnvironment
    private let domainManager: MirageDomainManager
    private var storage: AppGroupStorage?
    private var startupTask: Task<Void, Never>?
    private var providerCheckTask: Task<Void, Never>?
    private var favoriteRenditionTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// 两条串行 lane 将收藏下载限制为最多 2 路，避免连续收藏触发无界解码峰值。
    private var favoriteRenditionLaneTails: [Task<Void, Never>?] = [nil, nil]
    private var nextFavoriteRenditionLane = 0
    private var favoriteRenditionSignalTask: Task<Void, Never>?
    private var isFavoriteRenditionSignalPending = false
    private var hasAppliedLibrarySnapshot = false
    private var latestLibraryRevision: UInt64 = 0
    private var persistedFavorites: [RemoteImageRecord] = []
    private var liveGiphyFavoritesByID: [String: RemoteImageRecord] = [:]

    init(
        photoEnvironment: PhotoSearchEnvironment = .production(),
        avatarTypeSelectionStore: AvatarTypeSelectionStore = .standard,
        giphyContentTypeSelectionStore: GiphyContentTypeSelectionStore = .standard,
        photoSourceSelectionStore: PhotoSourceFilterSelectionStore = .standard
    ) {
        let appAvatarProvider = AvatarCatalogClient(includesPicrewDiscovery: true)
        let domainManager = MirageDomainManager()
        self.photoEnvironment = photoEnvironment
        self.domainManager = domainManager
        self.searchModel = SearchModel(
            service: photoEnvironment.imageSearchService(
                for: .app,
                diceBear: appAvatarProvider
            ),
            photoSearchService: { selectedSourceID in
                photoEnvironment.imageSearchService(
                    for: .app,
                    selectedSourceID: selectedSourceID,
                    diceBear: appAvatarProvider
                )
            },
            initialAvatarTypeSelection: avatarTypeSelectionStore.load(),
            avatarTypeSelectionDidChange: { selection in
                avatarTypeSelectionStore.save(selection)
                Task {
                    try? await domainManager.signalAvatarFilterChanged()
                }
            },
            initialGiphyContentTypeSelection: giphyContentTypeSelectionStore.load(),
            giphyContentTypeSelectionDidChange: { selection in
                giphyContentTypeSelectionStore.save(selection)
            },
            initialPhotoSourceSelection: photoSourceSelectionStore.load(),
            photoSourceSelectionDidChange: { selection in
                photoSourceSelectionStore.save(selection)
                Task {
                    try? await domainManager.signalPhotoFilterChanged()
                }
            },
            waitsForRecommendationFeed: true
        )
    }

    /// 同一时刻的窗口启动调用共享一个任务；后续激活仍可重新检查系统扩展状态。
    func start() async {
        if let startupTask {
            await startupTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStart()
        }
        startupTask = task
        await task.value
        startupTask = nil
    }

    /// 首次启动并行准备共享资料库和 File Provider，任一失败都不会阻塞另一项。
    private func performStart() async {
        let sourceSnapshot = await photoEnvironment.preferences.snapshot()
        searchModel.updatePhotoSourcePreferences(sourceSnapshot)
        async let provider: Void = configureProvider()
        async let library: Void = prepareLibrary()
        _ = await (provider, library)
    }

    /// 重新读取收藏与最近使用，供窗口重新获得焦点时同步扩展写入的记录。
    func refreshLibrary() async {
        guard let storage else { return }
        do {
            let snapshot = try await storage.readLibrarySnapshot()
            try Task.checkCancellation()
            guard applyLibrarySnapshot(snapshot) else { return }
            do {
                try await scheduleMissingFavoriteRenditions(from: snapshot, storage: storage)
            } catch {
                retryPendingFavoriteRenditionSignalIfNeeded()
                throw error
            }
            retryPendingFavoriteRenditionSignalIfNeeded()
            guard snapshot.revision == latestLibraryRevision else { return }
            await refreshGiphyFavorites(for: snapshot)
        } catch is CancellationError {
            return
        } catch {
            libraryNotice = .localized(
                "无法读取共享资料库：%@",
                .message(.error(error))
            )
        }
    }

    /// 收藏写入共享存储后刷新收藏目录与工作集，使打开的文件面板及时更新。
    func toggleFavorite(_ record: RemoteImageRecord) async {
        let isRemovingExistingFavorite = favoriteIDs.contains(record.id)
        guard record.source.allowsPersistentLibraryStorage || isRemovingExistingFavorite else {
            libraryNotice = .localized(
                "%@ 当前仅支持临时搜索预览，请从来源页打开并下载图片。",
                .text(record.source.displayName)
            )
            return
        }
        let normalizedGiphyID = record.giphyID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if record.source == .giphy,
           !isRemovingExistingFavorite,
           normalizedGiphyID?.isEmpty != false {
            libraryNotice = "该 GIPHY 内容缺少可安全保存的对象标识，请刷新后重试。"
            return
        }
        guard let storage else {
            switch libraryAvailability {
            case .preparing, .ready:
                libraryNotice = "共享资料库仍在准备，请稍后再试。"
            case let .failed(message):
                libraryNotice = .localized("收藏不可用：%@", .message(message))
            }
            return
        }
        let previousLiveGiphyRecord = liveGiphyFavoritesByID[record.id]
        if record.source == .giphy, !isRemovingExistingFavorite {
            liveGiphyFavoritesByID[record.id] = record
        }
        do {
            let snapshot: LibrarySnapshot
            if record.source.allowsPersistentLibraryStorage {
                snapshot = try await storage.toggleFavorite(record)
            } else {
                snapshot = try await storage.removeFavorite(id: record.id)
            }
            _ = applyLibrarySnapshot(snapshot)
            let currentFavorite = persistedFavorites.first { $0.id == record.id }
            if currentFavorite == nil {
                favoriteRenditionTasks.removeValue(forKey: record.id)?.task.cancel()
                retryPendingFavoriteRenditionSignalIfNeeded()
            } else if let currentFavorite,
                      currentFavorite.source.allowsMediaCaching {
                let sourceRecord = record == currentFavorite
                    ? record
                    : currentFavorite
                scheduleFavoriteRendition(
                    from: sourceRecord,
                    for: currentFavorite,
                    storage: storage
                )
            }
            do {
                try await domainManager.signalFavoritesChanged()
            } catch {
                libraryNotice = .localized(
                    "收藏已保存，但文件面板暂未刷新：%@",
                    .message(.error(error))
                )
            }
        } catch {
            if let previousLiveGiphyRecord {
                liveGiphyFavoritesByID[record.id] = previousLiveGiphyRecord
            } else {
                liveGiphyFavoritesByID.removeValue(forKey: record.id)
            }
            libraryNotice = .localized(
                "无法更新收藏：%@",
                .message(.error(error))
            )
        }
    }

    /// 收藏关系先落盘并刷新 UI；媒体副本在后台生成，失败时保留收藏并由 Finder 按需重试。
    private func scheduleFavoriteRendition(
        from sourceRecord: RemoteImageRecord,
        for favoriteRecord: RemoteImageRecord,
        storage: AppGroupStorage
    ) {
        favoriteRenditionTasks.removeValue(forKey: favoriteRecord.id)?.task.cancel()
        let token = UUID()
        let lane = nextFavoriteRenditionLane
        nextFavoriteRenditionLane = (nextFavoriteRenditionLane + 1) % favoriteRenditionLaneTails.count
        let predecessor = favoriteRenditionLaneTails[lane]
        let task = Task(priority: .utility) { [weak self, storage, sourceRecord, favoriteRecord] in
            await predecessor?.value
            guard !Task.isCancelled else { return }
            let committed = await Self.persistFavoriteRendition(
                from: sourceRecord,
                for: favoriteRecord,
                storage: storage
            )
            guard !Task.isCancelled, let self,
                  self.favoriteRenditionTasks[favoriteRecord.id]?.token == token else { return }
            self.favoriteRenditionTasks.removeValue(forKey: favoriteRecord.id)
            if committed {
                self.isFavoriteRenditionSignalPending = true
            }
            self.retryPendingFavoriteRenditionSignalIfNeeded()
        }
        favoriteRenditionLaneTails[lane] = task
        favoriteRenditionTasks[favoriteRecord.id] = (token, task)
    }

    /// 升级后的既有收藏也会懒补齐；已缓存或正在下载的记录不会重复排队。
    private func scheduleMissingFavoriteRenditions(
        from snapshot: LibrarySnapshot,
        storage: AppGroupStorage
    ) async throws {
        let cachedIDs = try await storage.favoriteRenditionIDs()
        try Task.checkCancellation()
        guard snapshot.revision == latestLibraryRevision else { return }
        let currentFavoritesByID = Dictionary(
            persistedFavorites.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let recentByID = Dictionary(
            snapshot.recent.map { ($0.id, $0.image) },
            uniquingKeysWith: { first, _ in first }
        )
        for record in snapshot.favorites
        where record.source.allowsMediaCaching
            && !cachedIDs.contains(record.id)
            && favoriteIDs.contains(record.id)
            && currentFavoritesByID[record.id] == record
            && favoriteRenditionTasks[record.id] == nil {
            let sourceRecord: RemoteImageRecord
            if let recent = recentByID[record.id], recent.source == record.source {
                sourceRecord = recent
            } else {
                sourceRecord = record
            }
            scheduleFavoriteRendition(
                from: sourceRecord,
                for: record,
                storage: storage
            )
        }
    }

    /// 短 debounce 合并同批完成事件，但不等待慢任务；失败保持 pending，等待下次刷新重试。
    private func retryPendingFavoriteRenditionSignalIfNeeded() {
        guard isFavoriteRenditionSignalPending,
              favoriteRenditionSignalTask == nil else { return }
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                self?.favoriteRenditionSignalTask = nil
                return
            }
            guard let self else { return }
            // 先消费本轮 pending；若 signal 等待期间又有副本完成，新变化会重新置为 pending。
            self.isFavoriteRenditionSignalPending = false
            do {
                try await self.domainManager.signalFavoritesChanged()
                self.favoriteRenditionSignalTask = nil
                self.retryPendingFavoriteRenditionSignalIfNeeded()
            } catch {
                self.isFavoriteRenditionSignalPending = true
                self.favoriteRenditionSignalTask = nil
                NSLog("Mirage 收藏图片副本已保存，但 Finder 刷新失败：%@", String(describing: error))
            }
        }
        favoriteRenditionSignalTask = task
    }

    /// 网络与图片转码均离开 MainActor；提交前存储层会再次确认该 ID 仍处于收藏状态。
    private nonisolated static func persistFavoriteRendition(
        from sourceRecord: RemoteImageRecord,
        for favoriteRecord: RemoteImageRecord,
        storage: AppGroupStorage
    ) async -> Bool {
        guard sourceRecord.id == favoriteRecord.id,
              sourceRecord.source == favoriteRecord.source,
              favoriteRecord.source.allowsMediaCaching else { return false }
        // 长期副本只从完整内容生成；独立缩略图地址只能用于临时预览，不能永久占用收藏副本。
        let candidateURLs = [sourceRecord.imageURL]
        var finalError: Error?

        for url in candidateURLs {
            do {
                try Task.checkCancellation()
                let sourceData: Data
                if url.scheme == AvatarSnapshotReference.scheme,
                   let reference = AvatarSnapshotReference(url: url),
                   let snapshot = try await storage.readAvatarSnapshot(key: reference.key) {
                    sourceData = snapshot
                } else {
                    sourceData = try await BoundedDownloader(
                        url: url,
                        maximumBytes: ImageTranscoder.defaultMaximumBytes,
                        timeoutInterval: 30
                    ).download()
                }
                try Task.checkCancellation()
                let rendition = try ImageTranscoder().transcode(sourceData)
                try Task.checkCancellation()
                return try await storage.commitFavoriteRenditionIfFavorited(
                    rendition,
                    for: favoriteRecord
                )
            } catch is CancellationError {
                return false
            } catch {
                finalError = error
                continue
            }
        }
        if let finalError {
            NSLog(
                "Mirage 收藏图片副本生成失败（%@）：%@",
                favoriteRecord.id,
                String(describing: finalError)
            )
        }
        return false
    }

    /// 只发布更新的资料库快照，防止较早发起但较晚恢复的任务覆盖新状态。
    @discardableResult
    private func applyLibrarySnapshot(_ snapshot: LibrarySnapshot) -> Bool {
        guard !hasAppliedLibrarySnapshot
                || snapshot.revision >= latestLibraryRevision else { return false }
        if hasAppliedLibrarySnapshot,
           snapshot.revision == latestLibraryRevision {
            return true
        }
        hasAppliedLibrarySnapshot = true
        latestLibraryRevision = snapshot.revision
        persistedFavorites = snapshot.favorites
        favoriteIDs = snapshot.favoriteIDs
        liveGiphyFavoritesByID = liveGiphyFavoritesByID.filter {
            snapshot.favoriteIDs.contains($0.key)
        }
        rebuildFavoritePresentation()
        recent = snapshot.recent
        return true
    }

    /// GIPHY 收藏快照只有对象 ID；媒体 URL 每次启动通过官方批量接口临时恢复。
    private func refreshGiphyFavorites(for snapshot: LibrarySnapshot) async {
        let allReferences = snapshot.favorites.filter { $0.source == .giphy }
        let references = allReferences.filter { liveGiphyFavoritesByID[$0.id] == nil }
        guard !allReferences.isEmpty else {
            isRefreshingGiphyFavorites = false
            unresolvedGiphyFavoriteCount = 0
            return
        }
        guard !references.isEmpty else {
            isRefreshingGiphyFavorites = false
            rebuildFavoritePresentation()
            return
        }
        let requestedRevision = snapshot.revision
        let ids = references.compactMap(\.giphyID)
        guard ids.count == references.count else {
            isRefreshingGiphyFavorites = false
            unresolvedGiphyFavoriteCount = references.count
            return
        }

        isRefreshingGiphyFavorites = true
        defer {
            if latestLibraryRevision == requestedRevision {
                isRefreshingGiphyFavorites = false
            }
        }
        do {
            let records = try await photoEnvironment.giphyFavoriteRecords(ids: ids)
            try Task.checkCancellation()
            guard latestLibraryRevision == requestedRevision else { return }
            let requestedIDs = Set(references.map(\.id))
            for record in records where requestedIDs.contains(record.id) {
                liveGiphyFavoritesByID[record.id] = record
            }
            rebuildFavoritePresentation()
            if unresolvedGiphyFavoriteCount > 0 {
                libraryNotice = .localized(
                    "有 %lld 项 GIPHY 收藏已不可用或被下架。",
                    .integer(unresolvedGiphyFavoriteCount)
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard latestLibraryRevision == requestedRevision else { return }
            rebuildFavoritePresentation()
            libraryNotice = .localized(
                "GIPHY 收藏暂时无法加载：%@",
                .message(.error(error))
            )
        }
    }

    /// 普通来源直接展示持久记录；GIPHY 内部引用只有成功实时回查后才进入可见网格。
    private func rebuildFavoritePresentation() {
        favorites = persistedFavorites.compactMap { record in
            guard record.source == .giphy else { return record }
            return liveGiphyFavoritesByID[record.id]
        }
        unresolvedGiphyFavoriteCount = persistedFavorites.reduce(into: 0) { count, record in
            guard record.source == .giphy,
                  liveGiphyFavoritesByID[record.id] == nil else { return }
            count += 1
        }
    }

    /// 初始化共享 App Group 存储，并加载已有收藏和最近使用。
    private func prepareLibrary() async {
        if storage != nil {
            await refreshLibrary()
            return
        }
        do {
            let sharedStorage = try AppGroupStorage()
            storage = sharedStorage
            libraryAvailability = .ready
            searchModel.configureRecommendationFeed(
                DiscoveryFeedRepository(
                    storage: sharedStorage,
                    service: photoEnvironment.imageSearchService(
                        for: .app,
                        purpose: .recommendation
                    ),
                    catalogKey: { [photoEnvironment] in
                        await photoEnvironment.recommendationCatalogKey(for: .app)
                    },
                    snapshotDidChange: { [domainManager] in
                        try await domainManager.signalDiscoveryChanged()
                    }
                )
            )
            await refreshLibrary()
        } catch {
            let message = AppDisplayMessage.error(error)
            libraryAvailability = .failed(message)
            libraryNotice = .localized("无法打开共享资料库：%@", .message(message))
            searchModel.useRecommendationFallback()
        }
    }

    /// 幂等注册系统域，再用公开状态与枚举 signal 验证扩展是否真实可用。
    func configureProvider() async {
        if let providerCheckTask {
            await providerCheckTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performProviderCheck()
        }
        providerCheckTask = task
        await task.value
        providerCheckTask = nil
    }

    /// 语言偏好已经由 App 写入共享容器；这里只负责让 File Provider 重新发布可见目录名。
    func appLanguageDidChange() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.domainManager.signalLanguageChanged()
            } catch {
                self.libraryNotice = .localized(
                    "语言已切换，但文件面板暂未刷新：%@",
                    .message(.error(error))
                )
            }
        }
    }

    /// 将注册成功与扩展已启用分开，避免首次安装时显示虚假的成功状态。
    private func performProviderCheck() async {
        // 已就绪后的后台复查不再插入临时状态栏，避免设置页内容上下跳动；
        // 首次检查与异常状态下的手动重试仍展示检查进度。
        if providerState != .ready {
            providerState = .checking
        }
        do {
            _ = try await domainManager.prepareBoundedCatalogAndRegisterIfNeeded()
            switch try await domainManager.refreshDiscoveryAndCheckAvailability() {
            case .ready: providerState = .ready
            case .needsActivation: providerState = .needsActivation
            }
        } catch {
            providerState = .failed(.error(error))
        }
    }

    /// 设置保存后重启主 App 搜索；Finder 来源配置变化按筛选级别完整失效并重新发布。
    private func photoSourceConfigurationDidChange(sourceID: PhotoSourceID) async {
        let snapshot = await photoEnvironment.preferences.snapshot()
        searchModel.sourceConfigurationDidChange(sourceID: sourceID, snapshot: snapshot)
        guard PhotoSourceRegistry.descriptor(for: sourceID)?.supports(.fileProvider) == true else {
            return
        }
        do {
            try await domainManager.signalPhotoFilterChanged()
        } catch {
            libraryNotice = .localized(
                "图片数据源设置已保存，但文件面板暂未刷新：%@",
                .message(.error(error))
            )
        }
    }

}
