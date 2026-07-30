import MirageCore
import SwiftUI

/// 展示归属、来源和许可信息，不对公版状态做超出来源声明的保证。
struct ImageDetailPopover: View {
    let record: RemoteImageRecord

    /// 展示图片预览及可核对的来源、作者和许可信息。
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AsyncImage(url: record.thumbnailURL) { phase in
                preview(for: phase)
            }
            .frame(width: 320, height: 220)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

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
        .frame(width: 356)
        .accessibilityElement(children: .contain)
    }

    /// 按加载阶段提供明确反馈，避免失败状态被误显示成持续加载。
    @ViewBuilder
    private func preview(for phase: AsyncImagePhase) -> some View {
        switch phase {
        case .empty:
            ProgressView("正在加载预览…")
                .accessibilityLabel("正在加载“\(record.title)”的预览图片")
        case .success(let image):
            image
                .resizable()
                .scaledToFit()
                .accessibilityLabel("“\(record.title)”的预览图片")
        case .failure:
            ContentUnavailableView(
                "预览加载失败",
                systemImage: "photo.badge.exclamationmark",
                description: Text("图片暂时不可用，请稍后再试。")
            )
            .accessibilityLabel("无法加载“\(record.title)”的预览图片")
            .accessibilityHint("图片暂时不可用，请稍后再试")
        @unknown default:
            ContentUnavailableView(
                "无法显示预览",
                systemImage: "photo.badge.exclamationmark",
                description: Text("图片当前不可用，请稍后再试。")
            )
            .accessibilityLabel("无法显示“\(record.title)”的预览图片")
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
