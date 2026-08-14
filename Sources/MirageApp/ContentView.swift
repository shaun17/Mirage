import AppKit
import MirageCore
import MirageDetailWindow
import SwiftUI

/// 主窗口只用于发现和管理内容；上传动作始终发生在目标 App 的文件面板中。
struct ContentView: View {
    /// 应用入口创建并持有模型；嵌套搜索模型不会由 AppModel 转发，因此需要单独观察。
    @ObservedObject var model: AppModel
    @ObservedObject private var searchModel: SearchModel

    /// 场景阶段用于在窗口重新进入前台时同步 File Provider 写入的数据。
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.locale) private var locale

    /// 整个窗口共用一个覆盖式详情抽屉；每张卡片各挂 popover 会在长列表里堆出成百个呈现上下文。
    @State private var inspectedRecord: RemoteImageRecord?
    @State private var detailSelectionRevision: UInt = 0
    @State private var showsUsageHelp = false
    @State private var lastAnnouncedProviderState: ProviderState?

    init(model: AppModel) {
        self.model = model
        _searchModel = ObservedObject(wrappedValue: model.searchModel)
    }

    /// 构建主导航，并让前台刷新任务严格跟随当前场景阶段。
    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            ZStack(alignment: .trailing) {
                selectedContent

                if let inspectedRecord {
                    DetailDrawerShell(
                        record: inspectedRecord,
                        onDismiss: dismissDetailDrawer
                    )
                    .transition(detailDrawerTransition)
                    .zIndex(1)
                }
            }
            // 标题属于 detail 列；挂在整个 SplitView 上时，AppKit 可能保留切换前的标题。
            .navigationTitle(
                Text(verbatim: model.selection.resolvedTitle(locale: locale))
            )
        }
        .background {
            DetailDrawerInteractionMonitor(
                isEnabled: inspectedRecord != nil,
                drawerWidth: DetailDrawerMetrics.width,
                selectionRevision: detailSelectionRevision,
                onEscape: dismissDetailDrawer,
                onOutsideClick: dismissDetailDrawerIfSelectionUnchanged
            )
            .allowsHitTesting(false)

            MainWindowTitleConfigurator(
                title: model.selection.resolvedTitle(locale: locale)
            )
            .allowsHitTesting(false)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showsUsageHelp = true
                } label: {
                    Label {
                        Text(verbatim: AppDisplayMessage.localized("使用说明").resolved(locale: locale))
                    } icon: {
                        Image(systemName: "questionmark.circle")
                    }
                }
                .help(
                    AppDisplayMessage.localized("如何在上传框中使用 Mirage")
                        .resolved(locale: locale)
                )
                .popover(isPresented: $showsUsageHelp, arrowEdge: .bottom) {
                    UsageHelpPopover(locale: locale)
                }
            }
        }
        .alert("Mirage", isPresented: noticeIsPresented) {
            Button("好") { model.libraryNotice = nil }
        } message: {
            Text(verbatim: model.libraryNotice?.resolved(locale: locale) ?? "")
        }
        .onChange(of: searchLifecycleState.isActive, initial: true) { _, isActive in
            // 同步状态变化直接提交，避免旧异步 task 在取消后反向覆盖最新生命周期。
            model.searchModel.setActive(isActive)
        }
        .onChange(of: model.selection) { oldSelection, newSelection in
            guard oldSelection != newSelection else { return }
            dismissDetailDrawer()
        }
        .onChange(of: searchModel.filter) { oldFilter, newFilter in
            guard oldFilter.crossesGIFBoundary(to: newFilter) else { return }
            dismissDetailDrawer()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, inspectedRecord?.source == .giphy else { return }
            dismissDetailDrawer()
        }
        .onChange(of: model.favoriteIDs) { oldIDs, newIDs in
            guard
                let inspectedRecord,
                oldIDs.contains(inspectedRecord.id),
                !newIDs.contains(inspectedRecord.id)
            else {
                return
            }
            dismissDetailDrawer()
        }
        .onChange(of: model.providerState) { _, state in
            guard let message = state.accessibilityAnnouncement else { return }
            guard state != lastAnnouncedProviderState else { return }
            lastAnnouncedProviderState = state
            AccessibilityNotification.Announcement(
                message.resolved(locale: locale)
            ).post()
        }
        .task(id: scenePhase) {
            // 返回前台时同时同步资料库并复查扩展，用户启用后无需重启 App。
            guard scenePhase == .active, !Task.isCancelled else { return }
            async let library: Void = model.refreshLibrary()
            async let provider: Void = model.configureProvider()
            _ = await (library, provider)
        }
    }

    /// 根据侧栏选择展示固定的三个内容区。
    @ViewBuilder
    private var selectedContent: some View {
        switch model.selection {
        case .discover:
            DiscoverView(
                model: model,
                searchModel: searchModel,
                onShowDetails: { presentDetailDrawer(for: $0) }
            )
        case .favorites:
            libraryContent {
                FavoritesGridView(
                    records: model.favorites,
                    favoriteIDs: model.favoriteIDs,
                    isRefreshingGiphy: model.isRefreshingGiphyFavorites,
                    unresolvedGiphyCount: model.unresolvedGiphyFavoriteCount,
                    onToggleFavorite: { record in
                        Task { await model.toggleFavorite(record) }
                    },
                    onShowDetails: { presentDetailDrawer(for: $0) }
                )
            }
        case .recent:
            libraryContent {
                RecentGridView(
                    records: model.recent,
                    favoriteIDs: model.favoriteIDs,
                    allowsFavoriteChanges: model.libraryAvailability.allowsFavoriteChanges,
                    onToggleFavorite: { record in
                        Task { await model.toggleFavorite(record) }
                    },
                    onShowDetails: { presentDetailDrawer(for: $0) }
                )
            }
        }
    }

    /// 收藏与最近使用只有在共享资料库可读时才展示空态，失败不能伪装成“没有内容”。
    @ViewBuilder
    private func libraryContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        switch model.libraryAvailability {
        case .preparing:
            ProgressView("正在准备共享资料库…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            content()
        case let .failed(message):
            ContentUnavailableView(
                "资料库不可用",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(verbatim: message.resolved(locale: locale))
            )
        }
    }

    /// 覆盖式抽屉不参与主内容布局；已打开时选择其他图片只替换详情内容。
    private func presentDetailDrawer(for record: RemoteImageRecord) {
        if let inspectedRecord {
            guard inspectedRecord.id != record.id else {
                self.inspectedRecord = record
                return
            }
            detailSelectionRevision &+= 1
            self.inspectedRecord = record
            return
        }

        detailSelectionRevision &+= 1
        withAnimation(detailDrawerPresentationAnimation) {
            inspectedRecord = record
        }
    }

    /// 所有收起入口只更新一次展示状态，避免触发额外的窗口级布局。
    private func dismissDetailDrawer() {
        guard inspectedRecord != nil else { return }
        withAnimation(detailDrawerDismissalAnimation) {
            inspectedRecord = nil
        }
    }

    /// 鼠标抬起后若卡片没有切换详情，说明本次点击只是落在抽屉外部。
    private func dismissDetailDrawerIfSelectionUnchanged(_ selectionRevision: UInt) {
        guard detailSelectionRevision == selectionRevision else { return }
        dismissDetailDrawer()
    }

    /// 减少动态效果时直接切换，其他情况下沿窗口右缘滑入和滑出。
    private var detailDrawerTransition: AnyTransition {
        accessibilityReduceMotion
            ? .identity
            : .move(edge: .trailing).combined(with: .opacity)
    }

    private var detailDrawerPresentationAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeOut(duration: 0.22)
    }

    private var detailDrawerDismissalAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeIn(duration: 0.18)
    }

    /// 把可选错误消息转换成 SwiftUI Alert 所需的绑定。
    private var noticeIsPresented: Binding<Bool> {
        Binding(
            get: { model.libraryNotice != nil },
            set: { if !$0 { model.libraryNotice = nil } }
        )
    }

    /// 把两个 SwiftUI 输入收敛成一个可比较状态，任一变化都会重新计算搜索活跃性。
    private var searchLifecycleState: SearchLifecycleState {
        SearchLifecycleState(scenePhase: scenePhase, selection: model.selection)
    }
}

