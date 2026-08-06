import Foundation

public enum NASAImagesError: Error, Equatable, Sendable {
    case rateLimited(retryAt: Date?)
    case invalidResponse(statusCode: Int)
    case invalidCursor
    case decoding(String)
    case network(String)
}

extension NASAImagesError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "NASA 图片库请求过于频繁，请稍后重试。"
        case let .invalidResponse(statusCode):
            return "NASA 图片库返回异常状态：\(statusCode)"
        case .invalidCursor:
            return "NASA 图片库分页位置无效。"
        case let .decoding(message):
            return "NASA 图片库数据解析失败：\(message)"
        case let .network(message):
            return "NASA 图片库网络错误：\(message)"
        }
    }
}

extension NASAImagesError: PhotoSourceFailure {
    public var sourceID: PhotoSourceID { .nasa }

    public var issueKind: PhotoSourceIssueKind {
        switch self {
        case .rateLimited: return .rateLimited
        case .invalidResponse, .invalidCursor: return .invalidResponse
        case .decoding: return .decoding
        case .network: return .network
        }
    }

    public var retryAt: Date? {
        guard case let .rateLimited(retryAt) = self else { return nil }
        return retryAt
    }
}

/// NASA Image and Video Library 的图片搜索适配器。
///
/// 搜索响应提供的官方 HTTPS preview 同时用于 App 预览与 Finder 图片物化；详情页仍保留
/// `nasa_id` 对应入口，避免把当前交付尺寸描述成 NASA 原始母版。
public struct NASAImagesClient: PhotoSourceSearching, Sendable {
    public static let defaultEndpoint = URL(string: "https://images-api.nasa.gov/search")!
    public let sourceID = PhotoSourceID.nasa

    private static let maximumPageSize = 100
    private static let allowedAssetHosts: Set<String> = [
        "images-api.nasa.gov",
        "images-assets.nasa.gov"
    ]

