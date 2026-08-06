import MirageDetailWindow
import Sparkle
import SwiftUI

/// Mirage 的应用入口；应用只维护一个主窗口和一份共享状态。
@main
@MainActor
struct MirageApp: App {
    /// 单一主窗口持有唯一模型，避免窗口之间出现彼此独立的资料库状态。
    @StateObject private var model = AppModel()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// 使用 `Window` 限制主界面为单实例，并集中注册资料库快捷键。
    var body: some Scene {
        Window("Mirage", id: "main") {
            ContentView(model: model)
                .frame(minWidth: DetailDrawerMetrics.minimumClosedWindowWidth, minHeight: 620)
                .task {
                    // 模型内部合并重复启动请求，避免窗口重新出现时重复注册域或初始化资料库。
                    await model.start()
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                SoftwareUpdateView(updater: updaterController.updater)
            }

            CommandMenu("资料库") {
                Button("发现") { model.selection = .discover }
                    .keyboardShortcut("1", modifiers: .command)
                Button("收藏") { model.selection = .favorites }
                    .keyboardShortcut("2", modifiers: .command)
                Button("最近使用") { model.selection = .recent }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }

        Settings {
            PhotoSourceSettingsView(
                model: model.sourceSettingsModel,
                providerState: model.providerState,
                onRecheckProvider: model.configureProvider
            )
        }
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
