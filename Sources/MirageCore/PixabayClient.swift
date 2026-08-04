import Foundation

public enum PixabayError: Error, Equatable, Sendable {
    case invalidCredential
    case rateLimited(resetAt: Date?)
    case invalidResponse(statusCode: Int)
    case invalidCursor
    case decoding(String)
    case network(String)
}

extension PixabayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCredential: return "Pixabay API Key 无效或未配置。"
        case .rateLimited: return "Pixabay 请求额度已用尽，请稍后重试。"
        case let .invalidResponse(statusCode): return "Pixabay 返回异常状态：\(statusCode)"
        case .invalidCursor: return "Pixabay 分页位置无效。"
        case let .decoding(message): return "Pixabay 数据解析失败：\(message)"
        case let .network(message): return "Pixabay 网络错误：\(message)"
        }
    }
}

extension PixabayError: PhotoSourceFailure {
    public var sourceID: PhotoSourceID { .pixabay }

    public var issueKind: PhotoSourceIssueKind {
        switch self {
        case .invalidCredential: return .invalidCredential
        case .rateLimited: return .rateLimited
        case .invalidResponse, .invalidCursor: return .invalidResponse
        case .decoding: return .decoding
        case .network: return .network
        }
    }

    public var retryAt: Date? {
        guard case let .rateLimited(resetAt) = self else { return nil }
        return resetAt
    }
}

/// 使用用户自有 API Key 的 Pixabay 照片适配器；Key 按上游合同进入查询参数。
public struct PixabayClient: PhotoSourceSearching, Sendable {
    public static let defaultEndpoint = URL(string: "https://pixabay.com/api/")!
    public let sourceID = PhotoSourceID.pixabay

    private static let allowedHosts: Set<String> = [
        "pixabay.com",
        "www.pixabay.com",
        "cdn.pixabay.com"
    ]

    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL
    private let now: @Sendable () -> Date

    /// 未注入 session 时使用不带 URLCache 的 ephemeral 会话，避免把含 Key 的请求 URL 落盘。
    public init(
        apiKey: String,
        session: URLSession? = nil,
        endpoint: URL = defaultEndpoint,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session ?? Self.makeEphemeralSession()
        self.endpoint = endpoint
        self.now = now
    }

