import MirageCore
import MirageDetailWindow
import SwiftUI

/// 主窗口只用于发现和管理内容；上传动作始终发生在目标 App 的文件面板中。
struct ContentView: View {
    /// 应用入口创建并持有模型，这里只观察单一状态源。
    @ObservedObject var model: AppModel

    /// 场景阶段用于在窗口重新进入前台时同步 File Provider 写入的数据。
    @Environment(\.scenePhase) private var scenePhase

    /// 窗口级协调器先扩展宿主窗口，再让系统检查器占用新增空间。
    @State private var detailWindowCoordinator = DetailWindowCoordinator()

    /// 整个窗口共用一个详情检查器；每张卡片各挂 popover 会在长列表里堆出成百个呈现上下文。
    @State private var inspectedRecord: RemoteImageRecord?
    @State private var showsUsageHelp = false

    /// 构建主导航，并让前台刷新任务严格跟随当前场景阶段。
    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            selectedContent
        }
        .navigationTitle("Mirage")
        .inspector(isPresented: inspectorIsPresented) {
            Group {
                if let inspectedRecord {
                    ImageDetailPopover(record: inspectedRecord)
                }
            }
            .inspectorColumnWidth(DetailDrawerMetrics.width)
        }
        .background {
            DetailWindowReader(coordinator: detailWindowCoordinator)
                .frame(width: 0, height: 0)
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

                if inspectedRecord != nil {
                    Button(action: dismissInspector) {
                        Label("收起详情", systemImage: "chevron.right.2")
                    }
                    .help("收起详情")
                    .accessibilityLabel("收起详情")
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
                searchModel: model.searchModel,
                onShowDetails: { presentInspector(for: $0) }
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
                    onShowDetails: { presentInspector(for: $0) }
                )
            }
        case .recent:
            libraryContent(title: "最近使用") {
                RecentGridView(
                    records: model.recent,
                    favoriteIDs: model.favoriteIDs,
                    onShowDetails: { presentInspector(for: $0) }
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

    /// 第一次选择先扩展外层窗口；检查器已打开时只替换详情内容。
    private func presentInspector(for record: RemoteImageRecord) {
        detailWindowCoordinator.setPresented(true)
        withoutPresentationAnimation {
            inspectedRecord = record
        }
    }

    /// 所有收起入口共用同一条路径，确保窗口 frame 与详情选择同步恢复。
    private func dismissInspector() {
        detailWindowCoordinator.setPresented(false)
        withoutPresentationAnimation {
            inspectedRecord = nil
        }
    }

    /// 禁用检查器自身过渡，避免窗口扩展和 adaptive grid 在中间帧不同步。
    private func withoutPresentationAnimation(_ updates: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }

    /// 选中记录即打开检查器；系统关闭操作也复用统一收起路径。
    private var inspectorIsPresented: Binding<Bool> {
        Binding(
            get: { inspectedRecord != nil },
            set: { if !$0 { dismissInspector() } }
        )
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

/// 搜索只有在窗口位于前台且用户正在浏览“发现”时才允许联网。
private struct SearchLifecycleState: Equatable {
    let scenePhase: ScenePhase
    let selection: AppSection

    var isActive: Bool {
        scenePhase == .active && selection == .discover
    }
}
