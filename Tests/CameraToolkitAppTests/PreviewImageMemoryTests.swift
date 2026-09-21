import AppKit
@testable import CameraToolkitApp
import XCTest

final class PreviewImageMemoryTests: XCTestCase {
    func testPreviewLoaderRejectsLargeNonImageCameraMetadata() {
        XCTAssertFalse(CameraPreviewSupport.canDecode(URL(fileURLWithPath: "/card/BODYDATA.DAT")))
        XCTAssertFalse(CameraPreviewSupport.canDecode(URL(fileURLWithPath: "/card/edit.photo-edit")))
        XCTAssertTrue(CameraPreviewSupport.canDecode(URL(fileURLWithPath: "/card/photo.ARW")))
        XCTAssertTrue(CameraPreviewSupport.canDecode(URL(fileURLWithPath: "/card/photo.JPG")))
    }

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

    func testAsyncPreviewPipelineReturnsBoundedDecodedImage() async throws {
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
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitPreviewPipeline-\(UUID().uuidString).jpg")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let loadedImage = await EmbeddedPreviewStore.shared.previewImage(
            from: file,
            preference: .thumbnail,
            maximumPixelSize: 160,
            priority: .utility
        )
        let image = try XCTUnwrap(loadedImage)

        XCTAssertLessThanOrEqual(max(image.width, image.height), 160)
    }
}
