import Darwin
import Foundation

/// A planned Apply rename whose destination name is already taken. Found
/// at plan time, so the sheet can say so instead of Apply silently leaving
/// the file where it is.
public struct ApplyCollision: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// The destination holds a byte-identical file: the photo is already
        /// in the event and this copy is redundant.
        case identicalCopy
        /// The destination holds a different file with the same name.
        case nameConflict
        /// A sidecar or twin whose own destination is free, held back
        /// because its primary is a `nameConflict`: moving it alone would
        /// pair it with the other file.
        case travelsWithConflict
    }

    public var kind: Kind
    /// Source → the taken destination (for `travelsWithConflict`, a free one).
    public var move: DriveMove
    /// The event assignment the move belongs to, when known.
    public var assignment: PhotoEventAssignment?
    /// Size of the file already at the destination, or nil when none.
    public var existingByteCount: Int64?

    public init(kind: Kind, move: DriveMove, assignment: PhotoEventAssignment?, existingByteCount: Int64?) {
        self.kind = kind
        self.move = move
        self.assignment = assignment
        self.existingByteCount = existingByteCount
    }

    public var fileName: String { (move.sourcePath as NSString).lastPathComponent }
}

/// One file the planner wants to rename, with the assignment behind it.
public struct ApplyMoveCandidate: Sendable {
    public var move: DriveMove
    public var assignment: PhotoEventAssignment?

    public init(move: DriveMove, assignment: PhotoEventAssignment?) {
        self.move = move
        self.assignment = assignment
    }
}

public struct ApplyCollisionPartition: Sendable {
    /// Destinations that are free: Apply renames these.
    public var clear: [ApplyMoveCandidate] = []
    public var duplicates: [ApplyCollision] = []
    /// `nameConflict` plus the `travelsWithConflict` companions.
    public var conflicts: [ApplyCollision] = []
}

/// Plan-time destination checks. One `lstat` per planned file; a checksum
/// only when a same-size file already sits at the destination. Hashes are
/// streamed through `StreamingFileIO`'s bounded buffer. Nothing here writes.
public enum ApplyCollisionCheck {
    public typealias Hasher = @Sendable (URL) throws -> String

    /// nil when the destination is free. A destination that exists but
    /// cannot be proven byte-identical is a `nameConflict` — never a
    /// duplicate, so nothing is offered for Trash on a guess.
    public static func classify(
        sourcePath: String,
        destinationPath: String,
        hasher: Hasher = { try FileScanner.sha256($0) }
    ) -> (kind: ApplyCollision.Kind, existingByteCount: Int64)? {
        var destination = stat()
        guard lstat(destinationPath, &destination) == 0 else { return nil }
        let existing = Int64(destination.st_size)
        var source = stat()
        guard lstat(sourcePath, &source) == 0,
              (source.st_mode & S_IFMT) == S_IFREG,
              (destination.st_mode & S_IFMT) == S_IFREG,
              source.st_size == destination.st_size else {
            return (.nameConflict, existing)
        }
        // The same file reached by two spellings (a case-insensitive drive,
        // a hard link) is not a spare copy: trashing it would trash the
        // photo itself.
        if source.st_dev == destination.st_dev, source.st_ino == destination.st_ino, source.st_ino != 0 {
            return (.nameConflict, existing)
        }
        guard let sourceHash = try? hasher(URL(fileURLWithPath: sourcePath)),
              let destinationHash = try? hasher(URL(fileURLWithPath: destinationPath)),
              sourceHash == destinationHash else {
            return (.nameConflict, existing)
        }
        return (.identicalCopy, existing)
    }

    /// Splits planned renames into free ones, identical duplicates, and
    /// name conflicts. A file that shares its source folder and base name
    /// with a conflict (its XMP, its JPEG twin) is held back with it.
    public static func partition(
        _ candidates: [ApplyMoveCandidate],
        hasher: Hasher = { try FileScanner.sha256($0) }
    ) -> ApplyCollisionPartition {
        var result = ApplyCollisionPartition()
        var free: [ApplyMoveCandidate] = []
        for candidate in candidates {
            if Task<Never, Never>.isCancelled { break }
            guard let found = classify(
                sourcePath: candidate.move.sourcePath,
                destinationPath: candidate.move.destinationPath,
                hasher: hasher
            ) else {
                free.append(candidate)
                continue
            }
            let collision = ApplyCollision(
                kind: found.kind,
                move: candidate.move,
                assignment: candidate.assignment,
                existingByteCount: found.existingByteCount
            )
            if found.kind == .identicalCopy {
                result.duplicates.append(collision)
            } else {
                result.conflicts.append(collision)
            }
        }
        let heldBack = Set(result.conflicts.map { groupKey($0.move.sourcePath) })
        for candidate in free {
            if heldBack.contains(groupKey(candidate.move.sourcePath)) {
                result.conflicts.append(ApplyCollision(
                    kind: .travelsWithConflict,
                    move: candidate.move,
                    assignment: candidate.assignment,
                    existingByteCount: nil
                ))
            } else {
                result.clear.append(candidate)
            }
        }
        return result
    }

