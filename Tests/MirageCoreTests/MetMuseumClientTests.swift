import Foundation
import XCTest
@testable import MirageCore

final class MetMuseumClientTests: XCTestCase {
    /// 搜索请求必须使用官方参数；有效详情完整映射为稳定 ID、CC0 和 The Met 元数据。
    func testSearchRequestAndSuccessfulMapping() async throws {
        let client = makeClient { request in
            if request.url?.lastPathComponent == "search" {
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let queryItems = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                })
                XCTAssertEqual(queryItems["hasImages"], "true")
                XCTAssertEqual(queryItems["q"], "water lilies")
                XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
                return response(request, data: searchFixture(ids: [436535]))
            }

            XCTAssertEqual(request.url?.path, "/public/collection/v1/objects/436535")
            return response(
                request,
                data: objectFixture(
                    id: 436535,
                    title: "Water Lilies",
                    artist: "Claude Monet",
                    image: "https://images.metmuseum.org/CRDImages/ep/original/DT1567.jpg",
                    thumbnail: "https://images.metmuseum.org/CRDImages/ep/web-large/DT1567.jpg",
                    objectURL: "https://www.metmuseum.org/art/collection/search/436535"
                )
            )
        }

        let page = try await client.search(query: "water lilies", cursor: nil, pageSize: 12)

        let record = try XCTUnwrap(page.records.first)
        XCTAssertEqual(page.records.count, 1)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(record.id, "met:436535")
        XCTAssertEqual(record.title, "Water Lilies")
        XCTAssertEqual(record.source, .metMuseum)
        XCTAssertEqual(record.imageURL.absoluteString, "https://images.metmuseum.org/CRDImages/ep/original/DT1567.jpg")
        XCTAssertEqual(record.thumbnailURL.absoluteString, "https://images.metmuseum.org/CRDImages/ep/web-large/DT1567.jpg")
        XCTAssertEqual(record.sourcePageURL?.absoluteString, "https://www.metmuseum.org/art/collection/search/436535")
        XCTAssertEqual(record.creator, "Claude Monet")
        XCTAssertEqual(record.license, .cc0)
        XCTAssertEqual(record.mimeType, "image/jpeg")
    }

    /// `isPublicDomain` 必须明确为 true；私有版权对象即使有图片也不能进入结果。
    func testStrictlyFiltersNonPublicDomainObjects() async throws {
        let client = makeClient { request in
            guard let objectID = objectID(from: request) else {
                return response(request, data: searchFixture(ids: [11, 12]))
            }
            return response(
                request,
                data: objectFixture(id: objectID, isPublicDomain: objectID == 12)
            )
        }

        let page = try await client.search(query: "portrait", cursor: nil, pageSize: 2)

        XCTAssertEqual(page.records.map(\.id), ["met:12"])
    }

    /// 原图和缩略图必须同时是非空 HTTPS；任意一项为 HTTP 或空值都要丢弃。
    func testRequiresHTTPSForBothImageURLs() async throws {
        let client = makeClient { request in
            guard let objectID = objectID(from: request) else {
                return response(request, data: searchFixture(ids: [21, 22, 23, 24]))
            }
            switch objectID {
            case 21:
                return response(request, data: objectFixture(id: objectID, image: "http://images.example/21.jpg"))
            case 22:
                return response(request, data: objectFixture(id: objectID, thumbnail: "http://images.example/22.jpg"))
            case 23:
                return response(request, data: objectFixture(id: objectID, image: "   "))
            default:
                return response(
                    request,
                    data: objectFixture(
                        id: objectID,
                        objectURL: "http://www.metmuseum.org/art/collection/search/24"
                    )
                )
            }
        }

        let page = try await client.search(query: "landscape", cursor: nil, pageSize: 4)

        XCTAssertEqual(page.records.map(\.id), ["met:24"])
        XCTAssertNil(page.records.first?.sourcePageURL, "非 HTTPS 作品页不影响图片记录，但不能暴露为链接")
    }

    /// 官方无结果响应使用 `objectIDs: null`，此时不能发起任何详情请求或制造空游标。
    func testNullObjectIDsReturnsExhaustedEmptyPage() async throws {
        let log = RequestLog()
        let client = makeClient { request in
            await log.append(request.url?.path ?? "")
            guard request.url?.lastPathComponent == "search" else {
                XCTFail("null ID 列表不应请求详情")
                return response(request, status: 404, data: Data())
            }
            return response(request, data: searchFixture(ids: nil))
        }

        let page = try await client.search(query: "no result", cursor: nil, pageSize: 20)
        let requestedPaths = await log.paths()

        XCTAssertEqual(page.records, [])
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(requestedPaths, ["/public/collection/v1/search"])
    }

    /// 相同 ID 快照生成稳定游标；快照的内容或顺序变化后旧 offset 必须明确失效。
    func testCursorIsStableAndRejectsChangedIDSnapshot() async throws {
        let snapshots = IDSnapshotStore([31, 32, 33])
        let client = makeClient { request in
            guard let objectID = objectID(from: request) else {
                return response(request, data: searchFixture(ids: await snapshots.ids()))
            }
            return response(request, data: objectFixture(id: objectID))
        }

        let first = try await client.search(query: "secret query", cursor: nil, pageSize: 1)
        let repeated = try await client.search(query: "secret query", cursor: nil, pageSize: 1)
        let firstCursor = try XCTUnwrap(first.nextCursor)
        XCTAssertEqual(firstCursor, repeated.nextCursor)
        XCTAssertFalse(firstCursor.rawValue.contains("secret query"))
        XCTAssertFalse(firstCursor.rawValue.contains("31,32,33"))
        XCTAssertEqual(firstCursor.rawValue.split(separator: ".").count, 3)

        let second = try await client.search(query: "secret query", cursor: firstCursor, pageSize: 1)
        XCTAssertEqual(second.records.map(\.id), ["met:32"])

        await snapshots.replace(with: [31, 33, 32])
        do {
            _ = try await client.search(query: "secret query", cursor: firstCursor, pageSize: 1)
            XCTFail("ID 快照变化后应拒绝旧游标")
        } catch {
            XCTAssertEqual(error as? MetMuseumError, .invalidCursor)
        }
    }

    /// 并发完成顺序不能改变搜索顺序；404 和单条解码失败只跳过该详情。
    func testPreservesSearchOrderWhileSkippingPartialDetailFailures() async throws {
        let client = makeClient { request in
            guard let objectID = objectID(from: request) else {
                return response(request, data: searchFixture(ids: [41, 42, 43, 44]))
            }
            switch objectID {
            case 41:
                try await Task.sleep(nanoseconds: 40_000_000)
                return response(request, data: objectFixture(id: objectID))
            case 42:
                return response(request, status: 404, data: Data())
            case 43:
                return response(request, data: Data("not-json".utf8))
            default:
                try await Task.sleep(nanoseconds: 5_000_000)
                return response(request, data: objectFixture(id: objectID))
            }
        }

        let page = try await client.search(query: "sculpture", cursor: nil, pageSize: 4)

        XCTAssertEqual(page.records.map(\.id), ["met:41", "met:44"])
    }

    /// 一页扫描量必须有限；游标只推进实际检查的前四项，下一页仍能交付紧随其后的有效对象。
    func testFiniteScanLimitAdvancesOnlyInspectedObjects() async throws {
        let client = makeClient { request in
            guard let objectID = objectID(from: request) else {
                return response(request, data: searchFixture(ids: [51, 52, 53, 54, 55]))
            }
            return response(
                request,
                data: objectFixture(id: objectID, isPublicDomain: objectID == 55)
            )
        }

        let first = try await client.search(query: "archive", cursor: nil, pageSize: 1)
        let cursor = try XCTUnwrap(first.nextCursor)
        XCTAssertEqual(first.records, [])
        XCTAssertEqual(cursor.rawValue.split(separator: ".")[1], "4")

        let second = try await client.search(query: "archive", cursor: cursor, pageSize: 1)
        XCTAssertEqual(second.records.map(\.id), ["met:55"])
        XCTAssertNil(second.nextCursor)
    }

    /// 详情加载可并行，但同一客户端同时在途的详情请求永远不超过四个。
    func testDetailConcurrencyIsBoundedAtFour() async throws {
        let probe = DetailConcurrencyProbe(ids: Array(61...72))
        let client = makeClient { request in
            try await probe.load(request)
        }

        let page = try await client.search(query: "objects", cursor: nil, pageSize: 12)
        let maximumObserved = await probe.maximumObserved()

        XCTAssertEqual(page.records.count, 12)
        XCTAssertEqual(maximumObserved, 4)
    }

    /// 搜索端 HTTP、限流、解析和传输错误必须保持可区分的 provider 错误分类。
    func testSearchFailuresAreClassified() async {
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let invalidResponseClient = makeClient { request in
            response(request, status: 503, data: Data())
        }
        do {
            _ = try await invalidResponseClient.search(query: "x", cursor: nil, pageSize: 1)
            XCTFail("503 应抛出响应错误")
        } catch {
            XCTAssertEqual(error as? MetMuseumError, .invalidResponse(statusCode: 503))
        }

        let rateLimitedClient = makeClient(now: { fixedNow }) { request in
            response(request, status: 429, headers: ["Retry-After": "7"], data: Data())
        }
        do {
            _ = try await rateLimitedClient.search(query: "x", cursor: nil, pageSize: 1)
            XCTFail("429 应抛出限流错误")
        } catch {
            XCTAssertEqual(error as? MetMuseumError, .rateLimited(retryAt: fixedNow.addingTimeInterval(7)))
            XCTAssertEqual((error as? PhotoSourceFailure)?.issueKind, .rateLimited)
        }

        let decodingClient = makeClient { request in
            response(request, data: Data("not-json".utf8))
        }
        do {
            _ = try await decodingClient.search(query: "x", cursor: nil, pageSize: 1)
            XCTFail("非法搜索 JSON 应抛出解析错误")
        } catch {
            XCTAssertEqual(error as? MetMuseumError, .decoding("搜索响应格式无效"))
        }

        let networkClient = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await networkClient.search(query: "x", cursor: nil, pageSize: 1)
            XCTFail("传输失败应抛出网络错误")
        } catch {
            XCTAssertEqual(error as? MetMuseumError, .network("错误代码 -1009"))
            XCTAssertEqual((error as? PhotoSourceFailure)?.issueKind, .network)
        }
    }

    /// 非 404 的详情服务错误会中止本页，避免把服务整体故障伪装成正常空结果。
    func testDetailServiceFailureIsNotSilentlySkipped() async {
        let client = makeClient { request in
            guard objectID(from: request) != nil else {
                return response(request, data: searchFixture(ids: [81]))
            }
            return response(request, status: 500, data: Data())
        }

        do {
            _ = try await client.search(query: "x", cursor: nil, pageSize: 1)
            XCTFail("详情服务错误应保留错误分类")
        } catch {
            XCTAssertEqual(error as? MetMuseumError, .invalidResponse(statusCode: 500))
        }
    }

    private func makeClient(
        now: @escaping @Sendable () -> Date = { Date() },
        loader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) -> MetMuseumClient {
        MetMuseumClient(
            minimumRequestInterval: 0,
            now: now,
            requestLoader: loader
        )
    }
}

