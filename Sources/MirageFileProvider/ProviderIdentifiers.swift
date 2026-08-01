import MirageCore
import FileProvider
import Foundation

/// File Provider 公开树中的稳定目录标识。
enum ProviderIdentifiers {
    static let avatars = NSFileProviderItemIdentifier("avatars")
    static let recent = NSFileProviderItemIdentifier("recent")
    static let favorites = NSFileProviderItemIdentifier("favorites")
    static let searchBacking = NSFileProviderItemIdentifier("_search-backing")
    static let discoveryPagePrefix = "discover-page:v3:"
    private static let discoveryPageItemPrefix = "discover-page-item:v3:"

    /// 为同一远程记录在不同视图中生成互不冲突的条目标识。
    static func itemIdentifier(recordID: String, view: ProviderView) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier("\(view.rawValue):\(recordID)")
    }

    /// 推荐续页目录的公开 ID 只包含逻辑页码，刷新 generation 不会让 Finder 误判为新目录。
    static func discoveryPageIdentifier(
        _ reference: DiscoveryPageReference
    ) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(discoveryPagePrefix + String(reference.page))
    }

    /// 分页图片的 ID 同时编码逻辑页与完整远程 ID；远程 ID 中的冒号原样保留。
    static func discoveryPageItemIdentifier(
        recordID: String,
        page reference: DiscoveryPageReference
    ) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(
            discoveryPageItemPrefix + String(reference.page) + ":" + recordID
        )
    }

    /// 只接受 canonical v3 续页目录 ID；旧版本、根页和越界页都会失效。
    static func discoveryPageReference(
        from identifier: NSFileProviderItemIdentifier
    ) -> DiscoveryPageReference? {
        guard identifier.rawValue.hasPrefix(discoveryPagePrefix) else { return nil }
        let rawPage = String(identifier.rawValue.dropFirst(discoveryPagePrefix.count))
        return canonicalDiscoveryPage(rawPage)
    }

    /// 从视图条目标识中还原远程记录 ID。
    static func recordReference(from identifier: NSFileProviderItemIdentifier) -> RecordReference? {
        if identifier.rawValue.hasPrefix(discoveryPageItemPrefix) {
            let payload = identifier.rawValue.dropFirst(discoveryPageItemPrefix.count)
            guard let separator = payload.firstIndex(of: ":") else { return nil }
            let rawPage = String(payload[..<separator])
            let recordID = String(payload[payload.index(after: separator)...])
            guard !recordID.isEmpty, let page = canonicalDiscoveryPage(rawPage) else { return nil }
            return RecordReference(recordID: recordID, discoveryPage: page)
        }
        for view in ProviderView.allCases {
            let prefix = view.rawValue + ":"
            guard identifier.rawValue.hasPrefix(prefix) else { continue }
            let recordID = String(identifier.rawValue.dropFirst(prefix.count))
            return recordID.isEmpty ? nil : RecordReference(recordID: recordID, view: view)
        }
        return nil
    }

    /// 拒绝前导零、符号、整数溢出和超过远端推荐容量的非 canonical 页码。
    private static func canonicalDiscoveryPage(_ rawPage: String) -> DiscoveryPageReference? {
        guard let page = Int(rawPage), String(page) == rawPage else { return nil }
        return DiscoveryPageReference(page: page)
    }
}

/// 远程图片在文件树中的呈现视图。
enum ProviderView: String, CaseIterable, Sendable {
    case discover
    case avatar
    case search
    case recent
    case favorite
}

/// 递归推荐目录的稳定逻辑位置。根页只在规划器内部表示，不对系统公开目录 ID。
struct DiscoveryPageReference: Hashable, Sendable {
    /// 底层最多 10,000 页、每页 20 张；File Provider 每批 50 张，因此最多公开 4,000 批。
    static let maximumPage =
        (SearchPaginationCursor.maximumPage * DiscoveryRecommendation.pageSize)
        / ProviderDiscoveryTreePlanner.batchSize

    let page: Int

    init?(page: Int) {
        guard (2...Self.maximumPage).contains(page) else { return nil }
        self.page = page
    }

    init(validating page: Int) throws {
        guard let reference = Self(page: page) else {
            throw ProviderDiscoveryTreeError.invalidPage(page)
        }
        self = reference
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        ProviderIdentifiers.discoveryPageIdentifier(self)
    }

    /// 第 2 批挂在根目录；更深的“更多图片”挂在上一批目录下。
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard page > 2, let parent = DiscoveryPageReference(page: page - 1) else {
            return .rootContainer
        }
        return parent.itemIdentifier
    }
}

