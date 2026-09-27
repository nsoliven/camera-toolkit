import AppKit
import CameraToolkitCore
import SwiftUI

/// One event: where its originals are right now, one action per place, and
/// every photo grouped by burst.
struct EventBoardView: View {
    @Bindable var model: DashboardModel
    @Bindable var workspace: EventsWorkspace
    let eventID: UUID

    @AppStorage("CameraToolkit.organize.tileWidth") private var tileWidth: Double = 220
    @AppStorage("CameraToolkit.organize.mode") private var boardMode: OrganizeBoardMode = .tiles
    @AppStorage("CameraToolkit.eventboard.grouping") private var grouping: OrganizeBoardGrouping = .day
    @AppStorage(OrganizeBoardSortDefaults.eventKey) private var sortKey: OrganizeSortKey = .captureTime
    @AppStorage(OrganizeBoardSortDefaults.eventAscending) private var sortAscending = OrganizeBoardSortDefaults.legacyAscending()
    @State private var previewStackID: String?
    @State private var previewFrameIndex = 0
    @State private var showAllPeople = false
    /// The filter popover — owned here, outside the bottom bar's
    /// `ViewThatFits`, so a candidate swap cannot re-present it mid-layout.
    @State private var showFilters = false
    /// Shared with the View menu's Show Inspector item (⌥⌘I); the
    /// inspector itself hangs off the split view in EventsRootView.
    @AppStorage(EventInfoInspector.visibilityDefaultsKey) private var showInspector = false

    /// People chips kept on the first row. The rest sit behind Show more,
    /// ordered by how many confirmed faces each person has on this event.
    private static let collapsedPeopleCount = 4

    /// Grouping that makes sense inside one event — every stack belongs to
    /// it, so "by event" would be a single useless section.
    private static let groupings: [OrganizeBoardGrouping] = [.day, .kind, .ungrouped]

    private var effectiveGrouping: OrganizeBoardGrouping {
        Self.groupings.contains(grouping) ? grouping : .day
    }

    private var boardGroups: [OrganizeBoardGroup] {
        workspace.eventBoardGroups(
            eventID,
            stacks: workspace.visibleEventStacks(eventID, search: workspace.search),
            grouping: effectiveGrouping,
            sort: sort
        )
    }

    private var sort: OrganizeStackSort {
        OrganizeStackSort(key: sortKey, ascending: sortAscending)
    }

