import MirageCore
import Foundation

/// 主窗口的资料库状态源；搜索由独立 SearchModel 管理，本类型负责收藏、最近使用和扩展生命周期。
@MainActor
final class AppModel: ObservableObject {
    @Published var selection: AppSection = .discover
    @Published private(set) var favorites: [RemoteImageRecord] = []
    @Published private(set) var recent: [RecentImageRecord] = []
    @Published private(set) var favoriteIDs: Set<String> = []
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
    private let domainManager = MirageDomainManager()
    private var storage: AppGroupStorage?
    private var startupTask: Task<Void, Never>?
    private var providerCheckTask: Task<Void, Never>?
    private var latestLibraryRevision: UInt64 = 0

    init(photoEnvironment: PhotoSearchEnvironment = .production()) {
        self.photoEnvironment = photoEnvironment
        self.searchModel = SearchModel(
            service: photoEnvironment.imageSearchService(for: .app),
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
        guard let storage else {
            switch libraryAvailability {
            case .preparing, .ready:
                libraryNotice = "共享资料库仍在准备，请稍后再试。"
            case let .failed(message):
                libraryNotice = "收藏不可用：\(message)"
            }
            return
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
            libraryNotice = "无法更新收藏：\(error.localizedDescription)"
        }
    }

    /// 只发布更新的资料库快照，防止较早发起但较晚恢复的任务覆盖新状态。
    private func applyLibrarySnapshot(_ snapshot: LibrarySnapshot) {
        guard snapshot.revision > latestLibraryRevision else { return }
        latestLibraryRevision = snapshot.revision
        favoriteIDs = snapshot.favoriteIDs
        favorites = snapshot.favorites
        recent = snapshot.recent
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
        providerState = .checking
        do {
            _ = try await domainManager.registerIfNeeded()
            switch try await domainManager.refreshDiscoveryAndCheckAvailability() {
            case .ready: providerState = .ready
            case .needsActivation: providerState = .needsActivation
            }
        } catch {
            providerState = .failed(error.localizedDescription)
        }
    }

    /// 设置保存后重启主 App 搜索；只有 Finder 支持的来源才通知扩展刷新。
    private func photoSourceConfigurationDidChange(sourceID: PhotoSourceID) async {
        searchModel.sourceConfigurationDidChange(sourceID: sourceID)
        guard PhotoSourceRegistry.descriptor(for: sourceID)?.supports(.fileProvider) == true else {
            return
        }
        do {
            try await domainManager.signalDiscoveryChanged()
        } catch {
            libraryNotice = "图片数据源设置已保存，但文件面板暂未刷新：\(error.localizedDescription)"
        }
    }

}
