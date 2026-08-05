import Foundation

public enum GiphyEmojiError: Error, Equatable, Sendable {
    case invalidCredential
    case rateLimited(retryAt: Date?)
    case invalidResponse(statusCode: Int)
    case invalidCursor
    case invalidIdentifier
    case decoding(String)
    case network(String)
}

extension GiphyEmojiError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "GIPHY API Key 无效或未配置。"
        case .rateLimited:
            return "GIPHY 请求过于频繁，请稍后重试。"
        case let .invalidResponse(statusCode):
            return "GIPHY 返回异常状态：\(statusCode)"
        case .invalidCursor:
            return "GIPHY 分页位置无效。"
        case .invalidIdentifier:
            return "GIPHY 内容标识无效。"
        case let .decoding(message):
            return "GIPHY 数据解析失败：\(message)"
        case let .network(message):
            return "GIPHY 网络错误：\(message)"
        }
    }
}

extension GiphyEmojiError: PhotoSourceFailure {
    public var sourceID: PhotoSourceID { .giphy }

    public var issueKind: PhotoSourceIssueKind {
        switch self {
        case .invalidCredential:
            return .invalidCredential
        case .rateLimited:
            return .rateLimited
        case .invalidResponse, .invalidCursor, .invalidIdentifier:
            return .invalidResponse
        case .decoding:
            return .decoding
        case .network:
            return .network
        }
    }

    public var retryAt: Date? {
        guard case let .rateLimited(retryAt) = self else { return nil }
        return retryAt
    }
}

/// GIPHY 列表 endpoint 适配器；默认指向 Emoji，混合目录会复用它读取 Trending 与 Search。
public struct GiphyEmojiClient: PhotoSourceSearching, Sendable {
    public static let defaultEndpoint = URL(string: "https://api.giphy.com/v2/emoji")!
    public static let lookupEndpoint = URL(string: "https://api.giphy.com/v1/gifs")!
    public let sourceID = PhotoSourceID.giphy

    private static let maximumPageSize = 40
    private static let maximumOffset = Int(Int32.max)
    private static let pageHosts: Set<String> = ["giphy.com", "www.giphy.com"]
    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL
    private let rating: String?
    private let queryParameterName: String?
    private let now: @Sendable () -> Date

