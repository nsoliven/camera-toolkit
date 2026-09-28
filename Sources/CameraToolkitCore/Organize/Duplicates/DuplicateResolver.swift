import Foundation

/// "Keep in `keep` only" for one duplicate group: the copies `drop` holds
/// go to Trash and their assignments go with them.
public struct DuplicateResolution: Sendable {
    public var group: DuplicateGroup
    public var keep: DuplicateOwner
    public var drop: Set<DuplicateOwner>

    public init(group: DuplicateGroup, keep: DuplicateOwner, drop: Set<DuplicateOwner>) {
        self.group = group
        self.keep = keep
        self.drop = drop.subtracting([keep])
    }
}

/// A copy the resolver left exactly as it was, and why.
public struct DuplicateRefusal: Hashable, Sendable {
    public var copy: DuplicateCopy
    public var reason: String

    public init(copy: DuplicateCopy, reason: String) {
        self.copy = copy
        self.reason = reason
    }
}

public struct DuplicateResolutionOutcome: Sendable {
    /// The `_Trash` batch holding the removed copies — restorable from the
    /// Trash window like any other batch. Nil when nothing moved.
    public var trashBatch: MediaTrashBatch?
    /// Copies renamed into Trash.
    public var trashed: [DuplicateCopy] = []
    /// Copies whose file stays — the same file as the kept copy, or one
    /// another assignment still uses — so only the assignment goes.
    public var unassigned: [DuplicateCopy] = []
    /// Assignments of every trashed or unassigned copy: what the catalog
    /// must drop, in one save.
    public var removedAssignments: [PhotoEventAssignment] = []
    public var refused: [DuplicateRefusal] = []

    public init() {}

    public var trashedBytes: Int64 { trashed.reduce(Int64(0)) { $0 + $1.byteCount } }
    /// Every copy that left its owner, trashed or unassigned.
    public var resolvedCopyIDs: Set<String> { Set((trashed + unassigned).map(\.id)) }
}

/// Acts on a reviewed duplicate group. Before anything moves it re-reads
/// both sides from disk: a kept copy that no longer hashes to the group's
/// SHA-256 stops the whole group, and a dropped copy that does not match is
/// left untouched with its assignment. Matching copies are renamed into the
/// drive's `_Trash` through `MediaTrashService` — one batch, manifest
/// first, never a copy or a delete — so the Trash window can put them
/// back. The scan's cached hashes are never trusted here.
public struct DuplicateResolver {
    public typealias Hasher = @Sendable (URL) throws -> String

    private let trash: MediaTrashService
    private let hasher: Hasher

    public init(trash: MediaTrashService, hasher: @escaping Hasher = { try FileScanner.sha256($0) }) {
        self.trash = trash
        self.hasher = hasher
    }

