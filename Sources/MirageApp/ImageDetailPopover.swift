import MirageCore
import MirageDetailWindow
import SwiftUI

/// 展示归属、来源和许可信息，不对公版状态做超出来源声明的保证。
struct ImageDetailPopover: View {
    let record: RemoteImageRecord

    /// 展示图片预览及可核对的来源、作者和许可信息。
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ThumbnailImage(url: record.thumbnailURL, maximumPixelSize: 512)
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
