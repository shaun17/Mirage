import Foundation
import XCTest
@testable import MirageCore

final class GiphyCatalogClientTests: XCTestCase {
    override func tearDown() {
        GiphyCatalogURLProtocol.handler = nil
        super.tearDown()
    }

    /// 40 条总配额不会被每个 endpoint 分别放大；余数按页在 Emoji、GIF、Sticker 间轮转。
    func testAllocatesOneTotalQuotaRotatesRemainderAndKeepsIndependentCursors() async throws {
        let script = CatalogScript(steps: [
            .emoji: [
                .success(ids: ["e0", "shared", "e2"], nextCursor: "10"),
                .success(ids: ["e3"], nextCursor: "11"),
                .success(ids: ["e4"], nextCursor: nil)
            ],
            .gif: [
                .success(ids: ["g0", "shared", "g2"], nextCursor: "20"),
                .success(ids: ["g3"], nextCursor: "21"),
                .success(ids: ["g4"], nextCursor: nil)
            ],
            .sticker: [
                .success(ids: ["s0", "s1"], nextCursor: "30"),
                .success(ids: ["s3"], nextCursor: "31"),
                .success(ids: ["s4"], nextCursor: nil)
            ]
        ])
        let client = makeClient(script: script)

        let first = try await client.search(query: "", cursor: nil, pageSize: 999)
        XCTAssertEqual(first.records.map(\.id), ["e0", "g0", "s0", "shared", "s1", "e2", "g2"])
        let firstCursor = try XCTUnwrap(first.nextCursor)
        XCTAssertTrue(firstCursor.rawValue.hasPrefix("gm1:"))
        XCTAssertLessThanOrEqual(firstCursor.rawValue.utf8.count, 1_024)
        XCTAssertFalse(firstCursor.rawValue.contains("http"))
        XCTAssertFalse(firstCursor.rawValue.contains("api_key"))

        let second = try await client.search(query: "", cursor: firstCursor, pageSize: 40)
        let secondCursor = try XCTUnwrap(second.nextCursor)
        _ = try await client.search(query: "", cursor: secondCursor, pageSize: 40)

        let calls = await script.invocations()
        let callsByFeed = Dictionary(grouping: calls, by: \.feed)
        XCTAssertEqual(callsByFeed[.emoji]?.map(\.pageSize), [14, 13, 13])
        XCTAssertEqual(callsByFeed[.gif]?.map(\.pageSize), [13, 14, 13])
        XCTAssertEqual(callsByFeed[.sticker]?.map(\.pageSize), [13, 13, 14])
        XCTAssertEqual(callsByFeed[.emoji]?.map(\.cursor), [nil, "10", "11"])
        XCTAssertEqual(callsByFeed[.gif]?.map(\.cursor), [nil, "20", "21"])
        XCTAssertEqual(callsByFeed[.sticker]?.map(\.cursor), [nil, "30", "31"])
    }

    /// 关键词模式只分配 GIF 与 Sticker，并使用独立游标，不能误接到空查询混合目录。
    func testKeywordSearchUsesTwoFeedsAndKeepsSearchCursorIsolated() async throws {
        let script = CatalogScript(steps: [
            .gif: [
                .success(ids: ["g0"], nextCursor: "20"),
                .success(ids: ["g1"], nextCursor: nil)
            ],
            .sticker: [
                .success(ids: ["s0"], nextCursor: "20"),
                .success(ids: ["s1"], nextCursor: nil)
            ]
        ])
        let client = GiphyCatalogClient(
            emoji: UnexpectedCatalogFeed(),
            gifTrending: UnexpectedCatalogFeed(),
            stickerTrending: UnexpectedCatalogFeed(),
            gifSearch: ScriptedCatalogFeed(feed: .gif, script: script),
            stickerSearch: ScriptedCatalogFeed(feed: .sticker, script: script)
        )

        let first = try await client.search(query: "cat", cursor: nil, pageSize: 40)
        let firstCursor = try XCTUnwrap(first.nextCursor)
        XCTAssertEqual(first.records.map(\.id), ["g0", "s0"])
        XCTAssertTrue(firstCursor.rawValue.hasPrefix("gs1:"))

        do {
            _ = try await client.search(query: "", cursor: firstCursor, pageSize: 40)
            XCTFail("关键词游标不应进入空查询混合目录")
        } catch let error as GiphyCatalogError {
            XCTAssertEqual(error, .invalidCursor)
        }

        let second = try await client.search(query: "cat", cursor: firstCursor, pageSize: 40)
        XCTAssertEqual(second.records.map(\.id), ["g1", "s1"])
        XCTAssertNil(second.nextCursor)

        let callsByFeed = Dictionary(grouping: await script.invocations(), by: \.feed)
        XCTAssertNil(callsByFeed[.emoji])
        XCTAssertEqual(callsByFeed[.gif]?.map(\.pageSize), [20, 20])
        XCTAssertEqual(callsByFeed[.sticker]?.map(\.pageSize), [20, 20])
        XCTAssertEqual(callsByFeed[.gif]?.map(\.cursor), [nil, "20"])
        XCTAssertEqual(callsByFeed[.sticker]?.map(\.cursor), [nil, "20"])
    }

