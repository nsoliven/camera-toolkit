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
    var result: OrganizeScanResult?
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
}

struct RenameEventRequest: Identifiable {
    var id: UUID { eventID }
    var eventID: UUID
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

        var copyFileCount: Int { copies.reduce(0) { $0 + $1.files.count } }
    }

    let id = UUID()
    var title: String
    var groups: [EventGroup]
    var pruneBoundaries: [URL]

    var moveCount: Int { groups.reduce(0) { $0 + $1.moves.count } }
    var copyCount: Int { groups.reduce(0) { $0 + $1.copyFileCount } }
    var byteCount: Int64 { groups.reduce(Int64(0)) { $0 + $1.byteCount } }
    var isEmpty: Bool { moveCount == 0 && copyCount == 0 }
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

private struct EventRefreshOutput: Sendable {
    var summary: EventPresenceSummary
    var stacks: [OrganizeStack]
    var assetsByPathKey: [String: EventAssetPresence]
    var immich: [String: ImmichCatalogStatus]
}

private struct PlannedReassignment: Sendable {
    var removed: PhotoEventAssignment
    var added: PhotoEventAssignment
    var moveSourcePath: String?
}

private struct NASArchiveGroup: Sendable {
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
    var sources: [UUID: UnsortedSourceState] = [:]
    var selectedStackIDs: Set<String> = []
    var focusedStackID: String?
    var presence: [UUID: EventPresenceSummary] = [:]
    var eventStacks: [UUID: [OrganizeStack]] = [:]
    var eventImmichStatuses: [UUID: [String: ImmichCatalogStatus]] = [:]
    var discoveredDriveEvents: [DiscoveredDriveEvent] = []
    var newEventRequest: NewEventRequest?
    var renameRequest: RenameEventRequest?
    var pendingApplyPlan: OrganizeApplyPlan?
    var pendingRemoval: RemovalRequest?
    var latestMoveJournalTitle: String?
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
    @ObservationIgnored private var loadedCaptureDateCache: CaptureDateCache?
    @ObservationIgnored private var lastConnectivityRefresh = Date.distantPast
    @ObservationIgnored private let mountObservers = MountObserverBox()

    /// Holds move journals and the capture-time cache.
    let supportFolder: URL