    var body: some View {
        if let event = workspace.event(eventID) {
            let stacks = workspace.eventStacks[eventID]
            // One grouping pass per render — the board, the toolbar count,
            // and the bottom bar all share it.
            let groups = boardGroups
            let ordered = groups
                .filter { !workspace.collapsedGroupIDs.contains($0.id) }
                .flatMap(\.stacks)
            let matched = groups.reduce(0) { $0 + $1.stacks.count }
            let title = workspace.eventTitle(event)
            let reachability = workspace.eventReachability[eventID]
            VStack(spacing: 0) {
                if let reachability, reachability.isOffline || stacks?.isEmpty == true {
                    // Terminal, not a spinner: nothing reachable holds the
                    // event's files, and the report says which drives to
                    // plug in.
                    offlineState(event, reachability)
                } else if stacks != nil {
                    if groups.isEmpty {
                        if workspace.search.isEmpty {
                            emptyState(event)
                        } else {
                            NoMatchesView(workspace: workspace, boardName: title)
                        }
                    } else {
                        board(groups: groups)
                    }
                } else {
                    ProgressView("Loading \(event.name)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("eventBoardLoading")
                }
            }
            .safeAreaBar(edge: .top) {
                titleAccessory(event)
            }
            // A firm edge under the bottom bar keeps its caption legible
            // over tiles scrolling beneath it.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                BoardBottomBar(model: model, workspace: workspace, loadingNote: loadingNote) {
                    ViewThatFits(in: .horizontal) {
                        viewControls(groups: groups, compact: false)
                        viewControls(groups: groups, compact: true)
                        viewControls(groups: groups, compact: true, iconOnlyMenus: true)
                    }
                    .boardFilterPopover(
                        isPresented: $showFilters,
                        workspace: workspace,
                        stacks: stacks ?? [],
                        eventScope: workspace.scopeIDs(eventID),
                        search: $workspace.search,
                        matchedCount: matched
                    )
                }
            }
            .overlay {
                if previewStackID != nil {
                    StackPreviewOverlay(
                        workspace: workspace,
                        stacks: ordered,
                        stackID: $previewStackID,
                        excludedEventID: eventID,
                        assignVerb: "Move to",
                        eventForStack: { stack in workspace.assignedEvent(for: stack).event ?? event },
                        onAssign: { stack, target in
                            workspace.moveStacks([stack.id], fromEvent: eventID, toEvent: target.id)
                        },
                        onNewEvent: { stack in
                            workspace.requestNewEvent(stackIDs: [stack.id], movingFromEvent: eventID, suggestedDate: stack.captureDate)
                        },
                        onTrashItems: { items in
                            workspace.requestTrash(items, fromEvent: eventID)
                        },
                        onSplitItems: { items in
                            workspace.splitItems(items)
                        },
                        orientationForFile: { workspace.displayTurns(for: $0) },
                        onRotate: { stack, delta in
                            workspace.rotateStack(stack, quarterTurnsCW: delta)
                        },
                        initialFrameIndex: previewFrameIndex
                    )
                }
            }
            .navigationTitle(title)
            .toolbar(removing: .title)
            .toolbar {
                EventBoardToolbar(
                    model: model,
                    workspace: workspace,
                    event: event,
                    title: title,
                    count: countText(total: stacks?.count, matched: matched),
                    countHelp: countHelp(total: stacks?.count, matched: matched),
                    help: summaryText(event),
                    showInspector: $showInspector
                )
            }
            // The task keys on the event and its storage policy only —
            // assignment writes patch the open board in place, so a count
            // change must not tear the grid down and rebuild it.
            .task(id: "\(eventID.uuidString)-\(workspace.resolvedPolicy(for: event).rawValue)") {
                await workspace.refreshEvent(eventID)
            }
            .onReceive(NotificationCenter.default.publisher(for: BrowserCommand.notification)) { notification in
                guard let raw = notification.object as? String, let command = BrowserCommand(rawValue: raw) else { return }
                handle(command, ordered: ordered)
            }
        } else {
            ContentUnavailableView("Event Not Found", systemImage: "calendar.badge.exclamationmark")
                .navigationTitle("Camera Toolkit")
        }
    }

    /// The capsule: the event's file count, or "N of M" items while a
    /// search or filter narrows the board.
    private func countText(total: Int?, matched: Int) -> String {
        if let total, !workspace.search.isEmpty {
            return "\(matched.formatted()) of \(total.formatted())"
        }
        return workspace.assignmentCount(for: eventID).formatted()
    }

    private func countHelp(total: Int?, matched: Int) -> String {
        if let total, !workspace.search.isEmpty {
            return "\(matched) of \(total) item\(total == 1 ? "" : "s") match the search and filters"
        }
        let files = workspace.assignmentCount(for: eventID)
        return "\(files) file\(files == 1 ? "" : "s")"
    }

    private func summaryText(_ event: SavedCameraEvent) -> String {
        let files = workspace.assignmentCount(for: eventID)
        return "\(event.eventDate.formatted(date: .complete, time: .omitted)) · \(files) file\(files == 1 ? "" : "s") · \(workspace.assignmentBytes(for: eventID).formattedBytes)"
    }

    /// Loading progress for the status caption — the board fills in first
    /// and keeps loading files and capture dates behind it.
    private var loadingNote: String? {
        if let reachability = workspace.eventReachability[eventID], !reachability.isOffline {
            // Partly mounted: the board loads what is reachable and says
            // what is not, instead of waiting on it.
            let places = reachability.offlinePlaces
            return "\(reachability.offlineList) \(places.count == 1 ? "isn't" : "aren't") connected — showing what's reachable."
        }
        if let remaining = workspace.eventBuildRemainders[eventID], remaining > 0 {
            return "First photos are up — the remaining \(remaining.formatted()) files are still loading."
        }
        if let pending = workspace.eventDateReadRemainders[eventID], pending > 0 {
            return "Reading capture dates… \(pending.formatted()) left."
        }
        return nil
    }

    private func viewControls(groups: [OrganizeBoardGroup], compact: Bool, iconOnlyMenus: Bool = false) -> some View {
        BoardViewControls(
            workspace: workspace,
            filterPresented: $showFilters,
            groups: groups,
            mode: $boardMode,
            grouping: Binding(get: { effectiveGrouping }, set: { grouping = $0 }),
            groupings: Self.groupings,
            sort: Binding(get: { sort }, set: { sortKey = $0.key; sortAscending = $0.ascending }),
            tileWidth: $tileWidth,
            compact: compact,
            iconOnlyMenus: iconOnlyMenus
        )
    }

    /// Pinned under the toolbar: where the originals are (one menu per
    /// place), subevent, people and — on a mixed board — camera chips,
    /// and the active filters.
    private func titleAccessory(_ event: SavedCameraEvent) -> some View {
        let people = workspace.eventPeople(eventID)
        let subevents = workspace.subevents(of: eventID)
        let shown = showAllPeople ? people : Array(people.prefix(Self.collapsedPeopleCount))
        // Camera chips only when the board mixes cameras — one camera
        // needs no filter.
        let cameras = workspace.boardCameras(for: workspace.eventStacks[eventID] ?? [])
        return VStack(alignment: .leading, spacing: 8) {
            EventStorageSummary(slots: EventStorageSlots(
                model: model,
                workspace: workspace,
                event: event,
                summary: workspace.presence[eventID]
            ))
            .guideHighlight(.storageStrip, in: workspace)
            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(subevents) { subevent in
                    SubeventChip(
                        event: subevent,
                        isFiltering: workspace.search.excludedEventIDs.contains(subevent.id),
                        onToggle: { workspace.search.toggleEventExclusion(subevent.id) }
                    )
                }
                ForEach(shown) { person in
                    PersonChip(person: person)
                }
                if people.count > Self.collapsedPeopleCount {
                    Button(showAllPeople ? "Show Less" : "Show \(people.count - Self.collapsedPeopleCount) More") {
                        showAllPeople.toggle()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                if cameras.count > 1 {
                    ForEach(cameras) { entry in
                        CameraChip(
                            camera: entry.camera,
                            count: entry.stackCount,
                            isOn: workspace.search.isCameraChipOn(entry.id),
                            onToggle: { workspace.search.toggleCameraChip(entry.id) }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !workspace.search.rowsWithValues.isEmpty {
                OrganizeFilterHotLinks(
                    workspace: workspace,
                    stacks: workspace.eventStacks[eventID] ?? [],
                    search: $workspace.search
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: eventID) { _, _ in showAllPeople = false }
    }

    /// The board's answer when the event's drives are unplugged (or a share
    /// is not answering): which places are missing, what to plug in, and
    /// a Retry. A mount notification re-checks on its own.
    private func offlineState(_ event: SavedCameraEvent, _ reachability: EventReachabilityReport) -> some View {
        let count = workspace.assignmentCount(for: eventID)
        return ContentUnavailableView {
            Label("Drives Not Connected", systemImage: "externaldrive.badge.xmark")
        } description: {
            Text("\(event.name) is on drives that aren't connected: \(reachability.offlineList). \(reachability.remedySentence)"
                + (count > 0 ? " \(count.formatted()) file\(count == 1 ? "" : "s") are waiting in the catalog." : ""))
        } actions: {
            Button("Retry") {
                Task { await workspace.refreshEvent(eventID) }
            }
            .help("Check again whether this event's drives and the NAS are connected")
        }
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("eventBoardOffline")
    }

    private func emptyState(_ event: SavedCameraEvent) -> some View {
        let count = workspace.assignmentCount(for: eventID)
        return ContentUnavailableView {
            Label(count == 0 ? "No Photos Yet" : "Files Not Reachable", systemImage: count == 0 ? "photo.on.rectangle.angled" : "externaldrive.badge.xmark")
        } description: {
            Text(count == 0
                ? "Open an Unsorted folder or card, select photos, and press a number key or drag them onto \(event.name)."
                : "\(count) files belong to this event, but no connected drive, card, or NAS has them right now.")
        } actions: {
            if count > 0 {
                Button("Check Again") {
                    workspace.refreshConnectivity()
                    Task { await workspace.refreshEvent(eventID) }
                }
                .help("Re-check every drive, card, and the NAS for this event's files")
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func board(groups: [OrganizeBoardGroup]) -> some View {
        OrganizeGrid(
            workspace: workspace,
            groups: groups,
            mode: boardMode,
            tileWidth: tileWidth,
            origin: .event,
            containerID: eventID,
            eventForStack: { _ in (nil, false) },
            tagForStack: { workspace.subeventTag(for: $0, in: eventID) },
            editTagsForStack: { workspace.editTagList(for: $0, in: eventID) },
            isDimmed: { _ in false },
            badge: { workspace.badge(for: $0, in: eventID) },
            orientationForFile: { workspace.displayTurns(for: $0) },
            onOpen: { stack, frame in
                workspace.select(stackID: stack.id, orderedIDs: [], extend: false, toggle: false)
                previewFrameIndex = frame
                previewStackID = stack.id
            },
            onKey: { press, _ in handleKey(press) },
            menu: { stack in LazyContextMenu { contextMenu(stack) } }
        )
    }

    private func openPreview(_ stackID: String, frame: Int = 0) {
        previewFrameIndex = frame
        previewStackID = stackID
    }

    /// Menu construction stays free of filesystem work and board scans: the
    /// workspace answers every row from indexes it already maintains, so the
    /// menu opens instantly even while the event is still "Checking". Rows
    /// that need data which is not ready stay enabled and explain themselves
    /// when clicked.
    @ViewBuilder
    private func contextMenu(_ stack: OrganizeStack) -> some View {
        let menu = workspace.stackMenuState(forStackID: stack.id, inEvent: eventID)
        let targets = menu.targetIDs
        Menu("Move to Event") {
            ForEach(menu.eventTargets) { target in
                Button(target.title) {
                    workspace.moveStacks(targets, fromEvent: eventID, toEvent: target.id)
                }
            }
        }
        Button("Return to Unsorted") {
            workspace.returnToUnsorted(targets, eventID: eventID)
        }
        Menu(menu.rotateTitle) {
            Button("Rotate All 90° Left") { rotate(targets, by: -1) }
            Button("Rotate All 180°") { rotate(targets, by: 2) }
            Button("Rotate All 90° Right") { rotate(targets, by: 1) }
        }
        .disabled(!menu.canRotate)
        .optionalHelp(menu.rotateHelp)
        Divider()
        Button("Preview") { openPreview(stack.id) }
        // A 360 clip's own editor leads when it's installed; Photomator
        // stays for everything else.
        if DJIStudio.isOffered(for: stack.items.map(\.primary.url), resolver: WorkspaceBundleResolver.shared) {
            Button("Open in \(DJIStudio.name)") {
                openInDJIStudio(targets)
            }
            .help(DJIStudio.help)
        }
        Button("Open in Photomator") {
            openInPhotomator(targets)
        }
        Button("Reveal in Finder") {
            reveal(targets)
        }
        Divider()
        Button("Move to Trash…", role: .destructive) {
            workspace.requestTrash(stackIDs: targets, fromEvent: eventID)
        }
        .help("Move these event files to the drive's Trash folder. Restorable from the Trash window.")
    }

    private func urls(for ids: Set<String>) -> [URL] {
        stacks(for: ids).flatMap { $0.items.map(\.primary.url) }
    }

    private func stacks(for ids: Set<String>) -> [OrganizeStack] {
        workspace.stacks(matching: ids, inEvent: eventID)
    }

    private func openInDJIStudio(_ ids: Set<String>) {
        let urls = urls(for: ids)
        guard !urls.isEmpty else {
            workspace.model.statusMessage = "Those stacks are not on the board anymore — click them again."
            return
        }
        if !DJIStudio.open(urls) {
            workspace.model.statusMessage = "DJI Studio isn't installed, or none of those items is a 360° clip."
        }
    }

    private func openInPhotomator(_ ids: Set<String>) {
        let urls = urls(for: ids)
        guard !urls.isEmpty else {
            workspace.model.statusMessage = "Those stacks are not on the board anymore — click them again."
            return
        }
        PhotomatorLauncher.open(urls)
    }

    private func reveal(_ ids: Set<String>) {
        let urls = urls(for: ids)
        guard !urls.isEmpty else {
            workspace.model.statusMessage = "Those stacks are not on the board anymore — click them again."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// One Rotate Selection action turns every targeted burst the same way.
    private func rotate(_ ids: Set<String>, by delta: Int) {
        workspace.rotateStacks(stacks(for: ids), quarterTurnsCW: delta)
    }

    private func rotateTargets(_ ids: Set<String>, by delta: Int) -> KeyPress.Result {
        let stacks = stacks(for: ids)
        guard !stacks.isEmpty else { return .ignored }
        workspace.rotateStacks(stacks, quarterTurnsCW: delta)
        return .handled
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Never board keys while a text field owns typing — 1–3 edits the
        // field, it does not move stacks between events.
        guard !KeyboardTextFocus.isTypingInTextField() else { return .ignored }
        let targets = workspace.targetStackIDs()
        if press.modifiers.isEmpty || press.modifiers == .shift {
            switch press.characters {
            case "]", "}", "r":
                return rotateTargets(targets, by: 1)
            case "[", "{", "R":
                return rotateTargets(targets, by: -1)
            default:
                break
            }
        }
        guard press.modifiers.isEmpty,
              let digit = press.characters.first?.wholeNumberValue,
              (1...3).contains(digit) else { return .ignored }
        let recents = workspace.assignableRecents(excluding: eventID)
        guard digit <= recents.count, !targets.isEmpty else { return .handled }
        workspace.moveStacks(targets, fromEvent: eventID, toEvent: recents[digit - 1].id)
        return .handled
    }

    private func handle(_ command: BrowserCommand, ordered: [OrganizeStack]) {
        // Commands are app-wide notifications — act only while the main
        // window is key, not with Trash or People in front of it.
        guard BrowserCommand.targetsMainWindow() else { return }
        guard command.isAllowedWhileTyping || !KeyboardTextFocus.isTypingInTextField() else { return }
        switch command {
        case .selectAll:
            workspace.selectStacks(ordered.map(\.id))
        case .previewSelection:
            if let id = workspace.focusedStackID ?? workspace.selectedStackIDs.first {
                openPreview(id)
            }
        case .openSelection:
            PreferredExternalOpen.open(urls(for: workspace.targetStackIDs()))
        case .revealSelection:
            NSWorkspace.shared.activateFileViewerSelecting(urls(for: workspace.targetStackIDs()))
        case .reload:
            Task { await workspace.refreshEvent(eventID) }
        case .find:
            // The window's toolbar search field takes ⌘F (EventsRootView).
            break
        case .moveSelectionToTrash:
            workspace.requestTrash(stackIDs: workspace.targetStackIDs(), fromEvent: eventID)
        }
    }
}

/// The event board's toolbar: centered title with its count, then the
/// window's search field and the event's actions. Its own ToolbarContent
/// so a board re-render does not rebuild the NSToolbar items it did not
/// change.
private struct EventBoardToolbar: ToolbarContent {
    let model: DashboardModel
    let workspace: EventsWorkspace
    let event: SavedCameraEvent
    let title: String
    let count: String
    let countHelp: String
    let help: String
    @Binding var showInspector: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            BoardToolbarTitle(
                title: title,
                color: EventPalette.color(for: event.id),
                count: count,
                countHelp: countHelp,
                help: help
            )
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            NASSyncToolbarButton(model: model, workspace: workspace, event: event)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                EventActionsMenu(model: model, workspace: workspace, event: event)
            } label: {
                Label("Event Actions", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("New subevent, rename, storage, faces, and more")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label(showInspector ? "Hide Event Info" : "Show Event Info", systemImage: "sidebar.trailing")
            }
            .help(showInspector ? "Hide Event Info (⌥⌘I)" : "Show Event Info — storage, people, and the event's details (⌥⌘I)")
        }
    }
}

/// "Sync to NAS" in the board header — or "Connect to NAS…" while the NAS
/// share is not mounted and an SMB address is configured.
private struct NASSyncToolbarButton: View {
    let model: DashboardModel
    let workspace: EventsWorkspace
    let event: SavedCameraEvent

    var body: some View {
        if workspace.nasIsConnected {
            Button {
                workspace.syncToNAS(event.id)
            } label: {
                Label("Sync to NAS", systemImage: "arrow.up.to.line.circle")
            }
            .disabled(model.isBusy)
            .help("Sync to NAS — copy this event and its subevents to the NAS, verifying every copy by re-reading it")
        } else if workspace.nasShareURL != nil {
            Button {
                workspace.connectToNAS()
            } label: {
                Label("Connect to NAS…", systemImage: "server.rack")
            }
            .help("The NAS is not connected. Open the configured share so Finder mounts it.")
        } else {
            Button {
                workspace.syncToNAS(event.id)
            } label: {
                Label("Sync to NAS", systemImage: "arrow.up.to.line.circle")
            }
            .disabled(true)
            .help("The NAS is not connected. Mount the share in Finder, or set its smb:// address in Settings → Locations.")
        }
    }
}

/// The event's ··· menu. Its own view: toolbar menu content can be built
/// eagerly, so nothing here starts work — Scan for Faces reads the status
/// the open board already loaded.
private struct EventActionsMenu: View {
    let model: DashboardModel
    let workspace: EventsWorkspace
    let event: SavedCameraEvent

    var body: some View {
        let eventID = event.id
        Button("New Subevent…") {
            workspace.requestNewEvent(from: nil, parentEventID: eventID)
        }
        Button("Rename or Change Date…") {
            workspace.renameRequest = RenameEventRequest(eventID: eventID)
        }
        Picker("Keep on Drive", selection: Binding(
            get: { workspace.resolvedPolicy(for: event) },
            set: { workspace.setPolicy(eventID, $0) }
        )) {
            Label("Shared Buffer", systemImage: "externaldrive").tag(EventStoragePolicy.buffer)
            Label("Private · NAS Only", systemImage: "lock.fill").tag(EventStoragePolicy.archiveOnly)
        }
        .pickerStyle(.menu)
        .help("Shared events live in the Buffer everyone browses. Private events stay hidden on the drive until they are archived to the NAS.")
        Divider()
        Button("Reveal Drive Folder") {
            reveal(workspace.locations.eventFolder(for: event, policy: workspace.resolvedPolicy(for: event)))
        }
        Button("Reveal NAS Folder") {
            // The mirror folder, or the legacy archive folder of an event
            // archived before the mirror layout.
            let mirror = workspace.locations.nasEventFolder(for: event)
            let legacy = workspace.locations.legacyArchiveEventFolder(for: event)
            reveal(FileManager.default.fileExists(atPath: mirror.path) || !FileManager.default.fileExists(atPath: legacy.path) ? mirror : legacy)
        }
        Divider()
        Button("Scan for Faces…") {
            workspace.requestFaceScan(event)
        }
        .disabled(workspace.faceScanBlocker(for: event) != nil)
        .help(workspace.faceScanBlocker(for: event)
            ?? "Detect and match faces on a sample of each burst — not every frame — plus single stills and, at MED and above, video frames. Writes only to the catalog — media is read, never touched.")
        Button("Refresh") {
            Task { await workspace.refreshEvent(eventID) }
        }
        Divider()
        Button("Undo Last Move") { workspace.undoLastMove() }
            .disabled(workspace.latestMoveJournalTitle == nil || model.isBusy)
        Button("Delete Empty Event", role: .destructive) { workspace.deleteEmptyEvent(eventID) }
            .disabled(workspace.assignmentCount(for: eventID) > 0)
    }

    private func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            model.statusMessage = "That folder does not exist yet: \(url.path)"
        }
    }
}

/// One place the event's originals can live — card, drive, NAS, or Immich —
/// as the numbers and actions both the compact summary and the inspector
/// draw from.
struct StorageSlot<Actions: View> {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    let detail: String
    let state: StorageSlotState
    @ViewBuilder let actions: () -> Actions
}

/// Source, drive, NAS, and Immich: where this event's originals are and the
/// one action that moves each place forward. Plain data, so the summary in
/// the board and the inspector show the same numbers and actions.
@MainActor
struct EventStorageSlots {
    let model: DashboardModel
    let workspace: EventsWorkspace
    let event: SavedCameraEvent
    let summary: EventPresenceSummary?

    private var assets: [EventAssetPresence] { summary?.assets ?? [] }

    /// Re-checks connections and re-probes where this event's files are. Used
    /// on slots that are showing Offline.
    private var checkAgainButton: some View {
        Button("Check Again") {
            workspace.refreshConnectivity()
            Task { await workspace.refreshEvent(event.id) }
        }
        .help("Re-check this connection right now")
    }

    var source: StorageSlot<some View> {
        let separate = assets.filter { !$0.sourceIsDriveCopy }
        let onSource = separate.count { $0.source == .present }
        let offline = separate.count { $0.source == .unavailable }
        let freeable = separate.count { $0.source == .present && $0.drive == .present }
        let value: String
        let detail: String
        if summary == nil {
            value = "Checking…"
            detail = "Looking at the card or unsorted folder"
        } else if separate.isEmpty {
            value = "—"
            detail = assets.isEmpty ? "No files yet" : "Already organized on the drive"
        } else {
            value = "\(onSource) of \(separate.count)"
            detail = offline > 0
                ? "\(offline) on a disconnected card or drive"
                : (onSource == 0 ? "Nothing left on the card or unsorted folder" : "Still on the card or unsorted folder")
        }
        return StorageSlot(
            title: "Card / Unsorted",
            symbol: "sdcard",
            tint: .orange,
            value: value,
            detail: detail,
            state: summary == nil ? .unknown : (onSource == 0 ? .complete : .partial)
        ) {
            if freeable > 0 {
                Button("Free Up Source…") { workspace.requestRemoveFromSource(event.id) }
                    .disabled(model.isBusy)
                    .help("Re-hash each source file against its drive copy, then remove the source originals")
            }
            if offline > 0 {
                checkAgainButton
            }
        }
    }

    var drive: StorageSlot<some View> {
        let policy = workspace.resolvedPolicy(for: event)
        let total = assets.count
        let onDrive = assets.count { $0.drive == .present }
        let onOther = assets.count { $0.otherDrive == .present }
        let needsDrive = assets.count { $0.drive != .present && ($0.otherDrive == .present || $0.isOnSeparateSource) }
        let removable = assets.count { ($0.drive == .present || $0.otherDrive == .present) && $0.archiveIsTrusted }
        let offline = summary?.driveOffline ?? false
        let detail: String
        if summary == nil {
            detail = "Checking the drive"
        } else if offline {
            detail = "The drive is not connected"
        } else if onOther > 0 {
            detail = policy == .archiveOnly ? "\(onOther) still in the shared Buffer" : "\(onOther) still in Private staging"
        } else if total > 0 && onDrive == total {
            detail = policy == .buffer ? "Everyone who browses the Buffer can see these" : "Hidden from the shared Buffer"
        } else if total > 0 && onDrive == 0 {
            detail = policy == .buffer ? "Not on the Buffer" : "Not on the drive"
        } else {
            detail = "\(total - onDrive) not on the drive yet"
        }
        return StorageSlot(
            title: policy == .buffer ? "Shared Buffer" : "Private Staging",
            symbol: policy == .buffer ? "externaldrive.fill" : "lock.fill",
            tint: policy == .buffer ? .blue : .purple,
            value: summary == nil ? "Checking…" : (offline ? "Offline" : "\(onDrive) of \(total)"),
            detail: detail,
            state: summary == nil ? .unknown : (offline ? .offline : (total > 0 && onDrive == total && onOther == 0 ? .complete : .partial))
        ) {
            if needsDrive > 0 {
                Button(policy == .buffer ? "Put on Buffer…" : "Move to Private…") {
                    // The counts cover the whole family, so the apply does
                    // too — each subevent's files land in its own nested
                    // folder.
                    workspace.prepareApply(
                        eventIDs: workspace.eventFamily(event.id).map(\.id),
                        title: policy == .buffer ? "Put \(event.name) on the Buffer" : "Move \(event.name) to Private staging"
                    )
                }
                .disabled(model.isBusy)
            }
            if removable > 0 {
                Button("Take Off Drive…") { workspace.requestRemoveFromDrive(event.id) }
                    .disabled(model.isBusy)
                    .help("Only files whose NAS copy Sync to NAS verified leave the drive, and each is re-hashed against the NAS first")
            }
            if offline {
                checkAgainButton
            }
        }
    }

    var nas: StorageSlot<some View> {
        let total = assets.count
        let onNAS = assets.count { $0.archive == .present }
        let verified = summary?.verifiedOnArchive ?? 0
        let legacy = summary?.onLegacyArchiveLayout ?? 0
        let offline = summary?.archiveOffline ?? false
        let onDrive = assets.count { $0.drive == .present || $0.otherDrive == .present }
        let detail: String
        if offline {
            detail = workspace.nasShareURL == nil ? "Connect the NAS share to sync" : "Not connected — Connect to NAS…"
        } else if total > 0, verified == total, let date = summary?.oldestArchiveVerification {
            detail = "On NAS ✓ verified \(date.formatted(date: .abbreviated, time: .shortened))"
        } else if total > 0, onNAS == total {
            detail = legacy > 0
                ? "On NAS · \(legacy) in the old archive layout"
                : "On NAS · \(verified) of \(total) verified — Sync to NAS checks the rest"
        } else {
            detail = "\(max(total - onNAS, 0)) not on the NAS yet"
        }
        return StorageSlot(
            title: "NAS",
            symbol: "server.rack",
            tint: .green,
            value: summary == nil ? "Checking…" : (offline ? "Offline" : "\(onNAS) of \(total)"),
            detail: detail,
            state: summary == nil ? .unknown : (offline ? .offline : (total > 0 && onNAS == total ? .complete : .partial))
        ) {
            if offline {
                if workspace.nasShareURL != nil {
                    Button("Connect to NAS…") { workspace.connectToNAS() }
                        .help("Open the configured NAS share so Finder mounts it")
                }
                checkAgainButton
            } else if onDrive > 0 || verified < onNAS {
                Button("Sync to NAS") { workspace.syncToNAS(event.id) }
                    .disabled(model.isBusy)
                    .help("Copy only the files missing on the NAS, each to the same path it has on the drive, and re-read every copy from the NAS to check its SHA-256. Existing files are never overwritten.")
            }
        }
    }

    var immich: StorageSlot<some View> {
        let statuses = workspace.eventImmichStatuses[event.id] ?? [:]
        let present = statuses.values.count { $0.status == "present" && !$0.isTrashed }
        let albumText: String = switch event.resolvedImmichAlbumPolicy {
        case .none: "No album"
        case .event: "Album “\(event.name)”"
        case .custom: "Album “\(event.immichAlbumName ?? event.name)”"
        }
        return StorageSlot(
            title: "Immich",
            symbol: "cloud.fill",
            tint: .teal,
            value: event.sendsToImmich ? "\(present) sent" : "Off",
            detail: event.sendsToImmich ? albumText : "This event stays out of Immich",
            state: event.sendsToImmich ? (present > 0 && present >= assets.count ? .complete : .partial) : .unknown
        ) {
            Toggle("Send", isOn: Binding(
                get: { event.sendsToImmich },
                set: { model.setEventImmichUploadEnabled(event.id, enabled: $0) }
            ))
            if event.sendsToImmich {
                Menu("Album") {
                    ForEach(ImmichAlbumPolicy.allCases) { policy in
                        Button(policy.displayName) { model.setEventImmichAlbumPolicy(event.id, policy: policy) }
                    }
                }
                .fixedSize()
                Button("Upload") { workspace.uploadToImmich(event.id) }
                    .disabled(model.isBusy || summary == nil)
            }
        }
    }
}

/// The storage status in the board itself: one small capsule per place,
/// each a menu with that place's actions — so Free Up, Put on Buffer,
/// Archive, and Check Again stay one click away with the inspector closed.
struct EventStorageSummary: View {
    let slots: EventStorageSlots

    var body: some View {
        HStack(spacing: 6) {
            item(slots.source)
            item(slots.drive)
            item(slots.nas)
            item(slots.immich)
        }
        .fixedSize()
    }

    private func item<Actions: View>(_ slot: StorageSlot<Actions>) -> some View {
        Menu {
            Text("\(slot.title) — \(slot.detail)")
            Divider()
            slot.actions()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: slot.symbol)
                    .foregroundStyle(slot.tint)
                Text(slot.value)
                    .monospacedDigit()
                    .lineLimit(1)
                StorageSlotStateIcon(state: slot.state)
                    .imageScale(.small)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.quinary, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .help("\(slot.title) — \(slot.detail)")
        .accessibilityLabel("\(slot.title), \(slot.value)")
    }
}

enum StorageSlotState {
    case unknown
    case partial
    case complete
    case offline
}

struct StorageSlotStateIcon: View {
    let state: StorageSlotState

    var body: some View {
        switch state {
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Complete")
        case .partial:
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Partial")
        case .offline:
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(.orange)
                .accessibilityLabel("Offline")
        case .unknown:
            EmptyView()
        }
    }
}

/// The event board's inspector: where the originals are with each place's
/// actions, the storage policy, Immich, people, and the event's own facts.
struct EventInfoInspector: View {
    /// Whether the inspector is open — the toolbar button and the View
    /// menu's Show Inspector item (⌥⌘I) both toggle it.
    static let visibilityDefaultsKey = "CameraToolkit.organize.showInspector"

    @Bindable var model: DashboardModel
    @Bindable var workspace: EventsWorkspace
    let event: SavedCameraEvent

    var body: some View {
        let slots = EventStorageSlots(model: model, workspace: workspace, event: event, summary: workspace.presence[event.id])
        let files = workspace.assignmentCount(for: event.id)
        let people = workspace.eventPeople(event.id)
        Form {
            Section {
                LabeledContent("Date", value: event.eventDate.formatted(date: .complete, time: .omitted))
                LabeledContent("Files", value: files.formatted())
                LabeledContent("Size", value: workspace.assignmentBytes(for: event.id).formattedBytes)
                Button("Rename or Change Date…") {
                    workspace.renameRequest = RenameEventRequest(eventID: event.id)
                }
            } header: {
                Text(workspace.eventTitle(event))
            }
            Section("Keep on Drive") {
                Picker("Keep on Drive", selection: Binding(
                    get: { workspace.resolvedPolicy(for: event) },
                    set: { workspace.setPolicy(event.id, $0) }
                )) {
                    Text("Shared Buffer").tag(EventStoragePolicy.buffer)
                    Text("Private · NAS Only").tag(EventStoragePolicy.archiveOnly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Shared events live in the Buffer everyone browses. Private events stay hidden on the drive until they are archived to the NAS.")
            }
            Section("Where It Is") {
                StorageSlotRow(slot: slots.source)
                StorageSlotRow(slot: slots.drive)
                StorageSlotRow(slot: slots.nas)
                StorageSlotRow(slot: slots.immich)
            }
            if !people.isEmpty {
                Section("People") {
                    ForEach(people) { person in
                        Label(person.name, systemImage: "person.crop.circle")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One storage place in the inspector: title and count, what that means,
/// and its actions.
private struct StorageSlotRow<Actions: View>: View {
    let slot: StorageSlot<Actions>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label {
                    Text(slot.title)
                } icon: {
                    Image(systemName: slot.symbol)
                        .foregroundStyle(slot.tint)
                }
                Spacer(minLength: 8)
                Text(slot.value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                StorageSlotStateIcon(state: slot.state)
            }
            Text(slot.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                slot.actions()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

/// A board with nothing left after its search and filters, with the one
/// action that fixes it.
struct NoMatchesView: View {
    let workspace: EventsWorkspace
    let boardName: String

    var body: some View {
        Group {
            if workspace.search.hasActiveConditions {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Nothing in \(boardName) matches the current search and filters.")
                } actions: {
                    Button("Clear Search and Filters") {
                        workspace.search = OrganizeSearchFilter()
                    }
                }
            } else {
                ContentUnavailableView.search(text: workspace.search.text)
            }
        }
        .frame(maxHeight: .infinity)
    }
}
