import Combine
import Sparkle
import SwiftUI

/// 订阅 Sparkle 的可检查状态，使菜单项在更新器忙碌时自动禁用。
@MainActor
final class SoftwareUpdateViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// 应用菜单中的手动更新入口；后台定时检查仍由 Sparkle 自行调度。
struct SoftwareUpdateView: View {
    @StateObject private var viewModel: SoftwareUpdateViewModel
    private let updater: SPUUpdater

    @MainActor
    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: SoftwareUpdateViewModel(updater: updater))
    }

    var body: some View {
        Button("检查更新…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
