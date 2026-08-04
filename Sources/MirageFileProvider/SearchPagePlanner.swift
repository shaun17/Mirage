import MirageCore
@preconcurrency import FileProvider
import Foundation

/// 把系统结果上限与远端页码转换为稳定的 File Provider 分页计划。
@available(macOS 26.0, *)
enum SearchPagePlanner {
    /// 首次枚举确定固定页大小；后续页从不改变它，避免远端分页边界漂移。
    static func cursor(
        startingAt page: NSFileProviderPage?,
        request: NSFileProviderStringSearchRequest,
        observer: any NSFileProviderSearchEnumerationObserver,
        configurationKey: String
    ) throws -> SearchPaginationCursor {
        if let page {
            do {
                let cursor = try SearchPaginationCursor.decode(page.rawValue)
                try cursor.validate(for: request.query, configurationKey: configurationKey)
                let observerLimit = observer.maximumNumberOfResultsPerPage
                guard observerLimit <= 0 || cursor.pageSize <= observerLimit else {
                    throw SearchPaginationCursorError.invalidValues
                }
                guard cursor.page == 1 || cursor.searchCursor != nil else {
                    throw SearchPaginationCursorError.invalidValues
                }
                return cursor
            } catch {
                throw ProviderError.invalidSearchPage()
            }
        }
        let limits = [
            SearchPaginationCursor.maximumPageSize,
            observer.maximumNumberOfResultsPerPage,
            request.desiredNumberOfResults
        ]
            .filter { $0 > 0 }
        return try SearchPaginationCursor(
            page: 1,
            pageSize: limits.min() ?? SearchPaginationCursor.maximumPageSize,
            delivered: 0,
            query: request.query,
            configurationKey: configurationKey
        )
    }

    /// 每次交付都执行有界加法，伪造或超深游标统一要求系统重新开始。
    static func deliveredCount(after cursor: SearchPaginationCursor, adding count: Int) throws -> Int {
        do {
            return try cursor.deliveredCount(adding: count)
        } catch {
            throw ProviderError.invalidSearchPage()
        }
    }

    /// desiredNumberOfResults 只是提示；远端存在严格向前的页码就继续交给系统决定是否调用。
    static func nextPage(
        after result: ImageSearchPage,
        cursor: SearchPaginationCursor,
        delivered: Int
    ) throws -> NSFileProviderPage? {
        guard let nextCursor = result.nextCursor else { return nil }
        do {
            let next = try cursor.advanced(to: nextCursor, delivered: delivered)
            return NSFileProviderPage(rawValue: try next.encoded())
        } catch {
            throw ProviderError.invalidSearchPage()
        }
    }
}
