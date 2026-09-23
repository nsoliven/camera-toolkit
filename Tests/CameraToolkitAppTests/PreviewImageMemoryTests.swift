import AppKit
@testable import CameraToolkitApp
import XCTest

final class PreviewImageMemoryTests: XCTestCase {
    /// The spinner names the file's actual format — a PNG never reads as
    /// "embedded JPEG", a RAW always reads as the embed it carries.
    func testLoadingMessageMatchesFileKind() {
        XCTAssertEqual(
            PreviewLoadMessage.title(for: URL(fileURLWithPath: "/card/photo.ARW")),
            "Reading embedded JPEG…"
        )
        XCTAssertEqual(
            PreviewLoadMessage.title(for: URL(fileURLWithPath: "/card/photo.DNG")),
            "Reading embedded JPEG…"
        )
        XCTAssertEqual(
            PreviewLoadMessage.title(for: URL(fileURLWithPath: "/card/photo.JPG")),
            "Reading JPEG…"
        )
        XCTAssertEqual(
            PreviewLoadMessage.title(for: URL(fileURLWithPath: "/card/photo.png")),
            "Reading PNG…"
        )
        XCTAssertEqual(
            PreviewLoadMessage.title(for: URL(fileURLWithPath: "/card/clip.MP4")),
            "Reading video frame…"
        )
        XCTAssertEqual(PreviewLoadMessage.title(for: nil), "Reading preview…")
    }

    func testThumbnailDecoderCapsDecodedPixelDimensions() throws {
        let width = 1_200
        let height = 800
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4,
                bitsPerPixel: 32
            )
        )
        let data = try XCTUnwrap(representation.representation(using: .jpeg, properties: [:]))
        let image = try XCTUnwrap(PreviewImageDecoder.image(data: data, maximumPixelSize: 128))
        var proposedRect = NSRect(origin: .zero, size: image.size)
        let decoded = try XCTUnwrap(
            image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        )

        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 128)
    }
}
