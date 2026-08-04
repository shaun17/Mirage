import Foundation

/// 保留 Openverse 自身 HTTP 合同，并把它适配到通用 provider 游标。
public struct OpenversePhotoSource: PhotoSourceSearching, Sendable {
    public let sourceID = PhotoSourceID.openverse
    private let client: any OpenverseSearching
    private static let cursorPrefix = "ov1:"

    public init(client: any OpenverseSearching = OpenverseClient()) {
        self.client = client
    }

    public func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        guard (1...SearchPaginationCursor.maximumPageSize).contains(pageSize) else {
            throw PhotoSearchError.invalidCursor
        }
        var position = try Self.position(from: cursor, logicalPageSize: pageSize)
        let upstreamPageSize = Self.upstreamPageSize(
            logicalPageSize: pageSize,
            startingOffset: position.offset
        )
        let requestLimit = Self.requestLimit(
            pageSize: pageSize,
            startingOffset: position.offset,
            upstreamPageSize: upstreamPageSize
        )
        var records: [RemoteImageRecord] = []
        var seen = Set<String>()
        var continuation: CursorPosition?

        for _ in 0..<requestLimit where records.count < pageSize {
            try Task.checkCancellation()
            let result = try await client.search(
                query: query,
                page: position.page,
                pageSize: upstreamPageSize
            )
            guard position.offset <= result.records.count else {
                throw PhotoSearchError.invalidCursor
            }

            var consumedOffset = position.offset
            for index in position.offset..<result.records.count where records.count < pageSize {
                consumedOffset = index + 1
                let record = result.records[index]
                if seen.insert(record.id).inserted {
                    records.append(record)
                }
            }

            if consumedOffset < result.records.count {
                continuation = CursorPosition(page: position.page, offset: consumedOffset)
                break
            }
            guard let nextPage = Self.nextPage(after: position.page, candidate: result.nextPage) else {
                continuation = nil
                break
            }
            position = CursorPosition(page: nextPage, offset: 0)
            continuation = position
        }

        return PhotoSourcePage(
            records: records,
            nextCursor: continuation.map(Self.cursor(from:))
        )
    }

    /// 20 条以内保持调用方页宽；更大的 Mirage 逻辑批次才拆成固定 20 条上游页。
    private static func upstreamPageSize(logicalPageSize: Int, startingOffset: Int) -> Int {
        startingOffset > 0
            ? OpenverseClient.maximumAnonymousPageSize
            : min(logicalPageSize, OpenverseClient.maximumAnonymousPageSize)
    }

    /// 非 20 倍数的逻辑批次会在游标中保留页内偏移，下一次可从同一远端页续读。
    private static func requestLimit(
        pageSize: Int,
        startingOffset: Int,
        upstreamPageSize: Int
    ) -> Int {
        return (startingOffset + pageSize + upstreamPageSize - 1) / upstreamPageSize
    }

    private static func nextPage(after page: Int, candidate: Int?) -> Int? {
        guard let candidate,
              candidate > page,
              candidate <= SearchPaginationCursor.maximumPage else { return nil }
        return candidate
    }

    private static func position(
        from cursor: PhotoSourceCursor?,
        logicalPageSize: Int
    ) throws -> CursorPosition {
        guard let cursor else { return CursorPosition(page: 1, offset: 0) }
        if let logicalPage = canonicalInteger(cursor.rawValue),
           (1...SearchPaginationCursor.maximumPage).contains(logicalPage) {
            let upstreamPageSize = min(
                logicalPageSize,
                OpenverseClient.maximumAnonymousPageSize
            )
            let absoluteOffset = (logicalPage - 1).multipliedReportingOverflow(
                by: logicalPageSize
            )
            guard !absoluteOffset.overflow else { throw PhotoSearchError.invalidCursor }
            let pageOffset = absoluteOffset.partialValue / upstreamPageSize
            let remotePage = pageOffset.addingReportingOverflow(1)
            guard !remotePage.overflow,
                  remotePage.partialValue <= SearchPaginationCursor.maximumPage else {
                throw PhotoSearchError.invalidCursor
            }
            return CursorPosition(
                page: remotePage.partialValue,
                offset: absoluteOffset.partialValue % upstreamPageSize
            )
        }

        guard cursor.rawValue.hasPrefix(cursorPrefix) else {
            throw PhotoSearchError.invalidCursor
        }
        let components = cursor.rawValue
            .dropFirst(cursorPrefix.count)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let page = canonicalInteger(String(components[0])),
              let offset = canonicalInteger(String(components[1])),
              (1...SearchPaginationCursor.maximumPage).contains(page),
              (0..<OpenverseClient.maximumAnonymousPageSize).contains(offset) else {
            throw PhotoSearchError.invalidCursor
        }
        return CursorPosition(page: page, offset: offset)
    }

    private static func cursor(from position: CursorPosition) -> PhotoSourceCursor {
        return PhotoSourceCursor(
            rawValue: "\(cursorPrefix)\(position.page):\(position.offset)"
        )
    }

    private static func canonicalInteger(_ value: String) -> Int? {
        guard let integer = Int(value), String(integer) == value else { return nil }
        return integer
    }

    private struct CursorPosition: Sendable {
        let page: Int
        let offset: Int
    }
}

extension OpenverseError: PhotoSourceFailure {
    public var sourceID: PhotoSourceID { .openverse }

    public var issueKind: PhotoSourceIssueKind {
        switch self {
        case .rateLimited: return .rateLimited
        case .network: return .network
        case .invalidResponse: return .invalidResponse
        case .decoding: return .decoding
        }
    }

    public var retryAt: Date? {
        guard case let .rateLimited(delay) = self, let delay else { return nil }
        return Date().addingTimeInterval(max(delay, 0))
    }
}
