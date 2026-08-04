import Foundation

public enum GiphyCatalogError: Error, Equatable, Sendable {
    case invalidCursor
}

extension GiphyCatalogError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCursor:
            return "GIPHY GIF 分页位置无效。"
        }
    }
}

extension GiphyCatalogError: PhotoSourceFailure {
    public var sourceID: PhotoSourceID { .giphy }
    public var issueKind: PhotoSourceIssueKind { .invalidResponse }
    public var retryAt: Date? { nil }
}

/// 将 GIPHY Emoji、Trending GIF 与 Trending Sticker 合并为一个可续页目录。
public struct GiphyCatalogClient: PhotoSourceSearching, Sendable {
    public static let emojiEndpoint = URL(string: "https://api.giphy.com/v2/emoji")!
    public static let gifTrendingEndpoint = URL(string: "https://api.giphy.com/v1/gifs/trending")!
    public static let stickerTrendingEndpoint = URL(string: "https://api.giphy.com/v1/stickers/trending")!
    public static let maximumPageSize = 40

    public let sourceID = PhotoSourceID.giphy

    private static let cursorPrefix = "gm1:"
    private static let maximumCursorBytes = 1_024
    private static let maximumPage = Int(Int32.max)

    private let feeds: [Feed]

    /// 三个子客户端共用同一个无持久缓存会话，避免含 API Key 的请求 URL 被写入 URLCache。
    public init(
        apiKey: String,
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let sharedSession = session ?? Self.makeEphemeralSession()
        self.init(
            emoji: GiphyEmojiClient(
                apiKey: apiKey,
                session: sharedSession,
                endpoint: Self.emojiEndpoint,
                rating: nil,
                now: now
            ),
            gifTrending: GiphyEmojiClient(
                apiKey: apiKey,
                session: sharedSession,
                endpoint: Self.gifTrendingEndpoint,
                rating: "g",
                now: now
            ),
            stickerTrending: GiphyEmojiClient(
                apiKey: apiKey,
                session: sharedSession,
                endpoint: Self.stickerTrendingEndpoint,
                rating: "g",
                now: now
            )
        )
    }

    /// 模块测试入口；生产入口始终创建固定官方 endpoint 的 GiphyEmojiClient。
    init(
        emoji: any PhotoSourceSearching,
        gifTrending: any PhotoSourceSearching,
        stickerTrending: any PhotoSourceSearching
    ) {
        self.feeds = [
            Feed(kind: .emoji, client: emoji),
            Feed(kind: .gifTrending, client: gifTrending),
            Feed(kind: .stickerTrending, client: stickerTrending)
        ]
    }

    public func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        try Task.checkCancellation()
        let safePageSize = min(max(pageSize, 1), Self.maximumPageSize)
        let current = try Self.cursorState(from: cursor)
        let stateByKind = Dictionary(uniqueKeysWithValues: current.states.map { ($0.kind, $0) })
        let activeFeeds = feeds.filter { stateByKind[$0.kind]?.exhausted == false }

        guard !activeFeeds.isEmpty else {
            return PhotoSourcePage(records: [], nextCursor: nil)
        }

        let quotas = Self.quotas(
            total: safePageSize,
            count: activeFeeds.count,
            page: current.page
        )
        let requests = zip(activeFeeds, quotas).compactMap { feed, quota -> FeedRequest? in
            guard quota > 0, let state = stateByKind[feed.kind] else { return nil }
            return FeedRequest(feed: feed, state: state, quota: quota)
        }
        let outcomes = await Self.loadConcurrently(
            requests: requests,
            query: query
        )

        try Task.checkCancellation()
        if outcomes.contains(where: \.isCancelled) {
            throw CancellationError()
        }

