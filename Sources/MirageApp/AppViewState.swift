import Foundation
import MirageCore
import SwiftUI

/// 同时维护当前界面语言与 App Group 持久化值，保存后立即驱动所有窗口重绘。
@MainActor
final class AppLanguageState: ObservableObject {
    @Published private(set) var language: MirageAppLanguage

    private let userDefaults: UserDefaults

    init(
        userDefaults: UserDefaults = UserDefaults(
            suiteName: AppGroupStorage.appGroupIdentifier
        ) ?? .standard
    ) {
        self.userDefaults = userDefaults
        language = MirageAppLanguage.resolve(
            userDefaults.string(forKey: MirageAppLanguage.storageKey)
        )
    }

    /// 先持久化共享偏好，再发布运行时状态；相同选择不触发无意义的刷新。
    @discardableResult
    func save(_ language: MirageAppLanguage) -> Bool {
        guard self.language != language else { return false }
        userDefaults.set(language.rawValue, forKey: MirageAppLanguage.storageKey)
        self.language = language
        return true
    }
}

/// 设置页底部保存按钮同时观察语言草稿与图片源草稿。
struct SettingsSaveState: Equatable {
    let savedLanguage: MirageAppLanguage
    let draftLanguage: MirageAppLanguage
    let hasPhotoSourceChanges: Bool

    var hasUnsavedChanges: Bool {
        savedLanguage != draftLanguage || hasPhotoSourceChanges
    }
}

/// 主窗口的三个固定内容区；GIF 是发现页中的独立 App 内容类型。
enum AppSection: String, CaseIterable, Identifiable {
    case discover
    case favorites
    case recent

    var id: Self { self }
    var title: String {
        switch self {
        case .discover: return "发现"
        case .favorites: return "收藏"
        case .recent: return "最近使用"
        }
    }

    var localizedTitle: LocalizedStringKey { LocalizedStringKey(title) }

    /// AppKit 导航标题与命令菜单使用显式字符串，避免既有窗口缓存旧的本地化键。
    func resolvedTitle(locale: Locale, bundle: Bundle = .main) -> String {
        switch self {
        case .discover:
            return AppDisplayMessage.localized("发现").resolved(locale: locale, bundle: bundle)
        case .favorites:
            return AppDisplayMessage.localized("收藏").resolved(locale: locale, bundle: bundle)
        case .recent:
            return AppDisplayMessage.localized("最近使用").resolved(locale: locale, bundle: bundle)
        }
    }

    var symbol: String {
        switch self {
        case .discover: return "square.grid.2x2"
        case .favorites: return "heart"
        case .recent: return "clock"
        }
    }
}

/// 搜索来源筛选；图片和头像分段交给 Core 的统一前缀规则。
enum SearchFilter: String, CaseIterable, Identifiable {
    case avatars
    case photos
    case all
    /// 保留旧 rawValue，避免未来恢复既有界面状态时把原 GIPHY 分类识别为未知值。
    case gif = "emoji"

    var id: Self { self }

    /// “全部”仅保留给历史状态与内部混合搜索；内容类型控件不再向用户展示该入口。
    static let contentTypes: [SearchFilter] = [.avatars, .photos, .gif]

    /// GIPHY 内容只属于 App 会话；进入或离开该会话时必须关闭仍在展示的详情资源。
    func crossesGIFBoundary(to other: SearchFilter) -> Bool {
        (self == .gif) != (other == .gif)
    }

    var title: String {
        switch self {
        case .all: return "全部"
        case .photos: return "图片"
        case .avatars: return "头像"
        case .gif: return "GIF"
        }
    }

    var localizedTitle: LocalizedStringKey { LocalizedStringKey(title) }

    /// 分段筛选覆盖输入中的旧前缀，避免产生“图片:头像:”一类无效查询。
    func serviceQuery(for rawQuery: String) -> String {
        guard self != .all else { return rawQuery }
        // GIPHY 使用独立的混合目录入口，不经过字符串查询路由。
        guard self != .gif else { return rawQuery }
        let text = SearchQueryParser.parse(rawQuery).text
        return self == .photos ? "图片:\(text)" : "头像:\(text)"
    }
}

/// 头像筛选保存内容类型集合；空集合会归一化为全部，保证任何时刻至少选中一项。
struct AvatarTypeSelection: Equatable, Sendable {
    private static let supportedTypes = Set(AvatarType.allCases)

    static let all = AvatarTypeSelection(types: supportedTypes)

    private(set) var types: Set<AvatarType>

    init(types: Set<AvatarType>) {
        let validTypes = types.intersection(Self.supportedTypes)
        self.types = validTypes.isEmpty ? Self.supportedTypes : validTypes
    }

