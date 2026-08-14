import FinderSync
import MirageCore
import SwiftUI

/// 左侧切换设置分类、右侧编辑详情，并在页面底部统一保存全部设置草稿。
struct PhotoSourceSettingsView: View {
    @ObservedObject var model: PhotoSourceSettingsModel
    let providerState: ProviderState
    let softwareUpdateController: SoftwareUpdateController
    @Binding var appLanguage: AppLanguage
    let onRecheckProvider: @MainActor () async -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @State private var selection: SettingsSidebarSelection = .source(.openverse)
    @State private var appLanguageDraft: AppLanguage?
    @State private var connectionTask: Task<Void, Never>?
    @State private var testingSourceID: PhotoSourceID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PhotoSourceSettingsSidebar(
                    descriptors: providerDescriptors,
                    selection: $selection,
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
            SettingsWindowTitleConfigurator(title: "")
                .allowsHitTesting(false)
        }
        .onAppear {
            selection = .source(.openverse)
            appLanguageDraft = appLanguage
        }
        .task { await model.load() }
        .task(id: scenePhase) {
            guard scenePhase == .active, !Task.isCancelled else { return }
            await onRecheckProvider()
        }
        .onDisappear {
            cancelConnectionTest()
            model.discardDrafts()
            appLanguageDraft = nil
        }
        .onChange(of: selection) {
            cancelConnectionTest()
        }
        .onChange(of: model.connectionMessages) { previous, messages in
            guard case let .source(sourceID) = selection,
                  let message = messages[sourceID],
                  message != previous[sourceID] else { return }
            AccessibilityNotification.Announcement(
                message.resolved(locale: locale)
            ).post()
        }
        .alert("内容数据源", isPresented: noticeIsPresented) {
            Button("好", action: model.dismissNotice)
        } message: {
            Text(verbatim: model.notice?.resolved(locale: locale) ?? "")
        }
    }

    private var detailArea: some View {
        VStack(spacing: 0) {
            if let providerStatus {
                providerStatusSection(providerStatus)
                Divider()
            }

            switch selection {
            case .general:
                GeneralSettingsPane(languageDraft: appLanguageDraftBinding)
            case .source:
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
                    Text(verbatim: detail.resolved(locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Finder 状态：") + Text(status.title))
            .accessibilityValue(
                Text(verbatim: status.detail?.resolved(locale: locale) ?? "")
            )

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

            if let pendingChangesDescription {
                Text(pendingChangesDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isBusy, testingSourceID == nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在处理内容数据源设置")
            }

            Button("保存", action: saveSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || !settingsSaveState.hasUnsavedChanges)
                .accessibilityLabel("保存所有设置")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.18))
    }

    private var selectedDescriptor: PhotoSourceDescriptor? {
        guard case let .source(sourceID) = selection else { return nil }
        return PhotoSourceRegistry.descriptor(for: sourceID)
    }

    private var providerDescriptors: [PhotoSourceDescriptor] {
        PhotoSourceRegistry.descriptors
    }

    private var isBusy: Bool {
        model.isLoading || !model.workingSourceIDs.isEmpty || !model.scheduledSourceIDs.isEmpty
    }

    private var effectiveLanguageDraft: AppLanguage {
        appLanguageDraft ?? appLanguage
    }

    private var appLanguageDraftBinding: Binding<AppLanguage> {
        Binding(
            get: { effectiveLanguageDraft },
            set: { appLanguageDraft = $0 }
        )
    }

    private var settingsSaveState: SettingsSaveState {
        SettingsSaveState(
            savedLanguage: appLanguage,
            draftLanguage: effectiveLanguageDraft,
            hasPhotoSourceChanges: model.hasUnsavedChanges
        )
    }

    private var pendingChangesDescription: LocalizedStringKey? {
        let languageChanged = appLanguage != effectiveLanguageDraft
        switch (languageChanged, model.hasUnsavedChanges) {
        case (true, true):
            return "已修改应用语言和 \(model.unsavedSourceIDs.count) 个数据源"
        case (true, false):
            return "已修改应用语言"
        case (false, true):
            return "已修改 \(model.unsavedSourceIDs.count) 个数据源"
        case (false, false):
            return nil
        }
    }

    /// 语言与图片源遵循同一个草稿边界；只有点击底部保存才写入共享偏好。
    private func saveSettings() {
        let language = effectiveLanguageDraft
        if language != appLanguage {
            appLanguage = language
        }
        model.scheduleSaveAllConfigurations()
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

/// 通用设置与图片源配置分开呈现；语言草稿与图片源草稿统一由底部按钮保存。
private struct GeneralSettingsPane: View {
    @Binding var languageDraft: AppLanguage
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                languageSection
                privacySection
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: "gearshape")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 68, height: 68)
                .background(
                    Color(nsColor: .controlBackgroundColor).opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text("设置")
                    .font(.title3.bold())
                Text("管理 Mirage 的语言与隐私选项。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("语言")
                .font(.headline)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("应用语言")
                        .font(.callout.weight(.medium))
                    Text("默认跟随系统语言，也可以随时切换。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Picker("应用语言", selection: $languageDraft) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .accessibilityLabel("应用语言")
            }
            .settingsCard()
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("隐私")
                .font(.headline)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("隐私政策")
                        .font(.callout.weight(.medium))
                    Text("在浏览器中查看 Mirage 隐私政策。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Button("查看隐私政策") {
                    openURL(Self.privacyPolicyURL)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("查看隐私政策")
            }
            .settingsCard()
        }
    }

    private static let privacyPolicyURL = URL(string: "https://mirage.wenmsg.fun/privacy")!
}

private extension View {
    func settingsCard() -> some View {
        padding(16)
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

private struct ProviderStatusPresentation {
    let title: LocalizedStringKey
    let detail: AppDisplayMessage?
    let symbol: String
    let color: Color
}