    private let session: URLSession
    private let endpoint: URL
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        endpoint: URL = defaultEndpoint,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.endpoint = endpoint
        self.now = now
    }

    public func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        try Task.checkCancellation()
        let page = try Self.page(from: cursor)
        let safePageSize = min(max(pageSize, 1), Self.maximumPageSize)
        let request = try makeRequest(query: query, page: page, pageSize: safePageSize)

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw NASAImagesError.invalidResponse(statusCode: 0)
            }

            switch http.statusCode {
            case 200..<300:
                return try Self.decodePage(data, requestedPage: page)
            case 429:
                throw NASAImagesError.rateLimited(
                    retryAt: Self.retryDate(http.value(forHTTPHeaderField: "Retry-After"), now: now())
                )
            default:
                throw NASAImagesError.invalidResponse(statusCode: http.statusCode)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NASAImagesError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            // URLError 可能携带含用户查询词的完整 URL，因此错误只保留数值代码。
            throw NASAImagesError.network("错误代码 \(error.code.rawValue)")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw NASAImagesError.network("请求失败")
        }
    }

    private func makeRequest(query: String, page: Int, pageSize: Int) throws -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "media_type", value: "image"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize))
        ]
        guard let url = components?.url else {
            throw NASAImagesError.network("无法构造请求地址")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func decodePage(_ data: Data, requestedPage: Int) throws -> PhotoSourcePage {
        do {
            let payload = try JSONDecoder().decode(NASASearchResponse.self, from: data)
            var seenIDs = Set<String>()
            var records: [RemoteImageRecord] = []
            for case let item? in payload.collection.items ?? [] {
                guard let record = makeRecord(item), seenIDs.insert(record.id).inserted else {
                    continue
                }
                records.append(record)
            }

            let hasNext = (payload.collection.links ?? [])
                .contains { $0?.rel?.normalizedField == "next" }
            let nextCursor = hasNext && requestedPage < SearchPaginationCursor.maximumPage
                ? PhotoSourceCursor(rawValue: String(requestedPage + 1))
                : nil

            return PhotoSourcePage(records: records, nextCursor: nextCursor)
        } catch is DecodingError {
            throw NASAImagesError.decoding("响应格式无效")
        }
    }

    private static func makeRecord(_ item: NASAItem) -> RemoteImageRecord? {
        var selectedPreview: (link: NASALink, url: URL)?
        for case let link? in item.links ?? [] {
            let render = link.render?.normalizedField
            guard link.rel?.normalizedField == "preview",
                  render == nil || render == "image",
                  let url = officialAssetURL(link.href) else {
                continue
            }
            selectedPreview = (link, url)
            break
        }
        guard let selectedPreview else { return nil }
        let preview = selectedPreview.link
        let previewURL = selectedPreview.url

        for case let metadata? in item.data ?? [] {
            guard metadata.mediaType?.normalizedField == "image",
                  let nasaID = metadata.nasaID?.trimmedNonEmpty else {
                continue
            }

            let creator = [metadata.photographer, metadata.secondaryCreator, metadata.center]
                .compactMap { $0?.trimmedNonEmpty }
                .first
            return RemoteImageRecord(
                id: StableImageID.nasa(nasaID: nasaID),
                title: metadata.title?.trimmedNonEmpty ?? nasaID,
                source: .nasa,
                imageURL: previewURL,
                thumbnailURL: previewURL,
                sourcePageURL: detailsURL(nasaID: nasaID),
                license: .nasaMediaUsage,
                creator: creator,
                width: preview.width.flatMap { $0 > 0 ? $0 : nil },
                height: preview.height.flatMap { $0 > 0 ? $0 : nil },
                mimeType: mimeType(for: previewURL)
            )
        }
        return nil
    }

    private static func page(from cursor: PhotoSourceCursor?) throws -> Int {
        guard let cursor else { return 1 }
        guard let page = Int(cursor.rawValue),
              String(page) == cursor.rawValue,
              (1...SearchPaginationCursor.maximumPage).contains(page) else {
            throw NASAImagesError.invalidCursor
        }
        return page
    }

    /// 搜索响应偶尔返回 http；只允许两个 NASA 官方域升级为 HTTPS，不接纳任意第三方地址。
    private static func officialAssetURL(_ rawValue: String?) -> URL? {
        guard let rawValue = rawValue?.trimmedNonEmpty,
              var components = URLComponents(string: rawValue),
              components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              allowedAssetHosts.contains(host),
              !components.path.isEmpty else {
            return nil
        }

        switch scheme {
        case "http":
            guard components.port == nil || components.port == 80 else { return nil }
        case "https":
            guard components.port == nil || components.port == 443 else { return nil }
        default:
            return nil
        }

        components.scheme = "https"
        components.port = nil
        guard let url = components.url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host else {
            return nil
        }
        return url
    }

    private static func detailsURL(nasaID: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encodedID = nasaID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "images.nasa.gov"
        components.percentEncodedPath = "/details/\(encodedID)"
        return components.url
    }

    private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "tif", "tiff": return "image/tiff"
        default: return nil
        }
    }

    /// Retry-After 的秒数形式按响应到达时刻转换；缺失或非法值保留 nil。
    private static func retryDate(_ rawValue: String?, now: Date) -> Date? {
        guard let rawValue,
              let seconds = TimeInterval(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite,
              seconds >= 0 else {
            return nil
        }
        let retryAt = now.addingTimeInterval(seconds)
        return retryAt.timeIntervalSinceReferenceDate.isFinite ? retryAt : nil
    }
}

private struct NASASearchResponse: Decodable {
    let collection: NASACollection
}

private struct NASACollection: Decodable {
    let items: [NASAItem?]?
    let links: [NASALink?]?
}

private struct NASAItem: Decodable {
    let data: [NASAMetadata?]?
    let links: [NASALink?]?
}

private struct NASAMetadata: Decodable {
    let nasaID: String?
    let mediaType: String?
    let title: String?
    let photographer: String?
    let secondaryCreator: String?
    let center: String?

    enum CodingKeys: String, CodingKey {
        case title, photographer, center
        case nasaID = "nasa_id"
        case mediaType = "media_type"
        case secondaryCreator = "secondary_creator"
    }
}

private struct NASALink: Decodable {
    let href: String?
    let rel: String?
    let render: String?
    let width: Int?
    let height: Int?
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var normalizedField: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
