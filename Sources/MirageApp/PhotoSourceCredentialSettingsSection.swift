import MirageCore
import SwiftUI

/// API Key 输入、连接测试与获取入口集中在同一区域，避免测试未保存的草稿时产生歧义。
struct PhotoSourceCredentialSettingsSection: View {
    @ObservedObject var model: PhotoSourceSettingsModel
    let descriptor: PhotoSourceDescriptor
    let isTesting: Bool
    let onTestConnection: (PhotoSourceID) -> Void

    @Environment(\.locale) private var locale
    @State private var showsCredential = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("API Key")
                .font(.headline)

            HStack(spacing: 8) {
                credentialField

                Button {
                    onTestConnection(descriptor.id)
                } label: {
                    HStack(spacing: 7) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if isTesting {
                            Text("测试中")
                        } else {
                            Text("测试")
                        }
                    }
                    .frame(minWidth: 52)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isWorking || !model.hasNonemptyCredentialDraft(for: descriptor.id))
                .accessibilityLabel("测试 \(descriptor.displayName) API Key")
            }

            if let message = model.connectionMessages[descriptor.id] {
                connectionStatus(message)
            }

            if let credentialURL = descriptor.credentialURL {
                credentialCallout(url: credentialURL)
            }
        }
        .onChange(of: descriptor.id) {
            showsCredential = false
        }
    }

    private var credentialField: some View {
        HStack(spacing: 10) {
            Group {
                if showsCredential {
                    TextField("输入 API Key", text: credentialBinding)
                } else {
                    SecureField("输入 API Key", text: credentialBinding)
                }
            }
            .textFieldStyle(.plain)
            .disabled(isWorking)
            .accessibilityLabel("\(descriptor.displayName) API Key")

            Button {
                showsCredential.toggle()
            } label: {
                Image(systemName: showsCredential ? "eye.slash" : "eye")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isWorking)
            .help(showsCredential ? Text("隐藏 API Key") : Text("显示 API Key"))
            .accessibilityLabel(showsCredential ? Text("隐藏 API Key") : Text("显示 API Key"))
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 42)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private func credentialCallout(url: URL) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key")
                .foregroundStyle(.tint)
                .font(.body.weight(.medium))

            VStack(alignment: .leading, spacing: 5) {
                Text("没有 API Key？")
                    .font(.callout)

                Link(destination: url) {
                    HStack(spacing: 5) {
                        Text(LocalizedStringKey(credentialAcquisitionLabel))
                            .fontWeight(.semibold)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                    }
                }
                .font(.callout)
                .accessibilityLabel("\(descriptor.displayName)，\(credentialAcquisitionLabel)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
    }

    private func connectionStatus(_ message: AppDisplayMessage) -> some View {
        let succeeded = model.successfulConnectionSourceIDs.contains(descriptor.id)

        return Label {
            Text(verbatim: message.resolved(locale: locale))
        } icon: {
            Image(systemName: succeeded ? "checkmark.circle.fill" : "info.circle")
        }
        .font(.caption)
        .foregroundStyle(succeeded ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
    }

    private var isWorking: Bool {
        model.isLoading
            || !model.workingSourceIDs.isEmpty
            || !model.scheduledSourceIDs.isEmpty
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
