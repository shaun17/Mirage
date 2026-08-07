import AppKit
import SwiftUI

/// `Settings` Scene 不提供标题参数；清空窗口名称，并隐藏系统居中的标题绘制。
struct SettingsWindowTitleConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> SettingsWindowTitleView {
        SettingsWindowTitleView(title: title)
    }

    func updateNSView(_ nsView: SettingsWindowTitleView, context: Context) {
        nsView.update(title: title)
    }
}

final class SettingsWindowTitleView: NSView {
    private var representedTitle: String

    init(title: String) {
        representedTitle = title
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTitle()
        scheduleTitleUpdate()
    }

    func update(title: String) {
        representedTitle = title
        applyTitle()
        scheduleTitleUpdate()
    }

    private func scheduleTitleUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.applyTitle()
        }
    }

    private func applyTitle() {
        guard let window else { return }
        window.title = representedTitle
        window.titleVisibility = .hidden
    }
}
