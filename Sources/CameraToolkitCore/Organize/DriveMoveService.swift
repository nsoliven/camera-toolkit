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

    public var completedMoves: [DriveMove] {
        completedIndices.compactMap { moves.indices.contains($0) ? moves[$0] : nil }
    }
}

public struct DriveMoveReport: Sendable {
    public var moved: [DriveMove] = []
    public var skipped: [DriveMoveIssue] = []
    public var journalPath: String?
    /// The journal's id, set when one was written — what NAS renames
    /// recorded for this move are linked to, so its Undo reverses them.
    public var journalID: UUID?

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
        pruneBoundaries: [URL] = [],
        progress: FileOperationProgressHandler? = nil
    ) throws -> DriveMoveReport {
        var report = DriveMoveReport()
        let planned = preflight(moves, report: &report)

        var journal = DriveMoveJournal(
            id: UUID(),
            title: title,
            createdAt: Date(),
            moves: planned,
            completedIndices: [],
            removedAssignments: removedAssignments,
            addedAssignments: addedAssignments
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
            if let journalURL, journal.completedIndices.count % 250 == 0, !journal.completedIndices.isEmpty {
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

        if let journalURL {
            try Self.write(journal, to: journalURL)
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
        let reversed = journal.completedMoves.reversed().map {
            DriveMove(sourcePath: $0.destinationPath, destinationPath: $0.sourcePath, byteCount: $0.byteCount)
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
        journal.undoneAt = Date()
        try Self.write(journal, to: journalURL)
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

    public static func journals(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public static func latestUndoableJournal(in folder: URL) -> (url: URL, journal: DriveMoveJournal)? {
        let barrier = layoutMigrationBarrier(in: folder)
        for url in journals(in: folder) {
            if let journal = try? read(url), journal.undoneAt == nil, !journal.completedIndices.isEmpty {
                // Journals older than the layout migration name Card Copy
                // paths; undoing one would swap assignments back while the
                // files stay in Originals.
                if let barrier, journal.createdAt < barrier.completedAt { return nil }
                return (url, journal)
            }
        }
        return nil
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
