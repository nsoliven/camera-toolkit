import Darwin
import Foundation

public struct DriveMove: Codable, Hashable, Sendable {
    public var sourcePath: String
    public var destinationPath: String
    public var byteCount: Int64

    public init(sourcePath: String, destinationPath: String, byteCount: Int64) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.byteCount = byteCount
    }
}

public struct DriveMoveIssue: Hashable, Sendable {
    public var move: DriveMove
    public var reason: String

    public init(move: DriveMove, reason: String) {
        self.move = move
        self.reason = reason
    }
}

/// A durable record of one Apply or reorganize action. It is written before
/// the first rename so an interrupted run can still be undone.
public struct DriveMoveJournal: Codable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var moves: [DriveMove]
    public var completedIndices: [Int]
    /// Configuration assignments this action replaced.
    public var removedAssignments: [PhotoEventAssignment]
    /// Configuration assignments this action added.
    public var addedAssignments: [PhotoEventAssignment]
    public var undoneAt: Date?
    /// For each catalog entry the action changed — `removedAssignments[i]`
    /// and `addedAssignments[i]` — the index in `moves` of the rename that
    /// carries its file: nil when only the catalog entry moved, `-1` when its
    /// rename was planned but refused. Undo swaps back only the entries whose
    /// file really went back. Nil in journals written before this existed.
    public var assignmentMoveIndices: [Int?]?
    /// Where each event the action touched kept its folder when it ran
    /// (event id → folder path). Undo refuses once an event's folder is
    /// somewhere else — renamed, re-dated or re-parented — instead of putting
    /// files and NAS copies back under the old name.
    public var eventFolders: [String: String]?
    /// The indices in `moves` Undo has put back so far — what Redo renames
    /// forward again. Nil in journals undone before Redo existed (Redo then
    /// takes every move the journal completed).
    public var undoneIndices: [Int]?
    /// An Undo or Redo of this journal that has begun: "undo" or "redo". Set
    /// before the first rename and cleared (`finishStep`) only once the
    /// catalog and the NAS copies have followed the drive — so a crash
    /// anywhere in between is replayed at the next launch instead of leaving
    /// the catalog behind the drive's files.
    public var pendingStep: String?
    /// The drive renames of `pendingStep` are all done (the catalog and the
    /// NAS copies may not be yet).
    public var driveStepDone: Bool?

    public var completedMoves: [DriveMove] {
        completedIndices.compactMap { moves.indices.contains($0) ? moves[$0] : nil }
    }

    /// The catalog entries Undo should swap back after reversing the moves at
    /// `reversed`: those whose file went back and those that only ever moved
    /// in the catalog. A journal without per-entry indices swaps everything
    /// only when every move went back. `removed` are entries to put back,
    /// `added` are entries to take out. `isCurrent` says whether an entry the
    /// action added is still in the catalog: when a later change moved that
    /// file on again, its old entry is not put back — the file would be
    /// assigned twice.
    public func assignmentsToRestore(
        reversed: [Int],
        fullyUndone: Bool,
        isCurrent: (PhotoEventAssignment) -> Bool = { _ in true }
    ) -> (removed: [PhotoEventAssignment], added: [PhotoEventAssignment]) {
        guard let indices = assignmentMoveIndices else {
            guard fullyUndone else { return ([], []) }
            return (removedAssignments, addedAssignments)
        }
        let wentBack = Set(reversed)
        var removed: [PhotoEventAssignment] = []
        var added: [PhotoEventAssignment] = []
        for position in 0..<max(removedAssignments.count, addedAssignments.count) {
            if position < indices.count, let move = indices[position], !wentBack.contains(move) { continue }
            if position < addedAssignments.count, !isCurrent(addedAssignments[position]) { continue }
            if position < removedAssignments.count { removed.append(removedAssignments[position]) }
            if position < addedAssignments.count { added.append(addedAssignments[position]) }
        }
        return (removed, added)
    }

    /// The catalog entries Redo should swap forward after re-applying the
    /// moves at `redone`: those whose file went forward again and those that
    /// only ever moved in the catalog. `removed` are entries to take out,
    /// `added` are entries to put in. `isCurrent` says whether an entry the
    /// action originally removed is in the catalog now — one a later change
    /// already replaced is left alone.
    public func assignmentsToReapply(
        redone: [Int],
        fullyRedone: Bool,
        isCurrent: (PhotoEventAssignment) -> Bool = { _ in true }
    ) -> (removed: [PhotoEventAssignment], added: [PhotoEventAssignment]) {
        guard let indices = assignmentMoveIndices else {
            guard fullyRedone else { return ([], []) }
            return (removedAssignments, addedAssignments)
        }
        let wentForward = Set(redone)
        var removed: [PhotoEventAssignment] = []
        var added: [PhotoEventAssignment] = []
        for position in 0..<max(removedAssignments.count, addedAssignments.count) {
            if position < indices.count, let move = indices[position], !wentForward.contains(move) { continue }
            if position < removedAssignments.count, !isCurrent(removedAssignments[position]) { continue }
            if position < removedAssignments.count { removed.append(removedAssignments[position]) }
            if position < addedAssignments.count { added.append(addedAssignments[position]) }
        }
        return (removed, added)
    }
}

