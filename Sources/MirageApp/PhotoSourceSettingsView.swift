import FinderSync
import MirageCore
import SwiftUI

/// 左侧切换供应商、右侧编辑详情，并在页面底部统一保存所有供应商草稿。
struct PhotoSourceSettingsView: View {
    @ObservedObject var model: PhotoSourceSettingsModel
    let providerState: ProviderState
    let softwareUpdateController: SoftwareUpdateController
    let onRecheckProvider: @MainActor () async -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedSourceID: PhotoSourceID = .openverse
    @State private var connectionTask: Task<Void, Never>?
    @State private var testingSourceID: PhotoSourceID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PhotoSourceSettingsSidebar(
                    descriptors: providerDescriptors,
                    selection: $selectedSourceID,
                    isDisabled: providerSwitchingIsDisabled
                )

                Divider()

                detailArea
            }

            Divider()
            actionBar
        }
        .frame(width: 720, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            SettingsWindowTitleConfigurator(title: "数据源设置")
                .allowsHitTesting(false)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("数据源设置")
                    .font(.headline)
            }
        }
        .onAppear {
            selectedSourceID = .openverse
        }
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

    private var detailArea: some View {
        VStack(spacing: 0) {
            if let providerStatus {
                providerStatusSection(providerStatus)
                Divider()
            }

            if let selectedDescriptor {
                PhotoSourceProviderSettingsPane(
                    model: model,
                    descriptor: selectedDescriptor,
                    isTesting: testingSourceID == selectedDescriptor.id,
                    onTestConnection: testConnection
                )
            } else {
                ContentUnavailableView("数据源不可用", systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 正常状态不占设置页空间；检查中或异常时才呈现 Finder 状态与处理入口。
    private func providerStatusSection(_ status: ProviderStatusPresentation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            providerStatusIndicator(status)

            VStack(alignment: .leading, spacing: 4) {
                Text(status.title)
                    .font(.callout.weight(.medium))

                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Finder 状态：\(status.title)")
            .accessibilityValue(status.detail ?? "")

            Spacer(minLength: 12)
            providerStatusAction
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(status.color.opacity(0.055))
    }

    @ViewBuilder
    private func providerStatusIndicator(_ status: ProviderStatusPresentation) -> some View {
        if providerState == .checking {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
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

    private var providerStatus: ProviderStatusPresentation? {
        switch providerState {
        case .checking:
            return ProviderStatusPresentation(
                title: "正在检查 Finder 扩展…",
                detail: nil,
                symbol: "hourglass",
                color: .secondary
            )
        case .ready:
            return nil
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

    private var actionBar: some View {
        HStack(spacing: 12) {
            SoftwareUpdateView(controller: softwareUpdateController)
                .buttonStyle(.bordered)
                .controlSize(.large)

            if model.hasUnsavedChanges {
                Text("已修改 \(model.unsavedSourceIDs.count) 个数据源")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isBusy, testingSourceID == nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在处理内容数据源设置")
            }

            Button("保存") {
                model.scheduleSaveAllConfigurations()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy || !model.hasUnsavedChanges)
            .accessibilityLabel("保存所有内容数据源设置")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.18))
    }

    private var selectedDescriptor: PhotoSourceDescriptor? {
        PhotoSourceRegistry.descriptor(for: selectedSourceID)
    }

    private var providerDescriptors: [PhotoSourceDescriptor] {
        PhotoSourceRegistry.descriptors
    }

    private var isBusy: Bool {
        model.isLoading || !model.workingSourceIDs.isEmpty || !model.scheduledSourceIDs.isEmpty
    }

    /// 连接测试允许切换供应商并由 `onChange` 取消；只有加载与持久化操作锁定侧栏。
    private var providerSwitchingIsDisabled: Bool {
        model.isLoading
            || !model.scheduledSourceIDs.isEmpty
            || (testingSourceID == nil && !model.workingSourceIDs.isEmpty)
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
