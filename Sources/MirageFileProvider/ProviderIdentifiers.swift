import MirageCore
import FileProvider
import Foundation

/// File Provider 公开树中的稳定目录标识。
enum ProviderIdentifiers {
    static let recent = NSFileProviderItemIdentifier("recent")
    static let favorites = NSFileProviderItemIdentifier("favorites")
    static let searchBacking = NSFileProviderItemIdentifier("_search-backing")
    /// 为同一远程记录在不同视图中生成互不冲突的条目标识。
    static func itemIdentifier(recordID: String, view: ProviderView) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier("\(view.rawValue):\(recordID)")
    }

    /// 从视图条目标识中还原远程记录 ID。
    static func recordReference(from identifier: NSFileProviderItemIdentifier) -> RecordReference? {
        for view in ProviderView.allCases {
            let prefix = view.rawValue + ":"
            guard identifier.rawValue.hasPrefix(prefix) else { continue }
            let recordID = String(identifier.rawValue.dropFirst(prefix.count))
            return recordID.isEmpty ? nil : RecordReference(recordID: recordID, view: view)
        }
        return nil
    }
}

/// 远程图片在文件树中的呈现视图。
enum ProviderView: String, CaseIterable, Sendable {
    case discover
    case search
    case recent
    case favorite
}

/// 已解析的远程图片视图引用。推荐流现在是扁平的，位置就等于视图本身。
struct RecordReference: Hashable, Sendable {
    let recordID: String
    let view: ProviderView

    init(recordID: String, view: ProviderView) {
        self.recordID = recordID
        self.view = view
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        ProviderIdentifiers.itemIdentifier(recordID: recordID, view: view)
    }

    /// 每个视图有唯一父目录；推荐图片直接挂在根目录下。
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        switch view {
        case .discover: return .rootContainer
        case .search: return ProviderIdentifiers.searchBacking
        case .recent: return ProviderIdentifiers.recent
        case .favorite: return ProviderIdentifiers.favorites
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
