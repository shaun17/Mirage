import Foundation

/// App 与 Finder 共用的统一游标；照片内部位置不再被压缩成单个页码。
public struct ImageSearchCursor: Codable, Equatable, Sendable {
    public let page: Int
    public let photoCursor: PhotoSearchCursor?
    /// 保留既有编码字段名以兼容旧游标；现在承载整个 GIPHY 混合目录的复合游标。
    public let emojiCursor: PhotoSourceCursor?

    public var giphyCursor: PhotoSourceCursor? { emojiCursor }

    public init(
        page: Int,
        photoCursor: PhotoSearchCursor?,
        emojiCursor: PhotoSourceCursor? = nil
    ) {
        self.page = page
        self.photoCursor = photoCursor
        self.emojiCursor = emojiCursor
    }
}

public struct ImageSearchPage: Sendable {
    public let records: [RemoteImageRecord]
    public let nextCursor: ImageSearchCursor?
    public let issues: [PhotoSourceIssue]

    public var nextPage: Int? { nextCursor?.page }

    public init(
        records: [RemoteImageRecord],
        nextCursor: ImageSearchCursor?,
        issues: [PhotoSourceIssue] = []
    ) {
        self.records = records
        self.nextCursor = nextCursor
        self.issues = issues
    }

    /// 兼容现有测试替身和单源客户端；生产续页使用 nextCursor 保存每源位置。
    public init(records: [RemoteImageRecord], nextPage: Int?, issues: [PhotoSourceIssue] = []) {
        self.init(
            records: records,
            nextCursor: nextPage.map { ImageSearchCursor(page: $0, photoCursor: nil) },
            issues: issues
        )
    }
}

/// 解析内容范围并组合聚合照片与本地头像；具体照片来源由 PhotoSearching 决定。
public struct ImageSearchService: Sendable {
    private let photos: any PhotoSearching
    private let giphy: (any PhotoSourceSearching)?
    private let avatarProvider: any AvatarProviding
    private let automaticAvatarCount: Int
    private let maximumPageSize: Int

    public init(
        photos: any PhotoSearching,
        giphy: (any PhotoSourceSearching)? = nil,
        diceBear: any AvatarProviding = AvatarCatalogClient(),
        automaticAvatarCount: Int = 4,
        maximumPageSize: Int = DiscoveryRecommendation.pageSize
    ) {
        self.photos = photos
        self.giphy = giphy
        self.avatarProvider = diceBear
        self.automaticAvatarCount = min(max(automaticAvatarCount, 0), 20)
        self.maximumPageSize = min(
            max(maximumPageSize, 1),
            SearchPaginationCursor.maximumPageSize
        )
    }

    public init(
        openverse: any OpenverseSearching = OpenverseClient(),
        giphy: (any PhotoSourceSearching)? = nil,
        diceBear: any AvatarProviding = AvatarCatalogClient(),
        automaticAvatarCount: Int = 4,
        maximumPageSize: Int = DiscoveryRecommendation.pageSize
    ) {
        self.init(
            photos: AggregatedPhotoSearcher(
                sources: [OpenversePhotoSource(client: openverse)],
                configurationRevision: 0
            ),
            giphy: giphy,
            diceBear: diceBear,
            automaticAvatarCount: automaticAvatarCount,
            maximumPageSize: maximumPageSize
        )
    }

    public func configurationKey() async -> String {
        await photos.configurationKey()
    }

    /// App 内 GIPHY 独立入口；空查询浏览混合目录，关键词查询搜索 GIF 与 Sticker。
    public func giphyCatalog(
        query: String = "",
        cursor: ImageSearchCursor?,
        pageSize: Int = SearchPaginationCursor.maximumPageSize
    ) async throws -> ImageSearchPage {
        let page = cursor?.page ?? 1
        let cursorIsConsistent = cursor == nil
            ? page == 1
            : page > 1 && cursor?.giphyCursor != nil
        guard (1...SearchPaginationCursor.maximumPage).contains(page),
              cursor?.photoCursor == nil,
              cursorIsConsistent else {
            throw PhotoSearchError.invalidCursor
        }
        guard let giphy else {
            throw PhotoSearchError.allSourcesFailed([
                PhotoSourceIssue(
                    sourceID: .giphy,
                    kind: .unavailable,
                    message: "GIPHY 数据源仅支持 Mirage App 内的独立 GIF 页面。"
                )
            ])
        }

        let safePageSize = min(max(pageSize, 1), SearchPaginationCursor.maximumPageSize)
        let result = try await giphy.search(
            query: query,
            cursor: cursor?.giphyCursor,
            pageSize: safePageSize
        )
        let next = result.nextCursor.flatMap {
            page < SearchPaginationCursor.maximumPage
                ? ImageSearchCursor(page: page + 1, photoCursor: nil, emojiCursor: $0)
                : nil
        }
        return ImageSearchPage(records: result.records, nextCursor: next, issues: result.issues)
    }