    init(persistedValues: [String]?) {
        guard let persistedValues else {
            self = .all
            return
        }
        self.init(types: Set(persistedValues.compactMap(AvatarType.init(rawValue:))))
    }

    var persistedValues: [String] {
        AvatarType.allCases.filter(types.contains).map(\.rawValue)
    }

    var count: Int { types.count }

    func contains(_ type: AvatarType) -> Bool {
        types.contains(type)
    }

    func toggling(_ type: AvatarType) -> AvatarTypeSelection {
        var updatedTypes = types
        if updatedTypes.contains(type) {
            guard updatedTypes.count > 1 else { return self }
            updatedTypes.remove(type)
        } else {
            updatedTypes.insert(type)
        }
        return AvatarTypeSelection(types: updatedTypes)
    }
}

/// 头像筛选通过 App Group 与 Finder 共用；该薄适配器只负责 App 的值类型转换。
@MainActor
struct AvatarTypeSelectionStore {
    private let preferences: DiscoveryFilterPreferencesStore

    static let standard = AvatarTypeSelectionStore(
        preferences: .production()
    )

    init(defaults: UserDefaults) {
        preferences = DiscoveryFilterPreferencesStore(userDefaults: defaults)
    }

    init(preferences: DiscoveryFilterPreferencesStore) {
        self.preferences = preferences
    }

    func load() -> AvatarTypeSelection {
        AvatarTypeSelection(types: preferences.snapshot().avatarTypes)
    }

    func save(_ selection: AvatarTypeSelection) {
        preferences.setAvatarTypes(selection.types)
    }
}

/// GIF 页面保存 Emoji、GIF、Sticker 的多选集合；空集合统一恢复为全部。
struct GiphyContentTypeSelection: Equatable, Sendable {
    private static let supportedTypes = Set(GiphyContentType.allCases)

    static let all = GiphyContentTypeSelection(types: supportedTypes)

    private(set) var types: Set<GiphyContentType>

    init(types: Set<GiphyContentType>) {
        let validTypes = types.intersection(Self.supportedTypes)
        self.types = validTypes.isEmpty ? Self.supportedTypes : validTypes
    }

    init(persistedValues: [String]?) {
        guard let persistedValues else {
            self = .all
            return
        }
        self.init(types: Set(persistedValues.compactMap(GiphyContentType.init(rawValue:))))
    }

    var persistedValues: [String] {
        GiphyContentType.allCases.filter(types.contains).map(\.rawValue)
    }

    var count: Int { types.count }

    func contains(_ type: GiphyContentType) -> Bool {
        types.contains(type)
    }

    func toggling(_ type: GiphyContentType) -> GiphyContentTypeSelection {
        var updatedTypes = types
        if updatedTypes.contains(type) {
            guard updatedTypes.count > 1 else { return self }
            updatedTypes.remove(type)
        } else {
            updatedTypes.insert(type)
        }
        return GiphyContentTypeSelection(types: updatedTypes)
    }
}

/// GIF 类型偏好写入共享筛选快照，供 App 页面跨页签和重启恢复。
@MainActor
struct GiphyContentTypeSelectionStore {
    private let preferences: DiscoveryFilterPreferencesStore

    static let standard = GiphyContentTypeSelectionStore(
        preferences: .production()
    )

    init(defaults: UserDefaults) {
        preferences = DiscoveryFilterPreferencesStore(userDefaults: defaults)
    }

    init(preferences: DiscoveryFilterPreferencesStore) {
        self.preferences = preferences
    }

    func load() -> GiphyContentTypeSelection {
        GiphyContentTypeSelection(types: preferences.snapshot().giphyContentTypes)
    }

    func save(_ selection: GiphyContentTypeSelection) {
        preferences.setGiphyContentTypes(selection.types)
    }
}

/// 图片页来源筛选；`all` 表示聚合当前在 Mirage 中启用的全部图片服务商。
enum PhotoSourceFilterSelection: Hashable, Identifiable, Sendable {
    case all
    case source(PhotoSourceID)

    var id: String {
        switch self {
        case .all: return "all"
        case let .source(sourceID): return sourceID.rawValue
        }
    }

    var sourceID: PhotoSourceID? {
        guard case let .source(sourceID) = self else { return nil }
        return sourceID
    }

    var title: String {
        guard let sourceID else { return "全部" }
        return PhotoSourceRegistry.descriptor(for: sourceID)?.displayName ?? sourceID.rawValue
    }

    /// 展示层保留本地化键；业务层继续使用稳定的普通字符串生成搜索播报。
    var localizedTitle: LocalizedStringKey {
        LocalizedStringKey(title)
    }

    var persistedValue: String { id }

