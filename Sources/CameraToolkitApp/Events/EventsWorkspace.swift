import AppKit
import CameraToolkitCore
import Foundation
import Observation

extension Notification.Name {
    static let cameraToolkitUndo = Notification.Name("CameraToolkit.Undo")
    static let cameraToolkitRedo = Notification.Name("CameraToolkit.Redo")
    /// Posted after a Trash batch is restored so unsorted boards rescan and
    /// show the files that came back.
    static let cameraToolkitMediaTrashChanged = Notification.Name("CameraToolkit.MediaTrashChanged")
}

enum EventsSidebarSelection: Hashable, Sendable {
    case unsorted(UUID)
    case event(UUID)
}

struct UnsortedSourceState {
    var result: OrganizeScanResult? {
        didSet {
            stacksByID = Dictionary(
                (result?.stacks ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
    /// `OrganizeStack.id` → stack, kept in step with `result` so a menu or
    /// key handler resolves its targets by lookup instead of scanning the
    /// whole board on every right-click.
    private(set) var stacksByID: [String: OrganizeStack] = [:]
    var isScanning = false
    var progress: OrganizeScanProgress?
    var error: String?
}

struct NewEventRequest: Identifiable {
    let id = UUID()
    var suggestedDate: Date
    var sourceLocationID: UUID?
    var stackIDs: Set<String>
    /// Preselected parent for "New Subevent…"; nil means a top-level event.
    var parentEventID: UUID?
    /// Set when the stacks live on an event board: completing the request
    /// moves them into the new event instead of assigning from a source.
    var moveFromEventID: UUID?
}

struct RenameEventRequest: Identifiable {
    var id: UUID { eventID }
    var eventID: UUID
}

/// Pending "Scan for Faces" sheet — the unsorted location or event to
/// scan; the sheet picks quality and whether Fast pins the Mac before the
/// job starts.
struct FaceScanRequest: Identifiable {
    enum Subject: Sendable {
        case location(UUID)
        case event(UUID)
    }

    var subject: Subject
    var id: UUID {
        switch subject {
        case .location(let id), .event(let id): id
        }
    }
}

struct RemovalRequest: Identifiable {
    enum Kind: Sendable {
        case drive
        case source
    }

    let id = UUID()
    var kind: Kind
    var eventID: UUID
    var fileCount: Int
    var byteCount: Int64
}

/// The Sync All to NAS confirmation. Its numbers are read live from
/// `nasPresence`, so Check Again updates the open sheet.
struct SyncAllToNASRequest: Identifiable {
    let id = UUID()
}

/// Confirmation before organizer Trash. Files are not moved until the user
/// confirms. Destinations are the volume-local `_Trash` folders, never Finder.
struct PendingTrashRequest: Identifiable {
    let id = UUID()
    var items: [OrganizeItem]
    var locationID: UUID?
    var eventID: UUID?
    var locationName: String
    var fileCount: Int
    var byteCount: Int64
    var sampleNames: [String]
    var destinations: [MediaTrashDestinationPreview]
    /// Source keys whose event assignment survives the trash — spare
    /// identical copies whose assignment is the event's only record.
    var preservedAssignmentKeys: Set<String> = []
    /// An extra line for the confirmation, e.g. why these files are spare.
    var note: String?
}

struct OrganizeApplyPlan: Identifiable, Sendable {
    struct CopyBatch: Sendable {
        var sourceRoot: String
        var destinationRoot: String
        var deviceID: String
        var files: [FileRecord]
    }

    struct EventGroup: Identifiable, Sendable {
        var id: UUID { event.id }
        var event: SavedCameraEvent
        var moves: [DriveMove]
        var copies: [CopyBatch]
        var alreadyThere: Int
        var unavailable: Int
        var destinationFolder: String
        /// The event's resolved private flag (subevents inherit it), for the
        /// chip lock in the plan sheet.
        var isPrivate: Bool
        var byteCount: Int64
        /// Sources whose destination already holds a byte-identical file.
        /// Not moved, not counted in `moves`; the sheet offers Trash.
        var duplicates: [ApplyCollision] = []
        /// Sources whose destination holds a different file with the same
        /// name, plus the sidecars held back with them. Not moved; the
        /// sheet offers Keep Both.
        var conflicts: [ApplyCollision] = []

        var copyFileCount: Int { copies.reduce(0) { $0 + $1.files.count } }
        /// Files that cannot move because their name is taken by another file
        /// (sidecars held back with them are not counted).
        var nameConflictCount: Int { conflicts.count { $0.kind == .nameConflict } }
    }

    let id = UUID()
    var title: String
    var groups: [EventGroup]
    var pruneBoundaries: [URL]

    var moveCount: Int { groups.reduce(0) { $0 + $1.moves.count } }
    var copyCount: Int { groups.reduce(0) { $0 + $1.copyFileCount } }
    /// Files Apply will relocate — every move plus every verified copy.
    var fileCount: Int { moveCount + copyCount }
    var byteCount: Int64 { groups.reduce(Int64(0)) { $0 + $1.byteCount } }
    var isEmpty: Bool { moveCount == 0 && copyCount == 0 }
    var duplicateCount: Int { groups.reduce(0) { $0 + $1.duplicates.count } }
    var conflictCount: Int { groups.reduce(0) { $0 + $1.nameConflictCount } }
    var hasCollisions: Bool { groups.contains { !$0.duplicates.isEmpty || !$0.conflicts.isEmpty } }
}

/// The plan behind the rename job an Apply kicked off, kept so the board can
/// show the same source → destination diagram while files are moving.
struct RunningApplyPlan: Sendable {
    var jobID: UUID
    var title: String
    var groups: [OrganizeApplyPlan.EventGroup]
}

struct DeviceChoice: Identifiable, Hashable {
    let id: String
    let name: String

    static let all: [DeviceChoice] = [
        DeviceChoice(id: "sony-a7v", name: "Sony A7V"),
        DeviceChoice(id: "osmo-360", name: "DJI Osmo 360"),
        DeviceChoice(id: "dji-nano", name: "DJI Nano"),
        DeviceChoice(id: "dji-mini-2", name: "DJI Mini 2"),
        DeviceChoice(id: "action-6", name: "DJI Action 6"),
        DeviceChoice(id: "iphone", name: "iPhone"),
        DeviceChoice(id: "generic-camera", name: "Other Camera"),
    ]

    static func name(for id: String?) -> String {
        all.first { $0.id == id }?.name ?? id ?? "Camera"
    }
}

struct AssignmentChange {
    var title: String
    var removed: [PhotoEventAssignment]
    var added: [PhotoEventAssignment]
    /// The NAS renames queued for this change (their batches carry this id as
    /// their move id), so undoing it brings the NAS copies back too.
    var nasLink: UUID?
    /// Where the events it touched kept their folders, recorded with `nasLink`
    /// so Undo can tell the NAS copies' paths are still the event's.
    var eventFolders: [String: String]?
}

/// `EventStorageLocations`' per-file path helpers with the per-event work
/// done once: `originalsRoot` and `layout` rebuild the event's folder chain
/// and format its dates on every call, which dominated planning a move —
/// one root per (event, camera, drive) and one layout per (event, camera)
/// answer every file after that with a string join.
private struct EventPathCache {
    let locations: EventStorageLocations
    private var roots: [String: URL] = [:]
    private var layouts: [String: OrganizedArchiveLayout] = [:]

    init(locations: EventStorageLocations) {
        self.locations = locations
    }

    private mutating func originalsRoot(_ event: SavedCameraEvent, _ deviceID: String?, _ policy: EventStoragePolicy) -> URL {
        let key = "\(event.id.uuidString)\u{0}\(deviceID ?? "")\u{0}\(policy.rawValue)"
        if let cached = roots[key] { return cached }
        let built = locations.originalsRoot(for: event, deviceID: deviceID, policy: policy)
        roots[key] = built
        return built
    }

    mutating func originalsRootPath(_ event: SavedCameraEvent, _ deviceID: String?, _ policy: EventStoragePolicy) -> String {
        originalsRoot(event, deviceID, policy).path
    }

    /// `EventStorageLocations.driveURL`, without the per-file root rebuild.
    mutating func driveURL(for assignment: PhotoEventAssignment, event: SavedCameraEvent, policy: EventStoragePolicy) -> URL? {
        guard (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else { return nil }
        return originalsRoot(event, assignment.deviceID, policy)
            .appendingPathComponent(assignment.relativePath, isDirectory: false)
            .standardizedFileURL
    }

    /// `EventStorageLocations.archiveURL`, without the per-file layout.
    mutating func archiveURL(for assignment: PhotoEventAssignment, event: SavedCameraEvent) -> URL? {
        let key = "\(event.id.uuidString)\u{0}\(assignment.deviceID ?? "")"
        let layout = layouts[key] ?? {
            let built = locations.layout(for: event, deviceID: assignment.deviceID)
            layouts[key] = built
            return built
        }()
        guard let relative = try? layout.mirrorRelativePath(for: assignment.relativePath) else { return nil }
        return locations.nasRoot.appendingPathComponent(relative, isDirectory: false).standardizedFileURL
    }
}

/// One clicked Move to Event, from the click until its rename settles.
private struct PendingEventMove {
    let id = UUID()
    /// The board the click came from. On a family board the files belong to
    /// its subevents, so `sourceIDs` — each item's own event — is what
    /// decides which boards lose the tiles, not this.
    var from: SavedCameraEvent
    var to: SavedCameraEvent
    var title: String
    var items: [EventMoveItem]
    /// The stacks as the source board showed them at the click.
    var stacks: [OrganizeStack]
    /// The events the files actually leave — the assignments' owners.
    var sourceIDs: Set<UUID>
    /// Each file that really moves (its board path key) and the event that
    /// owns it now: a board loses a file when that owner sits in the board's
    /// family and the target does not, and gains it the other way round.
    var movedOwners: [String: UUID]
    /// Titles of `sourceIDs`, for lines that name where a file stayed.
    var sourceTitles: [UUID: String]
    /// Boards the stacks left / joined, and boards whose running sweep the
    /// click dropped (they are re-checked when the move settles).
    var leftBoards: [UUID] = []
    var joinedBoards: [UUID] = []
    var interruptedBoards: [UUID] = []
    var overlayKeys: [String] = []
    /// Boards that only saw part of the change (their stacks are cut
    /// differently from the clicked board's) and are re-read after it lands.
    var truthBoards: [UUID] = []
    /// What the click left alone, added to the result line.
    var note = ""
    /// Another move was waiting or running when this one was clicked (or
    /// clicked after it): their optimistic tiles were laid over each other, so
    /// once it lands the boards are read again instead of patched.
    var overlapped = false
    var isRunning = false
    var isLanded = false

    init(
        from: SavedCameraEvent,
        to: SavedCameraEvent,
        title: String,
        items: [EventMoveItem],
        stacks: [OrganizeStack],
        sourceTitles: [UUID: String],
        ownerByKey: [String: UUID] = [:]
    ) {
        self.from = from
        self.to = to
        self.title = title
        self.items = items
        self.stacks = stacks
        self.sourceIDs = Set(items.map(\.removed.eventID))
        self.movedOwners = ownerByKey.filter { $0.value != to.id }
        self.sourceTitles = sourceTitles
    }
}

/// A moved file's NAS copy that the queued rename will bring to its new path.
struct PendingNASArrival {
    /// The presence row of the file at its new assignment.
    var assetID: String
    /// Where the NAS copy sits now (lowercased): the rename that brings it
    /// over must start there, or it is some other rename.
    var fromKey: String?
    /// The row's key in `eventAssetsByPathKey` (its drive path, lowercased).
    /// Nil for a file with no drive copy, whose row is keyed by its NAS path.
    var driveKey: String?
    /// When Sync to NAS last verified the copy at its old path — the rename
    /// carries the sync record along, so the copy stays verified.
    var verifiedAt: Date?
    /// Set when the NAS copy is the file's only copy (the Buffer is away):
    /// its tiles, rows and badge entries move to the new NAS path with it.
    var nasOnly: NASOnlyArrival?
}

/// What follows a NAS-only file when its queued rename runs.
struct NASOnlyArrival {
    var oldAssetID: String
    /// The tile's `pathKey` and the badge index's key at the old NAS path.
    var oldKey: String
    var oldPath: String
    var newPath: String
    var newKey: String
    /// The file's presence row at its new assignment and NAS path.
    var row: EventAssetPresence
    var targetEventID: UUID
}

/// A grid built from the catalog-implied `Originals/<Camera>` paths, before any
/// place has been probed. Pass one of an event open paints the first
/// screen of one of these; the deferred pass builds the whole event's.
private struct EventImpliedGrid: Sendable {
    var files: [OrganizeFile]
    var stacks: [OrganizeStack]
}

/// Pass two: the truthful four-place sweep plus everything that hangs off
/// it — the storage-strip summary, the badge index, and Immich statuses.
private struct EventRefreshOutput: Sendable {
    var summary: EventPresenceSummary
    /// One subtree-scoped summary per family member the sweep covered — a
    /// parent's pass scans every descendant too, so the sidebar chips and
    /// presence under it publish their own truthful scope in the same
    /// landing instead of waiting for each board to be opened.
    var memberSummaries: [UUID: EventPresenceSummary]
    var files: [OrganizeFile]
    var assetsByPathKey: [String: EventAssetPresence]
    var immich: [String: ImmichCatalogStatus]
}

/// The slice of `EventAssetPresence` a move or return needs, in a form the
/// app can also synthesize from the catalog alone when the presence sweep
/// has not landed yet — the scanner's own value type is read-only outside
/// `CameraToolkitCore`.
private struct MoveCandidate: Sendable {
    var assignment: PhotoEventAssignment
    var sourcePath: String?
    var drivePath: String?
    var otherDrivePath: String?
    var source: CatalogPresenceState
    var drive: CatalogPresenceState
    var otherDrive: CatalogPresenceState
    var sourceIsDriveCopy: Bool
    /// The NAS mirror copy, when the sweep found one.
    var archivePath: String?
    var archive: CatalogPresenceState = .missing
    var archiveIsLegacyLayout = false

    init(_ asset: EventAssetPresence) {
        assignment = asset.assignment
        sourcePath = asset.sourcePath
        drivePath = asset.drivePath
        otherDrivePath = asset.otherDrivePath
        source = asset.source
        drive = asset.drive
        otherDrive = asset.otherDrive
        sourceIsDriveCopy = asset.sourceIsDriveCopy
        archivePath = asset.archivePath
        archive = asset.archive
        archiveIsLegacyLayout = asset.archiveIsLegacyLayout
    }

    init(
        assignment: PhotoEventAssignment,
        sourcePath: String?,
        drivePath: String?,
        otherDrivePath: String?,
        source: CatalogPresenceState,
        drive: CatalogPresenceState,
        otherDrive: CatalogPresenceState,
        sourceIsDriveCopy: Bool
    ) {
        self.assignment = assignment
        self.sourcePath = sourcePath
        self.drivePath = drivePath
        self.otherDrivePath = otherDrivePath
        self.source = source
        self.drive = drive
        self.otherDrive = otherDrive
        self.sourceIsDriveCopy = sourceIsDriveCopy
    }
}

/// What a click's tiles resolved to: one candidate per catalog assignment,
/// and the names of files the catalog has no assignment for.
private struct MoveResolution {
    var candidates: [MoveCandidate] = []
    var unresolved: [String] = []
    /// The event whose assignment owns each resolved file, by board path key.
    var ownerByKey: [String: UUID] = [:]
}

private struct NASSyncJobOutcome: Sendable {
    var report: NASSyncReport
    var plan: NASSyncPlan
    var reportPath: String?
    /// Renames the sync applied before it copied: queued ones, NAS copies
    /// of files moved earlier, and stale duplicates set aside after.
    var follow = NASFollowResult()
    var queuedRenamesLeft = 0
}

private struct ImmichCandidate: Sendable {
    var id: String
    var path: String
    var size: Int64
    var modifiedAt: Date
    /// The owning event's album pick — a family board can span several.
    var albumName: String?
}

private struct BurstRegroupOutcome: Sendable {
    var stacks: [OrganizeStack]
    var links: Set<BurstVisualLink>
    var grouping: BurstGroupingConfiguration
}

private struct ImmichUploadOutcome: Sendable {
    var uploaded = 0
    var duplicates = 0
    var alreadyPresent = 0
    var albumName: String?
    var albumAdded = 0
}

private struct SourceCleanupGroup: Sendable {
    var sourceRoot: URL
    var driveRoot: URL
    var files: [FileRecord]
}

/// NSWorkspace notification tokens. Kept in a Sendable box so `deinit` can
/// unregister them; the workspace itself is main-actor bound.
private final class MountObserverBox: @unchecked Sendable {
    var observers: [NSObjectProtocol] = []
}

/// One `Originals/<Camera>` root per (member, device id) for the default implied-path
/// resolver — building the root spends a `DateFormatter` and an ancestor
/// walk per call, so the build runs once per key and only `relativePath`
/// joins per file.
private final class ImpliedOriginalsRoots: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [String: URL] = [:]

    func root(memberID: UUID, deviceID: String?, build: () -> URL) -> URL {
        let key = "\(memberID.uuidString)|\(deviceID ?? "")"
        return lock.withLock {
            if let cached = roots[key] {
                return cached
            }
            let built = build()
            roots[key] = built
            return built
        }
    }
}

/// Where a board draws a file before anything has been stat'ed: the drive
/// copy the catalog implies when that drive is mounted, else the NAS mirror
/// copy — whether or not the NAS is mounted right now. Both are string joins
/// over deterministic layouts.
final class ImpliedPaths: @unchecked Sendable {
    private let locations: EventStorageLocations
    private let members: [UUID: SavedCameraEvent]
    private let fallbackOwner: SavedCameraEvent
    private let custom: (@Sendable (PhotoEventAssignment) -> String?)?
    private let lock = NSLock()
    private var roots: [String: URL] = [:]
    private var layouts: [String: OrganizedArchiveLayout] = [:]

    init(
        locations: EventStorageLocations,
        members: [UUID: SavedCameraEvent],
        fallbackOwner: SavedCameraEvent,
        custom: (@Sendable (PhotoEventAssignment) -> String?)?
    ) {
        self.locations = locations
        self.members = members
        self.fallbackOwner = fallbackOwner
        self.custom = custom
    }

    /// The Buffer is a buffer — it is not always plugged in, and one day it
    /// is wiped — so the NAS mirror is the permanent library and the default
    /// home of every file. A member whose drive is mounted is drawn at its
    /// drive copy; otherwise (drive absent, NAS mounted or not) at the NAS
    /// mirror path, which is fixed by the layout and needs no stat to know.
    func path(for assignment: PhotoEventAssignment, driveUp: Bool) -> String? {
        // The test seam decides every path itself.
        if let custom { return custom(assignment) }
        guard (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else { return nil }
        let owner = members[assignment.eventID] ?? fallbackOwner
        let deviceKey = "\(owner.id.uuidString)|\(assignment.deviceID ?? "")"
        if driveUp {
            let root = lock.withLock { () -> URL in
                if let cached = roots[deviceKey] { return cached }
                let built = locations.originalsRoot(for: owner, deviceID: assignment.deviceID, policy: locations.resolvedPolicy(for: owner))
                roots[deviceKey] = built
                return built
            }
            return EventsWorkspace.resolvedPath(root: root, relativePath: assignment.relativePath)
        }
        let layout = lock.withLock { () -> OrganizedArchiveLayout in
            if let cached = layouts[deviceKey] { return cached }
            let built = locations.layout(for: owner, deviceID: assignment.deviceID)
            layouts[deviceKey] = built
            return built
        }
        guard let mirror = try? layout.mirrorRelativePath(for: assignment.relativePath) else { return nil }
        return EventsWorkspace.resolvedPath(root: locations.nasRoot, relativePath: mirror)
    }
}

/// Lets a cancelled pipeline cancel the utility sweep task it spawned, even
/// when the cancel lands before the task exists.
private final class SweepTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func set(_ task: Task<Void, Never>) {
        let cancelNow = lock.withLock { () -> Bool in
            self.task = task
            return cancelled
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}

/// State and actions for the event-first organizer: sorting unsorted folders
/// into events, moving events between the shared Buffer and private staging,
/// archiving to the NAS, freeing cards and drives, and sending to Immich.
@MainActor
@Observable
final class EventsWorkspace {
    let model: DashboardModel

    var selection: EventsSidebarSelection? {
        didSet {
            if oldValue != selection { selectionChanged() }
        }
    }
    var guide: SetupGuide?
    /// Bumped when keyboard focus should return to the open board's grid —
    /// Return in the toolbar search field. The grid re-focuses itself when
    /// it sees a new value.
    private(set) var boardFocusRequest = 0

    func requestBoardFocus() {
        boardFocusRequest &+= 1
    }
    var sources: [UUID: UnsortedSourceState] = [:] {
        didSet {
            // A rescan or removal on the open unsorted board re-points its
            // selection; progress ticks compare equal by buffer identity.
            guard case .unsorted(let id) = selection,
                  sources[id]?.result?.stacks != oldValue[id]?.result?.stacks else { return }
            resolveBoardSelection()
        }
    }
    /// The open board's selected stacks, resolved from `boardSelections`.
    /// Selection is remembered per board by file identity, so it survives
    /// switching boards and any restack that changes stack ids; writing
    /// here records the new choice for the open board.
    var selectedStackIDs: Set<String> = [] {
        didSet {
            guard !isApplyingBoardSelection else { return }
            recordSelectedKeys()
        }
    }
    var focusedStackID: String? {
        didSet {
            guard !isApplyingBoardSelection else { return }
            recordFocusKey()
        }
    }
    var presence: [UUID: EventPresenceSummary] = [:]
    var eventStacks: [UUID: [OrganizeStack]] = [:] {
        didSet { reindexEventStacks(from: oldValue) }
    }
    /// Files still resolving behind an event's first screen. While a
    /// count sits here the board's grid is real but partial — scrollable
    /// and openable — and a status line says the rest is still coming.
    var eventBuildRemainders: [UUID: Int] = [:]
    /// Events with a refresh in flight — the board shows placeholders, not a
    /// "not connected" verdict, while files it owns are still being found.
    var eventsLoading: Set<UUID> = []
    /// Cache-miss capture-date reads still running behind an event's
    /// provisional grid. The board is already complete — every resolved
    /// file is on it — and a status line says dates are still being read
    /// until the dated build lands.
    var eventDateReadRemainders: [UUID: Int] = [:]
    /// Per event, set only when some of its storage places are offline
    /// (not mounted, or mounted but not answering). When nothing the board
    /// could read is reachable (`isOffline`), the board shows a terminal
    /// "plug in the drive" state instead of a spinner; otherwise it loads
    /// what is reachable and names the rest.
    var eventReachability: [UUID: EventReachabilityReport] = [:]
    var eventImmichStatuses: [UUID: [String: ImmichCatalogStatus]] = [:]
    var discoveredDriveEvents: [DiscoveredDriveEvent] = []
    /// Per event board: which of its originals have edits under the
    /// family's `Edited/<Tag>` folders (`EditTagLinker`). Loaded off the
    /// main actor after the board's stacks land.
    var eventEditTags: [UUID: EditTagIndex] = [:]
    /// Camera folders on the Buffer and private staging still in the legacy
    /// `<device>/Card Copy` layout — offered for the layout migration.
    var legacyLayoutFolders: [DriveCameraFolder] = []
    var newEventRequest: NewEventRequest?
    var renameRequest: RenameEventRequest?
    var faceScanRequest: FaceScanRequest?
    var pendingApplyPlan: OrganizeApplyPlan?
    /// Per event: sorted files the last Apply plan found already in the
    /// event as byte-identical copies. Not pending — the event has them.
    var applyDuplicateSourceKeys: [UUID: Set<String>] = [:]
    /// Per event: sorted files whose event name is taken by another file.
    var applyConflictSourceKeys: [UUID: Set<String>] = [:]
    var pendingRemoval: RemovalRequest?
    var syncAllRequest: SyncAllToNASRequest?
    /// The Sync All sheet's "Reconcile NAS after moves" switch and the
    /// counts it shows (read from records, never from the NAS).
    var syncAllReconcile = true
    var reconcilePreview: NASReconcilePreview?
    /// NAS renames journaled and not applied yet — the NAS was away or a
    /// job held the gate. Kept in memory (recounted at launch and after
    /// each run) so a finished job need not read the journal folder.
    var pendingNASRenameCount = 0
    var pendingTrash: PendingTrashRequest?
    /// Bursts currently expanded inline in the board.
    var expandedStackIDs: Set<String> = []
    /// Board groups (day/folder/kind/event sections) the user collapsed.
    var collapsedGroupIDs: Set<String> = []
    /// The apply plan whose rename job is running — boards keep showing its
    /// source → destination diagram until the job finishes.
    var runningApply: RunningApplyPlan?
    /// Bumped by `refreshConnectivity()`. `isConnected` reads it so views that
    /// ask about connectivity re-render after a mount, unmount, or manual
    /// refresh.
    private(set) var connectivityRevision = 0
    /// Every undoable action in the order it finished — one list, so ⌘Z
    /// always takes back the newest and ⌘⇧Z puts it back. Recorded by the
    /// completions that finish an action (`recordUndo`), replayed by
    /// `undo()` / `redo()`, kept across a relaunch (`loadUndoHistory`).
    /// See `EventsWorkspace+Undo.swift`.
    var undoHistory = UndoHistory()
    /// Undo and Redo of changes whose inverse lives in memory only.
    @ObservationIgnored var undoSessionHandlers: [UUID: UndoSessionHandlers] = [:]
    /// The history file is read once per workspace, however often the window appears.
    @ObservationIgnored var undoHistoryLoaded = false
    /// Writes `undoHistory` to `undo-history.sqlite` off the main actor.
    @ObservationIgnored private(set) lazy var undoPersistence = UndoPersistence(
        store: UndoHistoryStore(url: supportFolder.appendingPathComponent(UndoHistoryStore.fileName))
    )

    @ObservationIgnored private var selectionAnchorID: String? {
        didSet {
            guard !isApplyingBoardSelection else { return }
            recordAnchorKey()
        }
    }
    /// What each board has selected, by file identity (`BoardSelectionState`).
    /// Kept for boards that are not open, so coming back finds the selection
    /// where it was left.
    @ObservationIgnored private(set) var boardSelections: [EventsSidebarSelection: BoardSelectionState] = [:]
    @ObservationIgnored private var isApplyingBoardSelection = false
    /// A plain click on a tile inside a multi-selection waits out the
    /// double-click interval before collapsing the selection to it — a
    /// second click means "open", not "select this one".
    @ObservationIgnored private var pendingSelectionCollapse: Task<Void, Never>?
    /// How long that wait is; a test shortens it.
    @ObservationIgnored var selectionCollapseDelay: TimeInterval = BoardClickPolicy.doubleClickInterval
    /// How many board reads (`refreshEvent`) have started — what a test
    /// compares to prove a move did not re-read the boards it patched.
    @ObservationIgnored private(set) var boardReadCount = 0
    /// How many times the assignment lookups were rebuilt from every
    /// assignment — ~750 ms on the main actor at 17,000 rows.
    @ObservationIgnored private(set) var assignmentIndexRebuildCount = 0
    /// The move's summary line, and what the status line said with its
    /// queued-NAS-renames sentence on it: when the NAS renames run right
    /// behind the move, the status line keeps the summary and adds theirs.
    @ObservationIgnored var lastMoveStatusLine: (base: String, full: String)?
    /// NAS copies that will sit at a moved file's new mirror path once their
    /// queued rename runs, by that path (lowercased) — what lets the finished
    /// rename patch the NAS column of just those rows instead of re-reading
    /// every open board.
    @ObservationIgnored var pendingNASArrivals: [String: PendingNASArrival] = [:]
    @ObservationIgnored private var indexRevision = -1
    @ObservationIgnored private var indexCount = -1
    @ObservationIgnored var assignmentsByPathKey: [String: PhotoEventAssignment] = [:]
    /// Clicked Move to Event batches that have not landed: tiles already
    /// moved in memory, rename running or queued behind another job.
    @ObservationIgnored private var pendingMoves: [PendingEventMove] = []
    /// A clicked move has not landed yet — the history is not final until it does.
    var hasPendingMoves: Bool { !pendingMoves.isEmpty }
    /// Boards touched by moves that were queued together. Each landing
    /// re-read them while the next move's tiles were still laid over them, so
    /// they are read once more when the queue is empty.
    @ObservationIgnored private var boardsToRecheck: Set<UUID> = []
    /// Moves landed so far — a click that waited for its board to load can
    /// tell whether another move landed in the meantime.
    @ObservationIgnored private var landedMoveCount = 0
    @ObservationIgnored private var assignmentsByEventAndName: [UUID: [String: PhotoEventAssignment]] = [:]
    /// Files whose Move to Event is clicked but not yet renamed, by their
    /// board path key → the event they are headed to. The catalog changes
    /// only when the rename lands (a crash between the two must never leave
    /// an assignment pointing at a folder the file is not in); until then
    /// the boards and counts read through this overlay.
    private(set) var moveOverlayRevision = 0
    @ObservationIgnored private var optimisticOwners: [String: UUID] = [:]
    @ObservationIgnored private var optimisticCounts: [UUID: Int] = [:]
    @ObservationIgnored private var optimisticBytes: [UUID: Int64] = [:]
    @ObservationIgnored private var assignmentCounts: [UUID: Int] = [:]
    @ObservationIgnored private var assignmentBytes: [UUID: Int64] = [:]
    @ObservationIgnored private var eventAssetsByPathKey: [UUID: [String: EventAssetPresence]] = [:] {
        didSet { eventAssetsRevision &+= 1 }
    }
    /// Bumped whenever a board's presence rows change. Tiles read it through
    /// `badge(for:in:)`, so a tile's "not on the drive" badge redraws with
    /// the rows and only the tiles on screen redraw.
    private(set) var eventAssetsRevision = 0
    @ObservationIgnored private var refreshGenerations: [UUID: UUID] = [:]
    /// The deferred refresh pipeline running per event — the remaining
    /// files' implied-path build, then the four-place presence sweep. A
    /// new refresh cancels the stale one so it never finishes against an
    /// old generation. Never awaited: `await task.value` would escalate
    /// it to the caller's priority, undoing the utility tier that keeps
    /// it off the UI path. The pipeline applies its own results and
    /// resolves `presenceWaiters`.
    @ObservationIgnored private var presenceTasks: [UUID: Task<Void, Never>] = [:]
    /// No move is queued or running, no job holds the gate, and no board is
    /// re-reading: the boards, counts and catalog are final.
    var isQuiet: Bool { pendingMoves.isEmpty && presenceTasks.isEmpty && refreshesInFlight == 0 && !model.isBusy }
    /// `refreshEvent` calls between their first line and their sweep landing.
    @ObservationIgnored private var refreshesInFlight = 0
    /// `refreshEvent` calls parked until their generation's sweep lands —
    /// (generation, continuation) pairs. A waiter whose generation went
    /// stale resumes as soon as any sweep finishes, instead of hanging on
    /// a pass that will never apply.
    @ObservationIgnored private var presenceWaiters: [UUID: [(UUID, CheckedContinuation<Void, Never>)]] = [:]
    /// Test seam: replaces the per-file presence stat inside the sweep —
    /// nil in production, where `EventPresenceScanner.state` does it. A
    /// test can park on the archive URL to prove the grid paints before
    /// the NAS answers.
    @ObservationIgnored var presenceProbe: EventPresenceScanner.PresenceProbe?
    /// Test seam: resolves one assignment's board path inside an event
    /// refresh — the first screen and the deferred build both go through
    /// it. Production joins the catalog-implied `Originals/<Camera>` path, pure
    /// string work that never touches the filesystem; a test counts
    /// which assignments resolved — or parks on one — to prove the first
    /// screen published before the rest of the files were resolved at
    /// all, let alone through `standardizedFileURL`.
    @ObservationIgnored var eventPathResolver: (@Sendable (PhotoEventAssignment) -> String?)?
    /// Test seam: replaces the capture-date header read inside the
    /// deferred build's dated pass — nil in production, where a cache
    /// miss reads through `CaptureDateReader.timestamp`. A test parks the
    /// first read to prove the provisional grid already published every
    /// implied file.
    @ObservationIgnored var captureDateReadProbe: (@Sendable (URL) -> CaptureTimestamp?)?
    /// Test seam: the mount table `refreshEvent` classifies places
    /// against — nil in production, where `VolumeInfo.mountedVolumePaths`
    /// reads the real one. Lets a test "mount" a `/Volumes/<name>` that
    /// does not exist without touching a real volume.
    @ObservationIgnored var mountedVolumesProvider: (@Sendable () -> Set<String>)?
    /// Test seam: the bounded existence stat of each place root — nil in
    /// production (`FileManager.fileExists`). A test parks it to stand in
    /// for a hung SMB share.
    @ObservationIgnored var placeResponseProbe: EventReachability.ResponseProbe?
    /// How long one place root may take to answer before the refresh
    /// treats its volume as not responding.
    @ObservationIgnored var placeResponseTimeout: TimeInterval = EventReachability.defaultTimeout
    @ObservationIgnored private var loadedCaptureDateCache: CaptureDateCache?
    @ObservationIgnored private var captureDateCacheLoaderStorage: CaptureDateCacheLoader?
    @ObservationIgnored private var lastConnectivityRefresh = Date.distantPast
    @ObservationIgnored private var connectivityRefreshTask: Task<Void, Never>?
    /// Standardized paths of volumes whose mount state changed during the
    /// pending debounce window; the coalesced refresh scopes itself to
    /// them and still rescans sources on the newly mounted ones.
    @ObservationIgnored private var pendingMountedVolumes: Set<URL> = []
    /// Mounted-volume set for `isConnected`, rebuilt once per connectivity
    /// revision instead of once per sidebar row.
    @ObservationIgnored private var mountedVolumesCache: (revision: Int, paths: Set<String>)?
    /// Folder path → reachable, per connectivity revision, for `isConnected`.
    @ObservationIgnored private var connectedPathsCache: (revision: Int, paths: [String: Bool])?
    /// The mounted-volume set as of the last connectivity refresh — the
    /// activation check diffs a fresh mount-table read against it so a
    /// wake where nothing mounted or unmounted does no work at all.
    @ObservationIgnored private var lastConnectivityMountedPaths: Set<String>?
    /// (catalogStateRevision, event → itself + descendants) — the scope a
    /// board, its sidebar count, its filters, and its people chips share.
    @ObservationIgnored private var eventScopeCache: (Int, [UUID: Set<UUID>])?
    /// Storage-location resolver reused within one configuration revision so
    /// event hierarchy lookups share its index.
    @ObservationIgnored private var locationsCache: (revision: Int, locations: EventStorageLocations)?
    /// `OrganizeStack.id` → stack per event board — rebuilt when the board
    /// writes `eventStacks`, so a context menu or key press resolves its
    /// targets by lookup instead of scanning every stack in the event.
    @ObservationIgnored private var eventStacksByID: [UUID: [String: OrganizeStack]] = [:]
    /// Event id → the `catalogStateRevision` its board's stacks reflect.
    /// A board stamped with the current revision is reused on a revisit —
    /// the refresh then only sweeps to verify — and a pipeline or sweep
    /// captured against an older revision must not overwrite a board a
    /// mutation already patched.
    /// Boards whose last full build could read capture dates. A grid built
    /// while its files' places were away has no dates to trust, so the next
    /// refresh rebuilds it instead of treating it as current.
    @ObservationIgnored private var eventDatesRead: Set<UUID> = []
    /// For a board built without dates, the connectivity revision it was
    /// built at: it stays current until a mount change might let a later
    /// build read them.
    @ObservationIgnored private var eventUnreadableAt: [UUID: Int] = [:]
    @ObservationIgnored private var eventGridRevisions: [UUID: Int] = [:]
    /// Event id → event index for title/policy lookups that must stay
    /// filesystem-free: `EventStorageLocations` standardizes the drive roots
    /// when it is built, so context menus and rows ask `EventHierarchy`
    /// through this index instead.
    @ObservationIgnored private var eventsByIDCache: (revision: Int, byID: [UUID: SavedCameraEvent])?
    @ObservationIgnored private let mountObservers = MountObserverBox()

    /// Holds move journals, the capture-time cache, and the duplicate
    /// review's hash cache.
    let supportFolder: URL

    /// The Duplicates window's scan and choices, shared with the event
    /// boards' "identical copies" notice. Observable on its own.
    @ObservationIgnored private(set) lazy var duplicateReview = DuplicateReviewModel(workspace: self)

    /// How the NAS share is connected (link, speed test, Wi-Fi guard).
    /// Inert until `startNASConnection()` — tests never mount or unmount.
    let nasConnection: NASConnectionModel

    /// Which event files are not on the NAS yet, kept current in the
    /// background. Inert until `startNASConnection()`, like the connection.
    let nasPresence = NASPresenceModel()

    /// Background disk work waits at this gate while a speed test is
    /// measuring the volume it would touch — scans, sweeps, capture-date
    /// reads, and tile decodes resume by themselves when the test ends.
    let driveActivityGate: DriveActivityGate

    init(
        model: DashboardModel,
        supportFolder: URL = EventsWorkspace.defaultSupportFolder,
        driveActivityGate: DriveActivityGate = .shared,
        nasConnection: NASConnectionModel = NASConnectionModel()
    ) {
        self.model = model
        self.supportFolder = supportFolder
        self.driveActivityGate = driveActivityGate
        self.nasConnection = nasConnection
        // A face-label restore from Settings rewrites face rows behind the
        // workspace; re-read people like after any other face change.
        let observer = NotificationCenter.default.addObserver(
            forName: .cameraToolkitFaceLabelsRestored,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.facesRevision &+= 1 }
        }
        faceLabelsRestoredObserver.observers = [observer]
        nasConnection.isNASInUse = { [weak self] in self?.nasIsInUse ?? true }
        nasPresence.context = { [weak self] in self?.nasPresenceContext }
        nasPresence.onReportChanged = { [weak self] old, new in self?.nasPresenceChanged(from: old, to: new) }
        // A job that only renames files on the drives never writes the
        // NAS, so it neither pauses a NAS listing nor triggers a new one.
        model.onJobStarted = { [weak self] action in
            guard action != .organize else { return }
            self?.nasPresence.pauseForJob()
        }
        model.onJobFinished = { [weak self] action in
            self?.nasPresence.jobFinished(action)
            self?.startPendingMoves()
            // Queued NAS renames run once the gate is free — never right
            // after a NAS rename job, so a stopped one is not restarted.
            if action != .nasRename { self?.drainNASRenames() }
        }
        model.onGateReleased = { [weak self] in
            self?.startPendingMoves()
            self?.drainNASRenames()
        }
    }

    @ObservationIgnored private let faceLabelsRestoredObserver = MountObserverBox()

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in mountObservers.observers {
            center.removeObserver(observer)
        }
        for observer in faceLabelsRestoredObserver.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Lookups

    static var defaultSupportFolder: URL {
        DashboardModel.defaultApplicationSupportURL.appendingPathComponent("CameraToolkit", isDirectory: true)
    }

    var journalFolder: URL {
        supportFolder.appendingPathComponent("Move Journals", isDirectory: true)
    }

    /// The capture-date cache, decoded on first use. A board's first screen
    /// asks for it from a background task (`captureDateCacheLoader`) so the
    /// JSON decode never runs on the main actor; this accessor serves the
    /// callers that already run there after a load.
    var captureDateCache: CaptureDateCache {
        if let loadedCaptureDateCache { return loadedCaptureDateCache }
        let cache = captureDateCacheLoader.cache()
        loadedCaptureDateCache = cache
        return cache
    }

    /// Thread-safe lazy loader for the capture-date cache.
    final class CaptureDateCacheLoader: @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var loaded: CaptureDateCache?

        init(url: URL) { self.url = url }

        func cache() -> CaptureDateCache {
            lock.lock()
            defer { lock.unlock() }
            if let loaded { return loaded }
            let cache = CaptureDateCache(url: url)
            loaded = cache
            return cache
        }
    }

    var captureDateCacheLoader: CaptureDateCacheLoader {
        if let cached = captureDateCacheLoaderStorage { return cached }
        let loader = CaptureDateCacheLoader(url: supportFolder.appendingPathComponent("capture-dates.json"))
        captureDateCacheLoaderStorage = loader
        return loader
    }

    var locations: EventStorageLocations {
        if let cached = locationsCache, cached.revision == model.configurationRevision {
            return cached.locations
        }
        let built = EventStorageLocations(configuration: model.configuration)
        locationsCache = (model.configurationRevision, built)
        return built
    }

    var unsortedLocations: [ConfiguredLocation] {
        model.configuration.locations(role: .importSource)
    }

    var events: [SavedCameraEvent] {
        model.savedEvents
    }

    /// Events flattened for the sidebar: parents newest-first, each followed
    /// by its subevents (depth drives the indent). Orphaned or looping parent
    /// links surface as top-level rows instead of disappearing.
    var sidebarEvents: [(event: SavedCameraEvent, depth: Int)] {
        EventHierarchy.flattened(model.configuration.savedEvents)
    }

    // MARK: - Search

    /// The board filter popover's shared state — unsorted boards, event
    /// boards, and the sidebar's Events list all evaluate the same
    /// condition rows; each board field also edits its text needle.
    var search = OrganizeSearchFilter()

    /// Sidebar rows matching the search query and the filter builder's
    /// condition rows — the same OR-of-AND-groups match the boards run,
    /// evaluated per event. Matching runs on each event's breadcrumb
    /// title, so a hit on a parent's name still reveals its subevents
    /// ("trip" shows TRIP2026 / Matcha), and on the named people detected
    /// in the event ("dad" keeps events where Dad was seen). Rows test
    /// `sidebarSubject(for:)`: People rows read the event's roster, Event
    /// rows its own id, Media rows its assigned files' kinds, Date rows
    /// its date. Empty query and no active rows returns all.
    func sidebarRows(
        matching query: String,
        applying filter: OrganizeSearchFilter = OrganizeSearchFilter()
    ) -> [(event: SavedCameraEvent, depth: Int)] {
        let needle = OrganizeSearch.needle(query)
        let filter = filter.droppingEditTagRows()
        guard !needle.isEmpty || filter.hasActiveConditions else { return sidebarEvents }
        return sidebarEvents.filter { row in
            let textHit = needle.isEmpty
                || OrganizeSearch.matches(eventTitle(row.event), needle: needle)
                || eventPeople(row.event.id).contains { OrganizeSearch.matches($0.name, needle: needle) }
            guard textHit else { return false }
            return OrganizeSearch.matches(
                subject: sidebarSubject(for: row.event, cameras: filter.needsCameras),
                search: filter
            )
        }
    }

    /// An event as filter-builder facts — the same subject a board builds
    /// per stack: its roster people (`event.people`, unnamed groups never
    /// count here), itself plus its ancestors so an Event row for a parent
    /// keeps the subevent's row too, the media kinds its assigned files
    /// carry, the cameras its assignments came from (when a Camera row
    /// asks), and its date as the capture span.
    private func sidebarSubject(for event: SavedCameraEvent, cameras: Bool = false) -> OrganizeFilterSubject {
        OrganizeFilterSubject(
            personIDs: Set(eventPeople(event.id).map(\.id)),
            eventIDs: ancestorScope(of: event),
            mediaKinds: eventMediaKinds(for: event.id),
            cameraIDs: cameras ? eventCameraIDs(for: event.id) : [],
            daySpan: event.eventDate...event.eventDate
        )
    }

    /// The event plus its ancestors — the id set an Event row matches
    /// against, so a parent filter keeps a stack sorted into a subevent
    /// and a subevent filter keeps its own descendants' stacks.
    private func ancestorScope(of event: SavedCameraEvent) -> Set<UUID> {
        Set(locations.ancestors(of: event).map(\.id) + [event.id])
    }

    /// The event plus every descendant — the family scope a board, its
    /// count, and its people chips cover. Cached per configuration
    /// revision so the sidebar's per-row counts share one walk.
    func scopeIDs(_ eventID: UUID) -> Set<UUID> {
        if let cache = eventScopeCache, cache.0 == model.catalogStateRevision {
            return cache.1[eventID] ?? [eventID]
        }
        let events = model.configuration.savedEvents
        var scopes: [UUID: Set<UUID>] = [:]
        for event in events {
            var ids: Set<UUID> = [event.id]
            ids.formUnion(EventHierarchy.descendants(of: event.id, in: events).map(\.id))
            scopes[event.id] = ids
        }
        eventScopeCache = (model.catalogStateRevision, scopes)
        return scopes[eventID] ?? [eventID]
    }

    /// The event plus its descendants in sidebar order — the family a
    /// board's Apply or storage actions cover.
    func eventFamily(_ eventID: UUID) -> [SavedCameraEvent] {
        guard let event = event(eventID) else { return [] }
        return [event] + EventHierarchy.descendants(of: eventID, in: model.configuration.savedEvents)
    }

    /// Unsorted sidebar locations matching the search query on name or path.
    func unsortedLocations(matching query: String) -> [ConfiguredLocation] {
        let needle = OrganizeSearch.needle(query)
        guard !needle.isEmpty else { return unsortedLocations }
        return unsortedLocations.filter { location in
            OrganizeSearch.matches(location.name, needle: needle)
                || OrganizeSearch.matches(location.path, needle: needle)
                || OrganizeSearch.matches(DashboardModel.expandedPath(location.path), needle: needle)
        }
    }

    /// Discovered drive events matching the search query on name, for the
    /// "Found on Your Drive" banner while it is showing.
    func discoveredDriveEvents(matching query: String) -> [DiscoveredDriveEvent] {
        let needle = OrganizeSearch.needle(query)
        guard !needle.isEmpty else { return discoveredDriveEvents }
        return discoveredDriveEvents.filter { OrganizeSearch.matches($0.name, needle: needle) }
    }

    /// The event id → event index backing `eventTitle`/`resolvedPolicy` —
    /// rebuilt once per configuration revision and shared by every caller in
    /// between, so titles never rebuild `locations` (a filesystem-touching
    /// resolver) inside a menu body or row render.
    private var eventsByID: [UUID: SavedCameraEvent] {
        if let cached = eventsByIDCache, cached.revision == model.catalogStateRevision {
            return cached.byID
        }
        let byID = EventHierarchy.index(model.configuration.savedEvents)
        eventsByIDCache = (model.catalogStateRevision, byID)
        return byID
    }

    /// "Parent / Child" title for menus, headers, and plan rows — pure
    /// in-memory: same answer as `locations.displayName`, without building
    /// `EventStorageLocations` (which standardizes the drive roots).
    func eventTitle(_ event: SavedCameraEvent) -> String {
        EventHierarchy.displayName(of: event, byID: eventsByID)
    }

    /// The event's effective storage policy, following parent inheritance —
    /// same answer as `locations.resolvedPolicy`, without touching the disk.
    func resolvedPolicy(for event: SavedCameraEvent) -> EventStoragePolicy {
        EventHierarchy.resolvedPolicy(of: event, byID: eventsByID)
    }

    /// Events that may parent `eventID` — every event except it and its own
    /// subevents, so the picker can never create a loop, and never deeper
    /// than the cap: a depth-2 event can't take another level. The event's
    /// current parent stays listed even then, so the picker can still show
    /// a grandfathered deeper link. Returned in flattened sidebar order
    /// for the parent picker's indented menu.
    func parentCandidates(excluding eventID: UUID?) -> [(event: SavedCameraEvent, depth: Int)] {
        let events = model.configuration.savedEvents
        let currentParentID = eventID.flatMap { event($0)?.parentEventID }
        return sidebarEvents.filter { row in
            guard row.event.id == currentParentID
                || EventHierarchy.canParent(row.event, in: events) else { return false }
            guard let eventID else { return true }
            return row.event.id != eventID
                && !EventHierarchy.ancestors(of: row.event, in: events).contains { $0.id == eventID }
        }
    }

    /// `candidate` when it can parent `eventID` — it exists, is not the
    /// event itself or one of its subevents, and sits below the depth cap.
    /// The parent an event already has always stays valid: an event deeper
    /// than the cap keeps its link instead of flattening on a rename —
    /// the cap only refuses new levels. Otherwise nil.
    func validParentEventID(_ candidate: UUID?, for eventID: UUID?) -> UUID? {
        guard let candidate,
              candidate != eventID,
              let parent = event(candidate) else { return nil }
        let events = model.configuration.savedEvents
        if let eventID {
            if event(eventID)?.parentEventID == candidate { return candidate }
            if EventHierarchy.ancestors(of: parent, in: events).contains(where: { $0.id == eventID }) {
                return nil
            }
        }
        guard EventHierarchy.canParent(parent, in: events) else { return nil }
        return candidate
    }

    /// Why a new subevent under `candidate` is refused, or nil when it is
    /// allowed — the status sentence the refusal reports.
    private func subeventRefusal(for candidate: UUID) -> String? {
        guard let parent = event(candidate) else { return "That event no longer exists." }
        guard EventHierarchy.canParent(parent, in: model.configuration.savedEvents) else {
            return "\(eventTitle(parent)) is already at the deepest level — a subevent can only go two levels under a top-level event."
        }
        return nil
    }

    /// The events behind the 1–3 chips and the picker's Recent section: up
    /// to three events, most recently assigned to or created first.
    /// Positions stay put for the session — reusing a listed event keeps
    /// its number, so a digit key never jumps to a different event
    /// mid-sort. Until three distinct events are used this session the
    /// list fills from `lastUsedAt` order.
    var recentEvents: [SavedCameraEvent] {
        let all = model.configuration.savedEvents
        var ids = sessionRecentIDs.filter { id in all.contains { $0.id == id } }
        if ids.count < Self.recentLimit {
            for event in all.sorted(by: Self.recentOrder) where !ids.contains(event.id) {
                ids.append(event.id)
                if ids.count == Self.recentLimit { break }
            }
        }
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    /// `recentEvents` minus a non-target — an event board's own event can't
    /// receive its stacks, so its overlay drops it from chips and keys.
    func assignableRecents(excluding excludedID: UUID? = nil) -> [SavedCameraEvent] {
        recentEvents.filter { $0.id != excludedID }
    }

    /// The "Event…" picker's sections: matching recents pinned on top,
    /// then every other query match in sidebar order. `excludedID` drops a
    /// non-target (the board's own event when moving between events).
    func eventPickerSections(
        matching query: String,
        excluding excludedID: UUID? = nil
    ) -> (recent: [SavedCameraEvent], other: [(event: SavedCameraEvent, depth: Int)]) {
        let rows = sidebarRows(matching: query).filter { $0.event.id != excludedID }
        let matchingIDs = Set(rows.map(\.event.id))
        let recent = recentEvents.filter { $0.id != excludedID && matchingIDs.contains($0.id) }
        let recentIDs = Set(recent.map(\.id))
        return (recent, rows.filter { !recentIDs.contains($0.event.id) })
    }

    static let recentLimit = 3
    /// Session ordering for `recentEvents` — the visible list as the user
    /// last saw it, so positions only shift when a new event enters.
    private var sessionRecentIDs: [UUID] = []

    /// Records `eventID` as a recent target when stacks are assigned or
    /// moved to it or it is created. An event already listed keeps its
    /// slot — digit keys stay stable — while a new one enters at the front
    /// and drops the tail.
    private func noteRecent(_ eventID: UUID) {
        var ids = recentEvents.map(\.id)
        if !ids.contains(eventID) {
            ids.insert(eventID, at: 0)
            ids = Array(ids.prefix(Self.recentLimit))
        }
        sessionRecentIDs = ids
    }

    private static func recentOrder(_ a: SavedCameraEvent, _ b: SavedCameraEvent) -> Bool {
        if a.lastUsedAt != b.lastUsedAt { return a.lastUsedAt > b.lastUsedAt }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.name < b.name
    }

    func event(_ id: UUID) -> SavedCameraEvent? {
        model.configuration.savedEvents.first { $0.id == id }
    }

    func location(_ id: UUID) -> ConfiguredLocation? {
        model.configuration.configuredLocations.first { $0.id == id }
    }

    func deviceID(for location: ConfiguredLocation) -> String {
        location.deviceID ?? DashboardModel.inferredDeviceID(for: location) ?? model.configuration.selectedDeviceID
    }

    func isConnected(_ location: ConfiguredLocation) -> Bool {
        isConnected(folder: URL(fileURLWithPath: DashboardModel.expandedPath(location.path), isDirectory: true))
    }

    /// Whether a folder is reachable — sidebar rows, the NAS button, the
    /// guide, and the follow-up jobs that check before they start. A folder
    /// on an external or network volume (`/Volumes/<name>`) is never stat'ed
    /// from the main actor, where a stale mount can park the window: it
    /// answers no at once when the volume is not in the mount table, and
    /// otherwise from its last verified state, or "connected" until its
    /// existence check (run on a background queue) reports back and the
    /// views re-draw. A folder on the startup disk cannot hang, so it is
    /// answered truthfully on the spot.
    func isConnected(folder url: URL) -> Bool {
        // Tracked reads: views that call this re-evaluate when
        // `refreshConnectivity()` bumps `connectivityRevision` and when a
        // background check lands.
        _ = connectivityRevision
        _ = connectivityVerificationRevision
        if let connected = verifiedConnectivity(of: url.path) { return connected }
        guard VolumeInfo.isAvailable(url, mountedVolumes: mountedVolumePaths()) else {
            recordConnectivity(false, for: url.path)
            return false
        }
        if VolumeInfo.volumeRoot(for: url) == nil {
            let exists = connectivityProbe?(url.path) ?? FileManager.default.fileExists(atPath: url.path)
            recordConnectivity(exists, for: url.path)
            return exists
        }
        verifyConnectivityInBackground(url.path)
        return true
    }

    /// The truthful answer for an action that has to know before it goes on
    /// — a scan, a retry. Uses the verified state when there is one and
    /// otherwise asks the filesystem, so it belongs behind a user's click,
    /// never in a view body.
    func isConnectedNow(_ location: ConfiguredLocation) -> Bool {
        let url = URL(fileURLWithPath: DashboardModel.expandedPath(location.path), isDirectory: true)
        if let connected = verifiedConnectivity(of: url.path) { return connected }
        let exists = VolumeInfo.isAvailable(url, mountedVolumes: mountedVolumePaths())
            && (connectivityProbe?(url.path) ?? FileManager.default.fileExists(atPath: url.path))
        recordConnectivity(exists, for: url.path)
        return exists
    }

    /// Seam for tests: answers "does this folder exist?" instead of the
    /// filesystem, from whichever thread asks.
    @ObservationIgnored var connectivityProbe: (@Sendable (String) -> Bool)?
    /// Bumped when a background existence check lands, so the views that
    /// asked `isConnected` re-draw with the verified answer.
    private(set) var connectivityVerificationRevision = 0
    @ObservationIgnored private var pendingConnectivityChecks: Set<String> = []

    private func verifiedConnectivity(of path: String) -> Bool? {
        guard let cached = connectedPathsCache, cached.revision == connectivityRevision else { return nil }
        return cached.paths[path]
    }

    private func recordConnectivity(_ connected: Bool, for path: String) {
        var paths = connectedPathsCache?.revision == connectivityRevision ? connectedPathsCache?.paths ?? [:] : [:]
        paths[path] = connected
        connectedPathsCache = (connectivityRevision, paths)
    }

    private func verifyConnectivityInBackground(_ path: String) {
        guard pendingConnectivityChecks.insert(path).inserted else { return }
        let revision = connectivityRevision
        let probe = connectivityProbe
        Task.detached(priority: .userInitiated) { [weak self] in
            let exists = probe?(path) ?? FileManager.default.fileExists(atPath: path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                pendingConnectivityChecks.remove(path)
                // A newer revision throws this answer away; the views that
                // draw again ask afresh.
                guard revision == connectivityRevision else {
                    connectivityVerificationRevision &+= 1
                    return
                }
                recordConnectivity(exists, for: path)
                connectivityVerificationRevision &+= 1
            }
        }
    }

    /// The mounted volume set, read once per connectivity revision instead of
    /// once per `isConnected` call in a sidebar render.
    private func mountedVolumePaths() -> Set<String> {
        if let cached = mountedVolumesCache, cached.revision == connectivityRevision {
            return cached.paths
        }
        let paths = mountedVolumesProvider?() ?? VolumeInfo.mountedVolumePaths()
        mountedVolumesCache = (connectivityRevision, paths)
        return paths
    }

    nonisolated static func sourceKey(_ assignment: PhotoEventAssignment) -> String {
        EventStorageLocations.pathKey(
            (NSString(string: assignment.sourceRootPath).expandingTildeInPath as NSString).appendingPathComponent(assignment.relativePath)
        )
    }

    /// Every place one assignment's file can be drawn from, as path keys:
    /// its own source path first, then the implied `Originals/<Camera>`
    /// (or legacy `Card Copy`) copies on either drive and the NAS mirror
    /// and legacy archive copies. `pathKey` walks the filesystem — realpath
    /// stats every component, and a NAS path answers in milliseconds — but
    /// every root joined here was standardized once already (the drive and
    /// staging roots at `EventStorageLocations.init`, the source roots
    /// below), so for a clean relative path the key is a string join plus a
    /// lowercase; only a rare unclean one pays for realpath. One root per
    /// event and camera — building it per file redoes the date formatting
    /// 13,000 times.
    private struct AssignmentKeyBuilder {
        let locations: EventStorageLocations
        var sourceRoots: [String: String] = [:]
        var cardRoots: [String: String] = [:]
        var archiveLayouts: [String: OrganizedArchiveLayout] = [:]

        init(locations: EventStorageLocations) {
            self.locations = locations
        }

        mutating func sourceKey(for assignment: PhotoEventAssignment) -> String {
            let rootPath: String
            if let cached = sourceRoots[assignment.sourceRootPath] {
                rootPath = cached
            } else {
                rootPath = URL(fileURLWithPath: NSString(string: assignment.sourceRootPath).expandingTildeInPath, isDirectory: true)
                    .standardizedFileURL.path
                sourceRoots[assignment.sourceRootPath] = rootPath
            }
            return EventStorageLocations.joinedPathKey(rootPath: rootPath, relativePath: assignment.relativePath)
                ?? EventStorageLocations.pathKey(rootPath + "/" + assignment.relativePath)
        }

        /// The copies the board's tiles point at instead of the import
        /// path. Empty when the owner is unknown or the path is unsafe.
        mutating func impliedKeys(for assignment: PhotoEventAssignment, owner: SavedCameraEvent?) -> [String] {
            guard let owner, (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else { return [] }
            var keys: [String] = []
            func add(_ root: String, _ relative: String) {
                keys.append(
                    EventStorageLocations.joinedPathKey(rootPath: root, relativePath: relative)
                        ?? EventStorageLocations.pathKey(root + "/" + relative)
                )
            }
            for policy in [EventStoragePolicy.buffer, .archiveOnly] {
                for legacy in [false, true] {
                    let cacheKey = "\(owner.id.uuidString)\u{0}\(assignment.deviceID ?? "")\u{0}\(policy.rawValue)\u{0}\(legacy)"
                    let rootPath = cardRoots[cacheKey] ?? {
                        let built = (legacy
                            ? locations.legacyCardCopyRoot(for: owner, deviceID: assignment.deviceID, policy: policy)
                            : locations.originalsRoot(for: owner, deviceID: assignment.deviceID, policy: policy)).path
                        cardRoots[cacheKey] = built
                        return built
                    }()
                    add(rootPath, assignment.relativePath)
                }
            }
            let layoutKey = "\(owner.id.uuidString)\u{0}\(assignment.deviceID ?? "")"
            let layout = archiveLayouts[layoutKey] ?? {
                let built = locations.layout(for: owner, deviceID: assignment.deviceID)
                archiveLayouts[layoutKey] = built
                return built
            }()
            // The NAS mirror copy, and the legacy archive copy an event
            // archived before the mirror layout still has.
            if let relative = try? layout.mirrorRelativePath(for: assignment.relativePath) {
                add(locations.nasRoot.path, relative)
            }
            if let relative = try? layout.legacyArchiveRelativePath(for: assignment.relativePath) {
                add(locations.libraryRoot.path, relative)
            }
            return keys
        }
    }

    func refreshIndexIfNeeded() {
        let assignments = model.configuration.photoEventAssignments
        guard indexRevision != model.assignmentIndexRevision || indexCount != assignments.count else { return }
        assignmentIndexRebuildCount += 1
        var index: [String: PhotoEventAssignment] = [:]
        index.reserveCapacity(assignments.count * 2)
        var counts: [UUID: Int] = [:]
        var bytes: [UUID: Int64] = [:]
        var builder = AssignmentKeyBuilder(locations: locations)
        func insert(_ key: String, _ assignment: PhotoEventAssignment) {
            guard index[key] == nil else { return }
            index[key] = assignment
        }
        for assignment in assignments {
            autoreleasepool {
                insert(builder.sourceKey(for: assignment), assignment)
                counts[assignment.eventID, default: 0] += 1
                bytes[assignment.eventID, default: 0] += assignment.fileSize
            }
        }
        // The board's tiles point at Originals/<Camera> (or the other drive,
        // a not-yet-migrated legacy Card Copy, or the NAS), not at the path
        // the file was imported from. Index those too, without letting them
        // steal a source path that already belongs to a different
        // assignment.
        let eventsByID = self.eventsByID
        for assignment in assignments {
            autoreleasepool {
                for key in builder.impliedKeys(for: assignment, owner: eventsByID[assignment.eventID]) {
                    insert(key, assignment)
                }
            }
        }
        assignmentsByPathKey = index
        assignmentCounts = counts
        assignmentBytes = bytes
        assignmentsByEventAndName = [:]
        indexRevision = model.assignmentIndexRevision
        indexCount = assignments.count
    }

    /// Whether the lookup indexes match the catalog right now — read
    /// before a catalog change so `patchAssignmentIndex` knows it may patch.
    private var assignmentIndexIsCurrent: Bool {
        indexRevision == model.assignmentIndexRevision && indexCount == model.configuration.photoEventAssignments.count
    }

    /// Brings the lookup indexes in step with a catalog change that just
    /// landed, touching only the rows that changed instead of rebuilding
    /// ~17,000 assignments' worth of keys. `wasCurrent` is whether the
    /// indexes matched the catalog right before the change; when they did
    /// not, the next read rebuilds as it always did. A key another
    /// assignment shadowed comes back on the next full rebuild, not here.
    private func patchAssignmentIndex(removed: [PhotoEventAssignment], added: [PhotoEventAssignment], wasCurrent: Bool) {
        guard wasCurrent else { return }
        var builder = AssignmentKeyBuilder(locations: locations)
        let eventsByID = self.eventsByID
        let removedIDs = Set(removed.map(CatalogStore.eventAssetID))
        for assignment in removed {
            let keys = [builder.sourceKey(for: assignment)] + builder.impliedKeys(for: assignment, owner: eventsByID[assignment.eventID])
            for key in keys {
                if let owner = assignmentsByPathKey[key], removedIDs.contains(CatalogStore.eventAssetID(owner)) {
                    assignmentsByPathKey[key] = nil
                }
            }
            assignmentCounts[assignment.eventID, default: 0] -= 1
            assignmentBytes[assignment.eventID, default: 0] -= assignment.fileSize
            let name = Self.nameKey(assignment.relativePath)
            if let named = assignmentsByEventAndName[assignment.eventID]?[name],
               removedIDs.contains(CatalogStore.eventAssetID(named)) {
                assignmentsByEventAndName[assignment.eventID]?[name] = nil
            }
        }
        for assignment in added {
            let source = builder.sourceKey(for: assignment)
            if assignmentsByPathKey[source] == nil { assignmentsByPathKey[source] = assignment }
            for key in builder.impliedKeys(for: assignment, owner: eventsByID[assignment.eventID]) where assignmentsByPathKey[key] == nil {
                assignmentsByPathKey[key] = assignment
            }
            assignmentCounts[assignment.eventID, default: 0] += 1
            assignmentBytes[assignment.eventID, default: 0] += assignment.fileSize
            let name = Self.nameKey(assignment.relativePath)
            if assignmentsByEventAndName[assignment.eventID] != nil, assignmentsByEventAndName[assignment.eventID]?[name] == nil {
                assignmentsByEventAndName[assignment.eventID]?[name] = assignment
            }
        }
        indexRevision = model.assignmentIndexRevision
        indexCount = model.configuration.photoEventAssignments.count
    }

    /// One event's assignments by lowercased relative path — what a move
    /// checks a destination name against. Built the first time an event is
    /// asked about (one pass) and kept in step by `patchAssignmentIndex`,
    /// so a move no longer scans every assignment in the library.
    func assignmentsByName(inEvent eventID: UUID) -> [String: PhotoEventAssignment] {
        refreshIndexIfNeeded()
        if let cached = assignmentsByEventAndName[eventID] { return cached }
        var names: [String: PhotoEventAssignment] = [:]
        for assignment in model.configuration.photoEventAssignments where assignment.eventID == eventID {
            let name = Self.nameKey(assignment.relativePath)
            if names[name] == nil { names[name] = assignment }
        }
        assignmentsByEventAndName[eventID] = names
        return names
    }

    func assignment(for file: OrganizeFile) -> PhotoEventAssignment? {
        refreshIndexIfNeeded()
        _ = moveOverlayRevision
        guard var assignment = assignmentsByPathKey[file.pathKey],
              assignment.fileSize == file.size else { return nil }
        // A tile that already left for another event while its rename runs
        // answers as that event's, so its color dot and menus agree with
        // the board it is drawn on.
        if let owner = optimisticOwners[file.pathKey] { assignment.eventID = owner }
        return assignment
    }

    /// Files in the event's family — itself plus every descendant. A
    /// parent's count covers its subevents; a subevent never counts the
    /// parent's files.
    func assignmentCount(for eventID: UUID) -> Int {
        refreshIndexIfNeeded()
        _ = moveOverlayRevision
        return scopeIDs(eventID).reduce(0) { $0 + (assignmentCounts[$1] ?? 0) + (optimisticCounts[$1] ?? 0) }
    }

    func assignmentBytes(for eventID: UUID) -> Int64 {
        refreshIndexIfNeeded()
        _ = moveOverlayRevision
        return scopeIDs(eventID).reduce(Int64(0)) { $0 + (assignmentBytes[$1] ?? 0) + (optimisticBytes[$1] ?? 0) }
    }

    func assignedEvent(for stack: OrganizeStack) -> (event: SavedCameraEvent?, mixed: Bool) {
        var ids: Set<UUID> = []
        var unassigned = false
        for item in stack.items {
            if let assignment = assignment(for: item.primary) {
                ids.insert(assignment.eventID)
            } else {
                unassigned = true
            }
        }
        guard ids.count == 1, let id = ids.first else {
            return (nil, ids.count > 1)
        }
        return (event(id), unassigned)
    }

    func isSorted(_ stack: OrganizeStack) -> Bool {
        stack.items.allSatisfy { assignment(for: $0.primary) != nil }
    }

    /// The stacks a board should show: `hideSorted` drops fully assigned
    /// stacks and a non-empty `search` keeps only stacks matching the text
    /// needle — file name, burst label, origin subfolder, assigned event
    /// title, or the name of a person or group whose face sits on one of
    /// the stack's files — and the builder's OR-of-AND condition groups.
    func visibleStacks(
        _ result: OrganizeScanResult,
        hideSorted: Bool,
        search: OrganizeSearchFilter = OrganizeSearchFilter()
    ) -> [OrganizeStack] {
        guard hideSorted || !search.isEmpty else { return result.stacks }
        let people: BoardPeople = search.needsPeople ? boardPeople(for: result.stacks) : ([], [:], [])
        let cameras = search.needsCameras
        return result.stacks.filter { stack in
            if hideSorted, isSorted(stack) { return false }
            guard !search.isEmpty else { return true }
            return OrganizeSearch.matches(
                stack: stack,
                search: search,
                rootPath: result.rootPath,
                facts: stackFacts(stack, people: people, cameras: cameras)
            )
        }
    }

    /// Text-only form of `visibleStacks(_:hideSorted:search:)`.
    func visibleStacks(_ result: OrganizeScanResult, hideSorted: Bool, matching query: String) -> [OrganizeStack] {
        visibleStacks(result, hideSorted: hideSorted, search: OrganizeSearchFilter(text: query))
    }

    /// The stacks an event board should show under the same search state.
    /// Event rows apply scoped to the board's family — the event plus its
    /// subevents — so an "is none of" pick on a subevent hides that branch
    /// while picks carried over from another board's panel narrow to
    /// nothing rather than emptying this one.
    func visibleEventStacks(_ eventID: UUID, search: OrganizeSearchFilter) -> [OrganizeStack] {
        let stacks = eventStacks[eventID] ?? []
        let scoped = search.scopingEventRows(to: scopeIDs(eventID))
        guard !scoped.isEmpty else { return stacks }
        let people: BoardPeople = scoped.needsPeople ? boardPeople(for: stacks) : ([], [:], [])
        let cameras = scoped.needsCameras
        let edits = scoped.needsEditTags
        return stacks.filter {
            var facts = stackFacts($0, people: people, cameras: cameras)
            if edits { facts.editTags = editTags(for: $0, in: eventID) }
            return OrganizeSearch.matches(
                stack: $0,
                search: scoped,
                rootPath: nil,
                facts: facts
            )
        }
    }

    /// The event's direct subevents, in sidebar sibling order — the header
    /// chips and the board's subevent sections share this list.
    func subevents(of eventID: UUID) -> [SavedCameraEvent] {
        EventHierarchy.children(of: eventID, in: model.configuration.savedEvents)
    }

    /// The color dot a stack wears. Any photo that belongs to a subevent
    /// keeps that subevent's color, including on the subevent's own board.
    /// A photo owned by the open event, when that event is top-level, has
    /// no dot. A grandchild wears its own color, not its parent's.
    func subeventTag(for stack: OrganizeStack, in eventID: UUID) -> SavedCameraEvent? {
        guard let owner = assignedEvent(for: stack).event,
              owner.parentEventID != nil,
              scopeIDs(eventID).contains(owner.id) else { return nil }
        return owner
    }

    /// The same day or kind sections as any other board. Subevent photos
    /// stay in those sections; the dot on the tile says which tag they
    /// belong to, instead of pulling them into a folder named after the tag.
    ///
    /// Grouping and sorting a 15,000-stack board costs tens of milliseconds
    /// and every board body evaluation asks for it, so the answer is kept per
    /// board and reused while the stacks (compared by buffer identity first),
    /// the grouping, the sort and the data cameras are named from are the
    /// same. Coming back to a board that is already loaded finds it ready.
    func eventBoardGroups(
        _ eventID: UUID,
        stacks: [OrganizeStack],
        grouping: OrganizeBoardGrouping,
        sort: OrganizeStackSort
    ) -> [OrganizeBoardGroup] {
        // Only the Camera sort reads the data cameras are named from; any
        // other board order is the same across a catalog or configuration
        // change (a move's landing bumps both), so it is kept.
        let catalog = sort.key == .camera ? model.catalogStateRevision : 0
        let configuration = sort.key == .camera ? model.configurationRevision : 0
        if let entry = eventBoardGroupsCache[eventID],
           entry.catalog == catalog, entry.configuration == configuration,
           entry.grouping == grouping, entry.sort == sort, entry.stacks == stacks {
            return entry.groups
        }
        let groups = OrganizeBoardPlan.groups(
            for: stacks,
            grouping: grouping,
            sort: sort,
            cameraName: { self.primaryCamera(for: $0)?.name }
        )
        eventBoardGroupsCache[eventID] = (catalog, configuration, grouping, sort, stacks, groups)
        return groups
    }

    @ObservationIgnored private var eventBoardGroupsCache: [UUID: (
        catalog: Int, configuration: Int,
        grouping: OrganizeBoardGrouping, sort: OrganizeStackSort,
        stacks: [OrganizeStack], groups: [OrganizeBoardGroup]
    )] = [:]

    /// The stacks an event board shows after its search field filters —
    /// the same match rules as the unsorted board, minus the origin
    /// subfolder (an event's files can sit under several roots).
    func visibleEventStacks(_ eventID: UUID, matching query: String) -> [OrganizeStack] {
        let stacks = eventStacks[eventID] ?? []
        let needle = OrganizeSearch.needle(query)
        guard !needle.isEmpty else { return stacks }
        let title = event(eventID).map { eventTitle($0) }
        return stacks.filter {
            OrganizeSearch.matches(
                stack: $0,
                needle: needle,
                rootPath: nil,
                eventTitle: title,
                personNames: personNames(on: $0)
            )
        }
    }

    /// Facts one stack needs for structured search — every event its items
    /// are assigned to plus those events' ancestors, so an Event row for a
    /// parent keeps a stack sorted into its subevent (the reverse — a
    /// subevent row against the parent's stack — does not match) — plus
    /// the face-catalog people on its files, and whether anyone else's
    /// face is on them too. `eventTitle` stays the text needle's
    /// single-event breadcrumb match. `cameras` resolves the frames'
    /// cameras too — only when a Camera row is filtering.
    private func stackFacts(_ stack: OrganizeStack, people: BoardPeople, cameras: Bool = false) -> OrganizeStackFacts {
        var assignedIDs = Set<UUID>()
        var eventIDs = Set<UUID>()
        for item in stack.items {
            if let assignment = assignment(for: item.primary) {
                assignedIDs.insert(assignment.eventID)
                if let owner = event(assignment.eventID) {
                    eventIDs.formUnion(ancestorScope(of: owner))
                }
            }
        }
        return OrganizeStackFacts(
            eventIDs: eventIDs,
            eventTitle: assignedIDs.count == 1
                ? assignedIDs.first.flatMap { event($0) }.map { eventTitle($0) }
                : nil,
            personIDs: people.byStackID[stack.id] ?? [],
            hasOtherFaces: people.othersStackIDs.contains(stack.id),
            personNames: personNames(on: stack),
            cameraIDs: cameras ? cameraIDs(for: stack) : []
        )
    }

    // MARK: - Edit tags

    /// Edit tags on a stack's frames on `eventID`'s board — the union a
    /// burst is judged on, like the other filter facts.
    func editTags(for stack: OrganizeStack, in eventID: UUID) -> Set<String> {
        guard let index = eventEditTags[eventID], !index.tagsByItemID.isEmpty else { return [] }
        var tags = Set<String>()
        for item in stack.items { tags.formUnion(index.tags(forItemID: item.id)) }
        return tags
    }

    /// The tile badge's tags, sorted.
    func editTagList(for stack: OrganizeStack, in eventID: UUID) -> [String] {
        editTags(for: stack, in: eventID).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Tags on a board's stacks with how many stacks carry each — the
    /// Edit tag row's options. `scope` is the board's event family; an
    /// unsorted board (nil) has no edits to offer.
    func boardEditTags(for stacks: [OrganizeStack], scope: Set<UUID>?) -> [(tag: String, stackCount: Int)] {
        guard let scope else { return [] }
        let indexes = scope.compactMap { eventEditTags[$0] }
        guard !indexes.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for stack in stacks {
            var tags = Set<String>()
            for index in indexes {
                for item in stack.items { tags.formUnion(index.tags(forItemID: item.id)) }
            }
            for tag in tags { counts[tag, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted {
            $0.stackCount != $1.stackCount ? $0.stackCount > $1.stackCount : $0.tag.localizedStandardCompare($1.tag) == .orderedAscending
        }
    }

    /// Reads the family's `Edited/` folders (both drives) and links each
    /// edit to the board's originals — by file-name stem, else by capture
    /// time and camera. Off the main actor; publishes only while the
    /// board still shows the same stacks.
    func refreshEditTags(for eventID: UUID) {
        guard let event = event(eventID), let stacks = eventStacks[eventID] else { return }
        let locations = self.locations
        let members = scopeIDs(eventID).compactMap { self.event($0) } + [event]
        var folders: [URL] = []
        for member in members {
            for policy in EventStoragePolicy.allCases {
                let folder = locations.eventFolder(for: member, policy: policy)
                if VolumeInfo.isAvailable(folder) { folders.append(folder) }
            }
        }
        let candidates = stacks.flatMap(\.items).map { item in
            EditTagCandidate(
                itemID: item.id,
                fileNames: [item.primary.name] + item.companions.map(\.name),
                captureDate: item.hasCameraDate ? item.captureDate : nil,
                cameraID: camera(for: item)?.id
            )
        }
        let gate = driveActivityGate
        let roots = folders
        Task { @MainActor [weak self] in
            let index = await Task.detached(priority: .utility) { () -> EditTagIndex? in
                let folders = roots
                guard folders.allSatisfy({ gate.waitIfPaused(for: $0, shouldStop: { Task.isCancelled }) }) else { return nil }
                let edits = EditTagLinker.editedFiles(eventFolders: folders)
                guard !edits.isEmpty else { return EditTagIndex() }
                return EditTagLinker.link(edits: edits, candidates: candidates) { edit in
                    let metadata = CaptureDateReader.metadata(of: URL(fileURLWithPath: edit.path))
                    return (metadata.timestamp?.date, CameraCatalog.camera(metadata: metadata.camera)?.id)
                }
            }.value
            guard let self, let index, self.eventStacks[eventID] == stacks else { return }
            if self.eventEditTags[eventID] != index { self.eventEditTags[eventID] = index }
        }
    }

    // MARK: - Cameras

    /// One camera on a board and how many of its stacks carry it — the
    /// Camera row's options and the event header's chips.
    struct BoardCamera: Identifiable, Equatable {
        var camera: OrganizeCamera
        var stackCount: Int
        var id: String { camera.id }
    }

    /// The resolver for the current configuration's sources — rebuilt only
    /// when the configuration changes. Building it is string work.
    var cameraResolver: OrganizeCameraResolver {
        if let cached = cameraResolverCache, cached.revision == model.configurationRevision {
            return cached.resolver
        }
        let resolver = OrganizeCameraResolver(locations: model.configuration.configuredLocations)
        cameraResolverCache = (model.configurationRevision, resolver)
        return resolver
    }

    /// Which camera shot one item: its assignment's device, else the
    /// configured source holding it, else its own camera tags (nil until
    /// the metadata pass has read them). Index lookups only.
    func camera(for item: OrganizeItem) -> OrganizeCamera? {
        cameraResolver.camera(
            assignmentDeviceID: assignment(for: item.primary)?.deviceID,
            file: item.primary,
            metadataCamera: item.metadataCamera
        )
    }

    /// Every camera across a stack's frames — the union a burst is judged
    /// on, like the other filter facts. A frame with no known camera
    /// contributes `OrganizeCamera.unknownID`.
    func cameraIDs(for stack: OrganizeStack) -> Set<String> {
        refreshIndexIfNeeded()
        return cameraIDs(for: stack, resolver: cameraResolver)
    }

    /// One stack's cameras, for a caller that has refreshed the assignment
    /// index and holds the resolver — a board asks this for every stack, and
    /// each `assignment(for:)` would copy the configuration to check the index.
    private func cameraIDs(for stack: OrganizeStack, resolver: OrganizeCameraResolver) -> Set<String> {
        var ids = Set<String>()
        for item in stack.items {
            let file = item.primary
            let device = assignmentsByPathKey[file.pathKey].flatMap { $0.fileSize == file.size ? $0.deviceID : nil }
            ids.insert(resolver.cameraID(assignmentDeviceID: device, file: file, metadataCamera: item.metadataCamera))
        }
        return ids
    }

    /// The first frame's camera — what the Camera sort orders by.
    func primaryCamera(for stack: OrganizeStack) -> OrganizeCamera? {
        stack.items.first.flatMap { camera(for: $0) }
    }

    /// (configurationRevision, resolver) behind `cameraResolver`.
    @ObservationIgnored private var cameraResolverCache: (revision: Int, resolver: OrganizeCameraResolver)?
    /// The last `boardCameras` answer, reused while the stacks, the
    /// assignments, and the sources are unchanged.
    @ObservationIgnored private var boardCamerasCache: [(catalog: Int, configuration: Int, stacks: [OrganizeStack], cameras: [BoardCamera])] = []

    /// The cameras on a board's stacks with how many stacks carry each —
    /// most stacks first, "Unknown camera" last. A mixed burst counts
    /// toward every camera in it. Answers for the last few boards are kept,
    /// so switching between boards does not recount either.
    func boardCameras(for stacks: [OrganizeStack]) -> [BoardCamera] {
        let catalog = model.catalogStateRevision
        let configuration = model.configurationRevision
        if let index = boardCamerasCache.firstIndex(where: {
            $0.catalog == catalog && $0.configuration == configuration && $0.stacks == stacks
        }) {
            let entry = boardCamerasCache.remove(at: index)
            boardCamerasCache.insert(entry, at: 0)
            return entry.cameras
        }
        refreshIndexIfNeeded()
        let resolver = cameraResolver
        let cameras = Self.boardCameras(stacks) { self.cameraIDs(for: $0, resolver: resolver) } name: { id in
            CameraCatalog.camera(id: id)
        }
        boardCamerasCache.insert((catalog, configuration, stacks, cameras), at: 0)
        if boardCamerasCache.count > 8 { boardCamerasCache.removeLast() }
        return cameras
    }

    // MARK: Header chips, kept off the render path

    /// Camera and people chips are decoration on the board's header, yet
    /// recounting them walks every stack (cameras) or every assignment
    /// (people) — ~20 ms on a 15,000-file family, and a move changes both
    /// answers twice. So a view draws the answer it already had while the
    /// new one is worked out on the next turn of the run loop, and redraws
    /// when it lands. The first answer for a board is computed at once.
    @ObservationIgnored private var displayedCameras: [UUID: [BoardCamera]] = [:]
    @ObservationIgnored private var displayedPeople: [UUID: [FacePerson]] = [:]
    @ObservationIgnored private var staleChipBoards: Set<UUID> = []
    @ObservationIgnored private var chipRefreshScheduled = false
    /// Bumped when a deferred chip answer lands; the header reads it.
    private(set) var boardChipsRevision = 0

    /// `boardCameras(for:)` for the header's chips — see above.
    func boardCamerasForDisplay(for stacks: [OrganizeStack], eventID: UUID) -> [BoardCamera] {
        _ = boardChipsRevision
        let catalog = model.catalogStateRevision
        let configuration = model.configurationRevision
        if boardCamerasCache.contains(where: { $0.catalog == catalog && $0.configuration == configuration && $0.stacks == stacks }) {
            let cameras = boardCameras(for: stacks)
            displayedCameras[eventID] = cameras
            return cameras
        }
        guard let shown = displayedCameras[eventID] else {
            let cameras = boardCameras(for: stacks)
            displayedCameras[eventID] = cameras
            return cameras
        }
        deferChipRefresh(eventID)
        return shown
    }

    /// `eventPeople(_:)` for the header's chips and the sidebar's tooltips.
    func eventPeopleForDisplay(_ eventID: UUID) -> [FacePerson] {
        _ = boardChipsRevision
        if let cache = eventPeopleCache, cache.0 == facesRevision, cache.1 == model.catalogStateRevision {
            let people = cache.2[eventID] ?? []
            displayedPeople[eventID] = people
            return people
        }
        guard let shown = displayedPeople[eventID] else {
            let people = eventPeople(eventID)
            displayedPeople[eventID] = people
            return people
        }
        deferChipRefresh(eventID)
        return shown
    }

    private func deferChipRefresh(_ eventID: UUID) {
        staleChipBoards.insert(eventID)
        guard !chipRefreshScheduled else { return }
        chipRefreshScheduled = true
        Task { @MainActor [weak self] in
            self?.refreshDeferredChips()
        }
    }

    /// Works out the chip answers that went stale and lets the views know.
    /// Runs on its own turn, so a move's landing does not carry it.
    func refreshDeferredChips() {
        chipRefreshScheduled = false
        let boards = staleChipBoards
        staleChipBoards = []
        for eventID in boards {
            if let stacks = eventStacks[eventID] { displayedCameras[eventID] = boardCameras(for: stacks) }
            displayedPeople[eventID] = eventPeople(eventID)
        }
        boardChipsRevision &+= 1
    }

    /// The counting behind `boardCameras(for:)`, pure so it can be tested
    /// without a workspace.
    static func boardCameras(
        _ stacks: [OrganizeStack],
        ids: (OrganizeStack) -> Set<String>,
        name: (String) -> OrganizeCamera
    ) -> [BoardCamera] {
        var counts: [String: Int] = [:]
        for stack in stacks {
            for id in ids(stack) {
                counts[id, default: 0] += 1
            }
        }
        return counts.map { BoardCamera(camera: name($0.key), stackCount: $0.value) }
            .sorted { lhs, rhs in
                let lhsUnknown = lhs.id == OrganizeCamera.unknownID
                let rhsUnknown = rhs.id == OrganizeCamera.unknownID
                if lhsUnknown != rhsUnknown { return rhsUnknown }
                if lhs.stackCount != rhs.stackCount { return lhs.stackCount > rhs.stackCount }
                return lhs.camera.name.localizedStandardCompare(rhs.camera.name) == .orderedAscending
            }
    }

    /// (catalogStateRevision, configurationRevision, camera ids by event)
    /// — the sidebar's Camera-row facts.
    @ObservationIgnored private var eventCameraIDsCache: (Int, Int, [UUID: Set<String>])?

    /// The cameras an event's assigned files came from, read off the
    /// assignments alone (the sidebar never reads file tags): the
    /// assignment's device, else the configured source it was imported
    /// from, else unknown.
    private func eventCameraIDs(for eventID: UUID) -> Set<String> {
        if let cache = eventCameraIDsCache,
           cache.0 == model.catalogStateRevision,
           cache.1 == model.configurationRevision {
            return cache.2[eventID] ?? []
        }
        let resolver = cameraResolver
        var ids: [UUID: Set<String>] = [:]
        for assignment in model.configuration.photoEventAssignments {
            let camera = CameraCatalog.camera(deviceID: assignment.deviceID)
                ?? resolver.locationCamera(forPathKey: (assignment.sourceRootPath + "/" + assignment.relativePath).lowercased())
            ids[assignment.eventID, default: []].insert(camera?.id ?? OrganizeCamera.unknownID)
        }
        eventCameraIDsCache = (model.catalogStateRevision, model.configurationRevision, ids)
        return ids[eventID] ?? []
    }

    /// The days a board should show — `visibleStacks` re-grouped into days.
    /// Days that lose every stack drop out entirely.
    func visibleDays(_ result: OrganizeScanResult, hideSorted: Bool, search: OrganizeSearchFilter = OrganizeSearchFilter()) -> [OrganizeDay] {
        let stacks = visibleStacks(result, hideSorted: hideSorted, search: search)
        guard hideSorted || !search.isEmpty else { return result.days }
        return OrganizeStacker.days(for: stacks)
    }

    /// Text-only form of `visibleDays(_:hideSorted:search:)`.
    func visibleDays(_ result: OrganizeScanResult, hideSorted: Bool, matching query: String) -> [OrganizeDay] {
        visibleDays(result, hideSorted: hideSorted, search: OrganizeSearchFilter(text: query))
    }

    /// Which event bucket a stack lands in when the board groups by event.
    func eventBucket(for stack: OrganizeStack) -> OrganizeEventBucket? {
        let assigned = assignedEvent(for: stack)
        if let event = assigned.event {
            return OrganizeEventBucket(key: event.id.uuidString, title: eventTitle(event), date: event.eventDate)
        }
        return assigned.mixed ? .mixed : nil
    }

    /// Inline burst expansion: which stacks currently show every frame in the
    /// board itself (not just the full-screen preview).
    func setExpanded(_ stackID: String, expanded: Bool) {
        if expanded {
            expandedStackIDs.insert(stackID)
        } else {
            expandedStackIDs.remove(stackID)
        }
    }

    func toggleExpanded(_ stackID: String) {
        setExpanded(stackID, expanded: !expandedStackIDs.contains(stackID))
    }

    func setGroupCollapsed(_ groupID: String, collapsed: Bool) {
        if collapsed {
            collapsedGroupIDs.insert(groupID)
        } else {
            collapsedGroupIDs.remove(groupID)
        }
    }

    func setAllGroupsCollapsed(_ collapsed: Bool, groups: [OrganizeBoardGroup]) {
        collapsedGroupIDs = collapsed ? Set(groups.map(\.id)) : []
    }

    /// Sorted files still waiting for Apply. A file the last Apply plan
    /// found already in its event as an identical copy is not waiting —
    /// it is counted by `applyCollisions(in:)` instead.
    func sortedFiles(in result: OrganizeScanResult) -> (files: Int, bytes: Int64) {
        let duplicates = applyDuplicateSourceKeys.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        var files = 0
        var bytes: Int64 = 0
        for item in result.items {
            for file in item.files where assignment(for: file) != nil && !duplicates.contains(file.pathKey) {
                files += 1
                bytes += file.size
            }
        }
        return (files, bytes)
    }

    /// Files in this folder the last Apply plan could not move: identical
    /// copies already in their event, and files whose name is taken.
    func applyCollisions(in result: OrganizeScanResult) -> (duplicates: Int, conflicts: Int) {
        let duplicates = applyDuplicateSourceKeys.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let conflicts = applyConflictSourceKeys.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        guard !duplicates.isEmpty || !conflicts.isEmpty else { return (0, 0) }
        var counts = (duplicates: 0, conflicts: 0)
        for item in result.items {
            for file in item.files where assignment(for: file) != nil {
                if duplicates.contains(file.pathKey) {
                    counts.duplicates += 1
                } else if conflicts.contains(file.pathKey) {
                    counts.conflicts += 1
                }
            }
        }
        return counts
    }

    func unsortedDetail(for location: ConfiguredLocation) -> String {
        guard isConnected(location) else { return "Not connected" }
        guard let state = sources[location.id] else { return DeviceChoice.name(for: deviceID(for: location)) }
        if state.isScanning { return "\(state.progress?.phase ?? "Reading")…" }
        if state.error != nil { return "Needs attention" }
        guard let result = state.result else { return DeviceChoice.name(for: deviceID(for: location)) }
        let left = result.stacks.count { !isSorted($0) }
        return left == 0 ? "All sorted" : "\(left) left to sort"
    }

    func assets(for stack: OrganizeStack, in eventID: UUID) -> [EventAssetPresence] {
        let index = eventAssetsByPathKey[eventID] ?? [:]
        return stack.files.compactMap { index[$0.pathKey] }
    }

    /// Rebuilds only the boards whose stack list just changed, keeping the
    /// id index in step with `eventStacks` without re-scanning untouched
    /// events.
    private func reindexEventStacks(from oldValue: [UUID: [OrganizeStack]]) {
        for key in Set(eventStacks.keys).union(oldValue.keys) {
            guard eventStacks[key] != oldValue[key] else { continue }
            eventStacksByID[key] = eventStacks[key].map { stacks in
                Dictionary(stacks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
            if case .event(let openID) = selection, openID == key { resolveBoardSelection() }
        }
    }

    /// The stacks behind a menu or key target on an event board — answered
    /// from the id index, so a right-click never scans the whole board.
    func stacks(matching ids: Set<String>, inEvent eventID: UUID) -> [OrganizeStack] {
        let byID = eventStacksByID[eventID] ?? [:]
        return ids.compactMap { byID[$0] }
    }

    /// Same lookup for an unsorted board.
    func stacks(matching ids: Set<String>, inLocation locationID: UUID) -> [OrganizeStack] {
        let byID = sources[locationID]?.stacksByID ?? [:]
        return ids.compactMap { byID[$0] }
    }

    /// "Move to Event"/"Sort Into" rows in sidebar order. `excluding` drops
    /// the event the stacks already sit in; nil keeps every event (the
    /// unsorted board's menu). Breadcrumb titles come from the shared
    /// hierarchy index — never `locations` — so building the menu does no
    /// filesystem work.
    private func menuTargets(excluding eventID: UUID?) -> [EventMenuTarget] {
        sidebarEvents.compactMap { row in
            guard row.event.id != eventID else { return nil }
            return EventMenuTarget(id: row.event.id, title: eventTitle(row.event))
        }
    }

    /// Everything the event board's right-click menu needs, answered from
    /// indexes the workspace already maintains — no stack scan and no
    /// filesystem work, so the menu opens instantly even while the event is
    /// still "Checking".
    func stackMenuState(forStackID stackID: String, inEvent eventID: UUID) -> OrganizeStackMenuState {
        let targets = targetStackIDs(including: stackID)
        return OrganizeStackMenuState(
            targetIDs: targets,
            stacks: stacks(matching: targets, inEvent: eventID),
            eventTargets: menuTargets(excluding: eventID)
        )
    }

    /// Same state for the unsorted board's menu; its "Sort Into" lists every
    /// event.
    func stackMenuState(forStackID stackID: String, inLocation locationID: UUID) -> OrganizeStackMenuState {
        let targets = targetStackIDs(including: stackID)
        return OrganizeStackMenuState(
            targetIDs: targets,
            stacks: stacks(matching: targets, inLocation: locationID),
            eventTargets: menuTargets(excluding: nil)
        )
    }

    func badge(for stack: OrganizeStack, in eventID: UUID) -> TileLocationBadge? {
        _ = eventAssetsRevision
        guard let event = event(eventID),
              let asset = eventAssetsByPathKey[eventID]?[stack.coverItem.primary.pathKey] else {
            return nil
        }
        if asset.drive == .present { return nil }
        if asset.otherDrive == .present { return locations.resolvedPolicy(for: event) == .buffer ? .inPrivate : .inBuffer }
        if asset.source == .present { return .onSource }
        if asset.archive == .present { return .nasOnly }
        return nil
    }

    // MARK: - Startup and selection

    func start() {
        observeVolumeChanges()
        Task { await loadUndoHistory() }
        discoverDriveEvents()
        scheduleRosterWarm()
        // Decode the capture-date cache now, off the main actor, so the
        // first board opened never waits for it.
        let loader = captureDateCacheLoader
        Task.detached(priority: .utility) { _ = loader.cache() }
    }

    func startGuide() {
        if guide == nil {
            guide = SetupGuide(workspace: self)
        }
        guide?.isCollapsed = false
    }

    func selectionChanged() {
        if case .event = selection { nasPresence.refresh(.boardOpened) }
        cancelPendingSelectionCollapse()
        // The board just opened gets its own selection back; the one just
        // left keeps its selection for when it is opened again.
        resolveBoardSelection(force: true)
        swapBoardViewState()
    }

    // MARK: Per-board view state

    /// Everything about how a board looks that is the board's own, not the
    /// window's: which bursts are open, which day groups are folded, the
    /// filters and search text, and where it is scrolled to. Saved when the
    /// board is left, put back when it is opened again.
    struct BoardViewState {
        var expandedStackIDs: Set<String> = []
        var collapsedGroupIDs: Set<String> = []
        var search = OrganizeSearchFilter()
        /// Distance of the visible top edge from the top of the content.
        var scrollOffset: Double = 0
    }

    @ObservationIgnored private(set) var boardViewStates: [EventsSidebarSelection: BoardViewState] = [:]
    /// The board `expandedStackIDs`, `collapsedGroupIDs` and `search` belong
    /// to right now.
    @ObservationIgnored private var boardOnScreen: EventsSidebarSelection?

    /// A board left while it was still finding its first files stops loading
    /// — clicking through ten boards must not leave ten pipelines running.
    /// Its partial grid stays, and opening it again starts the load over.
    private func cancelSupersededLoad(of board: EventsSidebarSelection) {
        guard case .event(let eventID) = board, board != selection,
              eventsLoading.contains(eventID),
              eventStacks[eventID]?.isEmpty != false || eventBuildRemainders[eventID] != nil else { return }
        presenceTasks[eventID]?.cancel()
        presenceTasks[eventID] = nil
        refreshGenerations[eventID] = UUID()
        eventsLoading.remove(eventID)
        resumePresenceWaiters(for: eventID, appliedGeneration: UUID())
    }

    private func swapBoardViewState() {
        if let left = boardOnScreen {
            cancelSupersededLoad(of: left)
            var state = boardViewStates[left] ?? BoardViewState()
            state.expandedStackIDs = expandedStackIDs
            state.collapsedGroupIDs = collapsedGroupIDs
            state.search = search
            boardViewStates[left] = state
        }
        boardOnScreen = selection
        if let opened = selection {
            let state = boardViewStates[opened] ?? BoardViewState()
            expandedStackIDs = state.expandedStackIDs
            collapsedGroupIDs = state.collapsedGroupIDs
            search = state.search
        } else {
            expandedStackIDs = []
            collapsedGroupIDs = []
        }
    }

    /// Called by a board's grid as it scrolls. Not observable — recording a
    /// scroll offset must never re-render anything.
    func noteScrollOffset(_ offset: Double, board: EventsSidebarSelection) {
        boardViewStates[board, default: BoardViewState()].scrollOffset = offset
    }

    func savedScrollOffset(for board: EventsSidebarSelection) -> Double {
        boardViewStates[board]?.scrollOffset ?? 0
    }

    // MARK: Per-board selection

    /// Selection identity of a file: name, bytes and mtime — the same key
    /// that follows a file between folders, so it survives a rebuild that
    /// rewrites every path-derived stack id.
    nonisolated static func selectionKey(_ file: OrganizeFile) -> String {
        FaceIndexStore.fileKey(fileName: file.name, byteCount: file.size, modifiedAt: file.modifiedAt)
    }

    private func stackOnOpenBoard(_ id: String) -> OrganizeStack? {
        switch selection {
        case .event(let eventID): eventStacksByID[eventID]?[id]
        case .unsorted(let locationID): sources[locationID]?.stacksByID[id]
        case nil: nil
        }
    }

    private func stacksOnBoard(_ board: EventsSidebarSelection) -> [OrganizeStack] {
        switch board {
        case .event(let eventID): eventStacks[eventID] ?? []
        case .unsorted(let locationID): sources[locationID]?.result?.stacks ?? []
        }
    }

    private func storeBoardSelection(_ state: BoardSelectionState, for board: EventsSidebarSelection) {
        boardSelections[board] = state.isEmpty ? nil : state
    }

    private func recordSelectedKeys() {
        guard let board = selection else { return }
        var state = boardSelections[board] ?? BoardSelectionState()
        var keys: Set<String> = []
        for id in selectedStackIDs {
            guard let stack = stackOnOpenBoard(id) else { continue }
            for file in stack.files { keys.insert(Self.selectionKey(file)) }
        }
        state.keys = keys
        storeBoardSelection(state, for: board)
    }

    private func recordFocusKey() {
        guard let board = selection else { return }
        var state = boardSelections[board] ?? BoardSelectionState()
        state.focusKey = focusedStackID.flatMap(stackOnOpenBoard)?.files.first.map(Self.selectionKey)
        storeBoardSelection(state, for: board)
    }

    private func recordAnchorKey() {
        guard let board = selection else { return }
        var state = boardSelections[board] ?? BoardSelectionState()
        state.anchorKey = selectionAnchorID.flatMap(stackOnOpenBoard)?.files.first.map(Self.selectionKey)
        storeBoardSelection(state, for: board)
    }

    /// Points the published selection at the open board's stacks as they
    /// are now. Runs when a board opens and whenever its stacks change
    /// (first screen, full build, NAS listing, rescan, restack). `force`
    /// re-resolves even when the current ids still exist; otherwise a
    /// selection whose stacks are all still on the board is left alone, so
    /// a progress tick costs a handful of lookups.
    private func resolveBoardSelection(force: Bool = false) {
        guard let board = selection, let state = boardSelections[board] else {
            if force, !selectedStackIDs.isEmpty || focusedStackID != nil {
                isApplyingBoardSelection = true
                selectedStackIDs = []
                focusedStackID = nil
                selectionAnchorID = nil
                isApplyingBoardSelection = false
            }
            return
        }
        if !force {
            let idsPresent = selectedStackIDs.allSatisfy { stackOnOpenBoard($0) != nil }
            let focusPresent = focusedStackID.map { stackOnOpenBoard($0) != nil } ?? (state.focusKey == nil)
            if idsPresent, focusPresent, !selectedStackIDs.isEmpty || state.keys.isEmpty { return }
        }
        var ids: Set<String> = []
        var focusID: String?
        var anchorID: String?
        for stack in stacksOnBoard(board) {
            var selectedHit = false
            for file in stack.files {
                let key = Self.selectionKey(file)
                if state.keys.contains(key) { selectedHit = true }
                if focusID == nil, key == state.focusKey { focusID = stack.id }
                if anchorID == nil, key == state.anchorKey { anchorID = stack.id }
            }
            if selectedHit { ids.insert(stack.id) }
        }
        isApplyingBoardSelection = true
        defer { isApplyingBoardSelection = false }
        if selectedStackIDs != ids { selectedStackIDs = ids }
        if focusedStackID != focusID { focusedStackID = focusID }
        if selectionAnchorID != anchorID { selectionAnchorID = anchorID }
    }

    /// Forgets the given files (by identity) on every board — used when the
    /// files themselves have left, so nothing else is disturbed.
    private func dropSelectionKeys(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        for (board, var state) in boardSelections {
            let before = state
            state.keys.subtract(keys)
            if let focus = state.focusKey, keys.contains(focus) { state.focusKey = nil }
            if let anchor = state.anchorKey, keys.contains(anchor) { state.anchorKey = nil }
            if state != before { storeBoardSelection(state, for: board) }
        }
        resolveBoardSelection(force: true)
    }

    /// Moves keyboard focus to a stack without touching the selection — what
    /// opening the viewer (double-click, Space) does.
    func focus(stackID: String) {
        cancelPendingSelectionCollapse()
        if focusedStackID != stackID { focusedStackID = stackID }
    }

    /// Click on a tile. Wraps `select` with `BoardClickPolicy`: a click
    /// that is part of a double-click never changes the selection, and a
    /// plain click on a selected tile in a multi-selection collapses it
    /// only once the double-click interval has passed without a second click.
    func click(stackID: String, orderedIDs: [String], modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        cancelPendingSelectionCollapse()
        switch BoardClickPolicy.decide(
            isSelected: selectedStackIDs.contains(stackID),
            selectionCount: selectedStackIDs.count,
            modifiers: modifiers,
            clickCount: clickCount
        ) {
        case .keepSelection:
            focusedStackID = stackID
        case .replace:
            select(stackID: stackID, orderedIDs: orderedIDs, extend: false, toggle: false)
        case .extend:
            select(stackID: stackID, orderedIDs: orderedIDs, extend: true, toggle: false)
        case .toggle:
            select(stackID: stackID, orderedIDs: orderedIDs, extend: false, toggle: true)
        case .replaceAfterDoubleClickInterval:
            focusedStackID = stackID
            let board = selection
            pendingSelectionCollapse = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.selectionCollapseDelay ?? 0))
                guard !Task.isCancelled, let self, self.selection == board else { return }
                self.pendingSelectionCollapse = nil
                self.select(stackID: stackID, orderedIDs: orderedIDs, extend: false, toggle: false)
            }
        }
    }

    private func cancelPendingSelectionCollapse() {
        pendingSelectionCollapse?.cancel()
        pendingSelectionCollapse = nil
    }

    func select(stackID: String, orderedIDs: [String], extend: Bool, toggle: Bool) {
        cancelPendingSelectionCollapse()
        if toggle {
            if selectedStackIDs.contains(stackID) {
                selectedStackIDs.remove(stackID)
            } else {
                selectedStackIDs.insert(stackID)
            }
            selectionAnchorID = stackID
        } else if extend,
                  let anchor = selectionAnchorID ?? focusedStackID,
                  let start = orderedIDs.firstIndex(of: anchor),
                  let end = orderedIDs.firstIndex(of: stackID) {
            selectedStackIDs = Set(orderedIDs[min(start, end)...max(start, end)])
        } else {
            selectedStackIDs = [stackID]
            selectionAnchorID = stackID
        }
        focusedStackID = stackID
    }

    func selectStacks(_ ids: [String]) {
        cancelPendingSelectionCollapse()
        selectedStackIDs = Set(ids)
        focusedStackID = ids.first
        selectionAnchorID = ids.first
    }

    func targetStackIDs() -> Set<String> {
        if !selectedStackIDs.isEmpty { return selectedStackIDs }
        return Set([focusedStackID].compactMap { $0 })
    }

    func targetStackIDs(including stackID: String) -> Set<String> {
        selectedStackIDs.contains(stackID) ? selectedStackIDs : [stackID]
    }

    func advanceFocus(past ids: Set<String>, orderedIDs: [String]) {
        guard let last = orderedIDs.lastIndex(where: { ids.contains($0) }),
              let next = orderedIDs[(last + 1)...].first(where: { !ids.contains($0) }) else {
            selectedStackIDs.removeAll()
            return
        }
        selectedStackIDs = [next]
        focusedStackID = next
        selectionAnchorID = next
    }

    /// How many drag payloads were built — one per drag, none per render.
    @ObservationIgnored private(set) var dragPayloadBuildCount = 0

    func dragPayload(for stackID: String, origin: OrganizeDragPayload.Origin, containerID: UUID) -> String {
        dragPayloadBuildCount += 1
        return OrganizeDragPayload(origin: origin, containerID: containerID, stackIDs: Array(targetStackIDs(including: stackID))).encoded
    }

    @discardableResult
    func handleDrop(_ strings: [String], onto eventID: UUID) -> Bool {
        guard let payload = strings.lazy.compactMap(OrganizeDragPayload.decode).first else { return false }
        switch payload.origin {
        case .unsorted:
            assign(stackIDs: Set(payload.stackIDs), from: payload.containerID, to: eventID)
        case .event:
            moveStacks(Set(payload.stackIDs), fromEvent: payload.containerID, toEvent: eventID)
        }
        return true
    }

    // MARK: - Unsorted folders

    func addUnsortedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Add Unsorted Folder or Card"
        panel.prompt = "Add"
        panel.message = "Choose a camera card, or a folder of photos you have not sorted into events yet."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        if let existing = unsortedLocations.first(where: {
            EventStorageLocations.pathKey(DashboardModel.expandedPath($0.path)) == EventStorageLocations.pathKey(path)
        }) {
            selection = .unsorted(existing.id)
            return
        }
        var location = ConfiguredLocation(role: .importSource, name: url.lastPathComponent, path: path)
        location.deviceID = DashboardModel.inferredDeviceID(for: location)
        model.updateConfiguration { $0.configuredLocations.append(location) }
        selection = .unsorted(location.id)
    }

    func removeUnsortedFolder(_ locationID: UUID) {
        guard let location = location(locationID) else { return }
        model.removeConfiguredLocation(location)
        sources[locationID] = nil
        if selection == .unsorted(locationID) { selection = nil }
        model.statusMessage = "Removed \(location.name) from the Unsorted list. No files were changed."
    }

    func setDevice(_ deviceID: String, for locationID: UUID) {
        model.updateConfiguration { configuration in
            guard let index = configuration.configuredLocations.firstIndex(where: { $0.id == locationID }) else { return }
            configuration.configuredLocations[index].deviceID = deviceID
        }
    }

    func scan(_ location: ConfiguredLocation, force: Bool = false) {
        let id = location.id
        var state = sources[id] ?? UnsortedSourceState()
        guard !state.isScanning, force || state.result == nil else { return }
        let root = URL(fileURLWithPath: DashboardModel.expandedPath(location.path), isDirectory: true)
        guard isConnectedNow(location) else {
            state.error = "\(location.name) is not connected. Plug in the drive or card, then press Rescan."
            sources[id] = state
            return
        }
        state.isScanning = true
        state.error = nil
        state.progress = nil
        sources[id] = state
        let cache = captureDateCache
        let burstSplits = model.configuration.burstSplits
        let reportProgress: @Sendable (OrganizeScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.sources[id]?.progress = progress
            }
        }

        let gate = driveActivityGate
        Task { @MainActor [weak self] in
            let outcome: Result<OrganizeScanResult, any Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try OrganizeScanner().scan(root: root, cache: cache, burstGrouping: BurstGroupingConfiguration.resolved(), burstSplits: burstSplits, pauseGate: gate, progress: reportProgress)
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let result):
                sources[id]?.result = result
                sources[id]?.error = nil
            case .failure(let error):
                sources[id]?.error = "Could not read \(location.name): \(error.localizedDescription)"
            }
            sources[id]?.isScanning = false
            sources[id]?.progress = nil
        }
    }

    // MARK: - Connectivity

    /// Re-checks which configured places are reachable. This is cheap — mount
    /// table and folder stat probes only, never a file-content scan. Cached
    /// event presence and drive-event discovery are refreshed so Offline
    /// badges clear, and unsorted sources that failed while offline scan again
    /// once they are reachable. When `mountedVolumes` is non-empty (those
    /// volumes just mounted), sources on them are scanned even if they were
    /// never tried.
    ///
    /// Refresh never mounts anything itself: the configuration stores local
    /// paths and service URLs, not network share URLs, so there is no share
    /// URL to hand to the mounter.
    func refreshConnectivity(mountedVolumes: Set<URL> = []) {
        connectivityRevision &+= 1
        lastConnectivityRefresh = Date()
        nasConnection.volumesChanged()
        nasPresence.refresh(.mounted)
        // The NAS may have just mounted: apply what moves left queued.
        drainNASRenames()
        let mountedNow = VolumeInfo.mountedVolumePaths()
        lastConnectivityMountedPaths = mountedNow

        discoverDriveEvents()

        // A refresh triggered by mount changes re-verifies only the boards
        // whose roots live on the volumes that changed, plus the board on
        // screen. An unscoped call — the launch path — still re-verifies
        // everything it knows.
        let changedRoots = Set(mountedVolumes.map { $0.standardizedFileURL.path })
        let scopeToChanged = !changedRoots.isEmpty
        let visibleEventID: UUID? = {
            if case .event(let id) = selection { return id }
            return nil
        }()
        for eventID in Set(presence.keys).union(eventStacks.keys).union(eventReachability.keys) {
            if scopeToChanged,
               eventID != visibleEventID,
               !eventRootsChanged(eventID, changedRoots: changedRoots) {
                continue
            }
            Task { await refreshEvent(eventID) }
        }

        let mountedRoots = changedRoots.intersection(mountedNow)
        for location in unsortedLocations {
            let state = sources[location.id]
            // Healthy cached results are never rescanned here.
            guard state?.isScanning != true, state?.result == nil else { continue }
            guard isConnectedNow(location) else { continue }
            if !mountedRoots.isEmpty {
                let locationURL = URL(fileURLWithPath: DashboardModel.expandedPath(location.path), isDirectory: true)
                guard let volumeRoot = VolumeInfo.volumeRoot(for: locationURL),
                      mountedRoots.contains(volumeRoot.path) else { continue }
            } else if state == nil {
                // A refresh not triggered by a mount only retries sources
                // that failed before. Fresh sources scan when selected or
                // when their volume mounts.
                continue
            }
            scan(location)
        }
    }

    /// True when the event's storage roots live on a volume whose mount
    /// state just changed — the scoped-refresh test.
    private func eventRootsChanged(_ eventID: UUID, changedRoots: Set<String>) -> Bool {
        guard event(eventID) != nil else { return false }
        // An event waiting on an offline card (or any other offline place)
        // reloads when that place's volume comes back.
        if let report = eventReachability[eventID],
           report.states.contains(where: { place, state in
               state.isOffline && place.volumeRoot.map { changedRoots.contains($0.standardizedFileURL.path) } == true
           }) {
            return true
        }
        let locations = self.locations
        return [
            locations.driveRoot(for: .buffer),
            locations.driveRoot(for: .archiveOnly),
            locations.libraryRoot,
            locations.nasRoot,
        ].contains { root in
            guard let volume = VolumeInfo.volumeRoot(for: root) else { return false }
            return changedRoots.contains(volume.standardizedFileURL.path)
        }
    }

    /// For app activation: connectivity re-checks at most every `maxAge`
    /// seconds, and only when the mounted-volume set actually moved. A
    /// wake where nothing mounted or unmounted updates no state at all —
    /// the offline badges were already right.
    func refreshConnectivityIfStale(maxAge: TimeInterval = 15) {
        guard Date().timeIntervalSince(lastConnectivityRefresh) >= maxAge else { return }
        let mounted = VolumeInfo.mountedVolumePaths()
        let changed = mounted.symmetricDifference(lastConnectivityMountedPaths ?? mounted)
        guard !changed.isEmpty else {
            lastConnectivityRefresh = Date()
            return
        }
        refreshConnectivity(mountedVolumes: Set(changed.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }))
    }

    /// Registers once for volume mount/unmount notifications so offline rows,
    /// presence summaries, and failed scans update themselves when a drive or
    /// card appears or disappears. Notifications are debounced, so a burst of
    /// mount/unmount events (a flapping hub) collapses into one refresh pass.
    /// Safe to call repeatedly.
    func observeVolumeChanges() {
        guard mountObservers.observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        mountObservers.observers = [
            center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { [weak self] notification in
                let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                Task { @MainActor [weak self] in
                    self?.scheduleConnectivityRefresh(changedVolume: url)
                }
            },
            center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { [weak self] notification in
                let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                Task { @MainActor [weak self] in
                    self?.scheduleConnectivityRefresh(changedVolume: url)
                }
            },
        ]
    }

    /// Trailing-edge debounce for mount notifications: a burst coalesces into
    /// a single `refreshConnectivity` about 0.75 s after the last event.
    /// Volumes reported during the window are remembered so sources on a
    /// just-mounted volume still rescan once.
    private func scheduleConnectivityRefresh(changedVolume: URL? = nil) {
        if let changedVolume {
            pendingMountedVolumes.insert(changedVolume.standardizedFileURL)
        }
        connectivityRefreshTask?.cancel()
        connectivityRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let changed = self.pendingMountedVolumes
            self.pendingMountedVolumes = []
            self.refreshConnectivity(mountedVolumes: changed)
        }
    }

    // MARK: - Sorting

    func assign(stackIDs: Set<String>, from locationID: UUID, to eventID: UUID, orderedIDs: [String] = []) {
        guard let result = sources[locationID]?.result,
              let location = location(locationID),
              let event = event(eventID) else { return }
        let stacks = result.stacks.filter { stackIDs.contains($0.id) }
        let files = stacks.flatMap(\.files)
        guard !files.isEmpty else {
            model.statusMessage = "Select photos first, then press a number or drag them onto an event."
            return
        }
        refreshIndexIfNeeded()
        let locations = self.locations
        let keys = Set(files.map(\.pathKey))
        let previous = keys.compactMap { assignmentsByPathKey[$0] }
        let blockedKeys = Set(previous.filter { prior in
            prior.eventID != eventID && hasDriveCopy(prior, locations: locations)
        }.map(Self.sourceKey))
        let eligible = files.filter { !blockedKeys.contains($0.pathKey) }
        guard !eligible.isEmpty else {
            model.statusMessage = "Those files already have a copy in another event's folder. Open that event to move them."
            return
        }
        let eligibleKeys = Set(eligible.map(\.pathKey))
        let existingInEvent = model.configuration.photoEventAssignments.filter {
            $0.eventID == eventID && !eligibleKeys.contains(Self.sourceKey($0))
        }
        var added = OrganizeAssignmentBuilder.assignments(
            for: eligible,
            scanRootPath: result.rootPath,
            duplicateNames: result.duplicateNames,
            existingEventAssignments: existingInEvent,
            eventID: eventID,
            deviceID: deviceID(for: location)
        )
        let removed = previous.filter { eligibleKeys.contains(Self.sourceKey($0)) }
        let priorOverrides = Dictionary(
            removed.filter { $0.eventID == eventID }.map { (Self.sourceKey($0), $0.immichUploadOverride) },
            uniquingKeysWith: { first, _ in first }
        )
        for index in added.indices {
            if let override = priorOverrides[Self.sourceKey(added[index])] {
                added[index].immichUploadOverride = override
            }
        }

        let change = AssignmentChange(title: "Sort into \(eventTitle(event))", removed: removed, added: added)
        // The items the open event board gains without a refresh — only
        // items whose every file was eligible, so nothing unassigned
        // boards. A file left uncovered falls back to a refresh inside
        // `applyAssignmentChange`.
        let eligibleItems = stacks.flatMap(\.items).filter { item in
            item.files.allSatisfy { eligibleKeys.contains($0.pathKey) }
        }
        applyAssignmentChange(change, touching: eventID, addedItems: eligibleItems)
        noteRecent(eventID)
        recordAssignmentUndo(change)
        let skipped = files.count - eligible.count
        model.statusMessage = "Sorted \(stacks.count) item\(stacks.count == 1 ? "" : "s") (\(eligible.count) file\(eligible.count == 1 ? "" : "s")) into \(eventTitle(event)). Nothing moves until you press Apply."
            + (skipped > 0 ? " \(skipped) file(s) already live in another event's folder and were left alone." : "")
        advanceFocus(past: stackIDs, orderedIDs: orderedIDs)
    }

    func unassign(stackIDs: Set<String>, from locationID: UUID) {
        guard let result = sources[locationID]?.result else { return }
        let files = result.stacks.filter { stackIDs.contains($0.id) }.flatMap(\.files)
        refreshIndexIfNeeded()
        let locations = self.locations
        let previous = Set(files.map(\.pathKey)).compactMap { assignmentsByPathKey[$0] }
        let removable = previous.filter { !hasDriveCopy($0, locations: locations) }
        guard !removable.isEmpty else {
            model.statusMessage = previous.isEmpty
                ? "Those photos are not sorted yet."
                : "Those files already have a copy in their event's folder. Open the event and use Return to Unsorted."
            return
        }
        let change = AssignmentChange(title: "Unsort", removed: removable, added: [])
        applyAssignmentChange(change, touching: nil)
        recordAssignmentUndo(change)
        model.statusMessage = "Unsorted \(removable.count) file\(removable.count == 1 ? "" : "s")."
    }

    func hasDriveCopy(_ assignment: PhotoEventAssignment, locations: EventStorageLocations) -> Bool {
        guard let event = event(assignment.eventID) else { return false }
        let sourceKey = locations.sourceURL(for: assignment).map { EventStorageLocations.pathKey($0.path) }
        return EventStoragePolicy.allCases.contains { policy in
            guard let url = locations.driveURL(for: assignment, event: event, policy: policy),
                  EventStorageLocations.pathKey(url.path) != sourceKey else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// `patchBoards: false` is for a caller that already moved the tiles
    /// itself (an optimistic Move to Event) and only needs the catalog and
    /// the lookup indexes brought in step.
    func applyAssignmentChange(
        _ change: AssignmentChange,
        touching eventID: UUID?,
        addedItems: [OrganizeItem] = [],
        patchBoards: Bool = true
    ) {
        let wasCurrent = assignmentIndexIsCurrent
        let revisionBefore = model.configurationRevision
        let applied = model.replaceAssignments(removing: change.removed, adding: change.added, touching: eventID)
        // Assignments are not part of what `EventStorageLocations` is built
        // from (roots, event names, dates, parents), so the resolver stays
        // valid across this change — no rebuild, no root stats.
        if let cached = locationsCache, cached.revision == revisionBefore {
            locationsCache = (model.configurationRevision, cached.locations)
        }
        patchAssignmentIndex(removed: applied.removed, added: applied.added, wasCurrent: wasCurrent)
        guard patchBoards else { return }
        // Open boards update in place — no refresh, no sweep, no grid
        // rebuild. Removed files leave every board by file identity, and
        // a board that already displays files gains the items it just
        // got. An addition whose items the caller could not supply (an
        // undo of a move, say) still refreshes that board the way it
        // always did.
        removeAssignmentsFromEventBoards(change.removed)
        let covered = Set(addedItems.flatMap(\.files).map(Self.fileKey))
        for (targetID, added) in Dictionary(grouping: change.added, by: \.eventID) {
            let wanted = Set(added.map(Self.fileKey))
            // The event's own board and the open family boards above it draw
            // its files alike.
            for boardID in Array(eventStacks.keys) where scopeIDs(boardID).contains(targetID) {
                guard let stacks = eventStacks[boardID] else { continue }
                guard wanted.isSubset(of: covered) else {
                    Task { await refreshEvent(boardID) }
                    continue
                }
                let present = Set(stacks.flatMap(\.files).map(\.pathKey))
                let fresh = addedItems.filter { !present.contains($0.primary.pathKey) }
                eventStacks[boardID] = OrganizeStacker.stacks(
                    for: stacks.flatMap(\.items) + fresh,
                    splits: model.configuration.burstSplits
                ).carryingIDs(from: stacks)
                eventGridRevisions[boardID] = model.catalogStateRevision
            }
        }
    }

    /// `FaceIndexStore.fileKey` for a catalog assignment — name, byte
    /// count, mtime; the identity that survives the file moving folders.
    static func fileKey(_ assignment: PhotoEventAssignment) -> String {
        FaceIndexStore.fileKey(
            fileName: (assignment.relativePath as NSString).lastPathComponent,
            byteCount: assignment.fileSize,
            modifiedAt: assignment.modifiedAt
        )
    }

    /// The same key for a board file, so an assignment's files match the
    /// tile showing them no matter which copy the tile points at.
    private static func fileKey(_ file: OrganizeFile) -> String {
        FaceIndexStore.fileKey(fileName: file.name, byteCount: file.size, modifiedAt: file.modifiedAt)
    }

    /// Drop removed assignments' files from every open board, matching by
    /// file identity so a stack loses the file whichever copy its tiles
    /// were pointing at. Boards without a match are left untouched.
    private func removeAssignmentsFromEventBoards(_ removed: [PhotoEventAssignment]) {
        guard !removed.isEmpty else { return }
        let fileKeys = Set(removed.map(Self.fileKey))
        let splits = model.configuration.burstSplits
        for boardID in Array(eventStacks.keys) {
            guard let stacks = eventStacks[boardID] else { continue }
            let items = stacks.flatMap(\.items)
            let remaining = items.filter { item in
                !item.files.contains { fileKeys.contains(Self.fileKey($0)) }
            }
            guard remaining.count != items.count else { continue }
            eventStacks[boardID] = OrganizeStacker.stacks(for: remaining, splits: splits)
                .carryingIDs(from: stacks)
            eventGridRevisions[boardID] = model.catalogStateRevision
        }
    }

    // MARK: - Events

    func requestNewEvent(from locationID: UUID?, parentEventID: UUID? = nil) {
        // New Subevent under an event already at the cap refuses here —
        // the picker never offered it, but the menu shortcut can reach it.
        if let parentEventID, let refusal = subeventRefusal(for: parentEventID) {
            model.statusMessage = refusal
            return
        }
        let stacks = locationID.flatMap { id in
            sources[id]?.result?.stacks.filter { targetStackIDs().contains($0.id) }
        } ?? []
        newEventRequest = NewEventRequest(
            suggestedDate: stacks.map(\.captureDate).min() ?? Date(),
            sourceLocationID: locationID,
            stackIDs: Set(stacks.map(\.id)),
            parentEventID: validParentEventID(parentEventID, for: nil)
        )
    }

    /// New Event for explicit stacks on an unsorted board — the burst
    /// preview's stack may not be the board's current selection.
    func requestNewEvent(stackIDs: Set<String>, from locationID: UUID, suggestedDate: Date? = nil) {
        let stacks = sources[locationID]?.result?.stacks.filter { stackIDs.contains($0.id) } ?? []
        newEventRequest = NewEventRequest(
            suggestedDate: suggestedDate ?? stacks.map(\.captureDate).min() ?? Date(),
            sourceLocationID: locationID,
            stackIDs: stackIDs
        )
    }

    /// New Event for stacks on an event board — completion moves them into
    /// the created event instead of assigning from an unsorted source.
    func requestNewEvent(stackIDs: Set<String>, movingFromEvent eventID: UUID, suggestedDate: Date? = nil) {
        let stacks = eventStacks[eventID]?.filter { stackIDs.contains($0.id) } ?? []
        newEventRequest = NewEventRequest(
            suggestedDate: suggestedDate ?? stacks.map(\.captureDate).min() ?? Date(),
            stackIDs: stackIDs,
            moveFromEventID: eventID
        )
    }

    @discardableResult
    func createEvent(name rawName: String, date: Date, policy: EventStoragePolicy?, parentEventID: UUID? = nil) -> UUID? {
        let validation = EventNamePolicy.validate(rawName)
        guard validation.isValid else {
            model.statusMessage = validation.errorMessage ?? "Choose a different event name."
            return nil
        }
        let day = Calendar.current.startOfDay(for: date)
        // A parent picked before the cap is validated reports why instead
        // of silently creating a top-level event.
        let parentID = validParentEventID(parentEventID, for: nil)
        if let parentEventID, parentID == nil {
            model.statusMessage = subeventRefusal(for: parentEventID)
                ?? "That parent can't take another subevent."
            return nil
        }
        // The dated folder name is unique per parent: the same name and date
        // under a different parent is a different folder, not a duplicate.
        if let existing = model.configuration.savedEvents.first(where: {
            $0.name.localizedCaseInsensitiveCompare(validation.normalizedName) == .orderedSame
                && Calendar.current.isDate($0.eventDate, inSameDayAs: day)
                && $0.parentEventID == parentID
        }) {
            noteRecent(existing.id)
            return existing.id
        }
        let event = SavedCameraEvent(
            name: validation.normalizedName,
            eventDate: day,
            storagePolicy: policy,
            parentEventID: parentID
        )
        model.updateConfiguration { $0.savedEvents.append(event) }
        noteRecent(event.id)
        recordUndo("Create \(eventTitle(event))", .config(.events(UndoEventsChange(created: [event]))))
        model.statusMessage = "Created \(eventTitle(event)). Sort photos into it, then press Apply."
        return event.id
    }

    func completeNewEvent(_ request: NewEventRequest, name: String, date: Date, policy: EventStoragePolicy?, parentEventID: UUID?) {
        guard let eventID = createEvent(name: name, date: date, policy: policy, parentEventID: parentEventID) else { return }
        newEventRequest = nil
        // Creating an event never sorts or moves photos. Assign is a separate
        // click on the board; Apply is the later move. Auto-assign made every
        // selected burst go gray the moment the sheet confirmed.
        if request.sourceLocationID == nil, request.moveFromEventID == nil {
            selection = .event(eventID)
        }
    }

    /// Deletes an event only when nothing belongs to it — decided by the
    /// catalog and the drive, never by a board or by the tiles a queued move
    /// has already lifted off it. Anything found is named, with its folder.
    func deleteEmptyEvent(_ eventID: UUID) {
        guard let event = event(eventID) else { return }
        let title = eventTitle(event)
        let owned = model.configuration.photoEventAssignments.count { $0.eventID == eventID }
        guard owned == 0 else {
            refuseMove("Delete \(title)", "\(title) still has \(ApplyPlanOverview.plural(owned, "file")) in the catalog, so it was not deleted. Move or return them first.")
            return
        }
        guard !pendingMoves.contains(where: { $0.to.id == eventID || $0.sourceIDs.contains(eventID) }) else {
            refuseMove("Delete \(title)", "A move into or out of \(title) is still waiting or running, so it was not deleted.")
            return
        }
        guard EventHierarchy.descendants(of: eventID, in: model.configuration.savedEvents).isEmpty else {
            refuseMove("Delete \(title)", "\(title) has subevents. Move or delete them first.")
            return
        }
        for policy in EventStoragePolicy.allCases {
            let folder = locations.eventFolder(for: event, policy: policy)
            let found = Self.filesOnDisk(under: folder)
            if found.count > 0 {
                refuseMove(
                    "Delete \(title)",
                    "\(title)'s folder still holds \(ApplyPlanOverview.plural(found.count, "file")) on the drive (\(folder.path)), so it was not deleted.",
                    files: found.names
                )
                return
            }
        }
        model.updateConfiguration { $0.savedEvents.removeAll { $0.id == eventID } }
        if selection == .event(eventID) { selection = nil }
        recordUndo("Delete \(title)", .config(.events(UndoEventsChange(deleted: [event]))))
        model.statusMessage = "Deleted the empty event \(event.name)."
    }

    /// Real files under `folder` (Finder metadata does not count), as a count
    /// and the first few names. Reads the disk; a missing folder holds none.
    nonisolated static func filesOnDisk(under folder: URL) -> (count: Int, names: [String]) {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return (0, []) }
        var count = 0
        var names: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  !JunkPolicy.isJunkFile(url.lastPathComponent) else { continue }
            count += 1
            if names.count < 25 { names.append(url.lastPathComponent) }
        }
        return (count, names)
    }

    /// `nil` leaves the policy unset: a subevent then follows its parent's
    /// setting, and a top-level event resolves to the shared Buffer.
    func setPolicy(_ eventID: UUID, _ policy: EventStoragePolicy?) {
        let before = event(eventID)
        model.updateConfiguration { configuration in
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].storagePolicy = policy
        }
        if let before, let after = event(eventID), before.storagePolicy != after.storagePolicy {
            let setting = policy == .archiveOnly ? "Private" : (policy == .buffer ? "Shared" : "Follow Parent")
            recordUndo(
                "Set \(eventTitle(before)) to \(setting)",
                .config(.events(UndoEventsChange(edited: [UndoEventPair(before: before, after: after)])))
            )
        }
        switch policy {
        case .archiveOnly:
            model.statusMessage = "Private event. Its originals stay out of the shared Buffer. Use Move to Private for any copies already there."
        case .buffer:
            model.statusMessage = "Shared event. Use Put on Buffer to move its originals into the shared Buffer."
        case nil:
            model.statusMessage = "This subevent now follows its parent event's storage setting."
        }
        Task { await refreshEvent(eventID) }
    }

    func renameEvent(_ eventID: UUID, name rawName: String, date: Date, policy: EventStoragePolicy?, parentEventID: UUID?) {
        renameRequest = nil
        guard let event = event(eventID) else { return }
        let validation = EventNamePolicy.validate(rawName)
        guard validation.isValid else {
            model.statusMessage = validation.errorMessage ?? "Choose a different event name."
            return
        }
        // The folders move with the name, and a job (or a queued move) has
        // absolute paths it worked out before the rename: it would recreate
        // the old folder and put files in it while the event points at the
        // new one. And a drive that is not there cannot have its folder
        // renamed, which would split the event from its files.
        guard !model.isBusy, !model.isStorageBenchmarkRunning, pendingMoves.isEmpty else {
            refuseMove("Rename \(eventTitle(event))", "A file job or a queued move is running. Rename \(eventTitle(event)) after it finishes — its folders move with the name.")
            return
        }
        let policiesInUse = Set(eventFamily(eventID).map { self.locations.resolvedPolicy(for: $0) })
        if let missing = EventStoragePolicy.allCases.first(where: { policiesInUse.contains($0) && !VolumeInfo.isAvailable(self.locations.driveRoot(for: $0)) }) {
            refuseMove(
                "Rename \(eventTitle(event))",
                "The drive holding \(self.locations.driveRoot(for: missing).path) isn't connected, so \(eventTitle(event)) was not renamed. Connect it first, so the folder and the name change together."
            )
            return
        }
        var renamed = event
        renamed.name = validation.normalizedName
        renamed.eventDate = Calendar.current.startOfDay(for: date)
        renamed.parentEventID = validParentEventID(parentEventID, for: eventID)
        renamed.storagePolicy = policy
        let locations = self.locations
        let fileManager = FileManager.default
        let oldResolved = locations.resolvedPolicy(for: event)
        var futureEvents = model.configuration.savedEvents
        if let index = futureEvents.firstIndex(where: { $0.id == eventID }) { futureEvents[index] = renamed }
        let newResolved = EventHierarchy.resolvedPolicy(of: renamed, in: futureEvents)

        var folderMoves: [(old: URL, new: URL, caseOnly: Bool)] = []
        for candidate in EventStoragePolicy.allCases {
            let old = locations.eventFolder(for: event, policy: candidate)
            let new = locations.eventFolder(for: renamed, policy: candidate)
            // "Beach day" → "Beach Day" is one folder to the volume but a
            // different name to the app: the folder is renamed in two steps
            // so the drive, the NAS and the board all spell it the same.
            let sameFolder = EventStorageLocations.pathKey(old.path) == EventStorageLocations.pathKey(new.path)
            let caseOnly = sameFolder && old.path != new.path
            guard fileManager.fileExists(atPath: old.path), !sameFolder || caseOnly else { continue }
            guard caseOnly || !fileManager.fileExists(atPath: new.path) else {
                model.statusMessage = "A folder named “\(new.lastPathComponent)” already exists. Choose another name or date."
                return
            }
            folderMoves.append((old, new, caseOnly))
        }

        var moved: [(URL, URL, Bool)] = []
        for (old, new, caseOnly) in folderMoves {
            do {
                if caseOnly {
                    try DriveMoveService().renameFolderChangingCase(from: old, to: new)
                } else {
                    try DriveMoveService().moveFolder(from: old, to: new)
                }
                moved.append((old, new, caseOnly))
            } catch {
                for (original, renamedFolder, wasCaseOnly) in moved.reversed() {
                    if wasCaseOnly {
                        try? DriveMoveService().renameFolderChangingCase(from: renamedFolder, to: original)
                    } else {
                        try? DriveMoveService().moveFolder(from: renamedFolder, to: original)
                    }
                }
                model.statusMessage = "Could not rename the event folder: \(error.localizedDescription)"
                return
            }
        }

        // Subevent folders move with the renamed parent, so their adopted
        // assignments need the same path rewrite.
        let touchedIDs = Set(EventHierarchy.descendants(of: eventID, in: model.configuration.savedEvents).map(\.id))
            .union([eventID])
        // Every board that draws these events' files — the event's own, its
        // subevents', and the family boards above it, before and after a
        // re-parent — holds tiles at the old folder names.
        let boardsBefore = Set(eventStacks.keys.filter { !scopeIDs($0).isDisjoint(with: touchedIDs) })
        model.updateConfiguration { configuration in
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].name = renamed.name
            configuration.savedEvents[index].eventDate = renamed.eventDate
            configuration.savedEvents[index].parentEventID = renamed.parentEventID
            configuration.savedEvents[index].storagePolicy = renamed.storagePolicy
            // Adopted assignments point straight at the old folder.
            for (old, new, _) in moved {
                let oldPrefix = old.standardizedFileURL.path + "/"
                for assignmentIndex in configuration.photoEventAssignments.indices
                where touchedIDs.contains(configuration.photoEventAssignments[assignmentIndex].eventID) {
                    let root = configuration.photoEventAssignments[assignmentIndex].sourceRootPath
                    if root.hasPrefix(oldPrefix) {
                        configuration.photoEventAssignments[assignmentIndex].sourceRootPath =
                            new.standardizedFileURL.path + "/" + root.dropFirst(oldPrefix.count)
                    }
                }
            }
        }
        // The NAS folder follows: one folder rename on the NAS, journaled
        // and queued now, applied by a NAS job as soon as the NAS is there
        // and idle. A connected NAS that has no folder for the event owes
        // nothing. Copies in the old archive layout keep their folder name.
        var nasNote = ""
        var nasLink: UUID?
        if let owed = NASMoveFollower.folderRename(from: event, to: renamed, locations: locations),
           !nasIsConnected || fileManager.fileExists(atPath: locations.nasRoot.appendingPathComponent(owed.from).path) {
            let link = UUID()
            nasLink = link
            let title = "Rename \(eventTitle(event)) on the NAS"
            // Journaled now, under an id the history's Undo of this rename
            // reverses — the batch is one small file, so it is written before
            // the rename is registered instead of racing an immediate Undo.
            let queued = Self.queueNASRenames(
                [owed], title: title, origin: .folderRename, moveJournalID: link,
                nasRoot: locations.nasRoot, journalFolder: journalFolder
            )
            noteNASRenamesQueued(queued)
            drainNASRenames()
            nasNote = nasIsConnected
                ? " The NAS folder is renamed to match next."
                : " The NAS folder will be renamed when the NAS is connected."
        }
        if VolumeInfo.isAvailable(locations.legacyArchiveEventFolder(for: event)),
           fileManager.fileExists(atPath: locations.legacyArchiveEventFolder(for: event).path) {
            nasNote += " Copies in the old NAS archive layout keep the old folder name."
        }
        model.statusMessage = "Renamed to \(eventTitle(renamed))." + nasNote
            + (newResolved == oldResolved ? ""
                : newResolved == .archiveOnly
                    ? " Its originals stay out of the shared Buffer. Use Move to Private for any copies already there."
                    : " It's a shared event now. Use Put on Buffer for copies still in Private.")
        let boardsAfter = Set(eventStacks.keys.filter { !scopeIDs($0).isDisjoint(with: touchedIDs) })
        for boardID in touchedIDs.union(boardsBefore).union(boardsAfter) {
            Task { await refreshEvent(boardID) }
        }
        if let after = self.event(eventID) {
            recordEventEditUndo(
                before: event, after: after,
                folderMoves: moved.map { UndoFolderMove(old: $0.0.standardizedFileURL.path, new: $0.1.standardizedFileURL.path, caseOnly: $0.2) },
                touchedEventIDs: touchedIDs,
                nasLink: nasLink
            )
        }
    }

    func discoverDriveEvents() {
        let configuration = model.configuration
        let locations = self.locations
        let gate = driveActivityGate
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .utility) { () -> ([DiscoveredDriveEvent], [DriveCameraFolder]) in
                var all: [DiscoveredDriveEvent] = []
                var legacy: [DriveCameraFolder] = []
                for (root, policy) in [(locations.bufferRoot, EventStoragePolicy.buffer), (locations.privateStagingRoot, .archiveOnly)] {
                    guard VolumeInfo.isAvailable(root),
                          gate.waitIfPaused(for: root, shouldStop: { Task.isCancelled }) else { continue }
                    all += (try? DriveEventDiscovery.discover(driveRoot: root, policy: policy, configuration: configuration)) ?? []
                    legacy += ((try? DriveEventDiscovery.cameraFolders(driveRoot: root)) ?? []).filter { $0.layout == .legacyCardCopy }
                }
                return (all, legacy)
            }.value
            self?.discoveredDriveEvents = found.0
            self?.legacyLayoutFolders = found.1
        }
    }

    func adoptDiscoveredDriveEvents() {
        let found = discoveredDriveEvents
        guard !found.isEmpty else { return }
        var summary = (createdEvents: 0, addedAssignments: 0)
        model.updateConfiguration { configuration in
            summary = DriveEventDiscovery.adopt(found, into: &configuration)
        }
        discoveredDriveEvents = []
        model.statusMessage = "Added \(summary.createdEvents) event(s) and \(summary.addedAssignments) file(s) already organized on the drive. No files moved."
    }

    // MARK: - Presence

    /// How many of an event's earliest files paint the first screen —
    /// enough tiles to fill a window before the rest of the build
    /// resolves behind them.
    nonisolated static let firstScreenFileLimit = 240
    /// A family this small is drawn whole on the first screen — laying it
    /// out costs less than the wait a partial screen would save. A test that
    /// wants the partial first screen sets this to 0.
    @ObservationIgnored var wholeBoardFirstScreenLimit = 4_000

    /// Three passes, ordered by what the board needs first.
    ///
    /// Pass one draws only the first screen of the grid — the earliest
    /// files of the event being opened — from the place the catalog
    /// already implies: that event's `Originals/<Camera>` folder joined with each
    /// assignment's relative path. That join is pure string work — no
    /// `standardizedFileURL`, no `resourceValues`, no per-file stat — so
    /// the first tiles never wait on the card, the other drive, or the
    /// NAS, and `eventStacks` is assigned as soon as the screen exists.
    ///
    /// Pass two resolves the rest of the family onto the same kind of
    /// implied path. A parent board includes its subevents, and each
    /// member's files join that member's own folder, not the parent's.
    /// It publishes twice: first a provisional grid stacked on whatever
    /// the capture-date cache already knows — every resolved file boards
    /// without waiting on a header read — then the dated grid once the
    /// remaining camera dates have been read. Both applies go through
    /// `applyEventBuild` — never `await task.value` here, which would
    /// escalate it to this context's priority and hold the spinner the
    /// way the old single pass did. Stacks that survive the merge keep
    /// the ids an open preview or a decoded tile is bound to.
    ///
    /// Pass three is the truthful four-place sweep, still on the same
    /// utility task so its corrections can never be overwritten by a
    /// late-running build. It scans every descendant with that
    /// descendant's own event, publishes each member's storage chips,
    /// and rebuilds the grid onto real paths only where files turned
    /// out to live somewhere else — still on the card, only on the NAS,
    /// or gone.
    ///
    /// A second open or a Refresh starts a new generation and cancels the
    /// stale pipeline; the generation guard keeps its results out either
    /// way.
    func refreshEvent(_ eventID: UUID) async {
        guard let event = event(eventID) else { return }
        refreshesInFlight += 1
        boardReadCount += 1
        defer { refreshesInFlight -= 1 }
        let generation = UUID()
        refreshGenerations[eventID] = generation
        presenceTasks[eventID]?.cancel()
        let locations = self.locations
        let policy = locations.resolvedPolicy(for: event)
        let cacheLoader = captureDateCacheLoader
        let burstSplits = model.configuration.burstSplits
        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
        let probe = presenceProbe
        let dateReadProbe = captureDateReadProbe
        let gate = driveActivityGate
        // The NAS listing the sidebar counts from, when it is fresh: the
        // sweep answers the NAS place from it instead of a stat per file.
        let archiveListing = nasPresence.boardListing()

        // The catalog state this pipeline proves itself against. A grid
        // that already reflects it — every build landed, no pending date
        // reads — only needs the sweep's verification, and a state change
        // that lands mid-pipeline (its revision is newer) drops the
        // pipeline's results instead of being overwritten by them.
        let revisionAtStart = model.catalogStateRevision
        let configurationRevisionAtStart = model.configurationRevision
        let connectivityRevisionAtStart = connectivityRevision
        // Held as the array the board already shows (copy on write) — walking
        // 15,000 stacks for their files happens off the main actor.
        let existingStacks = eventStacks[eventID]
        // An empty grid is an answer ("nothing reachable"), never a board
        // worth keeping: once a drive comes back it must rebuild.
        let gridIsCurrent = existingStacks?.isEmpty == false
            && (eventDatesRead.contains(eventID) || eventUnreadableAt[eventID] == connectivityRevisionAtStart)
            && eventGridRevisions[eventID] == revisionAtStart
            && eventBuildRemainders[eventID] == nil
            && eventDateReadRemainders[eventID] == nil

        // The board shows each direct subevent as its own section, so
        // the family is this event plus every descendant. Each member's
        // files resolve inside that member's folder.
        let members = [event] + EventHierarchy.descendants(of: eventID, in: model.configuration.savedEvents)
        let memberIDs = Set(members.map(\.id))
        var memberSubtrees: [UUID: Set<UUID>] = [:]
        for member in members {
            memberSubtrees[member.id] = scopeIDs(member.id).intersection(memberIDs)
        }
        let memberByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        let subtreesByMember = memberSubtrees
        // Sorting the catalog's rows into the family is 17,000 rows of work
        // at library scale — done on a background task, never here.
        let allAssignments = model.configuration.photoEventAssignments
        let memberOrder = members.map(\.id)
        let familyTask = Task.detached(priority: .userInitiated) { () -> (family: [PhotoEventAssignment], byEvent: [UUID: [PhotoEventAssignment]]) in
            let byEvent = Dictionary(grouping: allAssignments.filter { memberIDs.contains($0.eventID) }, by: \.eventID)
            return (memberOrder.flatMap { byEvent[$0] ?? [] }, byEvent)
        }
        eventsLoading.insert(eventID)
        defer {
            if refreshGenerations[eventID] == generation { eventsLoading.remove(eventID) }
        }

        // Reachability is asked in the background and never gates the
        // first screen: the mount table alone says which drives are up, so
        // the first tiles are on their way while every place root gets its
        // one bounded existence stat (a hung NAS share costs the timeout,
        // never a blank board). The answer is applied below, before the
        // build passes that depend on it.
        let mountedAll = mountedVolumesProvider?() ?? VolumeInfo.mountedVolumePaths()
        let timeout = placeResponseTimeout
        let responseProbe = placeResponseProbe
        let reachabilityCheck = Task.detached(priority: .userInitiated) {
            await EventReachability.check(
                places: EventReachability.places(members: members, assignments: await familyTask.value.family, locations: locations),
                mountedVolumes: mountedAll,
                timeout: timeout,
                probe: responseProbe
            )
        }

        let mountTableAvailable = Dictionary(uniqueKeysWithValues: members.map { member in
            (member.id, VolumeInfo.isAvailable(locations.driveRoot(for: locations.resolvedPolicy(for: member)), mountedVolumes: mountedAll))
        })
        let implied = ImpliedPaths(locations: locations, members: memberByID, fallbackOwner: event, custom: eventPathResolver)
        let wholeLimit = wholeBoardFirstScreenLimit

        // The first screen is a loading affordance — it paints only into
        // an empty grid, and only from the mount table: no per-file stat,
        // no header read, no wait on the NAS. It is the earliest files of
        // the whole family the board will show, so a parent event with no
        // files of its own still opens on real tiles; a family small enough
        // to lay out in a few milliseconds is drawn whole. Where a member's
        // drive is not mounted, its files are drawn at their NAS mirror
        // path — the layout is deterministic, so nothing needs a stat to
        // know where a file would be — and with nothing mounted at all the
        // grid is still drawn, its tiles blank until a drive or the NAS
        // answers. An event that already has a board
        // keeps every tile it has while the pipeline re-verifies; it never
        // shrinks back to the first screen.
        var firstPaint: (grid: EventImpliedGrid, familyCount: Int)?
        if eventStacks[eventID]?.isEmpty != false {
            firstPaint = await Task.detached(priority: .userInitiated) { () -> (EventImpliedGrid, Int) in
                let family = await familyTask.value.family
                let limit = family.count <= wholeLimit ? Int.max : Self.firstScreenFileLimit
                // Only the earliest files are resolved — a resolve that costs
                // anything is paid for the first screen alone.
                let earliest = family
                    .sorted { ($0.modifiedAt, $0.relativePath) < ($1.modifiedAt, $1.relativePath) }
                    .prefix(limit)
                let files = earliest.compactMap { assignment -> OrganizeFile? in
                    guard let path = implied.path(for: assignment, driveUp: mountTableAvailable[assignment.eventID] == true) else { return nil }
                    return OrganizeFile(literalPath: path, size: assignment.fileSize, modifiedAt: assignment.modifiedAt)
                }
                // Cache hits only — a miss is "no camera date" here, never a
                // header read, so nothing on this pass can wait on a drive.
                let items = OrganizeScanner.items(for: files, cache: cacheLoader.cache(), readMissingCaptureDates: false, pauseGate: gate).items
                return (
                    EventImpliedGrid(files: files, stacks: OrganizeStacker.stacks(for: items, splits: burstSplits)),
                    family.count
                )
            }.value
        }

        guard refreshGenerations[eventID] == generation else { return }
        if let firstPaint, !firstPaint.grid.stacks.isEmpty {
            eventStacks[eventID] = firstPaint.grid.stacks.carryingIDs(from: eventStacks[eventID] ?? [])
            notePublishedWhileMovePending(eventID)
            eventGridRevisions[eventID] = revisionAtStart
            let remaining = firstPaint.familyCount - firstPaint.grid.files.count
            eventBuildRemainders[eventID] = remaining > 0 ? remaining : nil
        } else if eventStacks[eventID] == nil {
            eventBuildRemainders[eventID] = nil
        }
        eventDateReadRemainders[eventID] = nil

        // The rest of the family, then the four-place sweep, is one
        // pipeline that applies itself back on this actor instead of being
        // awaited here. The build runs at user-initiated priority — the
        // owner is looking at a partial board and waiting for the rest —
        // and the sweep drops to utility on its own task, so file stats
        // never compete with scrolling and tile decode. The whole implied
        // grid is published before the reachability answer is awaited:
        // where each file is drawn depends only on the mount table, so the
        // answer gates just the passes that read or stat files (capture
        // dates, the presence sweep), never the board itself. Building
        // before the sweep keeps `finishPresenceSweep`'s path comparison
        // honest.
        let pipeline = Task.detached(priority: .userInitiated) { [self] in
            var built: EventImpliedGrid?
            var canReadHeaders = true
            // What the board shows, as far as this pipeline has put it there.
            var published = existingStacks
            let (familyAssignments, assignmentsByEvent) = await familyTask.value
            let cache = cacheLoader.cache()
            var files: [OrganizeFile] = []
            if !gridIsCurrent {
                files.reserveCapacity(familyAssignments.count)
                for assignment in familyAssignments where !Task.isCancelled {
                    guard let path = implied.path(for: assignment, driveUp: mountTableAvailable[assignment.eventID] == true) else { continue }
                    files.append(OrganizeFile(literalPath: path, size: assignment.fileSize, modifiedAt: assignment.modifiedAt))
                }
                if !Task.isCancelled, !files.isEmpty {
                    // The provisional grid stacks on whatever the cache already
                    // knows — a miss is "no camera date" here, never a header
                    // read — so every file boards at once instead of waiting
                    // out the remaining capture-date reads. The count of those
                    // reads rides the apply so the board can say dates are
                    // still coming without saying files are.
                    let undated = OrganizeScanner.items(for: files, cache: cache, readMissingCaptureDates: false, pauseGate: gate)
                    let provisional = OrganizeStacker.stacks(for: undated.items, splits: burstSplits)
                    // A refresh that rebuilds the very grid the board already
                    // shows publishes nothing: the comparison runs here, off
                    // the main actor, instead of a 15,000-stack restack there.
                    await applyEventBuild(
                        eventID: eventID,
                        generation: generation,
                        revision: revisionAtStart,
                        build: EventImpliedGrid(files: files, stacks: provisional),
                        pendingDateReads: undated.missingCaptureDates,
                        unchanged: provisional == published
                    )
                    published = provisional
                }
            }

            // Now the reachability answer, which gates the passes that stat or
            // read files. A volume that did not answer is treated as unmounted
            // for the rest of this refresh — nothing below stats a file on it.
            // Nothing offline is terminal: the board is always the catalog's
            // grid, and a place that is away only leaves its tiles blank and
            // its storage chip saying so.
            let report = await reachabilityCheck.value
            await applyReachability(report, for: eventID, generation: generation)
            let mounted = mountedAll.subtracting(report.unresponsiveVolumes)
            let driveAvailableByMember = Dictionary(uniqueKeysWithValues: members.map { member in
                (member.id, VolumeInfo.isAvailable(locations.driveRoot(for: locations.resolvedPolicy(for: member)), mountedVolumes: mounted))
            })
            // Header reads only go to places that answered: a file drawn at the
            // NAS mirror of a share that is away, or hung, is never read — and
            // neither is a drive copy on a volume that did not answer.
            let nasReadable = VolumeInfo.isAvailable(locations.nasRoot, mountedVolumes: mounted)
                && report.states.first { $0.key.role == .nas }.map { $0.value == .reachable } != false
            for member in members where familyAssignments.contains(where: { $0.eventID == member.id }) {
                let drawnOnDrive = mountTableAvailable[member.id] == true
                if drawnOnDrive ? driveAvailableByMember[member.id] != true : !nasReadable { canReadHeaders = false }
            }
            if !gridIsCurrent {
                if !Task.isCancelled, !files.isEmpty {
                    // The dated pass the provisional grid stood in for. The
                    // read seam attaches only here so a parked read always
                    // means "after the provisional publish". With any of the
                    // files' places away there is nothing to read from: the
                    // grid stands as drawn, and the next refresh once the
                    // place is back reads the dates.
                    let previousProbe = cache.timestampProbe
                    cache.timestampProbe = dateReadProbe
                    let dated = OrganizeScanner.items(for: files, cache: cache, readMissingCaptureDates: canReadHeaders, pauseGate: gate)
                    cache.timestampProbe = previousProbe
                    built = EventImpliedGrid(
                        files: files,
                        stacks: OrganizeStacker.stacks(for: dated.items, splits: burstSplits)
                    )
                }
                await applyEventBuild(
                    eventID: eventID,
                    generation: generation,
                    revision: revisionAtStart,
                    build: built,
                    datesRead: canReadHeaders,
                    connectivity: connectivityRevisionAtStart,
                    unchanged: built.map { $0.stacks == published } ?? false
                )
            }

            // The sweep. Its own utility task, joined through a continuation
            // (never `task.value`, which would lift it to this task's
            // priority); cancelling the pipeline cancels it.
            let sweep: @Sendable () -> EventRefreshOutput? = {
                var memberSummaries: [UUID: EventPresenceSummary] = [:]
                // What Sync to NAS verified under this family's NAS folder —
                // one catalog read, so presence can say "verified <date>".
                let nasVerified = NASSyncStore.verifiedDates(
                    catalogURL: catalogURL,
                    nasRoot: locations.nasRoot.path,
                    prefixes: [locations.layout(for: event, deviceID: nil).mirrorEventFolderPath]
                )
                for member in members {
                    guard !Task.isCancelled else { return nil }
                    guard let memberSummary = EventPresenceScanner.scan(
                        event: member,
                        assignments: assignmentsByEvent[member.id] ?? [],
                        locations: locations,
                        mountedVolumes: mounted,
                        probe: probe,
                        pauseGate: gate,
                        nasVerified: nasVerified,
                        archiveListing: archiveListing
                    ) else { return nil }
                    memberSummaries[member.id] = memberSummary
                }
                let assets = members.flatMap { memberSummaries[$0.id]?.assets ?? [] }
                var scopedSummaries: [UUID: EventPresenceSummary] = [:]
                for member in members {
                    let subtree = subtreesByMember[member.id] ?? [member.id]
                    scopedSummaries[member.id] = EventPresenceSummary(
                        eventID: member.id,
                        policy: memberSummaries[member.id]?.policy ?? locations.resolvedPolicy(for: member),
                        assets: members.filter { subtree.contains($0.id) }.flatMap { memberSummaries[$0.id]?.assets ?? [] },
                        checkedAt: Date()
                    )
                }
                let summary = scopedSummaries[eventID] ?? EventPresenceSummary(eventID: eventID, policy: policy, assets: assets, checkedAt: Date())
                var sweptFiles: [OrganizeFile] = []
                var byPath: [String: EventAssetPresence] = [:]
                for asset in assets {
                    guard let path = asset.bestLocalPath else {
                        // Not found anywhere it could be read — but a place
                        // that is away cannot say the file is gone. The
                        // catalog still has it, so it stays on the board at
                        // its NAS mirror path (the permanent library), its
                        // tile blank until a place answers. Only files every
                        // reachable place says are missing leave the grid.
                        guard asset.drive == .unavailable || asset.otherDrive == .unavailable || asset.archive == .unavailable,
                              let mirror = implied.path(for: asset.assignment, driveUp: false) else { continue }
                        sweptFiles.append(OrganizeFile(literalPath: mirror, size: asset.assignment.fileSize, modifiedAt: asset.assignment.modifiedAt))
                        byPath[mirror.lowercased()] = asset
                        continue
                    }
                    // `bestLocalPath` came out of `standardizedFileURL` in
                    // the sweep — re-standardizing it per file would be a
                    // realpath walk for an identical result, so the literal
                    // initializer + lowercase produce the same keys.
                    sweptFiles.append(OrganizeFile(literalPath: path, size: asset.assignment.fileSize, modifiedAt: asset.assignment.modifiedAt))
                    byPath[path.lowercased()] = asset
                }
                var immich: [String: ImmichCatalogStatus] = [:]
                let inspector = CatalogInspector(url: catalogURL)
                for member in members {
                    immich.merge((try? inspector.immichStatuses(eventID: member.id)) ?? [:]) { current, _ in current }
                }
                return EventRefreshOutput(
                    summary: summary,
                    memberSummaries: scopedSummaries,
                    files: sweptFiles,
                    assetsByPathKey: byPath,
                    immich: immich
                )
            }
            let sweepTask = SweepTaskHandle()
            let output: EventRefreshOutput? = await withTaskCancellationHandler {
                await withCheckedContinuation { (cc: CheckedContinuation<EventRefreshOutput?, Never>) in
                    sweepTask.set(Task.detached(priority: .utility) { cc.resume(returning: sweep()) })
                }
            } onCancel: {
                sweepTask.cancel()
            }
            await finishPresenceSweep(
                eventID: eventID,
                generation: generation,
                revision: revisionAtStart,
                // A reused grid verifies against what it shows: the sweep
                // restacks only when the files on disk are not the files
                // on the board.
                builtFiles: built?.files ?? existingStacks?.flatMap(\.files),
                output: output
            )
        }
        presenceTasks[eventID] = pipeline
        await withCheckedContinuation { (cc: CheckedContinuation<Void, Never>) in
            presenceWaiters[eventID, default: []].append((generation, cc))
        }
        if refreshGenerations[eventID] == generation, eventStacks[eventID]?.isEmpty == false, presence[eventID] != nil {
            boardVerifications[eventID] = BoardVerification(
                catalog: revisionAtStart,
                configuration: configurationRevisionAtStart,
                connectivity: connectivityRevisionAtStart,
                at: Date()
            )
        }
    }

    // MARK: Opening a board that is already loaded

    /// What a completed refresh proved: the board on screen matches the
    /// catalog, the configuration and the mounted drives as they were then.
    struct BoardVerification {
        var catalog: Int
        var configuration: Int
        var connectivity: Int
        var at: Date
    }

    @ObservationIgnored private(set) var boardVerifications: [UUID: BoardVerification] = [:]
    /// How long a verified board is trusted before opening it re-checks in
    /// the background. Anything that actually changes the data (catalog,
    /// configuration, a mount) re-checks at once regardless.
    @ObservationIgnored var boardFreshnessInterval: TimeInterval = 120

    /// True when re-selecting the board needs no work: its grid is complete,
    /// its presence is known, and nothing it depends on has changed since
    /// the refresh that built it.
    func isBoardFresh(_ eventID: UUID) -> Bool {
        guard let proof = boardVerifications[eventID],
              proof.catalog == model.catalogStateRevision,
              proof.configuration == model.configurationRevision,
              proof.connectivity == connectivityRevision,
              Date().timeIntervalSince(proof.at) < boardFreshnessInterval,
              eventStacks[eventID]?.isEmpty == false,
              eventBuildRemainders[eventID] == nil,
              eventDateReadRemainders[eventID] == nil,
              presence[eventID] != nil,
              !eventsLoading.contains(eventID) else { return false }
        return true
    }

    /// What an event board runs when it appears. A board that was already
    /// loaded and has not changed is left alone — selecting it again never
    /// re-stacks or re-sweeps it. Anything else refreshes behind the tiles
    /// already on screen.
    func refreshEventIfStale(_ eventID: UUID) async {
        guard !isBoardFresh(eventID) else { return }
        await refreshEvent(eventID)
    }

    /// True while the board has no tiles yet but files it owns are on their
    /// way: the catalog says it has files and a refresh is still running. The
    /// board shows placeholders then. It never says "not connected" — the
    /// Buffer is a buffer and is not always plugged in, and the grid is the
    /// catalog's whether or not any place is mounted.
    func eventBoardShowsPlaceholders(_ eventID: UUID) -> Bool {
        guard eventsLoading.contains(eventID), eventStacks[eventID]?.isEmpty != false else { return false }
        return assignmentCount(for: eventID) > 0
    }

    /// `root` + `relativePath` as a standardized-form path string — the
    /// board's path resolver. `appending(path:directoryHint:)` never asks the
    /// filesystem whether the result is a directory, which
    /// `appendingPathComponent(_:)` does for every call.
    nonisolated static func resolvedPath(root: URL, relativePath: String) -> String {
        root.appending(path: relativePath, directoryHint: .notDirectory).path
    }

    /// Main-actor landing point for the reachability answer. A stale
    /// generation drops it.
    private func applyReachability(_ report: EventReachabilityReport, for eventID: UUID, generation: UUID) {
        guard refreshGenerations[eventID] == generation else { return }
        eventReachability[eventID] = report.offlinePlaces.isEmpty ? nil : report
    }

    /// Main-actor landing point for the deferred build: the full implied
    /// grid replaces the first screen, carrying the stack ids an open
    /// preview or a decoded tile is bound to wherever the same files
    /// land together again. `pendingDateReads` is how many cache-miss
    /// capture-date reads the dated pass still owes — the provisional
    /// grid carries it so the board can say dates are still coming, and
    /// the dated grid lands with zero to clear it. A stale generation
    /// drops the build instead.
    private func applyEventBuild(
        eventID: UUID,
        generation: UUID,
        revision: Int,
        build: EventImpliedGrid?,
        pendingDateReads: Int = 0,
        datesRead: Bool = false,
        connectivity: Int? = nil,
        unchanged: Bool = false
    ) {
        guard refreshGenerations[eventID] == generation else { return }
        // A mutation that landed after the pipeline started already
        // patched the open grid itself — this older build must not
        // overwrite it.
        guard (eventGridRevisions[eventID] ?? -1) <= revision else { return }
        guard let build else { return }
        if !unchanged {
            eventStacks[eventID] = build.stacks.carryingIDs(from: eventStacks[eventID] ?? [])
            notePublishedWhileMovePending(eventID)
        }
        eventGridRevisions[eventID] = revision
        if datesRead {
            eventDatesRead.insert(eventID)
            eventUnreadableAt[eventID] = nil
        } else if pendingDateReads == 0 {
            eventDatesRead.remove(eventID)
            // Built with its files' places away: current until a mount changes.
            eventUnreadableAt[eventID] = connectivity
        }
        eventBuildRemainders[eventID] = nil
        eventDateReadRemainders[eventID] = pendingDateReads > 0 ? pendingDateReads : nil
        if pendingDateReads == 0 { refreshEditTags(for: eventID) }
    }

    /// Main-actor landing point for the utility-priority sweep. Publishes
    /// the storage chips and badge index, rebuilds the grid only when the
    /// truthful paths differ from what the implied build drew, and wakes
    /// the `refreshEvent` calls waiting on this pass. Stale generations
    /// only resume their waiters — their results are dropped.
    private func finishPresenceSweep(
        eventID: UUID,
        generation: UUID,
        revision: Int,
        builtFiles: [OrganizeFile]?,
        output: EventRefreshOutput?
    ) async {
        defer { resumePresenceWaiters(for: eventID, appliedGeneration: generation) }
        // Runs before the waiters resume. The current generation always
        // leaves the board a grid: when nothing is on disk and nothing was
        // drawn (every place offline or empty), pass one and the build both
        // skipped and an empty sweep equals an empty build, so no path
        // below assigns one — and the board sat on "Loading…" forever. An
        // empty grid is the terminal answer; the board turns it into "not
        // connected" or "not reachable".
        defer {
            if refreshGenerations[eventID] == generation, eventStacks[eventID] == nil {
                eventStacks[eventID] = []
            }
        }
        guard refreshGenerations[eventID] == generation else { return }
        presenceTasks[eventID] = nil
        // This generation's pipeline is done — build landed or was
        // dropped, sweep landed — so nothing is still coming.
        eventBuildRemainders[eventID] = nil
        eventDateReadRemainders[eventID] = nil
        // A mutation that landed after the pipeline started already
        // patched the open grid — this older sweep must not restack over
        // it. Presence rows are refreshed by the next refresh; dropping
        // them here keeps stale data out rather than over new.
        guard (eventGridRevisions[eventID] ?? -1) <= revision else {
            // The patch could not know what this sweep would have found, and
            // the build that ran before it may have drawn files at the paths
            // the catalog implies (a card's photos, say) rather than where
            // they are. Read the board again from the state it is in now,
            // instead of leaving it as drawn.
            Task { await refreshEvent(eventID) }
            return
        }
        guard let output else { return }

        eventAssetsByPathKey[eventID] = output.assetsByPathKey
        presence[eventID] = output.summary
        for (memberID, memberSummary) in output.memberSummaries {
            presence[memberID] = memberSummary
        }
        eventImmichStatuses[eventID] = output.immich
        // Order does not matter — the baseline for a reused grid is the
        // board's own files in stack order — but how many times each file is
        // drawn does: only "which files are on disk, once each" decides
        // whether a restack is owed, so a tile drawn twice is put right too.
        guard output.files.map(\.pathKey).sorted() != (builtFiles ?? []).map(\.pathKey).sorted() else { return }

        // Files resolved somewhere other than the implied Originals path —
        // restack onto the real ones. Continuation, not `task.value`, so
        // the rebuild keeps its utility priority.
        let cache = captureDateCache
        let splits = model.configuration.burstSplits
        let files = output.files
        let rebuilt = await withCheckedContinuation { (cc: CheckedContinuation<[OrganizeStack], Never>) in
            Task.detached(priority: .utility) {
                cc.resume(returning: OrganizeStacker.stacks(
                    for: OrganizeScanner.items(for: files, cache: cache, pauseGate: self.driveActivityGate).items,
                    splits: splits
                ))
            }
        }
        guard refreshGenerations[eventID] == generation else { return }
        // A change that landed while the stacks were being rebuilt patched the
        // board itself; the rebuild is from before it. Read the board again.
        guard (eventGridRevisions[eventID] ?? -1) <= revision else {
            Task { await refreshEvent(eventID) }
            return
        }
        eventStacks[eventID] = rebuilt.carryingIDs(from: eventStacks[eventID] ?? [])
        notePublishedWhileMovePending(eventID)
        eventGridRevisions[eventID] = revision
        refreshEditTags(for: eventID)
    }

    /// A board was rebuilt from the catalog while a clicked move had not
    /// landed: the rebuild drew the files where the catalog still says they
    /// are, undoing the tiles the click moved. The move remembers the board,
    /// and reads it again once it lands.
    private func notePublishedWhileMovePending(_ eventID: UUID) {
        guard !pendingMoves.isEmpty else { return }
        let scope = scopeIDs(eventID)
        for index in pendingMoves.indices where !pendingMoves[index].isLanded {
            let move = pendingMoves[index]
            if !scope.isDisjoint(with: move.sourceIDs.union([move.to.id])) { pendingMoves[index].truthBoards.append(eventID) }
        }
    }

    /// Wakes refresh waiters whose sweep just landed, plus every waiter
    /// left over from a stale generation — a stale pass has already been
    /// dropped, so it must not keep waiting for the newer one.
    private func resumePresenceWaiters(for eventID: UUID, appliedGeneration: UUID) {
        let current = refreshGenerations[eventID]
        var pending = presenceWaiters[eventID] ?? []
        pending.removeAll { generation, cc in
            guard generation == appliedGeneration || generation != current else { return false }
            cc.resume()
            return true
        }
        presenceWaiters[eventID] = pending.isEmpty ? nil : pending
    }

    // MARK: - Apply (put originals where their event keeps them)

    func prepareApply(sourceLocationID: UUID) {
        guard let location = location(sourceLocationID), let result = sources[sourceLocationID]?.result else { return }
        let eventIDs = Set(result.items.flatMap(\.files).compactMap { assignment(for: $0)?.eventID })
        prepareApply(eventIDs: Array(eventIDs), title: "Apply sorting from \(location.name)", onlyUnder: result.rootPath)
    }

    func prepareApply(eventIDs: [UUID], title: String, onlyUnder root: String? = nil) {
        let events = eventIDs.compactMap(event)
        guard !events.isEmpty else {
            model.statusMessage = "Sort some photos into an event first."
            return
        }
        let configuration = model.configuration
        let locations = self.locations
        let unsortedRoots = unsortedLocations.map {
            URL(fileURLWithPath: DashboardModel.expandedPath($0.path), isDirectory: true).standardizedFileURL
        }
        let gate = driveActivityGate
        model.statusMessage = "Checking where every sorted file is…"
        Task { @MainActor [weak self] in
            let plan = await Task.detached(priority: .userInitiated) {
                Self.buildApplyPlan(
                    events: events,
                    configuration: configuration,
                    locations: locations,
                    onlyUnder: root,
                    title: title,
                    unsortedRoots: unsortedRoots,
                    pauseGate: gate
                )
            }.value
            guard let self else { return }
            noteApplyCollisions(plan, events: events.map(\.id))
            if plan.isEmpty && !plan.hasCollisions {
                let unavailable = plan.groups.reduce(0) { $0 + $1.unavailable }
                model.statusMessage = unavailable > 0
                    ? "\(unavailable) file(s) are on a disconnected drive. Connect it and try again."
                    : "Nothing to move. Every sorted file is already where its event keeps it."
                return
            }
            model.statusMessage = plan.isEmpty
                ? ApplyStatusWording.collisionNote(for: plan) ?? "Review the plan."
                : "Review the plan, then press Apply."
            pendingApplyPlan = plan
        }
    }

    /// Remembers which sorted files a plan found already in their event
    /// (identical copies) or blocked by a same-name file, so the unsorted
    /// board stops calling them "nothing moves until you Apply".
    func noteApplyCollisions(_ plan: OrganizeApplyPlan, events: [UUID]) {
        for eventID in events {
            applyDuplicateSourceKeys[eventID] = nil
            applyConflictSourceKeys[eventID] = nil
        }
        for group in plan.groups {
            let duplicates = Set(group.duplicates.map { EventStorageLocations.pathKey($0.move.sourcePath) })
            let conflicts = Set(group.conflicts.map { EventStorageLocations.pathKey($0.move.sourcePath) })
            applyDuplicateSourceKeys[group.event.id] = duplicates.isEmpty ? nil : duplicates
            applyConflictSourceKeys[group.event.id] = conflicts.isEmpty ? nil : conflicts
        }
    }

    nonisolated static func buildApplyPlan(
        events: [SavedCameraEvent],
        configuration: AppConfiguration,
        locations: EventStorageLocations,
        onlyUnder root: String?,
        title: String,
        unsortedRoots: [URL],
        pauseGate: DriveActivityGate? = nil
    ) -> OrganizeApplyPlan {
        let mounted = VolumeInfo.mountedVolumePaths()
        let rootPrefix = root.map { EventStorageLocations.pathKey($0) + "/" }
        var sameVolumeCache: [String: Bool] = [:]
        var groups: [OrganizeApplyPlan.EventGroup] = []

        for event in events {
            let policy = locations.resolvedPolicy(for: event)
            let driveRoot = locations.driveRoot(for: policy)
            let assignments = configuration.photoEventAssignments.filter { $0.eventID == event.id }
            guard let summary = EventPresenceScanner.scan(event: event, assignments: assignments, locations: locations, mountedVolumes: mounted, pauseGate: pauseGate) else { continue }
            var candidates: [ApplyMoveCandidate] = []
            var copies: [String: OrganizeApplyPlan.CopyBatch] = [:]
            var destinationRoots: [String: String] = [:]
            var standardizedSourceRoots: [String: String] = [:]
            var alreadyThere = 0
            var unavailable = 0
            var copyBytes: Int64 = 0

            func isSameVolume(_ path: String) -> Bool {
                let folder = (path as NSString).deletingLastPathComponent
                if let cached = sameVolumeCache[folder] { return cached }
                let same = VolumeInfo.isSameVolume(URL(fileURLWithPath: folder), driveRoot, mountedVolumes: mounted)
                sameVolumeCache[folder] = same
                return same
            }

            for asset in summary.assets {
                if let rootPrefix {
                    // `sourcePath` came out of the sweep already
                    // standardized — a lowercase is the same key `pathKey`
                    // would produce, without another realpath walk.
                    guard let source = asset.sourcePath, source.lowercased().hasPrefix(rootPrefix) else { continue }
                }
                guard let drivePath = asset.drivePath else { continue }
                let size = asset.assignment.fileSize
                switch asset.drive {
                case .present:
                    // A same-size file is already in the event. If the
                    // sorted file is still sitting in a folder on the same
                    // drive, that copy is either a spare duplicate or a
                    // different photo with the same name — the collision
                    // check below decides. Card sources on another drive
                    // keep their originals by design and stay "in place".
                    if asset.source == .present, !asset.sourceIsDriveCopy,
                       let sourcePath = asset.sourcePath, isSameVolume(sourcePath) {
                        candidates.append(ApplyMoveCandidate(
                            move: DriveMove(sourcePath: sourcePath, destinationPath: drivePath, byteCount: size),
                            assignment: asset.assignment
                        ))
                    } else {
                        alreadyThere += 1
                    }
                    continue
                case .unavailable:
                    unavailable += 1
                    continue
                default:
                    break
                }
                if asset.otherDrive == .present, let other = asset.otherDrivePath {
                    candidates.append(ApplyMoveCandidate(
                        move: DriveMove(sourcePath: other, destinationPath: drivePath, byteCount: size),
                        assignment: asset.assignment
                    ))
                    continue
                }
                guard asset.source == .present, !asset.sourceIsDriveCopy, let sourcePath = asset.sourcePath else {
                    if asset.source == .unavailable { unavailable += 1 }
                    continue
                }
                if isSameVolume(sourcePath) {
                    candidates.append(ApplyMoveCandidate(
                        move: DriveMove(sourcePath: sourcePath, destinationPath: drivePath, byteCount: size),
                        assignment: asset.assignment
                    ))
                } else {
                    // Both roots depend only on the event/device/root
                    // string — standardizing per file paid realpath for
                    // every asset, so they are memoized per event.
                    let destinationRoot = destinationRoots[asset.assignment.deviceID ?? ""] ?? {
                        let built = locations.originalsRoot(for: event, deviceID: asset.assignment.deviceID, policy: policy).path
                        destinationRoots[asset.assignment.deviceID ?? ""] = built
                        return built
                    }()
                    let sourceRoot = standardizedSourceRoots[asset.assignment.sourceRootPath] ?? {
                        let built = URL(fileURLWithPath: NSString(string: asset.assignment.sourceRootPath).expandingTildeInPath, isDirectory: true)
                            .standardizedFileURL.path
                        standardizedSourceRoots[asset.assignment.sourceRootPath] = built
                        return built
                    }()
                    let key = sourceRoot + "\u{0}" + destinationRoot
                    copies[key, default: OrganizeApplyPlan.CopyBatch(
                        sourceRoot: sourceRoot,
                        destinationRoot: destinationRoot,
                        deviceID: asset.assignment.deviceID ?? locations.fallbackDeviceID,
                        files: []
                    )].files.append(FileRecord(
                        path: asset.assignment.relativePath,
                        size: size,
                        modifiedAt: asset.assignment.modifiedAt
                    ))
                    copyBytes += size
                }
            }

            // One lstat per planned rename; a streamed checksum only where a
            // same-size file already holds the name. A taken destination
            // never reaches the rename job, so Apply cannot silently no-op.
            let partition = ApplyCollisionCheck.partition(candidates)
            let moves = partition.clear.map(\.move)
            let bytes = copyBytes + moves.reduce(Int64(0)) { $0 + $1.byteCount }

            guard !moves.isEmpty || !copies.isEmpty || unavailable > 0
                || !partition.duplicates.isEmpty || !partition.conflicts.isEmpty else { continue }
            groups.append(OrganizeApplyPlan.EventGroup(
                event: event,
                moves: moves,
                copies: copies.values.sorted { $0.sourceRoot < $1.sourceRoot },
                alreadyThere: alreadyThere,
                unavailable: unavailable,
                destinationFolder: locations.eventFolder(for: event, policy: policy).path,
                isPrivate: policy == .archiveOnly,
                byteCount: bytes,
                duplicates: partition.duplicates,
                conflicts: partition.conflicts
            ))
        }

        return OrganizeApplyPlan(
            title: title,
            groups: groups.sorted { $0.event.eventDate < $1.event.eventDate },
            pruneBoundaries: unsortedRoots + [locations.bufferRoot, locations.privateStagingRoot]
        )
    }

    func performApply(_ plan: OrganizeApplyPlan) {
        performApply(plan, thenTrash: [])
    }

    /// `thenTrash`: identical copies whose Trash confirmation opens once the
    /// moves have landed (the job would refuse a Trash while it runs).
    private func performApply(_ plan: OrganizeApplyPlan, thenTrash trash: [ApplyCollision]) {
        let moves = plan.groups.flatMap(\.moves)
        // The renames need the job gate. Refused here, the plan stays open to
        // Apply again — it is not dropped, and no copy starts without them.
        if !moves.isEmpty, model.isBusy || model.isStorageBenchmarkRunning {
            refuseMove(plan.title, "Another file job is already running. Wait for it to finish, then Apply again — nothing was moved.")
            return
        }
        pendingApplyPlan = nil
        runningApply = nil
        let copies = plan.groups.flatMap { group in group.copies.map { (group.event, $0) } }
        let journalFolder = self.journalFolder
        let boundaries = plan.pruneBoundaries
        let title = plan.title
        let affectedEvents = plan.groups.map(\.event.id)
        let locations = self.locations
        let queuedRenames = NASQueuedRenames()

        if !moves.isEmpty {
            let jobID = model.runBackgroundJob(
                action: .organize,
                runningNote: "Moving \(moves.count) file(s) into their events",
                logTitle: title,
                logDetail: "Renamed files on the same drive. No file bytes were rewritten and nothing was replaced.",
                operation: { progress in
                    let report = try DriveMoveService().apply(
                        moves,
                        title: title,
                        journalFolder: journalFolder,
                        pruneBoundaries: boundaries
                    ) { update in
                        progress(DashboardModel.jobUpdate(from: update, notePrefix: "Organizing", command: ""))
                    }
                    // Files that already sat in an event folder (a drive
                    // move between events) owe the NAS the same rename;
                    // files coming from Unsorted owe nothing.
                    queuedRenames.add(Self.queueNASRenames(
                        NASMoveFollower.renames(forMoves: report.moved, locations: locations),
                        title: title, origin: .move, moveJournalID: report.journalID,
                        nasRoot: locations.nasRoot, journalFolder: journalFolder
                    ))
                    return report
                },
                completion: { [weak self] report in
                    self?.noteNASRenamesQueued(queuedRenames.count)
                    self?.recordJournalUndo(title: title, report: report)
                    self?.didMove(report: report, events: affectedEvents)
                    if !trash.isEmpty { self?.requestTrashApplyDuplicates(trash) }
                    return ApplyStatusWording.afterApply(
                        movedCount: report.moved.count,
                        movedBytes: report.movedBytes,
                        skipped: report.skipped,
                        plan: plan
                    )
                }
            )
            if let jobID {
                runningApply = RunningApplyPlan(jobID: jobID, title: plan.title, groups: plan.groups)
            }
        }
        for (event, batch) in copies {
            model.enqueueTransfer(
                files: batch.files,
                sourcePath: batch.sourceRoot,
                destinationPath: batch.destinationRoot,
                eventID: event.id,
                eventName: locations.displayName(for: event),
                deviceID: batch.deviceID
            )
        }
        if moves.isEmpty && !copies.isEmpty {
            model.statusMessage = "Copying \(plan.copyCount) file(s) with checksum verification. Originals stay on the card."
                + (ApplyStatusWording.collisionNote(for: plan).map { " " + $0 } ?? "")
        }
    }

    // MARK: - Apply collisions (identical copies and taken names)

    /// "Move Duplicate to Trash" from the Apply sheet: the spare copies
    /// still in an unsorted folder go through the ordinary organizer Trash
    /// confirmation and the recoverable `_Trash` rename — never a delete.
    /// The assignment stays when it is the event's only record of the
    /// photo (it then describes the copy already in the event, exactly as
    /// after an Apply); it is dropped when another assignment in the event
    /// already points at that file.
    func requestTrashApplyDuplicates(_ plan: OrganizeApplyPlan) {
        requestTrashApplyDuplicates(plan.groups.flatMap(\.duplicates))
    }

    /// The chosen identical copies only (the sheet's per-row "Trash
    /// Duplicate"), through the same confirmation.
    func requestTrashApplyDuplicates(_ duplicates: [ApplyCollision]) {
        pendingApplyPlan = nil
        refreshIndexIfNeeded()
        let duplicates = duplicates.filter { $0.kind == .identicalCopy }
        guard !duplicates.isEmpty else { return }
        let roots = unsortedLocations.map { location in
            (location, EventStorageLocations.pathKey(DashboardModel.expandedPath(location.path)) + "/")
        }
        var byLocation: [UUID: [ApplyCollision]] = [:]
        var order: [UUID] = []
        for duplicate in duplicates {
            let key = EventStorageLocations.pathKey(duplicate.move.sourcePath)
            guard let (location, _) = roots.first(where: { key.hasPrefix($0.1) }) else { continue }
            if byLocation[location.id] == nil { order.append(location.id) }
            byLocation[location.id, default: []].append(duplicate)
        }
        guard let locationID = order.first, let location = location(locationID),
              let chosen = byLocation[locationID] else {
            model.statusMessage = "Those copies are not in an unsorted folder, so they were left alone. Open the folder to remove them."
            return
        }
        let items = chosen.map { duplicate -> OrganizeItem in
            let file = OrganizeFile(
                path: duplicate.move.sourcePath,
                size: duplicate.move.byteCount,
                modifiedAt: duplicate.assignment?.modifiedAt ?? Date()
            )
            return OrganizeItem(
                primary: file,
                kind: OrganizeFileClassifier.kind(forExtension: file.fileExtension),
                captureDate: file.modifiedAt,
                hasCameraDate: false
            )
        }
        presentTrash(items: items, locationID: locationID, eventID: nil, locationName: location.name)
        pendingTrash?.preservedAssignmentKeys = Set(chosen.compactMap { duplicate -> String? in
            guard let assignment = duplicate.assignment else { return nil }
            return hasOtherAssignment(pointingLike: assignment) ? nil : Self.sourceKey(assignment)
        })
        pendingTrash?.note = order.count > 1
            ? "Identical copies in other folders stay until you Apply those folders."
            : "Each one is already in its event as a byte-identical file."
    }

    /// True when another assignment in the same event resolves to the same
    /// event file (same device folder and relative path).
    private func hasOtherAssignment(pointingLike assignment: PhotoEventAssignment) -> Bool {
        Self.hasOtherAssignment(pointingLike: assignment, in: model.configuration.photoEventAssignments)
    }

    /// The Apply sheet's primary button with the owner's choices for taken
    /// names. Plain moves and Keep Both renames run as one journaled job, so
    /// one Undo reverses both; copies are queued as usual. Identical copies
    /// chosen for Trash open the organizer Trash confirmation — right away
    /// when nothing moves, otherwise once the move job has finished — and
    /// nothing is trashed until the owner confirms there.
    func performApply(_ plan: OrganizeApplyPlan, resolving decisions: ApplyCollisionDecisions) {
        let keep = decisions.keepBoth
        let trash = decisions.trash
        guard !keep.isEmpty else {
            if plan.moveCount == 0 {
                if plan.copyCount > 0 { performApply(plan) }
                if !trash.isEmpty { requestTrashApplyDuplicates(trash) }
                pendingApplyPlan = nil
                return
            }
            performApply(plan, thenTrash: trash)
            return
        }
        pendingApplyPlan = nil
        guard !model.isBusy, !model.isStorageBenchmarkRunning else {
            model.statusMessage = "Another file job is already running. Wait for it to finish, then try again."
            return
        }
        runningApply = nil
        let moves = plan.groups.flatMap(\.moves)
        let journalFolder = self.journalFolder
        let boundaries = plan.pruneBoundaries
        let title = plan.title
        let keptSources = Set(keep.map(\.move.sourcePath))
        let keptEvents = plan.groups.filter { group in group.conflicts.contains { keptSources.contains($0.move.sourcePath) } }.map(\.event.id)
        let affectedEvents = plan.groups.map(\.event.id)
        let conflictCount = decisions.keepBothConflictCount
        let locations = self.locations
        let queuedRenames = NASQueuedRenames()
        let jobID = model.runBackgroundJob(
            action: .organize,
            runningNote: "Moving \(moves.count + keep.count) file(s) into their events",
            logTitle: title,
            logDetail: "Renamed files on the same drive. Files whose name was taken moved in under a free “(N)” name. Nothing was replaced.",
            operation: { progress in
                let outcome = try DriveMoveService().keepBoth(
                    keep,
                    plainMoves: moves,
                    title: title,
                    journalFolder: journalFolder,
                    pruneBoundaries: boundaries
                ) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Organizing", command: ""))
                }
                // Files that already sat in an event folder owe the NAS the
                // same rename — as on the plain path, which this job replaces.
                queuedRenames.add(Self.queueNASRenames(
                    NASMoveFollower.renames(forMoves: outcome.report.moved, locations: locations),
                    title: title, origin: .move, moveJournalID: outcome.report.journalID,
                    nasRoot: locations.nasRoot, journalFolder: journalFolder
                ))
                return outcome
            },
            completion: { [weak self] outcome in
                guard let self else { return "" }
                noteNASRenamesQueued(queuedRenames.count)
                applyAssignmentChange(
                    AssignmentChange(title: title, removed: outcome.removedAssignments, added: outcome.addedAssignments),
                    touching: nil
                )
                recordJournalUndo(title: title, report: outcome.report)
                didMove(report: outcome.report, events: affectedEvents)
                // Only the files that really moved stop counting as blocked;
                // a row left here still is.
                let movedKeys = Set(outcome.report.moved.map { EventStorageLocations.pathKey($0.sourcePath) })
                for eventID in keptEvents {
                    let rest = (applyConflictSourceKeys[eventID] ?? []).subtracting(movedKeys)
                    applyConflictSourceKeys[eventID] = rest.isEmpty ? nil : rest
                }
                if !trash.isEmpty { requestTrashApplyDuplicates(trash) }
                let movedKept = outcome.report.moved.count { keptSources.contains($0.sourcePath) }
                let skipped = outcome.report.skipped.first.map { " \(outcome.report.skipped.count) left in place: \($0.reason)" } ?? ""
                return "Moved \(outcome.report.moved.count) file(s) (\(outcome.report.movedBytes.formattedBytes)) into their events"
                    + (movedKept > 0 ? ", kept both for \(conflictCount) taken name\(conflictCount == 1 ? "" : "s")" : "")
                    + ". Nothing was replaced — Undo puts them back.\(skipped)"
            }
        )
        if let jobID, !moves.isEmpty {
            runningApply = RunningApplyPlan(jobID: jobID, title: plan.title, groups: plan.groups)
        }
        if jobID != nil {
            enqueueCopies(plan)
        }
    }

    private func enqueueCopies(_ plan: OrganizeApplyPlan) {
        for group in plan.groups {
            for batch in group.copies {
                model.enqueueTransfer(
                    files: batch.files,
                    sourcePath: batch.sourceRoot,
                    destinationPath: batch.destinationRoot,
                    eventID: group.event.id,
                    eventName: locations.displayName(for: group.event),
                    deviceID: batch.deviceID
                )
            }
        }
    }

    /// "Keep Both" from the Apply sheet: each file whose name is taken in
    /// its event moves in as `name (N).ext`, with its sidecars under the
    /// same N. One journaled job — nothing is replaced, Undo moves the
    /// files back under their original names. The rest of the plan is
    /// left for the next Apply.
    func keepBoth(_ plan: OrganizeApplyPlan) {
        pendingApplyPlan = nil
        let conflicts = plan.groups.flatMap(\.conflicts)
        guard !conflicts.isEmpty else { return }
        guard !model.isBusy, !model.isStorageBenchmarkRunning else {
            model.statusMessage = "Another file job is already running. Wait for it to finish, then try again."
            return
        }
        let journalFolder = self.journalFolder
        let boundaries = plan.pruneBoundaries
        let title = "Keep both in \(plan.groups.first { !$0.conflicts.isEmpty }.map { eventTitle($0.event) } ?? "the event")"
        let affectedEvents = plan.groups.filter { !$0.conflicts.isEmpty }.map(\.event.id)
        let remaining = plan.fileCount
        let locations = self.locations
        let queuedRenames = NASQueuedRenames()
        model.runBackgroundJob(
            action: .organize,
            runningNote: "Moving \(conflicts.count) file(s) in under a new name",
            logTitle: title,
            logDetail: "Renamed files on the same drive to a free “(N)” name next to the file that already had their name. Nothing was replaced.",
            operation: { progress in
                let outcome = try DriveMoveService().keepBoth(
                    conflicts,
                    title: title,
                    journalFolder: journalFolder,
                    pruneBoundaries: boundaries
                ) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Moving", command: ""))
                }
                queuedRenames.add(Self.queueNASRenames(
                    NASMoveFollower.renames(forMoves: outcome.report.moved, locations: locations),
                    title: title, origin: .move, moveJournalID: outcome.report.journalID,
                    nasRoot: locations.nasRoot, journalFolder: journalFolder
                ))
                return outcome
            },
            completion: { [weak self] outcome in
                guard let self else { return "" }
                noteNASRenamesQueued(queuedRenames.count)
                applyAssignmentChange(
                    AssignmentChange(title: title, removed: outcome.removedAssignments, added: outcome.addedAssignments),
                    touching: nil
                )
                recordJournalUndo(title: title, report: outcome.report)
                didMove(report: outcome.report, events: affectedEvents)
                for eventID in affectedEvents {
                    applyConflictSourceKeys[eventID] = nil
                }
                let names = outcome.report.moved.prefix(2).map { ($0.destinationPath as NSString).lastPathComponent }
                let named = names.isEmpty ? "" : " as " + names.joined(separator: ", ") + (outcome.report.moved.count > 2 ? "…" : "")
                let skipped = outcome.report.skipped.first.map { " \(outcome.report.skipped.count) left in place: \($0.reason)" } ?? ""
                let rest = remaining > 0 ? " Press Apply for the other \(remaining) file(s)." : ""
                return "Kept both: moved \(outcome.report.moved.count) file(s) in\(named). Nothing was replaced — Undo puts them back.\(skipped)\(rest)"
            }
        )
    }

    private func didMove(report: DriveMoveReport, events: [UUID]) {
        retargetMovedPaths(report.moved)
        let movedKeys = Set(report.moved.map { EventStorageLocations.pathKey($0.sourcePath) })
        // Only the files that actually moved stop being selected — every
        // board keeps the rest of its selection, and a finished Apply on one
        // board never clears another.
        var movedSelectionKeys: Set<String> = []
        for state in sources.values {
            for stack in state.result?.stacks ?? [] {
                for file in stack.files where movedKeys.contains(file.pathKey) {
                    movedSelectionKeys.insert(Self.selectionKey(file))
                }
            }
        }
        for (id, state) in sources {
            if let result = state.result {
                sources[id]?.result = result.removingFiles(withPathKeys: movedKeys)
            }
        }
        dropSelectionKeys(movedSelectionKeys)
        expandedStackIDs.removeAll()
        runningApply = nil
        refreshLatestJournal()
        for eventID in Set(events) {
            Task { await refreshEvent(eventID) }
        }
    }

    /// The Undo menu reads the undo history, which every finished action
    /// records itself. This only offers a journal the history does not know
    /// (one an earlier build wrote), in time order.
    func refreshLatestJournal() {
        discoverLatestJournal()
    }

    /// Kept for callers that used to read the journal folder in the
    /// background — the history already knows.
    func refreshLatestJournalInBackground() {}

    /// A rename batch landed, straight from the move report: every stack
    /// the boards already show repoints at the destination paths and the
    /// tile loader reroutes decodes off the vacated ones, so an open
    /// preview or tile keeps reading the moved file instead of failing on
    /// its old path. Called in the same update that records the move —
    /// `refreshEvent` still runs afterwards to restat the library; the
    /// preview is already correct before that finishes.
    func retargetMovedPaths(_ moved: [DriveMove]) {
        guard !moved.isEmpty else { return }
        TileImageLoader.shared.retarget(moves: moved)
        var destinations: [String: String] = [:]
        for move in moved {
            destinations[EventStorageLocations.pathKey(move.sourcePath)] =
                URL(fileURLWithPath: move.destinationPath).standardizedFileURL.path
        }
        for (eventID, stacks) in eventStacks {
            eventStacks[eventID] = stacks.map { $0.retargetingPaths(destinations) }
            eventGridRevisions[eventID] = model.catalogStateRevision
        }
    }

    /// The first event a journal's renames name whose folder is no longer the
    /// one the rename used — each rename's source is the drive path of the
    /// entry it moved out of, its destination the drive path of the entry it
    /// moved in. Journals from before entries carried their rename are not
    /// checked.
    /// The first event whose folder is no longer the recorded one (event id →
    /// folder path), or nil when they all are.
    func eventMoved(since recorded: [String: String]) -> SavedCameraEvent? {
        let locations = self.locations
        for (idText, path) in recorded {
            guard let id = UUID(uuidString: idText), let owner = event(id) else { continue }
            if locations.eventFolder(for: owner, policy: locations.resolvedPolicy(for: owner)).path != path { return owner }
        }
        return nil
    }

    func eventRenamedSince(_ journal: DriveMoveJournal) -> SavedCameraEvent? {
        let locations = self.locations
        // The folders the events kept when the action ran, where recorded.
        if let renamed = eventMoved(since: journal.eventFolders ?? [:]) { return renamed }
        guard let indices = journal.assignmentMoveIndices else { return nil }
        let completed = Set(journal.completedIndices)
        func matches(_ path: String, _ assignment: PhotoEventAssignment) -> Bool {
            guard let event = event(assignment.eventID) else { return true }
            let key = EventStorageLocations.pathKey(path)
            // An Apply's rename starts at the entry's source folder, not at
            // an event folder.
            if let source = locations.sourceURL(for: assignment), EventStorageLocations.pathKey(source.path) == key { return true }
            return EventStoragePolicy.allCases.contains { policy in
                locations.driveURL(for: assignment, event: event, policy: policy)
                    .map { EventStorageLocations.pathKey($0.path) == key } ?? false
            }
        }
        for (position, index) in indices.enumerated() {
            guard let index, completed.contains(index), journal.moves.indices.contains(index) else { continue }
            let move = journal.moves[index]
            if position < journal.removedAssignments.count, !matches(move.sourcePath, journal.removedAssignments[position]) {
                return event(journal.removedAssignments[position].eventID)
            }
            if position < journal.addedAssignments.count, !matches(move.destinationPath, journal.addedAssignments[position]) {
                return event(journal.addedAssignments[position].eventID)
            }
        }
        return nil
    }

    // MARK: - Reorganize inside events

    /// Every exit leaves the owner a sentence — and, when nothing moved,
    /// a line in the activity log with the reason and the file names: a
    /// queued or running job, an already-there note, or a name collision.
    /// A board still painting or a presence index still empty is never a
    /// reason to drop the click.
    ///
    /// `sourceEventID` is the board the tiles were clicked on. On a family
    /// board its files belong to its subevents, so each file moves out of
    /// the event whose assignment actually owns it; the board's own event
    /// is never assumed to be that owner.
    func moveStacks(_ stackIDs: Set<String>, fromEvent sourceEventID: UUID, toEvent targetEventID: UUID) {
        guard let from = event(sourceEventID), let to = event(targetEventID) else {
            refuseMove("Move to Event", "The source or destination event no longer exists — nothing was moved.")
            return
        }
        guard let stacks = eventStacks[sourceEventID] else {
            queueMove(stackIDs, from: from, to: to)
            return
        }
        moveLoadedStacks(visibleSelection(stackIDs, on: sourceEventID), from: from, to: to)
    }

    /// The selected stacks of a board that its filters still show. A stack
    /// selected and then hidden — a subevent chip switched off, a person
    /// filter added — is not moved: an action is about what the owner can see.
    private func visibleSelection(_ ids: Set<String>, on eventID: UUID) -> [OrganizeStack] {
        let chosen = (eventStacks[eventID] ?? []).filter { ids.contains($0.id) }
        guard !search.isEmpty, !chosen.isEmpty else { return chosen }
        let shown = Set(visibleEventStacks(eventID, search: search).map(\.id))
        return chosen.filter { shown.contains($0.id) }
    }

    /// The events and every open board whose family includes one of them —
    /// the boards that draw those events' files.
    func boardsShowing(_ events: Set<UUID>) -> Set<UUID> {
        Set(eventStacks.keys.filter { !scopeIDs($0).isDisjoint(with: events) }).union(events)
    }

    /// A click that moved nothing: the status line now, and an activity-log
    /// entry so the reason and the files are still there later.
    func refuseMove(_ title: String, _ message: String, files: [String] = []) {
        model.statusMessage = message
        model.recordActivity(
            action: .organize,
            state: .failed,
            title: "\(title) — nothing moved",
            summary: message,
            detail: Self.fileNameList(files)
        )
    }

    /// Up to `limit` names, then a count of the rest.
    nonisolated static func fileNameList(_ names: [String], limit: Int = 25) -> String {
        guard !names.isEmpty else { return "" }
        let shown = names.prefix(limit).joined(separator: "\n")
        return names.count > limit ? shown + "\n…and \(names.count - limit) more" : shown
    }

    /// A click arrived before the board painted, so the stack ids cannot be
    /// opened into their files yet. The click waits on the in-flight refresh
    /// (or starts one) and then runs the same move — it is never dropped.
    private func queueMove(_ stackIDs: Set<String>, from: SavedCameraEvent, to: SavedCameraEvent) {
        model.statusMessage = "Move to \(eventTitle(to)) queued — \(eventTitle(from)) is still loading. It runs as soon as the board appears."
        let landedAtClick = landedMoveCount
        Task { @MainActor [weak self] in
            guard let self else { return }
            await waitForBoard(from.id)
            // A move that landed while this click waited for its board has
            // patched the boards this one is about to patch: read them again.
            moveLoadedStacks(visibleSelection(stackIDs, on: from.id), from: from, to: to, overlapsEarlier: landedMoveCount != landedAtClick)
        }
    }

    /// Suspends until `eventStacks[eventID]` exists: waits out the in-flight
    /// sweep when one is already publishing the board, or drives a refresh
    /// for a board nobody opened. Clicks queued while a grid loads land here
    /// instead of vanishing.
    private func waitForBoard(_ eventID: UUID) async {
        guard eventStacks[eventID] == nil else { return }
        if let sweep = presenceTasks[eventID] {
            await sweep.value
            guard eventStacks[eventID] == nil else { return }
        }
        await refreshEvent(eventID)
    }

    /// The catalog assignment behind every file of `stacks`, wherever in the
    /// board's family it lives. A family board's tiles belong to its
    /// subevents, so the owner is whatever the presence sweep or the
    /// path-key index says — never assumed to be `board` — and each file's
    /// drive paths are worked out from its own event. The sweep's answer is
    /// used per file, and the catalog's answer fills in every file the sweep
    /// has not reached (or has dropped), so a half-finished "Checking" board
    /// or a partly patched index can never hide part of a selection.
    private func resolveMoveCandidates(for stacks: [OrganizeStack], in board: SavedCameraEvent) -> MoveResolution {
        refreshIndexIfNeeded()
        let scope = scopeIDs(board.id)
        let swept = eventAssetsByPathKey[board.id] ?? [:]
        let locations = self.locations
        let eventsByID = self.eventsByID
        var paths = EventPathCache(locations: locations)
        var resolution = MoveResolution()
        var seen: Set<String> = []
        for file in stacks.flatMap(\.files) {
            let candidate: MoveCandidate
            if let asset = swept[file.pathKey], scope.contains(asset.assignment.eventID) {
                candidate = MoveCandidate(asset)
            } else if let assignment = assignmentsByPathKey[file.pathKey],
                      assignment.fileSize == file.size,
                      scope.contains(assignment.eventID),
                      let owner = eventsByID[assignment.eventID] {
                candidate = catalogCandidate(assignment, owner: owner, tile: file, locations: locations, paths: &paths)
            } else {
                resolution.unresolved.append(file.name)
                continue
            }
            resolution.ownerByKey[file.pathKey] = candidate.assignment.eventID
            if seen.insert(CatalogStore.eventAssetID(candidate.assignment)).inserted {
                resolution.candidates.append(candidate)
            }
        }
        return resolution
    }

    /// `EventPresenceScanner`'s answer without the sweep: each file's
    /// catalog assignment plus the Originals path the grid implied is enough
    /// to plan a move. A location reads `.present` only where the tile's own
    /// path matches — exactly the place the file was drawn at — and
    /// `.missing` elsewhere, so a plan never points a rename at a location
    /// the sweep never verified. When the file is not actually there
    /// anymore, the rename's own preflight skips it and the completion
    /// reports why.
    private func catalogCandidate(
        _ assignment: PhotoEventAssignment,
        owner: SavedCameraEvent,
        tile file: OrganizeFile,
        locations: EventStorageLocations,
        paths: inout EventPathCache
    ) -> MoveCandidate {
        let policy = locations.resolvedPolicy(for: owner)
        let otherPolicy: EventStoragePolicy = policy == .buffer ? .archiveOnly : .buffer
        let source = locations.sourceURL(for: assignment)?.path
        let drive = paths.driveURL(for: assignment, event: owner, policy: policy)?.path
        let other = paths.driveURL(for: assignment, event: owner, policy: otherPolicy)?.path
        let sourceIsDriveCopy = [drive, other].contains { candidate in
            guard let candidate, let source else { return false }
            return candidate == source
        }
        return MoveCandidate(
            assignment: assignment,
            sourcePath: source,
            drivePath: drive,
            otherDrivePath: other,
            source: file.path == source ? .present : .missing,
            drive: file.path == drive ? .present : .missing,
            otherDrive: file.path == other ? .present : .missing,
            sourceIsDriveCopy: sourceIsDriveCopy
        )
    }

    /// A name the target already has is decided by content, not by name:
    /// the job re-hashes both files. An identical copy merges — the
    /// target's file stays and the extra one goes to the drive's `_Trash` —
    /// and a different photo moves in under a free "(N)" name
    /// (`EventMoveService`). Only a file that cannot be read stays behind.
    ///
    /// The click does only the planning, then the tiles change boards in
    /// memory at once (`beginOptimisticMove`) and the rename runs as a job
    /// (`startPendingMoves`) — queued, with a line saying behind what, when
    /// another job holds the gate. The catalog changes when the rename
    /// lands, not before.
    private func moveLoadedStacks(
        _ targetStacks: [OrganizeStack],
        from: SavedCameraEvent,
        to: SavedCameraEvent,
        overlapsEarlier: Bool = false
    ) {
        let targetEventID = to.id
        let title = "Move to \(eventTitle(to))"
        let selectedNames = targetStacks.flatMap(\.files).map(\.name)
        let inFlight = pendingMoveStackIDs
        guard inFlight.isDisjoint(with: targetStacks.map(\.id)),
              !targetStacks.contains(where: { $0.files.contains { optimisticOwners[$0.pathKey] != nil } }) else {
            refuseMove(title, "Those files are already moving. Give it a moment, then move them again if they are still here.", files: selectedNames)
            return
        }
        let resolution = resolveMoveCandidates(for: targetStacks, in: from)
        let assets = resolution.candidates
        guard !assets.isEmpty else {
            let family = subevents(of: from.id).isEmpty ? "" : " or its subevents"
            refuseMove(
                title,
                targetStacks.isEmpty
                    ? "Nothing to move — that selection is not on \(eventTitle(from))'s board any more, or a filter hides it. Click the stacks again."
                    : "Nothing to move — the catalog has no entry for those files in \(eventTitle(from))\(family).",
                files: targetStacks.isEmpty ? [] : resolution.unresolved
            )
            return
        }
        let locations = self.locations
        var paths = EventPathCache(locations: locations)
        let targetPolicy = locations.resolvedPolicy(for: to)
        let targetByName = assignmentsByName(inEvent: targetEventID)

        var items: [EventMoveItem] = []
        var alreadyThere: [String] = []
        // Names this batch already brings in, with where that file is now,
        // so two incoming files with one name are compared with each other.
        var claimed: [String: String] = [:]
        let targetOther: EventStoragePolicy = targetPolicy == .buffer ? .archiveOnly : .buffer
        for asset in assets {
            // A family board's stacks can already belong to the target —
            // a subevent section on the parent's board dropped back onto
            // that subevent moves nothing.
            guard asset.assignment.eventID != targetEventID else {
                alreadyThere.append((asset.assignment.relativePath as NSString).lastPathComponent)
                continue
            }
            var moved = asset.assignment
            moved.eventID = targetEventID
            var moveSource: String?
            if asset.sourceIsDriveCopy {
                if let path = [asset.drive == .present ? asset.drivePath : nil, asset.otherDrive == .present ? asset.otherDrivePath : nil]
                    .compactMap({ $0 }).first {
                    moved.sourceRootPath = paths.originalsRootPath(to, moved.deviceID, targetPolicy)
                    moveSource = path
                }
            } else if asset.drive == .present {
                moveSource = asset.drivePath
            } else if asset.otherDrive == .present {
                moveSource = asset.otherDrivePath
            }
            let move = moveSource.flatMap { source in
                paths.driveURL(for: moved, event: to, policy: targetPolicy).map {
                    DriveMove(sourcePath: source, destinationPath: $0.path, byteCount: moved.fileSize)
                }
            }
            let currentPath = moveSource ?? (asset.source == .present ? asset.sourcePath : nil)
            // No drive copy to rename, but a NAS copy at the mirror path: the
            // NAS copy owes the rename, or the file is lost to the event that
            // now owns it.
            var nasCopy: NASCopyMove?
            if move == nil, asset.archive == .present, !asset.archiveIsLegacyLayout, let archive = asset.archivePath,
               let target = paths.archiveURL(for: moved, event: to)?.path,
               let from = locations.nasRelativePath(archive), let toPath = locations.nasRelativePath(target) {
                nasCopy = NASCopyMove(from: from, to: toPath)
            }
            let name = Self.nameKey(moved.relativePath)
            var takenBy: [String] = []
            if let existing = targetByName[name] {
                takenBy = [
                    paths.driveURL(for: existing, event: to, policy: targetPolicy),
                    paths.driveURL(for: existing, event: to, policy: targetOther),
                    locations.sourceURL(for: existing)
                ].compactMap { $0?.path }
            } else if let earlier = claimed[name] {
                takenBy = [earlier]
            } else {
                claimed[name] = currentPath ?? ""
            }
            items.append(EventMoveItem(
                removed: asset.assignment,
                added: moved,
                move: move,
                currentPath: currentPath,
                takenBy: takenBy,
                nasCopy: nasCopy
            ))
        }
        guard !items.isEmpty else {
            refuseMove(title, "Those files are already in \(eventTitle(to)). Nothing moved.", files: alreadyThere)
            return
        }
        noteRecent(targetEventID)

        var sourceTitles: [UUID: String] = [:]
        for item in items {
            let ownerID = item.removed.eventID
            if sourceTitles[ownerID] == nil, let owner = event(ownerID) { sourceTitles[ownerID] = eventTitle(owner) }
        }
        var move = PendingEventMove(
            from: from, to: to, title: title, items: items, stacks: targetStacks,
            sourceTitles: sourceTitles, ownerByKey: resolution.ownerByKey
        )
        var notes: [String] = []
        if !alreadyThere.isEmpty { notes.append("\(ApplyPlanOverview.plural(alreadyThere.count, "file")) already in \(eventTitle(to)).") }
        if !resolution.unresolved.isEmpty {
            notes.append("\(ApplyPlanOverview.plural(resolution.unresolved.count, "file")) not in the catalog, left alone.")
            model.recordActivity(
                action: .organize,
                state: .failed,
                title: "\(title) — some files skipped",
                summary: "\(ApplyPlanOverview.plural(resolution.unresolved.count, "file")) on the board have no catalog entry in \(eventTitle(from)) and were not moved.",
                detail: Self.fileNameList(resolution.unresolved)
            )
        }
        move.note = notes.joined(separator: " ")
        beginOptimisticMove(&move)
        // Only catalog entries change: no rename and no name to compare.
        guard items.contains(where: { $0.move != nil || !$0.takenBy.isEmpty || $0.nasCopy != nil }) else {
            let change = AssignmentChange(title: title, removed: items.map(\.removed), added: items.map(\.added))
            endOptimisticMove(move)
            applyAssignmentChange(change, touching: targetEventID, patchBoards: false)
            stampBoards(of: move)
            landedMoveCount += 1
            recordAssignmentUndo(change)
            var outcome = EventMoveOutcome()
            outcome.moved = items
            model.statusMessage = summaryLine(outcome, move: move)
            return
        }
        if !pendingMoves.isEmpty || overlapsEarlier {
            move.overlapped = true
            for index in pendingMoves.indices { pendingMoves[index].overlapped = true }
        }
        pendingMoves.append(move)
        startPendingMoves()
    }

    /// `EventMoveWording`'s line for an outcome, plus what the click left
    /// alone; a stayed file names the event it stayed in.
    private func summaryLine(_ outcome: EventMoveOutcome, move: PendingEventMove) -> String {
        let line = EventMoveWording.summary(
            outcome,
            from: eventTitle(move.from),
            to: eventTitle(move.to),
            titles: move.sourceTitles
        )
        return move.note.isEmpty ? line : line + " " + move.note
    }

    /// Two names are the same file name when they are the same letters in
    /// any case and any Unicode composition — the volume treats "é" typed
    /// as one character or as e plus an accent as one name.
    nonisolated static func nameKey(_ relativePath: String) -> String {
        relativePath.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: - Optimistic Move to Event

    /// The stacks of every move that has been clicked and not yet settled.
    private var pendingMoveStackIDs: Set<String> {
        Set(pendingMoves.flatMap { $0.stacks.map(\.id) })
    }

    /// Moves the tiles between boards in memory, the moment of the click:
    /// a board whose family holds a file's owner but not the target loses
    /// its stack, one holding the target but not the owner gains it (in
    /// capture order, ids intact), and a board holding both — the parent's
    /// — keeps it. No stacker run, no filesystem, no catalog: O(the
    /// stacks moved) plus one array copy per board. The counts and the
    /// color dots follow through the overlay until the rename lands.
    private func beginOptimisticMove(_ move: inout PendingEventMove) {
        let ids = Set(move.stacks.map(\.id))
        for boardID in Array(eventStacks.keys) {
            guard var stacks = eventStacks[boardID] else { continue }
            let scope = scopeIDs(boardID)
            var cutDifferently = false
            if !scope.contains(move.to.id) {
                // The files whose owner sits in this board's family leave it.
                // Found by the files a stack holds, not by its id: ids are
                // carried from earlier boards, so two boards can hold the same
                // photos under different ids — and one id can even sit on a
                // stack that holds none of them.
                let leaving = Set(move.movedOwners.filter { scope.contains($0.value) }.keys)
                guard !leaving.isEmpty else { continue }
                stacks.removeAll { stack in
                    guard stack.files.contains(where: { leaving.contains($0.pathKey) }) else { return false }
                    if !ids.contains(stack.id) || stack.files.contains(where: { !leaving.contains($0.pathKey) }) { cutDifferently = true }
                    return true
                }
                move.leftBoards.append(boardID)
            } else {
                // The files whose owner sits outside arrive; those whose owner
                // is in the family (a subevent moved up to its parent) are
                // already drawn here.
                let arriving = Set(move.movedOwners.filter { !scope.contains($0.value) }.keys)
                guard !arriving.isEmpty else { continue }
                let present = Set(stacks.flatMap(\.files).map(\.pathKey))
                let incoming = move.stacks.filter { stack in
                    stack.files.contains { arriving.contains($0.pathKey) } && !stack.files.contains { present.contains($0.pathKey) }
                }
                if incoming.contains(where: { stack in stack.files.contains { !arriving.contains($0.pathKey) } }) { cutDifferently = true }
                stacks = Self.inserting(incoming, into: stacks)
                move.joinedBoards.append(boardID)
            }
            // A board that cuts the moved stacks differently from the clicked
            // one — a burst whose frames belong to two events, or ids the
            // board does not hold — is re-read from the catalog once the
            // move lands instead of trusting the ids. A board that cut them
            // the same is not: a move clicked on a family board used to
            // re-read every other board it touched (~1 s of stalls on a
            // 15,000-file family), and `MoveBoardTruthTests` proves those
            // boards already match a fresh read without it.
            if cutDifferently { move.truthBoards.append(boardID) }
            // A sweep or build still running for this board would publish
            // the old arrangement over the tiles that just moved. It is
            // dropped, and the board is re-checked once the move settles.
            if presenceTasks[boardID] != nil {
                presenceTasks[boardID]?.cancel()
                presenceTasks[boardID] = nil
                refreshGenerations[boardID] = UUID()
                move.interruptedBoards.append(boardID)
            }
            eventStacks[boardID] = stacks
            eventGridRevisions[boardID] = model.catalogStateRevision
        }
        for item in move.items {
            optimisticCounts[item.removed.eventID, default: 0] -= 1
            optimisticBytes[item.removed.eventID, default: 0] -= item.removed.fileSize
            optimisticCounts[move.to.id, default: 0] += 1
            optimisticBytes[move.to.id, default: 0] += item.removed.fileSize
        }
        for file in move.stacks.flatMap(\.files) {
            optimisticOwners[file.pathKey] = move.to.id
            move.overlayKeys.append(file.pathKey)
        }
        moveOverlayRevision &+= 1
    }

    /// Drops the overlay of a move that settled — landed or rolled back.
    private func endOptimisticMove(_ move: PendingEventMove) {
        for item in move.items {
            optimisticCounts[item.removed.eventID, default: 0] += 1
            optimisticBytes[item.removed.eventID, default: 0] += item.removed.fileSize
            optimisticCounts[move.to.id, default: 0] -= 1
            optimisticBytes[move.to.id, default: 0] -= item.removed.fileSize
        }
        optimisticCounts = optimisticCounts.filter { $0.value != 0 }
        optimisticBytes = optimisticBytes.filter { $0.value != 0 }
        for key in move.overlayKeys { optimisticOwners[key] = nil }
        moveOverlayRevision &+= 1
    }

    /// The tiles go back where they were: the inverse of
    /// `beginOptimisticMove`, applied to the boards as they are now (so
    /// anything else that changed them meanwhile stays changed).
    private func rollBackOptimisticMove(_ move: PendingEventMove) {
        for boardID in move.leftBoards {
            guard let stacks = eventStacks[boardID] else { continue }
            let scope = scopeIDs(boardID)
            let owned = Set(move.movedOwners.filter { scope.contains($0.value) }.keys)
            let present = Set(stacks.flatMap(\.files).map(\.pathKey))
            eventStacks[boardID] = Self.inserting(
                move.stacks.filter { stack in
                    stack.files.contains { owned.contains($0.pathKey) } && !stack.files.contains { present.contains($0.pathKey) }
                },
                into: stacks
            )
            eventGridRevisions[boardID] = model.catalogStateRevision
        }
        for boardID in move.joinedBoards {
            guard var stacks = eventStacks[boardID] else { continue }
            let scope = scopeIDs(boardID)
            let arrived = Set(move.movedOwners.filter { !scope.contains($0.value) }.keys)
            stacks.removeAll { stack in stack.files.contains { arrived.contains($0.pathKey) } }
            eventStacks[boardID] = stacks
            eventGridRevisions[boardID] = model.catalogStateRevision
        }
        endOptimisticMove(move)
    }

    /// Boards a move touched are as current as the catalog again.
    private func stampBoards(of move: PendingEventMove) {
        for boardID in move.leftBoards + move.joinedBoards where eventStacks[boardID] != nil {
            eventGridRevisions[boardID] = model.catalogStateRevision
        }
    }

    /// `new` merged into `stacks`, which is in capture order — each stack
    /// lands by binary search where the stacker would have put it.
    private static func inserting(_ new: [OrganizeStack], into stacks: [OrganizeStack]) -> [OrganizeStack] {
        var result = stacks
        func isBefore(_ lhs: OrganizeStack, _ rhs: OrganizeStack) -> Bool {
            if lhs.captureDate != rhs.captureDate { return lhs.captureDate < rhs.captureDate }
            return lhs.id < rhs.id
        }
        for stack in new.sorted(by: isBefore) {
            var low = 0
            var high = result.count
            while low < high {
                let middle = (low + high) / 2
                if isBefore(result[middle], stack) { low = middle + 1 } else { high = middle }
            }
            result.insert(stack, at: low)
        }
        return result
    }

    /// Starts the next clicked move when nothing else holds the job gate;
    /// otherwise says, right away, what it is queued behind. Called at the
    /// click and every time a job finishes, so a queued move begins in the
    /// same main-actor turn that frees the gate.
    func startPendingMoves() {
        guard let index = pendingMoves.firstIndex(where: { !$0.isRunning }),
              !pendingMoves.contains(where: \.isRunning) else { return }
        let move = pendingMoves[index]
        guard !model.isBusy, !model.isStorageBenchmarkRunning else {
            let behind = model.activeJob.map { "“\($0.note)”" } ?? "the running job"
            model.statusMessage = "Move to \(eventTitle(move.to)) queued behind \(behind). The tiles are already on \(eventTitle(move.to))'s board; the files are renamed when that finishes."
            return
        }
        pendingMoves[index].isRunning = true
        if runMoveJob(move) == nil { pendingMoves[index].isRunning = false }
    }

    /// While a clicked move waits for the job gate its tiles already sit on
    /// the new board and the counts follow. This says so on the boards it
    /// touches, so a queued move never looks like files that vanished.
    func queuedMoveNote(for eventID: UUID) -> String? {
        _ = moveOverlayRevision
        let scope = scopeIDs(eventID)
        guard let move = pendingMoves.first(where: {
            !$0.isRunning && !$0.isLanded && !scope.isDisjoint(with: $0.sourceIDs.union([$0.to.id]))
        }) else { return nil }
        let behind = model.activeJob.map { "“\($0.note)”" } ?? "the running job"
        return "Move to \(eventTitle(move.to)) is waiting behind \(behind). The tiles are already there; the files are renamed when it finishes."
    }

    /// The move's items with the names the target's catalog holds *now*. A move
    /// waits its turn behind other jobs and moves; one that landed first may
    /// have brought a file under the same name into the target, which the
    /// plan made at click time could not know — without this the second
    /// would find the name taken only on disk and adopt a second entry for
    /// the same file.
    private func itemsWithCurrentNameClashes(_ move: PendingEventMove) -> [EventMoveItem] {
        let locations = self.locations
        var paths = EventPathCache(locations: locations)
        let targetPolicy = locations.resolvedPolicy(for: move.to)
        let targetOther: EventStoragePolicy = targetPolicy == .buffer ? .archiveOnly : .buffer
        let targetByName = assignmentsByName(inEvent: move.to.id)
        return move.items.map { item in
            var item = item
            guard item.takenBy.isEmpty,
                  let existing = targetByName[Self.nameKey(item.added.relativePath)],
                  CatalogStore.eventAssetID(existing) != CatalogStore.eventAssetID(item.added) else { return item }
            item.takenBy = [
                paths.driveURL(for: existing, event: move.to, policy: targetPolicy),
                paths.driveURL(for: existing, event: move.to, policy: targetOther),
                locations.sourceURL(for: existing)
            ].compactMap { $0?.path }
            return item
        }
    }

    /// Where each of these events keeps its folder right now, for a journal.
    func eventFolderSnapshot(_ ids: Set<UUID>) -> [String: String] {
        let locations = self.locations
        var folders: [String: String] = [:]
        for id in ids {
            if let event = event(id) {
                folders[id.uuidString] = locations.eventFolder(for: event, policy: locations.resolvedPolicy(for: event)).path
            }
        }
        return folders
    }

    private func runMoveJob(_ move: PendingEventMove) -> UUID? {
        let targetEventID = move.to.id
        let items = itemsWithCurrentNameClashes(move)
        let locations = self.locations
        let targetPolicy = locations.resolvedPolicy(for: move.to)
        let title = move.title
        var trashEventIDs: [String: UUID] = [:]
        // The entry a spare copy stops having when it goes to Trash, written
        // into the manifest so restoring the copy brings it back.
        var trashAssignments: [String: [PhotoEventAssignment]] = [:]
        for item in items {
            if let path = item.currentPath {
                let key = EventStorageLocations.pathKey(path)
                trashEventIDs[key] = item.removed.eventID
                trashAssignments[key, default: []].append(item.removed)
            }
        }
        let trashContext = TrashContext(
            locationName: eventTitle(move.from),
            deviceID: nil,
            eventIDsByPathKey: trashEventIDs,
            eventNamesByID: move.sourceTitles,
            personNamesByPathKey: [:],
            captureDatesByPathKey: [:],
            assignmentsByPathKey: trashAssignments
        )
        let journalFolder = self.journalFolder
        let boundaries = [locations.bufferRoot, locations.privateStagingRoot]
        let fallbackTrashRoot = locations.removedFilesRoot
        let fromTitle = eventTitle(move.from)
        let toTitle = eventTitle(move.to)
        // The name-clash bookkeeping walks every assignment, so it runs
        // with the job — off the main actor — from a snapshot, and only
        // when a name is actually taken.
        let needsClashInputs = items.contains { !$0.takenBy.isEmpty }
        let assignmentsSnapshot = needsClashInputs ? model.configuration.photoEventAssignments : []
        let targetAssignments = needsClashInputs ? Array(assignmentsByName(inEvent: targetEventID).values) : []
        let toEvent = move.to
        let moveID = move.id
        // The NAS renames the merged copies owe are journaled under this id,
        // so Undo of the move reverses them.
        let mergeLink = UUID()
        let folders = eventFolderSnapshot(move.sourceIDs.union([move.to.id]))
        let nasRoot = locations.nasRoot
        let queuedRenames = NASQueuedRenames()
        return model.runBackgroundJob(
            action: .organize,
            runningNote: "Moving \(ApplyPlanOverview.plural(items.count, "file")) from \(fromTitle) to \(toTitle)",
            logTitle: title,
            logDetail: "Renamed originals between event folders on the same drive. Names already in the event were compared by content: identical copies merged and their extra copy went to _Trash; different photos moved in under a free “(N)” name. Nothing was replaced. The NAS copies are renamed to match by a separate NAS Rename job (queued, and applied when the NAS is connected).",
            onSettled: { [weak self] in self?.settleMove(moveID, fromTitle: fromTitle, toTitle: toTitle) },
            operation: { progress in
                // Files other assignments still use are never trashed as a
                // spare copy — the merge only drops this assignment. Keep
                // Both names also avoid every path the target's catalog
                // already claims.
                var protectedKeys: Set<String> = []
                var takenKeys: Set<String> = []
                if needsClashInputs {
                    let leaving = Set(items.map { CatalogStore.eventAssetID($0.removed) })
                    for assignment in assignmentsSnapshot where !leaving.contains(CatalogStore.eventAssetID(assignment)) {
                        protectedKeys.insert(Self.sourceKey(assignment))
                    }
                    for item in items where !item.takenBy.isEmpty && Self.hasOtherAssignment(pointingLike: item.removed, in: assignmentsSnapshot) {
                        if let path = item.currentPath { protectedKeys.insert(EventStorageLocations.pathKey(path)) }
                    }
                    for assignment in targetAssignments {
                        if let path = locations.impliedDrivePath(for: assignment, event: toEvent, policy: targetPolicy) {
                            takenKeys.insert(EventStorageLocations.pathKey(path))
                        }
                    }
                }
                let outcome = try EventMoveService(trash: MediaTrashService(removedFilesRoot: fallbackTrashRoot)).move(
                    items,
                    title: title,
                    journalFolder: journalFolder,
                    pruneBoundaries: boundaries,
                    protectedPathKeys: protectedKeys,
                    takenPathKeys: takenKeys,
                    trashContext: trashContext,
                    eventFolders: folders
                ) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Moving", command: ""))
                }
                // The NAS owes the same renames. Journaled here, in the
                // background, right after the drive move landed; a NAS job
                // applies them as soon as the NAS is there and idle.
                let owed = NASMoveFollower.renames(forEventMove: outcome, locations: locations)
                queuedRenames.add(Self.queueNASRenames(
                    owed.moves, title: title, origin: .move, moveJournalID: outcome.report.journalID ?? moveID,
                    nasRoot: nasRoot, journalFolder: journalFolder
                ))
                queuedRenames.add(Self.queueNASRenames(
                    owed.merges, title: "\(title) (merged duplicates)", origin: .merge, moveJournalID: mergeLink,
                    nasRoot: nasRoot, journalFolder: journalFolder
                ))
                return outcome
            },
            completion: { [weak self] outcome in
                guard let self else { return "" }
                noteNASRenamesQueued(queuedRenames.count)
                let line = landMove(moveID, mergeLink: mergeLink, outcome: outcome, fromTitle: fromTitle, toTitle: toTitle)
                let full = line + NASFollowWording.queued(queuedRenames.count, connected: nasIsConnected)
                lastMoveStatusLine = (line, full)
                return full
            }
        )
    }

    /// The rename finished. The catalog changes now, and the tiles that
    /// already sit on their new board are pointed at their new paths — in
    /// place, for just the files that moved. When every file moved under
    /// its own name that is all there is to do: the boards, counts and
    /// storage strip are patched from the move report, and nothing is
    /// swept — least of all the NAS, whose copies a Buffer rename does not
    /// touch (the moved files simply are not at their new mirror path yet,
    /// which is what "not on the NAS" already means). A move that merged,
    /// renamed a clash, or left files behind falls back to re-reading the
    /// boards it touched.
    private func landMove(_ moveID: UUID, mergeLink: UUID, outcome: EventMoveOutcome, fromTitle: String, toTitle: String) -> String {
        guard let index = pendingMoves.firstIndex(where: { $0.id == moveID }) else {
            return EventMoveWording.summary(outcome, from: fromTitle, to: toTitle)
        }
        pendingMoves[index].isLanded = true
        landedMoveCount += 1
        let move = pendingMoves[index]
        let title = move.title
        if !outcome.stayed.isEmpty {
            model.recordActivity(
                action: .organize,
                state: .failed,
                title: "\(title) — \(ApplyPlanOverview.plural(outcome.stayed.count, "file")) stayed",
                summary: EventMoveWording.summary(outcome, from: fromTitle, to: toTitle, titles: move.sourceTitles),
                detail: Self.fileNameList(outcome.stayed.map { "\($0.item.fileName) — \($0.reason)" })
            )
        }
        endOptimisticMove(move)
        applyAssignmentChange(
            AssignmentChange(title: title, removed: outcome.removedAssignments, added: outcome.addedAssignments),
            touching: move.to.id,
            patchBoards: false
        )
        // One history entry for the whole click: the journal's renames, the
        // entries of files that only moved in the catalog, the copies that
        // merged (their entries and the spare copy in Trash), and the NAS
        // renames the move and the merges owe.
        recordMoveUndo(
            title: title,
            moveID: moveID,
            mergeLink: mergeLink,
            outcome: outcome,
            eventFolders: eventFolderSnapshot(move.sourceIDs.union([move.to.id]))
        )
        let trashed = (outcome.trashBatch?.entries ?? []).map { EventStorageLocations.pathKey($0.originalAbsolutePath) }
        let plainMove = outcome.stayed.isEmpty && outcome.keptBoth.isEmpty && outcome.merged.isEmpty && trashed.isEmpty
            && !move.overlapped
        TileImageLoader.shared.retarget(moves: outcome.report.moved)
        if plainMove {
            retargetMovedStacks(moves: outcome.report.moved)
            stampBoards(of: move)
            // The storage strip's rows follow in this same turn: one frame
            // draws the tiles at their new paths, the counts, and the strip,
            // instead of one board redraw per piece.
            patchPresence(afterMoving: outcome.moved, move: move)
            recordNASOnlyArrivals(outcome.moved, move: move)
            for boardID in move.leftBoards + move.joinedBoards where eventStacks[boardID] != nil {
                refreshEditTags(for: boardID)
            }
            // Only the drive changed: recount what is not on the NAS from
            // the plan and the records, without listing the NAS again.
            nasPresence.refresh(.bufferChanged)
            for boardID in Set(move.interruptedBoards + move.truthBoards) { Task { await refreshEvent(boardID) } }
        } else {
            removeFilesFromEventBoards(
                Set(outcome.report.moved.map { EventStorageLocations.pathKey($0.sourcePath) } + trashed),
                events: []
            )
            retargetMovedPaths(outcome.report.moved)
            let involved = move.sourceIDs.union([move.from.id, move.to.id])
            let affected = Set(eventStacks.keys.filter { !scopeIDs($0).isDisjoint(with: involved) })
                .union(move.interruptedBoards).union(involved)
            Task {
                for boardID in affected { await refreshEvent(boardID) }
            }
            if !trashed.isEmpty {
                Self.postTrashChanged(rescanUnsorted: false)
            }
        }
        return summaryLine(outcome, move: move)
    }

    /// Runs after every move job, landed or not. A job that failed or was
    /// cancelled never reached `landMove`: the tiles go back to their
    /// boards and the line says so. Then the next queued move may start.
    private func settleMove(_ moveID: UUID, fromTitle: String, toTitle: String) {
        guard let index = pendingMoves.firstIndex(where: { $0.id == moveID }) else { return }
        let move = pendingMoves.remove(at: index)
        if move.overlapped { boardsToRecheck.formUnion(boardsShowing(move.sourceIDs.union([move.from.id, move.to.id]))) }
        if pendingMoves.isEmpty, !boardsToRecheck.isEmpty {
            let boards = boardsToRecheck
            boardsToRecheck = []
            Task {
                for boardID in boards { await refreshEvent(boardID) }
            }
        }
        if !move.isLanded {
            rollBackOptimisticMove(move)
            let reason = model.statusMessage
            model.statusMessage = "Move to \(toTitle) did not happen — \(ApplyPlanOverview.plural(move.items.count, "file")) went back to \(fromTitle). The catalog was not changed, and the boards are re-read from the drive. \(reason)"
            model.recordActivity(
                action: .organize,
                state: .failed,
                title: "\(move.title) — did not happen",
                summary: reason,
                detail: Self.fileNameList(move.items.map(\.fileName))
            )
            // A job that died part-way may have renamed some files first:
            // the boards it touched are re-read from the disk, the truth.
            let touched = Set(move.leftBoards + move.joinedBoards + move.interruptedBoards)
            Task {
                for boardID in touched { await refreshEvent(boardID) }
            }
        }
        startPendingMoves()
    }

    /// Repoints the stacks that hold a moved file at its destination path, on
    /// every board. Found by the files a stack holds, not by its id — another
    /// board can cut the same photos into stacks under other ids. The stacks
    /// keep their ids, so a selection, focus, or open preview follows the
    /// files. Stacks holding no moved file are left alone.
    private func retargetMovedStacks(moves: [DriveMove]) {
        guard !moves.isEmpty else { return }
        var destinations: [String: String] = [:]
        for move in moves {
            destinations[EventStorageLocations.pathKey(move.sourcePath)] =
                URL(filePath: move.destinationPath, directoryHint: .notDirectory).standardizedFileURL.path
        }
        for boardID in Array(eventStacks.keys) {
            guard var stacks = eventStacks[boardID] else { continue }
            var changed = false
            for index in stacks.indices where stacks[index].items.contains(where: { item in
                destinations[item.primary.pathKey] != nil || item.companions.contains { destinations[$0.pathKey] != nil }
            }) {
                stacks[index] = stacks[index].retargetingPaths(destinations)
                changed = true
            }
            if changed { eventStacks[boardID] = stacks }
        }
    }

    /// The storage strip and badge index after a rename, from the move
    /// report: each moved file's row leaves the boards' families that held
    /// the source and joins those that hold the target, now on the drive at
    /// its destination and not (yet) on the NAS at its new mirror path.
    /// Nothing is stat'ed — the sweep on the next board open confirms it.
    private func patchPresence(afterMoving moved: [EventMoveItem], move: PendingEventMove) {
        let renamed = moved.filter { $0.move != nil }
        guard !renamed.isEmpty else { return }
        let locations = self.locations
        var paths = EventPathCache(locations: locations)
        let targetPolicy = locations.resolvedPolicy(for: move.to)
        let otherPolicy: EventStoragePolicy = targetPolicy == .buffer ? .archiveOnly : .buffer
        var replacements: [String: EventAssetPresence] = [:]
        var oldKeys: [String] = []
        var newAssets: [(key: String, asset: EventAssetPresence)] = []
        for item in renamed {
            guard let drive = item.move else { continue }
            let oldKey = drive.sourcePath.lowercased()
            let oldID = CatalogStore.eventAssetID(item.removed)
            guard let old = eventAssetsByPathKey.values.lazy.compactMap({ $0[oldKey] }).first else { continue }
            var asset = old
            asset.id = CatalogStore.eventAssetID(item.added)
            asset.assignment = item.added
            asset.drivePath = drive.destinationPath
            asset.drive = .present
            asset.driveIsLegacyLayout = false
            asset.otherDrivePath = paths.driveURL(for: item.added, event: move.to, policy: otherPolicy)?.path
            asset.otherDrive = .missing
            asset.otherDriveIsLegacyLayout = false
            if let source = locations.sourceURL(for: item.added)?.path {
                asset.sourcePath = source
                if source.lowercased() == drive.destinationPath.lowercased() {
                    asset.sourceIsDriveCopy = true
                    asset.source = .present
                }
            }
            asset.archivePath = paths.archiveURL(for: item.added, event: move.to)?.path
            if let archivePath = asset.archivePath, old.archive == .present, !old.archiveIsLegacyLayout {
                pendingNASArrivals[archivePath.lowercased()] = PendingNASArrival(
                    assetID: asset.id,
                    fromKey: old.archivePath?.lowercased(),
                    driveKey: drive.destinationPath.lowercased(),
                    verifiedAt: old.archiveVerifiedAt,
                    nasOnly: nil
                )
            }
            if asset.archive != .unavailable { asset.archive = .missing }
            asset.archiveIsLegacyLayout = false
            asset.archiveVerifiedAt = nil
            replacements[oldID] = asset
            oldKeys.append(oldKey)
            newAssets.append((drive.destinationPath.lowercased(), asset))
        }
        guard !replacements.isEmpty else { return }
        installPresenceRows(replacing: replacements, oldKeys: oldKeys, newRows: newAssets, targetEventID: move.to.id)
    }

    /// Swaps each moved file's presence row for its row at the new
    /// assignment, on every board and summary. A board held a file's source
    /// when it still has the row for it — on a family board the source is
    /// whichever subevent owned the file, so the row itself is the answer,
    /// not the clicked event. The new rows join the boards whose family holds
    /// the target.
    private func installPresenceRows(
        replacing replacements: [String: EventAssetPresence],
        oldKeys: [String],
        newRows: [(key: String, asset: EventAssetPresence)],
        targetEventID: UUID
    ) {
        for boardID in Array(eventAssetsByPathKey.keys) {
            let holdsTarget = scopeIDs(boardID).contains(targetEventID)
            for key in oldKeys { eventAssetsByPathKey[boardID]?[key] = nil }
            if holdsTarget { for entry in newRows { eventAssetsByPathKey[boardID]?[entry.key] = entry.asset } }
        }
        for eventID in Array(presence.keys) {
            guard var summary = presence[eventID] else { continue }
            let holdsTarget = scopeIDs(eventID).contains(targetEventID)
            var next: [EventAssetPresence] = []
            next.reserveCapacity(summary.assets.count)
            var replaced: Set<String> = []
            for asset in summary.assets {
                guard let replacement = replacements[asset.id] else {
                    next.append(asset)
                    continue
                }
                replaced.insert(asset.id)
                if holdsTarget { next.append(replacement) }
            }
            if holdsTarget {
                next.append(contentsOf: replacements.filter { !replaced.contains($0.key) }.values)
            }
            guard next.count != summary.assets.count || !replaced.isEmpty || holdsTarget else { continue }
            summary.assets = next
            presence[eventID] = summary
        }
    }

    /// Files with no drive copy — the Buffer is away, the NAS copy is the
    /// file — have nothing to rename on the drive; their NAS copy owes the
    /// rename. Notes what that rename will change (the tile's path, the
    /// presence row, the badge index) so it can be patched in place when
    /// it runs, and lets lookups by the old NAS path keep answering with
    /// the new assignment until then. Nothing is stat'ed: every path here is
    /// a string join, because the paths are on the share.
    private func recordNASOnlyArrivals(_ moved: [EventMoveItem], move: PendingEventMove) {
        let candidates = moved.filter { $0.move == nil && $0.nasCopy != nil }
        guard !candidates.isEmpty else { return }
        let locations = self.locations
        var paths = EventPathCache(locations: locations)
        let nasRoot = locations.nasRoot.path
        let targetPolicy = locations.resolvedPolicy(for: move.to)
        let otherPolicy: EventStoragePolicy = targetPolicy == .buffer ? .archiveOnly : .buffer
        for item in candidates {
            guard let copy = item.nasCopy,
                  EventStorageLocations.isLexicallyClean(copy.from), EventStorageLocations.isLexicallyClean(copy.to) else { continue }
            let oldPath = nasRoot + "/" + copy.from
            let newPath = nasRoot + "/" + copy.to
            let oldKey = oldPath.lowercased()
            guard let old = eventAssetsByPathKey.values.lazy.compactMap({ $0[oldKey] }).first,
                  old.archive == .present, !old.archiveIsLegacyLayout else { continue }
            var row = old
            row.id = CatalogStore.eventAssetID(item.added)
            row.assignment = item.added
            row.drivePath = Self.lexicalPath(paths.originalsRootPath(move.to, item.added.deviceID, targetPolicy), item.added.relativePath)
            row.otherDrivePath = Self.lexicalPath(paths.originalsRootPath(move.to, item.added.deviceID, otherPolicy), item.added.relativePath)
            row.driveIsLegacyLayout = false
            row.otherDriveIsLegacyLayout = false
            row.archivePath = newPath
            let arrival = NASOnlyArrival(
                oldAssetID: CatalogStore.eventAssetID(item.removed),
                oldKey: oldKey,
                oldPath: oldPath,
                newPath: newPath,
                newKey: newPath.lowercased(),
                row: row,
                targetEventID: move.to.id
            )
            pendingNASArrivals[arrival.newKey] = PendingNASArrival(
                assetID: row.id, fromKey: oldKey, driveKey: nil, verifiedAt: old.archiveVerifiedAt, nasOnly: arrival
            )
            // The tile still points at the old NAS path until the rename runs.
            if assignmentsByPathKey[oldKey] == nil { assignmentsByPathKey[oldKey] = item.added }
        }
    }

    /// `root/relative` for a clean relative path, else nil.
    private static func lexicalPath(_ root: String, _ relative: String) -> String? {
        EventStorageLocations.isLexicallyClean(relative) ? root + "/" + relative : nil
    }

    /// The queued NAS renames of moved files ran: the NAS column of just
    /// those files follows, from the rename result, on every summary and
    /// badge index that holds them — no board is re-read. False when the
    /// result holds anything this cannot answer from the move (a folder
    /// rename, a rename another move's Undo or a catch-up queued, a file
    /// left because a different one is at its new name): the caller then
    /// re-reads the boards, as it always did.
    func patchPresence(afterNASRenames result: NASFollowResult) -> Bool {
        guard result.foldersRenamed == 0, result.differs.isEmpty, result.unproven.isEmpty else { return false }
        let nasRoot = locations.nasRoot.path
        var arrivals: [String: PendingNASArrival] = [:]
        var consumed: [String] = []
        for op in result.applied {
            guard op.kind == .file,
                  let key = EventStorageLocations.joinedPathKey(rootPath: nasRoot, relativePath: op.to) else { return false }
            switch op.state {
            case .renamed, .merged:
                guard let arrival = pendingNASArrivals[key],
                      arrival.fromKey == nil || arrival.fromKey == EventStorageLocations.joinedPathKey(rootPath: nasRoot, relativePath: op.from)
                else { return false }
                arrivals[arrival.assetID] = arrival
                consumed.append(key)
            case .absent:
                // Nothing was on the NAS to bring over: the row already says so.
                consumed.append(key)
            case .failed, .pending, .cancelled:
                continue
            default:
                return false
            }
        }
        for key in consumed { pendingNASArrivals[key] = nil }
        guard !arrivals.isEmpty else { return true }
        let nasOnly = arrivals.values.compactMap(\.nasOnly)
        if !nasOnly.isEmpty { applyNASOnlyArrivals(nasOnly) }
        for eventID in Array(presence.keys) {
            guard var summary = presence[eventID] else { continue }
            var next = summary.assets
            var changed = false
            for index in next.indices where next[index].archive == .missing {
                guard let arrival = arrivals[next[index].id] else { continue }
                next[index].archive = .present
                next[index].archiveVerifiedAt = arrival.verifiedAt
                next[index].archiveIsLegacyLayout = false
                changed = true
            }
            guard changed else { continue }
            summary.assets = next
            presence[eventID] = summary
        }
        for boardID in Array(eventAssetsByPathKey.keys) {
            for arrival in arrivals.values {
                guard let driveKey = arrival.driveKey,
                      var row = eventAssetsByPathKey[boardID]?[driveKey], row.archive == .missing else { continue }
                row.archive = .present
                row.archiveVerifiedAt = arrival.verifiedAt
                row.archiveIsLegacyLayout = false
                eventAssetsByPathKey[boardID]?[driveKey] = row
            }
        }
        return true
    }

    /// The NAS renames of files with no drive copy ran: their tiles point at
    /// the new NAS path, their rows and badge entries are the new
    /// assignment's, on every board — from strings, with no stat of the share.
    private func applyNASOnlyArrivals(_ arrivals: [NASOnlyArrival]) {
        var destinations: [String: String] = [:]
        var moves: [DriveMove] = []
        for arrival in arrivals {
            destinations[arrival.oldKey] = arrival.newPath
            moves.append(DriveMove(sourcePath: arrival.oldPath, destinationPath: arrival.newPath, byteCount: arrival.row.assignment.fileSize))
            if assignmentsByPathKey[arrival.oldKey]?.eventID == arrival.row.assignment.eventID { assignmentsByPathKey[arrival.oldKey] = nil }
        }
        TileImageLoader.shared.retarget(moves: moves, standardized: true)
        for boardID in Array(eventStacks.keys) {
            guard var stacks = eventStacks[boardID] else { continue }
            var changed = false
            for index in stacks.indices where stacks[index].items.contains(where: { item in
                destinations[item.primary.pathKey] != nil || item.companions.contains { destinations[$0.pathKey] != nil }
            }) {
                stacks[index] = stacks[index].retargetingPaths(destinations, literal: true)
                changed = true
            }
            if changed { eventStacks[boardID] = stacks }
        }
        // Rows are grouped by the event they were moved to: each set of rows
        // joins the boards whose family holds that event.
        for (targetID, group) in Dictionary(grouping: arrivals, by: \.targetEventID) {
            installPresenceRows(
                replacing: Dictionary(group.map { ($0.oldAssetID, $0.row) }, uniquingKeysWith: { first, _ in first }),
                oldKeys: group.map(\.oldKey),
                newRows: group.map { ($0.newKey, $0.row) },
                targetEventID: targetID
            )
        }
    }

    /// Another assignment in the same event resolves to the same file (same
    /// device folder and relative path) — `hasOtherAssignment` over a
    /// snapshot, for use off the main actor.
    nonisolated private static func hasOtherAssignment(pointingLike assignment: PhotoEventAssignment, in assignments: [PhotoEventAssignment]) -> Bool {
        let key = sourceKey(assignment)
        return assignments.contains { other in
            other.eventID == assignment.eventID
                && other.deviceID == assignment.deviceID
                && Self.nameKey(other.relativePath) == Self.nameKey(assignment.relativePath)
                && sourceKey(other) != key
        }
    }

    /// Same rule as `moveStacks`: every click ends in a readable result —
    /// a queued or running job, an already-organized note, or a reason the
    /// files stayed — never a bare return while the board is loading.
    func returnToUnsorted(_ stackIDs: Set<String>, eventID: UUID) {
        guard let event = event(eventID) else {
            refuseMove("Return to Unsorted", "That event no longer exists — nothing was returned.")
            return
        }
        guard let stacks = eventStacks[eventID] else {
            queueReturnToUnsorted(stackIDs, in: event)
            return
        }
        returnLoadedStacks(visibleSelection(stackIDs, on: eventID), from: event)
    }

    /// The Return to Unsorted counterpart of `queueMove`: the click waits
    /// for the board to paint, then runs the same return.
    private func queueReturnToUnsorted(_ stackIDs: Set<String>, in event: SavedCameraEvent) {
        model.statusMessage = "Return to Unsorted queued — \(eventTitle(event)) is still loading. It runs as soon as the board appears."
        Task { @MainActor [weak self] in
            guard let self else { return }
            await waitForBoard(event.id)
            returnLoadedStacks(visibleSelection(stackIDs, on: event.id), from: event)
        }
    }

    private func returnLoadedStacks(_ targetStacks: [OrganizeStack], from event: SavedCameraEvent) {
        let eventID = event.id
        let resolution = resolveMoveCandidates(for: targetStacks, in: event)
        let assets = resolution.candidates
        guard !assets.isEmpty else {
            let family = subevents(of: eventID).isEmpty ? "" : " or its subevents"
            refuseMove(
                "Return to Unsorted",
                targetStacks.isEmpty
                    ? "Nothing to return — that selection is not on \(eventTitle(event))'s board any more, or a filter hides it. Click the stacks again."
                    : "Nothing to return — the catalog has no entry for those files in \(eventTitle(event))\(family).",
                files: targetStacks.isEmpty ? [] : resolution.unresolved
            )
            return
        }
        // A family board's files each leave their own event.
        let owners = Set(assets.map(\.assignment.eventID)).union([eventID])
        let mounted = VolumeInfo.mountedVolumePaths()
        var removed: [PhotoEventAssignment] = []
        var removedSources: [String?] = []
        var moves: [DriveMove] = []
        var adopted = 0
        var blocked = 0
        var awayCount = 0
        var nasOnly = 0
        for asset in assets {
            if asset.sourceIsDriveCopy {
                adopted += 1
                continue
            }
            let driveCopy = asset.drive == .present ? asset.drivePath : (asset.otherDrive == .present ? asset.otherDrivePath : nil)
            if let driveCopy {
                // A card that is not plugged in is not a place to put a file.
                guard asset.source != .unavailable else {
                    awayCount += 1
                    continue
                }
                guard asset.source == .missing, let source = asset.sourcePath,
                      VolumeInfo.isSameVolume(URL(fileURLWithPath: driveCopy), URL(fileURLWithPath: source).deletingLastPathComponent(), mountedVolumes: mounted) else {
                    blocked += 1
                    continue
                }
                moves.append(DriveMove(sourcePath: driveCopy, destinationPath: source, byteCount: asset.assignment.fileSize))
            } else if asset.source != .present, asset.archive == .present {
                // Its only copy is on the NAS: dropping the assignment would
                // leave a photo nothing in the app can show.
                nasOnly += 1
                continue
            }
            removed.append(asset.assignment)
            removedSources.append(driveCopy)
        }
        let notes = [
            adopted > 0 ? "\(adopted) file(s) were already organized on the drive and have no unsorted folder to return to." : nil,
            blocked > 0 ? "\(blocked) file(s) still exist on their card or another drive; take the drive copy off first." : nil,
            awayCount > 0 ? "\(awayCount) file(s) came from a card or drive that isn't connected; connect it to return them." : nil,
            nasOnly > 0 ? "\(nasOnly) file(s) are only on the NAS, which has no unsorted folder to return them to." : nil,
        ].compactMap { $0 }.joined(separator: " ")
        guard !removed.isEmpty else {
            refuseMove(
                "Return to Unsorted",
                notes.isEmpty ? "Nothing to return." : notes,
                files: assets.map { ($0.assignment.relativePath as NSString).lastPathComponent }
            )
            return
        }
        guard !moves.isEmpty else {
            let change = AssignmentChange(title: "Return to Unsorted", removed: removed, added: [])
            // The open board drops the stacks in place — a refresh would
            // only re-derive what the patch already applied.
            applyAssignmentChange(change, touching: nil)
            recordAssignmentUndo(change)
            model.statusMessage = "Returned \(removed.count) file(s) from \(eventTitle(event)) to Unsorted. \(notes)"
            return
        }
        let journalFolder = self.journalFolder
        let locations = self.locations
        let boundaries = [locations.bufferRoot, locations.privateStagingRoot]
        let title = "Return to Unsorted from \(eventTitle(event))"
        let plannedMoves = moves
        let plannedRemoved = removed
        let plannedSources = removedSources
        let plannedFolders = eventFolderSnapshot(owners)
        model.runBackgroundJob(
            action: .organize,
            runningNote: "Returning \(moves.count) file(s) to their unsorted folders",
            logTitle: title,
            logDetail: "Renamed originals back to their original unsorted folders on the same drive.",
            operation: { progress in
                try DriveMoveService().apply(
                    plannedMoves,
                    title: title,
                    journalFolder: journalFolder,
                    removedAssignments: plannedRemoved,
                    addedAssignments: [],
                    assignmentMoveSources: plannedSources,
                    eventFolders: plannedFolders,
                    pruneBoundaries: boundaries
                ) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Returning", command: ""))
                }
            },
            completion: { [weak self] report in
                guard let self else { return "" }
                let failed = Set(report.skipped.map { EventStorageLocations.pathKey($0.move.destinationPath) })
                let applied = removed.filter { !failed.contains(Self.sourceKey($0)) }
                applyAssignmentChange(AssignmentChange(title: title, removed: applied, added: []), touching: nil)
                recordJournalUndo(title: title, report: report)
                // A path is one file: it leaves every board that draws it, the
                // family boards above the owner's included.
                removeFilesFromEventBoards(
                    Set(report.moved.map { EventStorageLocations.pathKey($0.sourcePath) }),
                    events: []
                )
                retargetMovedPaths(report.moved)
                refreshLatestJournal()
                for location in unsortedLocations where sources[location.id]?.result != nil {
                    scan(location, force: true)
                }
                let boards = boardsShowing(owners)
                Task {
                    for boardID in boards { await self.refreshEvent(boardID) }
                }
                return "Returned \(applied.count) file(s) to Unsorted. \(notes)"
            }
        )
    }

    // MARK: - NAS, drive, and source

    /// True when the NAS mirror root is mounted and exists.
    /// Cached per connectivity revision like the sidebar's checks, so a
    /// toolbar re-render never stats a slow share.
    var nasIsConnected: Bool {
        isConnected(folder: locations.nasRoot)
    }

    /// The configured SMB share, when there is one to open.
    var nasShareURL: URL? {
        let text = model.configuration.nasSMBURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased() == "smb", url.host != nil else { return nil }
        return url
    }

    /// Mounts the configured SMB share in the background with the
    /// keychain's saved password (NetFS, no dialog), falling back to Finder,
    /// which asks for one. The volume observer refreshes once it mounts.
    func connectToNAS() {
        guard let url = nasShareURL else {
            model.statusMessage = "Set the NAS share address (smb://…) in Settings → Locations, or connect the share in Finder."
            return
        }
        if nasConnection.isStarted {
            model.statusMessage = "Connecting to the NAS…"
            nasConnection.connect()
        } else if !NSWorkspace.shared.open(url) {
            model.statusMessage = "Could not open \(url.absoluteString)."
        }
    }

    /// The NAS connection's inputs from Settings.
    var nasConnectionSettings: NASConnectionSettings {
        NASConnectionSettings(
            nasRoot: locations.nasRoot,
            shareURL: nasShareURL,
            automatic: model.configuration.nasAutoConnect
        )
    }

    /// Launch: status, auto-connect, and the Wi-Fi guard. App only.
    func startNASConnection() {
        nasConnection.start(settings: nasConnectionSettings)
        nasPresence.isEnabled = true
        nasPresence.refresh(.launch)
        refreshNASRenameBacklog()
    }

    func nasSettingsChanged() {
        nasConnection.settingsChanged(nasConnectionSettings)
    }

    /// True while something may be reading or writing the NAS: any file
    /// job (sync, Take Off Drive, face scans, moves), a speed test, or a
    /// card transfer. The guard never unmounts then; the unmount itself
    /// is a normal one, which macOS refuses while any file is open.
    var nasIsInUse: Bool {
        model.isBusy || model.isStorageBenchmarkRunning || model.transferQueue?.state == .running
    }

    /// One-way Buffer → NAS copy of the event and its subevents.
    func syncToNAS(_ eventID: UUID) {
        guard let event = event(eventID) else { return }
        nasConnection.prepareForNASJob { [weak self] in
            guard let self else { return }
            // One event's sync renames what moved into place instead of
            // copying it; the stale-duplicate sweep is Sync All's.
            startNASSync(events: eventFamily(eventID), title: eventTitle(event), refresh: [eventID], catchUp: true, reconcile: false)
        }
    }

    /// Sync All to NAS: the confirmation first, listing each event's files
    /// not on the NAS yet. A stale or records-only answer is re-checked
    /// while the sheet is open.
    func requestSyncAllToNAS() {
        guard !model.configuration.savedEvents.isEmpty else {
            model.statusMessage = "There are no events to sync."
            return
        }
        let report = nasPresence.report
        let stale = report?.listedAt.map { Date().timeIntervalSince($0) > NASPresenceSchedule.automaticInterval } ?? true
        if nasIsConnected, stale, !nasPresence.isChecking {
            nasPresence.refresh(.manual)
        }
        syncAllReconcile = true
        reconcilePreview = nil
        syncAllRequest = SyncAllToNASRequest()
        refreshReconcilePreview()
    }

    /// Why Sync All to NAS cannot start right now, or nil when it can.
    var syncAllBlocker: String? {
        if model.configuration.savedEvents.isEmpty { return "There are no events to sync." }
        if !nasIsConnected {
            return nasShareURL == nil
                ? "The NAS is not connected. Mount the share in Finder, or set its smb:// address in Settings → Locations."
                : "The NAS is not connected — Connect to NAS first."
        }
        if model.isBusy { return "Another file job is running. Sync All once it has finished." }
        return nil
    }

    /// Files of this event's own folder not on the NAS yet, per the NAS
    /// presence index; nil before it has answered.
    func nasPendingTotals(for eventID: UUID) -> NASPresenceTotals? {
        nasPresence.report?.byEvent[eventID]
    }

    /// The same for the event and its subevents — what its board covers.
    func nasPendingFamilyTotals(for eventID: UUID) -> NASPresenceTotals? {
        nasPresence.report?.totals(for: scopeIDs(eventID))
    }

    /// The inputs of a NAS presence check, read when it starts.
    private var nasPresenceContext: NASPresenceContext {
        let locations = self.locations
        return NASPresenceContext(
            events: model.configuration.savedEvents,
            locations: locations,
            catalogURL: URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath)),
            configuration: model.configuration,
            nasAvailable: nasIsConnected,
            nasJobRunning: nasIsInUse
        )
    }

    /// A new NAS presence answer: the open board re-reads its NAS place
    /// from the listing when its family's numbers moved.
    private func nasPresenceChanged(from old: NASPresenceReport?, to new: NASPresenceReport) {
        if syncAllRequest != nil { refreshReconcilePreview() }
        guard case .event(let eventID) = selection, presence[eventID] != nil else { return }
        // A recount from the drive alone (a move, an Apply) learned nothing
        // new about the NAS, and the board was patched or re-read by the
        // job itself — sweeping it again would stat the NAS for nothing.
        guard old?.listedAt != new.listedAt else { return }
        let family = scopeIDs(eventID)
        guard old?.totals(for: family) != new.totals(for: family) || old?.listedAt == nil && new.listedAt != nil else { return }
        Task { await refreshEvent(eventID) }
    }

    /// One-way Buffer → NAS copy of every event.
    func syncAllToNAS() {
        let events = model.configuration.savedEvents
        guard !events.isEmpty else {
            model.statusMessage = "There are no events to sync."
            return
        }
        nasConnection.prepareForNASJob { [weak self] in
            let reconcile = self?.syncAllReconcile ?? false
            self?.startNASSync(
                events: events,
                title: "all events",
                refresh: events.filter { $0.parentEventID == nil }.map(\.id),
                catchUp: reconcile,
                reconcile: reconcile
            )
        }
    }

    /// `catchUp`: NAS copies of files moved before the NAS followed them
    /// are renamed to their new paths instead of copied again. `reconcile`:
    /// after the copy, stale NAS duplicates of files already at their right
    /// path are set aside (never deleted). Renames queued by moves are
    /// always applied first.
    private func startNASSync(events: [SavedCameraEvent], title: String, refresh: [UUID], catchUp: Bool, reconcile: Bool) {
        let locations = self.locations
        // A live check: the user just asked, so the cached answer may be old.
        guard VolumeInfo.isAvailable(locations.nasRoot), FileManager.default.fileExists(atPath: locations.nasRoot.path) else {
            model.statusMessage = "The NAS is not connected (\(locations.nasRoot.path))."
                + (nasShareURL == nil ? "" : " Use Connect to NAS… first.")
            return
        }
        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
        let reportsFolder = catalogURL.deletingLastPathComponent().appendingPathComponent("NAS Sync", isDirectory: true)
        let nasRoot = locations.nasRoot
        let options = NASSyncOptions.from(configuration: model.configuration, nasRoot: nasRoot)
        // Sync to NAS feeds its own recorder: per-second speed from the
        // engine, and a row per file.
        let recorder = model.makeHistoryRecorder(action: .syncBuffer, title: "Synced \(title) to the NAS")
        let nasPresence = self.nasPresence
        let renameQueue = nasRenameQueue
        let assignments = model.configuration.photoEventAssignments
        model.runBackgroundJob(
            action: .syncBuffer,
            runningNote: "Syncing \(title) to the NAS",
            logTitle: "Synced \(title) to the NAS",
            logDetail: "Copied only files missing on the NAS, each to the same path it has on the drive, \(options.parallelTransfers) at a time, and checked every copy's SHA-256 against the drive copy's (\(options.remoteVerifier == nil ? "re-read from the NAS" : "hashed on the NAS over SSH")) before naming it. Existing files were never overwritten.",
            destinationPath: nasRoot.path,
            history: recorder,
            // Settled either way (done, failed, stopped): list the synced
            // folders again — unthrottled, and only those.
            onSettled: { nasPresence.refresh(.syncFinished, scope: events) },
            operation: { progress in
                progress(BackgroundJobUpdate(progress: 0.02, note: "Sync to NAS: renaming NAS copies of moved files"))
                let store = try? NASSyncStore(catalogURL: catalogURL)
                let follower = NASMoveFollower(store: store, remoteVerifier: options.remoteVerifier, queue: renameQueue)
                let owned = NASCatchUp.ownedKeys(assignments: assignments, locations: locations)
                // Queued renames first, so a moved file is never copied a
                // second time; then the drive is planned, and NAS copies of
                // files moved before the NAS followed are renamed into place.
                let prepared = try follower.prepareSync(
                    events: events, locations: locations, nasRoot: nasRoot, ownedKeys: owned, catchUp: catchUp
                ) { update in
                    progress(DashboardModel.jobUpdate(from: update, lowerBound: 0.02, upperBound: 0.03, notePrefix: "Sync to NAS", command: ""))
                }
                let plan = prepared.plan
                var follow = prepared.follow
                progress(BackgroundJobUpdate(progress: 0.03, note: "Sync to NAS: copying"))
                let report = try NASSyncService(store: store, options: options, recorder: recorder).sync(plan, nasRoot: nasRoot) { update in
                    progress(DashboardModel.jobUpdate(from: update, lowerBound: 0.03, upperBound: 0.99, notePrefix: "Sync to NAS", command: ""))
                }
                if reconcile, !Task.isCancelled {
                    follow.add(try follower.reconcile(plan: plan, ownedKeys: owned, locations: locations, nasRoot: nasRoot))
                }
                let reportPath = Self.writeNASSyncReport(report, plan: plan, title: title, to: reportsFolder)
                return NASSyncJobOutcome(
                    report: report, plan: plan, reportPath: reportPath, follow: follow,
                    queuedRenamesLeft: renameQueue.pendingRenameCount(nasRoot: nasRoot.path)
                )
            },
            completion: { [weak self] outcome in
                self?.nasRenamesApplied(outcome.follow, remaining: outcome.queuedRenamesLeft)
                // What the sync proved on the NAS counts at once, before
                // the folders are listed again.
                let proven = Set(outcome.report.copied + outcome.report.matchedExisting + outcome.report.alreadyVerified)
                self?.nasPresence.noteSynced(outcome.plan.items.filter { proven.contains($0.relativePath) })
                for eventID in refresh {
                    Task { await self?.refreshEvent(eventID) }
                }
                let report = outcome.report
                var parts: [String] = []
                if !report.hashMismatches.isEmpty {
                    parts.append("\(report.hashMismatches.count) NAS cop\(report.hashMismatches.count == 1 ? "y" : "ies") did NOT match the drive's SHA-256 (removed; check the NAS pool's health)")
                }
                parts += ["\(report.copied.count) copied and verified", "\(report.matchedExisting.count + report.alreadyVerified.count) already on the NAS"]
                if !report.conflicts.isEmpty { parts.append("\(report.conflicts.count) conflict(s) left untouched") }
                if !report.failed.isEmpty { parts.append("\(report.failed.count) failed and skipped") }
                if report.notAttempted > 0 { parts.append("\(report.notAttempted) not attempted") }
                if !outcome.plan.outsideLayout.isEmpty { parts.append("\(outcome.plan.outsideLayout.count) folder(s) outside Originals/Edited not synced") }
                if !outcome.plan.inLegacyLayout.isEmpty {
                    parts.append("\(outcome.plan.inLegacyLayout.count) already on the NAS in the old archive layout, not copied again (run the NAS layout migration for this event, then sync)")
                }
                if !outcome.plan.unreadable.isEmpty { parts.append("\(outcome.plan.unreadable.count) drive folder(s) unreadable") }
                parts.insert(contentsOf: outcome.follow.clauses, at: 0)
                var summary = "Sync to NAS for \(title): " + parts.joined(separator: ", ") + "."
                if let stopped = report.stoppedReason { summary += " " + stopped }
                if let path = outcome.reportPath, !report.succeeded { summary += " Details: \(path)" }
                guard report.succeeded, outcome.plan.unreadable.isEmpty else {
                    throw ToolkitError.commandFailed(summary)
                }
                return summary
            }
        )
    }

    /// Every issue of a sync, per file, as JSON beside the catalog — a job
    /// note cannot hold 11,000 lines.
    nonisolated private static func writeNASSyncReport(_ report: NASSyncReport, plan: NASSyncPlan, title: String, to folder: URL) -> String? {
        struct Document: Encodable {
            var title: String
            var finishedAt: Date
            var report: NASSyncReport
            var outsideLayout: [String]
            var refused: [NASSyncIssue]
            var unreadable: [NASSyncIssue]
            var skippedJunk: Int
            var inLegacyLayout: [String]
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = folder.appendingPathComponent("sync-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(Document(
                title: title,
                finishedAt: Date(),
                report: report,
                outsideLayout: plan.outsideLayout,
                refused: plan.refused,
                unreadable: plan.unreadable,
                skippedJunk: plan.skippedJunk,
                inLegacyLayout: plan.inLegacyLayout
            )).write(to: url, options: .withoutOverwriting)
            return url.path
        } catch {
            return nil
        }
    }

    func requestRemoveFromDrive(_ eventID: UUID) {
        guard let summary = presence[eventID] else { return }
        let eligible = summary.assets.filter { ($0.drive == .present || $0.otherDrive == .present) && $0.archiveIsTrusted }
        guard !eligible.isEmpty else {
            model.statusMessage = "Sync to NAS first. Only files whose NAS copy Sync to NAS verified can leave the drive."
            return
        }
        pendingRemoval = RemovalRequest(
            kind: .drive,
            eventID: eventID,
            fileCount: eligible.count,
            byteCount: eligible.reduce(Int64(0)) { $0 + $1.assignment.fileSize }
        )
    }

    func requestRemoveFromSource(_ eventID: UUID) {
        guard let summary = presence[eventID] else { return }
        let eligible = summary.assets.filter { $0.isOnSeparateSource && $0.drive == .present }
        guard !eligible.isEmpty else {
            model.statusMessage = "Put the files on the drive first. Only files with a matching drive copy can be removed from the source."
            return
        }
        pendingRemoval = RemovalRequest(
            kind: .source,
            eventID: eventID,
            fileCount: eligible.count,
            byteCount: eligible.reduce(Int64(0)) { $0 + $1.assignment.fileSize }
        )
    }

    func confirmRemoval(_ request: RemovalRequest, confirmation: String) {
        pendingRemoval = nil
        switch request.kind {
        case .drive:
            // Take Off Drive re-reads every NAS copy: over Ethernet if it can.
            nasConnection.prepareForNASJob { [weak self] in
                self?.removeFromDrive(request.eventID, confirmation: confirmation)
            }
        case .source: removeFromSource(request.eventID, confirmation: confirmation)
        }
    }

    private func removeFromDrive(_ eventID: UUID, confirmation: String) {
        guard let event = event(eventID), let summary = presence[eventID] else { return }
        let locations = self.locations
        var pairs: [VerifiedRemovalPair] = []
        // Only NAS copies Sync to NAS verified; VerifiedRemovalService
        // re-hashes each pair regardless.
        for asset in summary.assets where asset.archiveIsTrusted {
            guard let archive = asset.archivePath else { continue }
            // Family scope: each asset's folders resolve through its own
            // event — a subevent's copies sit in its nested event folder.
            let owner = self.event(asset.assignment.eventID) ?? event
            let policy = locations.resolvedPolicy(for: owner)
            let eventFolderPath = locations.layout(for: owner, deviceID: nil).eventFolderPath
            let cameraFolder = locations.layout(for: owner, deviceID: asset.assignment.deviceID).cameraFolder
            let copies: [(CatalogPresenceState, String?, EventStoragePolicy)] = [
                (asset.drive, asset.drivePath, policy),
                (asset.otherDrive, asset.otherDrivePath, policy == .buffer ? .archiveOnly : .buffer),
            ]
            for (state, path, copyPolicy) in copies where state == .present {
                guard let path else { continue }
                pairs.append(VerifiedRemovalPair(
                    driveCopyPath: path,
                    referencePath: archive,
                    batchRelativePath: "\(copyPolicy == .buffer ? "Buffer" : "Private")/\(eventFolderPath)/\(EventStorageLocations.originalsFolderName)/\(cameraFolder)/\(asset.assignment.relativePath)",
                    byteCount: asset.assignment.fileSize
                ))
            }
        }
        guard !pairs.isEmpty else { return }
        let plannedPairs = pairs
        let trashRoot = locations.removedFilesRoot
        let boundaries = [locations.bufferRoot, locations.privateStagingRoot]
        model.runBackgroundJob(
            action: .freeUp,
            runningNote: "Rechecking \(pairs.count) drive copies of \(eventTitle(event)) against the NAS",
            logTitle: "Took \(eventTitle(event)) off the drive",
            logDetail: "Re-hashed every drive copy against its NAS copy, then moved the drive copies into the drive's hidden _Trash folder. Nothing was deleted.",
            operation: { progress in
                try VerifiedRemovalService().moveVerifiedCopiesAside(
                    pairs: plannedPairs,
                    trashRoot: trashRoot,
                    confirmation: confirmation,
                    pruneBoundaries: boundaries
                ) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Taking off the drive", command: ""))
                }
            },
            completion: { [weak self] report in
                Task { await self?.refreshEvent(eventID) }
                guard report.moved.count == pairs.count else {
                    var reasons: [String] = []
                    if !report.differ.isEmpty { reasons.append("\(report.differ.count) differ from the NAS") }
                    if !report.missingReference.isEmpty { reasons.append("\(report.missingReference.count) NAS copies are missing") }
                    if !report.missingDriveCopy.isEmpty { reasons.append("\(report.missingDriveCopy.count) drive copies are missing") }
                    if !report.errors.isEmpty { reasons.append("\(report.errors.count) could not be checked") }
                    throw ToolkitError.commandFailed(
                        (report.moved.isEmpty ? "Nothing left the drive" : "\(report.moved.count) left the drive, then it stopped safely")
                            + ": " + reasons.joined(separator: "; ") + "."
                    )
                }
                return "Took \(report.moved.count) file(s) (\(report.movedBytes.formattedBytes)) of \(self?.eventTitle(event) ?? event.name) off the drive. They stay recoverable in \(report.batchPath ?? trashRoot.path) until you empty it in Trash."
            }
        )
    }

    private func removeFromSource(_ eventID: UUID, confirmation: String) {
        guard let event = event(eventID), let summary = presence[eventID] else { return }
        let locations = self.locations
        var groups: [String: SourceCleanupGroup] = [:]
        for asset in summary.assets where asset.isOnSeparateSource && asset.drive == .present {
            let sourceRoot = URL(fileURLWithPath: DashboardModel.expandedPath(asset.assignment.sourceRootPath), isDirectory: true)
            // Family scope: the drive copy the source is checked against
            // sits in the asset's own event's nested Originals folder — or,
            // on a drive not migrated yet, its legacy Card Copy — exactly
            // where the presence sweep found it.
            let owner = self.event(asset.assignment.eventID) ?? event
            let driveRoot = asset.driveRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? locations.originalsRoot(for: owner, deviceID: asset.assignment.deviceID, policy: locations.resolvedPolicy(for: owner))
            let key = sourceRoot.path + "\u{0}" + driveRoot.path
            groups[key, default: SourceCleanupGroup(sourceRoot: sourceRoot, driveRoot: driveRoot, files: [])].files.append(
                FileRecord(path: asset.assignment.relativePath, size: asset.assignment.fileSize, modifiedAt: asset.assignment.modifiedAt)
            )
        }
        let cleanupGroups = Array(groups.values)
        guard !cleanupGroups.isEmpty else { return }
        let total = cleanupGroups.reduce(0) { $0 + $1.files.count }
        model.runBackgroundJob(
            action: .freeUp,
            runningNote: "Rechecking \(total) source files of \(eventTitle(event)) against the drive",
            logTitle: "Freed source space for \(eventTitle(event))",
            logDetail: "Re-hashed each source file against its drive copy before permanently removing only matching source originals.",
            operation: { progress in
                var removed = 0
                var bytes: Int64 = 0
                for group in cleanupGroups {
                    let report = try SourceCleanupService().removeVerifiedFiles(
                        sourceRoot: group.sourceRoot,
                        bufferRoot: group.driveRoot,
                        files: group.files,
                        confirmation: confirmation
                    ) { update in
                        progress(DashboardModel.jobUpdate(from: update, notePrefix: "Freeing source space", command: ""))
                    }
                    removed += report.removed.count
                    bytes += report.removedBytes
                    guard report.removed.count == group.files.count else {
                        throw ToolkitError.commandFailed(
                            "Removed \(removed) source file(s), then stopped: \(report.differ.count) differ, \(report.missingBuffer.count) drive copies missing, \(report.errors.count) could not be checked. Drive copies were untouched."
                        )
                    }
                }
                return (removed, bytes)
            },
            completion: { [weak self] outcome in
                Task { await self?.refreshEvent(eventID) }
                return "Removed \(outcome.0) checksum-matched file(s) from the source, freeing \(outcome.1.formattedBytes). Drive copies remain."
            }
        )
    }

    /// Tells the Trash window to reload. `rescanUnsorted` is false for a move
    /// that already dropped the files from the in-memory boards — a true
    /// value, or no flag, still makes unsorted folders rescan so a restore
    /// can show the files that came back.
    static func postTrashChanged(rescanUnsorted: Bool) {
        NotificationCenter.default.post(
            name: .cameraToolkitMediaTrashChanged,
            object: nil,
            userInfo: ["rescanUnsorted": rescanUnsorted]
        )
    }

    // MARK: - Trash

    /// Moves every file of the given stacks — primaries and companions — into
    /// the drive-local `.Camera Toolkit/_Trash` batch on whichever volume
    /// each file lives. Recoverable from the Trash window.
    func trash(stackIDs: Set<String>, from locationID: UUID) {
        guard let result = sources[locationID]?.result else { return }
        let items = result.stacks.filter { stackIDs.contains($0.id) }.flatMap(\.items)
        requestTrash(items, from: locationID)
    }

    func requestTrash(_ items: [OrganizeItem], from locationID: UUID) {
        guard let location = location(locationID) else { return }
        presentTrash(items: items, locationID: locationID, eventID: nil, locationName: location.name)
    }

    func requestTrash(_ items: [OrganizeItem], fromEvent eventID: UUID) {
        let name = event(eventID).map { eventTitle($0) } ?? "this event"
        presentTrash(items: items, locationID: nil, eventID: eventID, locationName: name)
    }

    func requestTrash(stackIDs: Set<String>, fromEvent eventID: UUID) {
        let items = (eventStacks[eventID] ?? []).filter { stackIDs.contains($0.id) }.flatMap(\.items)
        requestTrash(items, fromEvent: eventID)
    }

    func confirmTrash(_ request: PendingTrashRequest) {
        pendingTrash = nil
        if let locationID = request.locationID {
            trashItems(request.items, from: locationID, preservingAssignmentKeys: request.preservedAssignmentKeys)
        } else if let eventID = request.eventID {
            trashItems(request.items, fromEvent: eventID)
        }
    }

    private func presentTrash(items: [OrganizeItem], locationID: UUID?, eventID: UUID?, locationName: String) {
        let files = items.flatMap(\.files)
        guard !files.isEmpty else {
            model.statusMessage = "Select photos first, then move them to Trash."
            return
        }
        let destinations = MediaTrashService.previewDestinations(
            files: files,
            removedFilesRoot: locations.removedFilesRoot
        )
        pendingTrash = PendingTrashRequest(
            items: items,
            locationID: locationID,
            eventID: eventID,
            locationName: locationName,
            fileCount: files.count,
            byteCount: files.reduce(Int64(0)) { $0 + $1.size },
            sampleNames: files.prefix(3).map { $0.url.lastPathComponent },
            destinations: destinations
        )
    }

    /// Moves individual frames — each item's primary plus its sidecars and
    /// RAW+JPEG companions — into the drive-local `_Trash`. The burst preview
    /// calls this for single frames; a stack left with fewer items is
    /// restacked automatically when the scan result updates.
    func trashItems(_ items: [OrganizeItem], from locationID: UUID, preservingAssignmentKeys: Set<String> = []) {
        guard let location = location(locationID) else { return }
        let files = items.flatMap(\.files)
        guard !files.isEmpty else {
            model.statusMessage = "Select photos first, then move them to Trash."
            return
        }
        guard !model.isBusy, !model.isStorageBenchmarkRunning else {
            model.statusMessage = "Another file job is already running. Wait for it to finish, then try again."
            return
        }

        refreshIndexIfNeeded()
        // Capture each file's current event so the manifest records where it
        // lived. The assignments are dropped when the job says which files
        // really went to Trash — a file that stayed in place keeps its event.
        // The history entry (`recordTrashUndo`) carries the dropped entries
        // with the Trash batch: Undo restores the files first and puts the
        // entries back only for the files that really came back.
        var eventIDs: [String: UUID] = [:]
        var droppable: [String: PhotoEventAssignment] = [:]
        for file in files {
            let key = file.pathKey
            if let assignment = assignmentsByPathKey[key] {
                eventIDs[key] = assignment.eventID
                if !preservingAssignmentKeys.contains(key) {
                    droppable[key] = assignment
                }
            }
        }

        let trashedStackIDs = affectedStackIDs(for: items, in: locationID)
        let context = TrashContext(
            locationName: location.name,
            deviceID: deviceID(for: location),
            eventIDsByPathKey: eventIDs,
            eventNamesByID: trashEventNames(for: eventIDs),
            personNamesByPathKey: trashPersonNames(for: files),
            captureDatesByPathKey: trashCaptureDates(for: items),
            assignmentsByPathKey: droppable.mapValues { [$0] }
        )
        let originRoot = URL(fileURLWithPath: DashboardModel.expandedPath(location.path), isDirectory: true).standardizedFileURL
        let fallbackTrashRoot = locations.removedFilesRoot
        DebugLog.shared.log(
            "trash.start",
            subsystem: .trash,
            level: .info,
            detail: "\(files.count) file(s)"
        )
        model.runBackgroundJob(
            action: .organize,
            runningNote: "Moving \(files.count) file(s) to Trash",
            logTitle: "Moved files to Trash",
            logDetail: "Renamed files into the drive-local .Camera Toolkit/_Trash folder and wrote a manifest recording where each file lived. Nothing was deleted; batches are restorable from the Trash window.",
            operation: { progress in
                try MediaTrashService(removedFilesRoot: fallbackTrashRoot).trash(
                    files: files,
                    originRoot: originRoot,
                    context: context
                ) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Moving to Trash", command: ""))
                }
            },
            completion: { [weak self] batch in
                guard let self else { return "" }
                let movedKeys = Set(batch.entries.map { EventStorageLocations.pathKey($0.originalAbsolutePath) })
                let dropped = movedKeys.compactMap { droppable[$0] }
                if !dropped.isEmpty {
                    applyAssignmentChange(AssignmentChange(title: "Move to Trash", removed: dropped, added: []), touching: nil)
                }
                recordTrashUndo(title: "Move to Trash", batch: batch, dropped: dropped, originRoot: originRoot.path)
                if let result = sources[locationID]?.result {
                    sources[locationID]?.result = result.removingFiles(withPathKeys: movedKeys)
                }
                // Only what really went to Trash leaves the selection; a trash
                // that moved nothing (its folder could not be made) changes none.
                if !movedKeys.isEmpty { selectedStackIDs.subtract(trashedStackIDs) }
                if !movedKeys.isEmpty, let focusedStackID, trashedStackIDs.contains(focusedStackID) {
                    self.focusedStackID = nil
                    selectionAnchorID = nil
                }
                self.removeFilesFromEventBoards(movedKeys, events: [])
                // The boards are already truthful — tell the Trash window its
                // list changed rather than re-reading whole events.
                if !batch.entries.isEmpty {
                    Self.postTrashChanged(rescanUnsorted: false)
                }
                let skippedNote = batch.skipped.isEmpty
                    ? ""
                    : " \(batch.skipped.count) stayed in place: \(batch.skipped[0].reason)"
                return batch.entries.isEmpty
                    ? "Nothing moved to Trash.\(skippedNote)"
                    : "Moved \(batch.entries.count) files to Trash — restorable from the Trash window.\(skippedNote)"
            }
        )
    }

    /// Event-board trash: the files at each item's current path (event folder
    /// after Apply, or still-unsorted if only tagged). Same `_Trash` rename.
    func trashItems(_ items: [OrganizeItem], fromEvent eventID: UUID) {
        guard let event = event(eventID) else { return }
        let files = items.flatMap(\.files)
        guard !files.isEmpty else {
            model.statusMessage = "Select photos first, then move them to Trash."
            return
        }
        guard !model.isBusy, !model.isStorageBenchmarkRunning else {
            model.statusMessage = "Another file job is already running. Wait for it to finish, then try again."
            return
        }

        refreshIndexIfNeeded()
        var eventIDs: [String: UUID] = [:]
        var droppable: [String: PhotoEventAssignment] = [:]
        for file in files {
            let key = file.pathKey
            if let assignment = assignmentsByPathKey[key] {
                eventIDs[key] = assignment.eventID
                droppable[key] = assignment
            }
        }

        let itemIDs = Set(items.map(\.id))
        let trashedStackIDs = Set((eventStacks[eventID] ?? []).filter { stack in
            stack.items.contains { itemIDs.contains($0.id) }
        }.map(\.id))
        let context = TrashContext(
            locationName: eventTitle(event),
            deviceID: nil,
            eventIDsByPathKey: eventIDs,
            eventNamesByID: trashEventNames(for: eventIDs),
            personNamesByPathKey: trashPersonNames(for: files),
            captureDatesByPathKey: trashCaptureDates(for: items),
            assignmentsByPathKey: droppable.mapValues { [$0] }
        )
        let originRoot = locations.eventFolder(for: event, policy: resolvedPolicy(for: event))
        let fallbackTrashRoot = locations.removedFilesRoot
        model.runBackgroundJob(
            action: .organize,
            runningNote: "Moving \(files.count) file(s) to Trash",
            logTitle: "Moved files to Trash",
            logDetail: "Renamed files from the event folder into the drive-local .Camera Toolkit/_Trash folder. Nothing was deleted; batches are restorable from the Trash window.",
            operation: { progress in
                try MediaTrashService(removedFilesRoot: fallbackTrashRoot).trash(
                    files: files,
                    originRoot: originRoot,
                    context: context
                ) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Moving to Trash", command: ""))
                }
            },
            completion: { [weak self] batch in
                guard let self else { return "" }
                let movedKeys = Set(batch.entries.map { EventStorageLocations.pathKey($0.originalAbsolutePath) })
                // Only the files that really went to Trash stop belonging to
                // their event; a file that stayed in place keeps its entry.
                let dropped = movedKeys.compactMap { droppable[$0] }
                if !dropped.isEmpty {
                    applyAssignmentChange(AssignmentChange(title: "Move to Trash", removed: dropped, added: []), touching: nil)
                }
                recordTrashUndo(title: "Move to Trash", batch: batch, dropped: dropped, originRoot: originRoot.path)
                if let stacks = eventStacks[eventID] {
                    let remaining = stacks.flatMap(\.items).filter { item in
                        !item.files.contains { movedKeys.contains($0.pathKey) }
                    }
                    eventStacks[eventID] = OrganizeStacker.stacks(for: remaining, splits: model.configuration.burstSplits)
                        .carryingIDs(from: stacks)
                    eventGridRevisions[eventID] = model.catalogStateRevision
                }
                for (id, state) in sources {
                    if let result = state.result {
                        sources[id]?.result = result.removingFiles(withPathKeys: movedKeys)
                    }
                }
                // Only what really went to Trash leaves the selection; a trash
                // that moved nothing (its folder could not be made) changes none.
                if !movedKeys.isEmpty { selectedStackIDs.subtract(trashedStackIDs) }
                if !movedKeys.isEmpty, let focusedStackID, trashedStackIDs.contains(focusedStackID) {
                    self.focusedStackID = nil
                    selectionAnchorID = nil
                }
                // The board update above already dropped the moved files — a
                // full refreshEvent would repaint the grid and bury the move
                // confirmation under a reload of the whole event.
                if !batch.entries.isEmpty {
                    Self.postTrashChanged(rescanUnsorted: false)
                }
                let skippedNote = batch.skipped.isEmpty
                    ? ""
                    : " \(batch.skipped.count) stayed in place: \(batch.skipped[0].reason)"
                return batch.entries.isEmpty
                    ? "Nothing moved to Trash.\(skippedNote)"
                    : "Moved \(batch.entries.count) files to Trash — restorable from the Trash window.\(skippedNote)"
            }
        )
    }

    // MARK: - Duplicates

    /// "Keep in X only" from the Duplicates window. `DuplicateResolver`
    /// re-hashes the kept and the dropped copies first and refuses any that
    /// no longer match; matching copies go to the drive's `_Trash` in one
    /// restorable batch. Only then does the catalog drop the removed
    /// assignments — one save, one transaction — and their location and
    /// Immich rows cascade away with them. A file another assignment still
    /// points at stays on disk and only loses the dropped assignment.
    @discardableResult
    func resolveDuplicates(
        _ resolutions: [DuplicateResolution],
        onFinish: @escaping @MainActor (DuplicateResolutionOutcome) -> Void
    ) -> Bool {
        let dropping = resolutions.flatMap { resolution in
            resolution.group.copies.filter { resolution.drop.contains($0.owner) }
        }
        guard !dropping.isEmpty else { return false }
        guard !model.isBusy, !model.isStorageBenchmarkRunning else {
            model.statusMessage = "Another file job is already running. Wait for it to finish, then try again."
            return false
        }
        let leaving = Set(dropping.compactMap(\.assignment).map(CatalogStore.eventAssetID))
        var protectedKeys: Set<String> = []
        for assignment in model.configuration.photoEventAssignments where !leaving.contains(CatalogStore.eventAssetID(assignment)) {
            protectedKeys.insert(Self.sourceKey(assignment))
        }
        for copy in dropping {
            if let assignment = copy.assignment, hasOtherAssignment(pointingLike: assignment) {
                protectedKeys.insert(copy.pathKey)
            }
        }
        var eventIDs: [String: UUID] = [:]
        for copy in dropping {
            if let id = copy.owner.eventID { eventIDs[copy.pathKey] = id }
        }
        var captureDates: [String: Date] = [:]
        var droppedAssignments: [String: [PhotoEventAssignment]] = [:]
        for copy in dropping {
            if let date = copy.captureDate { captureDates[copy.pathKey] = date }
            if let assignment = copy.assignment { droppedAssignments[copy.pathKey, default: []].append(assignment) }
        }
        let context = TrashContext(
            locationName: "Duplicates",
            deviceID: nil,
            eventIDsByPathKey: eventIDs,
            eventNamesByID: trashEventNames(for: eventIDs),
            personNamesByPathKey: [:],
            captureDatesByPathKey: captureDates,
            assignmentsByPathKey: droppedAssignments
        )
        // The set-aside NAS copies are journaled under this id, so Undo of
        // the resolution brings them back out of the NAS stale folder.
        let nasLink = UUID()
        let fallbackTrashRoot = locations.removedFilesRoot
        let protected = protectedKeys
        let locations = self.locations
        let journalFolder = self.journalFolder
        let queuedRenames = NASQueuedRenames()
        return model.runBackgroundJob(
            action: .organize,
            runningNote: "Rechecking \(DuplicateReviewWording.copies(dropping.count)) before moving them to Trash",
            logTitle: "Removed duplicate copies",
            logDetail: "Re-hashed the kept and the removed copy of every group before moving anything. Matching extra copies were renamed into the drive-local .Camera Toolkit/_Trash folder with a manifest — restorable from the Trash window. Copies that changed or could not be read were left in place.",
            operation: { progress in
                let outcome = try DuplicateResolver(trash: MediaTrashService(removedFilesRoot: fallbackTrashRoot)).resolve(
                    resolutions,
                    protectedPathKeys: protected,
                    context: context
                ) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Rechecking", command: ""))
                }
                // A removed copy's NAS twin is a stale duplicate of the kept
                // copy's: set aside on the NAS (never deleted) when it runs.
                queuedRenames.add(Self.queueNASRenames(
                    NASMoveFollower.renames(forDuplicates: resolutions, outcome: outcome, locations: locations),
                    title: "Removed duplicate copies", origin: .merge, moveJournalID: nasLink,
                    nasRoot: locations.nasRoot, journalFolder: journalFolder
                ))
                return outcome
            },
            completion: { [weak self] outcome in
                guard let self else { return "" }
                noteNASRenamesQueued(queuedRenames.count)
                if !outcome.removedAssignments.isEmpty {
                    applyAssignmentChange(
                        AssignmentChange(title: "Remove duplicate copies", removed: outcome.removedAssignments, added: []),
                        touching: nil
                    )
                }
                recordDuplicatesUndo(outcome: outcome, nasLink: nasLink, eventFolders: eventFolderSnapshot(Set(eventIDs.values)))
                let trashedKeys = Set(outcome.trashed.map(\.pathKey))
                removeFilesFromEventBoards(trashedKeys, events: [])
                for (id, state) in sources {
                    if let result = state.result {
                        sources[id]?.result = result.removingFiles(withPathKeys: trashedKeys)
                    }
                }
                if outcome.trashBatch != nil {
                    Self.postTrashChanged(rescanUnsorted: false)
                }
                // Board edits match files by name, size and date, so the
                // kept copy's tile can drop out with the removed one —
                // reload every open board the groups touched.
                for eventID in Set(resolutions.flatMap { $0.group.owners.compactMap(\.eventID) }) where eventStacks[eventID] != nil {
                    Task { await self.refreshEvent(eventID) }
                }
                onFinish(outcome)
                return DuplicateReviewWording.resolutionSummary(outcome)
            }
        ) != nil
    }

    /// The event's display title for every event ID a trash run recorded —
    /// written into the manifest so the tag still reads correctly after the
    /// file leaves the board or the event is renamed.
    private func trashEventNames(for eventIDs: [String: UUID]) -> [UUID: String] {
        var names: [UUID: String] = [:]
        for id in Set(eventIDs.values) {
            if let event = event(id) {
                names[id] = eventTitle(event)
            }
        }
        return names
    }

    /// Confirmed person names per file being trashed, keyed by path key —
    /// one read of the already-built catalog index, never a rescan.
    private func trashPersonNames(for files: [OrganizeFile]) -> [String: [String]] {
        let names = faceNamesByFileKey()
        guard !names.isEmpty else { return [:] }
        var perFile: [String: [String]] = [:]
        for file in files {
            let key = FaceIndexStore.fileKey(
                fileName: file.name,
                byteCount: file.size,
                modifiedAt: file.modifiedAt
            )
            if let found = names[key], !found.isEmpty {
                perFile[file.pathKey] = found.sorted()
            }
        }
        return perFile
    }

    /// The capture date the board already shows each item under, keyed by
    /// every file's path key so a RAW's sidecar travels with the same date.
    private func trashCaptureDates(for items: [OrganizeItem]) -> [String: Date] {
        var dates: [String: Date] = [:]
        for item in items {
            for file in item.files {
                dates[file.pathKey] = item.captureDate
            }
        }
        return dates
    }

    /// Drop trashed files from cached event boards immediately so a tagged
    /// burst cannot linger after Unsorted Trash.
    func removeFilesFromEventBoards(_ pathKeys: Set<String>, events: Set<UUID>) {
        guard !pathKeys.isEmpty else { return }
        let ids = events.isEmpty ? Set(eventStacks.keys) : events
        let splits = model.configuration.burstSplits
        for eventID in ids {
            guard let stacks = eventStacks[eventID] else { continue }
            let items = stacks.flatMap(\.items)
            let remaining = items.filter { item in
                !item.files.contains { pathKeys.contains($0.pathKey) }
            }
            guard remaining.count != items.count else { continue }
            eventStacks[eventID] = OrganizeStacker.stacks(for: remaining, splits: splits)
                .carryingIDs(from: stacks)
            eventGridRevisions[eventID] = model.catalogStateRevision
        }
    }

    /// Stack IDs whose stacks contain any of the given items, for clearing
    /// the selection after they leave the board.
    private func affectedStackIDs(for items: [OrganizeItem], in locationID: UUID) -> Set<String> {
        guard let result = sources[locationID]?.result else { return [] }
        let itemIDs = Set(items.map(\.id))
        return Set(result.stacks.filter { stack in
            stack.items.contains { itemIDs.contains($0.id) }
        }.map(\.id))
    }

    // MARK: - Burst splits

    /// Pulls the given frames out of whatever burst they sit in and pins them
    /// as a stack of their own. The split is recorded in
    /// `AppConfiguration.burstSplits`, so a rescan or event refresh keeps the
    /// frames apart instead of letting the grouper join them again. Nothing
    /// on disk moves — this is a board-level regrouping only.
    func splitItems(_ items: [OrganizeItem]) {
        let keys = items.map(\.primary.pathKey)
        guard !keys.isEmpty else { return }
        let split = BurstSplit(memberPathKeys: keys)
        model.updateConfiguration { $0.burstSplits.append(split) }
        recordUndo("Split Burst", detail: "\(items.count) frame\(items.count == 1 ? "" : "s")", .config(.burstSplit(split)))
        let splits = model.configuration.burstSplits
        for id in Array(sources.keys) {
            if let result = sources[id]?.result {
                sources[id]?.result = result.restacked(withSplits: splits)
            }
        }
        for id in Array(eventStacks.keys) {
            if let stacks = eventStacks[id] {
                eventStacks[id] = OrganizeStacker.stacks(for: stacks.flatMap(\.items), splits: splits)
                    .carryingIDs(from: stacks)
                eventGridRevisions[id] = model.catalogStateRevision
            }
        }
        // Restacking changed some stack IDs; drop board selections that no
        // longer point at anything so follow-up actions can't go stale.
        let liveIDs = Set(sources.values.compactMap(\.result).flatMap { $0.stacks.map(\.id) })
            .union(eventStacks.values.flatMap { $0.map(\.id) })
        selectedStackIDs.formIntersection(liveIDs)
        if let focusedStackID, !liveIDs.contains(focusedStackID) {
            self.focusedStackID = nil
            selectionAnchorID = nil
        }
        model.statusMessage = "Split \(items.count) frame\(items.count == 1 ? "" : "s") into a new burst. Rescans will keep them apart."
    }

    // MARK: - Display rotation

    /// Quarter-turns clockwise recorded for this file's identity — survives
    /// the file moving between the card, the Buffer, and the NAS.
    func displayTurns(for file: OrganizeFile) -> Int {
        DisplayRotation.turns(for: file, in: model.configuration.displayOrientations)
    }

    /// Rotates every rotatable file in `stack` — all burst frames plus their
    /// JPEG companions, and a video's poster — by `delta` quarter-turns
    /// clockwise. Display-only: media bytes are never written, so RAW data
    /// and checksums stay untouched. Tiles, the filmstrip, and the preview
    /// re-decode with the new orientation; no rescan needed.
    func rotateStack(_ stack: OrganizeStack, quarterTurnsCW delta: Int) {
        rotateStacks([stack], quarterTurnsCW: delta)
    }

    /// The board's multi-select version of Rotate Burst: every targeted
    /// stack turns the same direction in a single configuration update, so
    /// ⌘- or ⇧-selected bursts all land at the new orientation together.
    /// Same display-only guarantee — the map changes, the files never do.
    func rotateStacks(_ stacks: [OrganizeStack], quarterTurnsCW delta: Int) {
        let rotated = stacks.flatMap { DisplayRotation.rotatableFiles(in: $0) }
        guard !rotated.isEmpty else {
            model.statusMessage = stacks.count == 1
                ? "Nothing to rotate in this stack."
                : "Nothing to rotate in the selection."
            return
        }
        let orientationsBefore = model.configuration.displayOrientations
        model.updateConfiguration { configuration in
            for stack in stacks {
                configuration.displayOrientations = DisplayRotation.rotatedMap(
                    configuration.displayOrientations,
                    applying: delta,
                    to: stack
                )
            }
        }
        let orientationsAfter = model.configuration.displayOrientations
        let orientationChanges = Set(orientationsBefore.keys).union(orientationsAfter.keys)
            .filter { orientationsBefore[$0] != orientationsAfter[$0] }
            .sorted()
            .map { UndoOrientationChange(key: $0, before: orientationsBefore[$0], after: orientationsAfter[$0]) }
        if !orientationChanges.isEmpty {
            let direction = abs(delta) == 2 ? "180°" : (delta > 0 ? "90° Clockwise" : "90° Counter-Clockwise")
            recordUndo("Rotate \(direction)", detail: stacks.count == 1 ? nil : "\(stacks.count) bursts", .config(.orientations(orientationChanges)))
        }
        for file in rotated {
            TileImageLoader.shared.invalidate(url: file.url)
        }
        let frames = stacks.reduce(0) { $0 + $1.items.count }
        let direction = abs(delta) == 2 ? "180°" : (delta > 0 ? "90° clockwise" : "90° counter-clockwise")
        model.statusMessage = stacks.count == 1
            ? "Rotated \(frames) frame\(frames == 1 ? "" : "s") \(direction). Originals untouched — the turn is remembered, not written."
            : "Rotated \(stacks.count) bursts (\(frames) frames) \(direction). Originals untouched — the turn is remembered, not written."
    }

    // MARK: - Immich

    func uploadToImmich(_ eventID: UUID) {
        guard let event = event(eventID), let summary = presence[eventID] else { return }
        let serverURL = model.configuration.immichServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty else {
            model.statusMessage = "Add the Immich server URL in Settings first."
            return
        }
        var apiKey = model.immichAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty {
            apiKey = ((try? model.secretStore.read(account: DashboardModel.immichAPIKeyAccount)) ?? nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !apiKey.isEmpty else {
            model.statusMessage = "Save an Immich API key in Settings first."
            return
        }
        let immichKey = apiKey
        let uploadable = OrganizeFileClassifier.rawExtensions
            .union(OrganizeFileClassifier.photoExtensions)
            .union(OrganizeFileClassifier.videoExtensions)
        // Family scope: each candidate follows the Send flag and album
        // policy of the event that actually owns it — a subevent's files
        // never upload under the parent's settings.
        let candidates = summary.assets.compactMap { asset -> ImmichCandidate? in
            let owner = self.event(asset.assignment.eventID) ?? event
            guard asset.assignment.immichUploadOverride ?? owner.sendsToImmich,
                  uploadable.contains((asset.assignment.relativePath as NSString).pathExtension.lowercased()),
                  let path = asset.bestLocalPath else { return nil }
            let albumName: String? = switch owner.resolvedImmichAlbumPolicy {
            case .none: nil
            case .event: owner.name
            case .custom:
                owner.immichAlbumName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? owner.name
            }
            return ImmichCandidate(id: asset.id, path: path, size: asset.assignment.fileSize, modifiedAt: asset.assignment.modifiedAt, albumName: albumName)
        }
        guard !candidates.isEmpty else {
            model.statusMessage = event.sendsToImmich
                ? "No reachable photos or videos to send. Connect the drive or NAS that has them."
                : "Turn on Send to Immich for \(eventTitle(event)) first."
            return
        }
        // The Immich status rows reference the catalog's assignment rows.
        model.persistCatalogStateNow()
        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
        let configuration = model.configuration

        model.runAsyncJob(
            action: .immichUpload,
            runningNote: "Sending \(candidates.count) file(s) from \(eventTitle(event)) to Immich",
            logTitle: "Sent \(eventTitle(event)) to Immich",
            logDetail: "Checked each file's SHA-1 with Immich, uploaded only missing originals, and kept the API key in Keychain.",
            operation: { progress in
                let client = try ImmichClient(serverURL: serverURL, apiKey: immichKey)
                var hashes: [String: String] = [:]
                for (index, candidate) in candidates.enumerated() {
                    try Task.checkCancellation()
                    hashes[candidate.id] = try FileSHA1.hexDigest(of: URL(fileURLWithPath: candidate.path))
                    progress(BackgroundJobUpdate(
                        progress: 0.02 + 0.2 * Double(index + 1) / Double(candidates.count),
                        note: "Checking \((candidate.path as NSString).lastPathComponent)",
                        processedFiles: index + 1,
                        totalFiles: candidates.count
                    ))
                }
                var remoteIDs: [String: String] = [:]
                var outcome = ImmichUploadOutcome(albumName: nil)
                for start in stride(from: 0, to: candidates.count, by: 100) {
                    let batch = candidates[start..<min(start + 100, candidates.count)]
                    let results = try await client.checkBulkUpload(batch.compactMap { candidate in
                        hashes[candidate.id].map { ImmichChecksumQuery(id: candidate.id, checksum: $0) }
                    })
                    for result in results where result.isPresent && !result.isTrashed {
                        remoteIDs[result.id] = result.assetID
                    }
                }
                outcome.alreadyPresent = remoteIDs.count

                var statuses: [ImmichCatalogStatus] = []
                for (index, candidate) in candidates.enumerated() {
                    try Task.checkCancellation()
                    if remoteIDs[candidate.id] == nil {
                        let result = try await client.uploadAsset(
                            fileURL: URL(fileURLWithPath: candidate.path),
                            deviceAssetID: "\((candidate.path as NSString).lastPathComponent)-\(candidate.size)",
                            fileCreatedAt: candidate.modifiedAt,
                            fileModifiedAt: candidate.modifiedAt
                        )
                        remoteIDs[candidate.id] = result.assetID
                        if result.isDuplicate { outcome.duplicates += 1 } else { outcome.uploaded += 1 }
                    }
                    statuses.append(ImmichCatalogStatus(
                        eventAssetID: candidate.id,
                        status: "present",
                        immichAssetID: remoteIDs[candidate.id],
                        checksumSHA1: hashes[candidate.id]
                    ))
                    progress(BackgroundJobUpdate(
                        progress: 0.25 + 0.7 * Double(index + 1) / Double(candidates.count),
                        note: "Sending \((candidate.path as NSString).lastPathComponent)",
                        processedFiles: index + 1,
                        totalFiles: candidates.count
                    ))
                }
                // Each candidate's album is its owning event's pick —
                // a family upload can fill several albums in one pass.
                var albumAssetIDs: [String: Set<String>] = [:]
                for candidate in candidates {
                    guard let remote = remoteIDs[candidate.id], let album = candidate.albumName else { continue }
                    albumAssetIDs[album, default: []].insert(remote)
                }
                for (name, ids) in albumAssetIDs {
                    let album = try await client.ensureAlbum(named: name)
                    outcome.albumAdded += try await client.addAssets(Array(ids), toAlbum: album.id).added
                }
                if albumAssetIDs.count == 1 { outcome.albumName = albumAssetIDs.keys.first }
                _ = try? CatalogStore(url: catalogURL).bootstrap(configuration: configuration, createBackup: false, createLibraryFolders: false)
                try? CatalogInspector(url: catalogURL).saveImmichStatuses(statuses)
                return outcome
            },
            completion: { [weak self] outcome in
                Task { await self?.refreshEvent(eventID) }
                let album = outcome.albumName.map { " Added \(outcome.albumAdded) to the “\($0)” album." } ?? ""
                return "Immich: \(outcome.uploaded) uploaded, \(outcome.alreadyPresent + outcome.duplicates) already there.\(album)"
            }
        )
    }

    // MARK: - Faces

    /// Bumped whenever face rows change so people chips and the People
    /// window re-read the catalog.
    var facesRevision = 0 {
        // Face review writes only the catalog; let the debounced backup
        // know a session is under way.
        didSet {
            model.noteCatalogWrite()
            scheduleRosterWarm()
        }
    }

    @ObservationIgnored private var faceStoreInstance: FaceIndexStore?
    /// (facesRevision, catalogStateRevision, people by event) — rebuilt
    /// lazily so sidebar rows share one catalog pass.
    @ObservationIgnored private var eventPeopleCache: (Int, Int, [UUID: [FacePerson]])?
    /// (mutationGeneration, facesRevision, roster rows, rows by file key)
    /// — the one roster fetch every people derivation shares. Face rows
    /// change only on a face write, so a file op's configurationRevision
    /// bump never refetches them; `scheduleRosterWarm` refetches detached
    /// after each bump so renders read memory, not SQLite.
    @ObservationIgnored private var rosterFacesCache: (
        generation: Int,
        facesRevision: Int,
        rows: [(personID: UUID, name: String, fileKey: String)],
        byFileKey: [String: [(personID: UUID, name: String)]],
        unapprovedKeys: Set<String>
    )?
    @ObservationIgnored private var rosterWarmTask: Task<Void, Never>?
    /// (mutationGeneration, facesRevision, file key → person/group names)
    /// — one catalog pass feeds every stack the board filters, so person
    /// search never re-queries per stack or touches the filesystem.
    @ObservationIgnored private var faceNamesByFileKeyCache: (Int, Int, [String: Set<String>])?

    var faceStore: FaceIndexStore {
        if let faceStoreInstance { return faceStoreInstance }
        let store = FaceIndexStore(url: catalogDatabaseURL)
        faceStoreInstance = store
        return store
    }

    private var catalogDatabaseURL: URL {
        URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
    }

    /// The confirmed-faces-on-roster-people pairs, grouped by file key —
    /// one catalog fetch shared by the event chips, stack person names,
    /// and the board People filter, parsed once per face revision instead
    /// of once per event per render. The fetch still happens
    /// synchronously when a caller cannot wait (a cold read racing the
    /// warm); `scheduleRosterWarm` keeps it off the main actor after
    /// every face change and at launch.
    ///
    /// `unapprovedKeys` rides the same fetch: the file keys of photos
    /// holding any face that is not confirmed on an approved person
    /// (unnamed groups, suggestions, never-grouped detections) — the
    /// "someone else is here" fact behind the "is exactly" People
    /// operator.
    private func rosterFaces() -> (
        rows: [(personID: UUID, name: String, fileKey: String)],
        byFileKey: [String: [(personID: UUID, name: String)]],
        unapprovedKeys: Set<String>
    ) {
        let generation = faceStore.mutationGeneration
        if let cache = rosterFacesCache,
           cache.generation == generation,
           cache.facesRevision == facesRevision {
            return (cache.rows, cache.byFileKey, cache.unapprovedKeys)
        }
        let rows = (try? faceStore.rosterFaceFiles()) ?? []
        let byFileKey = Self.groupRosterFaces(rows)
        let unapproved = (try? faceStore.unapprovedFaceFileKeys()) ?? []
        rosterFacesCache = (generation, facesRevision, rows, byFileKey, unapproved)
        return (rows, byFileKey, unapproved)
    }

    /// Refetch the roster pairs detached and publish them while the face
    /// revision is still current, so the post-change render reads memory
    /// instead of running the roster query and its ISO date parsing on
    /// the main actor.
    private func scheduleRosterWarm() {
        rosterWarmTask?.cancel()
        let store = faceStore
        let generation = store.mutationGeneration
        let revision = facesRevision
        rosterWarmTask = Task.detached(priority: .utility) { [weak self] in
            let rows = (try? store.rosterFaceFiles()) ?? []
            let unapproved = (try? store.unapprovedFaceFileKeys()) ?? []
            await MainActor.run {
                guard let self,
                      self.facesRevision == revision,
                      self.faceStore.mutationGeneration == generation else { return }
                self.rosterFacesCache = (generation, revision, rows, Self.groupRosterFaces(rows), unapproved)
            }
        }
    }

    nonisolated private static func groupRosterFaces(
        _ rows: [(personID: UUID, name: String, fileKey: String)]
    ) -> [String: [(personID: UUID, name: String)]] {
        var byFileKey: [String: [(personID: UUID, name: String)]] = [:]
        for row in rows {
            byFileKey[row.fileKey, default: []].append((row.personID, row.name))
        }
        return byFileKey
    }

    /// True once `scripts/setup-face-sidecar.sh` has installed the face
    /// engine on this Mac — the gate every scan and the People window show.
    ///
    /// The answer comes from files on disk and the sidebar footer asks on
    /// every redraw — with a job's progress that is several times a second
    /// — so it is kept for a few seconds before the files are looked at again.
    var faceEngineInstalled: Bool {
        let now = ContinuousClock.now
        if let known = faceEngineCheck, now - known.at < .seconds(5) { return known.installed }
        let installed = FaceSidecarInstallation(applicationSupport: DashboardModel.defaultApplicationSupportURL).isInstalled
        faceEngineCheck = (now, installed)
        return installed
    }

    @ObservationIgnored private var faceEngineCheck: (at: ContinuousClock.Instant, installed: Bool)?

    /// Opens the "Scan for Faces" sheet for a location — quality and the
    /// Fast (pin the Mac) are picked there before any job starts.
    func requestFaceScan(_ location: ConfiguredLocation) {
        faceScanRequest = FaceScanRequest(subject: .location(location.id))
    }

    /// Same sheet for an event — the scan runs on the stacks its board
    /// shows (each assigned file's best local copy).
    func requestFaceScan(_ event: SavedCameraEvent) {
        faceScanRequest = FaceScanRequest(subject: .event(event.id))
    }

    /// Test seam: supplies the face engine so a face scan can run without
    /// the sidecar installed. Nil in production — a sidecar pool opens per
    /// scan and shuts down with it.
    @ObservationIgnored var faceAnalyzerProvider: (@Sendable () async throws -> FaceAnalyzing?)?

    /// Why Face Scan cannot start on this location right now, or nil when it
    /// can. Faces are detected per burst stack, so a location must finish
    /// grouping first; the board disables its button with this reason.
    func faceScanBlocker(for location: ConfiguredLocation) -> String? {
        if sources[location.id]?.isScanning == true {
            return "Burst grouping is still running on \(location.name). Face Scan unlocks when it finishes."
        }
        if sources[location.id]?.result == nil {
            return "Face Scan runs after burst grouping — scan \(location.name) first."
        }
        if model.isBusy || model.isStorageBenchmarkRunning {
            return "Another job is already running. Wait for it to finish, then scan."
        }
        return nil
    }

    /// Why Face Scan cannot start on this event right now, or nil when it
    /// can. The scan runs over the event board's stacks — the reachable
    /// copies — so an event that has never been opened warms its presence
    /// data first, and an event whose files are all offline has nothing to
    /// scan until a drive or the NAS mounts. Pure: it only reports state —
    /// `prepareFaceScanStatus` starts the check, from the menu that can
    /// offer the scan, so a render never sweeps events as a side effect.
    func faceScanBlocker(for event: SavedCameraEvent) -> String? {
        guard assignmentCount(for: event.id) > 0 else {
            return "Sort photos into \(event.name) first — there is nothing to scan."
        }
        guard let stacks = eventStacks[event.id] else {
            return "Still checking where \(event.name)'s files are — the scan unlocks when that finishes."
        }
        guard !stacks.isEmpty else {
            return "No reachable copies of \(event.name)'s files — connect the drive or NAS that holds them, then scan."
        }
        if model.isBusy || model.isStorageBenchmarkRunning {
            return "Another job is already running. Wait for it to finish, then scan."
        }
        return nil
    }

    /// Kick the presence check a Face Scan needs on an event whose grid
    /// was never loaded. The context menu that offers the scan calls this
    /// when it opens — the one place the check is wanted — instead of
    /// every row render starting a sweep, which at launch meant all
    /// events sweeping just because the sidebar drew.
    func prepareFaceScanStatus(for event: SavedCameraEvent) {
        guard eventStacks[event.id] == nil, refreshGenerations[event.id] == nil else { return }
        Task { await refreshEvent(event.id) }
    }

    /// Whether `refreshEvent` has a pipeline in flight for this event —
    /// exposed so a render can tell checking from unchecked without
    /// starting work.
    func isCheckingFiles(for eventID: UUID) -> Bool {
        presenceTasks[eventID] != nil
    }

    /// "Regroup Bursts" on the Unsorted board: re-runs the stacker and the
    /// Vision recovery pass on the already-scanned items using the current
    /// Settings sliders — no capture times are re-read and nothing moves.
    /// Runs as an `.organize` job so it shows in the Jobs window.
    func regroupBursts(_ location: ConfiguredLocation) {
        let id = location.id
        guard let result = sources[id]?.result else {
            model.statusMessage = "Scan \(location.name) first — there is nothing to regroup yet."
            return
        }
        guard sources[id]?.isScanning != true else {
            model.statusMessage = "\(location.name) is already scanning or regrouping."
            return
        }
        guard !model.isBusy, !model.isStorageBenchmarkRunning else {
            model.statusMessage = "Another job is already running. Regroup Bursts starts when it finishes."
            return
        }
        let items = result.items
        let grouping = BurstGroupingConfiguration.resolved()
        var state = sources[id] ?? UnsortedSourceState()
        state.isScanning = true
        state.error = nil
        state.progress = OrganizeScanProgress(phase: "Regrouping bursts", processed: 0, total: 0)
        sources[id] = state
        let reportProgress: @Sendable (OrganizeScanProgress) -> Void = { [weak self] update in
            Task { @MainActor in
                self?.sources[id]?.progress = update
            }
        }
        model.runBackgroundJob(
            action: .organize,
            runningNote: "Regrouping bursts on \(location.name)",
            logTitle: "Regrouped bursts on \(location.name)",
            logDetail: "Re-ran burst grouping on the already-scanned files using the current Settings thresholds, including the Vision similarity check. File contents were not re-read and nothing was moved.",
            onSettled: { [weak self] in
                self?.sources[id]?.isScanning = false
                self?.sources[id]?.progress = nil
            },
            operation: { progress in
                let links = BurstVisualLinker.links(for: items, configuration: grouping) { update in
                    reportProgress(update)
                    progress(DashboardModel.jobUpdate(
                        from: FileOperationProgress(
                            phase: update.phase,
                            processedFiles: update.processed,
                            totalFiles: update.total
                        ),
                        lowerBound: 0.05,
                        upperBound: 0.9,
                        notePrefix: "Regrouping bursts",
                        command: ""
                    ))
                }
                reportProgress(OrganizeScanProgress(phase: "Grouping bursts", processed: 0, total: 0))
                return BurstRegroupOutcome(
                    stacks: OrganizeStacker.stacks(for: items, configuration: grouping, visualLinks: links),
                    links: links,
                    grouping: grouping
                )
            },
            completion: { [weak self] outcome in
                guard let self else { return "" }
                var updated = result
                updated.stacks = outcome.stacks
                updated.days = OrganizeStacker.days(for: outcome.stacks)
                updated.burstGrouping = outcome.grouping
                updated.visualLinks = outcome.links
                sources[id]?.result = updated
                // The grouping lives in memory (a rescan makes it again), so
                // its undo does too: gone after a relaunch.
                recordSessionUndo(
                    "Regroup Bursts on \(location.name)",
                    undo: { [weak self] in self?.sources[id]?.result = result },
                    redo: { [weak self] in self?.sources[id]?.result = updated }
                )
                let bursts = outcome.stacks.count { $0.isBurst }
                return "Regrouped \(location.name): \(outcome.stacks.count) item(s), \(bursts) burst(s). Nothing moved."
            }
        )
    }

    /// "Scan for Faces" on a connected, grouped unsorted source: detect
    /// faces with the mode's engine on a sample of each burst (every burst
    /// frame at HIGH and above) plus single stills, embed them with the
    /// on-device model, match named people, and group the rest. MED and
    /// above also sample video frames. Writes only to the catalog — media
    /// files are only read.
    func faceScan(_ location: ConfiguredLocation, options: FaceScanOptions = FaceScanOptions()) {
        guard isConnectedNow(location) else {
            model.statusMessage = "\(location.name) is not connected. Plug it in, then scan again."
            return
        }
        if let blocker = faceScanBlocker(for: location) {
            model.statusMessage = blocker
            return
        }
        // The grouping gate above guarantees a scan result; the stacks it
        // holds drive the face scan's burst sampling.
        guard let stacks = sources[location.id]?.result?.stacks else { return }
        runFaceScanJob(title: location.name, stacks: stacks, options: options)
    }

    /// "Scan for Faces" on an event board: the same burst-sampled pass as
    /// Unsorted, run over the event's reachable files — the stacks its
    /// board built from each assignment's best local copy (Buffer, private
    /// staging, card, or NAS mount). Writes only to the catalog — media
    /// files are only read — and faces attach to the event by file
    /// identity, so photos scanned here or in Unsorted share one index.
    func faceScan(_ event: SavedCameraEvent, options: FaceScanOptions = FaceScanOptions()) {
        if let blocker = faceScanBlocker(for: event) {
            model.statusMessage = blocker
            return
        }
        guard let stacks = eventStacks[event.id], !stacks.isEmpty else { return }
        runFaceScanJob(title: eventTitle(event), stacks: stacks, options: options)
    }

    /// The shared face-scan job: opens the face engine, runs
    /// `FaceIndexService` over the given stacks, and reports progress and
    /// the summary line to the Jobs window.
    private func runFaceScanJob(title: String, stacks: [OrganizeStack], options: FaceScanOptions) {
        // A scan can read NAS-only files: over Ethernet if it can. Starts
        // at once when the NAS is not on slow Wi-Fi.
        nasConnection.prepareForNASJob { [weak self] in
            self?.startFaceScanJob(title: title, stacks: stacks, options: options)
        }
    }

    private func startFaceScanJob(title: String, stacks: [OrganizeStack], options: FaceScanOptions) {
        let analyzerProvider = faceAnalyzerProvider
        guard faceEngineInstalled || analyzerProvider != nil else {
            model.statusMessage = FaceSidecarInstallation.notInstalledMessage
            return
        }
        let support = DashboardModel.defaultApplicationSupportURL
        let catalogURL = catalogDatabaseURL
        let configuration = model.configuration
        let burstScope = options.mode < .high ? "a sample of each burst" : "every burst frame"
        model.runAsyncJob(
            action: .faceScan,
            runningNote: "Scanning \(title) for faces",
            logTitle: "Face scan: \(title)",
            logDetail: "Quality \(options.mode.rawValue). Detected faces on \(burstScope), single stills, and — at MED and above — video frames with the on-device face engine; matched faces against the approved people and grouped the rest — every classification lands in the Inbox, unapproved until the user says so. Files were only read — nothing was written or moved.",
            operation: { progress in
                // Bootstrap is idempotent: it guarantees the face tables
                // exist even if no catalog sync has run since the upgrade.
                _ = try CatalogStore(url: catalogURL).bootstrap(
                    configuration: configuration,
                    createBackup: false,
                    createLibraryFolders: false
                )
                let analyzer: FaceAnalyzing
                if let analyzerProvider, let provided = try await analyzerProvider() {
                    analyzer = provided
                } else {
                    // Sidecar processes live for this job only.
                    analyzer = try FaceSidecarPool.open(applicationSupport: support, options: options)
                }
                defer { (analyzer as? FaceSidecarPool)?.shutdown() }
                // The board's burst stacks drive sampling — a burst decodes
                // its first/middle/last stills instead of every frame (all
                // stills at HIGH and above).
                return try FaceIndexService(catalogURL: catalogURL, options: options).scan(
                    stacks: stacks,
                    analyzer: analyzer
                ) { update in
                    progress(DashboardModel.jobUpdate(
                        from: update,
                        lowerBound: 0.02,
                        upperBound: 0.98,
                        notePrefix: "Face scan",
                        command: ""
                    ))
                }
            },
            completion: { [weak self] report in
                self?.facesRevision &+= 1
                let video = report.videoFramesRead > 0 ? "; \(report.videoFramesRead) video frames read" : ""
                let burst = report.photosBurstCovered > 0 ? "; \(report.photosBurstCovered) burst frames covered by sampled siblings" : ""
                // The Jobs log may name packages — the scan sheet cannot.
                let packages = report.detectorSummary.map { " Engine: \($0)." } ?? ""
                return "Face scan done — \(report.facesDetected) face\(report.facesDetected == 1 ? "" : "s") on \(report.photosProcessed) sampled photo(s); \(report.photosSkipped) already scanned\(burst); \(report.facesProposed) filed in the Inbox as lookalikes, \(report.facesGrouped) grouped\(video).\(packages)"
            }
        )
    }

    /// Approved people detected on this event's photos — the "event.people"
    /// derivation. Only confirmed faces on approved people count; Inbox
    /// faces never put a name on an event.
    func eventPeople(_ eventID: UUID) -> [FacePerson] {
        if let cache = eventPeopleCache,
           cache.0 == facesRevision,
           cache.1 == model.catalogStateRevision {
            return cache.2[eventID] ?? []
        }
        var keysByEvent: [UUID: Set<String>] = [:]
        for assignment in model.configuration.photoEventAssignments {
            let name = (assignment.relativePath as NSString).lastPathComponent
            keysByEvent[assignment.eventID, default: []].insert(
                FaceIndexStore.fileKey(
                    fileName: name,
                    byteCount: assignment.fileSize,
                    modifiedAt: assignment.modifiedAt
                )
            )
        }
        // The chips share the board's family scope: a subevent's files
        // count toward every ancestor's roster too, so a parent's chips
        // cover people confirmed only on its subevents' photos.
        let locations = self.locations
        for saved in model.configuration.savedEvents {
            guard let keys = keysByEvent[saved.id] else { continue }
            for ancestor in locations.ancestors(of: saved) {
                keysByEvent[ancestor.id, default: []].formUnion(keys)
            }
        }
        // One roster snapshot serves every event's chips: the roster
        // query and its ISO date parsing ran once (see `rosterFaceFiles`),
        // so a miss here is set intersections and counting — no SQLite,
        // no parsing, on any render trigger.
        let roster = rosterFaces().byFileKey
        var people: [UUID: [FacePerson]] = [:]
        for (id, keys) in keysByEvent {
            var seen: [UUID: FacePerson] = [:]
            var counts: [UUID: Int] = [:]
            for key in keys {
                for face in roster[key] ?? [] {
                    if seen[face.personID] == nil {
                        seen[face.personID] = FacePerson(
                            id: face.personID,
                            name: face.name,
                            isRoster: true,
                            faceCount: 0
                        )
                    }
                    counts[face.personID, default: 0] += 1
                }
            }
            people[id] = seen.values.map { person in
                var copy = person
                copy.faceCount = counts[person.id] ?? 0
                return copy
            }.sorted {
                if $0.faceCount != $1.faceCount { return $0.faceCount > $1.faceCount }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        eventPeopleCache = (facesRevision, model.catalogStateRevision, people)
        return people[eventID] ?? []
    }

    /// (catalogStateRevision, media kinds by event) — the sidebar's
    /// Media-row facts, rebuilt lazily so a filter pass shares one walk
    /// of the assignments.
    @ObservationIgnored private var eventMediaKindsCache: (Int, [UUID: Set<OrganizeMediaKind>])?

    /// The media kinds an event's assigned files carry, by extension —
    /// the same "any file in it has that kind" fact a board reads off a
    /// stack's items.
    private func eventMediaKinds(for eventID: UUID) -> Set<OrganizeMediaKind> {
        if let cache = eventMediaKindsCache, cache.0 == model.catalogStateRevision {
            return cache.1[eventID] ?? []
        }
        var kinds: [UUID: Set<OrganizeMediaKind>] = [:]
        for assignment in model.configuration.photoEventAssignments {
            kinds[assignment.eventID, default: []].insert(
                OrganizeFileClassifier.kind(
                    forExtension: (assignment.relativePath as NSString).pathExtension
                )
            )
        }
        eventMediaKindsCache = (model.catalogStateRevision, kinds)
        return kinds[eventID] ?? []
    }

    /// Approved-person names detected on the stack's files, joined through
    /// the catalog's confirmed face rows by file key (name|bytes|mtime —
    /// it survives the file moving between folders). Board search matches
    /// these, so "Sam" keeps every burst she appears in — while an
    /// Inbox face never names a stack.
    func personNames(on stack: OrganizeStack) -> Set<String> {
        let names = faceNamesByFileKey()
        guard !names.isEmpty else { return [] }
        var found = Set<String>()
        for file in stack.files {
            found.formUnion(
                names[FaceIndexStore.fileKey(
                    fileName: file.name,
                    byteCount: file.size,
                    modifiedAt: file.modifiedAt
                )] ?? []
            )
        }
        return found
    }

    /// The shared file key → person names map, rebuilt lazily when faces
    /// change and otherwise served from memory. It projects the shared
    /// roster fetch, so the names land without a second catalog pass.
    private func faceNamesByFileKey() -> [String: Set<String>] {
        let generation = faceStore.mutationGeneration
        if let cache = faceNamesByFileKeyCache,
           cache.0 == generation,
           cache.1 == facesRevision {
            return cache.2
        }
        var names: [String: Set<String>] = [:]
        for row in rosterFaces().rows {
            names[row.fileKey, default: []].insert(row.name)
        }
        faceNamesByFileKeyCache = (generation, facesRevision, names)
        return names
    }

    /// (facesRevision, stacks, people index) — the board People filter's
    /// data, rebuilt only when the face catalog or the board's stacks
    /// actually change so board renders share one catalog pass.
    @ObservationIgnored private var boardPeopleCache: (
        facesRevision: Int,
        stacks: [OrganizeStack],
        people: BoardPeople
    )?

    /// The board People filter's index: picker options, the approved
    /// people on each stack, and the stacks holding anyone else.
    typealias BoardPeople = (
        options: [FacePerson],
        byStackID: [String: Set<UUID>],
        othersStackIDs: Set<String>
    )

    /// Which approved people each stack's files carry (confirmed faces
    /// only), plus the filter picker's options — the approved people
    /// actually seen on these stacks. Inbox faces never satisfy a People
    /// filter; stacks without confirmed faces map to an empty set and
    /// boards never scanned for faces return no options.
    ///
    /// `othersStackIDs` names the stacks where some frame also holds a
    /// face that is not confirmed on an approved person — an unnamed
    /// group, a "looks like" suggestion, or a detection never grouped.
    /// Like `byStackID` it is the union over a burst's frames. Only
    /// "is exactly" reads it.
    func boardPeople(for stacks: [OrganizeStack]) -> BoardPeople {
        if let cache = boardPeopleCache,
           cache.facesRevision == facesRevision,
           cache.stacks == stacks {
            return cache.people
        }
        var keysByStack: [String: Set<String>] = [:]
        var allKeys = Set<String>()
        for stack in stacks {
            var keys = Set<String>()
            for item in stack.items {
                keys.insert(FaceIndexStore.fileKey(
                    fileName: item.primary.name,
                    byteCount: item.primary.size,
                    modifiedAt: item.primary.modifiedAt
                ))
            }
            keysByStack[stack.id] = keys
            allKeys.formUnion(keys)
        }
        // The shared roster fetch carries (person, file key) pairs; a
        // person's `faceCount` is their matching-face total across the
        // queried keys, exactly as `peopleByFileKey` counted it — counted
        // once over the union, not per stack, so a file in two stacks
        // still counts once.
        let faces = rosterFaces()
        let roster = faces.byFileKey
        var byStackID: [String: Set<UUID>] = [:]
        var othersStackIDs = Set<String>()
        var seen: [UUID: FacePerson] = [:]
        var counts: [UUID: Int] = [:]
        for key in allKeys {
            for face in roster[key] ?? [] {
                counts[face.personID, default: 0] += 1
                if seen[face.personID] == nil {
                    seen[face.personID] = FacePerson(
                        id: face.personID,
                        name: face.name,
                        isRoster: true,
                        faceCount: 0
                    )
                }
            }
        }
        for (stackID, keys) in keysByStack {
            var ids = Set<UUID>()
            for key in keys {
                for face in roster[key] ?? [] {
                    ids.insert(face.personID)
                }
            }
            byStackID[stackID] = ids
            if !faces.unapprovedKeys.isDisjoint(with: keys) {
                othersStackIDs.insert(stackID)
            }
        }
        let people = (
            options: seen.values.map { person in
                var copy = person
                copy.faceCount = counts[person.id] ?? 0
                return copy
            }.sorted {
                if $0.isRoster != $1.isRoster { return $0.isRoster }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
            byStackID: byStackID,
            othersStackIDs: othersStackIDs
        )
        boardPeopleCache = (facesRevision, stacks, people)
        return people
    }

    // MARK: - Face review actions

    /// Set after the first `faceSnapshot` checks for legacy proposals —
    /// the sweep runs once per workspace, not on every render.
    @ObservationIgnored private var didCheckRosterProposals = false

    /// Review data for the People window: the approved people and the
    /// Inbox — automatic clusters plus "looks like" suggestion rows.
    /// The first read sweeps any faces an older build proposed onto the
    /// roster into the Inbox (stored vectors only, in a background job).
    func faceSnapshot() -> (approved: [FacePerson], inbox: [FacePerson]) {
        if !didCheckRosterProposals {
            didCheckRosterProposals = true
            if (try? faceStore.hasUnapprovedRosterFaces()) == true {
                rematchFaces()
            }
        }
        let store = faceStore
        let approved = (try? store.rosterPeople()) ?? []
        let groups = (try? store.otherGroups()) ?? []
        // "Looks like" rows first — they are the closest to an approval —
        // then the plain clusters, largest first.
        let inbox = groups.sorted { lhs, rhs in
            if (lhs.suggestedPersonID != nil) != (rhs.suggestedPersonID != nil) {
                return lhs.suggestedPersonID != nil
            }
            if lhs.faceCount != rhs.faceCount { return lhs.faceCount > rhs.faceCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return (approved, inbox)
    }

    /// The live counts the Clear Face Scan sheet lists — scanned photos,
    /// detections, named people, unnamed groups.
    func faceIndexCounts() -> FaceIndexCounts {
        (try? faceStore.faceIndexCounts()) ?? FaceIndexCounts()
    }

    /// The scan grades actually stored on `face_photos` — the People
    /// window footer's quality list. Empty when no scan has run.
    func storedFaceScanGrades() -> [FaceScanGrade] {
        (try? faceStore.storedScanGrades()) ?? []
    }

    /// Throws away the whole face index — `face_photos`, `faces`,
    /// `people`, and `face_templates` rows only, in one transaction.
    /// Nothing on disk is touched and every other catalog table —
    /// events and assignments included — survives. The next scan treats
    /// all files as new instead of skipping them on `scan_grade`.
    func clearFaceIndex() {
        do {
            try faceStore.clearFaceIndex()
            facesRevision &+= 1
            model.statusMessage = "Face index cleared — catalog rows only, nothing on disk was touched. The next scan will not skip those files."
        } catch {
            model.statusMessage = "Could not clear the face index: \(error.localizedDescription)"
        }
    }

    func faces(for personID: UUID) -> [FaceRecord] {
        (try? faceStore.faces(personID: personID)) ?? []
    }

    /// An Inbox person's faces in review order: the stored match score,
    /// strongest first, so the doubtful ones sit at the bottom. A face
    /// with no score is a cluster seed — it belongs with the strongest.
    /// The strip and the full grid both use this order, uncapped.
    func inboxFaces(for personID: UUID) -> [FaceRecord] {
        faces(for: personID).sorted { lhs, rhs in
            let left = lhs.matchScore ?? .infinity
            let right = rhs.matchScore ?? .infinity
            if left != right { return left > right }
            if lhs.detScore != rhs.detScore { return lhs.detScore > rhs.detScore }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// A new roster person created from the overlay's tag picker.
    func createRosterPerson(named name: String) -> FacePerson? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let person = try? faceStore.createPerson(name: trimmed, isRoster: true)
        if let person {
            // The row did not exist before: Undo removes it.
            recordUndo("Add \(trimmed) to People", .faces(FaceSnapshot(personIDs: [person.id])))
            facesRevision &+= 1
            model.statusMessage = "Added \(trimmed) to the people list."
        }
        return person
    }

    /// Assigns an existing detection to a person and confirms it — the
    /// owner's call, so the face becomes frozen and its embedding is pinned
    /// as a match reference when one exists. Confirmed faces are untouched.
    func tagFace(_ faceID: UUID, as personID: UUID) {
        let undo = beginFaceUndo(people: [personID], faces: [faceID])
        try? faceStore.assignFace(faceID, to: personID, state: .confirmed, score: nil)
        try? faceStore.addTemplate(personID: personID, faceID: faceID)
        try? faceStore.refreshFaceCounts()
        recordFaceUndo(undo, "Tag Face as \(person(personID)?.name ?? "Person")")
        facesRevision &+= 1
        model.statusMessage = "Tagged. The photo file was not modified."
    }

    /// A face box the owner drew on the burst preview: stored confirmed so
    /// a later scan never reclassifies it. The photo row is created at
    /// grade `.none` when the file was never scanned, so it still gets its
    /// real detection pass later. Catalog-only — nothing is written to the
    /// photo file.
    func tagDrawnFace(
        on file: OrganizeFile,
        box: NormalizedFaceBox,
        personID: UUID,
        takenAt: Date?,
        crop: Data?
    ) {
        let photo = FacePhotoRecord(
            pathKey: file.pathKey,
            path: file.path,
            fileName: file.name,
            byteCount: file.size,
            modifiedAt: file.modifiedAt,
            takenAt: takenAt
        )
        _ = try? faceStore.addManualFace(photo: photo, box: box, personID: personID, crop: crop)
        try? faceStore.refreshFaceCounts()
        facesRevision &+= 1
        model.statusMessage = "Tagged. The photo file was not modified."
    }

    func renamePerson(_ personID: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let undo = beginFaceUndo(people: [personID])
        let oldName = person(personID)?.name
        try? faceStore.renamePerson(personID, name: trimmed)
        recordFaceUndo(undo, "Rename \(oldName ?? "Person") to \(trimmed)")
        facesRevision &+= 1
        model.statusMessage = "Renamed to \(trimmed)."
    }

    /// Merges one person into another — faces and templates move, the empty
    /// row is removed. Confirmed faces keep their frozen state.
    func mergePerson(_ sourceID: UUID, into targetID: UUID) {
        guard sourceID != targetID,
              let source = try? faceStore.person(sourceID),
              let target = try? faceStore.person(targetID) else { return }
        let undo = beginFaceUndo(expandingPeople: [sourceID], people: [targetID])
        try? faceStore.mergePerson(sourceID, into: targetID)
        try? faceStore.refreshFaceCounts()
        recordFaceUndo(undo, "Merge \(source.name) into \(target.name)", detail: "\(source.faceCount) face\(source.faceCount == 1 ? "" : "s")")
        facesRevision &+= 1
        model.statusMessage = "Merged \(source.name) into \(target.name)."
    }

    /// Takes a person off the approved list; the faces become an Inbox
    /// group again rather than disappearing. Confirmed faces keep their
    /// frozen state.
    func demotePerson(_ personID: UUID) {
        let undo = beginFaceUndo(expandingPeople: [personID])
        let name = person(personID)?.name ?? "Person"
        try? faceStore.demoteFromRoster(personID)
        recordFaceUndo(undo, "Move \(name) to the Inbox")
        facesRevision &+= 1
        model.statusMessage = "Moved to the Inbox — the confirmed faces stay grouped there."
    }

    /// Approves an Inbox person: it joins the approved list with the given
    /// name, and only the faces in that cluster are confirmed — a spread
    /// of them become the templates future scans match against. Nothing
    /// else moves; approving never triggers a catalog-wide re-match.
    func nameGroup(_ personID: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let undo = beginFaceUndo(expandingPeople: [personID])
        try? faceStore.promoteGroup(personID, name: trimmed, templateCap: FaceScanOptions().templateCap)
        recordFaceUndo(undo, "Approve \(trimmed)")
        facesRevision &+= 1
        model.statusMessage = "Approved \(trimmed) — only the faces in this cluster were confirmed."
    }

    /// Junks the one Inbox person the user confirmed (statues, dogs,
    /// strangers) — that cluster and its face rows are removed, nothing
    /// else. Approved people can never be junked, no Junk person is
    /// created, and photos keep their scan grade so a same-mode scan does
    /// not bring the faces back.
    func junkGroup(_ personID: UUID) {
        do {
            guard let person = try faceStore.person(personID) else { return }
            guard !person.isRoster else {
                model.statusMessage = "\(person.name) is an approved person — only Inbox rows can be junked."
                return
            }
            let undo = beginFaceUndo(expandingPeople: [personID])
            try faceStore.deletePersonAndFaces(personID)
            recordFaceUndo(undo, "Remove \(person.name)", detail: "\(person.faceCount) face\(person.faceCount == 1 ? "" : "s")")
            facesRevision &+= 1
            model.statusMessage = "Removed \(person.name). Nothing on disk was touched."
        } catch {
            model.statusMessage = "Could not remove the group: \(error.localizedDescription)"
        }
    }

    /// Deletes one face row — the Inbox's per-face junk. The photo, its
    /// scan grade, and every other face stay untouched.
    func junkFace(_ faceID: UUID) {
        do {
            let undo = beginFaceUndo(faces: [faceID])
            try faceStore.deleteFaces([faceID])
            try faceStore.refreshFaceCounts()
            recordFaceUndo(undo, "Remove Face")
            facesRevision &+= 1
            model.statusMessage = "Face removed from the index. The photo was not touched."
        } catch {
            model.statusMessage = "Could not remove the face: \(error.localizedDescription)"
        }
    }

    /// Confirms a face and pins it as a template — confirmed faces are
    /// frozen and never reclassified. A face on a "looks like X" row is
    /// confirmed onto X itself: the row is only a holding pen, and the
    /// rest of its faces stay unapproved.
    func confirmFace(_ faceID: UUID) {
        do {
            guard let face = try faceStore.face(id: faceID) else { return }
            let undo = beginFaceUndo(faces: [faceID])
            if let personID = face.personID,
               let person = try faceStore.person(personID),
               !person.isRoster,
               let target = person.suggestedPersonID {
                try faceStore.assignFace(faceID, to: target, state: .confirmed, score: face.matchScore)
                try faceStore.addTemplate(personID: target, faceID: faceID)
            } else {
                try faceStore.confirmFace(faceID)
                if let personID = face.personID {
                    try faceStore.addTemplate(personID: personID, faceID: faceID)
                }
            }
            try faceStore.refreshFaceCounts()
            recordFaceUndo(undo, "Confirm Face")
            facesRevision &+= 1
        } catch {
            model.statusMessage = "Could not confirm the face: \(error.localizedDescription)"
        }
    }

    /// "Not this person" / "not this group": the verdict is persisted — the
    /// face can never be matched back to that person and its embedding
    /// becomes a negative example that vetoes lookalikes — then the face
    /// re-groups with the Inbox clusters. Confirmed faces are frozen and
    /// never move; the detection and the photo stay untouched.
    func rejectFace(_ faceID: UUID) {
        do {
            guard let face = try faceStore.face(id: faceID) else { return }
            guard face.state != .confirmed else {
                model.statusMessage = "Confirmed faces are frozen — this one stays where it is."
                return
            }
            let person = face.personID.flatMap { try? faceStore.person($0) }
            let personName = person?.suggestedPersonName ?? person?.name
            let undo = beginFaceUndo(faces: [faceID])
            try FaceIndexService(catalogURL: catalogDatabaseURL).reject([faceID])
            recordFaceUndo(undo, "Reject Face" + (personName.map { " for \($0)" } ?? ""))
            facesRevision &+= 1
            model.statusMessage = personName.map {
                "Removed from \($0) — it will not be matched back. The photo was not touched."
            } ?? "Removed — the photo was not touched."
        } catch {
            model.statusMessage = "Could not remove the face: \(error.localizedDescription)"
        }
    }

    /// Pins a face as a match reference — the reviewed views of a person
    /// that future scans compare new faces against.
    func pinTemplate(_ faceID: UUID, for personID: UUID) {
        let undo = beginFaceUndo(people: [personID])
        try? faceStore.addTemplate(personID: personID, faceID: faceID)
        recordFaceUndo(undo, "Pin Match Reference")
        facesRevision &+= 1
        model.statusMessage = "Pinned as a match reference for future scans."
    }

    /// Sets the person's cover — the thumbnail the People list shows. The
    /// choice lives on the person row in the catalog; a face that leaves
    /// the person stops being the cover automatically. Catalog only —
    /// no photo is written to.
    func setCoverFace(_ faceID: UUID, for personID: UUID) {
        let undo = beginFaceUndo(people: [personID])
        guard (try? faceStore.setCoverFace(personID: personID, faceID: faceID)) == true else { return }
        recordFaceUndo(undo, "Change Cover")
        facesRevision &+= 1
        model.statusMessage = "Cover updated."
    }

    /// The current catalog row for a person — refreshed cover pick included.
    func person(_ id: UUID) -> FacePerson? {
        try? faceStore.person(id)
    }

    /// The Re-match button: re-matches every stored, unconfirmed face
    /// against the approved people — matches file into Inbox "looks like"
    /// rows, never onto the approved person — then rebundles the
    /// automatic "Person N" groups so a drifted cluster can split into
    /// real ones. All on stored vectors, so no photo is re-read, no ML
    /// runs, and nothing on disk moves. Named Inbox rows keep their
    /// faces; confirmed faces never move.
    func rematchFaces() {
        let catalogURL = catalogDatabaseURL
        let configuration = model.configuration
        model.runAsyncJob(
            action: .faceScan,
            runningNote: "Re-matching and regrouping stored faces",
            logTitle: "Re-matched faces",
            logDetail: "Stored face vectors were matched against the approved people — matches filed into the Inbox as lookalikes — and the automatic clusters were rebundled so a drifted cluster can split into real groups. No photos were re-read, no ML ran, and no files or events moved.",
            operation: { progress in
                let service = FaceIndexService(catalogURL: catalogURL)
                // Bootstrap stays the path that creates the face tables,
                // but on a catalog that already has them it would only
                // open a second writer against a possibly-locked
                // database — the transient-failure retry inside the
                // store covers the BEGIN IMMEDIATE stutter instead.
                if try !service.faceSchemaExists() {
                    _ = try CatalogStore(url: catalogURL).bootstrap(
                        configuration: configuration,
                        createBackup: false,
                        createLibraryFolders: false
                    )
                }
                return try service.rematchRoster { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Matching", command: ""))
                }
            },
            completion: { [weak self] report in
                self?.facesRevision &+= 1
                guard report.facesMoved > 0 || report.groupsDissolved > 0 else {
                    return "Re-match finished — nothing moved."
                }
                var parts = ["\(report.facesMoved) face\(report.facesMoved == 1 ? "" : "s") moved"]
                if report.facesProposed > 0 {
                    parts.append("\(report.facesProposed) filed in the Inbox as lookalikes")
                }
                if report.groupsCreated > 0 {
                    parts.append("\(report.groupsCreated) group\(report.groupsCreated == 1 ? "" : "s") formed")
                }
                if report.groupsDissolved > 0 {
                    parts.append("\(report.groupsDissolved) dissolved")
                }
                return "Re-match done — \(parts.joined(separator: ", ")). Stored vectors only; nothing on disk moved."
            }
        )
    }
}

extension Array where Element == OrganizeStack {
    /// Reuses the previous board's stack ids wherever a rebuilt stack holds
    /// the same files (matched by path keys). A rename repoints paths inside
    /// the stacks already on the board, so the id a preview or selection is
    /// bound to survives the refresh that follows instead of pointing at a
    /// stack that no longer exists.
    func carryingIDs(from previous: [OrganizeStack]) -> [OrganizeStack] {
        var idByFiles: [Set<String>: String] = [:]
        for stack in previous {
            let files = Set(stack.files.map(\.pathKey))
            if !files.isEmpty { idByFiles[files] = stack.id }
        }
        guard !idByFiles.isEmpty else { return self }
        // A carried id is a stack's old path-derived id, so it can equal the
        // natural id of a different stack that later landed on that path (a
        // photo moved away, another moved in under the same name). Two stacks
        // must never share an id — selection, previews and moves all go by
        // it — so the stack that has no claim on the id takes a suffixed one.
        var taken: Set<String> = []
        var carried: [Int: String] = [:]
        for (index, stack) in enumerated() {
            if let id = idByFiles[Set(stack.files.map(\.pathKey))], taken.insert(id).inserted {
                carried[index] = id
            }
        }
        return enumerated().map { index, stack in
            var stack = stack
            if let id = carried[index] {
                stack.id = id
            } else if !taken.insert(stack.id).inserted {
                var number = 2
                while taken.contains("\(stack.id)#\(number)") { number += 1 }
                stack.id = "\(stack.id)#\(number)"
                taken.insert(stack.id)
            }
            return stack
        }
    }
}
