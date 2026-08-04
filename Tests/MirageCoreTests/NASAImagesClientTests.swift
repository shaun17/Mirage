import Foundation
import XCTest
@testable import MirageCore

final class NASAImagesClientTests: XCTestCase {
    override func tearDown() {
        NASAImagesURLProtocol.handler = nil
        super.tearDown()
    }

    /// 请求必须固定为图片搜索；next 的 URL 不可信，只能由当前页推导下一页游标。
    func testSearchMapsAppPreviewAndDerivesPaginationCursor() async throws {
        NASAImagesURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "images-api.nasa.gov")
            XCTAssertEqual(request.url?.path, "/search")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

            let items = try Self.queryItems(for: request)
            XCTAssertEqual(items["q"], "apollo moon")
            XCTAssertEqual(items["media_type"], "image")
            XCTAssertEqual(items["page"], "3")
            XCTAssertEqual(items["page_size"], "20")
            return (Self.response(for: request, status: 200), Self.successFixture)
        }

        let page = try await makeClient().search(
            query: "apollo moon",
            cursor: PhotoSourceCursor(rawValue: "3"),
            pageSize: 20
        )

        let record = try XCTUnwrap(page.records.first)
        XCTAssertEqual(page.records.count, 1)
        XCTAssertEqual(record.id, StableImageID.nasa(nasaID: "PIA24439"))
        XCTAssertEqual(record.title, "Apollo Footprint")
        XCTAssertEqual(record.source, .nasa)
        XCTAssertEqual(record.imageURL.absoluteString, "https://images-assets.nasa.gov/image/PIA24439/PIA24439~medium.jpg")
        XCTAssertEqual(record.thumbnailURL, record.imageURL)
        XCTAssertEqual(record.sourcePageURL?.absoluteString, "https://images.nasa.gov/details/PIA24439")
        XCTAssertEqual(record.license, .nasaMediaUsage)
        XCTAssertEqual(record.creator, "Buzz Aldrin")
        XCTAssertEqual(record.width, 1_280)
        XCTAssertEqual(record.height, 1_253)
        XCTAssertEqual(record.mimeType, "image/jpeg")
        XCTAssertEqual(page.nextCursor?.rawValue, "4")
    }

    /// 同页 nasa_id 只保留首个安全条目；非图片、第三方 host、空字段和 null 元素都应被过滤。
    func testDeduplicatesFiltersUnsafeItemsAndUpgradesOfficialHTTPAsset() async throws {
        NASAImagesURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Self.filteringFixture)
        }

        let page = try await makeClient().search(query: "mission", cursor: nil, pageSize: 10)
        let record = try XCTUnwrap(page.records.first)

        XCTAssertEqual(page.records.count, 1)
        XCTAssertEqual(record.id, StableImageID.nasa(nasaID: "DUPLICATE ID/1"))
        XCTAssertEqual(record.imageURL.absoluteString, "https://images-assets.nasa.gov/image/duplicate/first~medium.png")
        XCTAssertEqual(record.thumbnailURL, record.imageURL)
        XCTAssertEqual(record.sourcePageURL?.absoluteString, "https://images.nasa.gov/details/DUPLICATE%20ID%2F1")
        XCTAssertEqual(record.creator, "NASA")
        XCTAssertEqual(record.mimeType, "image/png")
        XCTAssertNil(page.nextCursor)
    }

    /// 无 next 关系必须结束；NASA 的单页请求值夹在 1...100 内。
    func testNoNextEndsPaginationAndPageSizeIsClamped() async throws {
        NASAImagesURLProtocol.handler = { request in
            let items = try Self.queryItems(for: request)
            XCTAssertEqual(items["page"], "1")
            XCTAssertEqual(items["page_size"], "100")
            return (Self.response(for: request, status: 200), Self.emptyFixture)
        }

        let page = try await makeClient().search(query: "earth", cursor: nil, pageSize: 999)
        XCTAssertTrue(page.records.isEmpty)
        XCTAssertNil(page.nextCursor)
    }

    /// 即使服务端仍给 next，共享分页上限也必须终止；非规范或越界游标在发请求前拒绝。
    func testMaximumPageStopsAndInvalidCursorIsRejected() async throws {
        NASAImagesURLProtocol.handler = { request in
            let items = try Self.queryItems(for: request)
            XCTAssertEqual(items["page"], String(SearchPaginationCursor.maximumPage))
            return (Self.response(for: request, status: 200), Self.nextOnlyFixture)
        }

        let lastPage = try await makeClient().search(
            query: "earth",
            cursor: PhotoSourceCursor(rawValue: String(SearchPaginationCursor.maximumPage)),
            pageSize: 20
        )
        XCTAssertNil(lastPage.nextCursor)

        for rawCursor in ["01", "0", String(SearchPaginationCursor.maximumPage + 1), "not-a-page"] {
            do {
                _ = try await makeClient().search(
                    query: "earth",
                    cursor: PhotoSourceCursor(rawValue: rawCursor),
                    pageSize: 20
                )
                XCTFail("非法游标 \(rawCursor) 应被拒绝")
            } catch {
                XCTAssertEqual(error as? NASAImagesError, .invalidCursor)
            }
        }
    }

    /// 429 要保留可重试时间，并通过 PhotoSourceFailure 暴露统一来源与分类。
    func testRateLimitConformsToPhotoSourceFailure() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        NASAImagesURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "7"]
            )!
            return (response, Data())
        }

        do {
            _ = try await makeClient(now: now).search(query: "mars", cursor: nil, pageSize: 20)
            XCTFail("429 应抛出限流错误")
        } catch {
            let expectedDate = now.addingTimeInterval(7)
            XCTAssertEqual(error as? NASAImagesError, .rateLimited(retryAt: expectedDate))
            guard let failure = error as? any PhotoSourceFailure else {
                return XCTFail("NASA 错误必须符合 PhotoSourceFailure")
            }
            XCTAssertEqual(failure.sourceID, .nasa)
            XCTAssertEqual(failure.issueKind, .rateLimited)
            XCTAssertEqual(failure.retryAt, expectedDate)
        }
    }

    /// HTTP、解码与网络错误必须保持可区分的类型化分类。
    func testHTTPDecodingAndNetworkErrorsAreDistinctFailures() async {
        NASAImagesURLProtocol.handler = { request in
            (Self.response(for: request, status: 503), Data())
        }
        await assertFailure(
            expectedError: .invalidResponse(statusCode: 503),
            expectedKind: .invalidResponse
        )

        NASAImagesURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Data("not-json".utf8))
        }
        await assertFailure(
            expectedError: .decoding("响应格式无效"),
            expectedKind: .decoding
        )

        NASAImagesURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        do {
            _ = try await makeClient().search(query: "mars", cursor: nil, pageSize: 20)
            XCTFail("网络失败应抛出错误")
        } catch {
            guard case .network = error as? NASAImagesError else {
                return XCTFail("网络错误分类不正确：\(error)")
            }
            guard let failure = error as? any PhotoSourceFailure else {
                return XCTFail("NASA 错误必须符合 PhotoSourceFailure")
            }
            XCTAssertEqual(failure.sourceID, .nasa)
            XCTAssertEqual(failure.issueKind, .network)
            XCTAssertNil(failure.retryAt)
        }
    }

    private func assertFailure(
        expectedError: NASAImagesError,
        expectedKind: PhotoSourceIssueKind
    ) async {
        do {
            _ = try await makeClient().search(query: "mars", cursor: nil, pageSize: 20)
            XCTFail("请求应抛出错误")
        } catch {
            XCTAssertEqual(error as? NASAImagesError, expectedError)
            guard let failure = error as? any PhotoSourceFailure else {
                return XCTFail("NASA 错误必须符合 PhotoSourceFailure")
            }
            XCTAssertEqual(failure.sourceID, .nasa)
            XCTAssertEqual(failure.issueKind, expectedKind)
            XCTAssertNil(failure.retryAt)
        }
    }

    private func makeClient(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> NASAImagesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NASAImagesURLProtocol.self]
        return NASAImagesClient(
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

    private static let successFixture = Data(#"""
    {
      "collection": {
        "version": "1.1",
        "href": "http://images-api.nasa.gov/search?q=apollo&page=3",
        "links": [
          {"rel":"next","prompt":"Next","href":"http://evil.example/search?page=999"}
        ],
        "items": [
          {
            "data": [
              {
                "nasa_id":"PIA24439",
                "media_type":"image",
                "title":"  Apollo Footprint  ",
                "photographer":" Buzz Aldrin ",
                "secondary_creator":"NASA",
                "center":"JPL"
              }
            ],
            "links": [
              {
                "href":"https://images-assets.nasa.gov/image/PIA24439/PIA24439~medium.jpg",
                "rel":"preview",
                "render":"image",
                "width":1280,
                "height":1253
              }
            ]
          }
        ]
      }
    }
    """#.utf8)

    private static let filteringFixture = Data(#"""
    {
      "collection": {
        "items": [
          null,
          {"data":null,"links":null},
          {
            "data":[null,{"nasa_id":"DUPLICATE ID/1","media_type":"image","title":null,"photographer":"  ","secondary_creator":"NASA","center":"HQ"}],
            "links":[
              {"href":"https://evil.example/image/duplicate/first.png","rel":"preview","render":"image"},
              {"href":"http://images-assets.nasa.gov/image/duplicate/first~medium.png","rel":"preview","render":"image"}
            ]
          },
          {
            "data":[{"nasa_id":"DUPLICATE ID/1","media_type":"image","title":"Duplicate"}],
            "links":[{"href":"https://images-assets.nasa.gov/image/duplicate/second~medium.jpg","rel":"preview","render":"image"}]
          },
          {
            "data":[{"nasa_id":"VIDEO-1","media_type":"video","title":"Video"}],
            "links":[{"href":"https://images-assets.nasa.gov/video/video.jpg","rel":"preview","render":"image"}]
          },
          {
            "data":[{"nasa_id":"EVIL-1","media_type":"image","title":"Wrong host"}],
            "links":[{"href":"https://images-assets.nasa.gov.evil.example/image/evil.jpg","rel":"preview","render":"image"}]
          },
          {
            "data":[{"nasa_id":"EVIL-2","media_type":"image","title":"User info"}],
            "links":[{"href":"https://images-assets.nasa.gov@evil.example/image/evil.jpg","rel":"preview","render":"image"}]
          },
          {
            "data":[{"nasa_id":"NOT-IMAGE-LINK","media_type":"image"}],
            "links":[{"href":"https://images-assets.nasa.gov/image/not-image.mp4","rel":"preview","render":"video"}]
          },
          {
            "data":[{"nasa_id":null,"media_type":"image"}],
            "links":[{"href":"https://images-assets.nasa.gov/image/missing.jpg","rel":"preview","render":"image"}]
          }
        ],
        "links": null
      }
    }
    """#.utf8)

    private static let emptyFixture = Data(#"""
    {"collection":{"items":[],"links":[{"rel":"self","href":"http://images-api.nasa.gov/search?page=1"}]}}
    """#.utf8)

    private static let nextOnlyFixture = Data(#"""
    {"collection":{"items":[],"links":[{"rel":"next","href":"http://images-api.nasa.gov/search?page=10001"}]}}
    """#.utf8)
}

private final class NASAImagesURLProtocol: URLProtocol, @unchecked Sendable {
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
