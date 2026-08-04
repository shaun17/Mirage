import Foundation
import XCTest
@testable import MirageCore

final class PexelsClientTests: XCTestCase {
    override func tearDown() {
        PexelsURLProtocol.handler = nil
        super.tearDown()
    }

    /// Authorization 必须直接使用用户 Key，不添加 Bearer；查询和 provider 游标按 Pexels 合同编码。
    func testRequestUsesRawAuthorizationAndPaginationParameters() async throws {
        PexelsURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "pexels-raw-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let items = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
            XCTAssertEqual(items["query"], "red panda")
            XCTAssertEqual(items["page"], "3")
            XCTAssertEqual(items["per_page"], "27")
            return (Self.response(for: request, status: 200), Self.fixture)
        }

        let page = try await makeClient(apiKey: "pexels-raw-key").search(
            query: "red panda",
            cursor: PhotoSourceCursor(rawValue: "3"),
            pageSize: 27
        )
        XCTAssertEqual(page.nextCursor?.rawValue, "4")
    }

    /// 有效照片应完整映射稳定 ID、来源、署名、Pexels 许可和大图/缩略图地址。
    func testMapsPexelsPhotoMetadata() async throws {
        PexelsURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Self.fixture)
        }

        let page = try await makeClient().search(query: "cat", cursor: nil, pageSize: 10)
        let record = try XCTUnwrap(page.records.first)
        XCTAssertEqual(page.records.count, 1)
        XCTAssertEqual(record.id, "px:314159")
        XCTAssertEqual(record.title, "Orange cat near a window")
        XCTAssertEqual(record.source, .pexels)
        XCTAssertEqual(record.source.displayName, "Pexels")
        XCTAssertEqual(record.imageURL.absoluteString, "https://images.pexels.com/photos/314159/large2x.jpg")
        XCTAssertEqual(record.thumbnailURL.absoluteString, "https://images.pexels.com/photos/314159/medium.jpg")
        XCTAssertEqual(record.sourcePageURL?.absoluteString, "https://www.pexels.com/photo/orange-cat-314159/")
        XCTAssertEqual(record.creator, "Ana")
        XCTAssertEqual(record.creatorURL?.absoluteString, "https://www.pexels.com/@ana/")
        XCTAssertEqual(record.license, .pexels)
        XCTAssertEqual(record.width, 2400)
        XCTAssertEqual(record.height, 1600)
        XCTAssertEqual(record.mimeType, "image/jpeg")
    }

    /// 401 必须归类为凭据无效，错误描述不能包含用户传入的 Key。
    func testUnauthorizedResponseIsInvalidCredentialWithoutKeyLeak() async {
        PexelsURLProtocol.handler = { request in
            (Self.response(for: request, status: 401), Data())
        }
        let secret = "do-not-leak-this-key"

        do {
            _ = try await makeClient(apiKey: secret).search(query: "cat", cursor: nil, pageSize: 10)
            XCTFail("401 应抛出凭据错误")
        } catch {
            XCTAssertEqual(error as? PexelsError, .invalidCredential)
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }

    /// 429 应转换成限流错误并保留 Pexels 的绝对重置时间。
    func testRateLimitResponsePreservesResetTime() async {
        let resetTimestamp: TimeInterval = 1_800_000_123
        PexelsURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["X-Ratelimit-Reset": String(Int(resetTimestamp))]
            )!
            return (response, Data())
        }

        do {
            _ = try await makeClient().search(query: "cat", cursor: nil, pageSize: 10)
            XCTFail("429 应抛出限流错误")
        } catch {
            XCTAssertEqual(
                error as? PexelsError,
                .rateLimited(resetAt: Date(timeIntervalSince1970: resetTimestamp))
            )
        }
    }

    /// 成功响应的通用额度快照供跨 App/Finder 的预算层共享。
    func testSuccessfulResponseMapsQuotaHeaders() async throws {
        let resetTimestamp: TimeInterval = 1_800_000_456
        PexelsURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "X-Ratelimit-Limit": "200",
                    "X-Ratelimit-Remaining": "17",
                    "X-Ratelimit-Reset": String(Int(resetTimestamp))
                ]
            )!
            return (response, Self.fixture)
        }

        let page = try await makeClient().search(query: "cat", cursor: nil, pageSize: 80)

        XCTAssertEqual(page.quota?.limit, 200)
        XCTAssertEqual(page.quota?.remaining, 17)
        XCTAssertEqual(page.quota?.resetAt, Date(timeIntervalSince1970: resetTimestamp))
    }

    private func makeClient(apiKey: String = "test-key") -> PexelsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PexelsURLProtocol.self]
        return PexelsClient(apiKey: apiKey, session: URLSession(configuration: configuration))
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static let fixture = Data(#"""
    {
      "page": 3,
      "per_page": 27,
      "next_page": "https://api.pexels.com/v1/search?query=red%20panda&page=4&per_page=27",
      "photos": [
        {
          "id": 314159,
          "width": 2400,
          "height": 1600,
          "url": "https://www.pexels.com/photo/orange-cat-314159/",
          "photographer": "Ana",
          "photographer_url": "https://www.pexels.com/@ana/",
          "alt": "Orange cat near a window",
          "src": {
            "large2x": "https://images.pexels.com/photos/314159/large2x.jpg",
            "large": "https://images.pexels.com/photos/314159/large.jpg",
            "medium": "https://images.pexels.com/photos/314159/medium.jpg",
            "small": "https://images.pexels.com/photos/314159/small.jpg"
          }
        }
      ]
    }
    """#.utf8)
}

private final class PexelsURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler?(request) ?? { throw URLError(.badServerResponse) }()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
