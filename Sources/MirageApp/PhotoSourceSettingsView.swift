import FinderSync
import MirageCore
import SwiftUI

/// 横向切换供应商，并集中展示 Finder 状态与当前供应商的保存操作。
struct PhotoSourceSettingsView: View {
    @ObservedObject var model: PhotoSourceSettingsModel
    let providerState: ProviderState
    let onRecheckProvider: @MainActor () async -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedSourceID: PhotoSourceID = .openverse
    @State private var connectionTask: Task<Void, Never>?
    @State private var testingSourceID: PhotoSourceID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            providerStatusSection
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
        .frame(width: 620, height: 600)
        .task { await model.load() }
        .task(id: scenePhase) {
            guard scenePhase == .active, !Task.isCancelled else { return }
            await onRecheckProvider()
        }
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
        .alert("内容数据源", isPresented: noticeIsPresented) {
            Button("好", action: model.dismissNotice)
        } message: {
            Text(model.notice ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("内容数据源")
                .font(.title2.weight(.semibold))

            Picker("内容供应商", selection: $selectedSourceID) {
                ForEach(providerDescriptors) { descriptor in
                    Text(providerPickerTitle(for: descriptor)).tag(descriptor.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel("内容供应商")
            .disabled(providerSwitchingIsDisabled)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Finder 状态紧跟数据源选择；只有明确异常时才提供下一步操作。
    private var providerStatusSection: some View {
        HStack(alignment: .top, spacing: 10) {
            providerStatusIndicator

            VStack(alignment: .leading, spacing: 4) {
                Text(providerStatus.title)
                    .font(.callout.weight(.medium))

                if let detail = providerStatus.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Finder 状态：\(providerStatus.title)")
            .accessibilityValue(providerStatus.detail ?? "")

            Spacer(minLength: 16)
            providerStatusAction
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var providerStatusIndicator: some View {
        if providerState == .checking {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            Image(systemName: providerStatus.symbol)
                .foregroundStyle(providerStatus.color)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var providerStatusAction: some View {
        switch providerState {
        case .needsActivation:
            Button("打开系统设置…", action: openProviderSettings)
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("打开文件提供程序扩展设置")
        case .failed:
            Button("重新检查", action: recheckProvider)
                .controlSize(.small)
                .buttonStyle(.bordered)
        case .checking, .ready:
            EmptyView()
        }
    }

    /// 状态行只包含面向用户的 Finder 语义，具体系统错误保留原文以便诊断。
    private var providerStatus: ProviderStatusPresentation {
        switch providerState {
        case .checking:
            return ProviderStatusPresentation(
                title: "正在检查 Finder 扩展…",
                detail: nil,
                symbol: "hourglass",
                color: .secondary
            )
        case .ready:
            return ProviderStatusPresentation(
                title: "Finder 已可用",
                detail: nil,
                symbol: "checkmark.circle.fill",
                color: .green
            )
        case .needsActivation:
            return ProviderStatusPresentation(
                title: "需要启用 Finder 扩展",
                detail: "请在“系统设置 → 通用 → 登录项与扩展 → 文件提供程序”中启用 Mirage。",
                symbol: "exclamationmark.triangle.fill",
                color: .orange
            )
        case let .failed(message):
            return ProviderStatusPresentation(
                title: "Finder 状态检查失败",
                detail: message,
                symbol: "xmark.octagon.fill",
                color: .red
            )
        }
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

    /// “Default” 是设置入口名称；供应商详情仍保留 Openverse 的真实品牌与条款。
    private func providerPickerTitle(for descriptor: PhotoSourceDescriptor) -> String {
        descriptor.id == .openverse ? "Default" : descriptor.displayName
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

    private func recheckProvider() {
        Task { await onRecheckProvider() }
    }

    /// File Provider 复用系统的扩展管理界面；FinderSync 提供 Apple 指定的公开入口。
    private func openProviderSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    private var noticeIsPresented: Binding<Bool> {
        Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.dismissNotice() } }
        )
    }
}

private struct ProviderStatusPresentation {
    let title: String
    let detail: String?
    let symbol: String
    let color: Color
}
