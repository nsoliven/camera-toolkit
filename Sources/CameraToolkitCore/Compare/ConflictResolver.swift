import Darwin
import Foundation

/// A Sync to NAS conflict: the drive's copy of a file and the different
/// copy the NAS already holds at its mirrored path.
public struct ConflictPair: Codable, Equatable, Sendable {
    /// Absolute path of the drive copy.
    public var drivePath: String
    /// The NAS mirror root (standardized).
    public var nasRoot: String
    /// The file's path under `nasRoot` — what Sync to NAS recorded.
    public var relativePath: String
    public var eventID: UUID?

    public init(drivePath: String, nasRoot: String, relativePath: String, eventID: UUID? = nil) {
        self.drivePath = drivePath
        self.nasRoot = URL(fileURLWithPath: nasRoot).standardizedFileURL.path
        self.relativePath = relativePath
        self.eventID = eventID
    }

    public var nasPath: String { nasRoot + "/" + relativePath }
}

/// Which version wins. Nothing loses its bytes: the other version is set
/// aside (NAS `_Stale Copies`, drive `_Trash`) or kept under a new name.
public enum ConflictChoice: String, Codable, CaseIterable, Sendable {
    case keepDrive
    case keepNAS
    case keepBoth
}

/// What a resolution did, step by step — written before the first file
/// moves and after every step, so an interrupted one can be followed by
/// hand and undone.
public struct ConflictResolution: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case planned
        case done
        case failed
        case undone
    }

    public var id: UUID
    public var createdAt: Date
    public var choice: ConflictChoice
    public var pair: ConflictPair
    public var driveSHA256: String
    public var nasSHA256: String
    public var driveByteCount: Int64
    public var nasByteCount: Int64
    /// Keep drive: where the NAS version was set aside.
    public var staleNASPath: String?
    /// Keep NAS: the `_Trash` batch folder holding the drive version.
    public var trashBatchFolder: String?
    /// Keep both: the NAS version's new name, on the NAS and the drive.
    public var keptNASPath: String?
    public var keptDrivePath: String?
    public var steps: [String] = []
    public var status: Status = .planned
    public var detail: String?
}

public enum ConflictResolveError: Error, Equatable, LocalizedError {
    case unsafePath(String)
    case notAFile(String)
    case changedSinceCompared(String)
    case alreadyIdentical
    case verifyFailed(String)
    case trashFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): "The path \(path) cannot be resolved safely."
        case .notAFile(let path): "\(path) is not a regular file (it is missing, a folder, or a link)."
        case .changedSinceCompared(let side): "The \(side) copy changed since it was compared. Compare again, then choose."
        case .alreadyIdentical: "Both copies are identical now — there is nothing to resolve."
        case .verifyFailed(let path): "The new copy at \(path) did not verify against the original's SHA-256. It was not put in place."
        case .trashFailed(let reason): "The drive copy could not be moved to the drive's _Trash: \(reason)"
        }
    }
}

/// Resolves one Sync to NAS conflict without overwriting or deleting a
/// file: the losing NAS version moves to `.Camera Toolkit/_Stale Copies`
/// on the NAS, the losing drive version to the drive's `_Trash` through
/// `MediaTrashService`, and the winning version is copied in through an
/// exclusive temporary, re-hashed, and renamed into place only when its
/// SHA-256 matches. Both copies are re-hashed first and must still be the
/// ones the owner compared. Afterwards `nas_sync_files` records the pair
/// as verified, so the next Sync to NAS reports no conflict.
public struct ConflictResolver: Sendable {
    public static let staleFolderPath = NASMoveFollower.staleFolderPath
    public static let temporaryMarker = ".ctresolve-"

    let store: NASSyncStore?
    let removedFilesRoot: URL
    let journalFolder: URL
    let volumeRoot: @Sendable (URL) -> URL?
    let now: @Sendable () -> Date

