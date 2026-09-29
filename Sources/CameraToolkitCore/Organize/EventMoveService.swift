import Foundation

/// What two files with one name turn out to be, decided by content.
public enum MoveConflictVerdict: Equatable, Sendable {
    /// Both names reach one file on disk (a hard link, a case variant).
    case sameFile
    /// Byte-identical: the photo is already there.
    case identical
    /// Different bytes: a different photo that happens to share the name
    /// (Sony reuses frame numbers).
    case different
    /// One side could not be read, so nothing is decided.
    case unreadable(String)
}

public enum MoveConflictCheck {
    public typealias Hasher = @Sendable (URL) throws -> String

    /// Size first; a streamed SHA-256 of both files only when the sizes
    /// match. Never guesses: a file that cannot be read is `.unreadable`.
    public static func classify(
        incomingPath: String,
        existingPath: String,
        hasher: Hasher = { try FileScanner.sha256($0) }
    ) -> MoveConflictVerdict {
        guard let incoming = DuplicateFileFacts.read(incomingPath) else {
            return .unreadable("\((incomingPath as NSString).lastPathComponent) is no longer where the board last saw it.")
        }
        guard let existing = DuplicateFileFacts.read(existingPath) else {
            return .unreadable("the file already using the name \((existingPath as NSString).lastPathComponent) could not be found to compare.")
        }
        if incoming.identity == existing.identity { return .sameFile }
        guard incoming.byteCount == existing.byteCount else { return .different }
        do {
            return try hasher(URL(fileURLWithPath: incomingPath)) == hasher(URL(fileURLWithPath: existingPath))
                ? .identical
                : .different
        } catch {
            return .unreadable("\((incomingPath as NSString).lastPathComponent) could not be read to compare: \(error.localizedDescription)")
        }
    }
}

/// A NAS copy that has to follow its file into another event's folder,
/// as paths relative to the NAS root.
public struct NASCopyMove: Sendable, Equatable {
    public var from: String
    public var to: String
    /// Where the file would sit on the drive under its new event — the path
    /// a "(N)" name is checked against when the NAS already holds the name.
    public var driveDestination: String?

    public init(from: String, to: String, driveDestination: String? = nil) {
        self.from = from
        self.to = to
        self.driveDestination = driveDestination
    }
}

/// One file of a Move to Event.
public struct EventMoveItem: Sendable {
    /// The file's assignment in the event it leaves.
    public var removed: PhotoEventAssignment
    /// The same file's assignment in the event it joins.
    public var added: PhotoEventAssignment
    /// The rename into the target's folder. Nil when the file is not on
    /// the drive yet and only its catalog entry moves.
    public var move: DriveMove?
    /// Where the file is now — the rename's source, else the folder it was
    /// sorted from — for comparing against a taken name.
    public var currentPath: String?
    /// Set when the target's catalog already lists this name: every place
    /// that file may be, the first that exists is compared.
    public var takenBy: [String]
    /// For a file with no drive copy to rename — one only the NAS has — the
    /// rename its NAS copy owes. A file with a drive rename leaves this nil:
    /// the NAS follows the drive move.
    public var nasCopy: NASCopyMove?

    public init(
        removed: PhotoEventAssignment,
        added: PhotoEventAssignment,
        move: DriveMove?,
        currentPath: String?,
        takenBy: [String] = [],
        nasCopy: NASCopyMove? = nil
    ) {
        self.removed = removed
        self.added = added
        self.move = move
        self.currentPath = currentPath
        self.takenBy = takenBy
        self.nasCopy = nasCopy
    }

    public var fileName: String { (added.relativePath as NSString).lastPathComponent }
}

public struct EventMoveKeptBoth: Sendable {
    public var item: EventMoveItem
    /// The free name it moved in under, e.g. `DSC06987 (2).ARW`.
    public var newName: String

    public init(item: EventMoveItem, newName: String) {
        self.item = item
        self.newName = newName
    }
}

public struct EventMoveStay: Sendable {
    public var item: EventMoveItem
    public var reason: String