        let outcomeByKind = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.kind, $0) })
        var nextStates = current.states
        var visiblePages: [FeedKind: [RemoteImageRecord]] = [:]
        var feedIssues: [FeedIssue] = []
        var failures: [(feed: FeedKind, error: any Error)] = []
        var successCount = 0

        for request in requests {
            guard let outcome = outcomeByKind[request.feed.kind] else { continue }
            switch outcome {
            case let .success(kind, page):
                do {
                    let nextState = try Self.advancedState(
                        from: request.state,
                        nextCursor: page.nextCursor
                    )
                    guard let stateIndex = nextStates.firstIndex(where: { $0.kind == kind }) else {
                        throw GiphyCatalogError.invalidCursor
                    }
                    nextStates[stateIndex] = nextState
                    visiblePages[kind] = Array(page.records.prefix(request.quota))
                    feedIssues.append(contentsOf: page.issues.map { Self.feedIssue(from: $0, feed: kind) })
                    successCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append((kind, error))
                    feedIssues.append(Self.feedIssue(for: error, feed: kind))
                }
            case let .failure(kind, error):
                failures.append((kind, error))
                feedIssues.append(Self.feedIssue(for: error, feed: kind))
            case .cancelled:
                throw CancellationError()
            }
        }

        // 三个 endpoint 共用同一把 Key；任一路认证失败都代表目录配置不可用，不能伪装成部分成功。
        if let credentialFailure = failures.first(where: {
            guard let failure = $0.error as? any PhotoSourceFailure else { return false }
            return failure.issueKind == .missingCredential || failure.issueKind == .invalidCredential
        }) {
            throw credentialFailure.error
        }

        guard successCount > 0 else {
            throw Self.mostSpecificError(in: failures)
        }

        let records = Self.interleaved(visiblePages)
        let nextCursor: PhotoSourceCursor?
        if nextStates.contains(where: { !$0.exhausted }) {
            let (nextPage, overflow) = current.page.addingReportingOverflow(1)
            guard !overflow, nextPage <= Self.maximumPage else {
                throw GiphyCatalogError.invalidCursor
            }
            nextCursor = try Self.encodedCursor(page: nextPage, states: nextStates)
        } else {
            nextCursor = nil
        }

        let issues = Self.consolidatedIssue(from: feedIssues).map { [$0] } ?? []
        return PhotoSourcePage(records: records, nextCursor: nextCursor, issues: issues)
    }

    private static func loadConcurrently(
        requests: [FeedRequest],
        query: String
    ) async -> [FeedOutcome] {
        await withTaskGroup(of: FeedOutcome.self, returning: [FeedOutcome].self) { group in
            for request in requests {
                group.addTask {
                    do {
                        let page = try await request.feed.client.search(
                            query: query,
                            cursor: request.state.cursor.map(PhotoSourceCursor.init(rawValue:)),
                            pageSize: request.quota
                        )
                        try Task.checkCancellation()
                        return .success(kind: request.feed.kind, page: page)
                    } catch is CancellationError {
                        return .cancelled(kind: request.feed.kind)
                    } catch {
                        return .failure(kind: request.feed.kind, error: error)
                    }
                }
            }

            var values: [FeedOutcome] = []
            for await outcome in group {
                values.append(outcome)
                if outcome.isCancelled { group.cancelAll() }
            }
            return values
        }
    }

    /// 当前页从 page 对应的活跃流开始分配余数，确保连续页面不会固定偏向 Emoji。
    private static func quotas(total: Int, count: Int, page: Int) -> [Int] {
        guard count > 0 else { return [] }
        let base = total / count
        let remainder = total % count
        let start = page % count
        var values = Array(repeating: base, count: count)
        for offset in 0..<remainder {
            values[(start + offset) % count] += 1
        }
        return values
    }

    /// 输出顺序独立于网络完成顺序，固定按 Emoji、GIF、Sticker 轮询并跨流去重。
    private static func interleaved(_ pages: [FeedKind: [RemoteImageRecord]]) -> [RemoteImageRecord] {
        let maximum = pages.values.map(\.count).max() ?? 0
        var records: [RemoteImageRecord] = []
        var seen = Set<String>()
        for index in 0..<maximum {
            for kind in FeedKind.allCases {
                guard let page = pages[kind], page.indices.contains(index) else { continue }
                let record = page[index]
                if seen.insert(record.id).inserted { records.append(record) }
            }
        }
        return records
    }

    private static func cursorState(from cursor: PhotoSourceCursor?) throws -> CatalogCursorState {
        guard let cursor else {
            return CatalogCursorState(
                page: 0,
                states: FeedKind.allCases.map {
                    FeedCursorState(kind: $0, cursor: nil, exhausted: false)
                }
            )
        }
        let rawValue = cursor.rawValue
        guard rawValue.utf8.count <= maximumCursorBytes,
              rawValue.hasPrefix(cursorPrefix) else {
            throw GiphyCatalogError.invalidCursor
        }
        let payload = String(rawValue.dropFirst(cursorPrefix.count))
        guard let data = base64URLDecoded(payload) else {
            throw GiphyCatalogError.invalidCursor
        }

        let wire: WireCursor
        do {
            wire = try JSONDecoder().decode(WireCursor.self, from: data)
        } catch {
            throw GiphyCatalogError.invalidCursor
        }
        guard (1...maximumPage).contains(wire.page),
              wire.feeds.map(\.kind) == FeedKind.allCases else {
            throw GiphyCatalogError.invalidCursor
        }

        let states = try wire.feeds.map { value -> FeedCursorState in
            guard !value.exhausted || value.cursor == nil else {
                throw GiphyCatalogError.invalidCursor
            }
            if let cursor = value.cursor {
                _ = try feedOffset(cursor, kind: value.kind)
            }
            return FeedCursorState(
                kind: value.kind,
                cursor: value.cursor,
                exhausted: value.exhausted
            )
        }
        return CatalogCursorState(page: wire.page, states: states)
    }

    private static func encodedCursor(
        page: Int,
        states: [FeedCursorState]
    ) throws -> PhotoSourceCursor {
        guard (1...maximumPage).contains(page),
              states.map(\.kind) == FeedKind.allCases else {
            throw GiphyCatalogError.invalidCursor
        }
        for state in states {
            guard !state.exhausted || state.cursor == nil else {
                throw GiphyCatalogError.invalidCursor
            }
            if let cursor = state.cursor { _ = try feedOffset(cursor, kind: state.kind) }
        }

        let wire = WireCursor(
            page: page,
            feeds: states.map {
                WireFeedState(kind: $0.kind, cursor: $0.cursor, exhausted: $0.exhausted)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rawValue = cursorPrefix + base64URLEncoded(try encoder.encode(wire))
        guard rawValue.utf8.count <= maximumCursorBytes else {
            throw GiphyCatalogError.invalidCursor
        }
        return PhotoSourceCursor(rawValue: rawValue)
    }

    private static func advancedState(
        from current: FeedCursorState,
        nextCursor: PhotoSourceCursor?
    ) throws -> FeedCursorState {
        guard let nextCursor else {
            return FeedCursorState(
                kind: current.kind,
                cursor: nil,
                exhausted: true
            )
        }
        let nextOffset = try numericOffset(nextCursor.rawValue)
        let currentOffset = try current.cursor.map(numericOffset) ?? 0
        guard nextOffset > currentOffset else { throw GiphyCatalogError.invalidCursor }
        if nextOffset > current.kind.maximumRequestOffset {
            return FeedCursorState(
                kind: current.kind,
                cursor: nil,
                exhausted: true
            )
        }
        return FeedCursorState(
            kind: current.kind,
            cursor: nextCursor.rawValue,
            exhausted: false
        )
    }

    /// 三个固定 GIPHY endpoint 的子游标都是规范十进制 offset；Trending 官方上限为 499。
    private static func feedOffset(_ rawValue: String, kind: FeedKind) throws -> Int {
        let value = try numericOffset(rawValue)
        guard value <= kind.maximumRequestOffset else {
            throw GiphyCatalogError.invalidCursor
        }
        return value
    }

    private static func numericOffset(_ rawValue: String) throws -> Int {
        guard let value = Int(rawValue),
              value >= 0,
              value <= Int(Int32.max),
              String(value) == rawValue else {
            throw GiphyCatalogError.invalidCursor
        }
        return value
    }

    private static func feedIssue(for error: any Error, feed: FeedKind) -> FeedIssue {
        if let failure = error as? any PhotoSourceFailure {
            return FeedIssue(
                feed: feed,
                kind: failure.issueKind,
                retryAt: failure.retryAt
            )
        }
        return FeedIssue(
            feed: feed,
            kind: .unavailable,
            retryAt: nil
        )
    }

    private static func feedIssue(from issue: PhotoSourceIssue, feed: FeedKind) -> FeedIssue {
        FeedIssue(
            feed: feed,
            kind: issue.kind,
            retryAt: issue.retryAt
        )
    }

    /// DiscoverView 以 sourceID 标识 issue，因此三个内部子流必须合并成一个 GIPHY issue。
    private static func consolidatedIssue(from values: [FeedIssue]) -> PhotoSourceIssue? {
        guard !values.isEmpty else { return nil }
        let failedFeeds = Set(values.map(\.feed))
        let names = FeedKind.allCases
            .filter { failedFeeds.contains($0) }
            .map(\.displayName)
            .joined(separator: "、")
        let kind = values.reduce(PhotoSourceIssueKind.unavailable) { current, value in
            specificity(of: value.kind) > specificity(of: current) ? value.kind : current
        }
        let retryAt = values.compactMap(\.retryAt).max()
        return PhotoSourceIssue(
            sourceID: .giphy,
            kind: kind,
            message: "GIPHY \(names) 子流暂时不可用。",
            retryAt: retryAt
        )
    }

    private static func mostSpecificError(
        in failures: [(feed: FeedKind, error: any Error)]
    ) -> any Error {
        var selected: (error: any Error, rank: Int)?
        for failure in failures {
            let rank = specificity(of: failure.error)
            if selected == nil || rank > selected!.rank {
                selected = (failure.error, rank)
            }
        }
        return selected?.error ?? GiphyCatalogError.invalidCursor
    }

    private static func specificity(of error: any Error) -> Int {
        guard let failure = error as? any PhotoSourceFailure else { return 0 }
        return specificity(of: failure.issueKind)
    }

    private static func specificity(of kind: PhotoSourceIssueKind) -> Int {
        switch kind {
        case .missingCredential: return 80
        case .invalidCredential: return 70
        case .decoding: return 60
        case .invalidResponse: return 50
        case .rateLimited: return 40
        case .network: return 30
        case .unavailable: return 20
        }
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              base64URLEncoded(data) == value else {
            return nil
        }
        return data
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }
}

private extension GiphyCatalogClient {
    enum FeedKind: String, Codable, CaseIterable, Hashable, Sendable {
        case emoji = "e"
        case gifTrending = "g"
        case stickerTrending = "s"

        var displayName: String {
            switch self {
            case .emoji: return "Emoji"
            case .gifTrending: return "GIF"
            case .stickerTrending: return "Sticker"
            }
        }

        var maximumRequestOffset: Int {
            switch self {
            case .emoji: return Int(Int32.max)
            case .gifTrending, .stickerTrending: return 499
            }
        }
    }

    struct Feed: Sendable {
        let kind: FeedKind
        let client: any PhotoSourceSearching
    }

    struct FeedRequest: Sendable {
        let feed: Feed
        let state: FeedCursorState
        let quota: Int
    }

    enum FeedOutcome: Sendable {
        case success(kind: FeedKind, page: PhotoSourcePage)
        case failure(kind: FeedKind, error: any Error)
        case cancelled(kind: FeedKind)

        var kind: FeedKind {
            switch self {
            case let .success(kind, _), let .failure(kind, _), let .cancelled(kind): return kind
            }
        }

        var isCancelled: Bool {
            guard case .cancelled = self else { return false }
            return true
        }
    }

    struct CatalogCursorState: Sendable {
        let page: Int
        let states: [FeedCursorState]
    }

    struct FeedCursorState: Sendable {
        let kind: FeedKind
        let cursor: String?
        let exhausted: Bool
    }

    struct FeedIssue: Sendable {
        let feed: FeedKind
        let kind: PhotoSourceIssueKind
        let retryAt: Date?
    }

    struct WireCursor: Codable {
        let page: Int
        let feeds: [WireFeedState]

        enum CodingKeys: String, CodingKey {
            case page = "p"
            case feeds = "f"
        }
    }

    struct WireFeedState: Codable {
        let kind: FeedKind
        let cursor: String?
        let exhausted: Bool

        enum CodingKeys: String, CodingKey {
            case kind = "k"
            case cursor = "c"
            case exhausted = "x"
        }
    }
}
