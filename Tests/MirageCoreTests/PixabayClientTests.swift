import Foundation
import XCTest
@testable import MirageCore

final class PixabayClientTests: XCTestCase {
    override func tearDown() {
        PixabayURLProtocol.handler = nil
        super.tearDown()
    }

    /// Pixabay 要求 Key 进入查询参数；异常文本不得回显 Key、请求 URL 或底层响应正文。
    func testRequestUsesPixabayParametersWithoutLeakingKeyInErrors() async {
        let secret = "pixabay-secret-key"
        PixabayURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "pixabay.com")
            XCTAssertEqual(request.url?.path, "/api")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)

            let items = try Self.queryItems(for: request)
            XCTAssertEqual(items["key"], secret)
            XCTAssertEqual(items["q"], "red panda")
            XCTAssertEqual(items["lang"], "en")
            XCTAssertEqual(items["image_type"], "photo")
            XCTAssertEqual(items["safesearch"], "true")
            XCTAssertEqual(items["order"], "popular")
            XCTAssertEqual(items["page"], "3")
            XCTAssertEqual(items["per_page"], "27")
            return (Self.response(for: request, status: 500), Data("upstream \(secret)".utf8))
        }

        do {
            _ = try await makeClient(apiKey: "  \(secret)  ").search(
                query: "red panda",
                cursor: PhotoSourceCursor(rawValue: "3"),
                pageSize: 27
            )
            XCTFail("500 应抛出 HTTP 状态错误")
        } catch {
            XCTAssertEqual(error as? PixabayError, .invalidResponse(statusCode: 500))
            XCTAssertFalse(error.localizedDescription.contains(secret))
            XCTAssertFalse(error.localizedDescription.contains("pixabay.com/api"))
            XCTAssertFalse(error.localizedDescription.contains("upstream"))
        }
    }

    /// 普通 Key 不含 fullHDURL/imageURL 时仍应选 1280 档，并按原图比例回算实际尺寸。
    func testStandardAccessMapsLargeImageAndMetadata() async throws {
        PixabayURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Self.standardFixture)
        }

        let page = try await makeClient().search(query: "flower", cursor: nil, pageSize: 20)
        let record = try XCTUnwrap(page.records.first)
        XCTAssertEqual(page.records.count, 1)
        XCTAssertEqual(record.id, StableImageID.pixabay(id: 195_893))
        XCTAssertEqual(record.id, "pb:195893")
        XCTAssertEqual(record.title, "blossom, bloom, flower")
        XCTAssertEqual(record.source, .pixabay)
        XCTAssertEqual(record.source.displayName, "Pixabay")
        XCTAssertEqual(record.license, .pixabay)
        XCTAssertEqual(record.imageURL.absoluteString, "https://pixabay.com/get/flower_1280.jpg")
        XCTAssertEqual(record.thumbnailURL.absoluteString, "https://cdn.pixabay.com/photo/flower_640.jpg")
        XCTAssertEqual(record.sourcePageURL?.absoluteString, "https://pixabay.com/photos/blossom-bloom-flower-195893/")
        XCTAssertEqual(record.creator, "Josch13")
        XCTAssertEqual(record.creatorURL?.absoluteString, "https://pixabay.com/users/Josch13-48777/")
        XCTAssertEqual(record.width, 1_280)
        XCTAssertEqual(record.height, 720)
        XCTAssertEqual(record.mimeType, "image/jpeg")
        XCTAssertNil(page.nextCursor)
    }

    /// full access 同时返回多档地址时必须优先原图，并保留原始像素尺寸。
    func testFullAccessPrefersOriginalImage() async throws {
        PixabayURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Self.fullAccessFixture)
        }

        let page = try await makeClient().search(query: "flower", cursor: nil, pageSize: 20)
        let record = try XCTUnwrap(page.records.first)
        XCTAssertEqual(record.imageURL.absoluteString, "https://pixabay.com/get/flower-original.jpg")
        XCTAssertEqual(record.thumbnailURL.absoluteString, "https://cdn.pixabay.com/photo/flower_640.jpg")
        XCTAssertEqual(record.width, 4_000)
        XCTAssertEqual(record.height, 2_250)
    }

    /// 缺少原图时依次选择 1920 档或 webformat，并让元数据反映实际选择的文件而非原图能力。
    func testMapsFullHDAndWebformatDimensionsFromSelectedCapability() async throws {
        PixabayURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Self.scaledCapabilityFixture)
        }

        let records = try await makeClient().search(
            query: "landscape",
            cursor: nil,
            pageSize: 20
        ).records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].imageURL.absoluteString, "https://pixabay.com/get/wide_1920.jpg")
        XCTAssertEqual(records[0].width, 1_920)
        XCTAssertEqual(records[0].height, 1_080)
        XCTAssertEqual(records[1].imageURL.absoluteString, "https://cdn.pixabay.com/photo/small_640.jpg")
        XCTAssertEqual(records[1].width, 600)
        XCTAssertEqual(records[1].height, 400)
    }

    /// 成功响应应把三个额度头映射成共享快照，reset 按“距现在秒数”解释。
    func testSuccessfulResponseMapsRelativeRateLimitHeaders() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        PixabayURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "X-RateLimit-Limit": "100",
                    "X-RateLimit-Remaining": "17",
                    "X-RateLimit-Reset": "42"
                ]
            )!
            return (response, Self.emptyFixture(totalHits: 0))
        }

        let page = try await makeClient(now: now).search(query: "cat", cursor: nil, pageSize: 20)
        XCTAssertEqual(page.quota?.limit, 100)
        XCTAssertEqual(page.quota?.remaining, 17)
        XCTAssertEqual(page.quota?.resetAt, now.addingTimeInterval(42))
    }

    /// 429 使用同一相对 reset 语义，供上层预算协调器决定恢复时间。
    func testRateLimitResponseUsesRelativeResetTime() async {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        PixabayURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["X-RateLimit-Reset": "9"]
            )!
            return (response, Data())
        }

        do {
            _ = try await makeClient(now: now).search(query: "cat", cursor: nil, pageSize: 20)
            XCTFail("429 应抛出限流错误")
        } catch {
            XCTAssertEqual(
                error as? PixabayError,
                .rateLimited(resetAt: now.addingTimeInterval(9))
            )
        }
    }

    /// Pixabay 用 400/401/403 表示 Key 无效或未获授权，三者统一归为凭据错误。
    func testCredentialStatusCodesAreInvalidCredentialWithoutKeyLeak() async {
        let secret = "never-print-this-key"
        for status in [400, 401, 403] {
            PixabayURLProtocol.handler = { request in
                (Self.response(for: request, status: status), Data())
            }
            do {
                _ = try await makeClient(apiKey: secret).search(query: "cat", cursor: nil, pageSize: 20)
                XCTFail("\(status) 应抛出凭据错误")
            } catch {
                XCTAssertEqual(error as? PixabayError, .invalidCredential)
                XCTAssertFalse(error.localizedDescription.contains(secret))
                XCTAssertFalse(error.localizedDescription.contains("pixabay.com/api"))
            }
        }
    }

    /// 所有远端 URL 都必须逐项验证 host；非法高优先级地址可降级，无法得到安全主图的条目应丢弃。
    func testFiltersMaliciousHostsAndFallsBackToSafeURLs() async throws {
        PixabayURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Self.maliciousHostFixture)
        }

        let page = try await makeClient().search(query: "cat", cursor: nil, pageSize: 20)
        let record = try XCTUnwrap(page.records.first)
        XCTAssertEqual(page.records.map(\.id), [StableImageID.pixabay(id: 2)])
        XCTAssertEqual(record.imageURL.absoluteString, "https://cdn.pixabay.com/photo/safe_1280.jpg")
        XCTAssertEqual(record.thumbnailURL.absoluteString, "https://cdn.pixabay.com/photo/safe_150.jpg")
        XCTAssertNil(record.sourcePageURL)
        XCTAssertEqual(record.creatorURL?.host, "pixabay.com")
        XCTAssertFalse(record.imageURL.absoluteString.contains("evil.example"))
        XCTAssertFalse(record.thumbnailURL.absoluteString.contains("evil.example"))
    }

    /// nextCursor 只由请求页码、实际上游 pageSize 与 totalHits 决定，最后一页必须终止。
    func testPaginationUsesTotalHitsAndStopsAtLastPage() async throws {
        PixabayURLProtocol.handler = { request in
            let requestedPage = try Self.queryItems(for: request)["page"].flatMap(Int.init) ?? 1
            return (
                Self.response(for: request, status: 200),
                Self.singleHitFixture(totalHits: 7, id: requestedPage)
            )
        }
        let client = makeClient()

        let middle = try await client.search(
            query: "cat",
            cursor: PhotoSourceCursor(rawValue: "2"),
            pageSize: 3
        )
        XCTAssertEqual(middle.nextCursor?.rawValue, "3")

        let last = try await client.search(
            query: "cat",
            cursor: PhotoSourceCursor(rawValue: "3"),
            pageSize: 3
        )
        XCTAssertNil(last.nextCursor)
    }

    func testEmptyHitsStopPaginationEvenWhenTotalHitsIsStale() async throws {
        PixabayURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Self.emptyFixture(totalHits: 500))
        }

        let page = try await makeClient().search(query: "cat", cursor: nil, pageSize: 40)

        XCTAssertTrue(page.records.isEmpty)
        XCTAssertNil(page.nextCursor)
    }

    func testHanQueryUsesChineseSearchLanguage() async throws {
        PixabayURLProtocol.handler = { request in
            let items = try Self.queryItems(for: request)
            XCTAssertEqual(items["q"], "城市风景")
            XCTAssertEqual(items["lang"], "zh")
            return (Self.response(for: request, status: 200), Self.emptyFixture(totalHits: 0))
        }

        _ = try await makeClient().search(query: "城市风景", cursor: nil, pageSize: 20)
    }

    /// testConnection 的 pageSize=1 要夹到合法下限 3；超大页夹到 200，查询最多保留 100 个字符。
    func testClampsPageSizeAndTruncatesLongQuery() async throws {
        let longQuery = String(repeating: "a", count: 120)
        PixabayURLProtocol.handler = { request in
            let items = try Self.queryItems(for: request)
            if items["q"] == "cat" {
                XCTAssertEqual(items["per_page"], "200")
            } else {
                XCTAssertEqual(items["q"], String(longQuery.prefix(100)))
                XCTAssertEqual(items["q"]?.count, 100)
                XCTAssertEqual(items["per_page"], "3")
            }
            return (Self.response(for: request, status: 200), Self.emptyFixture(totalHits: 0))
        }
        let client = makeClient()

        _ = try await client.search(query: longQuery, cursor: nil, pageSize: 1)
        _ = try await client.search(query: "cat", cursor: nil, pageSize: 999)
    }

    private func makeClient(
        apiKey: String = "test-key",
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> PixabayClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PixabayURLProtocol.self]
        configuration.urlCache = nil
        return PixabayClient(
            apiKey: apiKey,
            session: URLSession(configuration: configuration),
            now: { now }
        )
    }

    private static func queryItems(for request: URLRequest) throws -> [String: String] {
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func emptyFixture(totalHits: Int) -> Data {
        Data(#"{"total":\#(totalHits),"totalHits":\#(totalHits),"hits":[]}"#.utf8)
    }

    private static func singleHitFixture(totalHits: Int, id: Int) -> Data {
        Data(#"""
        {
          "total": \#(totalHits),
          "totalHits": \#(totalHits),
          "hits": [
            {
              "id": \#(id),
              "tags": "fixture",
              "webformatURL": "https://cdn.pixabay.com/photo/fixture_640.jpg",
              "webformatWidth": 640,
              "webformatHeight": 360,
              "largeImageURL": "https://pixabay.com/get/fixture_1280.jpg",
              "imageWidth": 1920,
              "imageHeight": 1080
            }
          ]
        }
        """#.utf8)
    }

    private static let standardFixture = Data(#"""
    {
      "total": 1,
      "totalHits": 1,
      "hits": [
        {
          "id": 195893,
          "pageURL": "https://pixabay.com/photos/blossom-bloom-flower-195893/",
          "type": "photo",
          "tags": "blossom, bloom, flower",
          "previewURL": "https://cdn.pixabay.com/photo/flower_150.jpg",
          "previewWidth": 150,
          "previewHeight": 84,
          "webformatURL": "https://cdn.pixabay.com/photo/flower_640.jpg",
          "webformatWidth": 640,
          "webformatHeight": 360,
          "largeImageURL": "https://pixabay.com/get/flower_1280.jpg",
          "imageWidth": 4000,
          "imageHeight": 2250,
          "user_id": 48777,
          "user": "Josch13"
        }
      ]
    }
    """#.utf8)

    private static let fullAccessFixture = Data(#"""
    {
      "total": 1,
      "totalHits": 1,
      "hits": [
        {
          "id": 195893,
          "pageURL": "https://www.pixabay.com/photos/blossom-bloom-flower-195893/",
          "tags": "flower",
          "previewURL": "https://cdn.pixabay.com/photo/flower_150.jpg",
          "webformatURL": "https://cdn.pixabay.com/photo/flower_640.jpg",
          "webformatWidth": 640,
          "webformatHeight": 360,
          "largeImageURL": "https://pixabay.com/get/flower_1280.jpg",
          "fullHDURL": "https://pixabay.com/get/flower_1920.jpg",
          "imageURL": "https://pixabay.com/get/flower-original.jpg",
          "imageWidth": 4000,
          "imageHeight": 2250,
          "user_id": 48777,
          "user": "Josch13"
        }
      ]
    }
    """#.utf8)

    private static let maliciousHostFixture = Data(#"""
    {
      "total": 2,
      "totalHits": 2,
      "hits": [
        {
          "id": 1,
          "pageURL": "https://pixabay.com.evil.example/photo/1/",
          "previewURL": "https://cdn.pixabay.com/photo/preview-only_150.jpg",
          "webformatURL": "https://evil.example/photo/1_640.jpg",
          "largeImageURL": "https://pixabay.com.evil.example/photo/1_1280.jpg",
          "fullHDURL": "https://evil.example/photo/1_1920.jpg",
          "imageURL": "https://evil.example/photo/1.jpg",
          "imageWidth": 3000,
          "imageHeight": 2000,
          "user_id": 1,
          "user": "Attacker"
        },
        {
          "id": 2,
          "pageURL": "https://evil.example/photo/2/",
          "previewURL": "https://cdn.pixabay.com/photo/safe_150.jpg",
          "webformatURL": "https://evil.example/photo/2_640.jpg",
          "largeImageURL": "https://cdn.pixabay.com/photo/safe_1280.jpg",
          "fullHDURL": "https://evil.example/photo/2_1920.jpg",
          "imageURL": "https://evil.example/photo/2.jpg",
          "imageWidth": 3000,
          "imageHeight": 2000,
          "user_id": 2,
          "user": "SafeCreator"
        }
      ]
    }
    """#.utf8)

    private static let scaledCapabilityFixture = Data(#"""
    {
      "total": 2,
      "totalHits": 2,
      "hits": [
        {
          "id": 10,
          "previewURL": "https://cdn.pixabay.com/photo/wide_150.jpg",
          "webformatURL": "https://cdn.pixabay.com/photo/wide_640.jpg",
          "webformatWidth": 640,
          "webformatHeight": 360,
          "largeImageURL": "https://pixabay.com/get/wide_1280.jpg",
          "fullHDURL": "https://pixabay.com/get/wide_1920.jpg",
          "imageWidth": 4000,
          "imageHeight": 2250
        },
        {
          "id": 11,
          "previewURL": "https://cdn.pixabay.com/photo/small_150.jpg",
          "webformatURL": "https://cdn.pixabay.com/photo/small_640.jpg",
          "webformatWidth": 600,
          "webformatHeight": 400,
          "imageWidth": 3000,
          "imageHeight": 2000
        }
      ]
    }
    """#.utf8)
}

private final class PixabayURLProtocol: URLProtocol, @unchecked Sendable {
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
