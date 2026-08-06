import MirageCore
import SwiftUI

/// 参考 macOS 设置页的侧栏样式，保留所有供应商草稿并只切换当前详情。
struct PhotoSourceSettingsSidebar: View {
    let descriptors: [PhotoSourceDescriptor]
    @Binding var selection: PhotoSourceID
    let isDisabled: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(descriptors) { descriptor in
                    sourceButton(for: descriptor)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.never)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.32))
        .accessibilityLabel("内容供应商")
    }

    private func sourceButton(for descriptor: PhotoSourceDescriptor) -> some View {
        let isSelected = descriptor.id == selection

        return Button {
            selection = descriptor.id
        } label: {
            HStack(spacing: 12) {
                PhotoSourceBrandIcon(
                    sourceID: descriptor.id,
                    isSelected: isSelected,
                    size: 28
                )

                Text(sidebarTitle(for: descriptor))
                    .font(.callout.weight(isSelected ? .semibold : .regular))

                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.11)
                    : Color(nsColor: .windowBackgroundColor).opacity(0.68),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color.accentColor.opacity(0.58)
                            : Color(nsColor: .separatorColor).opacity(0.62),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(sidebarTitle(for: descriptor))
        .accessibilityValue(isSelected ? "已选择" : "")
    }

    private func sidebarTitle(for descriptor: PhotoSourceDescriptor) -> String {
        descriptor.id == .openverse ? "Default" : descriptor.displayName
    }
}

/// App 内只认识资源名映射；品牌素材随应用打包，不在运行时请求网络。
struct PhotoSourceBrandIcon: View {
    let sourceID: PhotoSourceID
    var isSelected = false
    let size: CGFloat

    var body: some View {
        Group {
            if sourceID == .openverse {
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            } else {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
            }
        }
        .padding(imagePadding)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var imagePadding: CGFloat {
        switch sourceID {
        case .openverse: return size * 0.08
        case .metMuseum: return size * 0.04
        case .nasa: return 0
        case .pexels, .pixabay: return size * 0.02
        case .giphy: return size * 0.09
        }
    }

    private var assetName: String {
        switch sourceID {
        case .openverse: return "PhotoSourceOpenverse"
        case .metMuseum: return "PhotoSourceMetMuseum"
        case .nasa: return "PhotoSourceNASA"
        case .pexels: return "PhotoSourcePexels"
        case .pixabay: return "PhotoSourcePixabay"
        case .giphy: return "PhotoSourceGiphy"
        }
    }
}
