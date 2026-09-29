import Foundation

/// One rename the NAS mirror owes after the drive changed: the copy at
/// `from` belongs at `to` (both relative to the NAS root, the same
/// `<year>/<event>/Originals/<Camera>/…` layout the drive has).
public struct NASRename: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file
        /// A whole event folder (an event rename or date change).
        case folder
    }

    public enum State: String, Codable, Sendable {
        /// Not applied yet — queued while the NAS is away or busy.
        case pending
        /// The NAS copy now sits at `to`.
        case renamed
        /// `to` already held the identical file, so the stale copy at
        /// `from` went to the NAS's `_Stale Copies` folder (`stalePath`).
        case merged
        /// Nothing was at `from`: the file was never on the NAS, or an
        /// earlier run already moved it.
        case absent
        /// `to` holds a different file. Both left exactly as they were.
        case differs
        /// `to` holds a file of the same size that no hash proves
        /// identical. Both left; Sync to NAS compares them.
        case unproven
        case failed
        /// A folder rename that could not be one rename (the new folder
        /// exists) and was split into per-file renames, appended to the
        /// batch.
        case expanded
        /// Never applied, and no longer wanted (its move was undone).
        case cancelled
    }

    public var kind: Kind
    public var from: String
    public var to: String
    /// The file's size when it moved on the drive (0 for a folder): a NAS
    /// copy of another size at `from` is not this file.
    public var byteCount: Int64
    /// The event the file belongs to now, for its sync record.
    public var eventID: UUID?
    /// The event it belonged to before, so Undo can put that back.
    public var previousEventID: UUID?
    public var state: State
    public var detail: String?
    /// Where the stale copy went (relative to the NAS root), for `.merged`.
    public var stalePath: String?
    /// How many times the rename was tried and the share answered with a
    /// transient error (a dropped session, `EIO`, a stale handle). Such a
    /// rename stays `.pending` — the copy is still at `from` — until it
    /// succeeds or `NASMoveFollower.maxAttempts` runs out. Nil: never.
    public var attempts: Int?

    public init(
        kind: Kind = .file,
        from: String,
        to: String,
        byteCount: Int64 = 0,
        eventID: UUID? = nil,
        previousEventID: UUID? = nil,
        state: State = .pending,
        detail: String? = nil,
        stalePath: String? = nil,
        attempts: Int? = nil
    ) {
        self.attempts = attempts
        self.kind = kind
        self.from = from
        self.to = to
        self.byteCount = byteCount
        self.eventID = eventID
        self.previousEventID = previousEventID
        self.state = state
        self.detail = detail
        self.stalePath = stalePath
    }
}

/// A durable list of NAS renames, written before the first one runs — the
/// journal a crash resumes from and an Undo reverses. A batch for a move
/// carries the id of its `DriveMoveJournal`.
public struct NASRenameBatch: Codable, Identifiable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// Files moved between events (or names) on the drive.
        case move
        /// An event folder was renamed on the drive.
        case folderRename
        /// A drive copy was merged into an identical one.
        case merge
        /// Sync to NAS found a NAS copy waiting at an old path.
        case catchUp
        /// Stale NAS duplicates of files already at their right path.
        case reconcile
        /// The reverse of another batch.
        case undo
    }

    public var id: UUID
    public var title: String
    public var origin: Origin
    public var createdAt: Date
    /// The standardized NAS root the paths are under.
    public var nasRoot: String
    /// The `DriveMoveJournal` this batch follows; Undo of that move reverses it.
    public var moveJournalID: UUID?
    /// The batch this one reverses.
    public var undoOf: UUID?
    public var ops: [NASRename]
    /// Set when the move was undone: the batch is closed.
    public var undoneAt: Date?
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        origin: Origin,
        createdAt: Date = Date(),
        nasRoot: String,
        moveJournalID: UUID? = nil,
        undoOf: UUID? = nil,
        ops: [NASRename]
    ) {
        self.id = id
        self.title = title
        self.origin = origin
        self.createdAt = createdAt
        self.nasRoot = NASSyncStore.standardizedRoot(nasRoot)
        self.moveJournalID = moveJournalID
        self.undoOf = undoOf
        self.ops = ops
    }

    public var pendingCount: Int { ops.filter { $0.state == .pending }.count }
    /// Waiting for the NAS: something is left to apply.
    public var isPending: Bool { undoneAt == nil && pendingCount > 0 }
}

/// The folder of NAS rename batches, one JSON file each, beside the move
/// journals (`Move Journals/NAS Renames`). Small: a batch is one move.
public struct NASRenameQueue: Sendable {
    public static let folderName = "NAS Renames"

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public init(journalFolder: URL) {
        self.folder = journalFolder.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// The file a batch lives in; stable for a batch, so saving overwrites.
    func url(for batch: NASRenameBatch) -> URL {
        let micros = Int64(batch.createdAt.timeIntervalSince1970 * 1_000_000)
        return folder.appendingPathComponent("\(micros)-\(batch.id.uuidString.prefix(8)).json")
    }

    /// Writes (or rewrites) `batch` atomically.
    public func save(_ batch: NASRenameBatch) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(batch).write(to: url(for: batch), options: .atomic)
    }

    /// Every batch, oldest first. A file that does not decode is skipped.
    public func batches() -> [NASRenameBatch] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(NASRenameBatch.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// Batches with renames still to apply, oldest first, optionally for
    /// one NAS root.
    public func pending(nasRoot: String? = nil) -> [NASRenameBatch] {
        let root = nasRoot.map(NASSyncStore.standardizedRoot)
        return batches().filter { $0.isPending && (root == nil || $0.nasRoot == root) }
    }

    /// The renames waiting for the NAS, counted.
    public func pendingRenameCount(nasRoot: String? = nil) -> Int {
        pending(nasRoot: nasRoot).reduce(0) { $0 + $1.pendingCount }
    }

    /// Batches recorded for one move journal.
    public func batches(forMoveJournal id: UUID) -> [NASRenameBatch] {
        batches().filter { $0.moveJournalID == id }
    }
}
