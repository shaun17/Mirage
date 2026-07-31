import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 有界的缩略图缓存，并在解码时就按目标尺寸降采样。
///
/// SwiftUI 的 `AsyncImage` 既不缓存解码结果，也不降采样：`LazyVGrid` 每次回收再复用格子
/// 都会重新发起请求，并按**原始像素**解码。Openverse 的原图常有数千像素宽，
/// 为一个 158pt 的卡片解一次就是可感知的卡顿，一屏十几张同时解码则会直接顶住主线程。
///
/// 这里用一次下载 + 一次降采样解码换掉那条路径：结果按 URL 缓存，
/// 并发请求合并成一次下载，失败不写缓存以便下次重试。
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSURL, ThumbnailImageBox>()
    private let fetch: @Sendable (URL) async throws -> Data
    private var inFlight: [URL: Task<CGImage?, Never>] = [:]

    init(
        countLimit: Int = 240,
        fetch: @escaping @Sendable (URL) async throws -> Data = {
            try await URLSession.shared.data(from: $0).0
        }
    ) {
        cache.countLimit = countLimit
        self.fetch = fetch
    }

    /// 命中缓存直接返回；否则合并并发请求，只下载与解码一次。
    func image(for url: URL, maximumPixelSize: Int) async -> CGImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached.image }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<CGImage?, Never> { [fetch] in
            guard let data = try? await fetch(url) else { return nil }
            return Self.downsample(data, maximumPixelSize: maximumPixelSize)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        // 失败不进缓存：网络抖动不该让这张图在整个会话里永远显示为失败。
        if let image { cache.setObject(ThumbnailImageBox(image), forKey: key) }
        return image
    }

    /// 由 ImageIO 在解码阶段直接生成目标尺寸，避免先解出整张原图再缩放。
    private static func downsample(_ data: Data, maximumPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maximumPixelSize, 1),
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// `NSCache` 只接受类类型，这里给 `CGImage` 一个最小包装。
final class ThumbnailImageBox: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

/// 走 `ThumbnailLoader` 的缩略图视图；随格子回收自动取消，随 URL 变化重新加载。
struct ThumbnailImage: View {
    let url: URL
    let maximumPixelSize: Int

    @State private var image: CGImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if didFail {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        // `.task(id:)` 在格子被回收时自动取消下载，快速滚动不会堆积无人认领的请求。
        .task(id: url) {
            let loaded = await ThumbnailLoader.shared.image(
                for: url,
                maximumPixelSize: maximumPixelSize
            )
            guard !Task.isCancelled else { return }
            image = loaded
            didFail = loaded == nil
        }
    }
}