public struct DriveMoveReport: Sendable {
    public var moved: [DriveMove] = []
    public var skipped: [DriveMoveIssue] = []
    public var journalPath: String?
    /// The journal's id, set when one was written — what NAS renames
    /// recorded for this move are linked to, so its Undo reverses them.
    public var journalID: UUID?
    /// For an Undo: the indices in the journal's `moves` that were reversed.
    public var reversedIndices: [Int] = []

    public var movedBytes: Int64 { moved.reduce(Int64(0)) { $0 + $1.byteCount } }
}

/// Moves originals between folders on the same drive with an exclusive
/// rename. File bytes are never rewritten, destinations are never replaced,
/// and a cross-drive request is refused instead of silently copying.
public struct DriveMoveService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func apply(
        _ moves: [DriveMove],
        title: String,
        journalFolder: URL?,
        removedAssignments: [PhotoEventAssignment] = [],
        addedAssignments: [PhotoEventAssignment] = [],
        assignmentMoveSources: [String?]? = nil,
        eventFolders: [String: String]? = nil,
        pruneBoundaries: [URL] = [],
        progress: FileOperationProgressHandler? = nil
    ) throws -> DriveMoveReport {
        var report = DriveMoveReport()
        let planned = preflight(moves, report: &report)

        // Which planned rename carries each catalog entry's file (by the
        // path it moves from), so Undo can swap back exactly those.
        let plannedIndex = Dictionary(planned.enumerated().map { ($1.sourcePath, $0) }, uniquingKeysWith: { first, _ in first })
        let moveIndices: [Int?]? = assignmentMoveSources.map { sources in
            sources.map { source in
                guard let source else { return nil }
                return plannedIndex[URL(fileURLWithPath: source).standardizedFileURL.path] ?? -1
            }
        }
        var journal = DriveMoveJournal(
            id: UUID(),
            title: title,
            createdAt: Date(),
            moves: planned,
            completedIndices: [],
            removedAssignments: removedAssignments,
            addedAssignments: addedAssignments,
            assignmentMoveIndices: moveIndices,
            eventFolders: eventFolders
        )
        var journalURL: URL?
        if let journalFolder, !planned.isEmpty {
            try fileManager.createDirectory(at: journalFolder, withIntermediateDirectories: true)
            let url = journalFolder.appendingPathComponent("\(Self.stamp(journal.createdAt))-\(journal.id.uuidString.prefix(8)).json")
            try Self.write(journal, to: url)
            journalURL = url
            report.journalPath = url.path
            report.journalID = journal.id
        }

        let totalBytes = planned.reduce(Int64(0)) { $0 + $1.byteCount }
        var processedBytes: Int64 = 0
        var limiter = FileOperationProgressLimiter()
        var sourceFolders: Set<String> = []
        // How often progress is written down: often enough that a crash or a
        // pulled cable leaves an Undo that knows most of what was renamed,
        // rarely enough that a very large move does not rewrite a huge file.
        let flushEvery = max(10, planned.count / 20)

        for (index, move) in planned.enumerated() {
            do {
                let destination = URL(fileURLWithPath: move.destinationPath)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.renameExclusive(from: move.sourcePath, to: move.destinationPath)
                Self.moveAppleDoubleIfNeeded(from: move.sourcePath, to: move.destinationPath)
                journal.completedIndices.append(index)
                report.moved.append(move)
                processedBytes += move.byteCount
                sourceFolders.insert((move.sourcePath as NSString).deletingLastPathComponent)
            } catch {
                report.skipped.append(DriveMoveIssue(move: move, reason: error.localizedDescription))
            }
            if let journalURL, journal.completedIndices.count % flushEvery == 0, !journal.completedIndices.isEmpty {
                try? Self.write(journal, to: journalURL)
            }
            if limiter.shouldEmit(force: index + 1 == planned.count) {
                progress?(FileOperationProgress(
                    phase: "Moving on drive",
                    currentPath: (move.destinationPath as NSString).lastPathComponent,
                    processedFiles: index + 1,
                    totalFiles: planned.count,
                    processedBytes: processedBytes,
                    totalBytes: totalBytes
                ))
            }
        }

        // The renames are done. A journal that cannot be rewritten now must
        // not throw the report away — the catalog has to hear what moved.
        if let journalURL, (try? Self.write(journal, to: journalURL)) == nil {
            try? Self.write(journal, to: journalURL)
        }
        pruneEmptyFolders(sourceFolders, boundaries: pruneBoundaries)
        return report
    }

    /// Reverses every completed move in a journal, newest first.
    public func undo(
        journalURL: URL,
        pruneBoundaries: [URL] = [],
        progress: FileOperationProgressHandler? = nil
    ) throws -> (report: DriveMoveReport, journal: DriveMoveJournal) {
        var journal = try Self.read(journalURL)
        guard journal.undoneAt == nil else {
            throw ToolkitError.commandFailed("That change was already undone.")
        }
        if let barrier = Self.layoutMigrationBarrier(in: journalURL.deletingLastPathComponent()),
           journal.createdAt < barrier.completedAt {
            throw ToolkitError.commandFailed(
                "“\(journal.title)” was recorded before the drive moved to the Originals layout; its paths no longer exist, so it can't be undone. Nothing was changed."
            )
        }
        var report = DriveMoveReport(journalPath: journalURL.path, journalID: journal.id)
        // An Undo that was interrupted (a crash, a pulled cable) left some files
        // already back; the journal remembers that one began, so those count as
        // reversed now and the catalog follows them too.
        let resuming = journal.pendingStep == "undo" && journal.driveStepDone == false
        journal.pendingStep = "undo"
        journal.driveStepDone = false
        try Self.write(journal, to: journalURL)
        // Renames a crash or a pulled cable finished after the last progress
        // write: the file is at its destination, gone from its source, and
        // only ever after the last recorded one (moves run in order).
        var completed = journal.completedIndices
        let lastRecorded = completed.max() ?? -1
        for index in journal.moves.indices where index > lastRecorded {
            let move = journal.moves[index]
            if !Self.exists(move.sourcePath), Self.isRegularFile(move.destinationPath),
               (try? fileManager.attributesOfItem(atPath: move.destinationPath)[.size] as? Int64) == move.byteCount {
                completed.append(index)
            }
        }
        completed.sort()
        var indexBySource: [String: Int] = [:]
        var reversed: [DriveMove] = []
        for index in completed.reversed() where journal.moves.indices.contains(index) {
            let move = journal.moves[index]
            if resuming, !Self.exists(move.destinationPath), Self.isRegularFile(move.sourcePath),
               (try? fileManager.attributesOfItem(atPath: move.sourcePath)[.size] as? Int64) == move.byteCount {
                // Already back: a step that began before this one moved it.
                report.reversedIndices.append(index)
                continue
            }
            indexBySource[URL(fileURLWithPath: move.destinationPath).standardizedFileURL.path] = index
            reversed.append(DriveMove(sourcePath: move.destinationPath, destinationPath: move.sourcePath, byteCount: move.byteCount))
        }
        let planned = preflight(reversed, report: &report)
        var folders: Set<String> = []
        for (index, move) in planned.enumerated() {
            do {
                try fileManager.createDirectory(
                    at: URL(fileURLWithPath: move.destinationPath).deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Self.renameExclusive(from: move.sourcePath, to: move.destinationPath)
                Self.moveAppleDoubleIfNeeded(from: move.sourcePath, to: move.destinationPath)
                report.moved.append(move)
                if let original = indexBySource[move.sourcePath] { report.reversedIndices.append(original) }
                folders.insert((move.sourcePath as NSString).deletingLastPathComponent)
            } catch {
                report.skipped.append(DriveMoveIssue(move: move, reason: error.localizedDescription))
            }
            progress?(FileOperationProgress(
                phase: "Undoing move",
                currentPath: (move.destinationPath as NSString).lastPathComponent,
                processedFiles: index + 1,
                totalFiles: planned.count
            ))
        }
        // Moves that could not go back (a name was taken, a drive dropped)
        // keep the journal open so Undo can be tried again for just those;
        // an attempt that got nowhere closes it, so older changes can still
        // be undone — the report names what stayed.
        let wentBack = Set(report.reversedIndices)
        let remaining = completed.filter { !wentBack.contains($0) }
        // What Redo will rename forward again: every move that went back,
        // now and in earlier partial attempts.
        journal.undoneIndices = Array(Set(journal.undoneIndices ?? []).union(wentBack)).sorted()
        if remaining.isEmpty || report.reversedIndices.isEmpty {
            journal.undoneAt = Date()
        } else {
            journal.completedIndices = remaining
        }
        if report.reversedIndices.isEmpty {
            // Nothing went back, so there is no catalog or NAS step to finish.
            journal.pendingStep = nil
            journal.driveStepDone = nil
        } else {
            journal.driveStepDone = true
        }
        try Self.write(journal, to: journalURL)
        pruneEmptyFolders(folders, boundaries: pruneBoundaries)
        return (report, journal)
    }

    /// Renames forward again what `undo` put back: every move of the
    /// journal that went back, in the order they first ran. Exclusive like
    /// every rename here — a name taken since is skipped and reported, never
    /// replaced. The journal is open again (undoable) as soon as anything
    /// went forward; moves that could not stay listed for another Redo.
    /// `report.reversedIndices` names the moves that were re-applied.
    public func redo(
        journalURL: URL,
        pruneBoundaries: [URL] = [],
        progress: FileOperationProgressHandler? = nil
    ) throws -> (report: DriveMoveReport, journal: DriveMoveJournal) {
        var journal = try Self.read(journalURL)
        guard journal.undoneAt != nil else {
            throw ToolkitError.commandFailed("That change is not undone, so there is nothing to redo.")
        }
        if let barrier = Self.layoutMigrationBarrier(in: journalURL.deletingLastPathComponent()),
           journal.createdAt < barrier.completedAt {
            throw ToolkitError.commandFailed(
                "“\(journal.title)” was recorded before the drive moved to the Originals layout; its paths no longer exist, so it can't be redone. Nothing was changed."
            )
        }
        var report = DriveMoveReport(journalPath: journalURL.path, journalID: journal.id)
        // A Redo that was interrupted left some files already forward; they
        // count as re-applied now, so the catalog follows them too.
        let resuming = journal.pendingStep == "redo" && journal.driveStepDone == false
        journal.pendingStep = "redo"
        journal.driveStepDone = false
        try Self.write(journal, to: journalURL)
        let indices = (journal.undoneIndices ?? journal.completedIndices)
            .filter { journal.moves.indices.contains($0) }
            .sorted()
        var indexBySource: [String: Int] = [:]
        var forward: [DriveMove] = []
        for index in indices {
            let move = journal.moves[index]
            if resuming, !Self.exists(move.sourcePath), Self.isRegularFile(move.destinationPath),
               (try? fileManager.attributesOfItem(atPath: move.destinationPath)[.size] as? Int64) == move.byteCount {
                report.reversedIndices.append(index)
                continue
            }
            indexBySource[URL(fileURLWithPath: move.sourcePath).standardizedFileURL.path] = index
            forward.append(move)
        }
        let planned = preflight(forward, report: &report)
        var folders: Set<String> = []
        for (position, move) in planned.enumerated() {
            do {
                try fileManager.createDirectory(
                    at: URL(fileURLWithPath: move.destinationPath).deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Self.renameExclusive(from: move.sourcePath, to: move.destinationPath)
                Self.moveAppleDoubleIfNeeded(from: move.sourcePath, to: move.destinationPath)
                report.moved.append(move)
                if let original = indexBySource[move.sourcePath] { report.reversedIndices.append(original) }
                folders.insert((move.sourcePath as NSString).deletingLastPathComponent)
            } catch {
                report.skipped.append(DriveMoveIssue(move: move, reason: error.localizedDescription))
            }
            progress?(FileOperationProgress(
                phase: "Redoing move",
                currentPath: (move.destinationPath as NSString).lastPathComponent,
                processedFiles: position + 1,
                totalFiles: planned.count
            ))
        }
        let didGoForward = Set(report.reversedIndices)
        if !didGoForward.isEmpty {
            journal.completedIndices = Array(Set(journal.completedIndices).union(didGoForward)).sorted()
            let rest = indices.filter { !didGoForward.contains($0) }
            journal.undoneIndices = rest.isEmpty ? nil : rest
            journal.undoneAt = nil
            journal.driveStepDone = true
            try Self.write(journal, to: journalURL)
        } else {
            journal.pendingStep = nil
            journal.driveStepDone = nil
            try Self.write(journal, to: journalURL)
        }
        pruneEmptyFolders(folders, boundaries: pruneBoundaries)
        return (report, journal)
    }

    /// Renames a whole folder on the same drive. It never merges into or
    /// replaces an existing folder.
    public func moveFolder(from source: URL, to destination: URL) throws {
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourcePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolkitError.notDirectory(sourcePath)
        }
        guard !Self.exists(destinationPath) else {
            throw ToolkitError.commandFailed("A folder already exists at \(destinationPath). Nothing was replaced.")
        }
        guard VolumeInfo.deviceNumber(for: source) == VolumeInfo.deviceNumber(for: destination.deletingLastPathComponent()) else {
            throw ToolkitError.commandFailed("\(source.lastPathComponent) is on a different drive than \(destinationPath).")
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.renameExclusive(from: sourcePath, to: destinationPath)
    }

    /// The Undo or Redo of this journal is complete: the catalog and the NAS
    /// copies followed the drive. Until this is written, a launch replays the
    /// step (`pendingStep`).
    public static func finishStep(journalURL: URL) throws {
        var journal = try read(journalURL)
        guard journal.pendingStep != nil else { return }
        journal.pendingStep = nil
        journal.driveStepDone = nil
        try write(journal, to: journalURL)
    }

    /// The journals in `folder`, newest first, whose Undo or Redo began and
    /// has not been finished — what a launch has to replay.
    public static func interruptedSteps(in folder: URL, limit: Int = 60) -> [(url: URL, journal: DriveMoveJournal)] {
        var found: [(url: URL, journal: DriveMoveJournal)] = []
        for url in journals(in: folder).prefix(limit) {
            if let journal = try? read(url), journal.pendingStep != nil { found.append((url, journal)) }
        }
        return found
    }

    /// Closes a journal that can no longer be undone (an event it names was
    /// deleted) so it stops standing in front of the older changes. No file
    /// is touched; the journal stays on disk, marked undone.
    public static func abandon(journalURL: URL) throws {
        var journal = try read(journalURL)
        journal.undoneAt = Date()
        try write(journal, to: journalURL)
    }

    /// Renames a folder to the same name in another letter case (`Beach day` →
    /// `Beach Day`), which the volume sees as one folder: it goes through a
    /// temporary name in the same parent, and comes back if the second step
    /// fails. `moveFolder` refuses this — its destination "exists".
    public func renameFolderChangingCase(from source: URL, to destination: URL) throws {
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard sourcePath.lowercased() == destinationPath.lowercased() else {
            throw ToolkitError.commandFailed("\(source.lastPathComponent) and \(destination.lastPathComponent) are not the same name.")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourcePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolkitError.notDirectory(sourcePath)
        }
        let parent = source.deletingLastPathComponent().standardizedFileURL
        let temporary = parent.appendingPathComponent(".rename-\(UUID().uuidString)").path
        try Self.renameExclusive(from: sourcePath, to: temporary)
        do {
            try Self.renameExclusive(from: temporary, to: destinationPath)
        } catch {
            try? Self.renameExclusive(from: temporary, to: sourcePath)
            throw error
        }
    }

    public static func journals(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public static func latestUndoableJournal(in folder: URL) -> (url: URL, journal: DriveMoveJournal)? {
        let barrier = layoutMigrationBarrier(in: folder)
        for url in journals(in: folder) {
            if let journal = try? read(url), journal.undoneAt == nil,
               !journal.completedIndices.isEmpty || firstMoveLooksDone(journal) {
                // Journals older than the layout migration name Card Copy
                // paths; undoing one would swap assignments back while the
                // files stay in Originals.
                if let barrier, journal.createdAt < barrier.completedAt { return nil }
                return (url, journal)
            }
        }
        return nil
    }

    /// A run that died before its first progress write recorded nothing, yet
    /// its first rename may have happened: the file is at the destination and
    /// gone from the source. Such a journal is still an Undo.
    private static func firstMoveLooksDone(_ journal: DriveMoveJournal) -> Bool {
        guard let first = journal.moves.first else { return false }
        return !exists(first.sourcePath) && isRegularFile(first.destinationPath)
    }

    /// Written into the journal folder by the layout migration: Apply
    /// journals recorded before `completedAt` are no longer undoable.
    public struct LayoutMigrationBarrier: Codable, Equatable, Sendable {
        public var migrationID: UUID
        public var completedAt: Date

        public init(migrationID: UUID, completedAt: Date) {
            self.migrationID = migrationID
            self.completedAt = completedAt
        }
    }

    /// Not a `.json` file, so `journals(in:)` never lists it.
    public static let layoutMigrationBarrierFileName = "layout-migration.barrier"

    public static func layoutMigrationBarrier(in folder: URL) -> LayoutMigrationBarrier? {
        let url = folder.appendingPathComponent(layoutMigrationBarrierFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LayoutMigrationBarrier.self, from: data)
    }

    public static func read(_ url: URL) throws -> DriveMoveJournal {
        let decoder = JSONDecoder()
        // Journals keep fractional seconds; older ones wrote whole seconds.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: journalDateStyle) {
                return date
            }
            if let date = try? Date(text, strategy: .iso8601) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
        }
        return try decoder.decode(DriveMoveJournal.self, from: Data(contentsOf: url))
    }

    private func preflight(_ moves: [DriveMove], report: inout DriveMoveReport) -> [DriveMove] {
        var destinations: Set<String> = []
        var planned: [DriveMove] = []
        for move in moves {
            let source = URL(fileURLWithPath: move.sourcePath).standardizedFileURL
            let destination = URL(fileURLWithPath: move.destinationPath).standardizedFileURL
            let normalized = DriveMove(sourcePath: source.path, destinationPath: destination.path, byteCount: move.byteCount)
            guard source.path.hasPrefix("/"), destination.path.hasPrefix("/"),
                  !move.sourcePath.split(separator: "/").contains(".."),
                  !move.destinationPath.split(separator: "/").contains("..") else {
                report.skipped.append(DriveMoveIssue(move: normalized, reason: "Unsafe path."))
                continue
            }
            guard Self.isRegularFile(source.path) else {
                report.skipped.append(DriveMoveIssue(move: normalized, reason: "The file is no longer at its original location."))
                continue
            }
            guard !Self.exists(destination.path) else {
                report.skipped.append(DriveMoveIssue(move: normalized, reason: "A file already exists at the destination. Nothing was replaced."))
                continue
            }
            guard destinations.insert(destination.path.lowercased()).inserted else {
                report.skipped.append(DriveMoveIssue(move: normalized, reason: "Two files would land on the same name. Nothing was replaced."))
                continue
            }
            guard let sourceDevice = VolumeInfo.deviceNumber(for: source),
                  let destinationDevice = VolumeInfo.deviceNumber(for: destination.deletingLastPathComponent()),
                  sourceDevice == destinationDevice else {
                report.skipped.append(DriveMoveIssue(move: normalized, reason: "The destination is on a different drive. Use a verified copy instead."))
                continue
            }
            planned.append(normalized)
        }
        return planned
    }

    /// Renames without ever replacing an existing file. exFAT and some other
    /// filesystems do not support `RENAME_EXCL`; they fall back to an
    /// existence check immediately before a same-volume `rename`.
    static func renameExclusive(from source: String, to destination: String) throws {
        if renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 {
            return
        }
        let code = errno
        switch code {
        case ENOTSUP, EINVAL:
            guard !exists(destination) else {
                throw ToolkitError.commandFailed("A file already exists at \(destination). Nothing was replaced.")
            }
            guard Darwin.rename(source, destination) == 0 else {
                throw posixError(errno, source: source, destination: destination)
            }
        default:
            throw posixError(code, source: source, destination: destination)
        }
    }

    static func moveAppleDoubleIfNeeded(from source: String, to destination: String) {
        let sourceDouble = ((source as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("._" + (source as NSString).lastPathComponent)
        let destinationDouble = ((destination as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("._" + (destination as NSString).lastPathComponent)
        guard exists(sourceDouble), !exists(destinationDouble) else { return }
        _ = Darwin.rename(sourceDouble, destinationDouble)
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func posixError(_ code: Int32, source: String, destination: String) -> ToolkitError {
        if code == EEXIST {
            return .commandFailed("A file already exists at \(destination). Nothing was replaced.")
        }
        if code == EXDEV {
            return .commandFailed("\((source as NSString).lastPathComponent) is on a different drive than its destination.")
        }
        return .commandFailed("Could not move \((source as NSString).lastPathComponent): \(String(cString: strerror(code))) (errno \(code))")
    }

    /// Removes folders emptied by a move, walking upward but never past or
    /// onto a boundary folder. Only Finder metadata files are removed along
    /// the way; a folder holding anything else is left untouched.
    func pruneEmptyFolders(_ folders: Set<String>, boundaries: [URL]) {
        let boundaryPaths = boundaries.map { $0.standardizedFileURL.path }
        guard !boundaryPaths.isEmpty else { return }
        for folder in folders.sorted(by: { $0.count > $1.count }) {
            var current = URL(fileURLWithPath: folder).standardizedFileURL.path
            while let boundary = boundaryPaths.first(where: { current.hasPrefix($0 + "/") }), current != boundary {
                guard let names = try? fileManager.contentsOfDirectory(atPath: current) else { break }
                guard names.allSatisfy(JunkPolicy.isJunkFile) else { break }
                for name in names {
                    try? fileManager.removeItem(atPath: (current as NSString).appendingPathComponent(name))
                }
                guard rmdir(current) == 0 else { break }
                current = (current as NSString).deletingLastPathComponent
            }
        }
    }

    private static func write(_ journal: DriveMoveJournal, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Fractional seconds matter: an assignment's identity rounds its
        // modification time, so a whole-second date read back from the
        // journal could name a different assignment and Undo would miss it.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(journalDateStyle))
        }
        try encoder.encode(journal).write(to: url, options: .atomic)
    }

    private static let stampClock = StampClock()

    /// `2026-08-20T06:00:04.500Z`: ISO 8601 with milliseconds.
    private static let journalDateStyle = Date.ISO8601FormatStyle()
        .year().month().day()
        .time(includingFractionalSeconds: true)
        .timeZone(separator: .omitted)

    private static func stamp(_ date: Date) -> String {
        stampClock.stamp(date)
    }
}

/// Microsecond journal ticks forced strictly increasing: back-to-back
/// moves inside one millisecond can never tie, so Undo always reverses
/// the most recent one.
private final class StampClock: @unchecked Sendable {
    private let lock = NSLock()
    private var lastMicros: Int64 = 0

    func stamp(_ date: Date) -> String {
        lock.lock()
        lastMicros = max(
            Int64(date.timeIntervalSince1970 * 1_000_000),
            lastMicros + 1
        )
        let micros = lastMicros
        lock.unlock()

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = formatter.string(from: Date(timeIntervalSince1970: Double(micros) / 1_000_000))
        return String(format: "%@-%06d", base, micros % 1_000_000)
    }
}
