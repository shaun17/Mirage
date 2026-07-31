import MirageCore
import MirageDetailWindow
import SwiftUI

/// 主窗口只用于发现和管理内容；上传动作始终发生在目标 App 的文件面板中。
struct ContentView: View {
    /// 应用入口创建并持有模型，这里只观察单一状态源。
    @ObservedObject var model: AppModel

    /// 场景阶段用于在窗口重新进入前台时同步 File Provider 写入的数据。
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    /// 整个窗口共用一个覆盖式详情抽屉；每张卡片各挂 popover 会在长列表里堆出成百个呈现上下文。
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
        .overlay(alignment: .trailing) {
            if let inspectedRecord {
                ImageDetailPopover(
                    record: inspectedRecord,
                    onDismiss: dismissDetailDrawer
                )
                .frame(width: DetailDrawerMetrics.width)
                .frame(maxHeight: .infinity, alignment: .top)
                .background {
                    Rectangle()
                        .fill(.regularMaterial)
                }
                .overlay(alignment: .leading) {
                    Color.secondary.opacity(0.2)
                        .frame(width: 1)
                }
                .contentShape(Rectangle())
                .shadow(color: .black.opacity(0.12), radius: 10, x: -3)
                .transition(detailDrawerTransition)
                .zIndex(1)
            }
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
            : .move(edge: .trailing)
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

/// 搜索只有在窗口位于前台且用户正在浏览“发现”时才允许联网。
private struct SearchLifecycleState: Equatable {
    let scenePhase: ScenePhase
    let selection: AppSection

    var isActive: Bool {
        scenePhase == .active && selection == .discover
    }
}