    /// 三路供应都充足时首屏必须实际交付 40 条，而不只是把请求配额相加为 40。
    func testFullFirstPageReturnsFortyUniqueMixedRecords() async throws {
        let emojiIDs = (0..<14).map { "e\($0)" }
        let gifIDs = (0..<13).map { "g\($0)" }
        let stickerIDs = (0..<13).map { "s\($0)" }
        let script = CatalogScript(steps: [
            .emoji: [.success(ids: emojiIDs, nextCursor: "14")],
            .gif: [.success(ids: gifIDs, nextCursor: "13")],
            .sticker: [.success(ids: stickerIDs, nextCursor: "13")]
        ])

        let page = try await makeClient(script: script).search(
            query: "",
            cursor: nil,
            pageSize: 40
        )

        XCTAssertEqual(page.records.count, 40)
        XCTAssertEqual(Set(page.records.map(\.id)).count, 40)
        XCTAssertEqual(
            Array(page.records.map(\.id).prefix(6)),
            ["e0", "g0", "s0", "e1", "g1", "s1"]
        )
        XCTAssertEqual(page.records.last?.id, "e13")
    }

    /// Emoji 耗尽后不再请求，下一页的 40 条配额完整重分给仍活跃的 GIF 与 Sticker。
    func testExhaustedFeedRedistributesQuotaAcrossRemainingFeeds() async throws {
        let script = CatalogScript(steps: [
            .emoji: [.success(ids: ["e0"], nextCursor: nil)],
            .gif: [
                .success(ids: ["g0"], nextCursor: "100"),
                .success(ids: ["g1"], nextCursor: nil)
            ],
            .sticker: [
                .success(ids: ["s0"], nextCursor: "200"),
                .success(ids: ["s1"], nextCursor: nil)
            ]
        ])
        let client = makeClient(script: script)

        let first = try await client.search(query: "", cursor: nil, pageSize: 40)
        let second = try await client.search(
            query: "",
            cursor: try XCTUnwrap(first.nextCursor),
            pageSize: 40
        )

        XCTAssertEqual(second.records.map(\.id), ["g1", "s1"])
        XCTAssertNil(second.nextCursor)
        let calls = await script.invocations()
        let callsByFeed = Dictionary(grouping: calls, by: \.feed)
        XCTAssertEqual(callsByFeed[.emoji]?.map(\.pageSize), [14])
        XCTAssertEqual(callsByFeed[.gif]?.map(\.pageSize), [13, 20])
        XCTAssertEqual(callsByFeed[.sticker]?.map(\.pageSize), [13, 20])
        XCTAssertEqual(callsByFeed[.gif]?.map(\.cursor), [nil, "100"])
        XCTAssertEqual(callsByFeed[.sticker]?.map(\.cursor), [nil, "200"])
    }