    public init(item: EventMoveItem, reason: String) {
        self.item = item
        self.reason = reason
    }
}

public struct EventMoveOutcome: Sendable {
    public var report = DriveMoveReport()
    /// The catalog change to save: everything that moved, kept both, or
    /// merged into a copy the target already had.
    public var removedAssignments: [PhotoEventAssignment] = []
    public var addedAssignments: [PhotoEventAssignment] = []
    /// Moved under their own name, on disk or in the catalog only.
    public var moved: [EventMoveItem] = []
    /// The target already had these exact bytes. The extra copy went to
    /// Trash (or was the target's own file) and the assignment merged.
    public var merged: [EventMoveItem] = []
    /// How many of `merged` sent a spare copy to Trash.
    public var mergedToTrash = 0
    public var trashBatch: MediaTrashBatch?
    /// Different photos whose name was taken, moved in under a free name.
    /// Sidecars that travel with them are in `moved`.
    public var keptBoth: [EventMoveKeptBoth] = []
    /// Photos only the NAS has that came in under a free "(N)" name because
    /// the NAS already held their name. Also in `moved`.
    public var nasRenamed: [EventMoveKeptBoth] = []
    /// Left exactly where they were, with the reason.
    public var stayed: [EventMoveStay] = []

    public init() {}
}

/// Move to Event, decided by content rather than by name. A name already
/// taken in the target is compared byte for byte (re-hashed now, never from
/// a cache):
///
/// - identical — the photo is already there. The target's copy stays, the
///   extra copy is renamed into the drive's `_Trash` (manifest first,
///   restorable from the Trash window), and the assignment merges;
/// - different — moved in under Apply's non-clobbering Keep Both name,
///   `DSC06987 (2).ARW`, with its sidecars under the same number;
/// - unreadable — left in place with the reason.
///
/// Plain moves and Keep Both renames are one journaled `DriveMoveService`
/// job, so one Undo reverses them. Nothing is ever replaced.
public struct EventMoveService {
    public typealias Hasher = MoveConflictCheck.Hasher

    private let trash: MediaTrashService
    private let hasher: Hasher
    private let nasCheck: EventMoveNASCheck?

    /// `nasCheck` lets the move see what the NAS holds at the names it is
    /// about to take. The NAS copy of a moved file is renamed to the new
    /// path; when the NAS already holds a *different* file there — debris
    /// of an older Buffer, another photo the catalog never listed — that
    /// rename can only be refused, and the entry would point at the other
    /// file (or at nothing). So a photo whose new NAS name is taken by a
    /// different file moves in under a free "(N)" name, checked against the
    /// drive, the catalog and the NAS. A photo only the NAS has (no drive
    /// copy to compare) is never guessed identical: it also takes a free name.
    public init(
        trash: MediaTrashService,
        hasher: @escaping Hasher = { try FileScanner.sha256($0) },
        nasCheck: EventMoveNASCheck? = nil
    ) {
        self.trash = trash
        self.hasher = hasher
        self.nasCheck = nasCheck
    }

