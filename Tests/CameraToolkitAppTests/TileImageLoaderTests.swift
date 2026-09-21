import AppKit
@testable import CameraToolkitApp
import XCTest

final class TileImageLoaderTests: XCTestCase {
    private func makeJPEG(width: Int = 1_200, height: Int = 800) throws -> URL {
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
            .appendingPathComponent("CameraToolkitTile-\(UUID().uuidString).jpg")
        try data.write(to: file)
        return file
    }

    func testPriorityRequestDecodesWithinBucket() async throws {
        let file = try makeJPEG()
        defer { try? FileManager.default.removeItem(at: file) }

        let loaded = await TileImageLoader.shared.image(
            for: file,
            maximumPixelSize: 2_400,
            priority: .veryHigh
        )
        let image = try XCTUnwrap(loaded)

        XCTAssertLessThanOrEqual(max(image.width, image.height), 2_400)
    }

    /// A hero-frame request joining an in-flight tile decode must get the
    /// same shared result — one decode feeds both waiters.
    func testConcurrentRequestsShareOneDecode() async throws {
        let file = try makeJPEG()
        defer { try? FileManager.default.removeItem(at: file) }
        TileImageLoader.shared.invalidate(url: file)

        async let tile = TileImageLoader.shared.image(for: file, maximumPixelSize: 384)
        async let hero = TileImageLoader.shared.image(
            for: file,
            maximumPixelSize: 384,
            priority: .veryHigh
        )
        let (tileImage, heroImage) = await (tile, hero)

        XCTAssertNotNil(tileImage)
        XCTAssertTrue(tileImage === heroImage)
    }
}
