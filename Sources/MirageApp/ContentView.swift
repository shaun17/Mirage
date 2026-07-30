import SwiftUI

/// 主窗口只用于发现和管理内容；上传动作始终发生在目标 App 的文件面板中。
struct ContentView: View {
    /// 应用入口创建并持有模型，这里只观察单一状态源。
    @ObservedObject var model: AppModel

    /// 场景阶段用于在窗口重新进入前台时同步 File Provider 写入的数据。
    @Environment(\.scenePhase) private var scenePhase

    /// 构建主导航，并让前台刷新任务严格跟随当前场景阶段。
    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            selectedContent
        }
        .navigationTitle("Mirage")
        .alert("Mirage", isPresented: noticeIsPresented) {
            Button("好") { model.libraryNotice = nil }
        } message: {
            Text(model.libraryNotice ?? "")
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
            DiscoverView(model: model)
        case .favorites:
            LibraryGridView(
                title: "收藏",
                records: model.favorites,
                favoriteIDs: model.favoriteIDs,
                emptyTitle: "还没有收藏",
                emptyDescription: "在发现页点按心形按钮，收藏会同步到文件面板。",
                allowsFavoriteChanges: true,
                onToggleFavorite: { record in
                    Task { await model.toggleFavorite(record) }
                }
            )
        case .recent:
            RecentGridView(records: model.recent, favoriteIDs: model.favoriteIDs)
        }
    }

    /// 把可选错误消息转换成 SwiftUI Alert 所需的绑定。
    private var noticeIsPresented: Binding<Bool> {
        Binding(
            get: { model.libraryNotice != nil },
            set: { if !$0 { model.libraryNotice = nil } }
        )
    }
}
