import Foundation
import XCTest
@testable import MirageCore

final class OpenverseClientTests: XCTestCase {
    /// 每个测试后清理全局拦截器，避免测试间互相污染。
    override func tearDown() {
        TestURLProtocol.handler = nil
        super.tearDown()
    }

    /// 客户端应发送质量与安全参数，并严格丢弃成熟、非 HTTPS、非公版及不适内容。
    func testRequestAndStrictFiltering() async throws {
        TestURLProtocol.handler = { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let items = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(items["mature"], "false")
            XCTAssertEqual(items["license"], "cc0,pdm")
            XCTAssertEqual(items["filter_dead"], "true")
            XCTAssertEqual(items["category"], "photograph")
            XCTAssertEqual(items["size"], "large")
            XCTAssertEqual(
                items["excluded_source"],
                OpenverseContentSafetyPolicy.excludedAPISources.joined(separator: ",")
            )
            XCTAssertEqual(items["page"], "2")
            XCTAssertEqual(items["page_size"], "7")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.fixture)
        }
        let page = try await makeClient().search(query: "cat", page: 2, pageSize: 7)
        XCTAssertEqual(page.records.map(\.id), ["ov:a0b1c2d3-e4f5-4678-9012-3456789abcde"])
        XCTAssertEqual(page.records.first?.license.identifier, "cc0")
        XCTAssertEqual(page.records.first?.mimeType, "image/png")
        XCTAssertEqual(page.records.first?.sourcePageURL?.absoluteString, "https://openverse.example/a")
        XCTAssertEqual(page.nextPage, 3)
    }

    /// 过滤器必须识别英文、中文和标签中的不适主题，同时避免子串误伤普通标题。
    func testContentSafetyPolicyUsesTokenBoundariesAndMultilingualTerms() {
        XCTAssertTrue(OpenverseContentSafetyPolicy.allows(
            title: "Antique botanical portrait",
            tags: ["plant"],
            source: "stocksnap",
            category: "photograph"
        ))
        XCTAssertFalse(OpenverseContentSafetyPolicy.allows(
            title: "Macro photograph",
            tags: ["Araneae"],
            source: "flickr",
            category: "photograph"
        ))
        XCTAssertFalse(OpenverseContentSafetyPolicy.allows(
            title: "蜘蛛特写",
            tags: [],
            source: "flickr",
            category: "photograph"
        ))
        for blockedTag in ["fireflies", "roadkill", "carcass", "decapitated"] {
            XCTAssertFalse(OpenverseContentSafetyPolicy.allows(
                title: "Archive photograph",
                tags: [blockedTag],
                source: "rawpixel",
                category: "photograph"
            ), "应过滤标签：\(blockedTag)")
        }
        XCTAssertFalse(OpenverseContentSafetyPolicy.allows(
            title: "Bird portrait",
            tags: [],
            source: "inaturalist",
            category: "photograph"
        ))
        XCTAssertFalse(OpenverseContentSafetyPolicy.allows(
            title: "Marine portrait",
            tags: [],
            source: "WoRMS",
            category: "photograph"
        ))
        XCTAssertFalse(OpenverseContentSafetyPolicy.allows(
            title: "Safe vector",
            tags: [],
            source: "svgsilh",
            category: "illustration"
        ))
    }

    /// 429 必须作为限流错误暴露，并保留服务端给出的重试秒数。
    func testRateLimitError() async {
        TestURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "9"]
            )!
            return (response, Data())
        }
        do {
            _ = try await makeClient().search(query: "cat", page: 1, pageSize: 1)
            XCTFail("应抛出限流错误")
        } catch {
            XCTAssertEqual(error as? OpenverseError, .rateLimited(retryAfter: 9))
        }
    }

    /// 非法 JSON 必须与网络和 HTTP 错误区分。
    func testDecodingError() async {
        TestURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("not-json".utf8))
        }
        do {
            _ = try await makeClient().search(query: "cat", page: 1, pageSize: 1)
            XCTFail("应抛出解析错误")
        } catch {
            guard case .decoding = error as? OpenverseError else { return XCTFail("错误类型不正确：\(error)") }
        }
    }

    /// 服务端当前页等于总页数时必须停止，避免请求越过 Openverse 的页深限制。
    func testLastPageHasNoContinuation() async throws {
        TestURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"page":4,"page_count":4,"page_size":20,"result_count":80,"results":[]}"#.utf8))
        }
        let page = try await makeClient().search(query: "cat", page: 4, pageSize: 20)
        XCTAssertEqual(page.records, [])
        XCTAssertNil(page.nextPage)
    }

    /// 创建仅使用 URLProtocol 的隔离会话，测试绝不访问真实网络。
    private func makeClient() -> OpenverseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return OpenverseClient(session: URLSession(configuration: configuration))
    }

    private static let fixture = Data(#"""
    {"page":2,"page_count":4,"page_size":7,"result_count":25,"results":[
      {"id":"A0B1C2D3-E4F5-4678-9012-3456789ABCDE","title":"Valid portrait","creator":"A","creator_url":"https://example.com/a","foreign_landing_url":"https://openverse.example/a","url":"https://images.example.com/a.png","thumbnail":"https://images.example.com/t.png","license":"cc0","license_url":"https://creativecommons.org/publicdomain/zero/1.0/","mature":false,"source":"stocksnap","category":"photograph","tags":[{"name":"portrait"}],"width":2400,"height":1600,"filetype":"png"},
      {"id":"B0B1C2D3-E4F5-4678-9012-3456789ABCDE","url":"https://images.example.com/b.png","thumbnail":"https://images.example.com/bt.png","license":"pdm","mature":true},
      {"id":"C0B1C2D3-E4F5-4678-9012-3456789ABCDE","url":"http://images.example.com/c.png","thumbnail":"https://images.example.com/ct.png","license":"pdm","mature":false},
      {"id":"D0B1C2D3-E4F5-4678-9012-3456789ABCDE","url":"https://images.example.com/d.png","thumbnail":"https://images.example.com/dt.png","license":"by","mature":false},
      {"id":"E0B1C2D3-E4F5-4678-9012-3456789ABCDE","title":"Macro portrait","url":"https://images.example.com/e.png","thumbnail":"https://images.example.com/et.png","license":"cc0","mature":false,"source":"flickr","category":"photograph","tags":[{"name":"spider"}]},
      {"id":"F0B1C2D3-E4F5-4678-9012-3456789ABCDE","title":"Medical archive","url":"https://images.example.com/f.png","thumbnail":"https://images.example.com/ft.png","license":"pdm","mature":false,"source":"flickr","category":"photograph","tags":[{"name":"open wound"}]},
      {"id":"F1B1C2D3-E4F5-4678-9012-3456789ABCDE","title":"Bird portrait","url":"https://images.example.com/g.png","thumbnail":"https://images.example.com/gt.png","license":"cc0","mature":false,"source":"inaturalist","category":"photograph","tags":[{"name":"bird"}]}
    ]}
    """#.utf8)
}

private final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    /// 拦截所有测试会话请求。
    override class func canInit(with request: URLRequest) -> Bool { true }

    /// 不改写请求，保留查询参数供断言。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// 同步返回测试夹具或把构造错误传给 URLSession。
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

    /// 测试响应没有额外后台工作需要取消。
    override func stopLoading() {}
}
