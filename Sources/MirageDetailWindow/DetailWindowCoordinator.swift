import AppKit
import Foundation

/// 将纯布局状态机应用到当前 SwiftUI 宿主窗口，并避开系统管理中的窗口状态。
@MainActor
public final class DetailWindowCoordinator {
    private weak var window: NSWindow?
    private var layoutState = DetailWindowLayoutState()
    private var isPresented = false
    private var observerTokens: [NSObjectProtocol] = []

    public init() {}

    /// 绑定当前宿主窗口；视图迁移或销毁时同时清理旧窗口通知。
    public func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        removeObservers()
        self.window = window
        layoutState = DetailWindowLayoutState()
        guard let window else { return }
        observeWindowState(window)
        reconcileWindowFrame()
    }

    /// 只响应详情可见性的边界变化，切换记录不会重复扩展窗口。
    public func setPresented(_ isPresented: Bool) {
        guard self.isPresented != isPresented else { return }
        self.isPresented = isPresented
        reconcileWindowFrame()
    }

    /// 全屏、zoom 和实时缩放由 AppKit 接管，恢复普通状态后再提交待处理 frame。
    private func reconcileWindowFrame() {
        guard let window, canAdjustFrame(of: window) else { return }
        guard let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        guard let target = layoutState.targetFrame(
            whenPresented: isPresented,
            currentFrame: window.frame,
            visibleFrame: visibleFrame
        ), target != window.frame else { return }
        window.setFrame(target, display: true, animate: false)
    }

    private func canAdjustFrame(of window: NSWindow) -> Bool {
        !window.styleMask.contains(.fullScreen)
            && !window.isZoomed
            && !window.inLiveResize
    }

    /// 窗口离开系统管理状态时重放最新可见性，不跟随每次 frame 通知重复计算。
    private func observeWindowState(_ window: NSWindow) {
        let names: [Notification.Name] = [
            NSWindow.didExitFullScreenNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didResizeNotification
        ]
        let center = NotificationCenter.default
        observerTokens = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcileWindowFrame()
                }
            }
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        observerTokens.forEach(center.removeObserver)
        observerTokens.removeAll()
    }
}