    /// Source folder + base name up to the first dot, lowercased:
    /// `DSC0001.ARW`, `DSC0001.XMP` and `DSC0001.ARW.xmp` share one key.
    public static func groupKey(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent.lowercased()
        let name = (path as NSString).lastPathComponent
        // A Sony clip sidecar (`C0167M01.XML`) belongs to its clip
        // (`C0167.MP4`): one group, so they are renamed together.
        let base = KeepBothNaming.sonySidecar(name)?.clip ?? KeepBothNaming.split(name).base
        return folder + "\u{0}" + base.lowercased()
    }
}

/// Non-clobbering "Keep Both" names: `DSC0001.ARW` → `DSC0001 (2).ARW`.
public enum KeepBothNaming {
    /// Base up to the first dot, and the rest including it. A leading dot
    /// is part of the base, so `.hidden` never becomes ` (2).hidden`.
    static func split(_ name: String) -> (base: String, rest: String) {
        guard let dot = name.dropFirst().firstIndex(of: ".") else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    public static func suffixed(_ name: String, _ number: Int) -> String {
        // The number goes on the clip's name, before the `M01`, so the
        // sidecar still pairs with the renamed clip: `C0167 (2)M01.XML`.
        if let sidecar = sonySidecar(name) {
            return "\(sidecar.clip) (\(number))\(sidecar.marker)\(sidecar.rest)"
        }
        let parts = split(name)
        return "\(parts.base) (\(number))\(parts.rest)"
    }

    /// `C0167M01.XML` → clip `C0167`, marker `M01`, rest `.XML`; nil for
    /// anything that is not a companion file named like a Sony clip sidecar.
    static func sonySidecar(_ name: String) -> (clip: String, marker: String, rest: String)? {
        let parts = split(name)
        // `rest` is ".XML" — a leading dot alone reads as a hidden name.
        let ext = (("x" + parts.rest) as NSString).pathExtension.lowercased()
        guard OrganizeFileClassifier.companionExtensions.contains(ext),
              parts.base.count > 4 else { return nil }
        let marker = parts.base.suffix(3)
        guard marker.first == "M" || marker.first == "m", marker.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return (String(parts.base.dropLast(3)), String(marker), parts.rest)
    }

    /// Picks the lowest number ≥ 2 that is free for every member of each
    /// group (same source folder and base name) in its destination folder —
    /// the file and its `._` AppleDouble — and not already claimed by this
    /// batch. Returns the renamed moves in input order. The free check is
    /// advisory: the rename itself is exclusive and re-checks.
    /// `reserved` holds destination paths other moves in the same batch
    /// will take (the plain Apply moves), so a "(N)" name never races one.
    public static func renamedMoves(
        for moves: [DriveMove],
        reserved: [DriveMove] = [],
        maxAttempts: Int = 999,
        exists: ((String) -> Bool)? = nil
    ) -> [DriveMove]? {
        let exists = exists ?? { DriveMoveService.exists($0) }
        var claimed = Set(reserved.map { $0.destinationPath.lowercased() })
        var renamed: [String: DriveMove] = [:]
        var order: [String] = []
        var groups: [String: [DriveMove]] = [:]
        for move in moves {
            let key = ApplyCollisionCheck.groupKey(move.sourcePath)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(move)
        }
        for key in order {
            let members = groups[key] ?? []
            var chosen: [DriveMove]?
            for number in 2...max(2, maxAttempts) {
                let candidates = members.map { move -> DriveMove in
                    let folder = (move.destinationPath as NSString).deletingLastPathComponent
                    let name = suffixed((move.destinationPath as NSString).lastPathComponent, number)
                    return DriveMove(
                        sourcePath: move.sourcePath,
                        destinationPath: (folder as NSString).appendingPathComponent(name),
                        byteCount: move.byteCount
                    )
                }
                let taken = candidates.contains { candidate in
                    let path = candidate.destinationPath
                    let double = ((path as NSString).deletingLastPathComponent as NSString)
                        .appendingPathComponent("._" + (path as NSString).lastPathComponent)
                    return claimed.contains(path.lowercased()) || exists(path) || exists(double)
                }
                if !taken {
                    chosen = candidates
                    break
                }
            }
            guard let chosen else { return nil }
            for move in chosen {
                claimed.insert(move.destinationPath.lowercased())
                renamed[move.sourcePath] = move
            }
        }
        return moves.compactMap { renamed[$0.sourcePath] }
    }
}

public struct KeepBothOutcome: Sendable {
    public var report: DriveMoveReport
    /// Assignments whose files actually moved, before and after the rename.
    public var removedAssignments: [PhotoEventAssignment]
    public var addedAssignments: [PhotoEventAssignment]
}

extension DriveMoveService {
    /// "Keep Both" for Apply name conflicts: renames each source into the
    /// event under a free `name (N).ext`, sidecars under the same N. It is
    /// an ordinary journaled `apply` — exclusive renames, nothing replaced,
    /// Undo moves the files back to their original names — and each
    /// assignment's relative path follows its file's new name.
    ///
    /// `plainMoves` are ordinary Apply renames that go in the same journal,
    /// so "Move 40 Files (Keep Both for 1)" is one job and one Undo.
    public func keepBoth(
        _ conflicts: [ApplyCollision],
        plainMoves: [DriveMove] = [],
        title: String,
        journalFolder: URL?,
        pruneBoundaries: [URL] = [],
        progress: FileOperationProgressHandler? = nil
    ) throws -> KeepBothOutcome {
        let moves = conflicts.map(\.move)
        guard let renamed = KeepBothNaming.renamedMoves(for: moves, reserved: plainMoves) else {
            throw ToolkitError.commandFailed("No free “(N)” name was found next to those files. Nothing was moved.")
        }
        var removed: [PhotoEventAssignment] = []
        var added: [PhotoEventAssignment] = []
        var pairSources: [String?] = []
        var assignmentBySource: [String: (old: PhotoEventAssignment, new: PhotoEventAssignment)] = [:]
        for (conflict, move) in zip(conflicts, renamed) {
            guard let old = conflict.assignment else { continue }
            var new = old
            let newName = (move.destinationPath as NSString).lastPathComponent
            let folder = (old.relativePath as NSString).deletingLastPathComponent
            new.relativePath = folder.isEmpty ? newName : (folder as NSString).appendingPathComponent(newName)
            removed.append(old)
            added.append(new)
            pairSources.append(move.sourcePath)
            assignmentBySource[URL(fileURLWithPath: move.sourcePath).standardizedFileURL.path] = (old, new)
        }
        let report = try apply(
            plainMoves + renamed,
            title: title,
            journalFolder: journalFolder,
            removedAssignments: removed,
            addedAssignments: added,
            assignmentMoveSources: pairSources,
            pruneBoundaries: pruneBoundaries,
            progress: progress
        )
        let moved = report.moved.compactMap { assignmentBySource[$0.sourcePath] }
        return KeepBothOutcome(
            report: report,
            removedAssignments: moved.map(\.old),
            addedAssignments: moved.map(\.new)
        )
    }
}

/// What the Apply sheet shows about each side of a taken name: size and
/// capture time. Read off the main actor; nothing here writes.
public struct ApplyCollisionFileFacts: Equatable, Sendable {
    public var byteCount: Int64?
    /// EXIF capture time when the file carries one.
    public var captureDate: Date?
    public var modifiedAt: Date?

