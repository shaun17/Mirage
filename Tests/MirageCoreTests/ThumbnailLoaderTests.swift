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
