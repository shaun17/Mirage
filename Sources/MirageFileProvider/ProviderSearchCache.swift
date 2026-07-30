import MirageCore
import Foundation

/// 在扩展进程内缓存近期查询，降低系统逐字搜索对匿名接口额度的消耗。
actor ProviderSearchCache {
    private struct Entry: Sendable {
        let records: [RemoteImageRecord]
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var rateLimitedUntil: Date?
    private let timeToLive: TimeInterval = 10 * 60
    private let maximumEntries = 80

    /// 返回未过期的查询结果；过期数据会在读取时立即清理。
    func records(for query: String, now: Date = Date()) -> [RemoteImageRecord]? {
        let key = Self.key(query)
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > now else {
            entries[key] = nil
            return nil
        }
        return entry.records
    }

    /// 写入查询结果并限制总条目数，防止长时间运行的扩展无限增长。
    func store(_ records: [RemoteImageRecord], for query: String, now: Date = Date()) {
        entries[Self.key(query)] = Entry(
            records: records,
            expiresAt: now.addingTimeInterval(timeToLive)
        )
        guard entries.count > maximumEntries else { return }
        let overflow = entries.count - maximumEntries
        for key in entries.sorted(by: { $0.value.expiresAt < $1.value.expiresAt }).prefix(overflow).map(\.key) {
            entries[key] = nil
        }
    }

    /// 在已知退避期内阻止新请求，并返回剩余等待时间。
    func remainingRateLimit(now: Date = Date()) -> TimeInterval? {
        guard let rateLimitedUntil else { return nil }
        let remaining = rateLimitedUntil.timeIntervalSince(now)
        if remaining <= 0 {
            self.rateLimitedUntil = nil
            return nil
        }
        return remaining
    }

    /// 记录服务端退避时间；无 Retry-After 时采用保守的一分钟。
    func recordRateLimit(retryAfter: TimeInterval?, now: Date = Date()) {
        let delay = max(retryAfter ?? 60, 1)
        rateLimitedUntil = now.addingTimeInterval(delay)
    }

    /// 查询键忽略大小写及首尾空白，但保留中文与内容前缀语义。
    private static func key(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
