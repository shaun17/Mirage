import SwiftUI

/// 侧栏只承载导航；使用说明移到工具栏帮助，系统状态收敛成一行可展开的提示。
struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var lastAnnouncedProviderState: ProviderState?
    @State private var showsProviderDetails = false

    var body: some View {
        List(selection: $model.selection) {
            ForEach(AppSection.allCases) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
                    .accessibilityHint("在右侧显示\(section.title)内容")
            }
        }
        .listStyle(.sidebar)
        // 侧栏不再承载说明文字，因此可以收窄到纯导航需要的宽度。
        .navigationSplitViewColumnWidth(min: 168, ideal: 180, max: 220)
        .safeAreaInset(edge: .bottom) { providerStatusBar }
        .onChange(of: model.providerState) { _, state in
            guard let message = state.accessibilityAnnouncement else { return }
            guard state != lastAnnouncedProviderState else { return }
            lastAnnouncedProviderState = state
            AccessibilityNotification.Announcement(message).post()
        }
    }

    /// 底部状态只占一行；只有需要用户处理时才展开完整说明。
    private var providerStatusBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                if status.needsAttention { showsProviderDetails = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: status.symbol)
                        .foregroundStyle(status.color)
                    Text(status.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if status.needsAttention {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!status.needsAttention)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityLabel("文件提供程序：\(status.title)")
            .accessibilityHint(status.needsAttention ? "打开处理建议" : "")
        }
        .background(.bar)
        .popover(isPresented: $showsProviderDetails, arrowEdge: .trailing) {
            providerDetails
        }
    }

    /// 只有异常状态需要详情，因此这里始终给出可执行的下一步。
    private var providerDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(status.title, systemImage: status.symbol)
                .font(.headline)
                .foregroundStyle(status.color)
            Text(status.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("重新检查", action: recheckProvider)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .frame(width: 300)
    }

    /// 把扩展状态收敛成一组可直接渲染的展示值，避免视图里散落分支。
    private var status: ProviderStatusPresentation {
        switch model.providerState {
        case .checking:
            return ProviderStatusPresentation(
                title: "正在检查扩展…",
                detail: "",
                symbol: "hourglass",
                color: .secondary,
                needsAttention: false
            )
        case .ready:
            return ProviderStatusPresentation(
                title: "已可在文件面板中使用",
                detail: "",
                symbol: "checkmark.circle.fill",
                color: .green,
                needsAttention: false
            )
        case .needsActivation:
            return ProviderStatusPresentation(
                title: "需要在系统设置中启用",
                detail: "请前往“系统设置 → 通用 → 登录项与扩展 → 文件提供程序”，启用 Mirage，然后返回这里重新检查。",
                symbol: "exclamationmark.triangle.fill",
                color: .orange,
                needsAttention: true
            )
        case let .failed(message):
            return ProviderStatusPresentation(
                title: "扩展检查失败",
                detail: message,
                symbol: "exclamationmark.triangle.fill",
                color: .orange,
                needsAttention: true
            )
        }
    }

    /// 用户显式重试时才重置播报去重，普通前后台复查不会重复打断 VoiceOver。
    private func recheckProvider() {
        lastAnnouncedProviderState = nil
        showsProviderDetails = false
        Task { await model.configureProvider() }
    }
}

/// 扩展状态的展示值；`needsAttention` 决定这一行是否可点开。
private struct ProviderStatusPresentation {
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    let needsAttention: Bool
}

/// 使用说明从侧栏移到工具栏帮助按钮，正文只描述用户能看到的行为。
struct UsageHelpPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("在上传框中使用 Mirage")
                .font(.headline)

            step(1, "打开目标 App 的上传框或文件面板")
            step(2, "在左侧“位置”中选择 Mirage")
            step(3, "每层显示 50 张；打开“更多图片”继续浏览")

            Divider()
            Text("收藏和最近使用会同步到文件面板中的同名目录。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 320)
    }

    /// 用连续编号建立可扫描、可被 VoiceOver 顺序朗读的步骤。
    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.tint, in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(number) 步，\(text)")
    }
}
