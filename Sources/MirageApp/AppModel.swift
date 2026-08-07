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
    @Published var libraryNotice: String?

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
            applyLibrarySnapshot(snapshot)
            await refreshGiphyFavorites(for: snapshot)
        } catch is CancellationError {
            return
        } catch {
            libraryNotice = "无法读取共享资料库：\(error.localizedDescription)"
        }
    }

    /// 收藏写入共享存储后刷新收藏目录与工作集，使打开的文件面板及时更新。
    func toggleFavorite(_ record: RemoteImageRecord) async {
        let isRemovingExistingFavorite = favoriteIDs.contains(record.id)
        guard record.source.allowsPersistentLibraryStorage || isRemovingExistingFavorite else {
            libraryNotice = "\(record.source.displayName) 当前仅支持临时搜索预览，请从来源页打开并下载图片。"
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
                libraryNotice = "收藏不可用：\(message)"
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
            applyLibrarySnapshot(snapshot)
            do {
                try await domainManager.signalFavoritesChanged()
            } catch {
                libraryNotice = "收藏已保存，但文件面板暂未刷新：\(error.localizedDescription)"
            }
        } catch {
            if let previousLiveGiphyRecord {
                liveGiphyFavoritesByID[record.id] = previousLiveGiphyRecord
            } else {
                liveGiphyFavoritesByID.removeValue(forKey: record.id)
            }
            libraryNotice = "无法更新收藏：\(error.localizedDescription)"
        }
    }

    /// 只发布更新的资料库快照，防止较早发起但较晚恢复的任务覆盖新状态。
    private func applyLibrarySnapshot(_ snapshot: LibrarySnapshot) {
        guard snapshot.revision > latestLibraryRevision else { return }
        latestLibraryRevision = snapshot.revision
        persistedFavorites = snapshot.favorites
        favoriteIDs = snapshot.favoriteIDs
        liveGiphyFavoritesByID = liveGiphyFavoritesByID.filter {
            snapshot.favoriteIDs.contains($0.key)
        }
        rebuildFavoritePresentation()
        recent = snapshot.recent
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
                libraryNotice = "有 \(unresolvedGiphyFavoriteCount) 项 GIPHY 收藏已不可用或被下架。"
            }
        } catch is CancellationError {
            return
        } catch {
            guard latestLibraryRevision == requestedRevision else { return }
            rebuildFavoritePresentation()
            libraryNotice = "GIPHY 收藏暂时无法加载：\(error.localizedDescription)"
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
            let message = error.localizedDescription
            libraryAvailability = .failed(message)
            libraryNotice = "无法打开共享资料库：\(message)"
            searchModel.useRecommendationFallback()
        }
    }

    /// 幂等注册系统域，再用系统可见 URL 与枚举 signal 验证扩展是否真实可用。
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

    /// 将注册成功与扩展已启用分开，避免首次安装时显示虚假的成功状态。
    private func performProviderCheck() async {
        // 已就绪后的后台复查不再插入临时状态栏，避免设置页内容上下跳动；
        // 首次检查与异常状态下的手动重试仍展示检查进度。
        if providerState != .ready {
            providerState = .checking
        }
        do {
            _ = try await domainManager.registerIfNeeded()
            try await domainManager.refreshAvatarCatalogAfterUpgradeIfNeeded()
            switch try await domainManager.refreshDiscoveryAndCheckAvailability() {
            case .ready: providerState = .ready
            case .needsActivation: providerState = .needsActivation
            }
        } catch {
            providerState = .failed(error.localizedDescription)
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
            libraryNotice = "图片数据源设置已保存，但文件面板暂未刷新：\(error.localizedDescription)"
        }
    }

}
