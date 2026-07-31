@preconcurrency import FileProvider
import Foundation
import OSLog

/// 推荐流当前的发布状态；顺序即 Finder 中的显示顺序。
struct ProviderFeedState: Sendable {
    let identifiers: [String]
    let hasMore: Bool

    var count: Int { identifiers.count }
}

/// 读取、推进推荐流并把增量发布给系统的能力；抽出协议以便单测不触碰网络与 App Group。
protocol ProviderFeedAdvancing: Sendable {
    /// 读取当前已落盘的推荐顺序。这是泵唯一的真值来源——不依赖系统是否回调过枚举。
    func feedState() async throws -> ProviderFeedState

    /// 追加下一页并落盘。
    func advanceFeed() async throws -> Bool

    /// 轻量通知系统拉取差异：已打开的目录原地追加，不清缩略图、不闪屏。
    func publishFeedChanges() async

    /// 要求系统整树重扫。重操作：会触发全目录缩略图重新请求，只能作为
    /// signal 无效之后的修复手段，绝不能进常规补页路径。
    func forceFeedRescan() async
}

/// 把「用户在 Finder 里滚动」翻译成「向同一目录追加下一页」的增量泵。
///
/// 两个实测结论决定了这里的设计：
///
/// 1. File Provider 的目录枚举是 replicated 语义。系统会一次性抽干
///    `finishEnumerating(upTo:)` 返回的所有续页，和视口位置无关，所以系统分页
///    无法表达懒加载；而且目录内容一旦同步进系统副本，打开窗口时
///    `enumerateItems` 根本不会被再调用——枚举回调不能用作「有人在浏览」的信号。
///
/// 2. `fetchThumbnails` 是这套 API 里唯一跟随视口的回调。160 项的扁平目录，
///    打开窗口只请求 3 批共 23 项，滚动到深处才追加 5 批共 42 项，全程从未逼近 160。
///    它能稳定到达扩展，因此既是滚动位置信号，也是「有人在浏览」的充分证明。
///
/// 于是泵不持有任何推荐流副本：每次收到可见信号就向仓库读一次当前顺序，
/// 据此判断是否接近尾部。推进后顺序自然变长，水位随之后移，不需要额外的防连锁状态。
actor ProviderFeedPump: ProviderFeedPumping {
    /// 水位、首屏保底、单次会话上限与失败退避；全部可注入，便于单测锁定语义。
    struct Limits: Sendable {
        /// 可见项距离列表尾部小于该值时补下一页。
        ///
        /// 一次补页要走完「网络抓取 → 落盘 → 请求重扫 → 系统重新枚举 → 缩略图上屏」
        /// 整条链路，取两页的提前量才能赶在用户真正触底之前完成；
        /// 不到半页的余量在实测中意味着用户几乎总要在底部等待。
        var prefetchDistance: Int
        /// 目录建成时必须一次性交付的图片数。
        ///
        /// 这不是「先给一点，滚动再补」的起点，而是**用户能看到的全部**：
        /// 副本建成后无法增长，第一次枚举给多少就是多少。
        var minimumPublishedItems: Int
        /// 单个时间窗口内最多补多少页。
        ///
        /// 预算必须挂在时间上而不是枚举器会话上：每次补页引发的重新枚举都会
        /// 让系统重建枚举器，按会话重置等于没有刹车，重扫循环会把远端拉穿。
        var maximumPagesPerWindow: Int
        /// 页数预算窗口的长度（秒）；窗口过期后预算恢复，正常深滚不受影响。
        var pageWindowSeconds: TimeInterval
        /// 补页失败后的静默窗口秒数。
        var backoffSeconds: TimeInterval
        /// 同一目标长度的重扫请求间隔秒数。
        ///
        /// 副本落后期间每一批缩略图请求都会命中「存储领先」分支，而重扫是系统级
        /// 重放整棵子树的重操作；不节流就是滚动一次触发十几次重扫。
        /// 窗口过后仍允许重试，一次丢失的重扫请求不会让新内容永久搁浅。
        var publishDebounceSeconds: TimeInterval

        init(
            prefetchDistance: Int = 40,
            minimumPublishedItems: Int = 200,
            maximumPagesPerWindow: Int = 15,
            pageWindowSeconds: TimeInterval = 600,
            backoffSeconds: TimeInterval = 30,
            publishDebounceSeconds: TimeInterval = 10
        ) {
            self.prefetchDistance = prefetchDistance
            self.minimumPublishedItems = minimumPublishedItems
            self.maximumPagesPerWindow = maximumPagesPerWindow
            self.pageWindowSeconds = pageWindowSeconds
            self.backoffSeconds = backoffSeconds
            self.publishDebounceSeconds = publishDebounceSeconds
        }
    }

    private static let logger = Logger(
        subsystem: "com.wenren.Mirage.FileProvider",
        category: "FeedPump"
    )

    private let advancer: any ProviderFeedAdvancing
    private let limits: Limits
    private let now: @Sendable () -> Date

    /// 当前时间窗口的起点与已消耗页数；窗口过期即整体作废重开。
    private var pageWindow: (start: Date, pages: Int)?
    private var backoffUntil: Date?
    private var advanceTask: Task<Void, Never>?
    /// 上一次枚举真正发布给系统的条数，也就是用户在 Finder 里能看到的长度。
    /// 水位必须以它为分母：共享存储抓到多少是我们的事，用户滚到哪儿只取决于副本。
    private var publishedCount = 0
    /// 本实例是否已经拿到过真实的发布基线。冷启动实例只为缩略图被唤醒时没有基线，
    /// 必须先采用存储长度——把「内存计数为零」当成副本落后会引发重扫风暴。
    private var hasPublishedBaseline = false
    /// 在途评估期间到达的可见信号不能丢：滚动位置比「刚被枚举」更有信息量，
    /// 暂存下来等当前任务收敛后立刻复评一次。
    private var queuedVisible: Set<String>?
    /// 当前存活的根目录枚举器数量。每次补页触发的重新枚举都会让系统先建新枚举器、
    /// 稍后才失效旧的；只有降到零才代表用户真的不在浏览了。
    private var activeEnumerators = 0
    /// 针对同一存储长度的发布请求记录：时刻用于节流，次数用于决定是否升级为重扫。
    private var lastPublishRequest: (count: Int, attempts: Int, at: Date)?

    init(
        advancer: any ProviderFeedAdvancing,
        limits: Limits = Limits(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.advancer = advancer
        self.limits = limits
        self.now = now
    }

    /// 根目录开始被枚举。只登记枚举器存活数——页数预算是时间窗口，
    /// 不随枚举器重建而恢复，否则补页引发的重新枚举会把刹车拆掉。
    func arm() {
        activeEnumerators += 1
    }

    /// 一个根目录枚举器失效。重扫循环里新旧枚举器的生命周期是交叠的：
    /// 旧枚举器晚一步失效不能取消新会话的在途补页，否则每翻一页都要卡一拍；
    /// 只有最后一个失效（用户真的关闭了浏览窗口）才停泵。
    func disarm() async {
        activeEnumerators = max(0, activeEnumerators - 1)
        guard activeEnumerators == 0 else { return }
        await cancelPendingWork()
    }

    /// 扩展实例失效：无论系统还欠着多少个枚举器的 invalidate，都无条件停泵。
    func shutdown() async {
        activeEnumerators = 0
        await cancelPendingWork()
    }

    /// 丢弃暂存信号、取消在途补页，并等它真正收敛。
    /// 取消只是请求——落盘可能已经在途，不等就会和调用方的清理逻辑打架。
    private func cancelPendingWork() async {
        queuedVisible = nil
        let task = advanceTask
        advanceTask = nil
        task?.cancel()
        await task?.value
    }

    /// 根目录刚被系统枚举：记录副本的真实长度，并检查是否需要补到保底线。
    func noteEnumerated(publishedCount: Int) {
        self.publishedCount = publishedCount
        hasPublishedBaseline = true
        scheduleEvaluation(visible: [])
    }

    /// 系统为可见条目请求缩略图——既是滚动位置，也是「有人在浏览」的证明。
    func noteVisible(_ identifiers: [NSFileProviderItemIdentifier]) {
        scheduleEvaluation(visible: Set(identifiers.map(\.rawValue)))
    }

    /// 等待泵完全收敛：一次评估结束后可能因暂存的可见信号立刻再起一轮，
    /// 所以要循环到确实没有在途任务为止。扩展失效与单测都需要这个确定的收敛点。
    func waitForPendingAdvance() async {
        while let task = advanceTask {
            await task.value
        }
    }

    /// 单飞地评估一次；闸门在派发前判定，避免并发缩略图批次各起一个任务。
    /// 页数预算不在这里拦：预算只约束联网补页，不该挡住轻量的滞后通知。
    private func scheduleEvaluation(visible: Set<String>) {
        if let backoffUntil, now() < backoffUntil { return }
        guard advanceTask == nil else {
            if !visible.isEmpty { queuedVisible = (queuedVisible ?? []).union(visible) }
            return
        }
        advanceTask = Task { await self.evaluate(visible: visible) }
    }

    /// 当前任务收敛后消费暂存的可见信号，滚动不会因为撞上保底评估而丢一拍。
    private func drainQueuedVisible() {
        guard let queued = queuedVisible, !queued.isEmpty else { return }
        queuedVisible = nil
        scheduleEvaluation(visible: queued)
    }

    /// 每次评估先比对「抓到多少」与「上屏多少」，再决定是补页还是先把已有内容推上屏。
    private func evaluate(visible: Set<String>) async {
        do {
            let state = try await advancer.feedState()
            try Task.checkCancellation()
            guard state.count > 0 else { return clearTask() }

            // 冷启动实例只为缩略图被唤醒时没有发布基线，先采用存储长度。
            // 把「内存计数为零」当成副本落后会立刻请求重扫，而重扫又会引发
            // 全目录缩略图重放——那正是空白闪动自激循环的入口。
            if !hasPublishedBaseline {
                publishedCount = state.count
                hasPublishedBaseline = true
            }

            // 已经抓到但还没进系统副本的内容，必须通知系统。
            // macOS 的 replicated 副本建成后不会主动回问扩展，这一步不做就永远是抓了不显示。
            if publishedCount < state.count {
                guard shouldRequestPublish(for: state.count) else { return clearTask() }
                let attempts = lastPublishRequest?.count == state.count
                    ? (lastPublishRequest?.attempts ?? 0) + 1
                    : 1
                lastPublishRequest = (state.count, attempts, now())
                Self.logger.notice(
                    "存储 \(state.count, privacy: .public) 张 / 已上屏 \(self.publishedCount, privacy: .public) 张，通知系统增量同步"
                )
                await advancer.publishFeedChanges()
                // signal 走增量差异不闪屏；只有同一长度反复通知无效才升级为重扫修复。
                if attempts >= 2 {
                    Self.logger.notice("增量同步未奏效，升级为整树重扫")
                    await advancer.forceFeedRescan()
                }
                return clearSuccess()
            }

            guard state.hasMore else { return clearTask() }
            guard needsAdvance(state: state, visible: visible) else { return clearTask() }
            guard budgetAllowsPage() else { return clearTask() }
            countPage()
            _ = try await advancer.advanceFeed()
            try Task.checkCancellation()
            await advancer.publishFeedChanges()
            // 记下补页后的新长度：随后涌入的缩略图信号会命中「存储领先」分支，
            // 不记账它们就会立刻再触发一次针对同样内容的发布。
            if let advanced = try? await advancer.feedState() {
                lastPublishRequest = (advanced.count, 1, now())
            }
            clearSuccess()
        } catch is CancellationError {
            clearTask()
        } catch {
            Self.logger.error(
                "推荐流补页失败：\(error.localizedDescription, privacy: .public)"
            )
            enterBackoff()
        }
    }

    /// 针对同一存储长度的重扫请求在静默窗口内只发一次；长度变了说明有新内容，立即放行。
    private func shouldRequestPublish(for storeCount: Int) -> Bool {
        guard let lastPublishRequest, lastPublishRequest.count == storeCount else { return true }
        return now() >= lastPublishRequest.at.addingTimeInterval(limits.publishDebounceSeconds)
    }

    /// 首屏未达保底线，或可见项已进入尾部水位，都需要补页。
    /// 水位分母用 `publishedCount`——用户滚到的是副本的底部，不是我们抓了多少。
    private func needsAdvance(state: ProviderFeedState, visible: Set<String>) -> Bool {
        if state.count < limits.minimumPublishedItems {
            Self.logger.notice(
                "首屏 \(state.count, privacy: .public) 张未达保底线，补下一页"
            )
            return true
        }
        guard !visible.isEmpty else { return false }
        var deepest = -1
        for (index, identifier) in state.identifiers.enumerated()
        where visible.contains(identifier) {
            deepest = max(deepest, index)
        }
        let visibleLength = max(publishedCount, 1)
        // 提前量对短列表以中点兜底：列表比水位还短时，固定距离会把整个列表都算成
        // 「接近尾部」，浏览第一屏就开始拉页；过半才补页保住「头部浏览不联网」。
        let threshold = max(visibleLength / 2, visibleLength - limits.prefetchDistance)
        guard deepest >= 0, deepest >= threshold else { return false }
        Self.logger.notice(
            "可见项已到第 \(deepest, privacy: .public) 项（已上屏 \(visibleLength, privacy: .public) 张），补下一页"
        )
        return true
    }

    /// 当前窗口是否还有联网补页预算；窗口过期视为预算已恢复。
    private func budgetAllowsPage() -> Bool {
        guard let window = pageWindow,
              now() < window.start.addingTimeInterval(limits.pageWindowSeconds) else {
            return true
        }
        return window.pages < limits.maximumPagesPerWindow
    }

    /// 页数计入当前时间窗口；窗口已过期就以本页为起点重开。
    private func countPage() {
        let currentTime = now()
        if let window = pageWindow,
           currentTime < window.start.addingTimeInterval(limits.pageWindowSeconds) {
            pageWindow = (window.start, window.pages + 1)
        } else {
            pageWindow = (currentTime, 1)
        }
    }

    /// 本次评估结束但没有补页。
    private func clearTask() {
        advanceTask = nil
        drainQueuedVisible()
    }

    /// 补页成功后解除退避，允许下一次可见信号继续推进。
    private func clearSuccess() {
        advanceTask = nil
        backoffUntil = nil
        drainQueuedVisible()
    }

    /// 失败后用退避窗口挡住紧接着的重复可见事件。
    private func enterBackoff() {
        advanceTask = nil
        backoffUntil = now().addingTimeInterval(limits.backoffSeconds)
    }
}

/// 让目录构造侧只依赖最小接口，避免 `ProviderCatalog` 反向持有整个泵实现。
protocol ProviderFeedPumping: Sendable {
    func noteEnumerated(publishedCount: Int) async
    func noteVisible(_ identifiers: [NSFileProviderItemIdentifier]) async
    func arm() async
    func disarm() async
}

/// 把读取、补页与增量发布都落到共享仓库的生产实现；系统 manager 始终由仓库单独持有。
struct ProviderSystemFeedAdvancer: ProviderFeedAdvancing {
    let repository: ProviderRepository

    /// 直接读当前冻结 generation 的已累积顺序，不经过系统枚举。
    func feedState() async throws -> ProviderFeedState {
        let feed = try await repository.discoveryRootFeed()
        return ProviderFeedState(
            identifiers: feed.records.map {
                ProviderIdentifiers.itemIdentifier(recordID: $0.id, view: .discover).rawValue
            },
            hasMore: feed.hasMore
        )
    }

    /// 仓库负责在当前冻结 generation 内追加下一页并落盘。
    func advanceFeed() async throws -> Bool {
        try await repository.advanceDiscoveryFeed()
    }

    /// 只发信号不发内容：系统随后走 `enumerateChanges`，Finder 因而是原地追加而不是整目录刷新。
    func publishFeedChanges() async {
        await repository.signalDiscoveryFeedChanged()
    }

    /// 整树重扫会触发全目录缩略图重放，只在增量同步反复无效时作为修复手段。
    func forceFeedRescan() async {
        await repository.rescanDiscoveryFeed()
    }
}
