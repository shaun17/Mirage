import MirageCore
@preconcurrency import FileProvider
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension FileProviderExtension {
    /// 下载原图、执行受限转码，并从 File Provider 临时卷交付标准 PNG。
    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, (any NSFileProviderItem)?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        // NSFileProviderItemVersion 不是 Sendable，只把不可变 Data 值带入并发任务。
        let requested = requestedVersion.map {
            RequestedProviderVersion(
                contentVersion: $0.contentVersion,
                metadataVersion: $0.metadataVersion
            )
        }
        let callback = ProviderCallbackBox(completionHandler)
        let relay = ProviderTaskRelay()
        let operationID = UUID()
        tasks.insert(relay, id: operationID)
        let task = Task { [manager, repository, tasks, relay] in
            defer { tasks.remove(id: operationID) }
            do {
                try Task.checkCancellation()
                guard let reference = ProviderIdentifiers.recordReference(from: itemIdentifier) else {
                    if Self.isDirectory(itemIdentifier) { throw ProviderError.notAFile() }
                    throw ProviderError.noSuchItem(itemIdentifier)
                }
                guard let occurrence = try await repository.occurrence(for: itemIdentifier) else {
                    throw ProviderError.noSuchItem(itemIdentifier)
                }
                try Task.checkCancellation()
                let record = occurrence.record
                let item = ProviderItem(
                    record: record,
                    view: reference.view,
                    lastUsedDate: occurrence.lastUsedDate
                )
                if let requested,
                   requested.contentVersion != item.itemVersion.contentVersion
                    || requested.metadataVersion != item.itemVersion.metadataVersion {
                    throw ProviderError.versionNoLongerAvailable()
                }
                guard let manager else { throw ProviderError.serverUnreachable("File Provider 域不可用。") }
                let data = try await BoundedDownloader(
                    url: record.imageURL,
                    maximumBytes: ImageTranscoder.defaultMaximumBytes
                ).download()
                try Task.checkCancellation()
                let directory = try manager.temporaryDirectoryURL()
                let outputURL = directory.appendingPathComponent(UUID().uuidString + ".png")
                do {
                    // Openverse 的 filetype 只是源站元数据提示，CDN 可能合法协商为 WebP；
                    // 安全边界以 ImageTranscoder 的魔数白名单、像素上限和实际解码结果为准。
                    try ImageTranscoder().transcode(data, writingTo: outputURL)
                    let outputValues = try outputURL.resourceValues(forKeys: [.fileSizeKey])
                    guard let byteCount = outputValues.fileSize,
                          byteCount == ImageTranscoder.outputFileSize else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let materializedItem = ProviderItem(
                        record: record,
                        view: reference.view,
                        lastUsedDate: item.lastUsedDate,
                        documentSize: NSNumber(value: byteCount)
                    )
                    try Task.checkCancellation()
                    guard relay.beginNonCancellableCompletion() else { throw CancellationError() }
                    // 从这里起取消不能再越过 recent 写入；若取消先到达，上面的原子门会直接拒绝提交。
                    try Task.checkCancellation()
                    try await repository.markRecent(record)
                    try Task.checkCancellation()
                    try? await manager.signalEnumerator(for: ProviderIdentifiers.recent)
                    try Task.checkCancellation()
                    try? await manager.signalEnumerator(for: .workingSet)
                    try Task.checkCancellation()
                    relay.finish({
                        progress.completedUnitCount = 100
                        callback.value(outputURL, materializedItem, nil)
                    }, ifCancelled: {
                        callback.value(nil, nil, ProviderError.cancelled())
                    })
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    throw error
                }
            } catch is CancellationError {
                relay.finish({
                    callback.value(nil, nil, ProviderError.cancelled())
                }, ifCancelled: {
                    callback.value(nil, nil, ProviderError.cancelled())
                })
            } catch {
                relay.finish({
                    callback.value(nil, nil, Self.contentError(error))
                }, ifCancelled: {
                    callback.value(nil, nil, ProviderError.cancelled())
                })
            }
        }
        progress.cancellationHandler = { relay.cancel() }
        relay.install(task)
        return progress
    }

    /// 为每个标识单独下载并验证 ImageIO 可识别的缩略图数据。
    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(max(itemIdentifiers.count, 1)))
        let perItem = ProviderCallbackBox(perThumbnailCompletionHandler)
        let completed = ProviderCallbackBox(completionHandler)
        let relay = ProviderTaskRelay()
        let operationID = UUID()
        tasks.insert(relay, id: operationID)
        let task = Task { [repository, tasks, relay] in
            defer { tasks.remove(id: operationID) }
            for (index, identifier) in itemIdentifiers.enumerated() {
                if Task.isCancelled {
                    itemIdentifiers[index...].forEach { perItem.value($0, nil, ProviderError.cancelled()) }
                    relay.finish({
                        completed.value(ProviderError.cancelled())
                    }, ifCancelled: {
                        completed.value(ProviderError.cancelled())
                    })
                    return
                }
                do {
                    guard let record = try await repository.record(for: identifier) else {
                        throw ProviderError.noSuchItem(identifier)
                    }
                    try Task.checkCancellation()
                    let data = try await BoundedDownloader(
                        url: record.thumbnailURL,
                        maximumBytes: 5 * 1024 * 1024
                    ).download()
                    try Task.checkCancellation()
                    let prepared = try Self.thumbnailData(from: data, requestedSize: size)
                    try Task.checkCancellation()
                    perItem.value(identifier, prepared, nil)
                } catch is CancellationError {
                    itemIdentifiers[index...].forEach { perItem.value($0, nil, ProviderError.cancelled()) }
                    relay.finish({
                        completed.value(ProviderError.cancelled())
                    }, ifCancelled: {
                        completed.value(ProviderError.cancelled())
                    })
                    return
                } catch {
                    if Task.isCancelled {
                        itemIdentifiers[index...].forEach { perItem.value($0, nil, ProviderError.cancelled()) }
                        relay.finish({
                            completed.value(ProviderError.cancelled())
                        }, ifCancelled: {
                            completed.value(ProviderError.cancelled())
                        })
                        return
                    }
                    perItem.value(identifier, nil, Self.contentError(error))
                }
                progress.completedUnitCount = Int64(index + 1)
            }
            do {
                try Task.checkCancellation()
                relay.finish({
                    completed.value(nil)
                }, ifCancelled: {
                    completed.value(ProviderError.cancelled())
                })
            } catch {
                relay.finish({
                    completed.value(ProviderError.cancelled())
                }, ifCancelled: {
                    completed.value(ProviderError.cancelled())
                })
            }
        }
        progress.cancellationHandler = { relay.cancel() }
        relay.install(task)
        return progress
    }

    /// 根和三个虚拟目录都不能通过 fetchContents 下载。
    private static func isDirectory(_ identifier: NSFileProviderItemIdentifier) -> Bool {
        identifier == .rootContainer || identifier == ProviderIdentifiers.recent
            || identifier == ProviderIdentifiers.favorites || identifier == ProviderIdentifiers.searchBacking
    }

    /// 把下载与转码错误归入系统允许的 Cocoa/FileProvider 错误域。
    private static func contentError(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return ProviderError.cancelled() }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return ProviderError.cancelled()
        }
        if let download = error as? DownloadError {
            return ProviderError.serverUnreachable(download.localizedDescription)
        }
        if error is ImageTranscoderError {
            return NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadCorruptFileError,
                userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
            )
        }
        return error
    }

    /// 先按最终头像规则中心裁切，再缩放到系统请求尺寸，保证预览和上传结果一致。
    private static func thumbnailData(from sourceData: Data, requestedSize: CGSize) throws -> Data {
        let squarePNG = try ImageTranscoder(
            maximumBytes: 5 * 1024 * 1024,
            maximumPixels: 50_000_000
        ).transcode(sourceData)
        let requestedEdge = max(requestedSize.width, requestedSize.height)
        let edge = min(max(Int(ceil(requestedEdge)), 64), ImageTranscoder.outputSize)
        guard edge < ImageTranscoder.outputSize else { return squarePNG }
        guard let source = CGImageSourceCreateWithData(squarePNG as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}

/// 仅保存版本比较需要的值，安全跨越扩展回调与 Swift 并发任务边界。
private struct RequestedProviderVersion: Sendable {
    let contentVersion: Data
    let metadataVersion: Data
}
