import AppKit
import SwiftUI

/// 从稳定的 SwiftUI 根视图解析实际宿主窗口，避免误取 popover 或其他 AppKit 窗口。
public struct DetailWindowReader: NSViewRepresentable {
    private let coordinator: DetailWindowCoordinator

    public init(coordinator: DetailWindowCoordinator) {
        self.coordinator = coordinator
    }

    public func makeNSView(context: Context) -> NSView {
        DetailWindowProbeView(coordinator: coordinator)
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let probe = nsView as? DetailWindowProbeView else { return }
        probe.coordinator = coordinator
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Void) {
        guard let probe = nsView as? DetailWindowProbeView else { return }
        probe.coordinator?.attach(to: nil)
        probe.coordinator = nil
    }
}

@MainActor
private final class DetailWindowProbeView: NSView {
    weak var coordinator: DetailWindowCoordinator?

    init(coordinator: DetailWindowCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.attach(to: window)
    }
}