    public init(
        store: NASSyncStore?,
        removedFilesRoot: URL,
        journalFolder: URL,
        volumeRoot: @escaping @Sendable (URL) -> URL? = VolumeInfo.volumeRoot(for:),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.removedFilesRoot = removedFilesRoot
        self.journalFolder = journalFolder
        self.volumeRoot = volumeRoot
        self.now = now
    }

    // MARK: - Resolve

    /// `expectedDrive` and `expectedNAS` are the SHA-256s the owner saw
    /// when comparing; a copy that changed since refuses the resolution.
    public func resolve(
        _ pair: ConflictPair,
        choice: ConflictChoice,
        expectedDrive: String,
        expectedNAS: String
    ) throws -> ConflictResolution {
        guard EventStorageLocations.isLexicallyClean(pair.relativePath),
              (try? PathSafety.validateRelativePath(pair.relativePath)) != nil else {
            throw ConflictResolveError.unsafePath(pair.relativePath)
        }
        let drive = try Self.regularFile(pair.drivePath)
        let nas = try Self.regularFile(pair.nasPath)
        let driveSHA = try NASFileIO.sha256(pair.drivePath, uncached: false, expectedByteCount: drive.size)
        let nasSHA = try NASFileIO.sha256(pair.nasPath, uncached: true, expectedByteCount: nas.size)
        guard driveSHA == expectedDrive else { throw ConflictResolveError.changedSinceCompared("drive") }
        guard nasSHA == expectedNAS else { throw ConflictResolveError.changedSinceCompared("NAS") }
        guard driveSHA != nasSHA else { throw ConflictResolveError.alreadyIdentical }

        var journal = ConflictResolution(
            id: UUID(), createdAt: now(), choice: choice, pair: pair,
            driveSHA256: driveSHA, nasSHA256: nasSHA, driveByteCount: drive.size, nasByteCount: nas.size
        )
        try save(journal)
        do {
            switch choice {
            case .keepDrive: try keepDrive(&journal, nasModified: nas.modified)
            case .keepNAS: try keepNAS(&journal, nasModified: nas.modified)
            case .keepBoth: try keepBoth(&journal, nasModified: nas.modified)
            }
            journal.status = .done
            try save(journal)
            return journal
        } catch {
            journal.status = .failed
            journal.detail = error.localizedDescription
            try? save(journal)
            throw error
        }
    }

    /// The NAS version moves to `_Stale Copies`; the drive version is
    /// copied to the NAS and verified there.
    private func keepDrive(_ journal: inout ConflictResolution, nasModified: Double) throws {
        let pair = journal.pair
        let stale = staleDestination(for: pair, id: journal.id)
        _ = try NASFileIO.makeDirectories((stale as NSString).deletingLastPathComponent)
        try NASFileIO.renameExclusive(from: pair.nasPath, to: stale)
        journal.staleNASPath = stale
        journal.steps.append("Set the NAS version aside in \(Self.staleFolderPath).")
        try save(journal)
        do {
            try placeVerified(from: pair.drivePath, to: pair.nasPath, sha256: journal.driveSHA256, byteCount: journal.driveByteCount, uncachedVerify: true)
        } catch {
            // Put the NAS version back where it was; nothing else changed.
            if (try? NASFileIO.renameExclusive(from: stale, to: pair.nasPath)) != nil {
                journal.staleNASPath = nil
                journal.steps.append("The copy failed; the NAS version was put back.")
            }
            throw error
        }
        journal.steps.append("Copied the drive version to the NAS and verified its SHA-256.")
        try record(pair.relativePath, pair: pair, sha: journal.driveSHA256, byteCount: journal.driveByteCount, drivePath: pair.drivePath)
    }

