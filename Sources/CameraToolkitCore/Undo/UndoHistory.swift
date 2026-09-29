import Foundation

/// One file the action moved into a `_Trash` batch: where the batch folder
/// is and the manifest entry that says where the file came from (and which
/// catalog entries went with it), so Undo can put it back and Redo can send
/// it again.
public struct UndoTrashedFile: Codable, Hashable, Sendable {
    /// Absolute path of the `<trashRoot>/<batch>` folder.
    public var batchFolder: String
    public var entry: MediaTrashEntry

    public init(batchFolder: String, entry: MediaTrashEntry) {
        self.batchFolder = batchFolder
        self.entry = entry
    }

    /// The Trash browser's unit for this file, enough for
    /// `MediaTrashService.restore(items:)` (which re-reads the manifest).
    public var item: MediaTrashItem {
        let folder = URL(fileURLWithPath: batchFolder, isDirectory: true)
        return MediaTrashItem(
            batchName: folder.lastPathComponent,
            batchFolder: folder,
            relativePath: entry.trashedRelativePath,
            fileName: (entry.trashedRelativePath as NSString).lastPathComponent,
            size: entry.size,
            modifiedAt: entry.capturedAt ?? Date(),
            trashedAt: Date(),
            capturedAt: entry.capturedAt,
            eventID: entry.eventID,
            eventName: entry.eventName,
            personNames: entry.personNames,
            originalAbsolutePath: entry.originalAbsolutePath,
            originalLocationName: entry.originalLocationName,
            deviceID: entry.deviceID
        )
    }
}

/// What an action that touched files or catalog entries did, as the four
/// pieces Undo and Redo replay in a fixed order:
///
/// 1. a journaled drive rename (`journalID`) — the move journal owns which
///    catalog entries swap with which rename;
/// 2. files sent to a `_Trash` batch (`trashed`) — Undo restores them,
///    Redo sends them again;
/// 3. a plain catalog swap (`removed` out, `added` in) for the entries no
///    journal covers — a sort, a merge into a copy the event already had,
///    the entries a Trash or a duplicate resolution dropped;
/// 4. NAS renames queued under `nasLinks`, which follow the drive.
public struct UndoFilesAction: Codable, Equatable, Sendable {
    public var removed: [PhotoEventAssignment]
    public var added: [PhotoEventAssignment]
    public var journalID: UUID?
    /// The journal's file name inside the journal folder.
    public var journalFile: String?
    public var trashed: [UndoTrashedFile]
    /// Root the trash batch's relative paths were taken from, when the files
    /// were not on a mounted volume (a Redo sends them the same way).
    public var trashOriginRoot: String?
    public var nasLinks: [UUID]
    /// Where the events kept their folders when the action ran. Undo of the
    /// NAS renames refuses once one moved.
    public var eventFolders: [String: String]?
    /// Set when the last step acted on the NAS copies and the catalog only,
    /// because the drive was not there (unplugged, or wiped): the indices of
    /// the journal's renames whose drive files were left where they were.
    /// The next step, the opposite one, does the same for them — the drive is
    /// still in the state the step before this one left it in — and clears it.
    public var driveLagging: [Int]?

    public init(
        removed: [PhotoEventAssignment] = [],
        added: [PhotoEventAssignment] = [],
        journalID: UUID? = nil,
        journalFile: String? = nil,
        trashed: [UndoTrashedFile] = [],
        trashOriginRoot: String? = nil,
        nasLinks: [UUID] = [],
        eventFolders: [String: String]? = nil,
        driveLagging: [Int]? = nil
    ) {
        self.removed = removed
        self.added = added
        self.journalID = journalID
        self.journalFile = journalFile
        self.trashed = trashed
        self.trashOriginRoot = trashOriginRoot
        self.nasLinks = nasLinks
        self.eventFolders = eventFolders
        self.driveLagging = driveLagging
    }

    /// Only catalog entries changed: nothing on a drive to rename or restore.
    public var isCatalogOnly: Bool { journalID == nil && trashed.isEmpty }
    public var touchesFiles: Bool { journalID != nil || !trashed.isEmpty }
}

