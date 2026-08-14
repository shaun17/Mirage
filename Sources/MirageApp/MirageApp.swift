import MirageCore
import MirageDetailWindow
import SwiftUI

/// Mirage 的应用入口；应用只维护一个主窗口和一份共享状态。
@main
@MainActor
struct MirageApp: App {
    /// 单一主窗口持有唯一模型，避免窗口之间出现彼此独立的资料库状态。
    @StateObject private var model = AppModel()
    @StateObject private var languageState = AppLanguageState()
    private let softwareUpdateController = SoftwareUpdateController()

    /// 使用 `Window` 限制主界面为单实例，并集中注册资料库快捷键。
    var body: some Scene {
        Window("Mirage", id: "main") {
            ContentView(model: model)
                .frame(minWidth: DetailDrawerMetrics.minimumClosedWindowWidth, minHeight: 620)
                .environment(\.locale, languageState.language.locale)
                .task {
                    // 模型内部合并重复启动请求，避免窗口重新出现时重复注册域或初始化资料库。
                    await model.start()
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                SoftwareUpdateView(controller: softwareUpdateController)
            }
            LibraryCommands(model: model, languageState: languageState)
        }
        .environment(\.locale, languageState.language.locale)

        Settings {
            PhotoSourceSettingsView(
                model: model.sourceSettingsModel,
                providerState: model.providerState,
                softwareUpdateController: softwareUpdateController,
                appLanguage: appLanguageBinding,
                onRecheckProvider: model.configureProvider
            )
            .environment(\.locale, languageState.language.locale)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .environment(\.locale, languageState.language.locale)
    }

    private var appLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { languageState.language },
            set: { language in
                guard languageState.save(language) else { return }
                model.appLanguageDidChange()
            }
        )
    }
}

/// 菜单栏有独立于窗口 View 的生命周期，需要直接观察语言状态才能重建标题。
private struct LibraryCommands: Commands {
    let model: AppModel
    @ObservedObject var languageState: AppLanguageState

    private var usesEnglish: Bool {
        languageState.language.locale.language.languageCode?.identifier == "en"
    }

    @CommandsBuilder
    var body: some Commands {
        if usesEnglish {
            CommandMenu("Library") {
                Button("Discover") { model.selection = .discover }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Favorites") { model.selection = .favorites }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Recents") { model.selection = .recent }
                    .keyboardShortcut("3", modifiers: .command)
            }
        } else {
            CommandMenu("资料库") {
                Button("发现") { model.selection = .discover }
                    .keyboardShortcut("1", modifiers: .command)
                Button("收藏") { model.selection = .favorites }
                    .keyboardShortcut("2", modifiers: .command)
                Button("最近使用") { model.selection = .recent }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }
    }
}
