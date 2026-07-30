import MirageCore
import Foundation

/// 主窗口的唯一状态源，负责搜索、共享资料库和 File Provider 生命周期。
@MainActor
final class AppModel: ObservableObject {
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published var searchFilter: SearchFilter = .all {
        didSet { scheduleSearch() }
    }
    @Published var selection: AppSection = .discover
    @Published private(set) var searchState: SearchState = .idle
    @Published private(set) var results: [RemoteImageRecord] = []
    @Published private(set) var favorites: [RemoteImageRecord] = []
    @Published private(set) var recent: [RecentImageRecord] = []
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var providerState: ProviderState = .checking
    @Published var libraryNotice: String?

    private let domainManager = MirageDomainManager()
    private let searchService = ImageSearchService()
    private var storage: AppGroupStorage?
    private var searchTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var providerCheckTask: Task<Void, Never>?
    private var latestLibraryRevision: UInt64 = 0

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
        guard let storage else {
            libraryNotice = "共享资料库尚未准备好。"
            return
        }
        do {
            let snapshot = try await storage.toggleFavorite(record)
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

    /// 网络恢复或限流结束后，由用户立即重试当前条件。
    func retrySearch() {
        scheduleSearch()
    }

    /// 初始化共享 App Group 存储，并加载已有收藏和最近使用。
    private func prepareLibrary() async {
        do {
            storage = try AppGroupStorage()
            await refreshLibrary()
        } catch {
            libraryNotice = "无法打开共享资料库：\(error.localizedDescription)"
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

    /// 每次条件变化立即取消旧任务，并在 400 毫秒静默期后执行新搜索。
    private func scheduleSearch() {
        searchTask?.cancel()
        let request = searchFilter.serviceQuery(for: query)
        let parsed = SearchQueryParser.parse(request)
        guard parsed.text.count >= 2 else {
            results = []
            searchState = .idle
            return
        }
        searchState = .searching
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                let found = try await searchService.search(request)
                try Task.checkCancellation()
                results = found
                searchState = found.isEmpty ? .empty : .results
            } catch is CancellationError {
                return
            } catch let error as OpenverseError {
                guard !Task.isCancelled else { return }
                self?.results = []
                self?.searchState = SearchState(openverseError: error)
            } catch {
                guard !Task.isCancelled else { return }
                self?.results = []
                self?.searchState = .failed(error.localizedDescription)
            }
        }
    }
}
