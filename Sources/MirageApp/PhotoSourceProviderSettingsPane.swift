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
            VStack(alignment: .leading, spacing: 16) {
                providerHeader
                if descriptor.availability == .adapting {
                    adaptingContent
                } else {
                    availableContent
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
                    .disabled(isWorking || enableRequiresCredential)
                    .help(enableRequiresCredential ? "请先填写 API Key" : "")
                    .accessibilityLabel("\(descriptor.displayName)，启用此数据源")
                    .accessibilityHint(enableRequiresCredential ? "请先填写 API Key" : "")
            }
        }
    }

    private var adaptingContent: some View {
        ContentUnavailableView {
            Label("正在适配", systemImage: "wrench.and.screwdriver")
        } description: {
            Text("\(descriptor.displayName) 已加入供应商入口，搜索和 API 设置将在适配完成后开放。")
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var availableContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if descriptor.credentialRequirement == .apiKey {
                credentialControls
            }

            Text(
                descriptor.searchResultAttribution?.note
                    ?? "启用后将在所有受支持的位置使用此数据源。"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var credentialControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
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
                    .disabled(isWorking || !model.hasNonemptyCredentialDraft(for: descriptor.id))
                    .accessibilityLabel("测试 \(descriptor.displayName) API Key")
                }

                if !model.hasNonemptyCredentialDraft(for: descriptor.id) {
                    Text("填写 API Key 后可启用此数据源")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message = model.connectionMessages[descriptor.id] {
                    connectionStatus(message)
                }

                if let credentialURL = descriptor.credentialURL {
                    Link(destination: credentialURL) {
                        Label(credentialAcquisitionLabel, systemImage: "key.fill")
                    }
                        .font(.callout)
                        .accessibilityLabel(
                            "\(descriptor.displayName)，\(credentialAcquisitionLabel)"
                        )
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

    private var enableRequiresCredential: Bool {
        !model.isEnabled(descriptor.id) && !model.canEnable(descriptor.id)
    }

    private var credentialBinding: Binding<String> {
        Binding(
            get: { model.credentialDrafts[descriptor.id, default: ""] },
            set: { model.setCredentialDraft($0, for: descriptor.id) }
        )
    }

    private var credentialAcquisitionLabel: String {
        descriptor.credentialAcquisitionLabel ?? "获取 API Key"
    }
}
