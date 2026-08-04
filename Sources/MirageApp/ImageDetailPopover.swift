import MirageCore
import MirageDetailWindow
import SwiftUI

/// 展示归属、来源和许可信息，不对公版状态做超出来源声明的保证。
struct ImageDetailPopover: View {
    let record: RemoteImageRecord

    /// 展示图片预览及可核对的来源、作者和许可信息。
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(record.source == .giphy ? "GIF 详情" : "图片详情")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Spacer()
                if record.source == .giphy {
                    GiphyAttributionLink()
                }
            }

            RemoteThumbnailImage(record: record, maximumPixelSize: 512)
                .id(record.thumbnailURL)
                .frame(width: 320, height: 220)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("“\(record.title)”的预览图片")

            Text(record.title)
                .font(.headline)
                .lineLimit(2)

            LabeledContent("来源", value: record.source.displayName)
            authorRow
            linkRow(title: "来源页", url: record.sourcePageURL)
            linkRow(
                title: record.source == .giphy ? "使用条款" : "许可",
                url: record.license.url,
                label: record.license.displayName
            )

            Divider()
            Text(usageNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: DetailDrawerMetrics.width)
        .accessibilityElement(children: .contain)
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

    private var usageNote: String {
        if record.source == .giphy {
            return "此 Emoji、GIF 或 Sticker 由 GIPHY 提供，仅在 Mirage App 中瞬时预览，不会写入收藏或 Finder。使用前请核对 GIPHY 来源页与 API 条款。"
        }
        return "许可信息来自内容提供方，仅供参考。使用前请核对来源页，并自行确认肖像权、商标权及其他适用限制。"
    }
}