    /// Finder occurrence 会把公开对象 ID 放进稳定条目标识；只允许 GIPHY 官方 ID 字符集。
    private static func validatedIdentifier(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
              }) else {
            return nil
        }
        return value
    }

    /// 默认会话不使用 URLCache，避免把含 `api_key` 的请求 URL 持久化。
    public init(
        apiKey: String,
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            apiKey: apiKey,
            session: session,
            endpoint: Self.defaultEndpoint,
            rating: nil,
            now: now
        )
    }

    /// 仅供模块内部和测试替换传输端点；公开生产入口始终固定到 GIPHY 官方地址。
    init(
        apiKey: String,
        session: URLSession? = nil,
        endpoint: URL,
        rating: String? = nil,
        queryParameterName: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session ?? Self.makeEphemeralSession()
        self.endpoint = endpoint
        self.rating = rating
        self.queryParameterName = queryParameterName
        self.now = now
    }

    public func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw GiphyEmojiError.invalidCredential }

        let offset = try Self.offset(from: cursor)
        let safePageSize = min(max(pageSize, 1), Self.maximumPageSize)
        let request = try makeRequest(query: query, offset: offset, pageSize: safePageSize)

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw GiphyEmojiError.invalidResponse(statusCode: 0)
            }

            switch http.statusCode {
            case 200..<300:
                return try Self.decodePage(
                    data,
                    response: http,
                    now: now(),
                    requestedOffset: offset,
                    requestedPageSize: safePageSize
                )
            case 401, 403:
                throw GiphyEmojiError.invalidCredential
            case 429:
                throw GiphyEmojiError.rateLimited(
                    retryAt: Self.retryDate(
                        http.value(forHTTPHeaderField: "Retry-After"),
                        now: now()
                    )
                )
            default:
                throw GiphyEmojiError.invalidResponse(statusCode: http.statusCode)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GiphyEmojiError {
            throw error
        } catch let error as URLError {
            // 只有调用方真的取消 Swift Task 时才静默退出；系统单独中断 URLSession
            // 必须作为可见网络失败返回，否则搜索页会永久停在 loading。
            if Task.isCancelled { throw CancellationError() }
            // URLError 可能附带含 API Key 的失败 URL，只保留数值错误码。
            throw GiphyEmojiError.network("错误代码 \(error.code.rawValue)")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // 不转发底层错误或响应正文，防止完整请求 URL 或 Key 进入可见错误。
            throw GiphyEmojiError.network("请求失败")
        }
    }

    /// 收藏恢复使用官方 Get GIFs by ID，一次最多回查 50 个对象且不使用 URLCache。
    public func records(ids: [String]) async throws -> [RemoteImageRecord] {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw GiphyEmojiError.invalidCredential }

        var seen = Set<String>()
        let normalizedIDs = ids.compactMap { rawValue -> String? in
            guard let value = Self.validatedIdentifier(rawValue),
                  seen.insert(value).inserted else {
                return nil
            }
            return value
        }
        guard normalizedIDs.count == Set(ids.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }).count,
              (1...50).contains(normalizedIDs.count) else {
            throw GiphyEmojiError.invalidIdentifier
        }

        let request = try makeLookupRequest(ids: normalizedIDs)
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw GiphyEmojiError.invalidResponse(statusCode: 0)
            }
            switch http.statusCode {
            case 200..<300:
                return try Self.decodePage(
                    data,
                    response: http,
                    now: now(),
                    requestedOffset: 0,
                    requestedPageSize: normalizedIDs.count
                ).records
            case 401, 403:
                throw GiphyEmojiError.invalidCredential
            case 429:
                throw GiphyEmojiError.rateLimited(
                    retryAt: Self.retryDate(
                        http.value(forHTTPHeaderField: "Retry-After"),
                        now: now()
                    )
                )
            default:
                throw GiphyEmojiError.invalidResponse(statusCode: http.statusCode)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GiphyEmojiError {
            throw error
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            throw GiphyEmojiError.network("错误代码 \(error.code.rawValue)")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw GiphyEmojiError.network("请求失败")
        }
    }

    private func makeRequest(query: String, offset: Int, pageSize: Int) throws -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        if let rating {
            queryItems.append(URLQueryItem(name: "rating", value: rating))
        }
        if let queryParameterName {
            queryItems.append(URLQueryItem(
                name: queryParameterName,
                value: query.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw GiphyEmojiError.network("无法构造请求地址")
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func makeLookupRequest(ids: [String]) throws -> URLRequest {
        var components = URLComponents(url: Self.lookupEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "ids", value: ids.joined(separator: ","))
        ]
        guard let url = components?.url else {
            throw GiphyEmojiError.network("无法构造请求地址")
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    private static func decodePage(
        _ data: Data,
        response: HTTPURLResponse,
        now: Date,
        requestedOffset: Int,
        requestedPageSize: Int
    ) throws -> PhotoSourcePage {
        let decoder = JSONDecoder()
        let metadata: GiphyMetadataEnvelope
        do {
            metadata = try decoder.decode(GiphyMetadataEnvelope.self, from: data)
        } catch let error as DecodingError {
            throw GiphyEmojiError.decoding(decodingMessage(for: error))
        }

        switch metadata.meta.status {
        case 200:
            break
        case 401, 403:
            throw GiphyEmojiError.invalidCredential
        case 429:
            throw GiphyEmojiError.rateLimited(
                retryAt: retryDate(
                    response.value(forHTTPHeaderField: "Retry-After"),
                    now: now
                )
            )
        default:
            throw GiphyEmojiError.invalidResponse(statusCode: metadata.meta.status)
        }

        do {
            let payload = try decoder.decode(GiphyEmojiResponse.self, from: data)
            guard !payload.data.isEmpty || payload.meta.responseID?.trimmedGiphyField != nil else {
                // GIPHY 的真实空页仍有 response_id；拒绝中间层伪造的空成功响应。
                throw GiphyEmojiError.invalidResponse(statusCode: 200)
            }
            let decodedEmojis = payload.data.compactMap(\.value)
            guard payload.data.isEmpty || !decodedEmojis.isEmpty else {
                throw GiphyEmojiError.decoding("字段 data 中没有可识别的 GIPHY 对象")
            }

            var seenIDs = Set<String>()
            var records: [RemoteImageRecord] = []
            records.reserveCapacity(decodedEmojis.count)
            for emoji in decodedEmojis {
                guard let record = makeRecord(emoji), seenIDs.insert(record.id).inserted else {
                    continue
                }
                records.append(record)
            }

            return PhotoSourcePage(
                records: records,
                nextCursor: nextCursor(
                    from: payload.pagination ?? GiphyPagination(
                        totalCount: nil,
                        count: payload.data.count,
                        nextCursor: nil
                    ),
                    requestedOffset: requestedOffset,
                    requestedPageSize: requestedPageSize,
                    actualItemCount: payload.data.count
                )
            )
        } catch let error as GiphyEmojiError {
            throw error
        } catch let error as DecodingError {
            throw GiphyEmojiError.decoding(decodingMessage(for: error))
        }
    }

    /// 只返回 schema 路径和失败类型，不包含响应原值或请求 URL。
    private static func decodingMessage(for error: DecodingError) -> String {
        let path: ([any CodingKey]) -> String = { codingPath in
            let value = codingPath.map(\.stringValue).joined(separator: ".")
            return value.isEmpty ? "根节点" : value
        }
        switch error {
        case let .keyNotFound(key, context):
            return "缺少字段 \(path(context.codingPath + [key]))"
        case let .typeMismatch(_, context):
            return "字段 \(path(context.codingPath)) 类型不匹配"
        case let .valueNotFound(_, context):
            return "字段 \(path(context.codingPath)) 缺少值"
        case let .dataCorrupted(context):
            return context.codingPath.isEmpty
                ? "响应格式无效"
                : "字段 \(path(context.codingPath)) 内容无效"
        @unknown default:
            return "响应格式无效"
        }
    }

    private static func makeRecord(_ emoji: GiphyEmoji) -> RemoteImageRecord? {
        guard let contentType = GiphyContentType(rawValue: emoji.type.normalizedGiphyField),
              let gifID = emoji.id.trimmedGiphyField,
              let original = emoji.images.original,
              let imageURL = mediaURL(original.url),
              let thumbnailURL = mediaURL(emoji.images.fixedWidth?.url)
                ?? mediaURL(emoji.images.fixedHeight?.url) else {
            return nil
        }

        let userCreator = emoji.user?.displayName?.trimmedGiphyField
            ?? emoji.user?.username?.trimmedGiphyField
        let creator = userCreator ?? emoji.username?.trimmedGiphyField
        let title = emoji.altText?.trimmedGiphyField
            ?? emoji.title?.trimmedGiphyField
            ?? "GIPHY \(gifID)"

        return RemoteImageRecord(
            id: StableImageID.giphy(id: gifID),
            title: title,
            source: .giphy,
            giphyContentType: contentType,
            giphyID: gifID,
            imageURL: imageURL,
            thumbnailURL: thumbnailURL,
            sourcePageURL: pageURL(emoji.url),
            license: .giphy,
            creator: creator,
            creatorURL: pageURL(emoji.user?.profileURL),
            width: positiveInteger(original.width),
            height: positiveInteger(original.height),
            mimeType: mimeType(for: imageURL)
        )
    }

    private static func offset(from cursor: PhotoSourceCursor?) throws -> Int {
        guard let cursor else { return 0 }
        guard let offset = Int(cursor.rawValue),
              offset >= 0,
              offset <= maximumOffset,
              String(offset) == cursor.rawValue else {
            throw GiphyEmojiError.invalidCursor
        }
        return offset
    }

    /// v2 优先采用 next_cursor；旧响应才按请求 offset 与实际 count 安全推进。
    private static func nextCursor(
        from pagination: GiphyPagination,
        requestedOffset: Int,
        requestedPageSize: Int,
        actualItemCount: Int
    ) -> PhotoSourceCursor? {
        guard actualItemCount > 0 else { return nil }

        // v2 Emoji 的 offset 字段并不是稳定的“当前页起点”；next_cursor 才是下一请求位置。
        if let explicitCursor = pagination.nextCursor {
            guard explicitCursor > requestedOffset,
                  explicitCursor <= maximumOffset else {
                return nil
            }
            // v2 的 next_cursor 是权威续页位置；total_count 可能缺失或与 cursor 语义不同。
            return PhotoSourceCursor(rawValue: String(explicitCursor))
        }

        // 兼容没有 next_cursor 的旧式响应：只按请求位置和返回数量前进。
        let responseCount = pagination.count ?? actualItemCount
        guard responseCount > 0 else { return nil }
        let (nextOffset, overflow) = requestedOffset.addingReportingOverflow(responseCount)
        guard !overflow,
              nextOffset > requestedOffset,
              nextOffset <= maximumOffset else {
            return nil
        }
        if let totalCount = pagination.totalCount {
            guard totalCount > 0, nextOffset < totalCount else { return nil }
        } else {
            guard actualItemCount >= requestedPageSize else { return nil }
        }
        return PhotoSourceCursor(rawValue: String(nextOffset))
    }

    private static func positiveInteger(_ rawValue: String?) -> Int? {
        guard let rawValue,
              let value = Int(rawValue),
              value > 0 else {
            return nil
        }
        return value
    }

    private static func pageURL(_ rawValue: String?) -> URL? {
        secureURL(rawValue) { pageHosts.contains($0) }
    }

    private static func mediaURL(_ rawValue: String?) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawValue),
              isAllowedMediaURL(url) else { return nil }
        return url
    }

    /// 应用端直接请求动图时复用同一 CDN 边界，包括重定向的最终 URL。
    public static func isAllowedMediaURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              !url.path.isEmpty else {
            return false
        }
        if host == "media.giphy.com" { return true }
        guard host.hasPrefix("media"), host.hasSuffix(".giphy.com") else { return false }
        let digitsStart = host.index(host.startIndex, offsetBy: "media".count)
        let digitsEnd = host.index(host.endIndex, offsetBy: -".giphy.com".count)
        let digits = host[digitsStart..<digitsEnd]
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// 直接返回校验后的 URL，不重建 query，以保留 GIPHY CDN 的 rendition 参数。
    private static func secureURL(
        _ rawValue: String?,
        allowedHost: (String) -> Bool
    ) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              allowedHost(host),
              !url.path.isEmpty else {
            return nil
        }
        return url
    }

    private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return nil
        }
    }

    /// Retry-After 优先按秒数处理，同时兼容标准 HTTP-date。
    private static func retryDate(_ rawValue: String?, now: Date) -> Date {
        let fallback = now.addingTimeInterval(
            PhotoSourceRequestPolicies.policy(for: .giphy).rateLimitFallback
        )
        guard let rawValue else { return fallback }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            let retryAt = now.addingTimeInterval(seconds)
            return retryAt.timeIntervalSinceReferenceDate.isFinite ? retryAt : fallback
        }

        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
            "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
            "EEE MMM d HH':'mm':'ss yyyy"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let retryAt = formatter.date(from: value) { return retryAt }
        }
        return fallback
    }
}

