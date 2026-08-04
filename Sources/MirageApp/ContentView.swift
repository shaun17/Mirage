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

    /// 整个窗口共用一个覆盖式详情抽屉；每张卡片各挂 popover 会在长列表里堆出成百个呈现上下文。
    @State private var inspectedRecord: RemoteImageRecord?
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
        }
        .navigationTitle("Mirage")
        .background(alignment: .topLeading) {
            DetailDrawerEscapeMonitor(
                isEnabled: inspectedRecord != nil,
                onEscape: dismissDetailDrawer
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showsUsageHelp = true
                } label: {
                    Label("使用说明", systemImage: "questionmark.circle")
                }
                .help("如何在上传框中使用 Mirage")
                .popover(isPresented: $showsUsageHelp, arrowEdge: .bottom) {
                    UsageHelpPopover()
                }
            }
        }
        .alert("Mirage", isPresented: noticeIsPresented) {
            Button("好") { model.libraryNotice = nil }
        } message: {
            Text(model.libraryNotice ?? "")
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
            AccessibilityNotification.Announcement(message).post()
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
            libraryContent(title: "收藏") {
                LibraryGridView(
                    title: "收藏",
                    records: model.favorites,
                    favoriteIDs: model.favoriteIDs,
                    emptyTitle: "还没有收藏",
                    emptyDescription: "在发现页点按心形按钮，收藏会同步到文件面板。",
                    allowsFavoriteChanges: true,
                    pagination: nil,
                    onToggleFavorite: { record in
                        Task { await model.toggleFavorite(record) }
                    },
                    onShowDetails: { presentDetailDrawer(for: $0) }
                )
            }
        case .recent:
            libraryContent(title: "最近使用") {
                RecentGridView(
                    records: model.recent,
                    favoriteIDs: model.favoriteIDs,
                    onShowDetails: { presentDetailDrawer(for: $0) }
                )
            }
        }
    }

    /// 收藏与最近使用只有在共享资料库可读时才展示空态，失败不能伪装成“没有内容”。
    @ViewBuilder
    private func libraryContent<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        switch model.libraryAvailability {
        case .preparing:
            ProgressView("正在准备共享资料库…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(title)
        case .ready:
            content()
        case let .failed(message):
            ContentUnavailableView(
                "资料库不可用",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(message)
            )
            .navigationTitle(title)
        }
    }

    /// 覆盖式抽屉不参与主内容布局；已打开时选择其他图片只替换详情内容。
    private func presentDetailDrawer(for record: RemoteImageRecord) {
        guard inspectedRecord == nil else {
            inspectedRecord = record
            return
        }

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

/// 在根视图监听当前窗口的 Escape；零尺寸且不参与命中，不能覆盖抽屉的鼠标交互。
private struct DetailDrawerEscapeMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onEscape: onEscape)
    }

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.window = window
        }
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {
        context.coordinator.window = nsView.window
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: WindowTrackingView, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        weak var window: NSWindow?
        var isEnabled: Bool
        var onEscape: () -> Void
        private var eventMonitor: Any?

        init(isEnabled: Bool, onEscape: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.onEscape = onEscape
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard
                    event.keyCode == 53,
                    event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                    let self,
                    isEnabled,
                    let window,
                    event.window === window
                else {
                    return event
                }

                onEscape()
                return nil
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
                ImageDetailPopover(record: record)
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
