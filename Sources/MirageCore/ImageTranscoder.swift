import CoreGraphics
import CoreServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageTranscoderError: Error, Equatable, LocalizedError, Sendable {
    case dataTooLarge(actualBytes: Int, maximumBytes: Int)
    case unsupportedFormat
    case mimeMismatch(declared: String, detected: String)
    case pixelLimitExceeded(actualPixels: Int, maximumPixels: Int)
    case fixedOutputSizeExceeded(actualBytes: Int, targetBytes: Int)
    case invalidImage
    case renderingFailed
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case let .dataTooLarge(actual, maximum): return "图片文件过大（\(actual) / \(maximum) 字节）"
        case .unsupportedFormat: return "图片格式不受支持或文件签名无效"
        case let .mimeMismatch(declared, detected): return "MIME 与文件内容不一致（\(declared) / \(detected)）"
        case let .pixelLimitExceeded(actual, maximum): return "图片像素过多（\(actual) / \(maximum)）"
        case let .fixedOutputSizeExceeded(actual, target):
            return "PNG 编码结果超过固定文件大小（\(actual) / \(target) 字节）"
        case .invalidImage: return "图片无法解码"
        case .renderingFailed: return "图片方向修正或裁切失败"
        case .encodingFailed: return "PNG 编码失败"
        }
    }
}

/// 对不可信的远程图片做有上限的解码，并生成无元数据的标准头像 PNG。
public struct ImageTranscoder: Sendable {
    public static let outputSize = 512
    /// File Provider 必须在枚举时给出精确字节数；1.25 MiB 足以容纳 512×512 RGBA PNG。
    public static let outputFileSize = 1_310_720
    public static let defaultMaximumBytes = 20 * 1024 * 1024
    public static let defaultMaximumPixels = 100_000_000

    private let maximumBytes: Int
    private let maximumPixels: Int

    public init(
        maximumBytes: Int = defaultMaximumBytes,
        maximumPixels: Int = defaultMaximumPixels
    ) {
        self.maximumBytes = maximumBytes
        self.maximumPixels = maximumPixels
    }

    /// 校验文件签名、MIME 和尺寸，再应用方向、中心裁切并输出 512×512 sRGB PNG。
    public func transcode(_ data: Data, declaredMIMEType: String? = nil) throws -> Data {
        guard data.count <= maximumBytes else {
            throw ImageTranscoderError.dataTooLarge(actualBytes: data.count, maximumBytes: maximumBytes)
        }
        guard let format = InputFormat.detect(data) else { throw ImageTranscoderError.unsupportedFormat }
        if let declaredMIMEType {
            let normalized = Self.normalizeMIME(declaredMIMEType)
            guard format.mimeAliases.contains(normalized) else {
                throw ImageTranscoderError.mimeMismatch(declared: normalized, detected: format.primaryMIME)
            }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw ImageTranscoderError.invalidImage }
        let dimensions = try sourceDimensions(source)
        let (pixels, overflow) = dimensions.width.multipliedReportingOverflow(by: dimensions.height)
        guard !overflow, pixels <= maximumPixels else {
            throw ImageTranscoderError.pixelLimitExceeded(actualPixels: overflow ? .max : pixels, maximumPixels: maximumPixels)
        }
        let image = try orientedThumbnail(source, dimensions: dimensions)
        let rendered = try renderSquare(image)
        return try encodePNG(rendered)
    }

    /// 写入固定字节数的合法 PNG，使 File Provider 可在下载前声明精确 documentSize。
    public func transcode(
        _ data: Data,
        declaredMIMEType: String? = nil,
        writingTo outputURL: URL
    ) throws {
        let encoded = try transcode(data, declaredMIMEType: declaredMIMEType)
        let pngData = try fixedSizePNG(from: encoded)
        try pngData.write(to: outputURL, options: .atomic)
    }

