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

            RemoteThumbnailImage(
                record: record,
                maximumPixelSize: 512,
                staticImageContentMode: .fit
            )
                .id(record.thumbnailURL)
                .frame(width: 320, height: 396)
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
                title: licenseLinkTitle,
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
            return "此 Emoji、GIF 或 Sticker 由 GIPHY 提供。收藏只保存 GIPHY 对象 ID，打开收藏时实时回查；媒体文件与媒体 URL 均不落盘，也不写入 Finder。使用前请核对来源页与 API 条款。"
        }
        if record.source == .picrew {
            return "此图来自 Picrew Discovery 的公开作品预览。收藏保存预览与 Maker 来源记录，但不发布到 Finder；实际生成图片的使用范围以来源页中的 Maker 作者说明为准。"
        }
        if record.source == .thisPersonDoesNotExist {
            return "此头像由 AI 动态生成，内容已在首次请求后冻结并可收藏。网站当前未公开 API 合约或使用许可且域名标示出售；对外使用前请自行核实权利与服务状态。"
        }
        return "许可信息来自内容提供方，仅供参考。使用前请核对来源页，并自行确认肖像权、商标权及其他适用限制。"
    }

    private var licenseLinkTitle: String {
        switch record.source {
        case .giphy: return "使用条款"
        case .picrew: return "使用范围"
        default: return "许可"
        }
    }
}