private actor RequestLog {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func paths() -> [String] {
        values
    }
}

private actor IDSnapshotStore {
    private var values: [Int]

    init(_ values: [Int]) {
        self.values = values
    }

    func ids() -> [Int] {
        values
    }

    func replace(with values: [Int]) {
        self.values = values
    }
}

private actor DetailConcurrencyProbe {
    private let ids: [Int]
    private var active = 0
    private var maximum = 0

    init(ids: [Int]) {
        self.ids = ids
    }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let objectID = objectID(from: request) else {
            return response(request, data: searchFixture(ids: ids))
        }

        active += 1
        maximum = max(maximum, active)
        do {
            try await Task.sleep(nanoseconds: 25_000_000)
        } catch {
            active -= 1
            throw error
        }
        active -= 1
        return response(request, data: objectFixture(id: objectID))
    }

    func maximumObserved() -> Int {
        maximum
    }
}

private func objectID(from request: URLRequest) -> Int? {
    guard request.url?.path.contains("/objects/") == true else { return nil }
    return request.url.flatMap { Int($0.lastPathComponent) }
}

private func response(
    _ request: URLRequest,
    status: Int = 200,
    headers: [String: String]? = nil,
    data: Data
) -> (Data, URLResponse) {
    let http = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: nil,
        headerFields: headers
    )!
    return (data, http)
}

private func searchFixture(ids: [Int]?) -> Data {
    let json: [String: Any] = [
        "total": ids?.count ?? 0,
        "objectIDs": ids.map { $0 as Any } ?? NSNull()
    ]
    return try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
}

private func objectFixture(
    id: Int,
    isPublicDomain: Bool = true,
    title: String? = nil,
    artist: String? = nil,
    image: String? = nil,
    thumbnail: String? = nil,
    objectURL: String? = nil
) -> Data {
    let json: [String: Any] = [
        "objectID": id,
        "isPublicDomain": isPublicDomain,
        "primaryImage": image ?? "https://images.example.com/\(id).jpg",
        "primaryImageSmall": thumbnail ?? "https://images.example.com/\(id)-small.jpg",
        "title": title ?? "Object \(id)",
        "artistDisplayName": artist ?? "Artist \(id)",
        "objectURL": objectURL ?? "https://www.metmuseum.org/art/collection/search/\(id)"
    ]
    return try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
}
