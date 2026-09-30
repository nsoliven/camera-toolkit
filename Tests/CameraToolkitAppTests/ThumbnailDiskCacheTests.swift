import AppKit
import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

/// Thumbnails of NAS photos kept on this Mac: what is stored, how a photo is
/// named, what is left alone, and that a second look at a photo never reads
/// the volume again. Everything happens in temporary folders — nothing here
/// touches the real Caches folder, Application Support, or a volume.
final class ThumbnailDiskCacheTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }

    private func scratch(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CameraToolkitThumbs-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    /// A gradient with grain, so it does not compress to nothing.
    private func makeImage(width: Int = 512, height: Int = 341, seed: UInt8 = 0) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        var rng = SystemRandomNumberGenerator()
        for y in 0..<height {
            for x in stride(from: 0, to: width, by: 8) {
                context.setFillColor(red: Double(x) / Double(width), green: Double(y) / Double(height), blue: Double((Int(seed) + x + y) % 255) / 255, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 8, height: 1))
            }
        }
        if let data = context.data {
            let pixels = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
            for i in stride(from: 0, to: context.bytesPerRow * height, by: 3) { pixels[i] = pixels[i] &+ UInt8.random(in: 0...20, using: &rng) }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func makeJPEG(in folder: URL, name: String = "DSC00001.JPG", width: Int = 1_800, height: Int = 1_200) throws -> URL {
        let image = try makeImage(width: width, height: height)
        let url = folder.appendingPathComponent(name)
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        try data.write(to: url)
        return url
    }

    private func file(_ url: URL, size: Int64 = 1_000, modified: TimeInterval = 1_772_000_000) -> OrganizeFile {
        OrganizeFile(path: url.path, size: size, modifiedAt: Date(timeIntervalSince1970: modified))
    }

    // MARK: The cache

    func testAStoredThumbnailComesBackAtItsSize() throws {
        let cache = ThumbnailDiskCache(folder: scratch("roundtrip"), byteLimit: 10_000_000)
        let image = try makeImage()
        cache.store(image, forKey: "a#512#0")
        cache.flush()
        let back = try XCTUnwrap(cache.image(forKey: "a#512#0"))
        XCTAssertEqual(back.width, image.width)
        XCTAssertEqual(back.height, image.height)
        XCTAssertNil(cache.image(forKey: "b#512#0"))
    }

    func testTheKeyNamesTheFileTheSizeAndTheRotation() {
        let one = ThumbnailDiskCache.key(fileIdentity: "id", bucket: 512, orientation: 0)
        XCTAssertNotEqual(one, ThumbnailDiskCache.key(fileIdentity: "id", bucket: 384, orientation: 0))
        XCTAssertNotEqual(one, ThumbnailDiskCache.key(fileIdentity: "id", bucket: 512, orientation: 1))
        XCTAssertNotEqual(one, ThumbnailDiskCache.key(fileIdentity: "other", bucket: 512, orientation: 0))
        // A full turn is no turn.
        XCTAssertEqual(one, ThumbnailDiskCache.key(fileIdentity: "id", bucket: 512, orientation: 4))
    }

    func testAPhotoKeepsItsIdentityWhenItMovesButNotWhenItChanges() {
        let a = OrganizeFile(path: "/Volumes/nas_share/2026/Trip/Originals/Cam A/DSC00001.ARW", size: 100, modifiedAt: Date(timeIntervalSince1970: 1_772_000_000))
        let moved = OrganizeFile(path: "/Volumes/nas_share/2026/Other/Originals/Cam A/DSC00001.ARW", size: 100, modifiedAt: Date(timeIntervalSince1970: 1_772_000_000))
        let edited = OrganizeFile(path: a.path, size: 101, modifiedAt: a.modifiedAt)
        let touched = OrganizeFile(path: a.path, size: 100, modifiedAt: Date(timeIntervalSince1970: 1_772_000_500))
        XCTAssertEqual(ThumbnailDiskCache.fileIdentity(a), ThumbnailDiskCache.fileIdentity(moved))
        XCTAssertNotEqual(ThumbnailDiskCache.fileIdentity(a), ThumbnailDiskCache.fileIdentity(edited))
        XCTAssertNotEqual(ThumbnailDiskCache.fileIdentity(a), ThumbnailDiskCache.fileIdentity(touched))
    }

    func testTheFolderStaysUnderItsLimitAndTheOldestThumbnailsGoFirst() throws {
        let folder = scratch("limit")
        let probe = try makeImage()
        let single = ThumbnailDiskCache(folder: scratch("probe"), byteLimit: 100_000_000)
        single.store(probe, forKey: "size")
        single.flush()
        let oneSize = single.measuredBytes()
        XCTAssertGreaterThan(oneSize, 1_000)

        // Room for about six thumbnails.
        let cache = ThumbnailDiskCache(folder: folder, byteLimit: oneSize * 6)
        for index in 0..<14 {
            cache.store(try makeImage(seed: UInt8(index)), forKey: "photo\(index)")
            cache.flush()
            // Distinct modification times, oldest first.
            let url = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
                .first { $0.pathExtension == "jpg" && !seenPaths.contains($0.path) })
            seenPaths.insert(url.path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 100))], ofItemAtPath: url.path)
        }
        cache.flush()
        XCTAssertLessThanOrEqual(cache.measuredBytes(), oneSize * 6, "the folder is held to its limit")
        XCTAssertNotNil(cache.image(forKey: "photo13"), "the newest survive")
        XCTAssertNil(cache.image(forKey: "photo0"), "the oldest are the ones removed")
    }

    private var seenPaths: Set<String> = []

    func testOnlyThumbnailsAreEverRemovedAndNoTemporaryFileIsLeftBehind() throws {
        let folder = scratch("safe")
        let bystander = folder.appendingPathComponent("note.txt")
        try Data("keep".utf8).write(to: bystander)
        let cache = ThumbnailDiskCache(folder: folder, byteLimit: 2_000)
        for index in 0..<10 { cache.store(try makeImage(seed: UInt8(index)), forKey: "k\(index)") }
        cache.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander.path), "a file that is not a thumbnail is never removed")
        let stray = FileManager.default.enumerator(atPath: folder.path)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".tmp") } ?? []
        XCTAssertTrue(stray.isEmpty, "temporary files are renamed into place, not left")
    }

    func testTheDefaultCacheLivesInCachesNeverInTheLibraryOrApplicationSupport() throws {
        let folder = try XCTUnwrap(ThumbnailDiskCache.appDefault).folder
        XCTAssertTrue(folder.path.contains("/Library/Caches/"), folder.path)
        XCTAssertFalse(folder.path.contains("Application Support"), folder.path)
        XCTAssertEqual(folder.lastPathComponent, "Thumbnails")
    }

    // MARK: The loader

    /// Counts reads of the "volume" the loader makes.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [String] = []
        var count: Int { lock.withLock { _urls.count } }
        func note(_ url: URL) { lock.withLock { _urls.append(url.path) } }
    }

    private func makeLoader(cache: ThumbnailDiskCache?, reads: Reads, network: @escaping @Sendable (URL) -> Bool = { _ in true }) -> TileImageLoader {
        TileImageLoader(
            driveActivityGate: DriveActivityGate(),
            willRead: { reads.note($0) },
            purgesOnMemoryPressure: false,
            thumbnailCache: cache,
            networkVolumeCheck: network
        )
    }

    func testASecondLookAtAPhotoOnTheNASNeverReadsTheVolume() async throws {
        let volume = scratch("volume")
        let source = try makeJPEG(in: volume)
        let reads = Reads()
        let cache = ThumbnailDiskCache(folder: scratch("cache"), byteLimit: 50_000_000)
        let loader = makeLoader(cache: cache, reads: reads)
        let identity = ThumbnailDiskCache.fileIdentity(file(source))

        let first = await loader.image(for: source, maximumPixelSize: 512, fileIdentity: identity)
        XCTAssertNotNil(first)
        XCTAssertEqual(reads.count, 1, "the first look reads the photo")
        cache.flush()

        // Memory forgets (a warning, a long scroll); the disk still has it.
        loader.purgeForMemoryPressure()
        let secondLook = await loader.image(for: source, maximumPixelSize: 512, fileIdentity: identity)
        let second = try XCTUnwrap(secondLook)
        XCTAssertEqual(reads.count, 1, "the second look is served from this Mac")
        XCTAssertLessThanOrEqual(max(second.width, second.height), 512)

        // Even with the volume gone.
        try FileManager.default.removeItem(at: source)
        loader.purgeForMemoryPressure()
        let third = await loader.image(for: source, maximumPixelSize: 512, fileIdentity: identity)
        XCTAssertNotNil(third, "a thumbnail already made does not need the photo")
        XCTAssertEqual(reads.count, 1)
    }

    func testAMovedPhotoIsFoundUnderItsNewPath() async throws {
        let volume = scratch("moved")
        let source = try makeJPEG(in: volume, name: "DSC00002.JPG")
        let reads = Reads()
        let cache = ThumbnailDiskCache(folder: scratch("cache2"), byteLimit: 50_000_000)
        let loader = makeLoader(cache: cache, reads: reads)
        let identity = ThumbnailDiskCache.fileIdentity(file(source))
        _ = await loader.image(for: source, maximumPixelSize: 512, fileIdentity: identity)
        cache.flush()
        loader.purgeForMemoryPressure()

        let elsewhere = volume.appendingPathComponent("Other Event", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let renamed = elsewhere.appendingPathComponent("DSC00002.JPG")
        try FileManager.default.moveItem(at: source, to: renamed)
        let again = await loader.image(for: renamed, maximumPixelSize: 512, fileIdentity: identity)
        XCTAssertNotNil(again)
        XCTAssertEqual(reads.count, 1, "the photo's name, size and time — not its folder — name its thumbnail")
    }

    func testNothingIsKeptForLocalFilesUnnamedPhotosOrBigDecodes() async throws {
        let volume = scratch("skipped")
        let source = try makeJPEG(in: volume, name: "DSC00003.JPG")
        let identity = ThumbnailDiskCache.fileIdentity(file(source))

        // A drive that is not a network volume.
        var reads = Reads()
        var cache = ThumbnailDiskCache(folder: scratch("c-local"), byteLimit: 50_000_000)
        var loader = makeLoader(cache: cache, reads: reads, network: { _ in false })
        _ = await loader.image(for: source, maximumPixelSize: 512, fileIdentity: identity)
        cache.flush()
        XCTAssertEqual(cache.measuredBytes(), 0)

        // No identity to name it by.
        reads = Reads()
        cache = ThumbnailDiskCache(folder: scratch("c-unnamed"), byteLimit: 50_000_000)
        loader = makeLoader(cache: cache, reads: reads)
        _ = await loader.image(for: source, maximumPixelSize: 512)
        cache.flush()
        XCTAssertEqual(cache.measuredBytes(), 0)

        // A large decode (a preview) is not a tile.
        cache = ThumbnailDiskCache(folder: scratch("c-big"), byteLimit: 50_000_000)
        loader = makeLoader(cache: cache, reads: reads)
        _ = await loader.image(for: source, maximumPixelSize: 1_600, fileIdentity: identity)
        cache.flush()
        XCTAssertEqual(cache.measuredBytes(), 0)
    }

    func testAChangedPhotoGetsANewThumbnail() async throws {
        let volume = scratch("changed")
        let source = try makeJPEG(in: volume, name: "DSC00004.JPG")
        let reads = Reads()
        let cache = ThumbnailDiskCache(folder: scratch("cache3"), byteLimit: 50_000_000)
        let loader = makeLoader(cache: cache, reads: reads)
        _ = await loader.image(for: source, maximumPixelSize: 512, fileIdentity: ThumbnailDiskCache.fileIdentity(file(source, size: 1_000)))
        cache.flush()
        loader.purgeForMemoryPressure()
        // Edited on the NAS: the same name, another size.
        _ = await loader.image(for: source, maximumPixelSize: 512, fileIdentity: ThumbnailDiskCache.fileIdentity(file(source, size: 2_000)))
        XCTAssertEqual(reads.count, 2, "a photo that changed is read again, not shown from its old thumbnail")
    }
}