    /// 在 IEND 前插入私有辅助块；像素不变、无来源元数据，且文件严格达到固定大小。
    private func fixedSizePNG(from pngData: Data) throws -> Data {
        let iend = Data(Self.iendChunk)
        guard pngData.count >= iend.count, pngData.suffix(iend.count) == iend else {
            throw ImageTranscoderError.encodingFailed
        }
        let addedBytes = Self.outputFileSize - pngData.count
        guard addedBytes >= Self.pngChunkOverhead else {
            throw ImageTranscoderError.fixedOutputSizeExceeded(
                actualBytes: pngData.count,
                targetBytes: Self.outputFileSize
            )
        }

        let payloadSize = addedBytes - Self.pngChunkOverhead
        var chunkBody = Data(Self.paddingChunkType)
        chunkBody.append(Data(repeating: 0, count: payloadSize))

        var output = Data(capacity: Self.outputFileSize)
        output.append(pngData.dropLast(iend.count))
        Self.appendBigEndian(UInt32(payloadSize), to: &output)
        output.append(chunkBody)
        Self.appendBigEndian(Self.crc32(chunkBody), to: &output)
        output.append(iend)
        guard output.count == Self.outputFileSize else {
            throw ImageTranscoderError.encodingFailed
        }
        return output
    }

    /// 在实际解码前读取 ImageIO 元数据并验证正整数尺寸。
    private func sourceDimensions(_ source: CGImageSource) throws -> (width: Int, height: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw ImageTranscoderError.invalidImage }
        return (width, height)
    }

    /// ImageIO 在缩略解码阶段应用 EXIF orientation，避免先完整展开超大位图。
    private func orientedThumbnail(
        _ source: CGImageSource,
        dimensions: (width: Int, height: Int)
    ) throws -> CGImage {
        let longSide = max(dimensions.width, dimensions.height)
        let shortSide = min(dimensions.width, dimensions.height)
        let requiredLongSide = Int(ceil(Double(Self.outputSize * longSide) / Double(shortSide)))
        let thumbnailSize = min(longSide, max(Self.outputSize, requiredLongSide))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageTranscoderError.invalidImage
        }
        return image
    }

    /// 以 aspect-fill 方式居中绘制到明确的 sRGB 画布。
    private func renderSquare(_ image: CGImage) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Self.outputSize,
                height: Self.outputSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw ImageTranscoderError.renderingFailed }
        let scale = max(Double(Self.outputSize) / Double(image.width), Double(Self.outputSize) / Double(image.height))
        let width = Double(image.width) * scale
        let height = Double(image.height) * scale
        let rect = CGRect(x: (Double(Self.outputSize) - width) / 2, y: (Double(Self.outputSize) - height) / 2, width: width, height: height)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ImageTranscoderError.renderingFailed }
        return result
    }

    /// 创建全新 PNG 容器且不附加源属性，从而移除 EXIF 等元数据。
    private func encodePNG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageTranscoderError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageTranscoderError.encodingFailed }
        return output as Data
    }

    /// MIME 参数可能带分号或大小写差异，比较前统一清理。
    private static func normalizeMIME(_ value: String) -> String {
        value.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    /// PNG chunk 固定包含 4 字节长度、4 字节类型和 4 字节 CRC。
    private static let pngChunkOverhead = 12
    private static let paddingChunkType: [UInt8] = Array("ahPd".utf8)
    private static let iendChunk: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
        0xAE, 0x42, 0x60, 0x82
    ]

    /// CRC 表只初始化一次，避免为最多 1.25 MiB 的辅助块逐位计算。
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var current = UInt32(value)
        for _ in 0..<8 {
            current = current & 1 == 1 ? 0xEDB8_8320 ^ (current >> 1) : current >> 1
        }
        return current
    }

    /// PNG 使用标准 IEEE CRC-32，覆盖 chunk type 与 payload。
    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ UInt32.max
    }

    /// PNG 长度与 CRC 字段都使用网络字节序。
    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

private enum InputFormat {
    case png, jpeg, webP, heif, bmp

    /// 使用魔数而不是扩展名判断真实内容格式。
    static func detect(_ data: Data) -> InputFormat? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.starts(with: [0x42, 0x4D]) { return .bmp }
        if bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return .webP }
        if bytes.count >= 12, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif", "avis"].contains(brand) { return .heif }
        }
        return nil
    }

    /// 供错误信息展示的规范 MIME。
    var primaryMIME: String {
        switch self {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        case .webP: return "image/webp"
        case .heif: return "image/heic"
        case .bmp: return "image/bmp"
        }
    }

    /// 接纳行业中确实等价的 MIME 拼法，但不跨格式放宽。
    var mimeAliases: Set<String> {
        switch self {
        case .png: return ["image/png"]
        case .jpeg: return ["image/jpeg", "image/jpg"]
        case .webP: return ["image/webp"]
        case .heif: return ["image/heic", "image/heif", "image/avif"]
        case .bmp: return ["image/bmp", "image/x-bmp", "image/x-ms-bmp"]
        }
    }
}