    public init(byteCount: Int64?, captureDate: Date?, modifiedAt: Date?) {
        self.byteCount = byteCount
        self.captureDate = captureDate
        self.modifiedAt = modifiedAt
    }

    /// Capture time, else the file date.
    public var bestDate: Date? { captureDate ?? modifiedAt }
}

extension ApplyCollisionCheck {
    /// One `lstat` and a small header read. Missing files give empty facts.
    public static func facts(atPath path: String) -> ApplyCollisionFileFacts {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return ApplyCollisionFileFacts(byteCount: nil, captureDate: nil, modifiedAt: nil)
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        let isRegular = (info.st_mode & S_IFMT) == S_IFREG
        return ApplyCollisionFileFacts(
            byteCount: Int64(info.st_size),
            captureDate: isRegular ? CaptureDateReader.captureDate(of: URL(fileURLWithPath: path)) : nil,
            modifiedAt: modified
        )
    }

    /// The name Keep Both would pick right now for a conflict and the
    /// sidecars held with it ("DSC0001 (2).ARW"), or nil when no free
    /// number is found. Advisory, like `renamedMoves`: the rename re-checks.
    public static func keepBothName(for conflict: ApplyCollision, companions: [ApplyCollision] = []) -> String? {
        guard let renamed = KeepBothNaming.renamedMoves(for: [conflict.move] + companions.map(\.move)),
              let first = renamed.first else { return nil }
        return (first.destinationPath as NSString).lastPathComponent
    }
}
