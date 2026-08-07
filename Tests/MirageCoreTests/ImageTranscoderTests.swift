import CoreGraphics
import CoreServices
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MirageCore

final class ImageTranscoderTests: XCTestCase {
    /// 横向源图经方向处理与中心裁切后必须是精确 512×512 PNG。
    func testOutputDimensionsFormatAndMetadata() throws {
        let input = try makePNG(width: 120, height: 60, orientation: 6)
        let output = try ImageTranscoder().transcode(input, declaredMIMEType: "image/png; charset=binary")
        XCTAssertTrue(output.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 512)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 512)
        XCTAssertNil(properties[kCGImagePropertyOrientation])
    }

    /// 声明 MIME 与魔数不一致时必须在解码前拒绝。
    func testRejectsMismatchedMIME() throws {
        let input = try makePNG(width: 10, height: 10)
        XCTAssertThrowsError(try ImageTranscoder().transcode(input, declaredMIMEType: "image/jpeg")) { error in
            XCTAssertEqual(error as? ImageTranscoderError, .mimeMismatch(declared: "image/jpeg", detected: "image/png"))
        }
    }

    /// 在真正展开位图前依据元数据执行像素上限。
    func testRejectsPixelLimit() throws {
        let input = try makePNG(width: 20, height: 20)
        XCTAssertThrowsError(try ImageTranscoder(maximumPixels: 399).transcode(input)) { error in
            XCTAssertEqual(error as? ImageTranscoderError, .pixelLimitExceeded(actualPixels: 400, maximumPixels: 399))
        }
    }

    /// Pixabay 偶尔以 `.jpg` 地址返回 BMP；按真实魔数解码后仍必须交付标准 PNG。
    func testTranscodesBitmapInput() throws {
        let input = try makeImage(width: 64, height: 96, type: .bmp)
        XCTAssertTrue(input.starts(with: [0x42, 0x4D]))

        let output = try ImageTranscoder().transcode(input, declaredMIMEType: "image/x-ms-bmp")
        XCTAssertTrue(output.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 512)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 512)
    }

    /// File Provider 写入版本必须是精确固定大小，并仍能被 ImageIO 识别为 512×512 PNG。
    func testWritingProducesFixedSizeValidPNG() throws {
        let input = try makePNG(width: 80, height: 120)
        let outputURL = temporaryOutputURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try ImageTranscoder().transcode(input, writingTo: outputURL)
        let output = try Data(contentsOf: outputURL)
        XCTAssertEqual(output.count, ImageTranscoder.outputFileSize)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 512)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 512)
    }

    /// 每次测试使用独立目标，避免并行测试互相覆盖输出。
    private func temporaryOutputURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageFixedPNG-\(UUID().uuidString).png")
    }

    /// 生成带可选 orientation 的有效 PNG 测试夹具。
    private func makePNG(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
        try makeImage(width: width, height: height, type: .png, orientation: orientation)
    }

    /// 用 ImageIO 生成指定静态格式，覆盖服务地址后缀与真实内容不一致的情况。
    private func makeImage(
        width: Int,
        height: Int,
        type: UTType,
        orientation: Int? = nil
    ) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        )
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
