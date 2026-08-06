import AppKit
import SwiftUI

/// `Settings` Scene 不提供标题参数，通过承载视图在窗口挂载时设置原生标题栏文本。
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
    }

    func update(title: String) {
        representedTitle = title
        applyTitle()
    }

    private func applyTitle() {
        window?.title = representedTitle
    }
}