    /// `protectedPathKeys`: files other assignments still use — an
    /// identical copy there merges but is never trashed. `takenPathKeys`:
    /// target paths the catalog already claims, avoided by Keep Both names
    /// even when no file is there yet.
    public func move(
        _ items: [EventMoveItem],
        title: String,
        journalFolder: URL?,
        pruneBoundaries: [URL] = [],
        protectedPathKeys: Set<String> = [],
        takenPathKeys: Set<String> = [],
        trashContext: TrashContext = TrashContext(),
        eventFolders: [String: String]? = nil,
        progress: FileOperationProgressHandler? = nil
    ) throws -> EventMoveOutcome {
        var outcome = EventMoveOutcome()
        var plain: [EventMoveItem] = []
        var keep: [EventMoveItem] = []
        var toTrash: [EventMoveItem] = []
        var nasKeptBoth: Set<String> = []
        // Names this batch already takes, on the drive and on the NAS.
        var claimedDrive = Set(items.compactMap { $0.move?.destinationPath.lowercased() })
        var claimedNAS = Set(items.compactMap { $0.move == nil ? $0.nasCopy.map { NASSyncStore.pathKey($0.to) } : nil })

        // A destination already on disk is a taken name even when the
        // target's catalog does not list it.
        var checked = 0
        var takenOnDiskOnly: Set<String> = []
        for var item in items {
            if item.move == nil, item.takenBy.isEmpty, let copy = item.nasCopy, let nasCheck, nasCheck.holds(copy.to) {
                guard let renamed = Self.nasKeepBothName(
                    for: item, copy: copy, nasHolds: nasCheck.holds, takenPathKeys: takenPathKeys,
                    claimedDrive: claimedDrive, claimedNAS: claimedNAS
                ) else {
                    outcome.stayed.append(EventMoveStay(item: item, reason: "the NAS already has a different file named \(item.fileName) there, and no free “(N)” name was found next to it"))
                    continue
                }
                if let drive = renamed.nasCopy?.driveDestination { claimedDrive.insert(drive.lowercased()) }
                if let nas = renamed.nasCopy { claimedNAS.insert(NASSyncStore.pathKey(nas.to)) }
                nasKeptBoth.insert(CatalogStore.eventAssetID(item.removed))
                plain.append(renamed)
                continue
            }
            if item.takenBy.isEmpty, let move = item.move, DriveMoveService.exists(move.destinationPath) {
                item.takenBy = [move.destinationPath]
                takenOnDiskOnly.insert(CatalogStore.eventAssetID(item.removed))
            }
            guard !item.takenBy.isEmpty else {
                // The drive and the catalog say the name is free; the NAS
                // may hold a different file at the mirror of it.
                if let move = item.move, let nasCheck, nasCheck.wouldClash(move, byteCount: item.removed.fileSize, hasher: hasher) {
                    keep.append(item)
                } else {
                    plain.append(item)
                }
                continue
            }
            checked += 1
            progress?(FileOperationProgress(
                phase: "Comparing",
                currentPath: item.fileName,
                processedFiles: checked,
                totalFiles: items.count,
                processedBytes: 0,
                totalBytes: 0
            ))
            guard let incoming = item.currentPath else {
                outcome.stayed.append(EventMoveStay(item: item, reason: "it is not on the drive or in its folder, so it could not be compared"))
                continue
            }
            guard let existing = item.takenBy.first(where: DriveMoveService.isRegularFile) else {
                outcome.stayed.append(EventMoveStay(item: item, reason: "the file already using the name \(item.fileName) could not be found to compare"))
                continue
            }
            switch MoveConflictCheck.classify(incomingPath: incoming, existingPath: existing, hasher: hasher) {
            case .sameFile:
                outcome.merged.append(item)
            case .identical:
                if protectedPathKeys.contains(EventStorageLocations.pathKey(incoming)) {
                    outcome.merged.append(item)
                } else {
                    toTrash.append(item)
                }
            case .different:
                if item.move != nil {
                    keep.append(item)
                } else {
                    outcome.stayed.append(EventMoveStay(
                        item: item,
                        reason: "a different photo named \(item.fileName) is already there, and this one is not on the drive yet to be renamed"
                    ))
                }
            case .unreadable(let reason):
                outcome.stayed.append(EventMoveStay(item: item, reason: reason))
            }
        }

        // Sidecars and twins travel with a renamed photo under the same
        // number, so an XMP never pairs with the other photo.
        let heldKeys = Set(keep.compactMap { $0.move.map { ApplyCollisionCheck.groupKey($0.sourcePath) } })
        var companions: [EventMoveItem] = []
        plain.removeAll { item in
            guard let move = item.move, heldKeys.contains(ApplyCollisionCheck.groupKey(move.sourcePath)) else { return false }
            companions.append(item)
            return true
        }

        let plainMoves = plain.compactMap(\.move)
        var renamedItems: [(item: EventMoveItem, renamed: EventMoveItem, isConflict: Bool)] = []
        let keepAll = keep.map { ($0, true) } + companions.map { ($0, false) }
        if !keepAll.isEmpty {
            let moves = keepAll.compactMap(\.0.move)
            let taken = takenPathKeys
            let nasCheck = self.nasCheck
            // Photos only the NAS has move in under their own names too:
            // a "(N)" name must not take one of theirs.
            let nasOnlyReserved = plain.compactMap { item -> DriveMove? in
                guard item.move == nil, let copy = item.nasCopy, let destination = copy.driveDestination else { return nil }
                return DriveMove(sourcePath: copy.from, destinationPath: destination, byteCount: item.removed.fileSize)
            }
            if let renamed = KeepBothNaming.renamedMoves(
                for: moves,
                reserved: plainMoves + nasOnlyReserved,
                exists: {
                    DriveMoveService.exists($0) || taken.contains(EventStorageLocations.pathKey($0))
                        || nasCheck?.holdsMirror(ofDrivePath: $0) == true
                }
            ) {
                let bySource = Dictionary(renamed.map { ($0.sourcePath, $0) }, uniquingKeysWith: { first, _ in first })
                for (item, isConflict) in keepAll {
                    guard let move = item.move, let newMove = bySource[move.sourcePath] else { continue }
                    var renamedItem = item
                    let newName = (newMove.destinationPath as NSString).lastPathComponent
                    let folder = (item.added.relativePath as NSString).deletingLastPathComponent
                    renamedItem.added.relativePath = folder.isEmpty ? newName : (folder as NSString).appendingPathComponent(newName)
                    renamedItem.move = newMove
                    renamedItems.append((item, renamedItem, isConflict))
                }
            } else {
                for (item, _) in keepAll {
                    outcome.stayed.append(EventMoveStay(item: item, reason: "no free “(N)” name was found next to \(item.fileName)"))
                }
            }
        }

        let journaled = plain + renamedItems.map(\.renamed)
        outcome.report = try DriveMoveService().apply(
            plainMoves + renamedItems.compactMap(\.renamed.move),
            title: title,
            journalFolder: journalFolder,
            removedAssignments: journaled.map(\.removed),
            addedAssignments: journaled.map(\.added),
            assignmentMoveSources: journaled.map { $0.move?.sourcePath },
            eventFolders: eventFolders,
            pruneBoundaries: pruneBoundaries,
            progress: progress
        )
        let failed = Dictionary(
            outcome.report.skipped.map { (EventStorageLocations.pathKey($0.move.sourcePath), $0.reason) },
            uniquingKeysWith: { first, _ in first }
        )
        func failure(_ item: EventMoveItem) -> String? {
            item.move.flatMap { failed[EventStorageLocations.pathKey($0.sourcePath)] }
        }
        for item in plain {
            if let reason = failure(item) {
                outcome.stayed.append(EventMoveStay(item: item, reason: reason))
            } else if nasKeptBoth.contains(CatalogStore.eventAssetID(item.removed)) {
                // Counted as moved (the catalog change and its Undo are
                // one change, NAS rename included) and listed apart so the
                // status line can say the name changed.
                outcome.moved.append(item)
                outcome.nasRenamed.append(EventMoveKeptBoth(item: item, newName: item.fileName))
            } else {
                outcome.moved.append(item)
            }
        }
        for entry in renamedItems {
            if let reason = failure(entry.renamed) {
                outcome.stayed.append(EventMoveStay(item: entry.item, reason: reason))
            } else if entry.isConflict {
                outcome.keptBoth.append(EventMoveKeptBoth(
                    item: entry.renamed,
                    newName: (entry.renamed.added.relativePath as NSString).lastPathComponent
                ))
            } else {
                outcome.moved.append(entry.renamed)
            }
        }

        if !toTrash.isEmpty {
            let files = toTrash.compactMap { item -> OrganizeFile? in
                guard let path = item.currentPath, let facts = DuplicateFileFacts.read(path) else { return nil }
                return OrganizeFile(path: path, size: facts.byteCount, modifiedAt: facts.modifiedAt)
            }
            // The renames above already happened, so a Trash that cannot be
            // written must not throw the whole move away: the catalog has to
            // hear about what moved. The extra copies simply stay put.
            var trashFailure: String?
            var batch: MediaTrashBatch?
            if !files.isEmpty {
                do {
                    batch = try trash.trash(
                        files: files,
                        originRoot: DuplicateResolver.commonFolder(of: files.map(\.path)),
                        context: trashContext
                    )
                } catch {
                    trashFailure = "its extra copy could not be moved to Trash: \(error.localizedDescription)"
                }
            }
            let trashed = Set((batch?.entries ?? []).map { EventStorageLocations.pathKey($0.originalAbsolutePath) })
            let skipped = Dictionary(
                (batch?.skipped ?? []).map { (EventStorageLocations.pathKey($0.path), $0.reason) },
                uniquingKeysWith: { first, _ in first }
            )
            for item in toTrash {
                let key = item.currentPath.map(EventStorageLocations.pathKey) ?? ""
                if trashed.contains(key) {
                    outcome.merged.append(item)
                    outcome.mergedToTrash += 1
                } else {
                    outcome.stayed.append(EventMoveStay(item: item, reason: skipped[key] ?? trashFailure ?? "its extra copy could not be moved to Trash"))
                }
            }
            outcome.trashBatch = batch.flatMap { $0.entries.isEmpty ? nil : $0 }
        }

        outcome.removedAssignments = (outcome.moved + outcome.keptBoth.map(\.item) + outcome.merged).map(\.removed)
        // A merge keeps the target's own entry. Only a name taken on disk
        // alone — a file the target's catalog did not list yet — adopts it.
        outcome.addedAssignments = (outcome.moved + outcome.keptBoth.map(\.item)).map(\.added)
            + outcome.merged.filter { takenOnDiskOnly.contains(CatalogStore.eventAssetID($0.removed)) }.map(\.added)
        return outcome
    }


