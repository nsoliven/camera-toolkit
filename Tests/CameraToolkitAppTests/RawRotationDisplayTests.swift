import AppKit
import CameraToolkitCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CameraToolkitApp

/// Builds a TIFF-based RAW whose embedded JPEG is drawn so a test can tell
/// which way up it came out: red down its left side, the rest white with a
/// green square, on a landscape frame. Only the orientation tag varies.
enum SyntheticRAW {
    static func jpeg(width: Int, height: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 4, height: height))
        // CoreGraphics is bottom-up: this is the square's stored "face",
        // near the top of the unrotated frame.
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(greenSquare(in: CGRect(x: 0, y: 0, width: width, height: height)))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// The green square as CoreGraphics draws it, bottom-left origin.
    static func greenSquare(in frame: CGRect) -> CGRect {
        CGRect(x: frame.width * 0.55, y: frame.height * 0.6, width: frame.width * 0.2, height: frame.height * 0.3)
    }

    /// A little-endian TIFF: IFD0 with an optional orientation tag and the
    /// JPEG preview pointer.
    static func file(orientation: UInt16?, width: Int, height: Int) -> Data {
        let jpeg = jpeg(width: width, height: height)
        var entries: [(tag: UInt16, type: UInt16, value: UInt32)] = []
        if let orientation { entries.append((0x0112, 3, UInt32(orientation))) }
        let jpegOffset = 512
        entries.append((0x0201, 4, UInt32(jpegOffset)))
        entries.append((0x0202, 4, UInt32(jpeg.count)))
        var bytes = Data(repeating: 0, count: jpegOffset + jpeg.count)
        bytes[0] = 0x49
        bytes[1] = 0x49
        bytes[2] = 42
        bytes[4] = 8
        bytes[8] = UInt8(entries.count)
        for (index, entry) in entries.enumerated() {
            let base = 10 + index * 12
            bytes[base] = UInt8(entry.tag & 0xff)
            bytes[base + 1] = UInt8(entry.tag >> 8)
            bytes[base + 2] = UInt8(entry.type)
            bytes[base + 4] = 1
            for byte in 0..<4 { bytes[base + 8 + byte] = UInt8((entry.value >> (byte * 8)) & 0xff) }
        }
        bytes.replaceSubrange(jpegOffset..<(jpegOffset + jpeg.count), with: jpeg)
        return bytes
    }

    /// What the extractor sees as a RAW with no preview to pull out: a file
    /// that is not a TIFF at all, which ImageIO decodes whole and whose
    /// orientation ImageIO applies itself.
    static func fileWithoutPreview(orientation: Int, width: Int, height: Int) -> Data {
        let source = CGImageSourceCreateWithData(jpeg(width: width, height: height) as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

/// What the camera recorded in a RAW reaches the picture and the boxes over
/// it, and only there: no double rotation, saved rotations left alone,
/// nothing on disk changed.
final class RawRotationDisplayTests: XCTestCase {
    private enum Side { case left, right, top, bottom }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("RawRotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func raw(orientation: UInt16?, name: String = "DSC00001.ARW") throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try SyntheticRAW.file(orientation: orientation, width: 600, height: 400).write(to: url)
        return url
    }

    /// Pixel color at a top-left-origin normalized point, as drawn.
    private func color(of image: CGImage, x: Double, y: Double) -> (r: UInt8, g: UInt8, b: UInt8) {
        var pixels = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixels, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .none
        let px = -CGFloat(x) * CGFloat(image.width) + 0.5
        let py = -CGFloat(1 - y) * CGFloat(image.height) + 0.5
        context.draw(image, in: CGRect(x: px, y: py, width: CGFloat(image.width), height: CGFloat(image.height)))
        return (pixels[0], pixels[1], pixels[2])
    }

    /// Which edge of the bitmap the red band ended up on.
    private func redSide(of image: CGImage) -> Side? {
        let probes: [(Side, Double, Double)] = [(.left, 0.03, 0.5), (.right, 0.97, 0.5), (.top, 0.5, 0.03), (.bottom, 0.5, 0.97)]
        return probes.first { _, x, y in
            let sample = color(of: image, x: x, y: y)
            return sample.r > 200 && sample.g < 60 && sample.b < 60
        }?.0
    }

    private func isGreen(_ image: CGImage, at point: (x: Double, y: Double)) -> Bool {
        let sample = color(of: image, x: point.x, y: point.y)
        return sample.g > 200 && sample.r < 60 && sample.b < 60
    }

    func testEachOrientationTagStandsTheExtractedPreviewUpright() throws {
        let expected: [(tag: UInt16?, side: Side, portrait: Bool, turns: Int)] = [
            (nil, .left, false, 0),
            (1, .left, false, 0),
            (6, .top, true, 1),
            (3, .right, false, 2),
            (8, .bottom, true, 3),
        ]
        for (index, entry) in expected.enumerated() {
            let url = try raw(orientation: entry.tag, name: "DSC0000\(index).ARW")
            let decoded = try XCTUnwrap(TileImageLoader.decode(url: url, maximumPixelSize: 384))
            XCTAssertEqual(decoded.cameraTurns, entry.turns, "tag \(String(describing: entry.tag))")
            XCTAssertEqual(decoded.image.height > decoded.image.width, entry.portrait, "tag \(String(describing: entry.tag))")
            XCTAssertEqual(redSide(of: decoded.image), entry.side, "tag \(String(describing: entry.tag))")
        }
    }

    func testBothSizesOfTheExtractedPreviewTurn() throws {
        let url = try raw(orientation: 8)
        for size in [384, 2_400] {
            let decoded = try XCTUnwrap(TileImageLoader.decode(url: url, maximumPixelSize: size))
            XCTAssertEqual(redSide(of: decoded.image), .bottom, "\(size) px")
        }
    }

    func testASavedEntryOverridesTheCameraInThePixels() throws {
        let url = try raw(orientation: 8)

        let savedZero = try XCTUnwrap(TileImageLoader.decode(url: url, maximumPixelSize: 384, orientation: 0))
        XCTAssertEqual(redSide(of: savedZero.image), .left, "a saved 0 is the unrotated preview")

        let savedOne = try XCTUnwrap(TileImageLoader.decode(url: url, maximumPixelSize: 384, orientation: 1))
        XCTAssertEqual(redSide(of: savedOne.image), .top, "a saved 1 is one turn from unrotated, the camera ignored")
        XCTAssertEqual(savedOne.cameraTurns, 3, "the camera's turn is learned even when it is overridden")
    }

    func testRawWithNoEmbeddedJPEGIsTurnedOnceByImageIO() throws {
        let url = scratch.appendingPathComponent("DSC00002.ARW")
        try SyntheticRAW.fileWithoutPreview(orientation: 6, width: 600, height: 400).write(to: url)

        let decoded = try XCTUnwrap(TileImageLoader.decode(url: url, maximumPixelSize: 384))

        XCTAssertEqual(decoded.cameraTurns, 0, "ImageIO already applied the rotation")
        XCTAssertGreaterThan(decoded.image.height, decoded.image.width, "turned exactly once: still portrait")
        XCTAssertEqual(redSide(of: decoded.image), .top)
    }

    func testAJPEGStaysAsImageIODecodesIt() throws {
        let url = scratch.appendingPathComponent("DSC00003.JPG")
        let source = CGImageSourceCreateWithData(SyntheticRAW.jpeg(width: 600, height: 400) as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let decoded = try XCTUnwrap(TileImageLoader.decode(url: url, maximumPixelSize: 384))

        XCTAssertNil(decoded.cameraTurns, "only RAWs carry a camera turn for the display")
        XCTAssertGreaterThan(decoded.image.height, decoded.image.width, "ImageIO turned it, and only ImageIO")
        XCTAssertEqual(redSide(of: decoded.image), .top)
        let loader = TileImageLoader()
        XCTAssertEqual(loader.knownCameraTurns(for: url), 0)
    }

    // MARK: Keys

    func testMemoryCacheKeepsAutomaticAndSavedDecodesApart() async throws {
        let url = try raw(orientation: 8)
        let loader = TileImageLoader()

        let automatic = await loader.image(for: url, maximumPixelSize: 384)
        XCTAssertEqual(try XCTUnwrap(automatic).height > (automatic?.width ?? 0), true)
        XCTAssertNotNil(loader.cachedImage(for: url, maximumPixelSize: 384))
        XCTAssertNil(loader.cachedImage(for: url, maximumPixelSize: 384, orientation: 0), "the saved-0 decode is a different picture")

        let savedZero = await loader.image(for: url, maximumPixelSize: 384, orientation: 0)
        XCTAssertEqual(savedZero.map { $0.width > $0.height }, true)

        loader.invalidate(url: url)
        XCTAssertNil(loader.cachedImage(for: url, maximumPixelSize: 384), "the automatic decode is dropped too")
    }

    func testTheDiskKeyDiffersFromTheOldFormatAndTheAutomaticCaseIsItsOwnEntry() {
        let automatic = ThumbnailDiskCache.key(fileIdentity: "id", bucket: 512, orientation: nil)
        XCTAssertNotEqual(automatic, "id#512#0", "an old sideways entry must never be reused")
        XCTAssertNotEqual(automatic, ThumbnailDiskCache.key(fileIdentity: "id", bucket: 512, orientation: 0))
    }

    func testTheCameraTurnsTravelWithAThumbnail() throws {
        let cache = ThumbnailDiskCache(folder: scratch.appendingPathComponent("cache"), byteLimit: 10_000_000)
        let image = try XCTUnwrap(TileImageLoader.decode(url: raw(orientation: 8), maximumPixelSize: 384)).image

        XCTAssertTrue(cache.storeAndWait(image, cameraTurns: 3, forKey: "k"))
        XCTAssertTrue(cache.storeAndWait(image, forKey: "photo"))

        XCTAssertEqual(try XCTUnwrap(cache.thumbnail(forKey: "k")).cameraTurns, 3)
        XCTAssertNil(try XCTUnwrap(cache.thumbnail(forKey: "photo")).cameraTurns)
    }

    func testWarmerAndTileShareOneEntry() async throws {
        let url = try raw(orientation: 8)
        let cache = ThumbnailDiskCache(folder: scratch.appendingPathComponent("cache"), byteLimit: 10_000_000)
        let file = OrganizeFile(path: url.path, size: 1_000, modifiedAt: Date(timeIntervalSince1970: 1_772_000_000))
        let identity = ThumbnailDiskCache.fileIdentity(file)
        let bucket = TileImageLoader.bucket(for: 512)

        // What the plan keys a RAW with no saved entry on.
        let key = ThumbnailDiskCache.key(fileIdentity: identity, bucket: bucket, orientation: nil)
        let decoded = try XCTUnwrap(TileImageLoader.decode(url: url, maximumPixelSize: bucket, orientation: nil))
        XCTAssertTrue(cache.storeAndWait(decoded.image, cameraTurns: decoded.cameraTurns, forKey: key))

        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var reads = 0
        }
        let counter = Counter()
        let loader = TileImageLoader(
            willRead: { _ in counter.lock.withLock { counter.reads += 1 } },
            thumbnailCache: cache,
            networkVolumeCheck: { _ in false },
            mountedVolumeCheck: { _ in true }
        )

        // The tile asks with the same request and finds the warmer's work.
        let tile = await loader.image(for: url, maximumPixelSize: 512, fileIdentity: identity)
        XCTAssertEqual(counter.reads, 0, "the warmer's thumbnail answered; the photo was not read")
        let shown = try XCTUnwrap(tile)
        XCTAssertGreaterThan(shown.height, shown.width, "and it is upright")
        XCTAssertEqual(loader.knownCameraTurns(for: url), 3, "a cached thumbnail still knows the camera's turn")
    }

    func testOlderLayoutsAreRemovedAndNothingElseIs() throws {
        let folder = scratch.appendingPathComponent("cache", isDirectory: true)
        let cache = ThumbnailDiskCache(folder: folder, byteLimit: 10_000_000)
        let digest = "ab" + String(repeating: "0", count: 62)
        let shard = folder.appendingPathComponent("ab", isDirectory: true)
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        let oldThumb = shard.appendingPathComponent(digest + ".jpg")
        try Data("old sideways thumbnail".utf8).write(to: oldThumb)
        let stranger = shard.appendingPathComponent("not-a-thumbnail.txt")
        try Data("left alone".utf8).write(to: stranger)
        let topLevelStranger = folder.appendingPathComponent("notes.txt")
        try Data("left alone".utf8).write(to: topLevelStranger)
        let image = try XCTUnwrap(TileImageLoader.decode(url: raw(orientation: 6), maximumPixelSize: 384)).image
        XCTAssertTrue(cache.storeAndWait(image, forKey: "new-entry"))

        cache.removeOlderLayouts()
        cache.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldThumb.path), "an old thumbnail is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path), "a file that is not a thumbnail stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: topLevelStranger.path))
        XCTAssertNotNil(cache.thumbnail(forKey: "new-entry"), "a current thumbnail stays")
    }

    // MARK: Boxes

    func testAStoredBoxStaysOnTheFaceOfAnAutoRotatedRaw() async throws {
        // Stored boxes are in the unrotated preview: this is the green
        // square as a box, bottom-left-normalized like detection writes it.
        let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let square = SyntheticRAW.greenSquare(in: frame)
        let box = NormalizedFaceBox(
            x: square.minX / frame.width,
            y: square.minY / frame.height,
            width: square.width / frame.width,
            height: square.height / frame.height
        )
        for tag: UInt16 in [1, 3, 6, 8] {
            let url = try raw(orientation: tag, name: "DSC1\(tag).ARW")
            let loader = TileImageLoader()
            let loaded = await loader.image(for: url, maximumPixelSize: 2_400)
            let shown = try XCTUnwrap(loaded)
            let turns = loader.effectiveTurns(saved: nil, for: url)
            let rect = FaceBoxProjection.rotatedTopLeftRect(FaceBoxProjection.topLeftRect(of: box), quarterTurnsCW: turns)
            XCTAssertTrue(isGreen(shown, at: (rect.midX, rect.midY)), "tag \(tag): the mapped box lands on the square")
        }
    }

    func testABoxDrawnOnAnAutoRotatedRawIsStoredInUnrotatedSpace() async throws {
        let url = try raw(orientation: 6)
        let loader = TileImageLoader()
        _ = await loader.image(for: url, maximumPixelSize: 2_400)
        let turns = loader.effectiveTurns(saved: nil, for: url)
        XCTAssertEqual(turns, 1)

        let drawn = CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.1)
        let stored = FaceBoxProjection.unrotatedTopLeftRect(drawn, quarterTurnsCW: turns)
        let back = FaceBoxProjection.rotatedTopLeftRect(stored, quarterTurnsCW: turns)
        XCTAssertEqual(back.minX, drawn.minX, accuracy: 1e-9)
        XCTAssertEqual(back.minY, drawn.minY, accuracy: 1e-9)
        XCTAssertNotEqual(stored.minX, drawn.minX, "stored in the unrotated preview, not the display")
    }
}
