import Foundation
import XCTest
@testable import MirageCore

final class GiphyEmojiClientTests: XCTestCase {
    override func tearDown() {
        GiphyEmojiURLProtocol.handler = nil
        super.tearDown()
    }

    /// 默认 Emoji endpoint 是固定列表而非文本搜索；请求只能携带 Key、limit 和 offset。
    func testRequestUsesOnlyCatalogContractAndClampsLimitAtForty() async throws {
        let secret = "secret&key"
        GiphyEmojiURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "api.giphy.com")
            XCTAssertEqual(request.url?.path, "/v2/emoji")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.timeoutInterval, 20)

            let components = URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )
            let queryItems = try XCTUnwrap(components?.queryItems)
            XCTAssertEqual(Set(queryItems.map(\.name)), ["api_key", "limit", "offset"])
            let values = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(values["api_key"], secret)
            XCTAssertEqual(values["limit"], "40")
            XCTAssertEqual(values["offset"], "37")
            XCTAssertNil(values["q"])
            XCTAssertNil(values["rating"])
            XCTAssertNil(values["lang"])
            return (
                Self.response(for: request, status: 200),
                Self.envelope(data: "[]", offset: 37, totalCount: 37, count: 0)
            )
        }

        let client = makeClient(apiKey: "  \(secret)  ")
        let page = try await client.search(
            query: "这个查询不应出现在请求中",
            cursor: PhotoSourceCursor(rawValue: "37"),
            pageSize: 999
        )

        XCTAssertEqual(client.sourceID, .giphy)
        XCTAssertTrue(page.records.isEmpty)
        XCTAssertNil(page.nextCursor)
    }

    /// 主图使用 original，网格使用动态 fixed_width，并映射 GIPHY 用户归属信息。
    func testMapsAnimatedRenditionsOriginalDimensionsAndAttribution() async throws {
        GiphyEmojiURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Self.mappingFixture)
        }

        let page = try await makeClient().search(query: "ignored", cursor: nil, pageSize: 20)
        let record = try XCTUnwrap(page.records.first)

        XCTAssertEqual(page.records.count, 1)
        XCTAssertEqual(record.id, StableImageID.giphy(id: "emoji123"))
        XCTAssertEqual(record.title, "A colorful blob celebrates")
        XCTAssertEqual(record.source, .giphy)
        XCTAssertEqual(record.giphyContentType, .gif)
        XCTAssertEqual(record.giphyID, "emoji123")
        XCTAssertEqual(record.license, .giphy)
        XCTAssertEqual(
            record.imageURL.absoluteString,
            "https://media2.giphy.com/media/emoji123/giphy.gif?cid=client-id&rid=giphy.gif&ct=s"
        )
        XCTAssertEqual(
            record.thumbnailURL.absoluteString,
            "https://media1.giphy.com/media/emoji123/200w.gif?cid=client-id&rid=200w.gif&ct=s"
        )
        XCTAssertEqual(
            record.sourcePageURL?.absoluteString,
            "https://giphy.com/gifs/party-emoji123?utm_source=mirage"
        )
        XCTAssertEqual(record.creator, "Emoji Artist")
        XCTAssertEqual(
            record.creatorURL?.absoluteString,
            "https://giphy.com/creators/emoji-artist/?utm_source=mirage"
        )
        XCTAssertEqual(record.width, 480)
        XCTAssertEqual(record.height, 480)
        XCTAssertEqual(record.mimeType, "image/gif")
        XCTAssertEqual(page.nextCursor?.rawValue, "23")
    }

    /// 收藏恢复只提交对象 ID 到官方批量端点，不复用或持久化旧媒体 URL。
    func testLookupRecordsUsesOfficialIDsEndpoint() async throws {
        GiphyEmojiURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/gifs")
            let values = try Self.queryValues(for: request)
            XCTAssertEqual(Set(values.keys), ["api_key", "ids"])
            XCTAssertEqual(values["api_key"], "test-key")
            XCTAssertEqual(values["ids"], "first,second")
            return (
                Self.response(for: request, status: 200),
                Self.envelope(
                    data: "[\(Self.emojiObject(id: "first", type: "gif")),\(Self.emojiObject(id: "second", type: "gif"))]",
                    offset: 0,
                    totalCount: 2,
                    count: 2
                )
            )
        }

        let records = try await makeClient().records(ids: ["first", "second"])

        XCTAssertEqual(records.map(\.giphyID), ["first", "second"])
        XCTAssertEqual(records.map(\.id), [
            StableImageID.giphy(id: "first"),
            StableImageID.giphy(id: "second")
        ])
    }

    func testLookupRejectsInvalidOrOversizedIdentifiersBeforeNetwork() async {
        GiphyEmojiURLProtocol.handler = { _ in
            XCTFail("无效标识不应发起请求")
            throw URLError(.badURL)
        }

        do {
            _ = try await makeClient().records(ids: ["invalid/id"])
            XCTFail("无效标识应被拒绝")
        } catch {
            XCTAssertEqual(error as? GiphyEmojiError, .invalidIdentifier)
        }
    }

    /// fixed_width 缺失或不安全时只降级到 fixed_height；没有安全小图时跳过记录。
    func testThumbnailFallsBackToFixedHeightAndSkipsMissingSafePreview() async throws {
        GiphyEmojiURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Self.renditionFallbackFixture)
        }

        let records = try await makeClient().search(
            query: "ignored",
            cursor: nil,
            pageSize: 20
        ).records

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(
            records[0].thumbnailURL.absoluteString,
            "https://media4.giphy.com/media/fallback-height/200.gif?rid=200.gif"
        )
    }

    /// v2 Emoji 只使用 next_cursor 续页；空数据页即使仍带 cursor 也必须终止。
    func testPaginationUsesNextCursorAndStopsOnEmptyPage() async throws {
        GiphyEmojiURLProtocol.handler = { request in
            let offset = try Self.queryValues(for: request)["offset"].flatMap(Int.init)
            switch offset {
            case 7:
                return (
                    Self.response(for: request, status: 200),
                    Self.envelope(
                        data: "[\(Self.emojiObject(id: "middle"))]",
                        offset: 1,
                        totalCount: 14,
                        count: 1,
                        nextCursor: 13
                    )
                )
            case 13:
                return (
                    Self.response(for: request, status: 200),
                    Self.envelope(
                        data: "[]",
                        offset: 0,
                        totalCount: 14,
                        count: 0,
                        nextCursor: 14
                    )
                )
            default:
                XCTFail("收到未预期的 offset：\(String(describing: offset))")
                return (
                    Self.response(for: request, status: 500),
                    Data()
                )
            }
        }
        let client = makeClient()

        let middle = try await client.search(
            query: "ignored",
            cursor: PhotoSourceCursor(rawValue: "7"),
            pageSize: 25
        )
        XCTAssertEqual(middle.nextCursor?.rawValue, "13")

        let last = try await client.search(
            query: "ignored",
            cursor: middle.nextCursor,
            pageSize: 25
        )
        XCTAssertNil(last.nextCursor)
    }

    /// GIPHY 文档明确 total_count 不保证出现；缺省时依赖实际 count 安全续页。
    func testMissingPaginationAndMalformedItemsDoNotDiscardValidEmoji() async throws {
        GiphyEmojiURLProtocol.handler = { request in
            (
                Self.response(for: request, status: 200),
                Data(#"""
                {
                  "data": [
                    {"unexpected": true},
                    {
                      "type": "gif",
                      "id": "survivor",
                      "title": "Survivor",
                      "images": {
                        "fixed_width": {
                          "url": "https://media1.giphy.com/media/survivor/200w.gif"
                        },
                        "original": {
                          "url": "https://media1.giphy.com/media/survivor/giphy.gif"
                        }
                      }
                    }
                  ],
                  "meta": {"status": 200, "msg": "OK", "response_id": "fixture"}
                }
                """#.utf8)
            )
        }

        let page = try await makeClient().search(query: "", cursor: nil, pageSize: 20)

        XCTAssertEqual(page.records.map(\.id), [StableImageID.giphy(id: "survivor")])
        XCTAssertNil(page.nextCursor)
    }

    func testPaginationWithoutTotalCountUsesExplicitNextCursor() async throws {
        GiphyEmojiURLProtocol.handler = { request in
            (
                Self.response(for: request, status: 200),
                Data("""
                {
                  "data": [\(Self.emojiObject(id: "cursor-item"))],
                  "pagination": {"offset": 1, "count": 1, "next_cursor": 50},
                  "meta": {"status": 200, "msg": "OK", "response_id": "fixture"}
                }
                """.utf8)
            )
        }

        let page = try await makeClient().search(
            query: "",
            cursor: PhotoSourceCursor(rawValue: "25"),
            pageSize: 25
        )

        XCTAssertEqual(page.nextCursor?.rawValue, "50")
    }

    /// 非前进的 next_cursor 不得复用，避免同一 GIPHY 页被反复请求。
    func testPaginationRejectsNonAdvancingNextCursor() async throws {
        GiphyEmojiURLProtocol.handler = { request in
            (
                Self.response(for: request, status: 200),
                Self.envelope(
                    data: "[\(Self.emojiObject(id: "same-cursor"))]",
                    offset: 1,
                    totalCount: 100,
                    count: 1,
                    nextCursor: 25
                )
            )
        }

        let page = try await makeClient().search(
            query: "",
            cursor: PhotoSourceCursor(rawValue: "25"),
            pageSize: 25
        )

        XCTAssertNil(page.nextCursor)
    }

    /// 真实 v2 形状：首批混合类型且 offset 会变义，续页必须只跟随 next_cursor。
    func testLiveV2ShapeKeepsMixedTypesAndFollowsNextCursor() async throws {
        GiphyEmojiURLProtocol.handler = { request in
            let requestedOffset = try Self.queryValues(for: request)["offset"].flatMap(Int.init)
            let objects: [String]
            let pagination: String
            switch requestedOffset {
            case 0:
                objects = (0..<25).map { index in
                    Self.emojiObject(
                        id: "first-\(index)",
                        type: index < 23 ? "emoji" : "sticker"
                    )
                }
                pagination = "{\"count\":25,\"offset\":25,\"next_cursor\":25}"
            case 25:
                objects = (0..<5).map { Self.emojiObject(id: "second-\($0)") }
                pagination = "{\"count\":5,\"offset\":5,\"next_cursor\":30}"
            default:
                XCTFail("未预期的 offset：\(String(describing: requestedOffset))")
                return (Self.response(for: request, status: 500), Data())
            }
            return (
                Self.response(for: request, status: 200),
                Data("""
                {
                  "data": [\(objects.joined(separator: ","))],
                  "pagination": \(pagination),
                  "meta": {"status":200,"msg":"OK","response_id":"fixture"}
                }
                """.utf8)
            )
        }

        let client = makeClient()
        let first = try await client.search(query: "", cursor: nil, pageSize: 25)
        XCTAssertEqual(first.records.count, 25)
        XCTAssertEqual(first.nextCursor?.rawValue, "25")

        let second = try await client.search(query: "", cursor: first.nextCursor, pageSize: 5)
        XCTAssertEqual(second.records.count, 5)
        XCTAssertEqual(second.nextCursor?.rawValue, "30")
    }

    func testPaginationRejectsExplicitCursorBeyondMaximumOffset() async throws {
        GiphyEmojiURLProtocol.handler = { request in
            (
                Self.response(for: request, status: 200),
                Self.envelope(
                    data: "[\(Self.emojiObject(id: "oversized-cursor"))]",
                    offset: 1,
                    totalCount: Int.max,
                    count: 1,
                    nextCursor: Int(Int32.max) + 1
                )
            )
        }

        let page = try await makeClient().search(query: "", cursor: nil, pageSize: 20)
        XCTAssertNil(page.nextCursor)
    }

    func testLegacyPaginationFallbackAdvancesFullPageAndRejectsOverflow() async throws {
        let fullPage = (0..<25).map { Self.emojiObject(id: "legacy-\($0)") }.joined(separator: ",")
        GiphyEmojiURLProtocol.handler = { request in
            (
                Self.response(for: request, status: 200),
                Data("""
                {
                  "data": [\(fullPage)],
                  "pagination": {"count":25},
                  "meta": {"status":200,"msg":"OK","response_id":"fixture"}
                }
                """.utf8)
            )
        }
        let client = makeClient()
        let normal = try await client.search(
            query: "",
            cursor: PhotoSourceCursor(rawValue: "25"),
            pageSize: 25
        )
        XCTAssertEqual(normal.nextCursor?.rawValue, "50")

        GiphyEmojiURLProtocol.handler = { request in
            (
                Self.response(for: request, status: 200),
                Data("""
                {
                  "data": [\(Self.emojiObject(id: "overflow"))],
                  "pagination": {"count":\(Int.max)},
                  "meta": {"status":200,"msg":"OK","response_id":"fixture"}
                }
                """.utf8)
            )
        }
        let overflow = try await client.search(
            query: "",
            cursor: PhotoSourceCursor(rawValue: String(Int32.max)),
            pageSize: 1
        )
        XCTAssertNil(overflow.nextCursor)
    }

    /// `/v2/emoji` 会混合 emoji 与 sticker；同时保留对旧 gif 类型的兼容。
    func testAcceptsEmojiStickerAndLegacyGifTypes() async throws {
        GiphyEmojiURLProtocol.handler = { request in
            let data = [
                Self.emojiObject(id: "emoji-type", type: "emoji"),
                Self.emojiObject(id: "sticker-type", type: "sticker"),
                Self.emojiObject(id: "gif-type", type: "gif"),
                Self.emojiObject(id: "video-type", type: "video")
            ].joined(separator: ",")
            return (
                Self.response(for: request, status: 200),
                Self.envelope(data: "[\(data)]", offset: 4, totalCount: 4, count: 4)
            )
        }

        let page = try await makeClient().search(query: "", cursor: nil, pageSize: 20)

        XCTAssertEqual(
            page.records.map(\.id),
            ["emoji-type", "sticker-type", "gif-type"].map(StableImageID.giphy(id:))
        )
    }

    /// 所有页面、媒体和用户 URL 都要独立检查 HTTPS 与 GIPHY host。
    func testFiltersNonGiphyAndInsecureURLsWithoutTrustingLookalikeHosts() async throws {
        GiphyEmojiURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Self.hostFilteringFixture)
        }

        let page = try await makeClient().search(query: "ignored", cursor: nil, pageSize: 20)
        let record = try XCTUnwrap(page.records.first)

        XCTAssertEqual(page.records.map(\.id), [StableImageID.giphy(id: "safe")])
        XCTAssertEqual(record.imageURL.host, "media.giphy.com")
        XCTAssertEqual(record.thumbnailURL.host, "media3.giphy.com")
        XCTAssertNil(record.sourcePageURL)
        XCTAssertEqual(record.creator, "Safe Artist")
        XCTAssertNil(record.creatorURL)
    }

    func testRejectsInvalidCursorAndMissingCredentialBeforeLoading() async {
        GiphyEmojiURLProtocol.handler = { request in
            XCTFail("本地验证失败不应发起请求：\(String(describing: request.url))")
            return (URLResponse(), Data())
        }

        do {
            _ = try await makeClient(apiKey: "   ").search(query: "ignored", cursor: nil, pageSize: 20)
            XCTFail("空 Key 应被拒绝")
        } catch {
            XCTAssertEqual(error as? GiphyEmojiError, .invalidCredential)
        }

        for rawCursor in ["-1", "01", "+1", "not-an-offset", String(Int64(Int32.max) + 1)] {
            do {
                _ = try await makeClient().search(
                    query: "ignored",
                    cursor: PhotoSourceCursor(rawValue: rawCursor),
                    pageSize: 20
                )
                XCTFail("非法游标 \(rawCursor) 应被拒绝")
            } catch {
                XCTAssertEqual(error as? GiphyEmojiError, .invalidCursor)
            }
        }
    }

    /// HTTP 的 401/403 不应进入解码，统一转为凭据错误。
    func testHTTPAuthenticationStatusesMapToInvalidCredential() async {
        for status in [401, 403] {
            GiphyEmojiURLProtocol.handler = { request in
                (Self.response(for: request, status: status), Data("secret response".utf8))
            }

            do {
                _ = try await makeClient().search(query: "ignored", cursor: nil, pageSize: 20)
                XCTFail("HTTP \(status) 应返回凭据错误")
            } catch {
                XCTAssertEqual(error as? GiphyEmojiError, .invalidCredential)
            }
        }
    }

    /// GIPHY 在 2xx 正文中仍声明 meta.status，必须与 HTTP 状态一样严格处理。
    func testMetaStatusesMapToTypedFailures() async {
        for status in [401, 403] {
            GiphyEmojiURLProtocol.handler = { request in
                (
                    Self.response(for: request, status: 200),
                    Self.envelope(data: "[]", offset: 0, totalCount: 0, count: 0, metaStatus: status)
                )
            }
            do {
                _ = try await makeClient().search(query: "ignored", cursor: nil, pageSize: 20)
                XCTFail("meta.status \(status) 应返回凭据错误")
            } catch {
                XCTAssertEqual(error as? GiphyEmojiError, .invalidCredential)
            }
        }

        GiphyEmojiURLProtocol.handler = { request in
            (
                Self.response(for: request, status: 200),
                Self.envelope(data: "[]", offset: 0, totalCount: 0, count: 0, metaStatus: 503)
            )
        }
        do {
            _ = try await makeClient().search(query: "ignored", cursor: nil, pageSize: 20)
            XCTFail("meta.status 503 应返回响应错误")
        } catch {
            XCTAssertEqual(error as? GiphyEmojiError, .invalidResponse(statusCode: 503))
        }
    }

    /// HTTP 或 meta 的 429 都要把 Retry-After 秒数映射到统一失败模型。
    func testRateLimitUsesRetryAfterForHTTPAndMetaStatuses() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for transportStatus in [429, 200] {
            GiphyEmojiURLProtocol.handler = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: transportStatus,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "9"]
                )!
                let data = transportStatus == 200
                    ? Self.envelope(
                        data: "[]",
                        offset: 0,
                        totalCount: 0,
                        count: 0,
                        metaStatus: 429
                    )
                    : Data()
                return (response, data)
            }

            do {
                _ = try await makeClient(now: now).search(
                    query: "ignored",
                    cursor: nil,
                    pageSize: 20
                )
                XCTFail("限流响应应抛出错误")
            } catch {
                let expected = now.addingTimeInterval(9)
                XCTAssertEqual(error as? GiphyEmojiError, .rateLimited(retryAt: expected))
                guard let failure = error as? any PhotoSourceFailure else {
                    return XCTFail("GIPHY 错误必须符合 PhotoSourceFailure")
                }
                XCTAssertEqual(failure.sourceID, .giphy)
                XCTAssertEqual(failure.issueKind, .rateLimited)
                XCTAssertEqual(failure.retryAt, expected)
            }
        }
    }

    /// Retry-After 缺失或非法时仍使用 GIPHY 策略的一小时退避，不能退化成立即重试。
    func testRateLimitUsesPolicyFallbackWhenRetryAfterIsMissingOrInvalid() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(transportStatus: Int, retryAfter: String?)] = [
            (429, nil),
            (200, "not-a-retry-date")
        ]

        for testCase in cases {
            GiphyEmojiURLProtocol.handler = { request in
                let headers = testCase.retryAfter.map { ["Retry-After": $0] }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: testCase.transportStatus,
                    httpVersion: nil,
                    headerFields: headers
                )!
                let data = testCase.transportStatus == 200
                    ? Self.envelope(
                        data: "[]",
                        offset: 0,
                        totalCount: 0,
                        count: 0,
                        metaStatus: 429
                    )
                    : Data()
                return (response, data)
            }

            do {
                _ = try await makeClient(now: now).search(
                    query: "ignored",
                    cursor: nil,
                    pageSize: 20
                )
                XCTFail("限流响应应抛出错误")
            } catch {
                let expected = now.addingTimeInterval(
                    PhotoSourceRequestPolicies.policy(for: .giphy).rateLimitFallback
                )
                XCTAssertEqual(error as? GiphyEmojiError, .rateLimited(retryAt: expected))
            }
        }
    }

    /// 非 HTTP 的合成 URLResponse 不能被当成成功响应。
    func testSyntheticNonHTTPResponseIsRejected() async {
        GiphyEmojiURLProtocol.handler = { request in
            (
                URLResponse(
                    url: request.url!,
                    mimeType: "application/json",
                    expectedContentLength: 0,
                    textEncodingName: nil
                ),
                Self.envelope(data: "[]", offset: 0, totalCount: 0, count: 0)
            )
        }

        do {
            _ = try await makeClient().search(query: "ignored", cursor: nil, pageSize: 20)
            XCTFail("非 HTTP 响应应被拒绝")
        } catch {
            XCTAssertEqual(error as? GiphyEmojiError, .invalidResponse(statusCode: 0))
        }
    }

    /// HTTP/meta 都声称成功时，空 data 必须有 GIPHY response_id 才是可信的真实空页。
    func testSyntheticEmptySuccessWithoutResponseIDIsRejected() async {
        GiphyEmojiURLProtocol.handler = { request in
            (
                Self.response(for: request, status: 200),
                Data(#"""
                {
                  "data": [],
                  "pagination": {"offset": 0, "total_count": 0, "count": 0},
                  "meta": {"status": 200, "msg": "OK", "response_id": "  "}
                }
                """#.utf8)
            )
        }

        do {
            _ = try await makeClient().search(query: "ignored", cursor: nil, pageSize: 20)
            XCTFail("缺少 response_id 的空成功响应应被拒绝")
        } catch {
            XCTAssertEqual(error as? GiphyEmojiError, .invalidResponse(statusCode: 200))
        }
    }

    /// 解码、HTTP 和底层网络错误必须可区分，且不得回显 Key、完整 URL 或正文。
    func testFailuresAreDistinctAndNeverLeakAPIKey() async {
        let secret = "never-print-this-giphy-key"

        GiphyEmojiURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Data("not-json \(secret)".utf8))
        }
        await assertFailure(
            client: makeClient(apiKey: secret),
            expectedError: .decoding("响应格式无效"),
            secret: secret
        )

        GiphyEmojiURLProtocol.handler = { request in
            (Self.response(for: request, status: 502), Data("upstream \(secret)".utf8))
        }
        await assertFailure(
            client: makeClient(apiKey: secret),
            expectedError: .invalidResponse(statusCode: 502),
            secret: secret
        )

        GiphyEmojiURLProtocol.handler = { request in
            let failingURL = URL(
                string: "https://api.giphy.com/v2/emoji?api_key=\(secret)&limit=20&offset=0"
            )!
            throw URLError(
                .timedOut,
                userInfo: [NSURLErrorFailingURLErrorKey: failingURL]
            )
        }
        do {
            _ = try await makeClient(apiKey: secret).search(
                query: "ignored",
                cursor: nil,
                pageSize: 20
            )
            XCTFail("网络错误应抛出错误")
        } catch {
            guard case .network = error as? GiphyEmojiError else {
                return XCTFail("网络错误分类不正确：\(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains(secret))
            XCTAssertFalse(error.localizedDescription.contains("api.giphy.com/v2/emoji"))
            XCTAssertFalse(error.localizedDescription.contains("api_key"))
        }
    }

    /// URLSession 自身的 cancelled 不等于调用方取消 Swift Task，必须形成可见网络错误。
    func testTransportCancellationWithoutTaskCancellationIsNetworkFailure() async {
        GiphyEmojiURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }

        do {
            _ = try await makeClient().search(query: "", cursor: nil, pageSize: 20)
            XCTFail("传输层中断应抛出网络错误")
        } catch {
            guard case .network = error as? GiphyEmojiError else {
                return XCTFail("传输层中断不应被误判为调用方取消：\(error)")
            }
        }
    }

    private func assertFailure(
        client: GiphyEmojiClient,
        expectedError: GiphyEmojiError,
        secret: String
    ) async {
        do {
            _ = try await client.search(query: "ignored", cursor: nil, pageSize: 20)
            XCTFail("请求应抛出错误")
        } catch {
            XCTAssertEqual(error as? GiphyEmojiError, expectedError)
            XCTAssertFalse(error.localizedDescription.contains(secret))
            XCTAssertFalse(error.localizedDescription.contains("api.giphy.com/v2/emoji"))
            XCTAssertFalse(error.localizedDescription.contains("api_key"))
        }
    }

    private func makeClient(
        apiKey: String = "test-key",
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> GiphyEmojiClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GiphyEmojiURLProtocol.self]
        configuration.urlCache = nil
        return GiphyEmojiClient(
            apiKey: apiKey,
            session: URLSession(configuration: configuration),
            now: { now }
        )
    }

    private static func queryValues(for request: URLRequest) throws -> [String: String] {
        let components = URLComponents(
            url: try XCTUnwrap(request.url),
            resolvingAgainstBaseURL: false
        )
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func envelope(
        data: String,
        offset: Int,
        totalCount: Int,
        count: Int,
        nextCursor: Int? = nil,
        metaStatus: Int = 200
    ) -> Data {
        let nextCursorField = nextCursor.map { ",\n            \"next_cursor\": \($0)" } ?? ""
        return Data("""
        {
          "data": \(data),
          "pagination": {
            "offset": \(offset),
            "total_count": \(totalCount),
            "count": \(count)\(nextCursorField)
          },
          "meta": {
            "status": \(metaStatus),
            "msg": "synthetic response",
            "response_id": "fixture"
          }
        }
        """.utf8)
    }

    private static func emojiObject(id: String, type: String = "emoji") -> String {
        """
        {
          "type": "\(type)",
          "id": "\(id)",
          "title": "\(id)",
          "images": {
            "fixed_width": {"url": "https://media1.giphy.com/media/\(id)/200w.gif"},
            "original": {"url": "https://media1.giphy.com/media/\(id)/giphy.gif"}
          }
        }
        """
    }

    private static let mappingFixture = Data(#"""
    {
      "data": [
        {
          "type": "gif",
          "id": "emoji123",
          "url": "https://giphy.com/gifs/party-emoji123?utm_source=mirage",
          "username": "fallback-user",
          "title": "  Party Blob Emoji  ",
          "alt_text": "A colorful blob celebrates",
          "images": {
            "fixed_width": {
              "url": "https://media1.giphy.com/media/emoji123/200w.gif?cid=client-id&rid=200w.gif&ct=s",
              "width": "200",
              "height": "200"
            },
            "fixed_height": {
              "url": "https://media1.giphy.com/media/emoji123/200.gif?cid=client-id&rid=200.gif&ct=s",
              "width": "200",
              "height": "200"
            },
            "original": {
              "url": "https://media2.giphy.com/media/emoji123/giphy.gif?cid=client-id&rid=giphy.gif&ct=s",
              "width": "480",
              "height": "480",
              "size": "345678"
            }
          },
          "user": {
            "username": "emoji-artist",
            "display_name": "  Emoji Artist  ",
            "profile_url": "https://giphy.com/creators/emoji-artist/?utm_source=mirage"
          }
        }
      ],
      "pagination": {"offset": 3, "total_count": 30, "count": 3, "next_cursor": 23},
      "meta": {"status": 200, "msg": "OK", "response_id": "fixture"}
    }
    """#.utf8)

    private static let renditionFallbackFixture = Data(#"""
    {
      "data": [
        {
          "type": "gif",
          "id": "fallback-height",
          "title": "Height fallback",
          "images": {
            "fixed_width": {"url": "https://evil.example/200w.gif"},
            "fixed_height": {"url": "https://media4.giphy.com/media/fallback-height/200.gif?rid=200.gif"},
            "original": {"url": "https://media.giphy.com/media/fallback-height/giphy.gif?rid=giphy.gif"}
          }
        },
        {
          "type": "gif",
          "id": "fallback-original",
          "title": "Original fallback",
          "images": {
            "fixed_width": null,
            "original": {"url": "https://media0.giphy.com/media/fallback-original/giphy.gif?rid=giphy.gif"}
          }
        }
      ],
      "pagination": {"offset": 0, "total_count": 2, "count": 2},
      "meta": {"status": 200, "msg": "OK", "response_id": "fixture"}
    }
    """#.utf8)

    private static let hostFilteringFixture = Data(#"""
    {
      "data": [
        {
          "type": "gif",
          "id": "lookalike",
          "images": {
            "fixed_width": {"url": "https://media1.giphy.com/media/lookalike/200w.gif"},
            "original": {"url": "https://media1.giphy.com.evil.example/media/lookalike/giphy.gif"}
          }
        },
        {
          "type": "gif",
          "id": "insecure",
          "images": {
            "fixed_width": {"url": "https://media2.giphy.com/media/insecure/200w.gif"},
            "original": {"url": "http://media2.giphy.com/media/insecure/giphy.gif"}
          }
        },
        {
          "type": "video",
          "id": "wrong-type",
          "images": {
            "fixed_width": {"url": "https://media2.giphy.com/media/wrong/200w.gif"},
            "original": {"url": "https://media2.giphy.com/media/wrong/giphy.gif"}
          }
        },
        {
          "type": "gif",
          "id": "safe",
          "url": "https://giphy.com.evil.example/gifs/safe",
          "title": "Safe",
          "images": {
            "fixed_width": {"url": "https://evil.example/media/safe/200w.gif"},
            "fixed_height": {"url": "https://media3.giphy.com/media/safe/200.gif?rid=200.gif"},
            "original": {"url": "https://media.giphy.com/media/safe/giphy.gif?rid=giphy.gif"}
          },
          "user": {
            "username": "safe-artist",
            "display_name": "Safe Artist",
            "profile_url": "https://attacker@giphy.com/safe-artist/"
          }
        }
      ],
      "pagination": {"offset": 0, "total_count": 4, "count": 4},
      "meta": {"status": 200, "msg": "OK", "response_id": "fixture"}
    }
    """#.utf8)
}

private final class GiphyEmojiURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (URLResponse, Data))?

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