    init(persistedValue: String?) {
        guard let persistedValue,
              let sourceID = PhotoSourceID(rawValue: persistedValue),
              let descriptor = PhotoSourceRegistry.descriptor(for: sourceID),
              descriptor.availability == .available,
              descriptor.supportsAggregatedSearch(on: .app, purpose: .interactive) else {
            self = .all
            return
        }
        self = .source(sourceID)
    }
}

/// 图片来源筛选写入 App Group，Finder 根目录据此选择同一数据范围。
@MainActor
struct PhotoSourceFilterSelectionStore {
    private let preferences: DiscoveryFilterPreferencesStore

    static let standard = PhotoSourceFilterSelectionStore(
        preferences: .production()
    )

    init(defaults: UserDefaults) {
        preferences = DiscoveryFilterPreferencesStore(userDefaults: defaults)
    }

    init(preferences: DiscoveryFilterPreferencesStore) {
        self.preferences = preferences
    }

    func load() -> PhotoSourceFilterSelection {
        preferences.snapshot().photoSourceID.map(PhotoSourceFilterSelection.source) ?? .all
    }

    func save(_ selection: PhotoSourceFilterSelection) {
        preferences.setPhotoSourceID(selection.sourceID)
    }
}

/// 搜索状态完整区分等待、进行中、空结果、网络失败和限流。
enum SearchState: Equatable {
    case idle
    case searching
    case results
    case empty
    case network(AppDisplayMessage)
    case rateLimited(AppDisplayMessage)
    case failed(AppDisplayMessage)

    /// 将 Core 的结构化错误转换成面向用户的精确状态。
    init(openverseError: OpenverseError) {
        switch openverseError {
        case .rateLimited:
            self = .rateLimited(openverseError.appDisplayMessage)
        case .network:
            self = .network(openverseError.appDisplayMessage)
        case .invalidResponse, .decoding:
            self = .failed(openverseError.appDisplayMessage)
        }
    }

    /// 聚合搜索只有在所有启用来源均失败时进入整页失败，并保留最具体的故障类型。
    init(photoSearchError: PhotoSearchError) {
        guard case let .allSourcesFailed(issues) = photoSearchError,
              !issues.isEmpty else {
            self = .failed(photoSearchError.appDisplayMessage)
            return
        }
        let issue = issues.first { $0.kind == .rateLimited }
            ?? issues.first { $0.kind == .network }
            ?? issues.first!
        let message = issue.appDisplayMessage
        switch issue.kind {
        case .rateLimited:
            self = .rateLimited(message)
        case .network:
            self = .network(message)
        case .missingCredential, .invalidCredential, .invalidResponse, .decoding, .unavailable:
            self = .failed(message)
        }
    }
}

/// 共享资料库状态明确区分启动准备与永久失败，避免展示实际上无法执行的收藏操作。
enum LibraryAvailability: Equatable {
    case preparing
    case ready
    case failed(AppDisplayMessage)

    /// 只有 App Group 已成功打开时才允许修改收藏。
    var allowsFavoriteChanges: Bool {
        self == .ready
    }

    /// 永久失败时提供可持续读取的界面说明，启动准备阶段不制造错误提示。
    var unavailableDescription: AppDisplayMessage? {
        guard case let .failed(message) = self else { return nil }
        return .localized("收藏不可用：%@", .message(message))
    }
}

/// 分页状态把自动加载、显式继续、失败和真正结束分开，避免把正常空页当成错误。
enum SearchPaginationState: Equatable {
    case unavailable
    case loadingSources
    case ready
    case loading
    case needsContinuation(AppDisplayMessage)
    case failed(AppDisplayMessage)
    case exhausted

    /// 只有准备态允许尾部卡片预取下一页，其他状态都需要等待或用户操作。
    var allowsAutomaticLoading: Bool {
        self == .ready
    }
}

/// 每次搜索提交只产生一个独立播报事件，避免结果数量和结束状态互相打断。
struct SearchAccessibilityEvent: Equatable {
    let id = UUID()
    let message: AppDisplayMessage
}

/// File Provider 从注册到真实可用的完整状态。
enum ProviderState: Equatable {
    case checking
    case ready
    case needsActivation
    case failed(AppDisplayMessage)

    /// 只在状态进入明确终态时播报，避免检查中的短暂状态打断 VoiceOver。
    var accessibilityAnnouncement: AppDisplayMessage? {
        switch self {
        case .checking:
            return nil
        case .ready:
            return "Mirage 文件提供程序已可用"
        case .needsActivation:
            return "Mirage 文件提供程序需要在系统设置中启用"
        case .failed:
            return "Mirage 文件提供程序检查失败"
        }
    }
}
