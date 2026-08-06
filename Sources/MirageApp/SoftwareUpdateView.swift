import AppKit
import Combine
import Sparkle
import SwiftUI

/// 记录手动检查更新前的前台窗口，并在 Sparkle 结束弹窗或更新会话后恢复窗口层级。
@MainActor
final class SoftwareUpdateWindowCoordinator: NSObject, @MainActor SPUStandardUserDriverDelegate {
    private weak var presentingWindow: NSWindow?

    func capturePresentingWindow() {
        presentingWindow = NSApp.keyWindow
    }

    func standardUserDriverDidShowModalAlert() {
        restorePresentingWindow(clearReference: false)
    }

    func standardUserDriverWillFinishUpdateSession() {
        restorePresentingWindow(clearReference: true)
    }

    private func restorePresentingWindow(clearReference: Bool) {
        guard let presentingWindow else { return }
        if clearReference {
            self.presentingWindow = nil
        }

        Task { @MainActor [weak presentingWindow] in
            await Task.yield()
            guard let presentingWindow, presentingWindow.isVisible else { return }
            presentingWindow.makeKeyAndOrderFront(nil)
        }
    }
}

/// 集中持有 Sparkle 更新器及其窗口代理，确保菜单和 Settings 复用同一次更新会话。
@MainActor
final class SoftwareUpdateController {
    private let windowCoordinator: SoftwareUpdateWindowCoordinator
    private let updaterController: SPUStandardUpdaterController

    var updater: SPUUpdater {
        updaterController.updater
    }

    init() {
        let windowCoordinator = SoftwareUpdateWindowCoordinator()
        self.windowCoordinator = windowCoordinator
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: windowCoordinator
        )
    }

    func checkForUpdates() {
        windowCoordinator.capturePresentingWindow()
        updater.checkForUpdates()
    }
}

/// 订阅 Sparkle 的可检查状态，使所有更新入口在更新器忙碌时自动禁用。
@MainActor
final class SoftwareUpdateViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// 可在应用菜单和设置中复用的手动更新入口；后台检查仍由 Sparkle 调度。
struct SoftwareUpdateView: View {
    @StateObject private var viewModel: SoftwareUpdateViewModel
    private let controller: SoftwareUpdateController

    @MainActor
    init(controller: SoftwareUpdateController) {
        self.controller = controller
        _viewModel = StateObject(wrappedValue: SoftwareUpdateViewModel(updater: controller.updater))
    }

    var body: some View {
        Button {
            controller.checkForUpdates()
        } label: {
            Label("检查更新…", systemImage: "arrow.clockwise")
        }
        .disabled(!viewModel.canCheckForUpdates)
        .help("检查 Mirage 是否有可用的新版本")
    }
}
