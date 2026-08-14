import MirageCore
import SwiftUI

/// 当前供应商的详情页；所有控件仍只编辑 Model 草稿，底部“保存”统一提交。
struct PhotoSourceProviderSettingsPane: View {
    @ObservedObject var model: PhotoSourceSettingsModel
    let descriptor: PhotoSourceDescriptor
    let isTesting: Bool
    let onTestConnection: (PhotoSourceID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                providerHeader

                if descriptor.availability == .adapting {
                    adaptingContent
                } else {
                    availableContent
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var providerHeader: some View {
        HStack(alignment: .top, spacing: 18) {
            PhotoSourceBrandIcon(sourceID: descriptor.id, isSelected: true, size: 48)
                .frame(width: 68, height: 68)
                .background(
                    Color(nsColor: .controlBackgroundColor).opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Text(descriptor.displayName)
                        .font(.title3.bold())

                    Text(requirementLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(requirementColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(requirementColor.opacity(0.10), in: Capsule())
                }

                Text(LocalizedStringKey(descriptor.summary))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: descriptor.termsURL) {
                    Label("使用条款", systemImage: "arrow.up.right")
                }
                .font(.caption)
                .accessibilityLabel("\(descriptor.displayName) 使用条款")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var availableContent: some View {
        if descriptor.credentialRequirement == .apiKey {
            PhotoSourceCredentialSettingsSection(
                model: model,
                descriptor: descriptor,
                isTesting: isTesting,
                onTestConnection: onTestConnection
            )
        } else {
            noCredentialCallout
        }

        statusSection
    }

    private var noCredentialCallout: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundStyle(.tint)
                .font(.body.weight(.medium))

            Text("启用后将在所有受支持的位置使用此数据源。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("状态")
                .font(.headline)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("启用此数据源")
                        .font(.callout.weight(.medium))

                    Text(usageDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Toggle("启用此数据源", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(isWorking || enableRequiresCredential)
                    .help(enableRequiresCredential ? Text("请先填写 API Key") : Text(""))
                    .accessibilityLabel("\(descriptor.displayName)，启用此数据源")
                    .accessibilityHint(enableRequiresCredential ? Text("请先填写 API Key") : Text(""))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.52),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.68), lineWidth: 1)
            }
        }
    }

    private var adaptingContent: some View {
        ContentUnavailableView {
            Label("正在适配", systemImage: "wrench.and.screwdriver")
        } description: {
            Text("\(descriptor.displayName) 已加入供应商入口，搜索和 API 设置将在适配完成后开放。")
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private var requirementLabel: LocalizedStringKey {
        switch descriptor.availability {
        case .adapting: return "正在适配"
        case .available:
            return descriptor.credentialRequirement == .apiKey ? "需要 API Key" : "无需 API Key"
        }
    }

    private var requirementColor: Color {
        descriptor.availability == .available ? .accentColor : .secondary
    }

    private var usageDescription: LocalizedStringKey {
        if descriptor.supports(.app), descriptor.supports(.fileProvider) {
            return "在搜索、下载和 Finder 中使用 \(descriptor.displayName)"
        }
        if descriptor.supports(.app) {
            return "在 App 中使用 \(descriptor.displayName)"
        }
        return "在 Finder 中使用 \(descriptor.displayName)"
    }

    private var isWorking: Bool {
        model.isLoading
            || !model.workingSourceIDs.isEmpty
            || !model.scheduledSourceIDs.isEmpty
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.isEnabled(descriptor.id) },
            set: { model.setEnabled($0, sourceID: descriptor.id) }
        )
    }

    private var enableRequiresCredential: Bool {
        !model.isEnabled(descriptor.id) && !model.canEnable(descriptor.id)
    }
}
