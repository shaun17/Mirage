import MirageCore
import SwiftUI

#if APP_STORE
/// Mac App Store 版本必须通过商店更新，因此不链接 Sparkle，也不呈现站外更新入口。
@MainActor
final class SoftwareUpdateController {}

struct SoftwareUpdateView: View {
    init(controller: SoftwareUpdateController) {}

    var body: some View {
        EmptyView()
    }
}
#else
import AppKit
import Combine
import Sparkle

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

/// 手动检查更新期间使用独立面板，避免直接展示 `NSAlert.window` 暴露其内部占位控件。
private struct SoftwareUpdateCheckingView: View {
    let icon: NSImage
    let title: String
    let cancelTitle: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                Text(verbatim: title)
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: title))

            Button(action: onCancel) {
                Text(verbatim: cancelTitle)
                    .frame(minWidth: 96)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(width: 320, height: 210)
    }
}

/// Sparkle 自带提示只跟随系统语言；最新版结果需要按 Mirage 的应用内语言显式呈现。
@MainActor
final class MirageSoftwareUpdateUserDriver: SPUStandardUserDriver {
    private weak var windowCoordinator: SoftwareUpdateWindowCoordinator?
    private var checkingPanel: NSPanel?
    private var checkCancellation: (() -> Void)?

    init(hostBundle: Bundle, windowCoordinator: SoftwareUpdateWindowCoordinator) {
        self.windowCoordinator = windowCoordinator
        super.init(hostBundle: hostBundle, delegate: windowCoordinator)
    }

    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        closeCheckingPanel()

        let locale = savedAppLanguage.locale
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 210),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = localized("软件更新", locale: locale)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.contentViewController = NSHostingController(
            rootView: SoftwareUpdateCheckingView(
                icon: NSApp.applicationIconImage,
                title: localized("正在检查更新…", locale: locale),
                cancelTitle: localized("取消", locale: locale),
                onCancel: { [weak self] in
                    self?.cancelUpdateCheck()
                }
            )
        )
        panel.setContentSize(NSSize(width: 320, height: 210))
        panel.center()

        checkingPanel = panel
        checkCancellation = cancellation
        panel.makeKeyAndOrderFront(nil)
    }

    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        closeCheckingPanel()
        super.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }

    override func showUpdaterError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        closeCheckingPanel()
        super.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    override func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        closeCheckingPanel()

        let nsError = error as NSError
        guard
            let reason = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue,
            reason == SPUNoUpdateFoundReason.onLatestVersion.rawValue
                || reason == SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue
        else {
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            return
        }

        let latestItem = nsError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        let displayVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
            ?? latestItem?.displayVersionString
            ?? ""
        let locale = savedAppLanguage.locale
        let informativeText: String
        if reason == SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue,
           let availableVersion = latestItem?.displayVersionString {
            informativeText = AppDisplayMessage.localized(
                "当前运行的 Mirage %@ 比可用的最新版本 %@ 更新。",
                .text(displayVersion),
                .text(availableVersion)
            ).resolved(locale: locale)
        } else {
            informativeText = AppDisplayMessage.localized(
                "Mirage %@ 是当前的最新版本。",
                .text(displayVersion)
            ).resolved(locale: locale)
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = localized("您使用的就是最新版本！", locale: locale)
        alert.informativeText = informativeText
        alert.addButton(withTitle: localized("好", locale: locale))

        let versionHistoryURL = latestItem?.fullReleaseNotesURL ?? latestItem?.releaseNotesURL
        if versionHistoryURL != nil {
            alert.addButton(withTitle: localized("版本历史记录", locale: locale))
        }

        defer {
            windowCoordinator?.standardUserDriverDidShowModalAlert()
            acknowledgement()
        }

        let response = alert.runModal()
        if response == .alertSecondButtonReturn, let versionHistoryURL {
            NSWorkspace.shared.open(versionHistoryURL)
        }
    }

    override func dismissUpdateInstallation() {
        closeCheckingPanel()
        super.dismissUpdateInstallation()
    }

    private var savedAppLanguage: MirageAppLanguage {
        let defaults = UserDefaults(
            suiteName: AppGroupStorage.appGroupIdentifier
        ) ?? .standard
        return MirageAppLanguage.resolve(
            defaults.string(forKey: MirageAppLanguage.storageKey)
        )
    }

    private func localized(_ key: StaticString, locale: Locale) -> String {
        AppDisplayMessage.localized(key).resolved(locale: locale)
    }

    private func cancelUpdateCheck() {
        let cancellation = checkCancellation
        closeCheckingPanel()
        cancellation?()
        windowCoordinator?.standardUserDriverDidShowModalAlert()
    }

    private func closeCheckingPanel() {
        checkingPanel?.close()
        checkingPanel = nil
        checkCancellation = nil
    }
}

/// 集中持有 Sparkle 更新器及其窗口代理，确保菜单和 Settings 复用同一次更新会话。
@MainActor
final class SoftwareUpdateController {
    private let windowCoordinator: SoftwareUpdateWindowCoordinator
    private let userDriver: MirageSoftwareUpdateUserDriver
    let updater: SPUUpdater

    init() {
        let windowCoordinator = SoftwareUpdateWindowCoordinator()
        let userDriver = MirageSoftwareUpdateUserDriver(
            hostBundle: .main,
            windowCoordinator: windowCoordinator
        )
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: nil
        )
        self.windowCoordinator = windowCoordinator
        self.userDriver = userDriver
        self.updater = updater

        do {
            try updater.start()
        } catch {
            NSLog("Sparkle updater failed to start: %@", error.localizedDescription)
        }
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
#endif