/// A folder the event edit renamed on a drive: Undo renames it back.
public struct UndoFolderMove: Codable, Equatable, Sendable {
    public var old: String
    public var new: String
    /// The two names differ only in letter case.
    public var caseOnly: Bool

    public init(old: String, new: String, caseOnly: Bool) {
        self.old = old
        self.new = new
        self.caseOnly = caseOnly
    }
}

/// An event's name, date, parent or storage setting changed — and with it
/// the folders it lives in and the source paths of the entries adopted
/// from them.
public struct UndoEventEdit: Codable, Equatable, Sendable {
    public var eventID: UUID
    public var before: SavedCameraEvent
    public var after: SavedCameraEvent
    public var folderMoves: [UndoFolderMove]
    /// The event and its subevents, whose adopted entries follow the folders.
    public var touchedEventIDs: [UUID]
    /// The NAS folder rename queued under this id, if one was owed.
    public var nasLink: UUID?
    /// Set when the last step renamed the event and its NAS folder only,
    /// because the drive's folders were not there (unplugged, or wiped): the
    /// drive is still one step behind, and the next step leaves it alone.
    public var driveLagging: Bool?

    public init(
        eventID: UUID,
        before: SavedCameraEvent,
        after: SavedCameraEvent,
        folderMoves: [UndoFolderMove] = [],
        touchedEventIDs: [UUID] = [],
        nasLink: UUID? = nil,
        driveLagging: Bool? = nil
    ) {
        self.eventID = eventID
        self.before = before
        self.after = after
        self.folderMoves = folderMoves
        self.touchedEventIDs = touchedEventIDs
        self.nasLink = nasLink
        self.driveLagging = driveLagging
    }
}

/// A display-rotation entry that changed: `nil` is "no entry".
public struct UndoOrientationChange: Codable, Equatable, Sendable {
    public var key: String
    public var before: Int?
    public var after: Int?

    public init(key: String, before: Int?, after: Int?) {
        self.key = key
        self.before = before
        self.after = after
    }
}

/// An event before and after an edit that touched no folder.
public struct UndoEventPair: Codable, Equatable, Sendable {
    public var before: SavedCameraEvent
    public var after: SavedCameraEvent

    public init(before: SavedCameraEvent, after: SavedCameraEvent) {
        self.before = before
        self.after = after
    }
}

/// An event created, deleted, or edited without touching folders (a storage
/// policy). `created` events are removed on Undo, `deleted` ones put back,
/// `edited` ones get their old fields back.
public struct UndoEventsChange: Codable, Equatable, Sendable {
    public var created: [SavedCameraEvent]
    public var deleted: [SavedCameraEvent]
    public var edited: [UndoEventPair]

    public init(
        created: [SavedCameraEvent] = [],
        deleted: [SavedCameraEvent] = [],
        edited: [UndoEventPair] = []
    ) {
        self.created = created
        self.deleted = deleted
        self.edited = edited
    }
}

/// A change to configuration only — nothing on disk moved.
public enum UndoConfigChange: Codable, Equatable, Sendable {
    /// A burst split the action appended; Undo removes it by id.
    case burstSplit(BurstSplit)
    case orientations([UndoOrientationChange])
    case events(UndoEventsChange)
}

/// What one Undo step replays.
public enum UndoAction: Codable, Equatable, Sendable {
    case files(UndoFilesAction)
    case eventEdit(UndoEventEdit)
    case config(UndoConfigChange)
    /// Face rows as they were (Undo) or are (Redo); swapped on each step.
    case faces(FaceSnapshot)
    /// A change whose undo lives in memory only (regrouped bursts on a
    /// scanned folder). Never persisted.
    case session(UUID)

    public var isPersistent: Bool {
        if case .session = self { return false }
        return true
    }
}

