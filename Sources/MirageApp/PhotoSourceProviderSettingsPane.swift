import MirageCore
import SwiftUI

/// 当前分段的设置面板；供应商切换不重建 Model，因此各自未保存草稿会继续保留。
struct PhotoSourceProviderSettingsPane: View {
    @ObservedObject var model: PhotoSourceSettingsModel
    let descriptor: PhotoSourceDescriptor
    let isTesting: Bool
    let onTestConnection: (PhotoSourceID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                providerHeader
                if descriptor.availability == .adapting {
                    adaptingContent
                } else {
                    availableContent
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        }
    }

    private var providerHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(descriptor.displayName)
                        .font(.headline)
                    if descriptor.availability == .adapting {
                        Text("正在适配")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    Link("使用条款", destination: descriptor.termsURL)
                        .font(.caption)
                        .accessibilityLabel("\(descriptor.displayName) 使用条款")
                }
                Text(descriptor.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if descriptor.availability == .available {
                Toggle("启用", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(isWorking)
                    .accessibilityLabel("\(descriptor.displayName)，启用此数据源")
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

    private var availableContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if descriptor.credentialRequirement == .apiKey {
                credentialControls
            } else {
                noCredentialContent
            }

            Text("启用后将在所有受支持的位置使用此数据源。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var noCredentialContent: some View {
        GroupBox {
            Label("无需 API Key，可直接使用", systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("API 访问")
                .font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity)
    }

    private var credentialControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SecureField("API Key", text: credentialBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking)
                        .accessibilityLabel("\(descriptor.displayName) API Key")

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在测试 \(descriptor.displayName) API Key")
                    }

                    Button("测试 API") {
                        onTestConnection(descriptor.id)
                    }
                    .disabled(isWorking)
                    .accessibilityLabel("测试 \(descriptor.displayName) API Key")
                }

                if let message = model.connectionMessages[descriptor.id] {
                    connectionStatus(message)
                }

                if let credentialURL = descriptor.credentialURL {
                    Link("获取 API Key", destination: credentialURL)
                        .font(.callout)
                        .accessibilityLabel("获取 \(descriptor.displayName) API Key")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("API 访问")
                .font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity)
    }

    private func connectionStatus(_ message: String) -> some View {
        Label(
            message,
            systemImage: model.successfulConnectionSourceIDs.contains(descriptor.id)
                ? "checkmark.circle.fill"
                : "info.circle"
        )
        .font(.caption)
        .foregroundStyle(
            model.successfulConnectionSourceIDs.contains(descriptor.id)
                ? AnyShapeStyle(.green)
                : AnyShapeStyle(.secondary)
        )
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

    private var credentialBinding: Binding<String> {
        Binding(
            get: { model.credentialDrafts[descriptor.id, default: ""] },
            set: { model.setCredentialDraft($0, for: descriptor.id) }
        )
    }
}
