import Foundation

/// 分页令牌损坏或包含越界值时拒绝继续，避免服务端页码失控。
public enum SearchPaginationCursorError: Error, Equatable, Sendable {
    case invalidValues
}

/// 可编码到 File Provider 页令牌中的搜索位置，不包含原始查询文字。
public struct SearchPaginationCursor: Codable, Equatable, Sendable {
    /// Finder 单页最多交付 40 张；主 App 仍由 ImageSearchService 实例限制为 20。
    public static let maximumPageSize = 40
    public static let maximumPage = 10_000
    public static let maximumDelivered = maximumPage * maximumPageSize
    public static let maximumAge: TimeInterval = 10 * 60
    public static let maximumEncodedSize = 64 * 1024

    public let page: Int
    public let pageSize: Int
    public let delivered: Int
    public let issuedAt: Date
    /// 下一次 ImageSearchService 请求的完整位置；包含聚合搜索中每个来源的独立游标。
    public let searchCursor: ImageSearchCursor?
    private let queryFingerprint: String
    private let configurationFingerprint: String

    public init(
        page: Int,
        pageSize: Int,
        delivered: Int,
        query: String,
        configurationKey: String = "legacy",
        searchCursor: ImageSearchCursor? = nil,
        issuedAt: Date = Date()
    ) throws {
        try self.init(
            page: page,
            pageSize: pageSize,
            delivered: delivered,
            issuedAt: issuedAt,
            searchCursor: searchCursor,
            queryFingerprint: Self.fingerprint(query),
            configurationFingerprint: Self.configurationFingerprint(configurationKey)
        )
    }

    /// 集中校验解码值和内部续页值，避免整数溢出或无限页码进入网络层。
    private init(
        page: Int,
        pageSize: Int,
        delivered: Int,
        issuedAt: Date,
        searchCursor: ImageSearchCursor?,
        queryFingerprint: String,
        configurationFingerprint: String
    ) throws {
        guard (1...Self.maximumPage).contains(page),
              (1...Self.maximumPageSize).contains(pageSize),
              (0...Self.maximumDelivered).contains(delivered),
              issuedAt.timeIntervalSinceReferenceDate.isFinite,
              queryFingerprint.count == 64,
              configurationFingerprint.count == 64,
              Self.isValid(searchCursor, forPage: page, pageSize: pageSize) else {
            throw SearchPaginationCursorError.invalidValues
        }
        self.page = page
        self.pageSize = pageSize
        self.delivered = delivered
        self.issuedAt = issuedAt
        self.searchCursor = searchCursor
        self.queryFingerprint = queryFingerprint
        self.configurationFingerprint = configurationFingerprint
    }

    /// 使用稳定 JSON 编码游标，供系统在下一次枚举时原样交还。
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// 解码后再次执行范围校验，不能信任来自系统持久化区的旧令牌。
    public static func decode(_ data: Data) throws -> SearchPaginationCursor {
        guard data.count <= maximumEncodedSize else {
            throw SearchPaginationCursorError.invalidValues
        }
        let value = try JSONDecoder().decode(SearchPaginationCursor.self, from: data)
        return try SearchPaginationCursor(
            page: value.page,
            pageSize: value.pageSize,
            delivered: value.delivered,
            issuedAt: value.issuedAt,
            searchCursor: value.searchCursor,
            queryFingerprint: value.queryFingerprint,
            configurationFingerprint: value.configurationFingerprint
        )
    }

    /// 续页令牌只对原查询、原数据源配置和十分钟内的同一批动态搜索结果有效。
    public func validate(
        for query: String,
        configurationKey: String? = nil,
        now: Date = Date()
    ) throws {
        let age = now.timeIntervalSince(issuedAt)
        let configurationMatches = configurationKey.map {
            configurationFingerprint == Self.configurationFingerprint($0)
        } ?? true
        guard queryFingerprint == Self.fingerprint(query),
              configurationMatches,
              age >= -30,
              age <= Self.maximumAge else {
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
            searchCursor: nil,
            queryFingerprint: queryFingerprint,
            configurationFingerprint: configurationFingerprint
        )
    }

    /// 生产续页必须保存服务返回的完整游标，不能把多来源位置退化成单个页码。
    public func advanced(
        to nextCursor: ImageSearchCursor,
        delivered newDelivered: Int
    ) throws -> SearchPaginationCursor {
        guard nextCursor.page > page, newDelivered >= delivered else {
            throw SearchPaginationCursorError.invalidValues
        }
        return try SearchPaginationCursor(
            page: nextCursor.page,
            pageSize: pageSize,
            delivered: newDelivered,
            issuedAt: issuedAt,
            searchCursor: nextCursor,
            queryFingerprint: queryFingerprint,
            configurationFingerprint: configurationFingerprint
        )
    }

    /// 查询只以不可逆摘要进入系统页令牌，不写入用户原始搜索文字。
    private static func fingerprint(_ query: String) -> String {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return StableImageID.seedHash("mirage-search|\(normalized)")
    }

    /// 配置内容同样只以不可逆摘要进入页令牌。
    private static func configurationFingerprint(_ configurationKey: String) -> String {
        StableImageID.seedHash("mirage-search-configuration|\(configurationKey)")
    }

    /// 对系统交回的嵌套游标做结构与大小校验，具体来源集合仍由聚合器验证。
    private static func isValid(
        _ cursor: ImageSearchCursor?,
        forPage page: Int,
        pageSize: Int
    ) -> Bool {
        guard let cursor else { return true }
        guard cursor.page == page,
              (1...maximumPage).contains(cursor.page),
              let photoCursor = cursor.photoCursor else {
            return cursor.page == page && cursor.photoCursor == nil
        }
        guard !photoCursor.states.isEmpty,
              photoCursor.states.count <= PhotoSourceID.allCases.count,
              Set(photoCursor.states.map(\.sourceID)).count == photoCursor.states.count else {
            return false
        }
        guard photoCursor.states.allSatisfy({ state in
            (1...maximumPageSize).contains(state.pageSize)
                && (state.cursor?.rawValue.utf8.count ?? 0) <= 1_024
        }) else {
            return false
        }
        return photoCursor.states.map(\.pageSize).reduce(0, +) <= pageSize
    }
}