public struct UndoEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    /// "Move to Lakeside"
    public var title: String
    /// "12 files"
    public var detail: String?
    public var action: UndoAction

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        detail: String? = nil,
        action: UndoAction
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.detail = detail
        self.action = action
    }

    /// The name a menu shows after "Undo" or "Redo": "Move to Lakeside (12 files)".
    public var displayName: String {
        guard let detail, !detail.isEmpty else { return title }
        return "\(title) (\(detail))"
    }

    /// The journal this entry owns, if any.
    public var journalID: UUID? {
        if case .files(let files) = action { return files.journalID }
        return nil
    }

    /// "12 files" / "1 file".
    public static func fileCount(_ count: Int) -> String {
        "\(count.formatted()) file\(count == 1 ? "" : "s")"
    }
}

/// The one time-ordered list every undoable action registers in. ⌘Z takes
/// the newest entry off `undoStack` and, once it worked, puts it on
/// `redoStack`; ⌘⇧Z does the reverse. A new action clears `redoStack` —
/// what was undone can no longer be redone on top of something else.
public struct UndoHistory: Codable, Equatable, Sendable {
    public static let defaultCapacity = 100

    public private(set) var undoStack: [UndoEntry]
    public private(set) var redoStack: [UndoEntry]
    public var capacity: Int

    public init(undoStack: [UndoEntry] = [], redoStack: [UndoEntry] = [], capacity: Int = UndoHistory.defaultCapacity) {
        self.undoStack = undoStack
        self.redoStack = redoStack
        self.capacity = capacity
    }

    public var nextUndo: UndoEntry? { undoStack.last }
    public var nextRedo: UndoEntry? { redoStack.last }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// A finished action: newest on the undo stack, redo forgotten.
    public mutating func record(_ entry: UndoEntry) {
        undoStack.append(entry)
        redoStack.removeAll()
        trim()
    }

    /// An entry found on disk that no action recorded (a journal an earlier
    /// build wrote): it takes its place in time order, redo untouched.
    public mutating func insertChronologically(_ entry: UndoEntry) {
        let position = undoStack.firstIndex { $0.createdAt > entry.createdAt } ?? undoStack.count
        undoStack.insert(entry, at: position)
        trim()
    }

    /// The newest entry's Undo worked: it becomes the next Redo. `entry` is
    /// the entry as the step left it (Redo may need updated pieces — the
    /// new Trash batch, say).
    public mutating func completeUndo(_ entry: UndoEntry) {
        remove(entry.id)
        redoStack.append(entry)
    }

    /// The next Redo worked: it is the newest Undo again.
    public mutating func completeRedo(_ entry: UndoEntry) {
        remove(entry.id)
        undoStack.append(entry)
        trim()
    }

    /// Replaces an entry in place (an Undo that only partly worked keeps
    /// the entry, with what is still left to do).
    public mutating func replace(_ entry: UndoEntry) {
        if let index = undoStack.firstIndex(where: { $0.id == entry.id }) {
            undoStack[index] = entry
        } else if let index = redoStack.firstIndex(where: { $0.id == entry.id }) {
            redoStack[index] = entry
        }
    }

    /// Takes an entry out of both stacks — it can never be undone (an event
    /// it names was deleted) and must stop standing in front of older ones.
    public mutating func remove(_ id: UUID) {
        undoStack.removeAll { $0.id == id }
        redoStack.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Keeps the newest entries. An old journal that falls off stays on disk
    /// and can still be found by "Undo Last Move" style discovery only if it
    /// is the newest open one.
    private mutating func trim() {
        if undoStack.count > capacity { undoStack.removeFirst(undoStack.count - capacity) }
        if redoStack.count > capacity { redoStack.removeFirst(redoStack.count - capacity) }
    }

    /// A history rebuilt from disk: both stacks in order, session entries gone.
    public var persistent: UndoHistory {
        UndoHistory(
            undoStack: undoStack.filter { $0.action.isPersistent },
            redoStack: redoStack.filter { $0.action.isPersistent },
            capacity: capacity
        )
    }
}

extension MediaTrashBatch {
    /// Every file this batch holds as an undo reference.
    public var undoTrashedFiles: [UndoTrashedFile] {
        segments.flatMap { segment in
            segment.entries.map { UndoTrashedFile(batchFolder: segment.folder.path, entry: $0) }
        }
    }
}
