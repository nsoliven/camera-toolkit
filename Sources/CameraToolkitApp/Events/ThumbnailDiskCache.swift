import CameraToolkitCore
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Tile-sized thumbnails of photos that live on the NAS or the Buffer drive,
/// kept on this Mac so a board that was scrolled once scrolls again without
/// reading the NAS. The in-memory cache holds a few hundred tiles; a family
/// board has thousands, and every one that fell out of memory was a network
/// round trip to get back.
///
/// The cache holds only what can be rebuilt from the originals: small JPEGs
/// under the app's Caches folder (never the library, never Application
/// Support), each named by a hash of the file's identity. Nothing here ever
/// touches, moves or deletes a photo — the only files this removes are its
/// own thumbnails, oldest first, when the folder outgrows its limit.
///
/// A photo's identity is its name, byte count and modification time — what
/// already follows a file between folders — so a thumbnail survives a Move
/// to Event, and an edited file (new size or time) gets a new one.
final class ThumbnailDiskCache: @unchecked Sendable {
    /// What the app's cache may hold. A grid tile is the 512 px bucket
    /// (220 pt at 2x), 512×341 at JPEG quality 0.82: about 2–4 bits a pixel
    /// for a real photo, so 45–85 KB. A 40,000-photo library is then
    /// 1.8–3.4 GB of tiles. Evicting to 80% still keeps the high end of that,
    /// with room left for filmstrip sizes, rotated copies and new photos.
    static let defaultByteLimit: Int64 = 5 * 1_024 * 1_024 * 1_024

    /// The app's cache: `~/Library/Caches/<app>/Thumbnails`. Nil when the
    /// system has no Caches folder to offer.
    static let appDefault: ThumbnailDiskCache? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches
            .appendingPathComponent("org.cameratoolkit.CameraToolkit", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        return ThumbnailDiskCache(folder: folder, byteLimit: defaultByteLimit)
    }()

    /// The largest decode bucket worth keeping: tiles and filmstrip frames.
    /// A full-screen preview is far bigger than the read it would save.
    static let largestBucket = 768

    let folder: URL
    let byteLimit: Int64
    private let queue = DispatchQueue(label: "CameraToolkit.ThumbnailDiskCache", qos: .utility)
    /// Total bytes on disk once counted; kept up to date by `store`. Only
    /// touched on `queue`.
    private var knownBytes: Int64?

    init(folder: URL, byteLimit: Int64) {
        self.folder = folder
        self.byteLimit = byteLimit
    }

    /// The key of one decode of one photo: identity, size bucket, rotation.
    static func key(fileIdentity: String, bucket: Int, orientation: Int) -> String {
        "\(fileIdentity)#\(bucket)#\(DisplayRotation.normalized(orientation))"
    }

    /// The file identity a photo's thumbnails are kept under.
    static func fileIdentity(_ file: OrganizeFile) -> String {
        FaceIndexStore.fileKey(fileName: file.name, byteCount: file.size, modifiedAt: file.modifiedAt)
    }

    // MARK: Reading

    /// The stored thumbnail, or nil. One small local file read — safe from
    /// any thread but the main one, which never asks.
    func image(forKey key: String) -> CGImage? {
        let url = fileURL(forKey: key)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            return nil
        }
        touchIfOld(url)
        return image
    }

    /// Whether a thumbnail is on disk. One local stat; never reads the photo.
    func contains(key: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forKey: key).path)
    }

    // MARK: Writing

    /// Keeps a thumbnail. Encoded and written on the cache's own queue —
    /// the caller is a decode that has already finished — through a
    /// temporary file renamed into place, so a half-written thumbnail is
    /// never read.
    func store(_ image: CGImage, forKey key: String) {
        queue.async { [self] in _ = write(image, forKey: key) }
    }

    /// `store`, waiting for the file to land. False when it could not be
    /// written. Background warming uses this so it never runs ahead of the
    /// disk, and so a full disk stops it instead of being retried per photo.
    func storeAndWait(_ image: CGImage, forKey key: String) -> Bool {
        queue.sync { write(image, forKey: key) }
    }

    /// Whether the folder has grown to where background warming should
    /// stop: 90% of the limit, under the size that triggers eviction, so
    /// warming never pushes out a thumbnail someone actually looked at.
    var isNearLimit: Bool {
        queue.sync {
            if knownBytes == nil { knownBytes = scanBytes() }
            return (knownBytes ?? 0) >= byteLimit / 10 * 9
        }
    }

    /// Runs on `queue`.
    private func write(_ image: CGImage, forKey key: String) -> Bool {
        guard let data = Self.encode(image) else { return false }
        let url = fileURL(forKey: key)
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            try data.write(to: temporary)
            if rename(temporary.path, url.path) != 0 {
                try? FileManager.default.removeItem(at: temporary)
                return false
            }
        } catch {
            return false
        }
        recordStore(bytes: Int64(data.count))
        return true
    }

    /// Waits for pending writes — for tests.
    func flush() { queue.sync {} }

    /// What the folder holds now, counted from disk — for tests.
    func measuredBytes() -> Int64 {
        queue.sync { scanBytes() }
    }

    // MARK: Internals

    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func fileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(digest + ".jpg", isDirectory: false)
    }

    /// A read renews the file's place in the eviction order, at most once an
    /// hour per file so scrolling never turns into a write per tile.
    private func touchIfOld(_ url: URL) {
        queue.async {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values?.contentModificationDate, Date().timeIntervalSince(modified) > 3_600 else { return }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
    }

    /// Runs on `queue`.
    private func recordStore(bytes: Int64) {
        if knownBytes == nil { knownBytes = scanBytes() } else { knownBytes = (knownBytes ?? 0) + bytes }
        if let known = knownBytes, known > byteLimit { evict() }
    }

    /// Runs on `queue`. Total size of the thumbnails on disk.
    private func scanBytes() -> Int64 {
        entries().reduce(Int64(0)) { $0 + $1.size }
    }

    private struct Entry {
        var url: URL
        var size: Int64
        var modified: Date
    }

    private func entries() -> [Entry] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [Entry] = []
        for case let url as URL in enumerator where Self.hasThumbnailName(url) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            result.append(Entry(url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
        }
        return result
    }

    /// The shape `fileURL` gives every thumbnail: `<2 hex>/<64 hex>.jpg`,
    /// the folder being the name's first two characters. Anything else that
    /// ended up in the folder is not ours to count or remove.
    private static func hasThumbnailName(_ url: URL) -> Bool {
        guard url.pathExtension == "jpg" else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        let isDigest = name.utf8.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        return isDigest && url.deletingLastPathComponent().lastPathComponent == String(name.prefix(2))
    }

    /// Whether a thumbnail's real location, with every symlink followed, is
    /// one shard folder directly under this cache's real folder. Asked
    /// before each removal.
    private func isInsideCacheFolder(_ url: URL, resolvedFolder: URL) -> Bool {
        url.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().path == resolvedFolder.path
    }

    /// Runs on `queue`. Removes the oldest thumbnails until the folder is at
    /// 80% of its limit, so one overflow does not trigger the next store.
    private func evict() {
        let all = entries().sorted { $0.modified < $1.modified }
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        let target = byteLimit / 5 * 4
        let resolvedFolder = folder.resolvingSymlinksInPath()
        for oldest in all {
            guard total > target else { break }
            guard isInsideCacheFolder(oldest.url, resolvedFolder: resolvedFolder) else { continue }
            if (try? FileManager.default.removeItem(at: oldest.url)) != nil { total -= oldest.size }
        }
        knownBytes = total
    }
}