    init(model: DashboardModel, supportFolder: URL = EventsWorkspace.defaultSupportFolder) {
        self.model = model
        self.supportFolder = supportFolder
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in mountObservers.observers {
            center.removeObserver(observer)
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
        EventStorageLocations(configuration: model.configuration)
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

    /// "Parent / Child" title for menus, headers, and plan rows.
    func eventTitle(_ event: SavedCameraEvent) -> String {
        locations.displayName(for: event)
    }

    /// The event's effective storage policy, following parent inheritance.
    func resolvedPolicy(for event: SavedCameraEvent) -> EventStoragePolicy {
        locations.resolvedPolicy(for: event)
    }

    /// Events that may parent `eventID` — every event except it and its own
    /// subevents, so the picker can never create a loop. Returned in
    /// flattened sidebar order for the parent picker's indented menu.
    func parentCandidates(excluding eventID: UUID?) -> [(event: SavedCameraEvent, depth: Int)] {
        sidebarEvents.filter { row in
            guard let eventID else { return true }
            return row.event.id != eventID
                && !EventHierarchy.ancestors(of: row.event, in: model.configuration.savedEvents).contains { $0.id == eventID }
        }
    }

    /// `candidate` when it can parent `eventID` — it exists, is not the
    /// event itself, and is not one of its subevents. Otherwise nil.
    func validParentEventID(_ candidate: UUID?, for eventID: UUID?) -> UUID? {
        guard let candidate,
              candidate != eventID,
              let parent = event(candidate) else { return nil }
        if let eventID,
           EventHierarchy.ancestors(of: parent, in: model.configuration.savedEvents).contains(where: { $0.id == eventID }) {
            return nil
        }
        return candidate
    }

    /// Up to nine recently created events in date order. The order stays put
    /// while sorting, so each number key keeps meaning the same event.
    var quickEvents: [SavedCameraEvent] {
        Array(model.configuration.savedEvents.sorted { $0.createdAt > $1.createdAt }.prefix(9))
            .sorted { $0.eventDate == $1.eventDate ? $0.name < $1.name : $0.eventDate < $1.eventDate }
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
        return VolumeInfo.isAvailable(url) && FileManager.default.fileExists(atPath: url.path)
    }

    static func sourceKey(_ assignment: PhotoEventAssignment) -> String {
        EventStorageLocations.pathKey(
            (DashboardModel.expandedPath(assignment.sourceRootPath) as NSString).appendingPathComponent(assignment.relativePath)
        )
    }

    private func refreshIndexIfNeeded() {
        let assignments = model.configuration.photoEventAssignments
        guard indexRevision != model.configurationRevision || indexCount != assignments.count else { return }
        var index: [String: PhotoEventAssignment] = [:]
        index.reserveCapacity(assignments.count)
        var counts: [UUID: Int] = [:]
        var bytes: [UUID: Int64] = [:]
        for assignment in assignments {
            index[Self.sourceKey(assignment)] = assignment
            counts[assignment.eventID, default: 0] += 1
            bytes[assignment.eventID, default: 0] += assignment.fileSize
        }
        assignmentsByPathKey = index
        assignmentCounts = counts
        assignmentBytes = bytes
        indexRevision = model.configurationRevision
        indexCount = assignments.count
    }

    func assignment(for file: OrganizeFile) -> PhotoEventAssignment? {
        refreshIndexIfNeeded()
        guard let assignment = assignmentsByPathKey[EventStorageLocations.pathKey(file.path)],
              assignment.fileSize == file.size else { return nil }
        return assignment
    }

    func assignmentCount(for eventID: UUID) -> Int {
        refreshIndexIfNeeded()
        return assignmentCounts[eventID] ?? 0
    }

    func assignmentBytes(for eventID: UUID) -> Int64 {
        refreshIndexIfNeeded()
        return assignmentBytes[eventID] ?? 0
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

    func visibleDays(_ result: OrganizeScanResult, hideSorted: Bool) -> [OrganizeDay] {
        guard hideSorted else { return result.days }
        return result.days.compactMap { day in
            let stacks = day.stacks.filter { !isSorted($0) }
            return stacks.isEmpty ? nil : OrganizeDay(id: day.id, date: day.date, stacks: stacks)
        }
    }

    func sortedFiles(in result: OrganizeScanResult) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        for item in result.items {
            for file in item.files where assignment(for: file) != nil {
                files += 1
                bytes += file.size
            }
        }
        return (files, bytes)
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
        return stack.files.compactMap { index[EventStorageLocations.pathKey($0.path)] }
    }

    func badge(for stack: OrganizeStack, in eventID: UUID) -> TileLocationBadge? {
        guard let event = event(eventID),
              let asset = eventAssetsByPathKey[eventID]?[EventStorageLocations.pathKey(stack.coverItem.primary.path)] else {
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
    }

    func startGuide() {
        AppShellMode.show(.events)
        if guide == nil {
            guide = SetupGuide(workspace: self)
        }
        guide?.isCollapsed = false
    }

    func selectionChanged() {
        selectedStackIDs = []
        focusedStackID = nil
        selectionAnchorID = nil
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
        let reportProgress: @Sendable (OrganizeScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.sources[id]?.progress = progress
            }
        }

        Task { @MainActor [weak self] in
            let outcome: Result<OrganizeScanResult, any Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try OrganizeScanner().scan(root: root, cache: cache, burstGrouping: BurstGroupingConfiguration.resolved(), progress: reportProgress)
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
    /// once they are reachable. When `mountedVolume` is set (that volume just
    /// mounted), sources on it are scanned even if they were never tried.
    ///
    /// Refresh never mounts anything itself: the configuration stores local
    /// paths and service URLs, not network share URLs, so there is no share
    /// URL to hand to the mounter.
    func refreshConnectivity(mountedVolume: URL? = nil) {
        connectivityRevision &+= 1
        lastConnectivityRefresh = Date()

        discoverDriveEvents()
        for eventID in Set(presence.keys).union(eventStacks.keys) {
            Task { await refreshEvent(eventID) }
        }

        let mountedRoot = mountedVolume?.standardizedFileURL
        for location in unsortedLocations {
            let state = sources[location.id]
            // Healthy cached results are never rescanned here.
            guard state?.isScanning != true, state?.result == nil else { continue }
            guard isConnected(location) else { continue }
            if let mountedRoot {
                let locationURL = URL(fileURLWithPath: DashboardModel.expandedPath(location.path), isDirectory: true)
                guard VolumeInfo.volumeRoot(for: locationURL) == mountedRoot else { continue }
            } else if state == nil {
                // A global refresh only retries sources that failed before.
                // Fresh sources scan when selected or when their volume mounts.
                continue
            }
            scan(location)
        }
    }

    /// For app activation: connectivity re-checks at most every `maxAge`
    /// seconds so returning to the app updates offline badges without redoing
    /// presence work on every activate.
    func refreshConnectivityIfStale(maxAge: TimeInterval = 15) {
        guard Date().timeIntervalSince(lastConnectivityRefresh) >= maxAge else { return }
        refreshConnectivity()
    }

    /// Registers once for volume mount/unmount notifications so offline rows,
    /// presence summaries, and failed scans update themselves when a drive or
    /// card appears or disappears. Safe to call repeatedly.
    func observeVolumeChanges() {
        guard mountObservers.observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        mountObservers.observers = [
            center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { [weak self] notification in
                let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                Task { @MainActor [weak self] in
                    self?.refreshConnectivity(mountedVolume: url)
                }
            },
            center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshConnectivity()
                }
            },
        ]
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
        let keys = Set(files.map { EventStorageLocations.pathKey($0.path) })
        let previous = keys.compactMap { assignmentsByPathKey[$0] }
        let blockedKeys = Set(previous.filter { prior in
            prior.eventID != eventID && hasDriveCopy(prior, locations: locations)
        }.map(Self.sourceKey))
        let eligible = files.filter { !blockedKeys.contains(EventStorageLocations.pathKey($0.path)) }
        guard !eligible.isEmpty else {
            model.statusMessage = "Those files already have a copy in another event's folder. Open that event to move them."
            return
        }
        let eligibleKeys = Set(eligible.map { EventStorageLocations.pathKey($0.path) })
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
        applyAssignmentChange(change, touching: eventID)
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
        let previous = Set(files.map { EventStorageLocations.pathKey($0.path) }).compactMap { assignmentsByPathKey[$0] }
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

    private func applyAssignmentChange(_ change: AssignmentChange, touching eventID: UUID?) {
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
    }

    // MARK: - Events

    func requestNewEvent(from locationID: UUID?, parentEventID: UUID? = nil) {
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

    @discardableResult
    func createEvent(name rawName: String, date: Date, policy: EventStoragePolicy?, parentEventID: UUID? = nil) -> UUID? {
        let validation = EventNamePolicy.validate(rawName)
        guard validation.isValid else {
            model.statusMessage = validation.errorMessage ?? "Choose a different event name."
            return nil
        }
        let day = Calendar.current.startOfDay(for: date)
        let parentID = validParentEventID(parentEventID, for: nil)
        // The dated folder name is unique per parent: the same name and date
        // under a different parent is a different folder, not a duplicate.
        if let existing = model.configuration.savedEvents.first(where: {
            $0.name.localizedCaseInsensitiveCompare(validation.normalizedName) == .orderedSame
                && Calendar.current.isDate($0.eventDate, inSameDayAs: day)
                && $0.parentEventID == parentID
        }) {
            return existing.id
        }
        let event = SavedCameraEvent(
            name: validation.normalizedName,
            eventDate: day,
            storagePolicy: policy,
            parentEventID: parentID
        )
        model.updateConfiguration { $0.savedEvents.append(event) }
        model.statusMessage = "Created \(eventTitle(event)). Sort photos into it, then press Apply."
        return event.id
    }

    func completeNewEvent(_ request: NewEventRequest, name: String, date: Date, policy: EventStoragePolicy?, parentEventID: UUID?) {
        guard let eventID = createEvent(name: name, date: date, policy: policy, parentEventID: parentEventID) else { return }
        newEventRequest = nil
        if let locationID = request.sourceLocationID, !request.stackIDs.isEmpty {
            assign(stackIDs: request.stackIDs, from: locationID, to: eventID)
        } else if request.sourceLocationID == nil {
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
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [DiscoveredDriveEvent] in
                var all: [DiscoveredDriveEvent] = []
                if VolumeInfo.isAvailable(locations.bufferRoot) {
                    all += (try? DriveEventDiscovery.discover(driveRoot: locations.bufferRoot, policy: .buffer, configuration: configuration)) ?? []
                }
                if VolumeInfo.isAvailable(locations.privateStagingRoot) {
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

    func refreshEvent(_ eventID: UUID) async {
        guard let event = event(eventID) else { return }
        let generation = UUID()
        refreshGenerations[eventID] = generation
        let assignments = model.configuration.photoEventAssignments.filter { $0.eventID == eventID }
        let locations = self.locations
        let cache = captureDateCache
        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))

        let output = await Task.detached(priority: .userInitiated) { () -> EventRefreshOutput in
            let summary = EventPresenceScanner.scan(event: event, assignments: assignments, locations: locations)
            var files: [OrganizeFile] = []
            var byPath: [String: EventAssetPresence] = [:]
            for asset in summary.assets {
                guard let path = asset.bestLocalPath else { continue }
                files.append(OrganizeFile(path: path, size: asset.assignment.fileSize, modifiedAt: asset.assignment.modifiedAt))
                byPath[EventStorageLocations.pathKey(path)] = asset
            }
            let items = OrganizeScanner.items(for: files, cache: cache).items
            let immich = (try? CatalogInspector(url: catalogURL).immichStatuses(eventID: eventID)) ?? [:]
            return EventRefreshOutput(
                summary: summary,
                stacks: OrganizeStacker.stacks(for: items),
                assetsByPathKey: byPath,
                immich: immich
            )
        }.value

        guard refreshGenerations[eventID] == generation else { return }
        eventAssetsByPathKey[eventID] = output.assetsByPathKey
        presence[eventID] = output.summary
        eventStacks[eventID] = output.stacks
        eventImmichStatuses[eventID] = output.immich
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
        model.statusMessage = "Checking where every sorted file is…"
        Task { @MainActor [weak self] in
            let plan = await Task.detached(priority: .userInitiated) {
                Self.buildApplyPlan(
                    events: events,
                    configuration: configuration,
                    locations: locations,
                    onlyUnder: root,
                    title: title,
                    unsortedRoots: unsortedRoots
                )
            }.value
            guard let self else { return }
            if plan.isEmpty {
                let unavailable = plan.groups.reduce(0) { $0 + $1.unavailable }
                model.statusMessage = unavailable > 0
                    ? "\(unavailable) file(s) are on a disconnected drive. Connect it and try again."
                    : "Nothing to move. Every sorted file is already where its event keeps it."
                return
            }
            model.statusMessage = "Review the plan, then press Apply."
            pendingApplyPlan = plan
        }
    }

    nonisolated static func buildApplyPlan(
        events: [SavedCameraEvent],
        configuration: AppConfiguration,
        locations: EventStorageLocations,
        onlyUnder root: String?,
        title: String,
        unsortedRoots: [URL]
    ) -> OrganizeApplyPlan {
        let mounted = VolumeInfo.mountedVolumePaths()
        let rootPrefix = root.map { EventStorageLocations.pathKey($0) + "/" }
        var sameVolumeCache: [String: Bool] = [:]
        var groups: [OrganizeApplyPlan.EventGroup] = []

        for event in events {
            let policy = locations.resolvedPolicy(for: event)
            let driveRoot = locations.driveRoot(for: policy)
            let assignments = configuration.photoEventAssignments.filter { $0.eventID == event.id }
            let summary = EventPresenceScanner.scan(event: event, assignments: assignments, locations: locations, mountedVolumes: mounted)
            var moves: [DriveMove] = []
            var copies: [String: OrganizeApplyPlan.CopyBatch] = [:]
            var alreadyThere = 0
            var unavailable = 0
            var bytes: Int64 = 0

            for asset in summary.assets {
                if let rootPrefix {
                    guard let source = asset.sourcePath, EventStorageLocations.pathKey(source).hasPrefix(rootPrefix) else { continue }
                }
                guard let drivePath = asset.drivePath else { continue }
                let size = asset.assignment.fileSize
                switch asset.drive {
                case .present:
                    alreadyThere += 1
                    continue
                case .unavailable:
                    unavailable += 1
                    continue
                default:
                    break
                }
                if asset.otherDrive == .present, let other = asset.otherDrivePath {
                    moves.append(DriveMove(sourcePath: other, destinationPath: drivePath, byteCount: size))
                    bytes += size
                    continue
                }
                guard asset.source == .present, !asset.sourceIsDriveCopy, let sourcePath = asset.sourcePath else {
                    if asset.source == .unavailable { unavailable += 1 }
                    continue
                }
                let folder = (sourcePath as NSString).deletingLastPathComponent
                let sameVolume: Bool
                if let cached = sameVolumeCache[folder] {
                    sameVolume = cached
                } else {
                    sameVolume = VolumeInfo.isSameVolume(URL(fileURLWithPath: folder), driveRoot, mountedVolumes: mounted)
                    sameVolumeCache[folder] = sameVolume
                }
                if sameVolume {
                    moves.append(DriveMove(sourcePath: sourcePath, destinationPath: drivePath, byteCount: size))
                } else {
                    let destinationRoot = locations.cardCopyRoot(for: event, deviceID: asset.assignment.deviceID, policy: policy).path
                    let sourceRoot = URL(fileURLWithPath: NSString(string: asset.assignment.sourceRootPath).expandingTildeInPath, isDirectory: true)
                        .standardizedFileURL.path
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
                }
                bytes += size
            }

            guard !moves.isEmpty || !copies.isEmpty || unavailable > 0 else { continue }
            groups.append(OrganizeApplyPlan.EventGroup(
                event: event,
                moves: moves,
                copies: copies.values.sorted { $0.sourceRoot < $1.sourceRoot },
                alreadyThere: alreadyThere,
                unavailable: unavailable,
                destinationFolder: locations.eventFolder(for: event, policy: policy).path,
                isPrivate: policy == .archiveOnly,
                byteCount: bytes
            ))
        }

        return OrganizeApplyPlan(
            title: title,
            groups: groups.sorted { $0.event.eventDate < $1.event.eventDate },
            pruneBoundaries: unsortedRoots + [locations.bufferRoot, locations.privateStagingRoot]
        )
    }

    func performApply(_ plan: OrganizeApplyPlan) {
        pendingApplyPlan = nil
        let moves = plan.groups.flatMap(\.moves)
        let copies = plan.groups.flatMap { group in group.copies.map { (group.event, $0) } }
        let journalFolder = self.journalFolder
        let boundaries = plan.pruneBoundaries
        let title = plan.title
        let affectedEvents = plan.groups.map(\.event.id)

        if !moves.isEmpty {
            model.runBackgroundJob(
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
                    let skippedNote = report.skipped.first.map {
                        " \(report.skipped.count) left in place: \($0.reason)"
                    } ?? ""
                    return "Moved \(report.moved.count) file(s) (\(report.movedBytes.formattedBytes)) into their events.\(skippedNote)"
                }
            )
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
        }
    }

    private func didMove(report: DriveMoveReport, events: [UUID]) {
        let movedKeys = Set(report.moved.map { EventStorageLocations.pathKey($0.sourcePath) })
        for (id, state) in sources {
            if let result = state.result {
                sources[id]?.result = result.removingFiles(withPathKeys: movedKeys)
            }
        }
        selectedStackIDs.removeAll()
        focusedStackID = nil
        refreshLatestJournal()
        for eventID in Set(events) {
            Task { await refreshEvent(eventID) }
        }
    }

    func refreshLatestJournal() {
        latestMoveJournalTitle = DriveMoveService.latestUndoableJournal(in: self.journalFolder)?.journal.title
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

    func moveStacks(_ stackIDs: Set<String>, fromEvent sourceEventID: UUID, toEvent targetEventID: UUID) {
        guard sourceEventID != targetEventID,
              let from = event(sourceEventID),
              let to = event(targetEventID),
              let stacks = eventStacks[sourceEventID] else { return }
        let assets = stacks.filter { stackIDs.contains($0.id) }.flatMap { self.assets(for: $0, in: sourceEventID) }
        guard !assets.isEmpty else { return }
        let locations = self.locations
        let targetPolicy = locations.resolvedPolicy(for: to)
        var targetNames = Set(model.configuration.photoEventAssignments
            .filter { $0.eventID == targetEventID }
            .map { $0.relativePath.lowercased() })

        var plans: [PlannedReassignment] = []
        var collisions = 0
        for asset in assets {
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
            model.statusMessage = "\(eventTitle(to)) already has files with those names. Nothing moved."
            return
        }

        let moves = plans.compactMap { plan -> DriveMove? in
            guard let source = plan.moveSourcePath,
                  let destination = locations.driveURL(for: plan.added, event: to, policy: targetPolicy) else { return nil }
            return DriveMove(sourcePath: source, destinationPath: destination.path, byteCount: plan.added.fileSize)
        }
        let collisionNote = collisions > 0 ? " \(collisions) file(s) stayed because \(eventTitle(to)) already has that name." : ""
        guard !moves.isEmpty else {
            let change = AssignmentChange(title: "Move to \(eventTitle(to))", removed: plans.map(\.removed), added: plans.map(\.added))
            applyAssignmentChange(change, touching: targetEventID)
            pushUndo(change)
            model.statusMessage = "Moved \(plans.count) file(s) from \(eventTitle(from)) to \(eventTitle(to)).\(collisionNote)"
            refreshBoth(sourceEventID, targetEventID)
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
                refreshLatestJournal()
                refreshBoth(sourceEventID, targetEventID)
                let skippedNote = report.skipped.isEmpty ? "" : " \(report.skipped.count) could not move: \(report.skipped[0].reason)"
                return "Moved \(applied.count) file(s) to \(eventTitle(to)).\(skippedNote)\(collisionNote)"
            }
        )
    }

    func returnToUnsorted(_ stackIDs: Set<String>, eventID: UUID) {
        guard let event = event(eventID), let stacks = eventStacks[eventID] else { return }
        let assets = stacks.filter { stackIDs.contains($0.id) }.flatMap { self.assets(for: $0, in: eventID) }
        guard !assets.isEmpty else { return }
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
            applyAssignmentChange(change, touching: nil)
            pushUndo(change)
            model.statusMessage = "Returned \(removed.count) file(s) from \(eventTitle(event)) to Unsorted. \(notes)"
            Task { await refreshEvent(eventID) }
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
        let policy = locations.resolvedPolicy(for: event)
        let otherPolicy: EventStoragePolicy = policy == .buffer ? .archiveOnly : .buffer
        var groups: [String: NASArchiveGroup] = [:]
        for asset in summary.assets where asset.archive != .present {
            let root: URL
            if asset.drive == .present {
                root = locations.cardCopyRoot(for: event, deviceID: asset.assignment.deviceID, policy: policy)
            } else if asset.otherDrive == .present {
                root = locations.cardCopyRoot(for: event, deviceID: asset.assignment.deviceID, policy: otherPolicy)
            } else if asset.source == .present {
                root = URL(fileURLWithPath: DashboardModel.expandedPath(asset.assignment.sourceRootPath), isDirectory: true)
            } else {
                continue
            }
            let key = root.standardizedFileURL.path + "\u{0}" + (asset.assignment.deviceID ?? "")
            groups[key, default: NASArchiveGroup(root: root, deviceID: asset.assignment.deviceID, files: [])].files.append(
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
                    let layout = locations.layout(for: event, deviceID: group.deviceID)
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
        let policy = locations.resolvedPolicy(for: event)
        let eventFolderPath = locations.layout(for: event, deviceID: nil).eventFolderPath
        var pairs: [VerifiedRemovalPair] = []
        for asset in summary.assets where asset.archive == .present {
            guard let archive = asset.archivePath else { continue }
            let deviceFolder = locations.layout(for: event, deviceID: asset.assignment.deviceID).deviceFolder
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
                return "Took \(report.moved.count) file(s) (\(report.movedBytes.formattedBytes)) of \(self?.eventTitle(event) ?? event.name) off the drive. They stay recoverable in \(report.batchPath ?? trashRoot.path) until you empty it in Settings."
            }
        )
    }

    private func removeFromSource(_ eventID: UUID, confirmation: String) {
        guard let event = event(eventID), let summary = presence[eventID] else { return }
        let locations = self.locations
        var groups: [String: SourceCleanupGroup] = [:]
        for asset in summary.assets where asset.isOnSeparateSource && asset.drive == .present {
            let sourceRoot = URL(fileURLWithPath: DashboardModel.expandedPath(asset.assignment.sourceRootPath), isDirectory: true)
            let driveRoot = locations.cardCopyRoot(for: event, deviceID: asset.assignment.deviceID, policy: locations.resolvedPolicy(for: event))
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

    // MARK: - Trash

    /// Moves every file of the given stacks — primaries and companions — into
    /// the drive-local `.Camera Toolkit/_Trash` batch on whichever volume
    /// each file lives. Recoverable from Settings → Trash.
    func trash(stackIDs: Set<String>, from locationID: UUID) {
        guard let result = sources[locationID]?.result else { return }
        let items = result.stacks.filter { stackIDs.contains($0.id) }.flatMap(\.items)
        trashItems(items, from: locationID)
    }

    /// Moves individual frames — each item's primary plus its sidecars and
    /// RAW+JPEG companions — into the drive-local `_Trash`. The burst preview
    /// calls this for single frames; a stack left with fewer items is
    /// restacked automatically when the scan result updates.
    func trashItems(_ items: [OrganizeItem], from locationID: UUID) {
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
            let key = EventStorageLocations.pathKey(file.path)
            if let assignment = assignmentsByPathKey[key] {
                eventIDs[key] = assignment.eventID
                removedAssignments.append(assignment)
            }
        }
        if !removedAssignments.isEmpty {
            applyAssignmentChange(AssignmentChange(title: "Move to Trash", removed: removedAssignments, added: []), touching: nil)
        }

        let trashedStackIDs = affectedStackIDs(for: items, in: locationID)
        let context = TrashContext(
            locationName: location.name,
            deviceID: deviceID(for: location),
            eventIDsByPathKey: eventIDs
        )
        let originRoot = URL(fileURLWithPath: DashboardModel.expandedPath(location.path), isDirectory: true).standardizedFileURL
        let fallbackTrashRoot = locations.removedFilesRoot
        model.runBackgroundJob(
            action: .organize,
            runningNote: "Moving \(files.count) file(s) to Trash",
            logTitle: "Moved files to Trash",
            logDetail: "Renamed files into the drive-local .Camera Toolkit/_Trash folder and wrote a manifest recording where each file lived. Nothing was deleted; batches are restorable from Settings.",
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
                let skippedNote = batch.skipped.isEmpty
                    ? ""
                    : " \(batch.skipped.count) stayed in place: \(batch.skipped[0].reason)"
                return batch.entries.isEmpty
                    ? "Nothing moved to Trash.\(skippedNote)"
                    : "Moved \(batch.entries.count) files to Trash — restorable from Settings.\(skippedNote)"
            }
        )
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
        let candidates = summary.assets.compactMap { asset -> ImmichCandidate? in
            guard asset.assignment.immichUploadOverride ?? event.sendsToImmich,
                  uploadable.contains((asset.assignment.relativePath as NSString).pathExtension.lowercased()),
                  let path = asset.bestLocalPath else { return nil }
            return ImmichCandidate(id: asset.id, path: path, size: asset.assignment.fileSize, modifiedAt: asset.assignment.modifiedAt)
        }
        guard !candidates.isEmpty else {
            model.statusMessage = event.sendsToImmich
                ? "No reachable photos or videos to send. Connect the drive or NAS that has them."
                : "Turn on Send to Immich for \(eventTitle(event)) first."
            return
        }
        let albumName: String? = switch event.resolvedImmichAlbumPolicy {
        case .none: nil
        case .event: event.name
        case .custom:
            event.immichAlbumName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? event.name
        }
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
                var outcome = ImmichUploadOutcome(albumName: albumName)
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
                if let albumName {
                    let album = try await client.ensureAlbum(named: albumName)
                    outcome.albumAdded = try await client.addAssets(Array(Set(remoteIDs.values)), toAlbum: album.id).added
                }
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
}