    /// The drive version moves to the drive's `_Trash`; the NAS version is
    /// copied to the drive, verified, and given the NAS copy's date.
    private func keepNAS(_ journal: inout ConflictResolution, nasModified: Double) throws {
        let pair = journal.pair
        let trashed = try trash(pair.drivePath)
        journal.trashBatchFolder = trashed
        journal.steps.append("Moved the drive version to the drive's _Trash.")
        try save(journal)
        try placeVerified(from: pair.nasPath, to: pair.drivePath, sha256: journal.nasSHA256, byteCount: journal.nasByteCount, uncachedVerify: false, modified: nasModified)
        journal.steps.append("Copied the NAS version to the drive and verified its SHA-256.")
        try record(pair.relativePath, pair: pair, sha: journal.nasSHA256, byteCount: journal.nasByteCount, drivePath: pair.drivePath)
    }

    /// The NAS version is renamed beside it on the NAS and copied to the
    /// drive under that name; the drive version takes the original name on
    /// the NAS. Both versions end up on both sides.
    private func keepBoth(_ journal: inout ConflictResolution, nasModified: Double) throws {
        let pair = journal.pair
        let keptName = Self.keptName(for: (pair.relativePath as NSString).lastPathComponent, modified: nasModified) { name in
            let nasCandidate = ((pair.nasPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
            let driveCandidate = ((pair.drivePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
            return !Self.exists(nasCandidate) && !Self.exists(driveCandidate)
        }
        let keptNAS = ((pair.nasPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(keptName)
        let keptDrive = ((pair.drivePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(keptName)
        try NASFileIO.renameExclusive(from: pair.nasPath, to: keptNAS)
        journal.keptNASPath = keptNAS
        journal.steps.append("Renamed the NAS version to \(keptName) on the NAS.")
        try save(journal)
        do {
            try placeVerified(from: keptNAS, to: keptDrive, sha256: journal.nasSHA256, byteCount: journal.nasByteCount, uncachedVerify: false, modified: nasModified)
        } catch {
            if (try? NASFileIO.renameExclusive(from: keptNAS, to: pair.nasPath)) != nil {
                journal.keptNASPath = nil
                journal.steps.append("The copy failed; the NAS version got its name back.")
            }
            throw error
        }
        journal.keptDrivePath = keptDrive
        journal.steps.append("Copied it to the drive as \(keptName) and verified its SHA-256.")
        try save(journal)
        try placeVerified(from: pair.drivePath, to: pair.nasPath, sha256: journal.driveSHA256, byteCount: journal.driveByteCount, uncachedVerify: true)
        journal.steps.append("Copied the drive version to the NAS under the original name and verified it.")
        let keptRelative = ((pair.relativePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(keptName)
        try record(pair.relativePath, pair: pair, sha: journal.driveSHA256, byteCount: journal.driveByteCount, drivePath: pair.drivePath)
        try record(keptRelative, pair: pair, sha: journal.nasSHA256, byteCount: journal.nasByteCount, drivePath: keptDrive)
    }

    // MARK: - Undo

    /// Takes a finished resolution back the same way: whatever was put in
    /// place moves aside (NAS `_Stale Copies`, drive `_Trash`), and what
    /// was set aside returns to its original path. Refuses when a file it
    /// would act on is no longer the one the resolution left there.
    public func undo(_ resolution: ConflictResolution) throws -> ConflictResolution {
        var journal = resolution
        let pair = journal.pair
        guard journal.status == .done else { throw ConflictResolveError.unsafePath("a resolution that did not finish") }
        let undoID = UUID()
        switch journal.choice {
        case .keepDrive:
            guard let stale = journal.staleNASPath else { throw ConflictResolveError.notAFile("the set-aside NAS version") }
            _ = try Self.regularFile(stale)
            try requireHash(pair.nasPath, journal.driveSHA256, uncached: true, side: "NAS")
            try setAsideOnNAS(pair.nasPath, pair: pair, id: undoID)
            try NASFileIO.renameExclusive(from: stale, to: pair.nasPath)
        case .keepNAS:
            guard let folder = journal.trashBatchFolder else { throw ConflictResolveError.notAFile("the trashed drive version") }
            try requireHash(pair.drivePath, journal.nasSHA256, uncached: false, side: "drive")
            _ = try trash(pair.drivePath)
            let service = MediaTrashService(removedFilesRoot: removedFilesRoot, volumeRoot: volumeRoot, now: now)
            let folderURL = URL(fileURLWithPath: folder).standardizedFileURL
            let segments = service.listBatches(under: [folderURL.deletingLastPathComponent()])
                .flatMap(\.segments)
                .filter { $0.folder.standardizedFileURL.path == folderURL.path }
            guard !segments.isEmpty else { throw ConflictResolveError.notAFile(folder) }
            let report = service.restore(batch: MediaTrashBatch(name: folderURL.lastPathComponent, createdAt: journal.createdAt, segments: segments))
            guard Self.exists(pair.drivePath) else {
                throw ConflictResolveError.trashFailed("the drive version could not be restored from \(folder) (\(report))")
            }
        case .keepBoth:
            guard let keptNAS = journal.keptNASPath, let keptDrive = journal.keptDrivePath else {
                throw ConflictResolveError.notAFile("the kept copies")
            }
            try requireHash(pair.nasPath, journal.driveSHA256, uncached: true, side: "NAS")
            try requireHash(keptNAS, journal.nasSHA256, uncached: true, side: "NAS")
            try setAsideOnNAS(pair.nasPath, pair: pair, id: undoID)
            try NASFileIO.renameExclusive(from: keptNAS, to: pair.nasPath)
            _ = try trash(keptDrive)
        }
        // The pair is a conflict again until it is resolved or synced.
        try store?.upsert([NASSyncRecord(
            nasRoot: pair.nasRoot, relativePath: pair.relativePath, eventID: pair.eventID,
            byteCount: journal.driveByteCount, sha256: journal.driveSHA256, nasSHA256: journal.nasSHA256,
            state: .conflict, detail: "The conflict resolution was undone.", checkedAt: now()
        )])
        journal.status = .undone
        journal.steps.append("Undone: the original versions are back where they were.")
        try save(journal)
        return journal
    }

    // MARK: - Pieces

    /// Copies `source` to an exclusive temporary beside `destination`,
    /// re-hashes it, and renames it into place only when both hashes match.
    /// The temporary is this resolver's own partial file; it is removed
    /// when the copy cannot be proven.
    func placeVerified(from source: String, to destination: String, sha256: String, byteCount: Int64, uncachedVerify: Bool, modified: Double? = nil) throws {
        let folder = (destination as NSString).deletingLastPathComponent
        let name = (destination as NSString).lastPathComponent
        let temporary = (folder as NSString).appendingPathComponent(".\(name)\(Self.temporaryMarker)\(UUID().uuidString.prefix(8))")
        let copied = try NASFileIO.copyNew(from: source, to: temporary, expectedByteCount: byteCount)
        do {
            guard copied.sha256 == sha256 else { throw ConflictResolveError.verifyFailed(destination) }
            guard try NASFileIO.sha256(temporary, uncached: uncachedVerify, expectedByteCount: byteCount) == sha256 else {
                throw ConflictResolveError.verifyFailed(destination)
            }
            if let modified { Self.setModificationTime(temporary, modified) }
            try NASFileIO.renameExclusive(from: temporary, to: destination)
        } catch {
            unlink(temporary)
            throw error
        }
    }

    private func requireHash(_ path: String, _ expected: String, uncached: Bool, side: String) throws {
        let file = try Self.regularFile(path)
        guard try NASFileIO.sha256(path, uncached: uncached, expectedByteCount: file.size) == expected else {
            throw ConflictResolveError.changedSinceCompared(side)
        }
    }

    private func setAsideOnNAS(_ path: String, pair: ConflictPair, id: UUID) throws {
        let stale = staleDestination(for: pair, id: id)
        _ = try NASFileIO.makeDirectories((stale as NSString).deletingLastPathComponent)
        try NASFileIO.renameExclusive(from: path, to: stale)
    }

    /// `<nasRoot>/.Camera Toolkit/_Stale Copies/<stamp>-<id>/<relative path>`
    /// — the convention `NASMoveFollower` sets copies aside with.
    func staleDestination(for pair: ConflictPair, id: UUID) -> String {
        "\(pair.nasRoot)/\(Self.staleFolderPath)/\(NASMoveFollower.stamp(now()))-\(id.uuidString.prefix(4))/\(pair.relativePath)"
    }

    /// Moves a drive file into its volume's `_Trash` with a manifest;
    /// answers the batch folder.
    private func trash(_ path: String) throws -> String {
        let file = try Self.regularFile(path)
        let service = MediaTrashService(removedFilesRoot: removedFilesRoot, volumeRoot: volumeRoot, now: now)
        let batch = try service.trash(
            files: [OrganizeFile(path: path, size: file.size, modifiedAt: Date(timeIntervalSince1970: file.modified))],
            originRoot: nil
        )
        guard batch.skipped.isEmpty, !Self.exists(path), let folder = batch.segments.first?.folder else {
            throw ConflictResolveError.trashFailed(batch.skipped.first?.reason ?? "it is still at its path")
        }
        return folder.path
    }

    /// The pair as Sync to NAS records a verified file, so its next run
    /// skips it instead of reporting a conflict.
    private func record(_ relativePath: String, pair: ConflictPair, sha: String, byteCount: Int64, drivePath: String) throws {
        guard let store else { return }
        let drive = try Self.regularFile(drivePath)
        let timestamp = now()
        try store.upsert([NASSyncRecord(
            nasRoot: pair.nasRoot, relativePath: relativePath, eventID: pair.eventID,
            byteCount: byteCount, sourceModifiedAt: drive.modified, sha256: sha, nasSHA256: sha,
            state: .verified, detail: "Conflict resolved in Camera Toolkit.", checkedAt: timestamp, verifiedAt: timestamp
        )])
    }

    private func save(_ journal: ConflictResolution) throws {
        try FileManager.default.createDirectory(at: journalFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: journalFolder.appendingPathComponent("\(journal.id.uuidString).json"), options: .atomic)
    }

    /// Every resolution journal in `folder`, newest first.
    public static func journals(in folder: URL) -> [ConflictResolution] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ConflictResolution.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// "DSC00177 (NAS 2026-09-06).photo-edit", numbered when taken.
    static func keptName(for name: String, modified: Double, isFree: (String) -> Bool) -> String {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date(timeIntervalSince1970: modified))
        for attempt in 1...99 {
            let label = attempt == 1 ? "NAS \(date)" : "NAS \(date) \(attempt)"
            let candidate = ext.isEmpty ? "\(stem) (\(label))" : "\(stem) (\(label)).\(ext)"
            if isFree(candidate) { return candidate }
        }
        return "\(stem) (NAS \(UUID().uuidString.prefix(6)))" + (ext.isEmpty ? "" : ".\(ext)")
    }

    struct FileFacts {
        var size: Int64
        /// Seconds since 1970, as Sync to NAS reads them.
        var modified: Double
    }

    /// A regular file's size and modification time; links and folders are
    /// refused.
    static func regularFile(_ path: String) throws -> FileFacts {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ConflictResolveError.notAFile(path)
        }
        return FileFacts(
            size: Int64(info.st_size),
            modified: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        )
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func setModificationTime(_ path: String, _ seconds: Double) {
        let whole = seconds.rounded(.down)
        var times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(tv_sec: Int(whole), tv_nsec: Int(((seconds - whole) * 1e9).rounded())),
        ]
        _ = utimensat(AT_FDCWD, path, &times, 0)
    }
}
