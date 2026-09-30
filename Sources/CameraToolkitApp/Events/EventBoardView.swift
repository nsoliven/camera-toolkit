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
    /// The board's measured height, which limits how tall its top bar's
    /// notices and chips may grow before they scroll.
    @State private var boardHeight: Double?
    /// Shared with the View menu's Show Inspector item (⌥⌘I); the
    /// inspector itself hangs off the split view in EventsRootView.
    @AppStorage(EventInfoInspector.visibilityDefaultsKey) private var showInspector = false

    /// Grouping that makes sense inside one event — every stack belongs to
    /// it, so "by event" would be a single useless section.
    fileprivate static let groupings: [OrganizeBoardGrouping] = [.day, .kind, .ungrouped]

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
        let _ = BoardRenderCounter.hit(.board)
        if let event = workspace.event(eventID) {
            let stacks = workspace.eventStacks[eventID]
            // One grouping pass per render — the board, the toolbar count,
            // and the bottom bar all share it.
            let groups = boardGroups
            // The stacks in board order, for the preview and Select All — built
            // when one of them asks, not on every render.
            let ordered = { groups.filter { !workspace.collapsedGroupIDs.contains($0.id) }.flatMap(\.stacks) }
            let matched = groups.reduce(0) { $0 + $1.stacks.count }
            let title = workspace.eventTitle(event)
            VStack(spacing: 0) {
                if workspace.eventBoardShowsPlaceholders(eventID) {
                    // Files this event owns are on their way and a drive
                    // that holds them is up: blank tiles, not a verdict.
                    BoardPlaceholderGrid(
                        title: "Loading \(event.name)…",
                        count: workspace.assignmentCount(for: eventID),
                        tileWidth: tileWidth
                    )
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
            // The header, the status caption and the toolbar's title each read
            // their own state (`EventBoardHeader`, `loadingNote`,
            // `EventBoardToolbarTitle`), so a count, a strip number or a job
            // that changes redraws that one region — not this whole board.
            .safeAreaBar(edge: .top) {
                EventBoardHeader(model: model, workspace: workspace, eventID: eventID, boardHeight: boardHeight)
                    .equatable()
            }
            // A firm edge under the bottom bar keeps its caption legible
            // over tiles scrolling beneath it.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                EventBoardBottomBar(
                    model: model,
                    workspace: workspace,
                    eventID: eventID,
                    groupIDs: groups.map(\.id),
                    loadingNote: { loadingNote }
                )
                .equatable()
            }
            .overlay {
                if previewStackID != nil {
                    StackPreviewOverlay(
                        workspace: workspace,
                        stacks: ordered(),
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
                    matched: matched,
                    showInspector: $showInspector
                )
            }
            // Measured outside both bars, so the top bar's limit never
            // depends on the top bar's own height.
            .onGeometryChange(for: Double.self) { $0.size.height.rounded() } action: { height in
                boardHeight = height
            }
            // The task keys on the event and its storage policy only —
            // assignment writes patch the open board in place, so a count
            // change must not tear the grid down and rebuild it.
            .task(id: "\(eventID.uuidString)-\(workspace.resolvedPolicy(for: event).rawValue)") {
                await workspace.refreshEventIfStale(eventID)
            }
            .onReceive(NotificationCenter.default.publisher(for: BrowserCommand.notification)) { notification in
                guard let raw = notification.object as? String, let command = BrowserCommand(rawValue: raw) else { return }
                handle(command, ordered: ordered())
            }
        } else {
            ContentUnavailableView("Event Not Found", systemImage: "calendar.badge.exclamationmark")
                .navigationTitle("Camera Toolkit")
        }
    }

    /// Loading progress for the status caption — the board fills in first
    /// and keeps loading files and capture dates behind it.
    private var loadingNote: String? {
        if let queued = workspace.queuedMoveNote(for: eventID) { return queued }
        // The Buffer is a buffer: it is not always plugged in, so its absence
        // is never a notice. Only the permanent library (the NAS) or a card
        // being away is worth a line, and never a blocking one — the grid is
        // already up and its tiles fill in when the place answers.
        if let reachability = workspace.eventReachability[eventID] {
            let away = reachability.offlinePlaces.filter { $0.role == .nas || $0.role == .card }
            if !away.isEmpty {
                let list = away.map(\.displayName).formatted(.list(type: .and))
                return "\(list) \(away.count == 1 ? "isn't" : "aren't") connected — photos appear as it comes back."
            }
        }
        if let remaining = workspace.eventBuildRemainders[eventID], remaining > 0 {
            return "First photos are up — the remaining \(remaining.formatted()) files are still loading."
        }
        if let pending = workspace.eventDateReadRemainders[eventID], pending > 0 {
            return "Reading capture dates… \(pending.formatted()) left."
        }
        return nil
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
                workspace.focus(stackID: stack.id)
                previewFrameIndex = frame
                previewStackID = stack.id
            },
            onKey: { press, _ in handleKey(press) },
            menu: { stack in LazyContextMenu { contextMenu(stack) } }
        )
        // Rebuilt only when what it draws changes — not each time the board
        // around it (strip, status line, counts) re-evaluates.
        .equatable()
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

