import Foundation

/// 保留 Openverse 自身 HTTP 合同，并把它适配到通用 provider 游标。
public struct OpenversePhotoSource: PhotoSourceSearching, Sendable {
    public let sourceID = PhotoSourceID.openverse
    private let client: any OpenverseSearching

    public init(client: any OpenverseSearching = OpenverseClient()) {
        self.client = client
    }

    public func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        let page = try Self.page(from: cursor)
        let result = try await client.search(query: query, page: page, pageSize: pageSize)
        let next = result.nextPage.flatMap { candidate -> PhotoSourceCursor? in
            guard candidate > page, candidate <= SearchPaginationCursor.maximumPage else { return nil }
            return PhotoSourceCursor(rawValue: String(candidate))
        }
        return PhotoSourcePage(records: result.records, nextCursor: next)
    }

    private static func page(from cursor: PhotoSourceCursor?) throws -> Int {
        guard let cursor else { return 1 }
        guard let value = Int(cursor.rawValue), String(value) == cursor.rawValue,
              (1...SearchPaginationCursor.maximumPage).contains(value) else {
            throw PhotoSearchError.invalidCursor
        }
        return value
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