private struct GiphyMetadataEnvelope: Decodable {
    let meta: GiphyMeta
}

private struct GiphyEmojiResponse: Decodable {
    let data: [LossyDecodable<GiphyEmoji>]
    let pagination: GiphyPagination?
    let meta: GiphyMeta
}

private struct GiphyMeta: Decodable {
    let status: Int
    let responseID: String?

    enum CodingKeys: String, CodingKey {
        case status
        case responseID = "response_id"
    }
}

private struct GiphyPagination: Decodable {
    let totalCount: Int?
    let count: Int?
    let nextCursor: Int?

    enum CodingKeys: String, CodingKey {
        case count
        case totalCount = "total_count"
        case nextCursor = "next_cursor"
    }
}

/// 单个上游条目缺字段时跳过该条，不让整页其他可用 GIPHY 内容一起失败。
private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct GiphyEmoji: Decodable {
    let type: String
    let id: String
    let url: String?
    let username: String?
    let title: String?
    let altText: String?
    let images: GiphyImages
    let user: GiphyUser?

    enum CodingKeys: String, CodingKey {
        case type, id, url, username, title, images, user
        case altText = "alt_text"
    }
}

private struct GiphyImages: Decodable {
    let fixedWidth: GiphyRendition?
    let fixedHeight: GiphyRendition?
    let original: GiphyRendition?

    enum CodingKeys: String, CodingKey {
        case fixedWidth = "fixed_width"
        case fixedHeight = "fixed_height"
        case original
    }
}

private struct GiphyRendition: Decodable {
    let url: String?
    let width: String?
    let height: String?
}

private struct GiphyUser: Decodable {
    let username: String?
    let displayName: String?
    let profileURL: String?

    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
        case profileURL = "profile_url"
    }
}

private extension String {
    var trimmedGiphyField: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var normalizedGiphyField: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