    /// The item with the lowest free `name (N).ext` (N ≥ 2) that no NAS
    /// file, catalog entry, drive file or other move of this batch uses.
    /// Its assignment and its NAS rename both carry the new name.
    static func nasKeepBothName(
        for item: EventMoveItem,
        copy: NASCopyMove,
        nasHolds: (String) -> Bool,
        takenPathKeys: Set<String>,
        claimedDrive: Set<String>,
        claimedNAS: Set<String>
    ) -> EventMoveItem? {
        let assignmentFolder = (item.added.relativePath as NSString).deletingLastPathComponent
        let assignmentLeaf = (item.added.relativePath as NSString).lastPathComponent
        let nasFolder = (copy.to as NSString).deletingLastPathComponent
        let nasLeaf = (copy.to as NSString).lastPathComponent
        for number in 2...999 {
            let newNASPath = nasFolder.isEmpty
                ? KeepBothNaming.suffixed(nasLeaf, number)
                : (nasFolder as NSString).appendingPathComponent(KeepBothNaming.suffixed(nasLeaf, number))
            var newDrive: String?
            if let drive = copy.driveDestination {
                let folder = (drive as NSString).deletingLastPathComponent
                newDrive = (folder as NSString).appendingPathComponent(KeepBothNaming.suffixed((drive as NSString).lastPathComponent, number))
            }
            if nasHolds(newNASPath) || claimedNAS.contains(NASSyncStore.pathKey(newNASPath)) { continue }
            if let newDrive {
                if claimedDrive.contains(newDrive.lowercased()) || takenPathKeys.contains(EventStorageLocations.pathKey(newDrive))
                    || DriveMoveService.exists(newDrive) { continue }
            }
            var renamed = item
            let newLeaf = KeepBothNaming.suffixed(assignmentLeaf, number)
            renamed.added.relativePath = assignmentFolder.isEmpty ? newLeaf : (assignmentFolder as NSString).appendingPathComponent(newLeaf)
            renamed.nasCopy = NASCopyMove(from: copy.from, to: newNASPath, driveDestination: newDrive)
            return renamed
        }
        return nil
    }
}
