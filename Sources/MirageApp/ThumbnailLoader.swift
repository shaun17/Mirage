import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MirageCore
import SwiftUI
import UniformTypeIdentifiers

private enum ThumbnailDataSource {
    static let snapshotStorage = try? AppGroupStorage()

    static func data(for url: URL) async throws -> Data {
        if url.scheme == AvatarSnapshotReference.scheme {
            guard let reference = AvatarSnapshotReference(url: url),
                  let snapshotStorage,
                  let data = try await snapshotStorage.readAvatarSnapshot(
                      key: reference.key,
                      maximumBytes: 5 * 1024 * 1024
                  ) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return data
        }
        if PicrewDiscoveryMediaPolicy.isAllowedThumbnailURL(url) {
            return try await BoundedDownloader(
                url: url,
                maximumBytes: 2 * 1_024 * 1_024,
                timeoutInterval: 15,
                allowedHosts: ["cdn.picrew.me"],
                acceptedMIMETypes: ["image/jpeg", "image/png", "image/webp"]
            ).download()
        }
        return try await URLSession.shared.data(from: url).0
    }
}

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
            try await ThumbnailDataSource.data(for: $0)
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

/// 根据来源的数据处理约束选择预览路径：普通图片复用有界缓存，GIPHY 仅做瞬时加载。
struct RemoteThumbnailImage: View {
    let record: RemoteImageRecord
    let maximumPixelSize: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var copyImageTask: Task<Void, Never>?

