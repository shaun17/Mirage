import MirageCore
import FileProvider
import Foundation
import UniformTypeIdentifiers

/// Spotlight/File Provider 搜索阶段的轻量结果，不声明父目录。
final class SearchResult: NSObject, NSFileProviderSearchResult {
    let itemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let creationDate: Date? = nil
    let contentModificationDate: Date? = nil
    let lastUsedDate: Date? = nil
    let contentType: UTType = .png
    // 搜索阶段同样不知道远端编码文件大小，保持 nil 让系统按未知值处理。
    let documentSize: NSNumber? = nil

    /// 复用完整条目的文件名规则，确保搜索结果与后续 item(for:) 一致。
    init(record: RemoteImageRecord) {
        let item = ProviderItem(record: record, view: .search)
        itemIdentifier = item.itemIdentifier
        filename = item.filename
        super.init()
    }
}
