import Foundation

/// What the NAS holds at the names a Move to Event is about to take, read
/// with one folder listing per destination folder (never a stat per file),
/// off the main actor with the move job. Nothing here writes.
///
/// The NAS follows a drive move by renaming the moved file's copy. That
/// rename never replaces anything, so a *different* file already sitting at
/// the new mirror path — debris of an older Buffer, a photo the catalog
/// never listed — leaves the copy where it was and the entry pointing at
/// the other file. The move avoids it: such a photo takes a free "(N)" name.
public final class EventMoveNASCheck: @unchecked Sendable {
    private let locations: EventStorageLocations
    private let root: String
    private let lock = NSLock()
    private var listings: [String: [String: DirectoryListingEntry]] = [:]

    public init(locations: EventStorageLocations) {
        self.locations = locations
        self.root = locations.nasRoot.standardizedFileURL.path
    }

    /// The entry at `relative` (a path under the NAS root), if any.
    func entry(_ relative: String) -> DirectoryListingEntry? {
        let folder = (relative as NSString).deletingLastPathComponent
        let name = NASSyncStore.pathKey((relative as NSString).lastPathComponent)
        let known: [String: DirectoryListingEntry]? = lock.withLock { listings[folder] }
        if let known { return known[name] }
        let listed = (try? DirectoryListing.list(root + "/" + folder)) ?? []
        let byName = Dictionary(listed.map { (NASSyncStore.pathKey($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        lock.withLock { listings[folder] = byName }
        return byName[name]
    }

    /// Anything at `relative`.
    public func holds(_ relative: String) -> Bool { entry(relative) != nil }

    /// Anything at the NAS mirror of a drive path (false for a path that has
    /// no mirror, such as one outside an event folder).
    public func holdsMirror(ofDrivePath path: String) -> Bool {
        guard let relative = mirror(path) else { return false }
        return holds(relative)
    }

    private func mirror(_ drivePath: String) -> String? {
        guard let relative = locations.mirrorRelativePath(forDrivePath: drivePath), NASMoveFollower.isEventPath(relative) else { return nil }
        return relative
    }

    /// True when `move` would land on a NAS path that holds a different file:
    /// another size, or the same size and other bytes (both hashed now), or
    /// one that cannot be read to tell. A move whose mirror path does not
    /// change (Buffer ↔ Private) or whose target holds nothing — or its own
    /// identical bytes, which the NAS rename merges — is no clash.
    func wouldClash(_ move: DriveMove, byteCount: Int64, hasher: (URL) throws -> String) -> Bool {
        guard let from = mirror(move.sourcePath), let to = mirror(move.destinationPath),
              NASSyncStore.pathKey(from) != NASSyncStore.pathKey(to),
              let held = entry(to) else { return false }
        guard held.kind == .file, held.size == byteCount else { return true }
        guard let ours = try? hasher(URL(fileURLWithPath: move.sourcePath)),
              let theirs = try? hasher(URL(fileURLWithPath: root + "/" + to)) else { return true }
        return ours != theirs
    }
}
