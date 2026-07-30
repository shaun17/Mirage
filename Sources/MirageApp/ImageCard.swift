import MirageCore
import SwiftUI

/// 单个图片卡片；主按钮打开详情，收藏按钮始终有明确的辅助功能状态。
struct ImageCard: View {
    let record: RemoteImageRecord
    let isFavorite: Bool
    let allowsFavoriteChanges: Bool
    let onToggleFavorite: () -> Void

    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                showsDetails = true
            } label: {
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
                    Text("\(sourceName) · \(record.license.displayName)")
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
        .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
            ImageDetailPopover(record: record)
        }
    }

    /// 使用系统异步图片加载器，并为加载和失败阶段提供稳定占位。
    @ViewBuilder
    private var preview: some View {
        AsyncImage(url: record.thumbnailURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            default:
                ProgressView()
            }
        }
        .frame(height: 158)
        .frame(maxWidth: .infinity)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 将内部来源枚举转换成用户可识别的服务名称。
    private var sourceName: String {
        record.source == .openverse ? "Openverse" : "DiceBear"
    }
}