    /// Trending 的最后合法请求位置是 499；服务端推进到 500 时该流应正常耗尽且不再请求。
    func testTrendingOffsetBeyond499ExhaustsFeedWithoutRequestingOffset500() async throws {
        let script = CatalogScript(steps: [
            .emoji: [
                .success(ids: ["e0"], nextCursor: "10"),
                .success(ids: ["e1"], nextCursor: "20"),
                .success(ids: ["e2"], nextCursor: nil)
            ],
            .gif: [
                .success(ids: ["g0"], nextCursor: "499"),
                .success(ids: ["g1"], nextCursor: "500")
            ],
            .sticker: [
                .success(ids: ["s0"], nextCursor: "30"),
                .success(ids: ["s1"], nextCursor: "40"),
                .success(ids: ["s2"], nextCursor: nil)
            ]
        ])
        let client = makeClient(script: script)

        let first = try await client.search(query: "", cursor: nil, pageSize: 40)
        let second = try await client.search(
            query: "",
            cursor: try XCTUnwrap(first.nextCursor),
            pageSize: 40
        )
        let third = try await client.search(
            query: "",
            cursor: try XCTUnwrap(second.nextCursor),
            pageSize: 40
        )

        XCTAssertEqual(third.records.map(\.id), ["e2", "s2"])
        XCTAssertNil(third.nextCursor)
        let callsByFeed = Dictionary(grouping: await script.invocations(), by: \.feed)
        XCTAssertEqual(callsByFeed[.gif]?.map(\.cursor), [nil, "499"])
        XCTAssertEqual(callsByFeed[.gif]?.map(\.pageSize), [13, 14])
        XCTAssertEqual(callsByFeed[.emoji]?.map(\.pageSize), [14, 13, 20])
        XCTAssertEqual(callsByFeed[.sticker]?.map(\.pageSize), [13, 13, 20])
    }

    /// 子流并发读取；单流失败不丢弃其他结果，也不推进失败流自己的 cursor。
    func testPartialFailureReturnsSuccessfulFeedsPreservesFailedCursorAndIssue() async throws {
        let retryAt = Date(timeIntervalSinceReferenceDate: 500)
        let probe = CatalogConcurrencyProbe()
        let client = GiphyCatalogClient(
            emoji: ConcurrentCatalogFeed(
                feed: .emoji,
                outcome: .success(ids: ["e0"], nextCursor: "10"),
                probe: probe
            ),
            gifTrending: ConcurrentCatalogFeed(
                feed: .gif,
                outcome: .failure(CatalogTestFailure(kind: .network, retryAt: retryAt)),
                probe: probe
            ),
            stickerTrending: ConcurrentCatalogFeed(
                feed: .sticker,
                outcome: .success(ids: ["s0"], nextCursor: "30"),
                probe: probe
            )
        )

        let first = try await client.search(query: "", cursor: nil, pageSize: 40)
        XCTAssertEqual(first.records.map(\.id), ["e0", "s0"])
        XCTAssertEqual(first.issues.count, 1)
        XCTAssertEqual(first.issues[0].sourceID, .giphy)
        XCTAssertEqual(first.issues[0].kind, .network)
        XCTAssertEqual(first.issues[0].retryAt, retryAt)
        XCTAssertTrue(first.issues[0].message.contains("GIF"))
        let maximumConcurrency = await probe.maximumConcurrentRequests()
        XCTAssertEqual(maximumConcurrency, 3)

        _ = try await client.search(
            query: "",
            cursor: try XCTUnwrap(first.nextCursor),
            pageSize: 40
        )
        let calls = await probe.invocations()
        let callsByFeed = Dictionary(grouping: calls, by: \.feed)
        XCTAssertEqual(callsByFeed[.emoji]?.last?.cursor, "10")
        XCTAssertNil(callsByFeed[.gif]?.last?.cursor)
        XCTAssertEqual(callsByFeed[.sticker]?.last?.cursor, "30")
        XCTAssertEqual(callsByFeed[.emoji]?.last?.pageSize, 13)
        XCTAssertEqual(callsByFeed[.gif]?.last?.pageSize, 14)
        XCTAssertEqual(callsByFeed[.sticker]?.last?.pageSize, 13)
    }