/// The board's bottom bar: the view controls in a width-adaptive glass
/// capsule, and the status caption under it. Its own view, drawn again only
/// when what it shows changes — the ids of the board's groups — and not each
/// time a stack under the grid does (a move changes stacks three times). The
/// controls' settings are read here, from the defaults, and the filter panel
/// asks for the board's stacks and the count that match when it opens.
private struct EventBoardBottomBar: View {
    let model: DashboardModel
    @Bindable var workspace: EventsWorkspace
    let eventID: UUID
    let groupIDs: [String]
    let loadingNote: () -> String?

    @AppStorage("CameraToolkit.organize.tileWidth") private var tileWidth: Double = 220
    @AppStorage("CameraToolkit.organize.mode") private var boardMode: OrganizeBoardMode = .tiles
    @AppStorage("CameraToolkit.eventboard.grouping") private var grouping: OrganizeBoardGrouping = .day
    @AppStorage(OrganizeBoardSortDefaults.eventKey) private var sortKey: OrganizeSortKey = .captureTime
    @AppStorage(OrganizeBoardSortDefaults.eventAscending) private var sortAscending = OrganizeBoardSortDefaults.legacyAscending()
    /// The filter popover — owned here, outside the bar's renderings, so a
    /// width change cannot re-present it mid-layout.
    @State private var showFilters = false

    private var effectiveGrouping: OrganizeBoardGrouping {
        EventBoardView.groupings.contains(grouping) ? grouping : .day
    }

    private var sort: OrganizeStackSort {
        OrganizeStackSort(key: sortKey, ascending: sortAscending)
    }

    var body: some View {
        BoardBottomBar(model: model, workspace: workspace, loadingNote: loadingNote) {
            // Wide, then compact, then icon-only menus: the widest that fits,
            // measured once per width change.
            AdaptiveBar(id: "event-board", tierCount: 3) { tier in
                controls(compact: tier > 0, iconOnlyMenus: tier > 1)
                    .boardFilterPopover(
                        isPresented: $showFilters,
                        workspace: workspace,
                        stacks: workspace.eventStacks[eventID] ?? [],
                        eventScope: workspace.scopeIDs(eventID),
                        search: $workspace.search,
                        matchedCount: workspace.visibleEventStacks(eventID, search: workspace.search).count
                    )
            }
        }
    }

    private func controls(compact: Bool, iconOnlyMenus: Bool) -> some View {
        BoardViewControls(
            workspace: workspace,
            filterPresented: $showFilters,
            groupIDs: groupIDs,
            mode: $boardMode,
            grouping: Binding(get: { effectiveGrouping }, set: { grouping = $0 }),
            groupings: EventBoardView.groupings,
            sort: Binding(get: { sort }, set: { sortKey = $0.key; sortAscending = $0.ascending }),
            tileWidth: $tileWidth,
            compact: compact,
            iconOnlyMenus: iconOnlyMenus
        )
    }
}

extension EventBoardBottomBar: @preconcurrency Equatable {
    static func == (lhs: EventBoardBottomBar, rhs: EventBoardBottomBar) -> Bool {
        lhs.model === rhs.model && lhs.workspace === rhs.workspace && lhs.eventID == rhs.eventID
            && lhs.groupIDs == rhs.groupIDs
    }
}

/// Pinned under the toolbar: where the originals are (one menu per place),
/// subevent, people and — on a mixed board — camera chips, and the active
/// filters. Its own view with its own reads: a move's counts, a job, or the
/// status line change without this being asked to draw again, and the board
/// around it only hands it the event and the height it may grow to.
private struct EventBoardHeader: View {
    let model: DashboardModel
    @Bindable var workspace: EventsWorkspace
    let eventID: UUID
    /// The board's measured height, which limits how tall the notices and
    /// chips may grow before they scroll.
    let boardHeight: Double?
    @State private var showAllPeople = false

