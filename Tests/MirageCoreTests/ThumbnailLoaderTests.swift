import CoreGraphics
import Foundation
import XCTest

/// 缩略图加载器的缓存、并发去重与失败语义；这些规则决定长列表来回滚动时的流畅度与流量。
final class ThumbnailLoaderTests: XCTestCase {
    /// 同一 URL 只解码一次，第二次直接命中缓存，不再触碰网络。
    func testSecondRequestHitsCacheWithoutFetching() async throws {
        let fetcher = CountingFetcher(data: Self.pngData())
        let loader = ThumbnailLoader(countLimit: 8, fetch: fetcher.fetch)

        let first = await loader.image(for: Self.url(1), maximumPixelSize: 64)
        let second = await loader.image(for: Self.url(1), maximumPixelSize: 64)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        let count = await fetcher.count
        XCTAssertEqual(count, 1)
    }

    /// 同一 URL 的并发请求合并成一次下载，滚动时一屏多张同图不会放大流量。
    func testConcurrentRequestsForSameURLFetchOnce() async throws {
        let fetcher = CountingFetcher(data: Self.pngData(), delay: .milliseconds(40))
        let loader = ThumbnailLoader(countLimit: 8, fetch: fetcher.fetch)

        async let a = loader.image(for: Self.url(2), maximumPixelSize: 64)
        async let b = loader.image(for: Self.url(2), maximumPixelSize: 64)
        async let c = loader.image(for: Self.url(2), maximumPixelSize: 64)
        let results = await [a, b, c]

        XCTAssertEqual(results.compactMap { $0 }.count, 3)
        let count = await fetcher.count
        XCTAssertEqual(count, 1)
    }

    /// 不同 URL 各自独立下载。
    func testDifferentURLsFetchSeparately() async throws {
        let fetcher = CountingFetcher(data: Self.pngData())
        let loader = ThumbnailLoader(countLimit: 8, fetch: fetcher.fetch)

        _ = await loader.image(for: Self.url(3), maximumPixelSize: 64)
        _ = await loader.image(for: Self.url(4), maximumPixelSize: 64)

        let count = await fetcher.count
        XCTAssertEqual(count, 2)
    }

    /// 下载失败返回空值，且不写进缓存——下次仍可重试。
    func testFailureIsNotCached() async throws {
        let fetcher = CountingFetcher(data: Self.pngData(), failsFirst: true)
        let loader = ThumbnailLoader(countLimit: 8, fetch: fetcher.fetch)

        let failed = await loader.image(for: Self.url(5), maximumPixelSize: 64)
        let retried = await loader.image(for: Self.url(5), maximumPixelSize: 64)

        XCTAssertNil(failed)
        XCTAssertNotNil(retried)
        let count = await fetcher.count
        XCTAssertEqual(count, 2)
    }

    /// 无法解码的数据同样返回空值，不会把损坏内容当成有效缩略图缓存起来。
    func testUndecodableDataReturnsNil() async throws {
        let fetcher = CountingFetcher(data: Data("not an image".utf8))
        let loader = ThumbnailLoader(countLimit: 8, fetch: fetcher.fetch)

        let image = await loader.image(for: Self.url(6), maximumPixelSize: 64)

        XCTAssertNil(image)
    }

    /// 解码结果按目标像素降采样，卡片不会为 158pt 的位置持有整张原图。
    func testDecodedImageIsDownsampledToRequestedSize() async throws {
        let fetcher = CountingFetcher(data: Self.pngData(width: 1200, height: 900))
        let loader = ThumbnailLoader(countLimit: 8, fetch: fetcher.fetch)

        let decoded = await loader.image(for: Self.url(7), maximumPixelSize: 128)
        let image = try XCTUnwrap(decoded)

        XCTAssertLessThanOrEqual(max(image.width, image.height), 128)
        XCTAssertGreaterThan(image.width, 0)
    }