    /// 多个内部子流故障只向 UI 暴露一个 GIPHY issue，并合并子流名和重试时间。
    func testMultipleFeedFailuresConsolidateIntoOneIssue() async throws {
        let earlyRetry = Date(timeIntervalSinceReferenceDate: 100)
        let lateRetry = Date(timeIntervalSinceReferenceDate: 200)
        let script = CatalogScript(steps: [
            .emoji: [.success(ids: ["e"], nextCursor: "1")],
            .gif: [.failure(CatalogTestFailure(kind: .network, retryAt: earlyRetry))],
            .sticker: [.failure(CatalogTestFailure(kind: .rateLimited, retryAt: lateRetry))]
        ])

        let page = try await makeClient(script: script).search(
            query: "",
            cursor: nil,
            pageSize: 40
        )

        XCTAssertEqual(page.records.map(\.id), ["e"])
        XCTAssertEqual(page.issues.count, 1)
        XCTAssertEqual(page.issues[0].sourceID, .giphy)
        XCTAssertEqual(page.issues[0].kind, .rateLimited)
        XCTAssertEqual(page.issues[0].retryAt, lateRetry)
        XCTAssertTrue(page.issues[0].message.contains("GIF"))
        XCTAssertTrue(page.issues[0].message.contains("Sticker"))
    }

    /// 即使 GIF 最先完成、Emoji 最后完成，最终卡片仍按 Emoji、GIF、Sticker 稳定轮询。
    func testNetworkCompletionOrderDoesNotChangeCanonicalInterleaving() async throws {
        let probe = CatalogConcurrencyProbe()
        let client = GiphyCatalogClient(
            emoji: ConcurrentCatalogFeed(
                feed: .emoji,
                outcome: .success(ids: ["e0", "e1"], nextCursor: nil),
                probe: probe,
                delay: .milliseconds(90)
            ),
            gifTrending: ConcurrentCatalogFeed(
                feed: .gif,
                outcome: .success(ids: ["g0", "g1"], nextCursor: nil),
                probe: probe,
                delay: .milliseconds(10)
            ),
            stickerTrending: ConcurrentCatalogFeed(
                feed: .sticker,
                outcome: .success(ids: ["s0", "s1"], nextCursor: nil),
                probe: probe,
                delay: .milliseconds(50)
            )
        )

        let page = try await client.search(query: "", cursor: nil, pageSize: 40)

        XCTAssertEqual(page.records.map(\.id), ["e0", "g0", "s0", "e1", "g1", "s1"])
        let completionOrder = await probe.completionOrder()
        XCTAssertEqual(completionOrder, [.gif, .sticker, .emoji])
    }

    /// 没有任何可提交子流时抛出最具体的类型化错误，而不是制造空成功页。
    func testAllFeedsFailThrowsMostSpecificError() async throws {
        let probe = CatalogConcurrencyProbe()
        let client = GiphyCatalogClient(
            emoji: ConcurrentCatalogFeed(
                feed: .emoji,
                outcome: .failure(CatalogTestFailure(kind: .network)),
                probe: probe
            ),
            gifTrending: ConcurrentCatalogFeed(
                feed: .gif,
                outcome: .failure(CatalogTestFailure(kind: .invalidCredential)),
                probe: probe
            ),
            stickerTrending: ConcurrentCatalogFeed(
                feed: .sticker,
                outcome: .failure(CatalogTestFailure(kind: .invalidResponse)),
                probe: probe
            )
        )

        do {
            _ = try await client.search(query: "", cursor: nil, pageSize: 40)
            XCTFail("全部子流失败时不应返回页面")
        } catch let error as CatalogTestFailure {
            XCTAssertEqual(error.kind, .invalidCredential)
        } catch {
            XCTFail("应保留最具体的原始错误类型，实际为：\(type(of: error))")
        }
    }

    /// 三路共用一把 API Key；任一路认证失败都必须让整个目录失败，不能返回其他流的局部页面。
    func testCredentialFailureAbortsOtherwiseSuccessfulCatalogPage() async throws {
        let script = CatalogScript(steps: [
            .emoji: [.success(ids: ["e"], nextCursor: "1")],
            .gif: [.failure(CatalogTestFailure(kind: .invalidCredential))],
            .sticker: [.success(ids: ["s"], nextCursor: "1")]
        ])

        do {
            _ = try await makeClient(script: script).search(
                query: "",
                cursor: nil,
                pageSize: 40
            )
            XCTFail("共享 Key 的任一认证失败都不应降级为局部成功")
        } catch let error as CatalogTestFailure {
            XCTAssertEqual(error.kind, .invalidCredential)
        } catch {
            XCTFail("应保留认证失败类型，实际为：\(type(of: error))")
        }
    }

