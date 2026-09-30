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

    /// The decode buckets pin every size a tile or preview can land on —
    /// the 512 rung exists so a Retina-sized request doesn't round up to
    /// the much larger 768 bitmap.
    func testDecodeBuckets() {
        XCTAssertEqual(TileImageLoader.bucket(for: 200), 384)
        XCTAssertEqual(TileImageLoader.bucket(for: 384), 384)
        XCTAssertEqual(TileImageLoader.bucket(for: 385), 512)
        XCTAssertEqual(TileImageLoader.bucket(for: 512), 512)
        XCTAssertEqual(TileImageLoader.bucket(for: 513), 768)
        XCTAssertEqual(TileImageLoader.bucket(for: 768), 768)
        XCTAssertEqual(TileImageLoader.bucket(for: 1_000), 1_280)
        XCTAssertEqual(TileImageLoader.bucket(for: 2_000), 2_400)
        XCTAssertEqual(TileImageLoader.bucket(for: 9_999), 4_800)
    }

    /// The tile cache is capped well under a gigabyte of bitmaps, and the
    /// few multi-tens-of-MB zoom previews get their own small allowance so
    /// they cannot evict every filmstrip tile.
    func testCacheCostLimits() {
        let loader = TileImageLoader()
        XCTAssertEqual(loader.tileCacheCostLimit, 320 * 1_024 * 1_024)
        XCTAssertEqual(loader.previewCacheCostLimit, 192 * 1_024 * 1_024)
    }

    /// A finished decode is served from the cache; a memory-pressure purge
    /// drops both the tile and the preview stores so the app sheds bitmaps
    /// when the system asks.
    func testPurgeForMemoryPressureClearsBothCaches() async throws {
        // No memory-pressure source of its own: under a loaded full-suite
        // run the machine raises real warnings, and an NSCache may also shed
        // entries on its own. Either empties the caches between the decode
        // and the look, so the fill is retried until both hold.
        let loader = TileImageLoader(purgesOnMemoryPressure: false)
        let file = try makeJPEG()
        defer { try? FileManager.default.removeItem(at: file) }

        var filled = false
        for _ in 0..<10 where !filled {
            _ = await loader.image(for: file, maximumPixelSize: 384)
            _ = await loader.image(for: file, maximumPixelSize: 4_800)
            filled = loader.cachedImage(for: file, maximumPixelSize: 384) != nil
                && loader.cachedImage(for: file, maximumPixelSize: 4_800) != nil
        }
        XCTAssertTrue(filled, "both decodes were cached")

        loader.purgeForMemoryPressure()
        XCTAssertNil(loader.cachedImage(for: file, maximumPixelSize: 384))
        XCTAssertNil(loader.cachedImage(for: file, maximumPixelSize: 4_800))
    }
}
