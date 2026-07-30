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

/// 已解析的远程图片视图引用。
struct RecordReference: Sendable {
    let recordID: String
    let view: ProviderView
}

/// 将内部错误收敛到 File Provider 接受的错误域。
enum ProviderError {
    /// 未知条目必须返回 noSuchItem，系统据此清理陈旧占位符。
    static func noSuchItem(_ identifier: NSFileProviderItemIdentifier) -> Error {
        NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier)
    }

    /// 只读数据源拒绝所有来自本地文件系统的写操作。
    static func readOnly(_ operation: String) -> Error {
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
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
}
