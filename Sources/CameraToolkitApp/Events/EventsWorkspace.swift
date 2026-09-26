import AppKit
import CameraToolkitCore
import Foundation
import Observation

extension Notification.Name {
    static let cameraToolkitUndoSort = Notification.Name("CameraToolkit.UndoSort")
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

private struct AssignmentChange {
    var title: String
    var removed: [PhotoEventAssignment]
    var added: [PhotoEventAssignment]
}

/// A grid built from the catalog-implied `Card Copy` paths, before any
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

private struct PlannedReassignment: Sendable {
    var removed: PhotoEventAssignment
    var added: PhotoEventAssignment
    var moveSourcePath: String?
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

    init(_ asset: EventAssetPresence) {
        assignment = asset.assignment
        sourcePath = asset.sourcePath
        drivePath = asset.drivePath
        otherDrivePath = asset.otherDrivePath
        source = asset.source
        drive = asset.drive
        otherDrive = asset.otherDrive
        sourceIsDriveCopy = asset.sourceIsDriveCopy
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

private struct NASArchiveGroup: Sendable {
    /// The event these files are assigned to — on a family board the
    /// assets can belong to a subevent, whose layout nests deeper.
    var owner: SavedCameraEvent
    var root: URL
    var deviceID: String?
    var files: [FileRecord]
}

private struct NASArchiveOutcome: Sendable {
    var copied = 0
    var alreadySafe = 0
    var conflicts = 0
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

/// One `Card Copy` root per (member, device id) for the default implied-path
/// resolver — building the root spends a `DateFormatter` and an ancestor
/// walk per call, so the build runs once per key and only `relativePath`
/// joins per file.
private final class ImpliedCardCopyRoots: @unchecked Sendable {
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
    var sources: [UUID: UnsortedSourceState] = [:]
    var selectedStackIDs: Set<String> = []
    var focusedStackID: String?
    var presence: [UUID: EventPresenceSummary] = [:]
    var eventStacks: [UUID: [OrganizeStack]] = [:] {
        didSet { reindexEventStacks(from: oldValue) }
    }
    /// Files still resolving behind an event's first screen. While a
    /// count sits here the board's grid is real but partial — scrollable
    /// and openable — and a status line says the rest is still coming.
    var eventBuildRemainders: [UUID: Int] = [:]
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
    var pendingTrash: PendingTrashRequest?
    var latestMoveJournalTitle: String?
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
    private var assignmentUndoStack: [AssignmentChange] = []

    @ObservationIgnored private var selectionAnchorID: String?
    @ObservationIgnored private var indexRevision = -1
    @ObservationIgnored private var indexCount = -1
    @ObservationIgnored private var assignmentsByPathKey: [String: PhotoEventAssignment] = [:]
    @ObservationIgnored private var assignmentCounts: [UUID: Int] = [:]
    @ObservationIgnored private var assignmentBytes: [UUID: Int64] = [:]
    @ObservationIgnored private var eventAssetsByPathKey: [UUID: [String: EventAssetPresence]] = [:]
    @ObservationIgnored private var refreshGenerations: [UUID: UUID] = [:]
    /// The deferred refresh pipeline running per event — the remaining
    /// files' implied-path build, then the four-place presence sweep. A
    /// new refresh cancels the stale one so it never finishes against an
    /// old generation. Never awaited: `await task.value` would escalate
    /// it to the caller's priority, undoing the utility tier that keeps
    /// it off the UI path. The pipeline applies its own results and
    /// resolves `presenceWaiters`.
    @ObservationIgnored private var presenceTasks: [UUID: Task<Void, Never>] = [:]
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
    /// it. Production joins the catalog-implied `Card Copy` path, pure
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
    @ObservationIgnored private var eventGridRevisions: [UUID: Int] = [:]
    /// Event id → event index for title/policy lookups that must stay
    /// filesystem-free: `EventStorageLocations` standardizes the drive roots
    /// when it is built, so context menus and rows ask `EventHierarchy`
    /// through this index instead.
    @ObservationIgnored private var eventsByIDCache: (revision: Int, byID: [UUID: SavedCameraEvent])?
    @ObservationIgnored private let mountObservers = MountObserverBox()

    /// Holds move journals and the capture-time cache.
    let supportFolder: URL

    /// Background disk work waits at this gate while a speed test is
    /// measuring the volume it would touch — scans, sweeps, capture-date
    /// reads, and tile decodes resume by themselves when the test ends.
    let driveActivityGate: DriveActivityGate

    init(
        model: DashboardModel,
        supportFolder: URL = EventsWorkspace.defaultSupportFolder,
        driveActivityGate: DriveActivityGate = .shared
    ) {
        self.model = model
        self.supportFolder = supportFolder
        self.driveActivityGate = driveActivityGate
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

    var captureDateCache: CaptureDateCache {
        if let loadedCaptureDateCache { return loadedCaptureDateCache }
        let cache = CaptureDateCache(url: supportFolder.appendingPathComponent("capture-dates.json"))
        loadedCaptureDateCache = cache
        return cache
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
        guard !needle.isEmpty || filter.hasActiveConditions else { return sidebarEvents }
        return sidebarEvents.filter { row in
            let textHit = needle.isEmpty
                || OrganizeSearch.matches(eventTitle(row.event), needle: needle)
                || eventPeople(row.event.id).contains { OrganizeSearch.matches($0.name, needle: needle) }
            guard textHit else { return false }
            return OrganizeSearch.matches(
                subject: sidebarSubject(for: row.event),
                search: filter
            )
        }
    }

    /// An event as filter-builder facts — the same subject a board builds
    /// per stack: its roster people (`event.people`, unnamed groups never
    /// count here), itself plus its ancestors so an Event row for a parent
    /// keeps the subevent's row too, the media kinds its assigned files
    /// carry, and its date as the capture span.
    private func sidebarSubject(for event: SavedCameraEvent) -> OrganizeFilterSubject {
        OrganizeFilterSubject(
            personIDs: Set(eventPeople(event.id).map(\.id)),
            eventIDs: ancestorScope(of: event),
            mediaKinds: eventMediaKinds(for: event.id),
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

    var canUndoSort: Bool { !assignmentUndoStack.isEmpty }

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
        // Tracked read: views that call this re-evaluate when
        // `refreshConnectivity()` bumps `connectivityRevision`.
        _ = connectivityRevision
        let url = URL(fileURLWithPath: DashboardModel.expandedPath(location.path), isDirectory: true)
        // One filesystem check per folder per connectivity revision — a
        // sidebar re-render between refreshes answers from the cache.
        if let cached = connectedPathsCache, cached.revision == connectivityRevision, let connected = cached.paths[url.path] {
            return connected
        }
        let connected = VolumeInfo.isAvailable(url, mountedVolumes: mountedVolumePaths()) && FileManager.default.fileExists(atPath: url.path)
        var paths = connectedPathsCache?.revision == connectivityRevision ? connectedPathsCache?.paths ?? [:] : [:]
        paths[url.path] = connected
        connectedPathsCache = (connectivityRevision, paths)
        return connected
    }

    /// The mounted volume set, read once per connectivity revision instead of
    /// once per `isConnected` call in a sidebar render.
    private func mountedVolumePaths() -> Set<String> {
        if let cached = mountedVolumesCache, cached.revision == connectivityRevision {
            return cached.paths
        }
        let paths = VolumeInfo.mountedVolumePaths()
        mountedVolumesCache = (connectivityRevision, paths)
        return paths
    }

    static func sourceKey(_ assignment: PhotoEventAssignment) -> String {
        EventStorageLocations.pathKey(
            (DashboardModel.expandedPath(assignment.sourceRootPath) as NSString).appendingPathComponent(assignment.relativePath)
        )
    }

    private func refreshIndexIfNeeded() {
        let assignments = model.configuration.photoEventAssignments
        guard indexRevision != model.catalogStateRevision || indexCount != assignments.count else { return }
        var index: [String: PhotoEventAssignment] = [:]
        index.reserveCapacity(assignments.count * 2)
        var counts: [UUID: Int] = [:]
        var bytes: [UUID: Int64] = [:]
        // `pathKey` walks the filesystem: realpath stats every component,
        // and a NAS path answers in milliseconds. Every root joined below
        // was already standardized once — the drive/staging roots at
        // `EventStorageLocations.init` and the source roots here — so for
        // a clean relative path the resolved key is a string join plus a
        // lowercase. Only a rare unclean relative path pays for realpath.
        var sourceRoots: [String: String] = [:]
        func sourceRoot(_ raw: String) -> String {
            if let cached = sourceRoots[raw] { return cached }
            let built = URL(fileURLWithPath: DashboardModel.expandedPath(raw), isDirectory: true)
                .standardizedFileURL.path
            sourceRoots[raw] = built
            return built
        }
        func insert(_ key: String?, _ assignment: PhotoEventAssignment) {
            guard let key, index[key] == nil else { return }
            index[key] = assignment
        }
        for assignment in assignments {
            autoreleasepool {
                let rootPath = sourceRoot(assignment.sourceRootPath)
                if let key = EventStorageLocations.joinedPathKey(rootPath: rootPath, relativePath: assignment.relativePath) {
                    insert(key, assignment)
                } else {
                    insert(EventStorageLocations.pathKey(rootPath + "/" + assignment.relativePath), assignment)
                }
                counts[assignment.eventID, default: 0] += 1
                bytes[assignment.eventID, default: 0] += assignment.fileSize
            }
        }
        // The board's tiles point at Card Copy (or the other drive, or the
        // NAS), not at the path the file was imported from. Index those
        // too, without letting them steal a source path that already
        // belongs to a different assignment. One root per event and camera
        // — building it per file redoes the date formatting 13,000 times.
        let eventsByID = Dictionary(uniqueKeysWithValues: model.configuration.savedEvents.map { ($0.id, $0) })
        var cardRoots: [String: String] = [:]
        var archiveLayouts: [String: OrganizedArchiveLayout] = [:]
        for assignment in assignments {
            autoreleasepool {
                guard let owner = eventsByID[assignment.eventID],
                      (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else { return }
                for policy in [EventStoragePolicy.buffer, .archiveOnly] {
                    let cacheKey = "\(owner.id.uuidString)\u{0}\(assignment.deviceID ?? "")\u{0}\(policy.rawValue)"
                    let rootPath = cardRoots[cacheKey] ?? {
                        let built = locations.cardCopyRoot(for: owner, deviceID: assignment.deviceID, policy: policy).path
                        cardRoots[cacheKey] = built
                        return built
                    }()
                    if let key = EventStorageLocations.joinedPathKey(rootPath: rootPath, relativePath: assignment.relativePath) {
                        insert(key, assignment)
                    } else {
                        insert(EventStorageLocations.pathKey(rootPath + "/" + assignment.relativePath), assignment)
                    }
                }
                let layoutKey = "\(owner.id.uuidString)\u{0}\(assignment.deviceID ?? "")"
                let layout = archiveLayouts[layoutKey] ?? {
                    let built = locations.layout(for: owner, deviceID: assignment.deviceID)
                    archiveLayouts[layoutKey] = built
                    return built
                }()
                if let relative = try? layout.destinationRelativePath(for: assignment.relativePath) {
                    // `relative` is assembled from validated components and
                    // sanitized folder names, and `libraryRoot` is
                    // standardized — the archive key is a string join too.
                    let joined = locations.libraryRoot.path + "/" + relative
                    if let key = EventStorageLocations.joinedPathKey(rootPath: locations.libraryRoot.path, relativePath: relative) {
                        insert(key, assignment)
                    } else {
                        insert(EventStorageLocations.pathKey(joined), assignment)
                    }
                }
            }
        }
        assignmentsByPathKey = index
        assignmentCounts = counts
        assignmentBytes = bytes
        indexRevision = model.catalogStateRevision
        indexCount = assignments.count
    }

    func assignment(for file: OrganizeFile) -> PhotoEventAssignment? {
        refreshIndexIfNeeded()
        guard let assignment = assignmentsByPathKey[file.pathKey],
              assignment.fileSize == file.size else { return nil }
        return assignment
    }

    /// Files in the event's family — itself plus every descendant. A
    /// parent's count covers its subevents; a subevent never counts the
    /// parent's files.
    func assignmentCount(for eventID: UUID) -> Int {
        refreshIndexIfNeeded()
        return scopeIDs(eventID).reduce(0) { $0 + (assignmentCounts[$1] ?? 0) }
    }

    func assignmentBytes(for eventID: UUID) -> Int64 {
        refreshIndexIfNeeded()
        return scopeIDs(eventID).reduce(Int64(0)) { $0 + (assignmentBytes[$1] ?? 0) }
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
        return result.stacks.filter { stack in
            if hideSorted, isSorted(stack) { return false }
            guard !search.isEmpty else { return true }
            return OrganizeSearch.matches(
                stack: stack,
                search: search,
                rootPath: result.rootPath,
                facts: stackFacts(stack, people: people)
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
        return stacks.filter {
            OrganizeSearch.matches(
                stack: $0,
                search: scoped,
                rootPath: nil,
                facts: stackFacts($0, people: people)
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
    func eventBoardGroups(
        _ eventID: UUID,
        stacks: [OrganizeStack],
        grouping: OrganizeBoardGrouping,
        sort: OrganizeStackSort
    ) -> [OrganizeBoardGroup] {
        OrganizeBoardPlan.groups(for: stacks, grouping: grouping, sort: sort)
    }

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
    /// single-event breadcrumb match.
    private func stackFacts(_ stack: OrganizeStack, people: BoardPeople) -> OrganizeStackFacts {
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
            personNames: personNames(on: stack)
        )
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
        refreshLatestJournal()
        discoverDriveEvents()
        scheduleRosterWarm()
    }

    func startGuide() {
        if guide == nil {
            guide = SetupGuide(workspace: self)
        }
        guide?.isCollapsed = false
    }

    func selectionChanged() {
        selectedStackIDs = []
        focusedStackID = nil
        selectionAnchorID = nil
        expandedStackIDs = []
        collapsedGroupIDs = []
    }

    func select(stackID: String, orderedIDs: [String], extend: Bool, toggle: Bool) {
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

    func dragPayload(for stackID: String, origin: OrganizeDragPayload.Origin, containerID: UUID) -> String {
        OrganizeDragPayload(origin: origin, containerID: containerID, stackIDs: Array(targetStackIDs(including: stackID))).encoded
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
        guard isConnected(location) else {
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
            guard isConnected(location) else { continue }
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
        pushUndo(change)
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
        pushUndo(change)
        model.statusMessage = "Unsorted \(removable.count) file\(removable.count == 1 ? "" : "s")."
    }

    func undoLastSort() {
        guard let change = assignmentUndoStack.popLast() else {
            model.statusMessage = "Nothing to undo."
            return
        }
        applyAssignmentChange(AssignmentChange(title: change.title, removed: change.added, added: change.removed), touching: nil)
        model.statusMessage = "Undid “\(change.title)”."
    }

    private func pushUndo(_ change: AssignmentChange) {
        assignmentUndoStack.append(change)
        if assignmentUndoStack.count > 50 {
            assignmentUndoStack.removeFirst(assignmentUndoStack.count - 50)
        }
    }

    private func hasDriveCopy(_ assignment: PhotoEventAssignment, locations: EventStorageLocations) -> Bool {
        guard let event = event(assignment.eventID) else { return false }
        let sourceKey = locations.sourceURL(for: assignment).map { EventStorageLocations.pathKey($0.path) }
        return EventStoragePolicy.allCases.contains { policy in
            guard let url = locations.driveURL(for: assignment, event: event, policy: policy),
                  EventStorageLocations.pathKey(url.path) != sourceKey else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    private func applyAssignmentChange(_ change: AssignmentChange, touching eventID: UUID?, addedItems: [OrganizeItem] = []) {
        let removedIDs = Set(change.removed.map(CatalogStore.eventAssetID))
        model.updateConfiguration { configuration in
            if !removedIDs.isEmpty {
                configuration.photoEventAssignments.removeAll { removedIDs.contains(CatalogStore.eventAssetID($0)) }
            }
            if !change.added.isEmpty {
                let existing = Set(configuration.photoEventAssignments.map(CatalogStore.eventAssetID))
                configuration.photoEventAssignments.append(
                    contentsOf: change.added.filter { !existing.contains(CatalogStore.eventAssetID($0)) }
                )
            }
            if let eventID, let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) {
                configuration.savedEvents[index].lastUsedAt = Date()
            }
        }
        // Open boards update in place — no refresh, no sweep, no grid
        // rebuild. Removed files leave every board by file identity, and
        // a board that already displays files gains the items it just
        // got. An addition whose items the caller could not supply (an
        // undo of a move, say) still refreshes that board the way it
        // always did.
        removeAssignmentsFromEventBoards(change.removed)
        let covered = Set(addedItems.flatMap(\.files).map(Self.fileKey))
        for (targetID, added) in Dictionary(grouping: change.added, by: \.eventID) {
            guard let stacks = eventStacks[targetID] else { continue }
            let wanted = Set(added.map(Self.fileKey))
            guard wanted.isSubset(of: covered) else {
                Task { await refreshEvent(targetID) }
                continue
            }
            eventStacks[targetID] = OrganizeStacker.stacks(
                for: stacks.flatMap(\.items) + addedItems,
                splits: model.configuration.burstSplits
            ).carryingIDs(from: stacks)
            eventGridRevisions[targetID] = model.catalogStateRevision
        }
    }

    /// `FaceIndexStore.fileKey` for a catalog assignment — name, byte
    /// count, mtime; the identity that survives the file moving folders.
    private static func fileKey(_ assignment: PhotoEventAssignment) -> String {
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

    func deleteEmptyEvent(_ eventID: UUID) {
        guard assignmentCount(for: eventID) == 0, let event = event(eventID) else {
            model.statusMessage = "Only an event with no photos can be deleted. Move or return its photos first."
            return
        }
        guard EventHierarchy.descendants(of: eventID, in: model.configuration.savedEvents).isEmpty else {
            model.statusMessage = "\(eventTitle(event)) has subevents. Move or delete them first."
            return
        }
        model.updateConfiguration { $0.savedEvents.removeAll { $0.id == eventID } }
        if selection == .event(eventID) { selection = nil }
        model.statusMessage = "Deleted the empty event \(event.name)."
    }

    /// `nil` leaves the policy unset: a subevent then follows its parent's
    /// setting, and a top-level event resolves to the shared Buffer.
    func setPolicy(_ eventID: UUID, _ policy: EventStoragePolicy?) {
        model.updateConfiguration { configuration in
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].storagePolicy = policy
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

        var folderMoves: [(URL, URL)] = []
        for candidate in EventStoragePolicy.allCases {
            let old = locations.eventFolder(for: event, policy: candidate)
            let new = locations.eventFolder(for: renamed, policy: candidate)
            guard EventStorageLocations.pathKey(old.path) != EventStorageLocations.pathKey(new.path),
                  fileManager.fileExists(atPath: old.path) else { continue }
            guard !fileManager.fileExists(atPath: new.path) else {
                model.statusMessage = "A folder named “\(new.lastPathComponent)” already exists. Choose another name or date."
                return
            }
            folderMoves.append((old, new))
        }

        var moved: [(URL, URL)] = []
        for (old, new) in folderMoves {
            do {
                try DriveMoveService().moveFolder(from: old, to: new)
                moved.append((old, new))
            } catch {
                for (original, renamedFolder) in moved.reversed() {
                    try? DriveMoveService().moveFolder(from: renamedFolder, to: original)
                }
                model.statusMessage = "Could not rename the event folder: \(error.localizedDescription)"
                return
            }
        }

        // Subevent folders move with the renamed parent, so their adopted
        // assignments need the same path rewrite.
        let touchedIDs = Set(EventHierarchy.descendants(of: eventID, in: model.configuration.savedEvents).map(\.id))
            .union([eventID])
        model.updateConfiguration { configuration in
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].name = renamed.name
            configuration.savedEvents[index].eventDate = renamed.eventDate
            configuration.savedEvents[index].parentEventID = renamed.parentEventID
            configuration.savedEvents[index].storagePolicy = renamed.storagePolicy
            // Adopted assignments point straight at the old folder.
            for (old, new) in moved {
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
        let oldLayout = locations.layout(for: event, deviceID: nil)
        var oldNAS = locations.libraryRoot
            .appendingPathComponent("Originals", isDirectory: true)
            .appendingPathComponent(oldLayout.year, isDirectory: true)
        for folder in oldLayout.parentEventFolders {
            oldNAS.appendPathComponent(folder, isDirectory: true)
        }
        oldNAS.appendPathComponent(oldLayout.eventFolder, isDirectory: true)
        let nasNote = VolumeInfo.isAvailable(oldNAS) && fileManager.fileExists(atPath: oldNAS.path)
            ? " NAS copies keep the old folder name until you archive again."
            : ""
        model.statusMessage = "Renamed to \(eventTitle(renamed))." + nasNote
            + (newResolved == oldResolved ? ""
                : newResolved == .archiveOnly
                    ? " Its originals stay out of the shared Buffer. Use Move to Private for any copies already there."
                    : " It's a shared event now. Use Put on Buffer for copies still in Private.")
        for touchedID in touchedIDs {
            Task { await refreshEvent(touchedID) }
        }
    }

    func discoverDriveEvents() {
        let configuration = model.configuration
        let locations = self.locations
        let gate = driveActivityGate
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [DiscoveredDriveEvent] in
                var all: [DiscoveredDriveEvent] = []
                if VolumeInfo.isAvailable(locations.bufferRoot),
                   gate.waitIfPaused(for: locations.bufferRoot, shouldStop: { Task.isCancelled }) {
                    all += (try? DriveEventDiscovery.discover(driveRoot: locations.bufferRoot, policy: .buffer, configuration: configuration)) ?? []
                }
                if VolumeInfo.isAvailable(locations.privateStagingRoot),
                   gate.waitIfPaused(for: locations.privateStagingRoot, shouldStop: { Task.isCancelled }) {
                    all += (try? DriveEventDiscovery.discover(driveRoot: locations.privateStagingRoot, policy: .archiveOnly, configuration: configuration)) ?? []
                }
                return all
            }.value
            self?.discoveredDriveEvents = found
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

    /// Three passes, ordered by what the board needs first.
    ///
    /// Pass one draws only the first screen of the grid — the earliest
    /// files of the event being opened — from the place the catalog
    /// already implies: that event's `Card Copy` folder joined with each
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
        let generation = UUID()
        refreshGenerations[eventID] = generation
        presenceTasks[eventID]?.cancel()
        let locations = self.locations
        let policy = locations.resolvedPolicy(for: event)
        let cache = captureDateCache
        let burstSplits = model.configuration.burstSplits
        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
        let probe = presenceProbe
        let dateReadProbe = captureDateReadProbe
        let gate = driveActivityGate

        // The catalog state this pipeline proves itself against. A grid
        // that already reflects it — every build landed, no pending date
        // reads — only needs the sweep's verification, and a state change
        // that lands mid-pipeline (its revision is newer) drops the
        // pipeline's results instead of being overwritten by them.
        let revisionAtStart = model.catalogStateRevision
        let existingFiles = eventStacks[eventID]?.flatMap(\.files)
        // An empty grid is an answer ("nothing reachable"), never a board
        // worth keeping: once a drive comes back it must rebuild.
        let gridIsCurrent = existingFiles?.isEmpty == false
            && eventGridRevisions[eventID] == revisionAtStart
            && eventBuildRemainders[eventID] == nil
            && eventDateReadRemainders[eventID] == nil

        // The board shows each direct subevent as its own section, so
        // the family is this event plus every descendant. Each member's
        // files resolve inside that member's folder.
        let members = [event] + EventHierarchy.descendants(of: eventID, in: model.configuration.savedEvents)
        let assignmentsByEvent = Dictionary(grouping: model.configuration.photoEventAssignments, by: \.eventID)
        let memberIDs = Set(members.map(\.id))
        var memberSubtrees: [UUID: Set<UUID>] = [:]
        for member in members {
            memberSubtrees[member.id] = scopeIDs(member.id).intersection(memberIDs)
        }
        let memberByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        let openedAssignments = assignmentsByEvent[eventID] ?? []
        let familyAssignments = members.flatMap { assignmentsByEvent[$0.id] ?? [] }

        // Reachability first, before any per-file work: the mount table
        // answers unplugged drives without touching a path, and every
        // other place root gets one existence stat off this actor, bounded
        // by a timeout so a hung share can never hold the board. A volume
        // that does not answer is treated as unmounted for the rest of
        // this refresh — nothing below stats a file on it.
        let mountedAll = mountedVolumesProvider?() ?? VolumeInfo.mountedVolumePaths()
        let places = EventReachability.places(members: members, assignments: familyAssignments, locations: locations)
        let report = await EventReachability.check(
            places: places,
            mountedVolumes: mountedAll,
            timeout: placeResponseTimeout,
            probe: placeResponseProbe
        )
        guard refreshGenerations[eventID] == generation else { return }
        eventReachability[eventID] = report.offlinePlaces.isEmpty ? nil : report
        let mounted = mountedAll.subtracting(report.unresponsiveVolumes)
        if report.isOffline {
            // Terminal right away: nothing the board could read is
            // reachable, so a grid left from before the drive went away
            // only points at dead paths. The sweep below still runs — it
            // is string work plus mount-table answers here, never a stat —
            // to keep the storage strip truthful.
            eventStacks[eventID] = []
            eventBuildRemainders[eventID] = nil
            eventDateReadRemainders[eventID] = nil
        }

        let driveAvailableByMember = Dictionary(uniqueKeysWithValues: members.map { member in
            (member.id, VolumeInfo.isAvailable(locations.driveRoot(for: locations.resolvedPolicy(for: member)), mountedVolumes: mounted))
        })
        let resolve: @Sendable (PhotoEventAssignment) -> String?
        if let eventPathResolver {
            resolve = eventPathResolver
        } else {
            let cardCopyRoots = ImpliedCardCopyRoots()
            resolve = { assignment in
                guard (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else { return nil }
                let owner = memberByID[assignment.eventID] ?? event
                let root = cardCopyRoots.root(memberID: owner.id, deviceID: assignment.deviceID) {
                    locations.cardCopyRoot(for: owner, deviceID: assignment.deviceID, policy: locations.resolvedPolicy(for: owner))
                }
                return root.appendingPathComponent(assignment.relativePath).path
            }
        }

        // Pass one is skipped when this event's drive is offline: there
        // is no local copy to point a tile at, and drawing one anyway
        // would paint a grid of dead paths. The sweep then publishes
        // the grid. Subevent files wait for pass two so the first
        // screen stays the event the user opened.
        let driveAvailable = driveAvailableByMember[eventID] == true
        var firstPaint: EventImpliedGrid?
        // The first screen is a loading affordance — it paints only into
        // an empty grid. An event that already has a board keeps every
        // tile it has while the pipeline re-verifies; it never shrinks
        // back to the first screen.
        if driveAvailable && eventStacks[eventID]?.isEmpty != false {
            firstPaint = await Task.detached(priority: .userInitiated) { () -> EventImpliedGrid in
                let earliest = openedAssignments
                    .sorted { ($0.modifiedAt, $0.relativePath) < ($1.modifiedAt, $1.relativePath) }
                    .prefix(Self.firstScreenFileLimit)
                let files = earliest.compactMap { assignment -> OrganizeFile? in
                    guard let path = resolve(assignment) else { return nil }
                    return OrganizeFile(literalPath: path, size: assignment.fileSize, modifiedAt: assignment.modifiedAt)
                }
                let items = OrganizeScanner.items(for: files, cache: cache, pauseGate: gate).items
                return EventImpliedGrid(
                    files: files,
                    stacks: OrganizeStacker.stacks(for: items, splits: burstSplits)
                )
            }.value
        }

        guard refreshGenerations[eventID] == generation else { return }
        if let firstPaint {
            eventStacks[eventID] = firstPaint.stacks.carryingIDs(from: eventStacks[eventID] ?? [])
            eventGridRevisions[eventID] = revisionAtStart
            let remaining = familyAssignments.count - firstPaint.files.count
            eventBuildRemainders[eventID] = remaining > 0 ? remaining : nil
        } else if eventStacks[eventID] == nil {
            eventBuildRemainders[eventID] = nil
        }
        eventDateReadRemainders[eventID] = nil

        // The rest of the family, then the four-place sweep, is one
        // utility-priority pipeline that applies itself back on this
        // actor instead of being awaited here. Building before the
        // sweep keeps `finishPresenceSweep`'s path comparison honest,
        // and utility priority keeps both off scrolling and tile decode.
        let pipeline = Task.detached(priority: .utility) { [self] in
            var built: EventImpliedGrid?
            if !gridIsCurrent {
                var files: [OrganizeFile] = []
                files.reserveCapacity(familyAssignments.count)
                for assignment in familyAssignments where !Task.isCancelled {
                    guard driveAvailableByMember[assignment.eventID] == true else { continue }
                    guard let path = resolve(assignment) else { continue }
                    files.append(OrganizeFile(literalPath: path, size: assignment.fileSize, modifiedAt: assignment.modifiedAt))
                }
                if !Task.isCancelled, !files.isEmpty {
                    // The provisional grid stacks on whatever the cache already
                    // knows — a miss is "no camera date" here, never a header
                    // read — so every resolved file boards at once instead of
                    // waiting out the remaining capture-date reads. The count
                    // of those reads rides the apply so the board can say
                    // dates are still coming without saying files are.
                    let undated = OrganizeScanner.items(for: files, cache: cache, readMissingCaptureDates: false, pauseGate: gate)
                    await applyEventBuild(
                        eventID: eventID,
                        generation: generation,
                        revision: revisionAtStart,
                        build: EventImpliedGrid(
                            files: files,
                            stacks: OrganizeStacker.stacks(for: undated.items, splits: burstSplits)
                        ),
                        pendingDateReads: undated.missingCaptureDates
                    )
                }
                if !Task.isCancelled, !files.isEmpty {
                    // The dated pass the provisional grid stood in for. The
                    // read seam attaches only here so a parked read always
                    // means "after the provisional publish".
                    let previousProbe = cache.timestampProbe
                    cache.timestampProbe = dateReadProbe
                    let dated = OrganizeScanner.items(for: files, cache: cache, pauseGate: gate)
                    cache.timestampProbe = previousProbe
                    built = EventImpliedGrid(
                        files: files,
                        stacks: OrganizeStacker.stacks(for: dated.items, splits: burstSplits)
                    )
                }
                await applyEventBuild(eventID: eventID, generation: generation, revision: revisionAtStart, build: built)
            }

            var memberSummaries: [UUID: EventPresenceSummary] = [:]
            var cancelled = false
            for member in members {
                guard !Task.isCancelled else { cancelled = true; break }
                guard let memberSummary = EventPresenceScanner.scan(
                    event: member,
                    assignments: assignmentsByEvent[member.id] ?? [],
                    locations: locations,
                    mountedVolumes: mounted,
                    probe: probe,
                    pauseGate: gate
                ) else { cancelled = true; break }
                memberSummaries[member.id] = memberSummary
            }
            var output: EventRefreshOutput?
            if !cancelled {
                let assets = members.flatMap { memberSummaries[$0.id]?.assets ?? [] }
                var scopedSummaries: [UUID: EventPresenceSummary] = [:]
                for member in members {
                    let subtree = memberSubtrees[member.id] ?? [member.id]
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
                    guard let path = asset.bestLocalPath else { continue }
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
                output = EventRefreshOutput(
                    summary: summary,
                    memberSummaries: scopedSummaries,
                    files: sweptFiles,
                    assetsByPathKey: byPath,
                    immich: immich
                )
            }
            await finishPresenceSweep(
                eventID: eventID,
                generation: generation,
                revision: revisionAtStart,
                // A reused grid verifies against what it shows: the sweep
                // restacks only when the files on disk are not the files
                // on the board.
                builtFiles: built?.files ?? existingFiles,
                output: output
            )
        }
        presenceTasks[eventID] = pipeline
        await withCheckedContinuation { (cc: CheckedContinuation<Void, Never>) in
            presenceWaiters[eventID, default: []].append((generation, cc))
        }
    }

    /// Main-actor landing point for the deferred build: the full implied
    /// grid replaces the first screen, carrying the stack ids an open
    /// preview or a decoded tile is bound to wherever the same files
    /// land together again. `pendingDateReads` is how many cache-miss
    /// capture-date reads the dated pass still owes — the provisional
    /// grid carries it so the board can say dates are still coming, and
    /// the dated grid lands with zero to clear it. A stale generation
    /// drops the build instead.
    private func applyEventBuild(eventID: UUID, generation: UUID, revision: Int, build: EventImpliedGrid?, pendingDateReads: Int = 0) {
        guard refreshGenerations[eventID] == generation else { return }
        // A mutation that landed after the pipeline started already
        // patched the open grid itself — this older build must not
        // overwrite it.
        guard (eventGridRevisions[eventID] ?? -1) <= revision else { return }
        guard let build else { return }
        eventStacks[eventID] = build.stacks.carryingIDs(from: eventStacks[eventID] ?? [])
        eventGridRevisions[eventID] = revision
        eventBuildRemainders[eventID] = nil
        eventDateReadRemainders[eventID] = pendingDateReads > 0 ? pendingDateReads : nil
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
        guard (eventGridRevisions[eventID] ?? -1) <= revision else { return }
        guard let output else { return }

        eventAssetsByPathKey[eventID] = output.assetsByPathKey
        presence[eventID] = output.summary
        for (memberID, memberSummary) in output.memberSummaries {
            presence[memberID] = memberSummary
        }
        eventImmichStatuses[eventID] = output.immich
        // Set compare, not array compare: the baseline for a reused grid
        // is the board's own files in stack order, and only "which files
        // are on disk" decides whether a restack is owed.
        guard Set(output.files.map(\.pathKey)) != Set((builtFiles ?? []).map(\.pathKey)) else { return }

        // Files resolved somewhere other than the implied Card Copy path —
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
        eventStacks[eventID] = rebuilt.carryingIDs(from: eventStacks[eventID] ?? [])
        eventGridRevisions[eventID] = revision
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
                        let built = locations.cardCopyRoot(for: event, deviceID: asset.assignment.deviceID, policy: policy).path
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
        pendingApplyPlan = nil
        runningApply = nil
        let moves = plan.groups.flatMap(\.moves)
        let copies = plan.groups.flatMap { group in group.copies.map { (group.event, $0) } }
        let journalFolder = self.journalFolder
        let boundaries = plan.pruneBoundaries
        let title = plan.title
        let affectedEvents = plan.groups.map(\.event.id)

        if !moves.isEmpty {
            let jobID = model.runBackgroundJob(
                action: .organize,
                runningNote: "Moving \(moves.count) file(s) into their events",
                logTitle: title,
                logDetail: "Renamed files on the same drive. No file bytes were rewritten and nothing was replaced.",
                operation: { progress in
                    try DriveMoveService().apply(
                        moves,
                        title: title,
                        journalFolder: journalFolder,
                        pruneBoundaries: boundaries
                    ) { update in
                        progress(DashboardModel.jobUpdate(from: update, notePrefix: "Organizing", command: ""))
                    }
                },
                completion: { [weak self] report in
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
        let key = Self.sourceKey(assignment)
        return model.configuration.photoEventAssignments.contains { other in
            other.eventID == assignment.eventID
                && other.deviceID == assignment.deviceID
                && other.relativePath.lowercased() == assignment.relativePath.lowercased()
                && Self.sourceKey(other) != key
        }
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
        let jobID = model.runBackgroundJob(
            action: .organize,
            runningNote: "Moving \(moves.count + keep.count) file(s) into their events",
            logTitle: title,
            logDetail: "Renamed files on the same drive. Files whose name was taken moved in under a free “(N)” name. Nothing was replaced.",
            operation: { progress in
                try DriveMoveService().keepBoth(
                    keep,
                    plainMoves: moves,
                    title: title,
                    journalFolder: journalFolder,
                    pruneBoundaries: boundaries
                ) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Organizing", command: ""))
                }
            },
            completion: { [weak self] outcome in
                guard let self else { return "" }
                applyAssignmentChange(
                    AssignmentChange(title: title, removed: outcome.removedAssignments, added: outcome.addedAssignments),
                    touching: nil
                )
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
        model.runBackgroundJob(
            action: .organize,
            runningNote: "Moving \(conflicts.count) file(s) in under a new name",
            logTitle: title,
            logDetail: "Renamed files on the same drive to a free “(N)” name next to the file that already had their name. Nothing was replaced.",
            operation: { progress in
                try DriveMoveService().keepBoth(
                    conflicts,
                    title: title,
                    journalFolder: journalFolder,
                    pruneBoundaries: boundaries
                ) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Moving", command: ""))
                }
            },
            completion: { [weak self] outcome in
                guard let self else { return "" }
                applyAssignmentChange(
                    AssignmentChange(title: title, removed: outcome.removedAssignments, added: outcome.addedAssignments),
                    touching: nil
                )
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
        for (id, state) in sources {
            if let result = state.result {
                sources[id]?.result = result.removingFiles(withPathKeys: movedKeys)
            }
        }
        selectedStackIDs.removeAll()
        focusedStackID = nil
        expandedStackIDs.removeAll()
        runningApply = nil
        refreshLatestJournal()
        for eventID in Set(events) {
            Task { await refreshEvent(eventID) }
        }
    }

    func refreshLatestJournal() {
        latestMoveJournalTitle = DriveMoveService.latestUndoableJournal(in: self.journalFolder)?.journal.title
    }

    /// A rename batch landed, straight from the move report: every stack
    /// the boards already show repoints at the destination paths and the
    /// tile loader reroutes decodes off the vacated ones, so an open
    /// preview or tile keeps reading the moved file instead of failing on
    /// its old path. Called in the same update that records the move —
    /// `refreshEvent` still runs afterwards to restat the library; the
    /// preview is already correct before that finishes.
    private func retargetMovedPaths(_ moved: [DriveMove]) {
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

    func undoLastMove() {
        guard let latest = DriveMoveService.latestUndoableJournal(in: self.journalFolder) else {
            latestMoveJournalTitle = nil
            model.statusMessage = "There is no move to undo."
            return
        }
        let url = latest.url
        let boundaries = [locations.bufferRoot, locations.privateStagingRoot]
        model.runBackgroundJob(
            action: .organize,
            runningNote: "Undoing “\(latest.journal.title)”",
            logTitle: "Undid a move",
            logDetail: "Renamed files back to where they were. Nothing was replaced.",
            operation: { progress in
                try DriveMoveService().undo(journalURL: url, pruneBoundaries: boundaries) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Undoing", command: ""))
                }
            },
            completion: { [weak self] outcome in
                guard let self else { return "" }
                retargetMovedPaths(outcome.report.moved)
                let journal = outcome.journal
                if !journal.addedAssignments.isEmpty || !journal.removedAssignments.isEmpty {
                    applyAssignmentChange(
                        AssignmentChange(title: journal.title, removed: journal.addedAssignments, added: journal.removedAssignments),
                        touching: nil
                    )
                }
                refreshLatestJournal()
                for location in unsortedLocations where sources[location.id]?.result != nil {
                    scan(location, force: true)
                }
                for eventID in Set(journal.addedAssignments.map(\.eventID) + journal.removedAssignments.map(\.eventID)) {
                    Task { await self.refreshEvent(eventID) }
                }
                if case .event(let eventID) = selection {
                    Task { await self.refreshEvent(eventID) }
                }
                return "Moved \(outcome.report.moved.count) file(s) back." + (outcome.report.skipped.isEmpty ? "" : " \(outcome.report.skipped.count) could not move back.")
            }
        )
    }

    // MARK: - Reorganize inside events

    /// Every exit leaves the owner a sentence: a queued or running job, an
    /// already-there note, or a name collision. A board still painting or a
    /// presence index still empty is never a reason to drop the click.
    func moveStacks(_ stackIDs: Set<String>, fromEvent sourceEventID: UUID, toEvent targetEventID: UUID) {
        guard let from = event(sourceEventID), let to = event(targetEventID) else {
            model.statusMessage = "The source or destination event no longer exists — nothing was moved."
            return
        }
        guard sourceEventID != targetEventID else {
            model.statusMessage = "Those files are already in \(eventTitle(to))."
            return
        }
        guard let stacks = eventStacks[sourceEventID] else {
            queueMove(stackIDs, from: from, to: to)
            return
        }
        moveLoadedStacks(stacks.filter { stackIDs.contains($0.id) }, from: from, to: to)
    }

    /// A click arrived before the board painted, so the stack ids cannot be
    /// opened into their files yet. The click waits on the in-flight refresh
    /// (or starts one) and then runs the same move — it is never dropped.
    private func queueMove(_ stackIDs: Set<String>, from: SavedCameraEvent, to: SavedCameraEvent) {
        model.statusMessage = "Move to \(eventTitle(to)) queued — \(eventTitle(from)) is still loading. It runs as soon as the board appears."
        Task { @MainActor [weak self] in
            guard let self else { return }
            await waitForBoard(from.id)
            moveLoadedStacks(
                (eventStacks[from.id] ?? []).filter { stackIDs.contains($0.id) },
                from: from,
                to: to
            )
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

    /// `EventPresenceScanner`'s answer without the sweep: while an event is
    /// still "Checking", each file's catalog assignment plus the Card Copy
    /// path the grid implied is enough to plan a move. A location reads
    /// `.present` only where the file's own path matches — exactly the place
    /// the file was drawn at — and `.missing` elsewhere, so a plan never
    /// points a rename at a location the sweep never verified. When the file
    /// is not actually there anymore, the rename's own preflight skips it
    /// and the completion reports why.
    private func catalogAssets(for stacks: [OrganizeStack], in event: SavedCameraEvent) -> [MoveCandidate] {
        let locations = self.locations
        let policy = locations.resolvedPolicy(for: event)
        let otherPolicy: EventStoragePolicy = policy == .buffer ? .archiveOnly : .buffer
        var byPath: [String: PhotoEventAssignment] = [:]
        for assignment in model.configuration.photoEventAssignments where assignment.eventID == event.id {
            for url in [
                locations.sourceURL(for: assignment),
                locations.driveURL(for: assignment, event: event, policy: policy),
                locations.driveURL(for: assignment, event: event, policy: otherPolicy),
                locations.archiveURL(for: assignment, event: event)
            ] {
                if let path = url?.path { byPath[path] = assignment }
            }
        }
        return stacks.flatMap(\.files).compactMap { file in
            guard let assignment = byPath[file.path] else { return nil }
            let source = locations.sourceURL(for: assignment)?.path
            let drive = locations.driveURL(for: assignment, event: event, policy: policy)?.path
            let other = locations.driveURL(for: assignment, event: event, policy: otherPolicy)?.path
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
    }

    private func moveLoadedStacks(_ targetStacks: [OrganizeStack], from: SavedCameraEvent, to: SavedCameraEvent) {
        let sourceEventID = from.id
        let targetEventID = to.id
        var assets = targetStacks.flatMap { self.assets(for: $0, in: sourceEventID).map(MoveCandidate.init) }
        if assets.isEmpty {
            assets = catalogAssets(for: targetStacks, in: from)
        }
        guard !assets.isEmpty else {
            model.statusMessage = targetStacks.isEmpty
                ? "Nothing to move — that selection no longer matches \(eventTitle(from))'s board. Click the stacks again."
                : "Nothing to move — none of those files are in \(eventTitle(from))'s catalog yet."
            return
        }
        let locations = self.locations
        let targetPolicy = locations.resolvedPolicy(for: to)
        var targetNames = Set(model.configuration.photoEventAssignments
            .filter { $0.eventID == targetEventID }
            .map { $0.relativePath.lowercased() })

        var plans: [PlannedReassignment] = []
        var collisions = 0
        var alreadyThere = 0
        for asset in assets {
            // A family board's stacks can already belong to the target —
            // a subevent section on the parent's board dropped back onto
            // that subevent moves nothing.
            guard asset.assignment.eventID != targetEventID else {
                alreadyThere += 1
                continue
            }
            var moved = asset.assignment
            moved.eventID = targetEventID
            guard targetNames.insert(moved.relativePath.lowercased()).inserted else {
                collisions += 1
                continue
            }
            var moveSource: String?
            if asset.sourceIsDriveCopy {
                if let path = [asset.drive == .present ? asset.drivePath : nil, asset.otherDrive == .present ? asset.otherDrivePath : nil]
                    .compactMap({ $0 }).first {
                    moved.sourceRootPath = locations.cardCopyRoot(for: to, deviceID: moved.deviceID, policy: targetPolicy).path
                    moveSource = path
                }
            } else if asset.drive == .present {
                moveSource = asset.drivePath
            } else if asset.otherDrive == .present {
                moveSource = asset.otherDrivePath
            }
            plans.append(PlannedReassignment(removed: asset.assignment, added: moved, moveSourcePath: moveSource))
        }
        guard !plans.isEmpty else {
            model.statusMessage = alreadyThere > 0 && collisions == 0
                ? "Those files already belong to \(eventTitle(to)). Nothing moved."
                : "\(eventTitle(to)) already has files with those names. Nothing moved."
            return
        }
        noteRecent(targetEventID)

        let moves = plans.compactMap { plan -> DriveMove? in
            guard let source = plan.moveSourcePath,
                  let destination = locations.driveURL(for: plan.added, event: to, policy: targetPolicy) else { return nil }
            return DriveMove(sourcePath: source, destinationPath: destination.path, byteCount: plan.added.fileSize)
        }
        let collisionNote = collisions > 0 ? " \(collisions) file(s) stayed because \(eventTitle(to)) already has that name." : ""
        guard !moves.isEmpty else {
            let change = AssignmentChange(title: "Move to \(eventTitle(to))", removed: plans.map(\.removed), added: plans.map(\.added))
            // The stacks are already on the source board with real paths
            // and dates — the target board gains them in place.
            applyAssignmentChange(
                change,
                touching: targetEventID,
                addedItems: targetStacks.flatMap(\.items)
            )
            pushUndo(change)
            model.statusMessage = "Moved \(plans.count) file(s) from \(eventTitle(from)) to \(eventTitle(to)).\(collisionNote)"
            return
        }

        let journalFolder = self.journalFolder
        let boundaries = [locations.bufferRoot, locations.privateStagingRoot]
        let title = "Move to \(eventTitle(to))"
        let removed = plans.map(\.removed)
        let added = plans.map(\.added)
        model.runBackgroundJob(
            action: .organize,
            runningNote: "Moving \(moves.count) file(s) from \(eventTitle(from)) to \(eventTitle(to))",
            logTitle: title,
            logDetail: "Renamed originals between event folders on the same drive. NAS copies were not changed.",
            operation: { progress in
                try DriveMoveService().apply(
                    moves,
                    title: title,
                    journalFolder: journalFolder,
                    removedAssignments: removed,
                    addedAssignments: added,
                    pruneBoundaries: boundaries
                ) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Moving", command: ""))
                }
            },
            completion: { [weak self] report in
                guard let self else { return "" }
                let failedSources = Set(report.skipped.map { EventStorageLocations.pathKey($0.move.sourcePath) })
                let applied = plans.filter { plan in
                    guard let source = plan.moveSourcePath else { return true }
                    return !failedSources.contains(EventStorageLocations.pathKey(source))
                }
                applyAssignmentChange(
                    AssignmentChange(title: title, removed: applied.map(\.removed), added: applied.map(\.added)),
                    touching: targetEventID
                )
                removeFilesFromEventBoards(
                    Set(report.moved.map { EventStorageLocations.pathKey($0.sourcePath) }),
                    events: [sourceEventID]
                )
                retargetMovedPaths(report.moved)
                refreshLatestJournal()
                refreshBoth(sourceEventID, targetEventID)
                let skippedNote = report.skipped.isEmpty ? "" : " \(report.skipped.count) could not move: \(report.skipped[0].reason)"
                return "Moved \(applied.count) file(s) to \(eventTitle(to)).\(skippedNote)\(collisionNote)"
            }
        )
    }

    /// Same rule as `moveStacks`: every click ends in a readable result —
    /// a queued or running job, an already-organized note, or a reason the
    /// files stayed — never a bare return while the board is loading.
    func returnToUnsorted(_ stackIDs: Set<String>, eventID: UUID) {
        guard let event = event(eventID) else {
            model.statusMessage = "That event no longer exists — nothing was returned."
            return
        }
        guard let stacks = eventStacks[eventID] else {
            queueReturnToUnsorted(stackIDs, in: event)
            return
        }
        returnLoadedStacks(stacks.filter { stackIDs.contains($0.id) }, from: event)
    }

    /// The Return to Unsorted counterpart of `queueMove`: the click waits
    /// for the board to paint, then runs the same return.
    private func queueReturnToUnsorted(_ stackIDs: Set<String>, in event: SavedCameraEvent) {
        model.statusMessage = "Return to Unsorted queued — \(eventTitle(event)) is still loading. It runs as soon as the board appears."
        Task { @MainActor [weak self] in
            guard let self else { return }
            await waitForBoard(event.id)
            returnLoadedStacks(
                (eventStacks[event.id] ?? []).filter { stackIDs.contains($0.id) },
                from: event
            )
        }
    }

    private func returnLoadedStacks(_ targetStacks: [OrganizeStack], from event: SavedCameraEvent) {
        let eventID = event.id
        var assets = targetStacks.flatMap { self.assets(for: $0, in: eventID).map(MoveCandidate.init) }
        if assets.isEmpty {
            assets = catalogAssets(for: targetStacks, in: event)
        }
        guard !assets.isEmpty else {
            model.statusMessage = targetStacks.isEmpty
                ? "Nothing to return — that selection no longer matches \(eventTitle(event))'s board. Click the stacks again."
                : "Nothing to return — none of those files are in \(eventTitle(event))'s catalog yet."
            return
        }
        let mounted = VolumeInfo.mountedVolumePaths()
        var removed: [PhotoEventAssignment] = []
        var moves: [DriveMove] = []
        var adopted = 0
        var blocked = 0
        for asset in assets {
            if asset.sourceIsDriveCopy {
                adopted += 1
                continue
            }
            let driveCopy = asset.drive == .present ? asset.drivePath : (asset.otherDrive == .present ? asset.otherDrivePath : nil)
            if let driveCopy {
                guard asset.source == .missing, let source = asset.sourcePath,
                      VolumeInfo.isSameVolume(URL(fileURLWithPath: driveCopy), URL(fileURLWithPath: source).deletingLastPathComponent(), mountedVolumes: mounted) else {
                    blocked += 1
                    continue
                }
                moves.append(DriveMove(sourcePath: driveCopy, destinationPath: source, byteCount: asset.assignment.fileSize))
            }
            removed.append(asset.assignment)
        }
        let notes = [
            adopted > 0 ? "\(adopted) file(s) were already organized on the drive and have no unsorted folder to return to." : nil,
            blocked > 0 ? "\(blocked) file(s) still exist on their card or another drive; take the drive copy off first." : nil,
        ].compactMap { $0 }.joined(separator: " ")
        guard !removed.isEmpty else {
            model.statusMessage = notes.isEmpty ? "Nothing to return." : notes
            return
        }
        guard !moves.isEmpty else {
            let change = AssignmentChange(title: "Return to Unsorted", removed: removed, added: [])
            // The open board drops the stacks in place — a refresh would
            // only re-derive what the patch already applied.
            applyAssignmentChange(change, touching: nil)
            pushUndo(change)
            model.statusMessage = "Returned \(removed.count) file(s) from \(eventTitle(event)) to Unsorted. \(notes)"
            return
        }
        let journalFolder = self.journalFolder
        let locations = self.locations
        let boundaries = [locations.bufferRoot, locations.privateStagingRoot]
        let title = "Return to Unsorted from \(eventTitle(event))"
        let plannedMoves = moves
        let plannedRemoved = removed
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
                removeFilesFromEventBoards(
                    Set(report.moved.map { EventStorageLocations.pathKey($0.sourcePath) }),
                    events: [eventID]
                )
                retargetMovedPaths(report.moved)
                refreshLatestJournal()
                for location in unsortedLocations where sources[location.id]?.result != nil {
                    scan(location, force: true)
                }
                Task { await self.refreshEvent(eventID) }
                return "Returned \(applied.count) file(s) to Unsorted. \(notes)"
            }
        )
    }

    private func refreshBoth(_ first: UUID, _ second: UUID) {
        Task {
            await refreshEvent(first)
            await refreshEvent(second)
        }
    }

    // MARK: - NAS, drive, and source

    func archiveToNAS(_ eventID: UUID) {
        guard let event = event(eventID), let summary = presence[eventID] else {
            Task { await refreshEvent(eventID) }
            return
        }
        let locations = self.locations
        guard VolumeInfo.isAvailable(locations.libraryRoot), FileManager.default.fileExists(atPath: locations.libraryRoot.path) else {
            model.statusMessage = "The NAS library is not connected: \(locations.libraryRoot.path)"
            return
        }
        var groups: [String: NASArchiveGroup] = [:]
        // The root only varies with (owner, device, policy) — cardCopyRoot
        // is already standardized and a source root standardizes once —
        // so group keys reuse memoized paths instead of a realpath walk
        // per asset.
        var cardRoots: [String: URL] = [:]
        var sourceRoots: [String: URL] = [:]
        var standardizedKeys: [String: String] = [:]
        func cardCopyRoot(_ owner: SavedCameraEvent, _ deviceID: String?, _ policy: EventStoragePolicy) -> URL {
            let cacheKey = "\(owner.id)\u{0}\(deviceID ?? "")\u{0}\(policy.rawValue)"
            if let cached = cardRoots[cacheKey] { return cached }
            let built = locations.cardCopyRoot(for: owner, deviceID: deviceID, policy: policy)
            cardRoots[cacheKey] = built
            return built
        }
        func standardizedKey(for root: URL) -> String {
            if let cached = standardizedKeys[root.path] { return cached }
            let built = root.standardizedFileURL.path
            standardizedKeys[root.path] = built
            return built
        }
        for asset in summary.assets where asset.archive != .present {
            // Family scope: the asset's own event resolves the folders —
            // a subevent's copies live in its nested Card Copy, and its
            // archive layout nests under the parent's folders.
            let owner = self.event(asset.assignment.eventID) ?? event
            let ownerPolicy = locations.resolvedPolicy(for: owner)
            let root: URL
            if asset.drive == .present {
                root = cardCopyRoot(owner, asset.assignment.deviceID, ownerPolicy)
            } else if asset.otherDrive == .present {
                root = cardCopyRoot(owner, asset.assignment.deviceID, ownerPolicy == .buffer ? .archiveOnly : .buffer)
            } else if asset.source == .present {
                root = sourceRoots[asset.assignment.sourceRootPath] ?? {
                    let built = URL(fileURLWithPath: DashboardModel.expandedPath(asset.assignment.sourceRootPath), isDirectory: true)
                    sourceRoots[asset.assignment.sourceRootPath] = built
                    return built
                }()
            } else {
                continue
            }
            let key = standardizedKey(for: root) + "\u{0}" + (asset.assignment.deviceID ?? "")
            groups[key, default: NASArchiveGroup(owner: owner, root: root, deviceID: asset.assignment.deviceID, files: [])].files.append(
                FileRecord(path: asset.assignment.relativePath, size: asset.assignment.fileSize, modifiedAt: asset.assignment.modifiedAt)
            )
        }
        guard !groups.isEmpty else {
            model.statusMessage = summary.onArchive == summary.total
                ? "\(eventTitle(event)) is already on the NAS."
                : "No reachable copy of the remaining files. Connect the drive or card that has them."
            return
        }
        let archiveGroups = groups.values.sorted { $0.root.path < $1.root.path }
        let libraryRoot = locations.libraryRoot
        let fileCount = archiveGroups.reduce(0) { $0 + $1.files.count }
        model.runBackgroundJob(
            action: .syncBuffer,
            runningNote: "Archiving \(fileCount) file(s) from \(eventTitle(event)) to the NAS",
            logTitle: "Archived \(eventTitle(event)) to the NAS",
            logDetail: "Copied originals into Library Originals and checked every copy with SHA-256. Different existing files were never overwritten.",
            operation: { progress in
                var outcome = NASArchiveOutcome()
                for (index, group) in archiveGroups.enumerated() {
                    let span = 1.0 / Double(archiveGroups.count)
                    let base = Double(index) * span
                    let layout = locations.layout(for: group.owner, deviceID: group.deviceID)
                    let plan = try OrganizedArchivePlanner().plan(
                        source: group.root,
                        sourceFiles: group.files,
                        libraryRoot: libraryRoot,
                        layout: layout
                    ) { update in
                        progress(DashboardModel.jobUpdate(from: update, lowerBound: base, upperBound: base + span * 0.3, notePrefix: "Checking NAS", command: ""))
                    }
                    let result = try OrganizedArchiveService().archive(source: group.root, libraryRoot: libraryRoot, plan: plan) { update in
                        progress(DashboardModel.jobUpdate(from: update, lowerBound: base + span * 0.3, upperBound: base + span, notePrefix: "Archiving to NAS", command: ""))
                    }
                    outcome.copied += result.copied.count
                    outcome.alreadySafe += result.skippedIdentical.count
                    outcome.conflicts += result.conflicts.count
                }
                return outcome
            },
            completion: { [weak self] outcome in
                Task { await self?.refreshEvent(eventID) }
                return "NAS archive verified for \(self?.eventTitle(event) ?? event.name): \(outcome.copied) copied, \(outcome.alreadySafe) already safe, \(outcome.conflicts) conflict(s) left untouched."
            }
        )
    }

    func requestRemoveFromDrive(_ eventID: UUID) {
        guard let summary = presence[eventID] else { return }
        let eligible = summary.assets.filter { ($0.drive == .present || $0.otherDrive == .present) && $0.archive == .present }
        guard !eligible.isEmpty else {
            model.statusMessage = "Archive to the NAS first. Only files with a NAS copy can leave the drive."
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
        case .drive: removeFromDrive(request.eventID, confirmation: confirmation)
        case .source: removeFromSource(request.eventID, confirmation: confirmation)
        }
    }

    private func removeFromDrive(_ eventID: UUID, confirmation: String) {
        guard let event = event(eventID), let summary = presence[eventID] else { return }
        let locations = self.locations
        var pairs: [VerifiedRemovalPair] = []
        for asset in summary.assets where asset.archive == .present {
            guard let archive = asset.archivePath else { continue }
            // Family scope: each asset's folders resolve through its own
            // event — a subevent's copies sit in its nested event folder.
            let owner = self.event(asset.assignment.eventID) ?? event
            let policy = locations.resolvedPolicy(for: owner)
            let eventFolderPath = locations.layout(for: owner, deviceID: nil).eventFolderPath
            let deviceFolder = locations.layout(for: owner, deviceID: asset.assignment.deviceID).deviceFolder
            let copies: [(CatalogPresenceState, String?, EventStoragePolicy)] = [
                (asset.drive, asset.drivePath, policy),
                (asset.otherDrive, asset.otherDrivePath, policy == .buffer ? .archiveOnly : .buffer),
            ]
            for (state, path, copyPolicy) in copies where state == .present {
                guard let path else { continue }
                pairs.append(VerifiedRemovalPair(
                    driveCopyPath: path,
                    referencePath: archive,
                    batchRelativePath: "\(copyPolicy == .buffer ? "Buffer" : "Private")/\(eventFolderPath)/\(deviceFolder)/\(asset.assignment.relativePath)",
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
            // sits in the asset's own event's nested Card Copy folder.
            let owner = self.event(asset.assignment.eventID) ?? event
            let driveRoot = locations.cardCopyRoot(for: owner, deviceID: asset.assignment.deviceID, policy: locations.resolvedPolicy(for: owner))
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
        // lived, then drop the assignments — a trashed file no longer belongs
        // to an event. This uses the same removal machinery as Unsort so the
        // indexes stay consistent. It is not pushed onto the sort undo stack:
        // undoing would restore assignments for files that are in the Trash.
        var eventIDs: [String: UUID] = [:]
        var removedAssignments: [PhotoEventAssignment] = []
        for file in files {
            let key = file.pathKey
            if let assignment = assignmentsByPathKey[key] {
                eventIDs[key] = assignment.eventID
                if !preservingAssignmentKeys.contains(key) {
                    removedAssignments.append(assignment)
                }
            }
        }
        if !removedAssignments.isEmpty {
            applyAssignmentChange(AssignmentChange(title: "Move to Trash", removed: removedAssignments, added: []), touching: nil)
        }
        // Don't leave the event board showing a tile whose file is in _Trash.
        // Unsorted used to update only its own scan result; eventStacks stayed
        // stale until the user hit Refresh.
        removeFilesFromEventBoards(Set(files.map(\.pathKey)), events: [])

        let trashedStackIDs = affectedStackIDs(for: items, in: locationID)
        let context = TrashContext(
            locationName: location.name,
            deviceID: deviceID(for: location),
            eventIDsByPathKey: eventIDs,
            eventNamesByID: trashEventNames(for: eventIDs),
            personNamesByPathKey: trashPersonNames(for: files),
            captureDatesByPathKey: trashCaptureDates(for: items)
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
                if let result = sources[locationID]?.result {
                    sources[locationID]?.result = result.removingFiles(withPathKeys: movedKeys)
                }
                selectedStackIDs.subtract(trashedStackIDs)
                if let focusedStackID, trashedStackIDs.contains(focusedStackID) {
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
        var removedAssignments: [PhotoEventAssignment] = []
        for file in files {
            let key = file.pathKey
            if let assignment = assignmentsByPathKey[key] {
                eventIDs[key] = assignment.eventID
                removedAssignments.append(assignment)
            }
        }
        if !removedAssignments.isEmpty {
            applyAssignmentChange(AssignmentChange(title: "Move to Trash", removed: removedAssignments, added: []), touching: nil)
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
            captureDatesByPathKey: trashCaptureDates(for: items)
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
                selectedStackIDs.subtract(trashedStackIDs)
                if let focusedStackID, trashedStackIDs.contains(focusedStackID) {
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
    private func removeFilesFromEventBoards(_ pathKeys: Set<String>, events: Set<UUID>) {
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
        model.updateConfiguration { $0.burstSplits.append(BurstSplit(memberPathKeys: keys)) }
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
        model.updateConfiguration { configuration in
            for stack in stacks {
                configuration.displayOrientations = DisplayRotation.rotatedMap(
                    configuration.displayOrientations,
                    applying: delta,
                    to: stack
                )
            }
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
    private(set) var facesRevision = 0 {
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
    var faceEngineInstalled: Bool {
        FaceSidecarInstallation(applicationSupport: DashboardModel.defaultApplicationSupportURL).isInstalled
    }

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
        guard isConnected(location) else {
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
        if person != nil {
            facesRevision &+= 1
            model.statusMessage = "Added \(trimmed) to the people list."
        }
        return person
    }

    /// Assigns an existing detection to a person and confirms it — the
    /// owner's call, so the face becomes frozen and its embedding is pinned
    /// as a match reference when one exists. Confirmed faces are untouched.
    func tagFace(_ faceID: UUID, as personID: UUID) {
        try? faceStore.assignFace(faceID, to: personID, state: .confirmed, score: nil)
        try? faceStore.addTemplate(personID: personID, faceID: faceID)
        try? faceStore.refreshFaceCounts()
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
        try? faceStore.renamePerson(personID, name: trimmed)
        facesRevision &+= 1
        model.statusMessage = "Renamed to \(trimmed)."
    }

    /// Merges one person into another — faces and templates move, the empty
    /// row is removed. Confirmed faces keep their frozen state.
    func mergePerson(_ sourceID: UUID, into targetID: UUID) {
        guard sourceID != targetID,
              let source = try? faceStore.person(sourceID),
              let target = try? faceStore.person(targetID) else { return }
        try? faceStore.mergePerson(sourceID, into: targetID)
        try? faceStore.refreshFaceCounts()
        facesRevision &+= 1
        model.statusMessage = "Merged \(source.name) into \(target.name)."
    }

    /// Takes a person off the approved list; the faces become an Inbox
    /// group again rather than disappearing. Confirmed faces keep their
    /// frozen state.
    func demotePerson(_ personID: UUID) {
        try? faceStore.demoteFromRoster(personID)
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
        try? faceStore.promoteGroup(personID, name: trimmed, templateCap: FaceScanOptions().templateCap)
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
            try faceStore.deletePersonAndFaces(personID)
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
            try faceStore.deleteFaces([faceID])
            try faceStore.refreshFaceCounts()
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
            try FaceIndexService(catalogURL: catalogDatabaseURL).reject([faceID])
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
        try? faceStore.addTemplate(personID: personID, faceID: faceID)
        facesRevision &+= 1
        model.statusMessage = "Pinned as a match reference for future scans."
    }

    /// Sets the person's cover — the thumbnail the People list shows. The
    /// choice lives on the person row in the catalog; a face that leaves
    /// the person stops being the cover automatically. Catalog only —
    /// no photo is written to.
    func setCoverFace(_ faceID: UUID, for personID: UUID) {
        guard (try? faceStore.setCoverFace(personID: personID, faceID: faceID)) == true else { return }
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

private extension Array where Element == OrganizeStack {
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
        return map { stack in
            var stack = stack
            if let id = idByFiles[Set(stack.files.map(\.pathKey))] {
                stack.id = id
            }
            return stack
        }
    }
}