    /// 所有 GIPHY CDN host 共用同一个许可池，瞬时加载总并发不能超过全局上限。
    func testTransientGiphyGateLimitsGlobalConcurrency() async {
        let gate = TransientGiphyLoadGate(maximumConcurrentLoads: 2)
        let tracker = TransientConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try? await gate.withPermit {
                        await tracker.started()
                        try await Task.sleep(for: .milliseconds(30))
                        await tracker.finished()
                    }
                }
            }
        }

        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.completed, 6)
        XCTAssertLessThanOrEqual(snapshot.maximumActive, 2)
    }

    /// 已取消的视图任务必须在下载前终止，不能留下脱离生命周期的瞬时解码工作。
    func testCancelledTransientGiphyLoadThrowsCancellation() async {
        TransientGiphyURLProtocol.handler = { request in
            (
                Self.response(for: request.url!, mimeType: "image/png"),
                Self.pngData()
            )
        }
        let request = URLRequest(url: Self.giphyURL)
        let session = Self.transientSession()
        let task = Task<Void, any Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await TransientGiphyMediaLoader.image(for: request, using: session)
        }

        do {
            _ = try await task.value
            XCTFail("已取消任务不应继续下载或解码")
        } catch is CancellationError {
            // 预期路径。
        } catch {
            XCTFail("应保留结构化取消语义，实际为：\(error)")
        }
    }

    /// 即使压缩字节很小，超过像素边界的媒体也必须在交给 NSImage 前被拒绝。
    func testTransientGiphyLoadRejectsOversizedDecodeDimensions() async {
        TransientGiphyURLProtocol.handler = { request in
            (
                Self.response(for: request.url!, mimeType: "image/png"),
                Self.pngData(width: 2_049, height: 1)
            )
        }

        do {
            _ = try await TransientGiphyMediaLoader.image(
                for: URLRequest(url: Self.giphyURL),
                using: Self.transientSession()
            )
            XCTFail("超过像素预算的媒体不应解码")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotDecodeContentData)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }

    /// 最终响应若跳出 GIPHY CDN，即使数据本身可解码也必须拒绝。
    func testTransientGiphyLoadRejectsNonGiphyFinalURL() async {
        TransientGiphyURLProtocol.handler = { _ in
            (
                Self.response(
                    for: URL(string: "https://evil.example/redirected.gif")!,
                    mimeType: "image/png"
                ),
                Self.pngData()
            )
        }

        do {
            _ = try await TransientGiphyMediaLoader.image(
                for: URLRequest(url: Self.giphyURL),
                using: Self.transientSession()
            )
            XCTFail("跳出 GIPHY CDN 的最终响应不应被接受")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }

    private static let giphyURL = URL(
        string: "https://media1.giphy.com/media/test/200w.gif"
    )!

    private static func transientSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransientGiphyURLProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private static func response(for url: URL, mimeType: String) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mimeType]
        )!
    }

    private static func url(_ index: Int) -> URL {
        URL(string: "https://example.com/thumb-\(index).png")!
    }

    /// 生成一张可被 ImageIO 解码的真实 PNG。
    private static func pngData(width: Int = 40, height: Int = 30) -> Data {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}

/// 记录下载次数的替身，验证缓存与并发去重而不触碰网络。
private actor CountingFetcher {
    private(set) var count = 0
    private let data: Data
    private let delay: Duration?
    private var failsFirst: Bool

    init(data: Data, delay: Duration? = nil, failsFirst: Bool = false) {
        self.data = data
        self.delay = delay
        self.failsFirst = failsFirst
    }

    /// 以 `@Sendable` 闭包形式交给加载器，保持注入点最小。
    nonisolated var fetch: @Sendable (URL) async throws -> Data {
        { [self] _ in try await perform() }
    }

    private func perform() async throws -> Data {
        count += 1
        if let delay { try await Task.sleep(for: delay) }
        if failsFirst {
            failsFirst = false
            throw ThumbnailTestError.unavailable
        }
        return data
    }
}

private enum ThumbnailTestError: Error {
    case unavailable
}

private actor TransientConcurrencyTracker {
    private var active = 0
    private var maximumActive = 0
    private var completed = 0

    func started() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func finished() {
        active -= 1
        completed += 1
    }

    func snapshot() -> (maximumActive: Int, completed: Int) {
        (maximumActive, completed)
    }
}

private final class TransientGiphyURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (URLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler?(request)
                ?? { throw URLError(.badServerResponse) }()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