    /// People chips kept on the first row. The rest sit behind Show more,
    /// ordered by how many confirmed faces each person has on this event.
    private static let collapsedPeopleCount = 4

    var body: some View {
        let people = workspace.shownEventPeople(eventID: eventID)
        let subevents = workspace.subevents(of: eventID)
        let shown = showAllPeople ? people : Array(people.prefix(Self.collapsedPeopleCount))
        // Camera chips only when the board mixes cameras — one camera
        // needs no filter.
        let cameras = workspace.shownBoardCameras(eventID: eventID)
        VStack(alignment: .leading, spacing: 8) {
            EventStorageStrip(model: model, workspace: workspace, eventID: eventID)
                .guideHighlight(.storageStrip, in: workspace)
            // The strip stays put; the notices and chips under it scroll
            // once they would take more than their share of the board.
            BoardBarScrollRegion(maxHeight: OrganizeChromeSizing.boardAccessoryHeightLimit(boardHeight: boardHeight)) {
                VStack(alignment: .leading, spacing: 8) {
                    EventMisplacedNotice(model: model, workspace: workspace, eventID: eventID)
                    DuplicateBoardNotice(model: model, workspace: workspace, review: workspace.duplicateReview, eventID: eventID)
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Notices when the chips' answers went stale, from a view of its own,
        // so the header is not drawn again until a recount says something new.
        .background { EventChipsWatcher(workspace: workspace, eventID: eventID) }
    }
}

/// Draws nothing. Reads what the header's chips are counted from, so that a
/// stale answer is noticed here instead of by redrawing the header.
private struct EventChipsWatcher: View {
    let workspace: EventsWorkspace
    let eventID: UUID

    var body: some View {
        let _ = workspace.watchChipInputs(eventID)
        Color.clear.frame(width: 0, height: 0)
    }
}

extension EventBoardHeader: @preconcurrency Equatable {
    static func == (lhs: EventBoardHeader, rhs: EventBoardHeader) -> Bool {
        lhs.model === rhs.model && lhs.workspace === rhs.workspace
            && lhs.eventID == rhs.eventID && lhs.boardHeight == rhs.boardHeight
    }
}

/// The storage strip: one capsule per place. It reads the event and the
/// presence *counts* only — not the file rows behind them, which the strip
/// never draws and which SwiftUI would otherwise compare row by row each
/// time the strip is asked to redraw.
private struct EventStorageStrip: View {
    let model: DashboardModel
    let workspace: EventsWorkspace
    let eventID: UUID

    var body: some View {
        if let event = workspace.event(eventID) {
            EventStorageSummary(slots: EventStorageSlots(
                model: model,
                workspace: workspace,
                event: event,
                counts: workspace.presence[eventID]?.counts
            ))
        }
    }
}

/// The purple notice about copies in the wrong half of the drive.
private struct EventMisplacedNotice: View {
    let model: DashboardModel
    let workspace: EventsWorkspace
    let eventID: UUID

    var body: some View {
        if let event = workspace.event(eventID) {
            EventStorageSlots(
                model: model,
                workspace: workspace,
                event: event,
                counts: workspace.presence[eventID]?.counts
            ).misplacedNotice
        }
    }
}

/// The toolbar's centered title with its count capsule. Reads the counts
/// itself, so a move's optimistic and landed counts redraw this capsule and
/// nothing else in the toolbar or the board.
private struct EventBoardToolbarTitle: View {
    let workspace: EventsWorkspace
    let eventID: UUID
    /// Stacks that match the search and filters, worked out once by the board.
    let matched: Int

    var body: some View {
        if let event = workspace.event(eventID) {
            let total = workspace.eventStacks[eventID]?.count
            let narrowed = total != nil && !workspace.search.isEmpty
            let files = workspace.assignmentCount(for: eventID)
            BoardToolbarTitle(
                title: workspace.eventTitle(event),
                color: EventPalette.color(for: event.id),
                count: narrowed ? "\(matched.formatted()) of \((total ?? 0).formatted())" : files.formatted(),
                countHelp: narrowed
                    ? "\(matched) of \(total ?? 0) item\((total ?? 0) == 1 ? "" : "s") match the search and filters"
                    : "\(files) file\(files == 1 ? "" : "s")",
                help: "\(event.eventDate.formatted(date: .complete, time: .omitted)) · \(files) file\(files == 1 ? "" : "s") · \(workspace.assignmentBytes(for: eventID).formattedBytes)"
            )
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
    let matched: Int
    @Binding var showInspector: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            EventBoardToolbarTitle(workspace: workspace, eventID: event.id, matched: matched)
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
            .disabledWhileBusy(model)
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
        Button(workspace.undoMenuTitle ?? "Undo") { workspace.undo() }
            .disabledWhileBusy(model, or: !workspace.canUndo)
        Button(workspace.redoMenuTitle ?? "Redo") { workspace.redo() }
            .disabledWhileBusy(model, or: !workspace.canRedo)
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
    /// The presence counts, taken once when the rows were set — a render
    /// reads these instead of walking ~15,000 rows per slot. Nil while the
    /// event is still being checked. Only the counts: the rows themselves
    /// are never handed to a view, which would have to compare them.
    let presenceCounts: EventPresenceCounts?

    init(model: DashboardModel, workspace: EventsWorkspace, event: SavedCameraEvent, counts: EventPresenceCounts?) {
        self.model = model
        self.workspace = workspace
        self.event = event
        self.presenceCounts = counts
    }

    private var counts: EventPresenceCounts { presenceCounts ?? EventPresenceCounts() }

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
        let counts = counts
        let separate = counts.separateSource
        let onSource = counts.onSource
        let offline = counts.sourceOffline
        let freeable = counts.freeable
        let value: String
        let detail: String
        if presenceCounts == nil {
            value = "Checking…"
            detail = "Looking at the card or unsorted folder"
        } else if separate == 0 {
            value = "—"
            detail = counts.total == 0 ? "No files yet" : "Already organized on the drive"
        } else {
            value = "\(onSource) of \(separate)"
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
            state: presenceCounts == nil ? .unknown : (onSource == 0 ? .complete : .partial)
        ) {
            if freeable > 0 {
                Button("Free Up Source…") { workspace.requestRemoveFromSource(event.id) }
                    .disabledWhileBusy(model)
                    .help("Re-hash each source file against its drive copy, then remove the source originals")
            }
            if offline > 0 {
                checkAgainButton
            }
        }
    }

    var drive: StorageSlot<some View> {
        let policy = workspace.resolvedPolicy(for: event)
        let counts = counts
        let total = counts.total
        let onDrive = counts.onDrive
        let onOther = counts.onOtherDrive
        let needsDrive = counts.needsDrive
        let removable = counts.removable
        let offline = counts.driveOffline
        let detail: String
        if presenceCounts == nil {
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
            value: presenceCounts == nil ? "Checking…" : (offline ? "Offline" : "\(onDrive) of \(total)"),
            detail: detail,
            state: presenceCounts == nil ? .unknown : (offline ? .offline : (total > 0 && onDrive == total && onOther == 0 ? .complete : .partial))
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
                .disabledWhileBusy(model)
            }
            if removable > 0 {
                Button("Take Off Drive…") { workspace.requestRemoveFromDrive(event.id) }
                    .disabledWhileBusy(model)
                    .help("Only files whose NAS copy Sync to NAS verified leave the drive, and each is re-hashed against the NAS first")
            }
            if offline {
                checkAgainButton
            }
        }
    }

    /// Files in the wrong half of the drive for this event's setting — a
    /// private event's copies still in the shared Buffer, or a shared
    /// event's still in Private staging. Changing the setting never moves
    /// files, so say so on the board instead of only in the lock menu.
    @ViewBuilder var misplacedNotice: some View {
        let policy = workspace.resolvedPolicy(for: event)
        let misplaced = counts.onOtherDrive
        if presenceCounts != nil, !counts.driveOffline, misplaced > 0 {
            HStack(spacing: 8) {
                Image(systemName: policy == .archiveOnly ? "lock.open.fill" : "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.purple)
                Text(policy == .archiveOnly
                    ? "\(misplaced) \(misplaced == 1 ? "photo is" : "photos are") still in the shared Buffer, where everyone can see \(misplaced == 1 ? "it" : "them"). This event is private — move \(misplaced == 1 ? "it" : "them") to hide \(misplaced == 1 ? "it" : "them")."
                    : "\(misplaced) \(misplaced == 1 ? "photo is" : "photos are") still in Private staging. This event is shared — put \(misplaced == 1 ? "it" : "them") on the Buffer.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(policy == .buffer ? "Put on Buffer…" : "Move to Private…") {
                    workspace.prepareApply(
                        eventIDs: workspace.eventFamily(event.id).map(\.id),
                        title: policy == .buffer ? "Put \(event.name) on the Buffer" : "Move \(event.name) to Private staging"
                    )
                }
                .buttonStyle(.glass)
                .disabledWhileBusy(model)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    var nas: StorageSlot<some View> {
        let counts = counts
        let total = counts.total
        let onNAS = counts.onArchive
        let verified = counts.verifiedOnArchive
        let legacy = counts.onLegacyArchiveLayout
        let offline = counts.archiveOffline
        let onDrive = counts.onEitherDrive
        // The presence index counts every file Sync to NAS would copy —
        // edits and sidecars too, which have no assignment here.
        let indexedPending = workspace.nasPendingFamilyTotals(for: event.id)?.pendingFiles ?? 0
        let detail: String
        if offline {
            detail = workspace.nasShareURL == nil ? "Connect the NAS share to sync" : "Not connected — Connect to NAS…"
        } else if total > 0, verified == total, let date = counts.oldestArchiveVerification {
            detail = "On NAS ✓ verified \(date.formatted(date: .abbreviated, time: .shortened))"
        } else if total > 0, onNAS == total, indexedPending > 0 {
            detail = "On NAS · \(NASPendingText.files(indexedPending)) of edits or sidecars not on the NAS yet"
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
            value: presenceCounts == nil ? "Checking…" : (offline ? "Offline" : "\(onNAS) of \(total)"),
            detail: detail,
            state: presenceCounts == nil ? .unknown : (offline ? .offline : (total > 0 && onNAS == total ? .complete : .partial))
        ) {
            if offline {
                if workspace.nasShareURL != nil {
                    Button("Connect to NAS…") { workspace.connectToNAS() }
                        .help("Open the configured NAS share so Finder mounts it")
                }
                checkAgainButton
            } else if onDrive > 0 || verified < onNAS || indexedPending > 0 {
                Button("Sync to NAS") { workspace.syncToNAS(event.id) }
                    .disabledWhileBusy(model)
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
            state: event.sendsToImmich ? (present > 0 && present >= counts.total ? .complete : .partial) : .unknown
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
                    .disabledWhileBusy(model, or: presenceCounts == nil)
                    .help(UndoScopeWording.immichUpload)
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
        let _ = BoardRenderCounter.hit(.storageStrip)
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
        let _ = BoardRenderCounter.hit(.inspector)
        let slots = EventStorageSlots(model: model, workspace: workspace, event: event, counts: workspace.presence[event.id]?.counts)
        let files = workspace.assignmentCount(for: event.id)
        // The answer the board's header already drew; the recount after a move
        // lands on its own turn instead of inside this body.
        let people = workspace.shownEventPeople(eventID: event.id)
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

/// Shown once a duplicate scan found photos this event holds as
/// byte-identical copies of photos somewhere else — the same pattern as
/// the storage notices above it. Opens the Duplicates window on the pair.
private struct DuplicateBoardNotice: View {
    let model: DashboardModel
    let workspace: EventsWorkspace
    @Bindable var review: DuplicateReviewModel
    let eventID: UUID

    var body: some View {
        let shared = review.sharedGroups(forEvent: eventID)
        if !shared.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundStyle(.orange)
                Text(DuplicateReviewWording.boardNotice(
                    count: shared.count,
                    partners: review.partners(ofEvent: eventID).map(review.title)
                ))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Review Duplicates…") {
                    DuplicatesWindowController.shared.show(model: model, workspace: workspace, focusingEvent: eventID)
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Disables a control while a file job runs, reading the job state from a
/// view of its own. A control that read `model.isBusy` in the body that built
/// it made that whole body — the storage strip's four menus, the toolbar's
/// items — draw again every time any job started or ended.
private struct DisabledWhileBusy: ViewModifier {
    let model: DashboardModel
    let otherwise: Bool

    func body(content: Content) -> some View {
        content.disabled(otherwise || model.isBusy)
    }
}

private extension View {
    func disabledWhileBusy(_ model: DashboardModel, or otherwise: Bool = false) -> some View {
        modifier(DisabledWhileBusy(model: model, otherwise: otherwise))
    }
}
