import Foundation

/// 一次统一搜索的结果页；下一页由服务端页数或本地头像偏移决定。
public struct ImageSearchPage: Sendable {
    public let records: [RemoteImageRecord]
    public let nextPage: Int?

    public init(records: [RemoteImageRecord], nextPage: Int?) {
        self.records = records
        self.nextPage = nextPage
    }
}

/// 根据显式前缀决定图片搜索来源，并维护默认结果的来源顺序。
public struct ImageSearchService: Sendable {
    private let openverse: any OpenverseSearching
    private let diceBear: any DiceBearProviding
    private let automaticAvatarCount: Int

    public init(
        openverse: any OpenverseSearching = OpenverseClient(),
        diceBear: any DiceBearProviding = DiceBearClient(),
        automaticAvatarCount: Int = 4
    ) {
        self.openverse = openverse
        self.diceBear = diceBear
        self.automaticAvatarCount = min(max(automaticAvatarCount, 0), 20)
    }

    /// 每页严格最多返回 pageSize 条；无前缀时照片在前、头像在后。
    public func search(_ rawQuery: String, page: Int = 1, pageSize: Int = 20) async throws -> ImageSearchPage {
        let query = SearchQueryParser.parse(rawQuery)
        guard !query.text.isEmpty else { return ImageSearchPage(records: [], nextPage: nil) }
        guard (1...SearchPaginationCursor.maximumPage).contains(page) else {
            throw SearchPaginationCursorError.invalidValues
        }
        let safePageSize = min(max(pageSize, 1), SearchPaginationCursor.maximumPageSize)
        let avatarOffset = try Self.avatarOffset(page: page, pageSize: safePageSize)

        switch query.scope {
        case .photo:
            let response = try await openverse.search(query: query.text, page: page, pageSize: safePageSize)
            return Self.normalized(response, after: page, pageSize: safePageSize)
        case .avatar:
            let records = await diceBear.avatars(
                query: query.text,
                offset: avatarOffset,
                count: safePageSize
            )
            let nextPage = records.isEmpty || page == SearchPaginationCursor.maximumPage ? nil : page + 1
            return ImageSearchPage(records: records, nextPage: nextPage)
        case .automatic:
            // 自动模式按约20%头像配额缩放，小页优先保留真实照片且默认20条仍为16+4。
            let avatarCount = min(automaticAvatarCount, safePageSize / 5)
            let photoCount = safePageSize - avatarCount
            let photoPage = try await openverse.search(query: query.text, page: page, pageSize: photoCount)
            // 本地安全过滤可能减少照片数量，使用本页独立头像区间补足20条且不跨页重复。
            let avatars = await diceBear.avatars(
                query: query.text,
                offset: avatarOffset,
                count: safePageSize - photoPage.records.count
            )
            return ImageSearchPage(
                records: Array((photoPage.records + avatars).prefix(safePageSize)),
                nextPage: Self.validNextPage(photoPage.nextPage, after: page)
            )
        }
    }

    /// 用显式溢出检查计算头像绝对偏移，不能让外部页码触发整数陷阱。
    private static func avatarOffset(page: Int, pageSize: Int) throws -> Int {
        let result = (page - 1).multipliedReportingOverflow(by: pageSize)
        guard !result.overflow else { throw SearchPaginationCursorError.invalidValues }
        return result.partialValue
    }

    /// 统一截断异常数据源的超量记录，并只接受严格向前的有限续页。
    private static func normalized(
        _ response: ImageSearchPage,
        after page: Int,
        pageSize: Int
    ) -> ImageSearchPage {
        ImageSearchPage(
            records: Array(response.records.prefix(pageSize)),
            nextPage: validNextPage(response.nextPage, after: page)
        )
    }

    /// 数据源返回当前页、倒退页或超过安全上限时视为已经结束。
    private static func validNextPage(_ candidate: Int?, after page: Int) -> Int? {
        guard let candidate, candidate > page, candidate <= SearchPaginationCursor.maximumPage else { return nil }
        return candidate
    }
}
