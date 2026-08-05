import MirageCore
import SwiftUI

/// 头像页只按内容类型筛选；所有类型都可独立勾选，且始终至少保留一个。
struct AvatarTypeFilterBar: View {
    let selection: AvatarTypeSelection
    let onToggle: (AvatarType) -> Void

    var body: some View {
        MultiSelectionFilterBar(
            title: "头像类型",
            options: AvatarType.allCases,
            displayName: \AvatarType.displayName,
            selectedCount: selection.count,
            isSelected: selection.contains,
            minimumSelectionMessage: "至少保留一种头像类型",
            onToggle: onToggle
        )
    }
}

/// GIPHY 独立页复用同一组多选交互和辅助功能语义。
struct GiphyContentTypeFilterBar: View {
    let selection: GiphyContentTypeSelection
    let onToggle: (GiphyContentType) -> Void

    var body: some View {
        MultiSelectionFilterBar(
            title: "GIF 类型",
            options: GiphyContentType.allCases,
            displayName: \GiphyContentType.displayName,
            selectedCount: selection.count,
            isSelected: selection.contains,
            minimumSelectionMessage: "至少保留一种 GIF 类型",
            onToggle: onToggle
        )
    }
}

/// 多选标签只负责展示与切换；“至少一项”和持久化规则由对应 Selection 值对象负责。
private struct MultiSelectionFilterBar<Option: Identifiable & Hashable>: View {
    let title: String
    let options: [Option]
    let displayName: (Option) -> String
    let selectedCount: Int
    let isSelected: (Option) -> Bool
    let minimumSelectionMessage: String
    let onToggle: (Option) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(options) { option in
                        optionButton(option)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private func optionButton(_ option: Option) -> some View {
        let name = displayName(option)
        let selected = isSelected(option)
        let isOnlySelection = selected && selectedCount == 1

        return Button {
            onToggle(option)
        } label: {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                }
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .padding(.horizontal, selected ? 9 : 11)
            .frame(height: 22)
            .background {
                Capsule()
                    .fill(
                        selected
                            ? Color.accentColor.opacity(0.12)
                            : Color.secondary.opacity(0.08)
                    )
            }
            .overlay {
                Capsule()
                    .stroke(
                        selected ? Color.accentColor.opacity(0.35) : Color.clear,
                        lineWidth: 1
                    )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(helpText(name: name, isSelected: selected, isOnlySelection: isOnlySelection))
        .accessibilityLabel(name)
        .accessibilityValue(selected ? "已勾选" : "未勾选")
        .accessibilityHint(isOnlySelection ? minimumSelectionMessage : "按下切换勾选状态")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func helpText(name: String, isSelected: Bool, isOnlySelection: Bool) -> String {
        if isOnlySelection { return "\(name) 已勾选；\(minimumSelectionMessage)" }
        return isSelected ? "取消勾选 \(name)" : "勾选 \(name)"
    }
}
