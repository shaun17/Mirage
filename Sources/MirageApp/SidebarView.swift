import SwiftUI

/// 侧栏同时承载内容导航、三步使用方式和系统集成状态。
struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var lastAnnouncedProviderState: ProviderState?

    var body: some View {
        List(selection: $model.selection) {
            Section("资料库") {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                        .accessibilityHint("在右侧显示\(section.title)内容")
                }
            }

            Section("在上传框中使用") {
                instructionRow(number: 1, text: "打开目标 App 的上传框")
                instructionRow(number: 2, text: "在“位置”中选择 Mirage")
                instructionRow(number: 3, text: "直接选择根目录中的推荐项，或用右上角搜索更多图片")

                Text("Mirage 根目录会显示 12 个推荐项，以及“最近使用”和“收藏”两个文件夹。浏览时只加载缩略图；选择后才下载原图并转换为 512×512 PNG。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("系统集成") {
                providerStatus
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 280, ideal: 310, max: 360)
        .onChange(of: model.providerState) { _, state in
            guard let message = state.accessibilityAnnouncement else { return }
            guard state != lastAnnouncedProviderState else { return }
            lastAnnouncedProviderState = state
            AccessibilityNotification.Announcement(message).post()
        }
    }

    /// 用连续编号建立可扫描、可被 VoiceOver 顺序朗读的步骤。
    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.tint, in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(number) 步，\(text)")
    }

    /// 精确区分检查中、真实可用、等待用户启用和注册失败状态。
    @ViewBuilder
    private var providerStatus: some View {
        switch model.providerState {
        case .checking:
            statusLabel("正在检查…", symbol: "hourglass", color: .secondary)
        case .ready:
            statusLabel("可在文件面板中使用", symbol: "checkmark.circle.fill", color: .green)
        case .needsActivation:
            VStack(alignment: .leading, spacing: 8) {
                statusLabel("需要启用文件扩展", symbol: "exclamationmark.triangle.fill", color: .orange)
                Text("请前往“系统设置 → 通用 → 登录项与扩展 → 文件提供程序”，启用 Mirage，然后返回这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重新检查") {
                    Task { await model.configureProvider() }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                statusLabel("检查失败", symbol: "exclamationmark.triangle.fill", color: .orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("重新检查") {
                    Task { await model.configureProvider() }
                }
            }
        }
    }

    /// 统一状态标签的图标与可访问文本。
    private func statusLabel(_ title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(color)
            .accessibilityLabel("Mirage 文件扩展：\(title)")
    }
}
