import Foundation

/// 分页令牌损坏或包含越界值时拒绝继续，避免服务端页码失控。
public enum SearchPaginationCursorError: Error, Equatable, Sendable {
    case invalidValues
}

/// 可编码到 File Provider 页令牌中的搜索位置，不包含原始查询文字。
public struct SearchPaginationCursor: Codable, Equatable, Sendable {
    public static let maximumPageSize = 20
    public static let maximumPage = 10_000
    public static let maximumDelivered = maximumPage * maximumPageSize
    public static let maximumAge: TimeInterval = 10 * 60

    public let page: Int
    public let pageSize: Int
    public let delivered: Int
    public let issuedAt: Date
    private let queryFingerprint: String

    public init(
        page: Int,
        pageSize: Int,
        delivered: Int,
        query: String,
        issuedAt: Date = Date()
    ) throws {
        try self.init(
            page: page,
            pageSize: pageSize,
            delivered: delivered,
            issuedAt: issuedAt,
            queryFingerprint: Self.fingerprint(query)
        )
    }

    /// 集中校验解码值和内部续页值，避免整数溢出或无限页码进入网络层。
    private init(
        page: Int,
        pageSize: Int,
        delivered: Int,
        issuedAt: Date,
        queryFingerprint: String
    ) throws {
        guard (1...Self.maximumPage).contains(page),
              (1...Self.maximumPageSize).contains(pageSize),
              (0...Self.maximumDelivered).contains(delivered),
              issuedAt.timeIntervalSinceReferenceDate.isFinite,
              queryFingerprint.count == 64 else {
            throw SearchPaginationCursorError.invalidValues
        }
        self.page = page
        self.pageSize = pageSize
        self.delivered = delivered
        self.issuedAt = issuedAt
        self.queryFingerprint = queryFingerprint
    }

    /// 使用稳定 JSON 编码游标，供系统在下一次枚举时原样交还。
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// 解码后再次执行范围校验，不能信任来自系统持久化区的旧令牌。
    public static func decode(_ data: Data) throws -> SearchPaginationCursor {
        let value = try JSONDecoder().decode(SearchPaginationCursor.self, from: data)
        return try SearchPaginationCursor(
            page: value.page,
            pageSize: value.pageSize,
            delivered: value.delivered,
            issuedAt: value.issuedAt,
            queryFingerprint: value.queryFingerprint
        )
    }

    /// 续页令牌只对原查询和十分钟内的同一批动态搜索结果有效。
    public func validate(for query: String, now: Date = Date()) throws {
        let age = now.timeIntervalSince(issuedAt)
        guard queryFingerprint == Self.fingerprint(query), age >= -30, age <= Self.maximumAge else {
            throw SearchPaginationCursorError.invalidValues
        }
    }

    /// 使用报告溢出的加法累计已交付数量，拒绝伪造令牌触发运行时崩溃。
    public func deliveredCount(adding count: Int) throws -> Int {
        guard count >= 0 else { throw SearchPaginationCursorError.invalidValues }
        let addition = delivered.addingReportingOverflow(count)
        guard !addition.overflow, addition.partialValue <= Self.maximumDelivered else {
            throw SearchPaginationCursorError.invalidValues
        }
        return addition.partialValue
    }

    /// 创建严格向前且继承原查询会话的下一页游标。
    public func advanced(to nextPage: Int, delivered newDelivered: Int) throws -> SearchPaginationCursor {
        guard nextPage > page, newDelivered >= delivered else {
            throw SearchPaginationCursorError.invalidValues
        }
        return try SearchPaginationCursor(
            page: nextPage,
            pageSize: pageSize,
            delivered: newDelivered,
            issuedAt: issuedAt,
            queryFingerprint: queryFingerprint
        )
    }

    /// 查询只以不可逆摘要进入系统页令牌，不写入用户原始搜索文字。
    private static func fingerprint(_ query: String) -> String {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return StableImageID.seedHash("mirage-search|\(normalized)")
    }
}
