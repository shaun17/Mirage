import Foundation

public enum PexelsError: Error, Equatable, Sendable {
    case invalidCredential
    case rateLimited(resetAt: Date?)
    case invalidResponse(statusCode: Int)
    case invalidCursor
    case decoding(String)
    case network(String)
}

extension PexelsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCredential: return "Pexels API Key 无效或未配置。"
        case .rateLimited: return "Pexels 请求额度已用尽，请稍后重试。"
        case let .invalidResponse(statusCode): return "Pexels 返回异常状态：\(statusCode)"
        case .invalidCursor: return "Pexels 分页位置无效。"
        case let .decoding(message): return "Pexels 数据解析失败：\(message)"
        case let .network(message): return "Pexels 网络错误：\(message)"
        }
    }
}

extension PexelsError: PhotoSourceFailure {
    public var sourceID: PhotoSourceID { .pexels }

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

/// 使用用户自有 API Key 的 Pexels 照片适配器；Key 只进入 Authorization 请求头。
public struct PexelsClient: PhotoSourceSearching, Sendable {
    public static let defaultEndpoint = URL(string: "https://api.pexels.com/v1/search")!
    public let sourceID = PhotoSourceID.pexels

    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: URL = defaultEndpoint
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
        self.endpoint = endpoint
    }

    public func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        guard !apiKey.isEmpty else { throw PexelsError.invalidCredential }
        let page = try Self.page(from: cursor)
        let safePageSize = min(max(pageSize, 1), 80)
        let request = try makeRequest(query: query, page: page, pageSize: safePageSize)
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw PexelsError.invalidResponse(statusCode: 0)
            }
            switch http.statusCode {
            case 200..<300:
                return try Self.decodePage(
                    data,
                    requestedPage: page,
                    quota: Self.quotaSnapshot(http)
                )
            case 401, 403:
                throw PexelsError.invalidCredential
            case 429:
                throw PexelsError.rateLimited(resetAt: Self.rateLimitReset(http))
            default:
                throw PexelsError.invalidResponse(statusCode: http.statusCode)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PexelsError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw PexelsError.network(error.localizedDescription)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PexelsError.network(error.localizedDescription)
        }
    }

    private func makeRequest(query: String, page: Int, pageSize: Int) throws -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(pageSize))
        ]
        guard let url = components?.url else { throw PexelsError.network("无法构造请求地址") }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func decodePage(
        _ data: Data,
        requestedPage: Int,
        quota: PhotoSourceQuotaSnapshot?
    ) throws -> PhotoSourcePage {
        do {
            let payload = try JSONDecoder().decode(PexelsSearchResponse.self, from: data)
            let currentPage = max(payload.page, requestedPage)
            let next = payload.nextPage.flatMap { _ -> PhotoSourceCursor? in
                guard currentPage < SearchPaginationCursor.maximumPage else { return nil }
                return PhotoSourceCursor(rawValue: String(currentPage + 1))
            }
            return PhotoSourcePage(
                records: payload.photos.compactMap(makeRecord),
                nextCursor: next,
                quota: quota
            )
        } catch let error as DecodingError {
            throw PexelsError.decoding(String(describing: error))
        }
    }

    private static func makeRecord(_ photo: PexelsPhoto) -> RemoteImageRecord? {
        guard photo.id > 0,
              let imageURL = pexelsImageURL(photo.src.large2x ?? photo.src.large ?? photo.src.medium),
              let thumbnailURL = pexelsImageURL(photo.src.medium ?? photo.src.small),
              let sourcePageURL = pexelsPageURL(photo.url) else { return nil }
        let creator = photo.photographer.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = photo.alt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Pexels Photo \(photo.id)"
        return RemoteImageRecord(
            id: StableImageID.pexels(id: photo.id),
            title: title,
            source: .pexels,
            imageURL: imageURL,
            thumbnailURL: thumbnailURL,
            sourcePageURL: sourcePageURL,
            license: .pexels,
            creator: creator.nilIfEmpty,
            creatorURL: pexelsPageURL(photo.photographerURL),
            width: photo.width > 0 ? photo.width : nil,
            height: photo.height > 0 ? photo.height : nil,
            mimeType: mimeType(for: imageURL)
        )
    }

    private static func page(from cursor: PhotoSourceCursor?) throws -> Int {
        guard let cursor else { return 1 }
        guard let page = Int(cursor.rawValue), String(page) == cursor.rawValue,
              (1...SearchPaginationCursor.maximumPage).contains(page) else {
            throw PexelsError.invalidCursor
        }
        return page
    }

    private static func pexelsImageURL(_ rawValue: String?) -> URL? {
        secureURL(rawValue, allowedHosts: ["images.pexels.com"])
    }

    private static func pexelsPageURL(_ rawValue: String?) -> URL? {
        secureURL(rawValue, allowedHosts: ["pexels.com", "www.pexels.com"])
    }

    private static func secureURL(_ rawValue: String?, allowedHosts: Set<String>) -> URL? {
        guard let rawValue, let url = URL(string: rawValue), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), allowedHosts.contains(host) else { return nil }
        return url
    }

    private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    private static func rateLimitReset(_ response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "X-Ratelimit-Reset"),
              let timestamp = TimeInterval(value), timestamp.isFinite else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    /// Pexels 只承诺成功响应携带额度头；缺失或非法字段保持 nil，不猜测剩余额度。
    private static func quotaSnapshot(_ response: HTTPURLResponse) -> PhotoSourceQuotaSnapshot? {
        let limit = response.value(forHTTPHeaderField: "X-Ratelimit-Limit").flatMap(Int.init)
        let remaining = response.value(forHTTPHeaderField: "X-Ratelimit-Remaining").flatMap(Int.init)
        let resetAt = rateLimitReset(response)
        guard limit != nil || remaining != nil || resetAt != nil else { return nil }
        return PhotoSourceQuotaSnapshot(
            limit: limit.flatMap { $0 > 0 ? $0 : nil },
            remaining: remaining.flatMap { $0 >= 0 ? $0 : nil },
            resetAt: resetAt
        )
    }
}

private struct PexelsSearchResponse: Decodable {
    let page: Int
    let photos: [PexelsPhoto]
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case page, photos
        case nextPage = "next_page"
    }
}

private struct PexelsPhoto: Decodable {
    let id: Int
    let width: Int
    let height: Int
    let url: String
    let photographer: String
    let photographerURL: String?
    let src: PexelsPhotoSources
    let alt: String?

    enum CodingKeys: String, CodingKey {
        case id, width, height, url, photographer, src, alt
        case photographerURL = "photographer_url"
    }
}

private struct PexelsPhotoSources: Decodable {
    let large2x: String?
    let large: String?
    let medium: String?
    let small: String?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
