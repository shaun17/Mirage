import Foundation

public protocol OpenverseSearching: Sendable {
    /// 搜索符合安全与授权要求的 Openverse 图片。
    func search(query: String, pageSize: Int) async throws -> [RemoteImageRecord]
}

public enum OpenverseError: Error, Equatable, Sendable {
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    case invalidResponse(statusCode: Int)
    case decoding(String)
}

extension OpenverseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .rateLimited(retryAfter):
            return retryAfter.map { "Openverse 请求过于频繁，请在 \(Int($0)) 秒后重试" } ?? "Openverse 请求过于频繁"
        case let .network(message): return "Openverse 网络错误：\(message)"
        case let .invalidResponse(statusCode): return "Openverse 返回异常状态：\(statusCode)"
        case let .decoding(message): return "Openverse 数据解析失败：\(message)"
        }
    }
}

/// 无需账号的 Openverse 图片搜索客户端。
public struct OpenverseClient: OpenverseSearching, Sendable {
    public static let defaultEndpoint = URL(string: "https://api.openverse.org/v1/images")!

    private let session: URLSession
    private let endpoint: URL

    public init(session: URLSession = .shared, endpoint: URL = defaultEndpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    /// 请求时始终声明成熟内容关闭，并把授权范围收窄为 CC0 与 PDM。
    public func search(query: String, pageSize: Int = 20) async throws -> [RemoteImageRecord] {
        try Task.checkCancellation()
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "mature", value: "false"),
            URLQueryItem(name: "license", value: "cc0,pdm"),
            URLQueryItem(name: "page_size", value: String(min(max(pageSize, 1), 50)))
        ]
        guard let url = components?.url else { throw OpenverseError.network("无法构造请求地址") }

        do {
            let (data, response) = try await session.data(from: url)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw OpenverseError.invalidResponse(statusCode: 0)
            }
            if http.statusCode == 429 {
                throw OpenverseError.rateLimited(retryAfter: Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
            }
            guard (200..<300).contains(http.statusCode) else {
                throw OpenverseError.invalidResponse(statusCode: http.statusCode)
            }
            do {
                let payload = try JSONDecoder().decode(SearchResponse.self, from: data)
                return payload.results.compactMap(Self.makeRecord)
            } catch let error as DecodingError {
                throw OpenverseError.decoding(String(describing: error))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenverseError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw OpenverseError.network(error.localizedDescription)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw OpenverseError.network(error.localizedDescription)
        }
    }

    /// 只接纳 UUID、非成熟、HTTPS 且授权确实为 CC0/PDM 的记录。
    private static func makeRecord(_ value: SearchResult) -> RemoteImageRecord? {
        guard let uuid = UUID(uuidString: value.id), value.mature == false,
              let imageURL = secureURL(value.url), let thumbnailURL = secureURL(value.thumbnail) else { return nil }
        let licenseID = value.license.lowercased()
        guard licenseID == "cc0" || licenseID == "pdm" else { return nil }
        let license = LicenseInfo(
            identifier: licenseID,
            displayName: licenseID == "cc0" ? "CC0 1.0" : "Public Domain Mark",
            url: secureURL(value.licenseURL)
        )
        return RemoteImageRecord(
            id: StableImageID.openverse(uuid: uuid),
            title: value.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled",
            source: .openverse,
            imageURL: imageURL,
            thumbnailURL: thumbnailURL,
            sourcePageURL: secureURL(value.foreignLandingURL),
            license: license,
            creator: value.creator?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            creatorURL: secureURL(value.creatorURL),
            width: value.width.flatMap { $0 > 0 ? $0 : nil },
            height: value.height.flatMap { $0 > 0 ? $0 : nil },
            mimeType: mimeType(filetype: value.filetype)
        )
    }

    /// 所有可点击或下载的远程地址都必须使用 HTTPS。
    private static func secureURL(_ rawValue: String?) -> URL? {
        guard let rawValue, let url = URL(string: rawValue), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// 将 Openverse 的文件扩展名转换为常见 MIME 类型。
    private static func mimeType(filetype: String?) -> String? {
        switch filetype?.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    /// Retry-After 的秒数形式最稳定；无法解析时交给上层采用默认退避。
    private static func retryDelay(_ value: String?) -> TimeInterval? {
        guard let value, let seconds = TimeInterval(value), seconds >= 0 else { return nil }
        return seconds
    }
}

private struct SearchResponse: Decodable {
    let results: [SearchResult]
}

private struct SearchResult: Decodable {
    let id: String
    let title: String?
    let creator: String?
    let creatorURL: String?
    let url: String?
    let thumbnail: String?
    let foreignLandingURL: String?
    let license: String
    let licenseURL: String?
    let mature: Bool?
    let width: Int?
    let height: Int?
    let filetype: String?

    enum CodingKeys: String, CodingKey {
        case id, title, creator, url, thumbnail, license, mature, width, height, filetype
        case creatorURL = "creator_url"
        case foreignLandingURL = "foreign_landing_url"
        case licenseURL = "license_url"
    }
}

private extension String {
    /// 把清理后的空字符串折叠为 nil。
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
