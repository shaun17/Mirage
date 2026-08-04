import MirageCore
import SwiftUI

/// 单个图片卡片；主按钮把详情请求交给上层，收藏按钮始终有明确的辅助功能状态。
struct ImageCard: View {
    let record: RemoteImageRecord
    let isFavorite: Bool
    let allowsFavoriteChanges: Bool
    let onToggleFavorite: () -> Void
    /// 详情由整个网格共用一个检查器呈现；每张卡片各挂一个 popover 会在长列表里堆出成百个呈现上下文。
    let onShowDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: onShowDetails) {
                preview
            }
            .buttonStyle(.plain)
            .help("查看详情")
            .accessibilityLabel("查看 \(record.title) 的详情")

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(record.source.displayName) · \(record.license.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if allowsFavoriteChanges {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(isFavorite ? .red : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(isFavorite ? "取消收藏" : "收藏")
                    .accessibilityLabel(isFavorite ? "取消收藏 \(record.title)" : "收藏 \(record.title)")
                } else if isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("已收藏")
                }
            }
        }
    }

    /// 走共享缓存并按卡片尺寸降采样，滚动回来不再重新下载与全尺寸解码。
    ///
    /// 图片必须以 overlay 呈现而不是直接参与布局：`scaledToFill` 的横图会把
    /// 只约束了 `maxWidth` 的弹性 frame 撑到自己的填充宽度，卡片随之溢出网格
    /// 单元格、相互覆盖。overlay 不参与布局，卡片尺寸只由占位框决定，
    /// 超出部分被裁切在圆角内。
    @ViewBuilder
    private var preview: some View {
        Color.clear
            .frame(height: 158)
            .frame(maxWidth: .infinity)
            .background(.quaternary)
            .overlay {
                ThumbnailImage(url: record.thumbnailURL, maximumPixelSize: 512)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
