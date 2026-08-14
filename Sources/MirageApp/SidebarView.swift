import SwiftUI

/// 侧栏承载主导航，并在底部提供始终可见的设置入口。
struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(AppSection.allCases) { section in
                    Label(section.localizedTitle, systemImage: section.symbol)
                        .tag(section)
                        .accessibilityHint("在右侧显示\(Text(section.localizedTitle))内容")
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .help("打开 Mirage 设置")
            .accessibilityHint("打开服务商和文件面板设置")
        }
        // 底部设置入口与导航共用紧凑侧栏宽度。
        .navigationSplitViewColumnWidth(min: 168, ideal: 180, max: 220)
    }
}

/// 使用说明从侧栏移到工具栏帮助按钮，正文只描述用户能看到的行为。
struct UsageHelpPopover: View {
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: localized("在上传框中使用 Mirage"))
                .font(.headline)

            step(1, "打开目标 App 的上传框或文件面板")
            step(2, "在左侧“位置”中选择 Mirage")
            step(3, "打开“更多图片”继续浏览")

            Divider()
            Text(verbatim: localized("收藏和最近使用会同步到文件面板中的同名目录。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 320)
    }

    /// 用连续编号建立可扫描、可被 VoiceOver 顺序朗读的步骤。
    private func step(_ number: Int, _ key: StaticString) -> some View {
        let text = localized(key)
        let accessibilityLabel = AppDisplayMessage.localized(
            "第 %lld 步，%@",
            .integer(number),
            .text(text)
        ).resolved(locale: locale)

        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.tint, in: Circle())
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    private func localized(_ key: StaticString) -> String {
        AppDisplayMessage.localized(key).resolved(locale: locale)
    }
}