    public func search(
        _ rawQuery: String,
        cursor: ImageSearchCursor?,
        pageSize: Int = 20
    ) async throws -> ImageSearchPage {
        let page = cursor?.page ?? 1
        return try await search(
            rawQuery,
            page: page,
            photoCursor: cursor?.photoCursor,
            pageSize: pageSize,
            onPartialResults: nil
        )
    }

    /// App 交互搜索可在完整游标就绪前接收来源级结果；Finder 等原子调用方继续使用旧入口。
    public func search(
        _ rawQuery: String,
        cursor: ImageSearchCursor?,
        pageSize: Int = 20,
        onPartialResults: @escaping @Sendable ([RemoteImageRecord]) async -> Void
    ) async throws -> ImageSearchPage {
        let page = cursor?.page ?? 1
        return try await search(
            rawQuery,
            page: page,
            photoCursor: cursor?.photoCursor,
            pageSize: pageSize,
            onPartialResults: onPartialResults
        )
    }

    /// 旧页码入口继续服务测试和历史快照；返回值仍携带完整的新游标。
    public func search(_ rawQuery: String, page: Int = 1, pageSize: Int = 20) async throws -> ImageSearchPage {
        try await search(
            rawQuery,
            page: page,
            photoCursor: nil,
            pageSize: pageSize,
            usesLegacyPage: true,
            onPartialResults: nil
        )
    }

    private func search(
        _ rawQuery: String,
        page: Int,
        photoCursor: PhotoSearchCursor?,
        pageSize: Int,
        usesLegacyPage: Bool = false,
        onPartialResults: (@Sendable ([RemoteImageRecord]) async -> Void)?
    ) async throws -> ImageSearchPage {
        let query = SearchQueryParser.parse(rawQuery)
        guard !query.text.isEmpty else { return ImageSearchPage(records: [], nextCursor: nil) }
        guard (1...SearchPaginationCursor.maximumPage).contains(page) else {
            throw SearchPaginationCursorError.invalidValues
        }
        let safePageSize = min(max(pageSize, 1), maximumPageSize)
        let avatarOffset = try Self.avatarOffset(page: page, pageSize: safePageSize)

        switch query.scope {
        case .photo:
            let result = try await photoPage(
                query: query.text,
                page: page,
                cursor: photoCursor,
                pageSize: safePageSize,
                usesLegacyPage: usesLegacyPage,
                onPartialResults: onPartialResults
            )
            return Self.imagePage(from: result, currentPage: page, pageSize: safePageSize)
        case .avatar:
            let records = await avatarProvider.avatars(
                query: query.text,
                offset: avatarOffset,
                count: safePageSize
            )
            let next = records.isEmpty || page == SearchPaginationCursor.maximumPage
                ? nil
                : ImageSearchCursor(page: page + 1, photoCursor: nil)
            return ImageSearchPage(records: records, nextCursor: next)
        case .automatic:
            let avatarCount = min(automaticAvatarCount, safePageSize / 5)
            let photoCount = safePageSize - avatarCount
            let result = try await photoPage(
                query: query.text,
                page: page,
                cursor: photoCursor,
                pageSize: photoCount,
                usesLegacyPage: usesLegacyPage,
                onPartialResults: onPartialResults
            )
            let avatars = await avatarProvider.avatars(
                query: query.text,
                offset: avatarOffset,
                count: safePageSize - result.records.count
            )
            let next = result.nextCursor.flatMap {
                page < SearchPaginationCursor.maximumPage
                    ? ImageSearchCursor(page: page + 1, photoCursor: $0)
                    : nil
            }
            return ImageSearchPage(
                records: Array((result.records + avatars).prefix(safePageSize)),
                nextCursor: next,
                issues: result.issues
            )
        }
    }

    private func photoPage(
        query: String,
        page: Int,
        cursor: PhotoSearchCursor?,
        pageSize: Int,
        usesLegacyPage: Bool,
        onPartialResults: (@Sendable ([RemoteImageRecord]) async -> Void)?
    ) async throws -> PhotoSearchPage {
        if usesLegacyPage { return try await photos.search(query: query, page: page, pageSize: pageSize) }
        if let onPartialResults {
            return try await photos.search(
                query: query,
                cursor: cursor,
                pageSize: pageSize
            ) { batch in
                await onPartialResults(batch.records)
            }
        }
        return try await photos.search(query: query, cursor: cursor, pageSize: pageSize)
    }

    private static func imagePage(
        from result: PhotoSearchPage,
        currentPage: Int,
        pageSize: Int
    ) -> ImageSearchPage {
        let next = result.nextCursor.flatMap {
            currentPage < SearchPaginationCursor.maximumPage
                ? ImageSearchCursor(page: currentPage + 1, photoCursor: $0)
                : nil
        }
        return ImageSearchPage(
            records: Array(result.records.prefix(pageSize)),
            nextCursor: next,
            issues: result.issues
        )
    }

    private static func avatarOffset(page: Int, pageSize: Int) throws -> Int {
        let result = (page - 1).multipliedReportingOverflow(by: pageSize)
        guard !result.overflow else { throw SearchPaginationCursorError.invalidValues }
        return result.partialValue
    }

}
