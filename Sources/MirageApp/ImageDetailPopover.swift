import AppKit
import MirageCore
import MirageDetailWindow
import SwiftUI

/// 展示归属、来源和许可信息，不对公版状态做超出来源声明的保证。
struct ImageDetailPopover: View {
    let record: RemoteImageRecord
    let onDismiss: () -> Void

    /// 展示图片预览及可核对的来源、作者和许可信息。
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("图片详情")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Button(action: onDismiss) {
                    Label("收起详情", systemImage: "chevron.right.2")
                        .labelStyle(.iconOnly)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("收起详情（Esc）")
                .accessibilityLabel("收起详情")
                .accessibilityHint("也可按 Escape 键收起")
            }

            ThumbnailImage(url: record.thumbnailURL, maximumPixelSize: 512)
                .id(record.thumbnailURL)
                .frame(width: 320, height: 220)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("“\(record.title)”的预览图片")

            Text(record.title)
                .font(.headline)
                .lineLimit(2)

            LabeledContent("来源", value: sourceName)
            authorRow
            linkRow(title: "来源页", url: record.sourcePageURL)
            linkRow(title: "许可", url: record.license.url, label: record.license.displayName)

            Divider()
            Text("许可信息来自内容提供方，仅供参考。使用前请核对来源页，并自行确认肖像权、商标权及其他适用限制。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: DetailDrawerMetrics.width)
        .accessibilityElement(children: .contain)
        .background {
            DetailDrawerEscapeMonitor(onEscape: onDismiss)
                .allowsHitTesting(false)
        }
    }

    /// 作者有主页时提供可点击链接，否则保留纯文本归属。
    @ViewBuilder
    private var authorRow: some View {
        if let creatorURL = record.creatorURL, let creator = record.creator {
            LabeledContent("作者") { Link(creator, destination: creatorURL) }
        } else {
            LabeledContent("作者", value: record.creator ?? "未提供")
        }
    }

    /// 缺失链接时仍明确显示状态，避免把原图地址误称为来源页。
    @ViewBuilder
    private func linkRow(title: String, url: URL?, label: String? = nil) -> some View {
        if let url {
            LabeledContent(title) {
                Link(label ?? "打开", destination: url)
            }
        } else {
            LabeledContent(title, value: label ?? "未提供")
        }
    }

    /// 使用服务品牌名表达来源，避免向用户暴露内部枚举值。
    private var sourceName: String {
        record.source == .openverse ? "Openverse" : "DiceBear"
    }
}

/// 搜索框会优先消费第一次 Escape，因此只在抽屉所在窗口的事件分发前拦截。
private struct DetailDrawerEscapeMonitor: NSViewRepresentable {
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.window = window
        }
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {
        context.coordinator.window = nsView.window
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: WindowTrackingView, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        weak var window: NSWindow?
        var onEscape: () -> Void
        private var eventMonitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard
                    event.keyCode == 53,
                    event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                    let self,
                    let window,
                    event.window === window
                else {
                    return event
                }

                onEscape()
                return nil
            }
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

    }

    @MainActor
    final class WindowTrackingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}