/// 监听当前窗口的 Escape 与抽屉外点击；视图不参与命中，原始鼠标事件仍交给卡片处理。
private struct DetailDrawerInteractionMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let drawerWidth: CGFloat
    let selectionRevision: UInt
    let onEscape: () -> Void
    let onOutsideClick: (UInt) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            drawerWidth: drawerWidth,
            selectionRevision: selectionRevision,
            onEscape: onEscape,
            onOutsideClick: onOutsideClick
        )
    }

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.window = window
        }
        context.coordinator.trackingView = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {
        context.coordinator.window = nsView.window
        context.coordinator.trackingView = nsView
        context.coordinator.isEnabled = isEnabled
        context.coordinator.drawerWidth = drawerWidth
        context.coordinator.selectionRevision = selectionRevision
        context.coordinator.onEscape = onEscape
        context.coordinator.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ nsView: WindowTrackingView, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.trackingView = nil
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        weak var window: NSWindow?
        weak var trackingView: NSView?
        var isEnabled: Bool
        var drawerWidth: CGFloat
        var selectionRevision: UInt
        var onEscape: () -> Void
        var onOutsideClick: (UInt) -> Void
        private var eventMonitor: Any?

        init(
            isEnabled: Bool,
            drawerWidth: CGFloat,
            selectionRevision: UInt,
            onEscape: @escaping () -> Void,
            onOutsideClick: @escaping (UInt) -> Void
        ) {
            self.isEnabled = isEnabled
            self.drawerWidth = drawerWidth
            self.selectionRevision = selectionRevision
            self.onEscape = onEscape
            self.onOutsideClick = onOutsideClick
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseUp]
            ) { [weak self] event in
                guard
                    let self,
                    isEnabled,
                    let window,
                    event.window === window
                else {
                    return event
                }

                if event.type == .keyDown {
                    return handleKeyDown(event)
                }
                handleOutsideMouseUp(event)
                return event
            }
        }

        private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            guard event.keyCode == 53 else { return event }
            let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            guard event.modifierFlags.intersection(modifiers).isEmpty else { return event }
            onEscape()
            return nil
        }

        private func handleOutsideMouseUp(_ event: NSEvent) {
            guard event.type == .leftMouseUp, let trackingView else { return }
            let point = trackingView.convert(event.locationInWindow, from: nil)
            let width = min(drawerWidth, trackingView.bounds.width)
            let drawerFrame = CGRect(
                x: trackingView.bounds.maxX - width,
                y: trackingView.bounds.minY,
                width: width,
                height: trackingView.bounds.height
            )
            guard !drawerFrame.contains(point) else { return }

            let revision = selectionRevision
            DispatchQueue.main.async { [weak self] in
                self?.onOutsideClick(revision)
            }
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    @MainActor
    final class WindowTrackingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

/// 抽屉背景与详情作为一个合成层移动；内容短暂延迟淡入，避免缓存图片抢在材质面板前出现。
private struct DetailDrawerShell: View {
    let record: RemoteImageRecord
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var revealsContent = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.regularMaterial)
                .contentShape(Rectangle())
                .onTapGesture { }

            if accessibilityReduceMotion || revealsContent {
                ScrollView {
                    ImageDetailPopover(record: record)
                }
                .transition(.opacity)
            }
        }
        .frame(width: DetailDrawerMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) {
            Color.secondary.opacity(0.2)
                .frame(width: 1)
        }
        .overlay(alignment: .topTrailing) {
            ZStack {
                Color.clear
                Image(systemName: "chevron.right.2")
                    .font(.body.weight(.semibold))
            }
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
            .help("收起详情（Esc）")
            .accessibilityElement()
            .accessibilityLabel("收起详情")
            .accessibilityHint("也可按 Escape 键收起")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onDismiss() }
        }
        .contentShape(Rectangle())
        .clipped()
        .shadow(color: .black.opacity(0.12), radius: 10, x: -3)
        .task(id: accessibilityReduceMotion) {
            if accessibilityReduceMotion {
                revealsContent = true
                return
            }
            guard !revealsContent else { return }
            do {
                try await Task.sleep(for: .milliseconds(35))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                revealsContent = true
            }
        }
    }
}

/// 搜索只有在窗口位于前台且用户正在浏览“发现”时才允许联网。
private struct SearchLifecycleState: Equatable {
    let scenePhase: ScenePhase
    let selection: AppSection

    var isActive: Bool {
        scenePhase == .active && selection == .discover
    }
}
