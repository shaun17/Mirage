import MirageCore
import SwiftUI

/// Settings 侧栏只在 UI 层组合数据源和通用设置，不污染图片源业务注册表。
enum SettingsSidebarSelection: Hashable {
    case source(PhotoSourceID)
    case general
}

/// 参考 macOS 设置页的侧栏样式，保留所有供应商草稿并只切换当前详情。
struct PhotoSourceSettingsSidebar: View {
    let descriptors: [PhotoSourceDescriptor]
    @Binding var selection: SettingsSidebarSelection
    let isDisabled: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(descriptors) { descriptor in
                    sourceButton(for: descriptor)
                }

                generalSettingsButton
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
        let isSelected = selection == .source(descriptor.id)

        return Button {
            selection = .source(descriptor.id)
        } label: {
            HStack(spacing: 12) {
                PhotoSourceBrandIcon(
                    sourceID: descriptor.id,
                    isSelected: isSelected,
                    size: 28
                )

                Text(descriptor.displayName)
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
        .accessibilityLabel(descriptor.displayName)
        .accessibilityValue(isSelected ? Text("已选择") : Text("未选择"))
    }

    private var generalSettingsButton: some View {
        let isSelected = selection == .general

        return Button {
            selection = .general
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                Text("设置")
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
        .accessibilityLabel("设置")
        .accessibilityValue(isSelected ? Text("已选择") : Text("未选择"))
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