    public func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        guard !apiKey.isEmpty else { throw PixabayError.invalidCredential }
        let page = try Self.page(from: cursor)
        let safePageSize = min(max(pageSize, 3), 200)
        let request = try makeRequest(query: query, page: page, pageSize: safePageSize)

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw PixabayError.invalidResponse(statusCode: 0)
            }

            switch http.statusCode {
            case 200..<300:
                let responseDate = now()
                return try Self.decodePage(
                    data,
                    requestedPage: page,
                    requestedPageSize: safePageSize,
                    quota: Self.quotaSnapshot(http, now: responseDate)
                )
            case 400, 401, 403:
                throw PixabayError.invalidCredential
            case 429:
                throw PixabayError.rateLimited(resetAt: Self.rateLimitReset(http, now: now()))
            default:
                throw PixabayError.invalidResponse(statusCode: http.statusCode)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PixabayError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            // URLError 的 userInfo 可能包含带 Key 的失败 URL，因此只保留数值错误码。
            throw PixabayError.network("错误代码 \(error.code.rawValue)")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // 不转发任意底层错误文本，避免其中携带完整请求 URL 或 API Key。
            throw PixabayError.network("请求失败")
        }
    }

    private func makeRequest(query: String, page: Int, pageSize: Int) throws -> URLRequest {
        let effectiveQuery = String(query.prefix(100))
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "q", value: effectiveQuery),
            URLQueryItem(name: "lang", value: Self.searchLanguage(for: effectiveQuery)),
            URLQueryItem(name: "image_type", value: "photo"),
            URLQueryItem(name: "safesearch", value: "true"),
            URLQueryItem(name: "order", value: "popular"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(pageSize))
        ]
        guard let url = components?.url else {
            throw PixabayError.network("无法构造请求地址")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Pixabay 的查询语言属于请求合同；含汉字的输入使用中文语料，其余保持官方默认英语语义。
    private static func searchLanguage(for query: String) -> String {
        query.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2A6DF, 0x2A700...0x2EBEF:
                return true
            default:
                return false
            }
        } ? "zh" : "en"
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private static func decodePage(
        _ data: Data,
        requestedPage: Int,
        requestedPageSize: Int,
        quota: PhotoSourceQuotaSnapshot?
    ) throws -> PhotoSourcePage {
        do {
            let payload = try JSONDecoder().decode(PixabaySearchResponse.self, from: data)
            let deliveredThrough = requestedPage * requestedPageSize
            let nextCursor: PhotoSourceCursor?
            if !payload.hits.isEmpty,
               deliveredThrough < max(payload.totalHits, 0),
               requestedPage < SearchPaginationCursor.maximumPage {
                nextCursor = PhotoSourceCursor(rawValue: String(requestedPage + 1))
            } else {
                nextCursor = nil
            }
            return PhotoSourcePage(
                records: payload.hits.compactMap(makeRecord),
                nextCursor: nextCursor,
                quota: quota
            )
        } catch is DecodingError {
            // 服务端解析细节不进入错误文本，避免意外回显响应中的敏感字符串或 URL。
            throw PixabayError.decoding("响应格式无效")
        }
    }

    private static func makeRecord(_ photo: PixabayPhoto) -> RemoteImageRecord? {
        guard photo.id > 0, let selectedImage = selectImage(from: photo) else { return nil }
        let thumbnailURL = pixabayURL(photo.webformatURL)
            ?? pixabayURL(photo.previewURL)
            ?? selectedImage.url
        let creator = photo.user?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let title = photo.tags?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Pixabay Photo \(photo.id)"

        return RemoteImageRecord(
            id: StableImageID.pixabay(id: photo.id),
            title: title,
            source: .pixabay,
            imageURL: selectedImage.url,
            thumbnailURL: thumbnailURL,
            sourcePageURL: pixabayURL(photo.pageURL),
            license: .pixabay,
            creator: creator,
            creatorURL: creator.flatMap { creatorProfileURL(username: $0, userID: photo.userID) },
            width: selectedImage.width,
            height: selectedImage.height,
            mimeType: mimeType(for: selectedImage.url)
        )
    }

    private static func selectImage(from photo: PixabayPhoto) -> PixabaySelectedImage? {
        if let url = pixabayURL(photo.imageURL) {
            let dimensions = validatedDimensions(width: photo.imageWidth, height: photo.imageHeight)
            return PixabaySelectedImage(url: url, width: dimensions?.width, height: dimensions?.height)
        }
        if let url = pixabayURL(photo.fullHDURL) {
            let dimensions = scaledDimensions(
                width: photo.imageWidth,
                height: photo.imageHeight,
                maximumDimension: 1_920
            )
            return PixabaySelectedImage(url: url, width: dimensions?.width, height: dimensions?.height)
        }
        if let url = pixabayURL(photo.largeImageURL) {
            let dimensions = scaledDimensions(
                width: photo.imageWidth,
                height: photo.imageHeight,
                maximumDimension: 1_280
            )
            return PixabaySelectedImage(url: url, width: dimensions?.width, height: dimensions?.height)
        }
        if let url = pixabayURL(photo.webformatURL) {
            let dimensions = validatedDimensions(width: photo.webformatWidth, height: photo.webformatHeight)
            return PixabaySelectedImage(url: url, width: dimensions?.width, height: dimensions?.height)
        }
        return nil
    }

    private static func validatedDimensions(width: Int?, height: Int?) -> (width: Int, height: Int)? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// fullHD/large 只声明最大边能力，需由原图比例推导实际返回尺寸。
    private static func scaledDimensions(
        width: Int?,
        height: Int?,
        maximumDimension: Int
    ) -> (width: Int, height: Int)? {
        guard let dimensions = validatedDimensions(width: width, height: height) else { return nil }
        let largestDimension = max(dimensions.width, dimensions.height)
        guard largestDimension > maximumDimension else { return dimensions }
        let scale = Double(maximumDimension) / Double(largestDimension)
        let scaledWidth = max(1, Int((Double(dimensions.width) * scale).rounded()))
        let scaledHeight = max(1, Int((Double(dimensions.height) * scale).rounded()))
        return (min(scaledWidth, maximumDimension), min(scaledHeight, maximumDimension))
    }

    private static func page(from cursor: PhotoSourceCursor?) throws -> Int {
        guard let cursor else { return 1 }
        guard let page = Int(cursor.rawValue), String(page) == cursor.rawValue,
              (1...SearchPaginationCursor.maximumPage).contains(page) else {
            throw PixabayError.invalidCursor
        }
        return page
    }

    private static func pixabayURL(_ rawValue: String?) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              allowedHosts.contains(host) else {
            return nil
        }
        return url
    }

    private static func creatorProfileURL(username: String, userID: Int?) -> URL? {
        guard let userID, userID > 0 else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "pixabay.com"
        components.path = "/users/\(username)-\(userID)/"
        return components.url.flatMap { pixabayURL($0.absoluteString) }
    }

    private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    /// Pixabay 的 reset 头是距离当前窗口重置的秒数，不是 Unix timestamp。
    private static func rateLimitReset(_ response: HTTPURLResponse, now: Date) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
              let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite,
              seconds >= 0 else {
            return nil
        }
        let resetAt = now.addingTimeInterval(seconds)
        return resetAt.timeIntervalSinceReferenceDate.isFinite ? resetAt : nil
    }

    private static func quotaSnapshot(
        _ response: HTTPURLResponse,
        now: Date
    ) -> PhotoSourceQuotaSnapshot? {
        let limit = response.value(forHTTPHeaderField: "X-RateLimit-Limit")
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            .flatMap(Int.init)
            .flatMap { $0 >= 0 ? $0 : nil }
        let resetAt = rateLimitReset(response, now: now)
        guard limit != nil || remaining != nil || resetAt != nil else { return nil }
        return PhotoSourceQuotaSnapshot(limit: limit, remaining: remaining, resetAt: resetAt)
    }
}

private struct PixabaySearchResponse: Decodable {
    let totalHits: Int
    let hits: [PixabayPhoto]
}

private struct PixabayPhoto: Decodable {
    let id: Int
    let pageURL: String?
    let tags: String?
    let previewURL: String?
    let webformatURL: String?
    let largeImageURL: String?
    let fullHDURL: String?
    let imageURL: String?
    let previewWidth: Int?
    let previewHeight: Int?
    let webformatWidth: Int?
    let webformatHeight: Int?
    let imageWidth: Int?
    let imageHeight: Int?
    let userID: Int?
    let user: String?

    enum CodingKeys: String, CodingKey {
        case id, pageURL, tags, previewURL, webformatURL, largeImageURL, fullHDURL, imageURL
        case previewWidth, previewHeight, webformatWidth, webformatHeight, imageWidth, imageHeight, user
        case userID = "user_id"
    }
}

private struct PixabaySelectedImage {
    let url: URL
    let width: Int?
    let height: Int?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
