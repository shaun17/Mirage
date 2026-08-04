import MirageCore
import SwiftUI

/// 横向切换供应商，并让每个供应商只通过自己的底部保存操作提交设置。
struct PhotoSourceSettingsView: View {
    @ObservedObject var model: PhotoSourceSettingsModel
    @State private var selectedSourceID: PhotoSourceID = .openverse
    @State private var connectionTask: Task<Void, Never>?
    @State private var testingSourceID: PhotoSourceID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let selectedDescriptor {
                PhotoSourceProviderSettingsPane(
                    model: model,
                    descriptor: selectedDescriptor,
                    isTesting: testingSourceID == selectedDescriptor.id,
                    onTestConnection: testConnection
                )
                Divider()
                actionBar(for: selectedDescriptor)
            } else {
                ContentUnavailableView("数据源不可用", systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 620, height: 520)
        .task { await model.load() }
        .onDisappear {
            cancelConnectionTest()
            model.discardDrafts()
        }
        .onChange(of: selectedSourceID) {
            cancelConnectionTest()
        }
        .onChange(of: model.connectionMessages) { previous, messages in
            guard let message = messages[selectedSourceID],
                  message != previous[selectedSourceID] else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        .alert("图片数据源", isPresented: noticeIsPresented) {
            Button("好", action: model.dismissNotice)
        } message: {
            Text(model.notice ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("图片数据源")
                .font(.title2.weight(.semibold))

            ScrollView(.horizontal) {
                Picker("图片供应商", selection: $selectedSourceID) {
                    ForEach(providerDescriptors) { descriptor in
                        Text(descriptor.displayName).tag(descriptor.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(minWidth: max(572, CGFloat(providerDescriptors.count) * 150))
                .accessibilityLabel("图片供应商")
            }
            .scrollIndicators(.hidden)
            .disabled(providerSwitchingIsDisabled)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionBar(for descriptor: PhotoSourceDescriptor) -> some View {
        HStack(spacing: 12) {
            Spacer()

            if isBusy, testingSourceID == nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在处理 \(descriptor.displayName) 设置")
            }

            Button("保存") {
                model.scheduleSaveConfiguration(for: descriptor.id)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave(descriptor))
            .help(descriptor.availability == .adapting ? "适配完成后可设置" : "")
            .accessibilityLabel("保存 \(descriptor.displayName) 设置")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var selectedDescriptor: PhotoSourceDescriptor? {
        return PhotoSourceRegistry.descriptor(for: selectedSourceID)
    }

    private var providerDescriptors: [PhotoSourceDescriptor] {
        PhotoSourceRegistry.descriptors
    }

    private var isBusy: Bool {
        model.isLoading || !model.workingSourceIDs.isEmpty || !model.scheduledSourceIDs.isEmpty
    }

    /// 连接测试允许切换供应商并由 `onChange` 取消；只有加载与持久化操作锁定分段选择。
    private var providerSwitchingIsDisabled: Bool {
        model.isLoading
            || !model.scheduledSourceIDs.isEmpty
            || (testingSourceID == nil && !model.workingSourceIDs.isEmpty)
    }

    private func canSave(_ descriptor: PhotoSourceDescriptor) -> Bool {
        descriptor.availability == .available
            && !isBusy
            && model.hasUnsavedChanges(for: descriptor.id)
    }

    /// 测试使用当前输入草稿；任务结束、切换供应商或关闭窗口时同步清理本地进度状态。
    private func testConnection(for sourceID: PhotoSourceID) {
        cancelConnectionTest()
        testingSourceID = sourceID
        connectionTask = Task { @MainActor in
            await model.testConnection(for: sourceID)
            guard !Task.isCancelled, testingSourceID == sourceID else { return }
            testingSourceID = nil
            connectionTask = nil
        }
    }

    private func cancelConnectionTest() {
        connectionTask?.cancel()
        connectionTask = nil
        testingSourceID = nil
    }

    private var noticeIsPresented: Binding<Bool> {
        Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.dismissNotice() } }
        )
    }
}