    var body: some View {
        Group {
            if record.source.allowsMediaCaching {
                ThumbnailImage(url: record.thumbnailURL, maximumPixelSize: maximumPixelSize)
            } else if scenePhase == .active, isVisible {
                TransientAnimatedImage(
                    url: record.thumbnailURL,
                    animates: !reduceMotion,
                    accessibilityLabel: "“\(record.title)”的 GIPHY 动图预览"
                )
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .contextMenu {
            Button {
                copyImage()
            } label: {
                Label("复制图片", systemImage: "doc.on.doc")
            }

            Button {
                copyImageTask?.cancel()
                copyImageTask = nil
                RemoteImagePasteboardWriter.copyAddress(record.imageURL)
            } label: {
                Label("复制地址", systemImage: "link")
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    /// 图片加载完成后才提交剪贴板；新复制动作会取消尚未完成的旧请求。
    private func copyImage() {
        copyImageTask?.cancel()
        copyImageTask = Task { @MainActor in
            let copied = await RemoteImagePasteboardWriter.copyImage(for: record)
            guard !Task.isCancelled else { return }
            copyImageTask = nil
            if !copied { NSSound.beep() }
        }
    }
}

/// 把图片视图当前对应的媒体或原图地址写入系统剪贴板。
@MainActor
enum RemoteImagePasteboardWriter {
    /// 普通来源复用缩略图缓存；GIPHY 以临时 GIF 文件复制，防止粘贴端选择静态 TIFF。
    static func copyImage(
        for record: RemoteImageRecord,
        to pasteboard: NSPasteboard = .general
    ) async -> Bool {
        if record.source.allowsMediaCaching {
            guard let image = await cachedImage(for: record),
                  !Task.isCancelled else {
                return false
            }
            return writeImage(image, to: pasteboard)
        }

        guard record.source == .giphy,
              let data = try? await TransientGiphyMediaLoader.gifData(
                  for: record.thumbnailURL
              ),
              !Task.isCancelled else {
            return false
        }
        return writeGIFData(data, to: pasteboard)
    }

    /// 同时提供纯文本和 URL 类型，文本框与识别链接的 App 都能正确粘贴。
    @discardableResult
    static func copyAddress(
        _ url: URL,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        let value = url.absoluteString
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setString(value, forType: .URL)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    @discardableResult
    static func writeImage(_ image: NSImage, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    /// 复制真实 GIF 文件 URL；直接写图片数据会被 AppKit 派生出静态 TIFF。
    @discardableResult
    static func writeGIFData(
        _ data: Data,
        to pasteboard: NSPasteboard
    ) -> Bool {
        guard TransientGiphyMediaLoader.isGIF(data) else { return false }
        guard let fileURL = try? materializeGIF(data) else {
            return false
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([fileURL as NSURL]) else {
            try? FileManager.default.removeItem(at: fileURL)
            return false
        }
        removeOldClipboardGIFs(except: fileURL)
        return true
    }

    private static func materializeGIF(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageClipboard", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory
            .appendingPathComponent("Mirage-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("gif")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func removeOldClipboardGIFs(except currentURL: URL) {
        let directory = currentURL.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for url in contents
        where url.lastPathComponent != currentURL.lastPathComponent
            && url.pathExtension.lowercased() == "gif" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func cachedImage(for record: RemoteImageRecord) async -> NSImage? {
        guard let image = await ThumbnailLoader.shared.image(
            for: record.thumbnailURL,
            maximumPixelSize: 512
        ) else {
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height))
        )
    }
}

/// 直接呈现动画媒体，但不使用 URLCache 或应用内解码缓存。
private struct TransientAnimatedImage: NSViewRepresentable {
    let url: URL
    let animates: Bool
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.load(url: url, animates: animates, into: imageView)
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        imageView.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.load(url: url, animates: animates, into: imageView)
    }

    static func dismantleNSView(_ imageView: NSImageView, coordinator: Coordinator) {
        coordinator.cancel()
        imageView.image = nil
    }

    @MainActor
    final class Coordinator {
        private var activeURL: URL?
        private var task: Task<Void, Never>?

        func load(url: URL, animates: Bool, into imageView: NSImageView) {
            imageView.animates = animates
            guard activeURL != url else { return }

            cancel()
            activeURL = url
            imageView.image = nil

            guard GiphyEmojiClient.isAllowedMediaURL(url) else {
                showFailure(in: imageView)
                activeURL = nil
                return
            }

            let session = TransientGiphyMediaLoader.sharedSession
            task = Task { @MainActor [weak self, weak imageView] in
                do {
                    let image = try await TransientGiphyMediaLoader.image(for: url, using: session)
                    try Task.checkCancellation()
                    guard let self,
                          self.activeURL == url else { return }
                    imageView?.image = image
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch {
                    guard self?.activeURL == url else { return }
                    if let imageView { self?.showFailure(in: imageView) }
                    self?.activeURL = nil
                }
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
            activeURL = nil
        }

        private func showFailure(in imageView: NSImageView) {
            imageView.setAccessibilityLabel("GIPHY 动图加载失败")
            imageView.image = NSImage(
                systemSymbolName: "photo.badge.exclamationmark",
                accessibilityDescription: "GIPHY 动图加载失败"
            )
        }
    }
}

/// 瞬时动图下载在收包时即限制大小，并拒绝跳出 GIPHY CDN 的重定向。
enum TransientGiphyMediaLoader {
    private static let maximumMediaBytes = 16 * 1_024 * 1_024
    private static let maximumPixelDimension = 2_048
    private static let maximumFrameCount = 240
    /// 单任务 RGBA 展开量约 64 MiB；配合两个全局许可，将瞬时解码总量限制在约 128 MiB。
    private static let maximumDecodedPixelFrames = 16 * 1_024 * 1_024
    private static let loadGate = TransientGiphyLoadGate(maximumConcurrentLoads: 2)
    private static let allowedMIMETypes: Set<String> = [
        "image/gif", "image/webp", "image/png", "image/jpeg"
    ]

    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(
            configuration: configuration,
            delegate: GiphyMediaRedirectDelegate(),
            delegateQueue: nil
        )
    }()

    /// 所有 GIPHY 展示与复制动作共用同一份无缓存请求配置。
    nonisolated static func image(
        for url: URL,
        using session: URLSession = sharedSession
    ) async throws -> NSImage {
        try await image(for: mediaRequest(for: url), using: session)
    }

    nonisolated static func image(
        for request: URLRequest,
        using session: URLSession
    ) async throws -> NSImage {
        try await loadGate.withPermit {
            let data = try await loadData(for: request, using: session)
            try Task.checkCancellation()
            guard let image = NSImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            try Task.checkCancellation()
            return image
        }
    }

    /// 返回经过同一安全边界校验的 GIF 原始字节，供剪贴板保留动画表示。
    nonisolated static func gifData(
        for url: URL,
        using session: URLSession = sharedSession
    ) async throws -> Data {
        try await gifData(for: mediaRequest(for: url), using: session)
    }

    nonisolated static func gifData(
        for request: URLRequest,
        using session: URLSession
    ) async throws -> Data {
        try await loadGate.withPermit {
            let data = try await loadData(for: request, using: session)
            guard isGIF(data) else { throw URLError(.cannotDecodeContentData) }
            return data
        }
    }

    nonisolated static func isGIF(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            return false
        }
        return type as String == UTType.gif.identifier
    }

    private nonisolated static func mediaRequest(for url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(
            "image/gif,image/webp,image/png,image/jpeg",
            forHTTPHeaderField: "Accept"
        )
        return request
    }

    private nonisolated static func loadData(
        for request: URLRequest,
        using session: URLSession
    ) async throws -> Data {
        guard let requestedURL = request.url,
              GiphyEmojiClient.isAllowedMediaURL(requestedURL) else {
            throw URLError(.unsupportedURL)
        }

        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url,
              GiphyEmojiClient.isAllowedMediaURL(finalURL) else {
            throw URLError(.badServerResponse)
        }
        if let mimeType = http.mimeType?.lowercased(),
           !allowedMIMETypes.contains(mimeType) {
            throw URLError(.cannotDecodeContentData)
        }
        let expectedLength = http.expectedContentLength
        guard expectedLength <= 0 || expectedLength <= Int64(maximumMediaBytes) else {
            throw URLError(.dataLengthExceedsMaximum)
        }

        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumMediaBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        guard !data.isEmpty else { throw URLError(.zeroByteResource) }
        guard isWithinDecodeBudget(data) else {
            throw URLError(.cannotDecodeContentData)
        }

        try Task.checkCancellation()
        return data
    }

    /// 压缩字节数不足以约束动画展开内存；在交给 NSImage 前检查像素和帧数预算。
    private nonisolated static func isWithinDecodeBudget(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, frameCount <= maximumFrameCount else { return false }

        var decodedPixelFrames = 0
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                index,
                nil
            ) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0,
            width <= maximumPixelDimension,
            height <= maximumPixelDimension else {
                return false
            }
            let (framePixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
            let (newTotal, totalOverflow) = decodedPixelFrames.addingReportingOverflow(framePixels)
            guard !pixelOverflow,
                  !totalOverflow,
                  newTotal <= maximumDecodedPixelFrames else {
                return false
            }
            decodedPixelFrames = newTotal
        }
        return true
    }
}

/// 跨所有 GIPHY CDN host 共用的取消安全许可池，避免每个 host 各自放大下载与解码并发。
actor TransientGiphyLoadGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let maximumConcurrentLoads: Int
    private var activeLoads = 0
    private var waiters: [Waiter] = []

    init(maximumConcurrentLoads: Int) {
        self.maximumConcurrentLoads = max(maximumConcurrentLoads, 1)
    }

    func withPermit<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard activeLoads >= maximumConcurrentLoads else {
            activeLoads += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func release() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
        } else {
            activeLoads = max(activeLoads - 1, 0)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private final class GiphyMediaRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              GiphyEmojiClient.isAllowedMediaURL(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// GIPHY 要求在使用其内容的位置持续展示官方品牌标记。
struct GiphyAttributionLink: View {
    private static let destination = URL(string: "https://giphy.com/")!

    var body: some View {
        Link(destination: Self.destination) {
            Image("PoweredByGiphy")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 100, height: 21)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Powered by GIPHY")
        .accessibilityHint("打开 GIPHY 网站")
    }
}