/// 远程图片的完整公开位置；同一推荐记录可在根页或不同递归页中拥有独立 occurrence。
struct RecordReference: Hashable, Sendable {
    let recordID: String
    private let location: Location

    private enum Location: Hashable, Sendable {
        case view(ProviderView)
        case discoveryPage(DiscoveryPageReference)
    }

    init(recordID: String, view: ProviderView) {
        self.recordID = recordID
        location = .view(view)
    }

    init(recordID: String, discoveryPage: DiscoveryPageReference) {
        self.recordID = recordID
        location = .discoveryPage(discoveryPage)
    }

    /// 分页 occurrence 仍属于 discover 视图，供内容版本和仓库路由保持一致。
    var view: ProviderView {
        switch location {
        case let .view(view): return view
        case .discoveryPage: return .discover
        }
    }

    var discoveryPage: DiscoveryPageReference? {
        guard case let .discoveryPage(reference) = location else { return nil }
        return reference
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        switch location {
        case let .view(view):
            return ProviderIdentifiers.itemIdentifier(recordID: recordID, view: view)
        case let .discoveryPage(reference):
            return ProviderIdentifiers.discoveryPageItemIdentifier(
                recordID: recordID,
                page: reference
            )
        }
    }

    /// 普通推荐图片挂根目录；分页 occurrence 必须挂在对应的稳定续页目录下。
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        switch location {
        case let .discoveryPage(reference):
            return reference.itemIdentifier
        case let .view(view):
            switch view {
            case .discover: return .rootContainer
            case .avatar: return ProviderIdentifiers.avatars
            case .search: return ProviderIdentifiers.searchBacking
            case .recent: return ProviderIdentifiers.recent
            case .favorite: return ProviderIdentifiers.favorites
            }
        }
    }
}

/// 将内部错误收敛到 File Provider 接受的错误域。
enum ProviderError {
    /// 未知条目必须返回 noSuchItem，系统据此清理陈旧占位符。
    static func noSuchItem(_ identifier: NSFileProviderItemIdentifier) -> Error {
        NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier)
    }

    /// 只读数据源拒绝所有来自本地文件系统的写操作。
    ///
    /// 必须返回 `cannotSynchronize` 这个**终态**错误：早先返回 Cocoa 的
    /// `NSFileWriteNoPermissionError`，系统把它当成可重试失败，于是对同一批条目
    /// 每秒数次地反复调用 `createItem`，把缩略图请求彻底饿死——表现为目录里图片全黑。
    static func readOnly(_ operation: String) -> Error {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: NSFileProviderError.Code.cannotSynchronize.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Mirage 为只读数据源，不能\(operation)。"]
        )
    }

    /// 目录不能通过内容下载接口物化为普通文件。
    static func notAFile() -> Error {
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnsupportedSchemeError,
            userInfo: [NSLocalizedDescriptionKey: "请求的条目是目录，不是可下载文件。"]
        )
    }

    /// 用户或系统取消请求时使用 Cocoa 标准取消错误。
    static func cancelled() -> Error {
        NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    }

    /// 网络、限流及无效远端响应均按服务不可达处理，允许系统稍后重试。
    static func serverUnreachable(_ message: String) -> Error {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: NSFileProviderError.Code.serverUnreachable.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// 请求的旧版本没有本地副本时，明确要求系统重新取得当前版本元数据。
    static func versionNoLongerAvailable() -> Error {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: NSFileProviderError.Code.versionNoLongerAvailable.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "请求的头像版本已更新，旧版本不再可用。"]
        )
    }

    /// 锚点超出持久化历史窗口时要求系统重新执行全量枚举。
    static func syncAnchorExpired() -> Error {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: NSFileProviderError.Code.syncAnchorExpired.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "同步锚点已过期，需要重新枚举。"]
        )
    }

    /// 无法恢复分页令牌时要求系统从第一页重新开始搜索。
    static func invalidSearchPage() -> Error {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: NSFileProviderError.Code.pageExpired.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "搜索分页位置已失效，请重新搜索。"]
        )
    }

    /// 根目录推荐 token 无法恢复时要求系统重新执行首次枚举。
    static func invalidEnumerationPage() -> Error {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: NSFileProviderError.Code.pageExpired.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "推荐分页位置已失效，请重新打开 Mirage。"]
        )
    }

    /// 推荐快照已换代或被历史窗口淘汰时，要求系统重新枚举根目录。
    static func expiredDiscoveryPage() -> Error {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: NSFileProviderError.Code.pageExpired.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "推荐内容已刷新，请重新打开 Mirage 目录。"]
        )
    }
}
