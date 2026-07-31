import MirageCore
import Foundation

/// 搜索枚举器只依赖结果持久化能力，便于隔离验证多页回调和取消行为。
protocol ProviderSearchResultStoring: Sendable {
    /// 保存当前搜索页；第一页替换旧查询，后续页按稳定图片 ID 追加。
    func storeSearchResults(
        _ records: [RemoteImageRecord],
        queryKey: String,
        appending: Bool
    ) async throws
}