    /// 任一子流取消都代表整次搜索已取消，不能降级成普通 issue。
    func testCancellationAlwaysCancelsWholeCatalogRequest() async throws {
        let probe = CatalogConcurrencyProbe()
        let client = GiphyCatalogClient(
            emoji: ConcurrentCatalogFeed(
                feed: .emoji,
                outcome: .success(ids: ["e"], nextCursor: "1"),
                probe: probe
            ),
            gifTrending: ConcurrentCatalogFeed(feed: .gif, outcome: .cancelled, probe: probe),
            stickerTrending: ConcurrentCatalogFeed(
                feed: .sticker,
                outcome: .success(ids: ["s"], nextCursor: "1"),
                probe: probe
            )
        )

        do {
            _ = try await client.search(query: "", cursor: nil, pageSize: 40)
            XCTFail("取消不应返回部分页面")
        } catch is CancellationError {
            // expected
        }
    }

    /// 复合游标拒绝未知版本、非规范 base64、损坏 schema、URL 子游标及超长输入。
    func testRejectsMalformedUnknownAndOversizedCompositeCursors() async throws {
        let client = GiphyCatalogClient(
            emoji: UnexpectedCatalogFeed(),
            gifTrending: UnexpectedCatalogFeed(),
            stickerTrending: UnexpectedCatalogFeed()
        )
        let malformedPayload = Self.base64URL(Data("not-json".utf8))
        let urlPayload = Self.base64URL(Data(#"{"p":1,"f":[{"k":"e","c":"https://api.giphy.com/?api_key=secret","x":false},{"k":"g","x":false},{"k":"s","x":false}]}"#.utf8))
        let wrongOrderPayload = Self.base64URL(Data(#"{"p":1,"f":[{"k":"g","x":false},{"k":"e","x":false},{"k":"s","x":false}]}"#.utf8))
        let trendingOffsetPayload = Self.base64URL(Data(#"{"p":1,"f":[{"k":"e","x":false},{"k":"g","c":"500","x":false},{"k":"s","x":false}]}"#.utf8))
        let cursors = [
            PhotoSourceCursor(rawValue: "gm2:\(malformedPayload)"),
            PhotoSourceCursor(rawValue: "gm1:not*base64"),
            PhotoSourceCursor(rawValue: "gm1:\(malformedPayload)"),
            PhotoSourceCursor(rawValue: "gm1:\(urlPayload)"),
            PhotoSourceCursor(rawValue: "gm1:\(wrongOrderPayload)"),
            PhotoSourceCursor(rawValue: "gm1:\(trendingOffsetPayload)"),
            PhotoSourceCursor(rawValue: String(repeating: "x", count: 1_025))
        ]

        for cursor in cursors {
            do {
                _ = try await client.search(query: "", cursor: cursor, pageSize: 40)
                XCTFail("损坏游标不应发起请求")
            } catch let error as GiphyCatalogError {
                XCTAssertEqual(error, .invalidCursor)
            } catch {
                XCTFail("应统一报告 invalidCursor，实际为：\(type(of: error))")
            }
        }
    }

    /// 生产构造器固定使用三个官方 endpoint；Trending 只携带白名单 rating=g，Emoji 不携带 rating。
    func testProductionInitializerUsesThreeOfficialEndpointsAndRatingWhitelist() async throws {
        let recorder = GiphyRequestRecorder()
        GiphyCatalogURLProtocol.handler = { request in
            recorder.record(request)
            let path = try XCTUnwrap(request.url?.path)
            let (type, id): (String, String)
            switch path {
            case "/v2/emoji": (type, id) = ("emoji", "prod-e")
            case "/v1/gifs/trending": (type, id) = ("gif", "prod-g")
            case "/v1/stickers/trending": (type, id) = ("sticker", "prod-s")
            default: throw URLError(.badURL)
            }
            return (
                Self.response(for: request),
                Self.giphyEnvelope(type: type, id: id)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GiphyCatalogURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let page = try await GiphyCatalogClient(
            apiKey: "secret&key",
            session: session
        ).search(query: "", cursor: nil, pageSize: 40)

        XCTAssertEqual(page.records.map(\.id), [
            StableImageID.giphy(id: "prod-e"),
            StableImageID.giphy(id: "prod-g"),
            StableImageID.giphy(id: "prod-s")
        ])
        let requests = recorder.snapshot().sorted { ($0.url?.path ?? "") < ($1.url?.path ?? "") }
        XCTAssertEqual(requests.count, 3)
        let valuesByPath = try Dictionary(uniqueKeysWithValues: requests.map { request in
            let url = try XCTUnwrap(request.url)
            let values = Dictionary(uniqueKeysWithValues: (URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            return (url.path, values)
        })
        XCTAssertEqual(valuesByPath["/v2/emoji"]?["limit"], "14")
        XCTAssertNil(valuesByPath["/v2/emoji"]?["rating"])
        XCTAssertEqual(valuesByPath["/v1/gifs/trending"]?["limit"], "13")
        XCTAssertEqual(valuesByPath["/v1/gifs/trending"]?["rating"], "g")
        XCTAssertEqual(valuesByPath["/v1/stickers/trending"]?["limit"], "13")
        XCTAssertEqual(valuesByPath["/v1/stickers/trending"]?["rating"], "g")
        XCTAssertTrue(valuesByPath.values.allSatisfy { $0["api_key"] == "secret&key" })
        XCTAssertTrue(valuesByPath.values.allSatisfy { $0["offset"] == "0" })
    }

    /// 非空关键词只访问官方 GIF/Sticker Search，并把用户原始关键词放入 q 参数。
    func testProductionInitializerSearchesGIFAndStickerWithExactQuery() async throws {
        let recorder = GiphyRequestRecorder()
        GiphyCatalogURLProtocol.handler = { request in
            recorder.record(request)
            let path = try XCTUnwrap(request.url?.path)
            let (type, id): (String, String)
            switch path {
            case "/v1/gifs/search": (type, id) = ("gif", "search-g")
            case "/v1/stickers/search": (type, id) = ("sticker", "search-s")
            default: throw URLError(.badURL)
            }
            return (
                Self.response(for: request),
                Self.giphyEnvelope(type: type, id: id)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GiphyCatalogURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let page = try await GiphyCatalogClient(
            apiKey: "secret&key",
            session: session
        ).search(query: "  猫 & dog  ", cursor: nil, pageSize: 40)

        XCTAssertEqual(page.records.map(\.id), [
            StableImageID.giphy(id: "search-g"),
            StableImageID.giphy(id: "search-s")
        ])
        let requests = recorder.snapshot().sorted { ($0.url?.path ?? "") < ($1.url?.path ?? "") }
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let url = try XCTUnwrap(request.url)
            let values = Dictionary(uniqueKeysWithValues: (URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(values["api_key"], "secret&key")
            XCTAssertEqual(values["q"], "猫 & dog")
            XCTAssertEqual(values["rating"], "g")
            XCTAssertEqual(values["limit"], "20")
            XCTAssertEqual(values["offset"], "0")
        }
    }

    private func makeClient(script: CatalogScript) -> GiphyCatalogClient {
        GiphyCatalogClient(
            emoji: ScriptedCatalogFeed(feed: .emoji, script: script),
            gifTrending: ScriptedCatalogFeed(feed: .gif, script: script),
            stickerTrending: ScriptedCatalogFeed(feed: .sticker, script: script)
        )
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func response(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static func giphyEnvelope(type: String, id: String) -> Data {
        Data(#"{"data":[{"type":"\#(type)","id":"\#(id)","title":"\#(id)","images":{"fixed_width":{"url":"https://media1.giphy.com/media/\#(id)/200w.gif"},"original":{"url":"https://media1.giphy.com/media/\#(id)/giphy.gif"}}}],"pagination":{"total_count":1,"count":1,"offset":0},"meta":{"status":200,"msg":"OK","response_id":"fixture"}}"#.utf8)
    }
}

private enum CatalogTestFeed: String, Hashable, Sendable {
    case emoji
    case gif
    case sticker
}

private struct CatalogInvocation: Equatable, Sendable {
    let feed: CatalogTestFeed
    let cursor: String?
    let pageSize: Int
}

private enum CatalogStep: Sendable {
    case success(ids: [String], nextCursor: String?)
    case failure(CatalogTestFailure)
    case cancelled
}

private actor CatalogScript {
    private var steps: [CatalogTestFeed: [CatalogStep]]
    private var calls: [CatalogInvocation] = []

    init(steps: [CatalogTestFeed: [CatalogStep]]) {
        self.steps = steps
    }

    func request(
        feed: CatalogTestFeed,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) throws -> PhotoSourcePage {
        calls.append(CatalogInvocation(feed: feed, cursor: cursor?.rawValue, pageSize: pageSize))
        guard var feedSteps = steps[feed], !feedSteps.isEmpty else {
            throw CatalogTestFailure(kind: .unavailable)
        }
        let step = feedSteps.removeFirst()
        steps[feed] = feedSteps
        switch step {
        case let .success(ids, nextCursor):
            return PhotoSourcePage(
                records: ids.map(makeCatalogRecord),
                nextCursor: nextCursor.map(PhotoSourceCursor.init(rawValue:))
            )
        case let .failure(error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }

    func invocations() -> [CatalogInvocation] { calls }
}

private struct ScriptedCatalogFeed: PhotoSourceSearching {
    let sourceID = PhotoSourceID.giphy
    let feed: CatalogTestFeed
    let script: CatalogScript

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        try await script.request(feed: feed, cursor: cursor, pageSize: pageSize)
    }
}

private actor CatalogConcurrencyProbe {
    private var active = 0
    private var maximum = 0
    private var calls: [CatalogInvocation] = []
    private var completions: [CatalogTestFeed] = []

    func enter(_ invocation: CatalogInvocation) {
        calls.append(invocation)
        active += 1
        maximum = max(maximum, active)
    }

    func leave(_ feed: CatalogTestFeed) {
        active -= 1
        completions.append(feed)
    }
    func maximumConcurrentRequests() -> Int { maximum }
    func invocations() -> [CatalogInvocation] { calls }
    func completionOrder() -> [CatalogTestFeed] { completions }
}

private struct ConcurrentCatalogFeed: PhotoSourceSearching {
    let sourceID = PhotoSourceID.giphy
    let feed: CatalogTestFeed
    let outcome: CatalogStep
    let probe: CatalogConcurrencyProbe
    let delay: Duration

    init(
        feed: CatalogTestFeed,
        outcome: CatalogStep,
        probe: CatalogConcurrencyProbe,
        delay: Duration = .milliseconds(40)
    ) {
        self.feed = feed
        self.outcome = outcome
        self.probe = probe
        self.delay = delay
    }

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        await probe.enter(CatalogInvocation(feed: feed, cursor: cursor?.rawValue, pageSize: pageSize))
        do {
            try await Task.sleep(for: delay)
        } catch {
            await probe.leave(feed)
            throw CancellationError()
        }
        await probe.leave(feed)
        switch outcome {
        case let .success(ids, nextCursor):
            let advancingCursor: String?
            if let requested = cursor.flatMap({ Int($0.rawValue) }),
               let scripted = nextCursor.flatMap(Int.init),
               scripted <= requested {
                advancingCursor = String(requested + 1)
            } else {
                advancingCursor = nextCursor
            }
            return PhotoSourcePage(
                records: ids.map(makeCatalogRecord),
                nextCursor: advancingCursor.map(PhotoSourceCursor.init(rawValue:))
            )
        case let .failure(error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }
}

private struct CatalogTestFailure: Error, Equatable, Sendable, PhotoSourceFailure {
    let kind: PhotoSourceIssueKind
    let retryAt: Date?

    init(kind: PhotoSourceIssueKind, retryAt: Date? = nil) {
        self.kind = kind
        self.retryAt = retryAt
    }

    var sourceID: PhotoSourceID { .giphy }
    var issueKind: PhotoSourceIssueKind { kind }
}

private struct UnexpectedCatalogFeed: PhotoSourceSearching {
    let sourceID = PhotoSourceID.giphy

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        XCTFail("无效复合游标不得触发子请求")
        return PhotoSourcePage(records: [], nextCursor: nil)
    }
}

private func makeCatalogRecord(_ id: String) -> RemoteImageRecord {
    let url = URL(string: "https://media1.giphy.com/media/\(id)/giphy.gif")!
    return RemoteImageRecord(
        id: id,
        title: id,
        source: .giphy,
        imageURL: url,
        thumbnailURL: url,
        license: .giphy,
        mimeType: "image/gif"
    )
}

private final class GiphyRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func snapshot() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class GiphyCatalogURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