    /// `protectedPathKeys`: files other assignments still point at — those
    /// copies lose their assignment but stay on disk.
    public func resolve(
        _ resolutions: [DuplicateResolution],
        protectedPathKeys: Set<String> = [],
        context: TrashContext = TrashContext(),
        progress: FileOperationProgressHandler? = nil
    ) throws -> DuplicateResolutionOutcome {
        var outcome = DuplicateResolutionOutcome()
        var toTrash: [DuplicateCopy] = []
        var trashKeys: Set<String> = []
        let total = resolutions.reduce(0) { $0 + $1.group.copies.count }
        var processed = 0
        var limiter = FileOperationProgressLimiter()

        func tick(_ copy: DuplicateCopy) {
            processed += 1
            if limiter.shouldEmit(force: processed == total) {
                progress?(FileOperationProgress(
                    phase: "Rechecking",
                    currentPath: copy.fileName,
                    processedFiles: processed,
                    totalFiles: total,
                    processedBytes: 0,
                    totalBytes: 0
                ))
            }
        }

        for resolution in resolutions {
            let group = resolution.group
            let dropped = group.copies.filter { resolution.drop.contains($0.owner) }
            guard !dropped.isEmpty else { continue }

            // Every kept copy that still exists, and at least one of them
            // proven byte-identical to the scan right now.
            var keptIdentities: Set<String> = []
            var keptVerified = false
            for copy in group.copies(of: resolution.keep) {
                tick(copy)
                guard let facts = DuplicateFileFacts.read(copy.path) else { continue }
                keptIdentities.insert(facts.identity)
                if !keptVerified, facts.byteCount == group.byteCount,
                   (try? hasher(URL(fileURLWithPath: copy.path))) == group.sha256 {
                    keptVerified = true
                }
            }
            guard keptVerified else {
                for copy in dropped {
                    outcome.refused.append(DuplicateRefusal(
                        copy: copy,
                        reason: "The copy being kept is missing or changed since the scan, so nothing was moved. Scan again."
                    ))
                }
                continue
            }

            for copy in dropped {
                tick(copy)
                guard let facts = DuplicateFileFacts.read(copy.path) else {
                    outcome.refused.append(DuplicateRefusal(copy: copy, reason: "The file is no longer at \(copy.path)."))
                    continue
                }
                if keptIdentities.contains(facts.identity) {
                    // One file reached twice: trashing it would trash the
                    // photo being kept. Only the extra assignment goes.
                    outcome.unassigned.append(copy)
                    continue
                }
                guard facts.byteCount == group.byteCount,
                      let hash = try? hasher(URL(fileURLWithPath: copy.path)) else {
                    outcome.refused.append(DuplicateRefusal(copy: copy, reason: "Could not read the file to recheck it. It was left in place."))
                    continue
                }
                guard hash == group.sha256 else {
                    outcome.refused.append(DuplicateRefusal(copy: copy, reason: "The file changed since the scan and no longer matches. It was left in place."))
                    continue
                }
                if protectedPathKeys.contains(copy.pathKey) {
                    outcome.unassigned.append(copy)
                } else if trashKeys.insert(copy.pathKey).inserted {
                    toTrash.append(copy)
                } else {
                    // Two dropped owners held this one file: trashed once,
                    // both assignments go.
                    outcome.unassigned.append(copy)
                }
            }
        }

        if !toTrash.isEmpty {
            let files = toTrash.map { OrganizeFile(path: $0.path, size: $0.byteCount, modifiedAt: $0.modifiedAt) }
            let batch = try trash.trash(files: files, originRoot: Self.commonFolder(of: toTrash.map(\.path)), context: context)
            let moved = Set(batch.entries.map { EventStorageLocations.pathKey($0.originalAbsolutePath) })
            let skipped = Dictionary(
                batch.skipped.map { (EventStorageLocations.pathKey($0.path), $0.reason) },
                uniquingKeysWith: { first, _ in first }
            )
            for copy in toTrash {
                if moved.contains(copy.pathKey) {
                    outcome.trashed.append(copy)
                } else {
                    outcome.refused.append(DuplicateRefusal(copy: copy, reason: skipped[copy.pathKey] ?? "It could not be moved to Trash."))
                }
            }
            outcome.trashBatch = batch.entries.isEmpty ? nil : batch
        }
        // A copy whose file stayed only because another dropped owner's
        // assignment shared it follows that file: if the file did not reach
        // Trash, its assignment stays too.
        let trashedKeys = Set(outcome.trashed.map(\.pathKey))
        outcome.unassigned.removeAll { copy in
            trashKeys.contains(copy.pathKey) && !trashedKeys.contains(copy.pathKey)
        }
        outcome.removedAssignments = (outcome.trashed + outcome.unassigned).compactMap(\.assignment)
        return outcome
    }

    /// The deepest folder every path sits under, so a non-volume Trash
    /// batch keeps the files' folder structure instead of flattening it.
    static func commonFolder(of paths: [String]) -> URL? {
        guard var common = paths.first.map({ ($0 as NSString).deletingLastPathComponent.split(separator: "/") }) else { return nil }
        for path in paths.dropFirst() {
            let parts = (path as NSString).deletingLastPathComponent.split(separator: "/")
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
        }
        guard !common.isEmpty else { return nil }
        return URL(fileURLWithPath: "/" + common.joined(separator: "/"), isDirectory: true)
    }
}

extension CatalogOwnedState {
    /// This state without the given assignments — what a resolution hands
    /// the catalog writer as one save (one transaction). Their location
    /// and Immich rows cascade away with them.
    public func removingAssignments(_ removed: [PhotoEventAssignment]) -> CatalogOwnedState {
        let ids = Set(removed.map(CatalogStore.eventAssetID))
        var next = self
        next.photoEventAssignments.removeAll { ids.contains(CatalogStore.eventAssetID($0)) }
        return next
    }
}
