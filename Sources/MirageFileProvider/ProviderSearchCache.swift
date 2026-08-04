import MirageCore
import Foundation

/// 在扩展进程内缓存近期查询，降低系统逐字搜索对匿名接口额度的消耗。
actor ProviderSearchCache {
    private struct Entry: Sendable {
        let page: ImageSearchPage
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let timeToLive: TimeInterval = 10 * 60
    private let maximumEntries = 80

    /// 返回未过期的查询结果；过期数据会在读取时立即清理。
    func page(
        for query: String,
        cursor: ImageSearchCursor?,
        page: Int,
        pageSize: Int,
        configurationKey: String,
        now: Date = Date()
    ) -> ImageSearchPage? {
        let key = Self.key(
            query,
            cursor: cursor,
            page: page,
            pageSize: pageSize,
            configurationKey: configurationKey
        )
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > now else {
            entries[key] = nil
            return nil
        }
        return entry.page
    }

    /// 完整聚合游标和配置都参与键计算，避免同一逻辑页错误复用另一批来源位置。
    func store(
        _ result: ImageSearchPage,
        for query: String,
        cursor: ImageSearchCursor?,
        page: Int,
        pageSize: Int,
        configurationKey: String,
        now: Date = Date()
    ) {
        entries[Self.key(
            query,
            cursor: cursor,
            page: page,
            pageSize: pageSize,
            configurationKey: configurationKey
        )] = Entry(
            page: result,
            expiresAt: now.addingTimeInterval(timeToLive)
        )
        guard entries.count > maximumEntries else { return }
        let overflow = entries.count - maximumEntries
        for key in entries.sorted(by: { $0.value.expiresAt < $1.value.expiresAt }).prefix(overflow).map(\.key) {
            entries[key] = nil
        }
    }

    /// 查询键忽略大小写及首尾空白，但保留中文与内容前缀语义。
    private static func key(
        _ query: String,
        cursor: ImageSearchCursor?,
        page: Int,
        pageSize: Int,
        configurationKey: String
    ) -> String {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let configuration = configurationFingerprint(configurationKey)
        let cursor = cursorFingerprint(cursor)
        return "\(normalized)|configuration:\(configuration)|cursor:\(cursor)|page:\(page)|size:\(pageSize)"
    }

    private static func configurationFingerprint(_ configurationKey: String) -> String {
        StableImageID.seedHash("mirage-search-cache-configuration|\(configurationKey)")
    }

    private static func cursorFingerprint(_ cursor: ImageSearchCursor?) -> String {
        guard let cursor else { return "initial" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(cursor) else { return "invalid" }
        return StableImageID.seedHash("mirage-search-cache-cursor|\(data.base64EncodedString())")
    }
}
