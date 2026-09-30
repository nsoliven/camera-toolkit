import AppKit
import CameraToolkitCore
import SwiftUI

/// Sort one card or unsorted folder into events. Nothing moves until Apply.
struct UnsortedBoardView: View {
    @Bindable var model: DashboardModel
    @Bindable var workspace: EventsWorkspace
    let location: ConfiguredLocation

    @AppStorage("CameraToolkit.organize.tileWidth") private var tileWidth: Double = 220
    @AppStorage("CameraToolkit.organize.hideSorted") private var hideSorted = false
    @AppStorage("CameraToolkit.organize.mode") private var boardMode: OrganizeBoardMode = .tiles
    @AppStorage("CameraToolkit.organize.grouping") private var grouping: OrganizeBoardGrouping = .day
    @AppStorage(OrganizeBoardSortDefaults.unsortedKey) private var sortKey: OrganizeSortKey = .captureTime
    @AppStorage(OrganizeBoardSortDefaults.unsortedAscending) private var sortAscending = OrganizeBoardSortDefaults.legacyAscending()
    @State private var previewStackID: String?
    @State private var previewFrameIndex = 0
    /// The filter popover — owned here, outside the bottom bar's
    /// renderings, so a width change cannot re-present it mid-layout.
    @State private var showFilters = false
    /// The Event… picker sheet — outside the renderings for the same
    /// reason as `showFilters`.
    @State private var showEventPicker = false

    private var state: UnsortedSourceState {
        workspace.sources[location.id] ?? UnsortedSourceState()
    }

    private var groups: [OrganizeBoardGroup] {
        guard let result = state.result else { return [] }
        return OrganizeBoardPlan.groups(
            for: workspace.visibleStacks(result, hideSorted: hideSorted, search: workspace.search),
            grouping: grouping,
            sort: sort,
            rootPath: result.rootPath,
            eventBucket: { workspace.eventBucket(for: $0) },
            cameraName: { workspace.primaryCamera(for: $0)?.name }
        )
    }

    private var sort: OrganizeStackSort {
        OrganizeStackSort(key: sortKey, ascending: sortAscending)
    }

    /// Stacks in display order — collapsed groups contribute nothing, so
    /// selection ranges, keyboard focus, and the preview follow what the
    /// owner actually sees.
    private func orderedStacks(in groups: [OrganizeBoardGroup]) -> [OrganizeStack] {
        groups
            .filter { !workspace.collapsedGroupIDs.contains($0.id) }
            .flatMap(\.stacks)
    }

    var body: some View {
        let result = state.result
        // One grouping pass per render — the board, toolbar count, and
        // bottom bar all share it, so collapsing a group never re-plans
        // the whole board.
        let groups = self.groups
        let ordered = orderedStacks(in: groups)
        let searching = !workspace.search.isEmpty
        let matched = groups.reduce(0) { $0 + $1.stacks.count }

        VStack(spacing: 0) {
            if result != nil {
                if groups.isEmpty {
                    if searching {
                        NoMatchesView(workspace: workspace, boardName: location.name)
                    } else if hideSorted {
                        ContentUnavailableView {
                            Label("Everything Here Is Sorted", systemImage: "checkmark.circle")
                        } description: {
                            Text("Show sorted items to review them, or Apply to move the files into their events.")
                        } actions: {
                            Button("Show Sorted") { hideSorted = false }
                            if let result, workspace.sortedFiles(in: result).files > 0 {
                                Button("Apply…") { workspace.prepareApply(sourceLocationID: location.id) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.isBusy)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        ContentUnavailableView {
                            Label("No Photos or Videos", systemImage: "photo")
                        } description: {
                            Text("This folder has no camera files.")
                        } actions: {
                            Button("Rescan") { workspace.scan(location, force: true) }
                                .disabled(state.isScanning || model.isBusy)
                        }
                        .frame(maxHeight: .infinity)
                    }
                } else {
                    board(groups: groups)
                        .guideHighlight(.grid, in: workspace)
                }
            } else if state.isScanning {
                scanningView
            } else if let error = state.error {
                ContentUnavailableView {
                    Label("Can’t Read This Folder", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Rescan") { workspace.scan(location, force: true) }
                        .disabled(state.isScanning || model.isBusy)
                }
                .frame(maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A firm edge under the bottom bar keeps its caption legible over
        // tiles scrolling beneath it.
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .safeAreaBar(edge: .bottom) {
            if let result {
                bottomBar(result, groups: groups, ordered: ordered, matched: matched)
            } else {
                BoardBottomBar(model: model, workspace: workspace) { EmptyView() }
            }
        }
        .overlay {
            if previewStackID != nil {
                StackPreviewOverlay(
                    workspace: workspace,
                    stacks: ordered,
                    stackID: $previewStackID,
                    rootPath: result?.rootPath,
                    eventForStack: { workspace.assignedEvent(for: $0).event },
                    onAssign: { stack, event in
                        workspace.assign(stackIDs: [stack.id], from: location.id, to: event.id)
                    },
                    onNewEvent: { stack in
                        workspace.requestNewEvent(stackIDs: [stack.id], from: location.id, suggestedDate: stack.captureDate)
                    },
                    onTrashItems: { items in
                        workspace.requestTrash(items, from: location.id)
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
        .navigationTitle(location.name)
        .toolbar(removing: .title)
        .toolbar {
            UnsortedBoardToolbar(
                model: model,
                workspace: workspace,
                location: location,
                title: location.name,
                count: countText(result, matched: matched),
                countHelp: countHelp(result, matched: matched),
                help: summaryLine(result),
                isScanning: state.isScanning,
                hasResult: result != nil
            )
        }
        .task(id: location.id) {
            workspace.scan(location)
        }
        .onReceive(NotificationCenter.default.publisher(for: BrowserCommand.notification)) { notification in
            guard let raw = notification.object as? String, let command = BrowserCommand(rawValue: raw) else { return }
            handle(command, ordered: ordered)
        }
    }

    /// The capsule: how many items are left to sort, or "N of M" items
    /// while a search or filter narrows the board.
    private func countText(_ result: OrganizeScanResult?, matched: Int) -> String {
        guard let result else { return state.isScanning ? "…" : "—" }
        if !workspace.search.isEmpty {
            return "\(matched.formatted()) of \(result.stacks.count.formatted())"
        }
        return result.stacks.count { !workspace.isSorted($0) }.formatted()
    }

    private func countHelp(_ result: OrganizeScanResult?, matched: Int) -> String {
        guard let result else { return state.isScanning ? "Reading the folder" : "Not read yet" }
        if !workspace.search.isEmpty {
            return "\(matched) of \(result.stacks.count) items match the search and filters"
        }
        let left = result.stacks.count { !workspace.isSorted($0) }
        return "\(left) item\(left == 1 ? "" : "s") left to sort"
    }

    private func summaryLine(_ result: OrganizeScanResult?) -> String {
        if state.isScanning {
            return state.progress.map { "\($0.phase)…" } ?? "Working…"
        }
        guard let result else { return location.path }
        let bursts = result.stacks.count { $0.isBurst }
        let left = result.stacks.count { !workspace.isSorted($0) }
        return "\(result.stacks.count) items · \(bursts) bursts · \(result.fileCount) files · \(result.byteCount.formattedBytes) · \(result.days.count) day\(result.days.count == 1 ? "" : "s") · \(left) left to sort"
    }

    /// One bottom bar for the sorting workflow: sort-into on the leading
    /// side, view controls in the middle, Undo and Apply trailing. Narrow
    /// windows (the widest rendering that fits, measured once per width) first drop the tile slider and shorten Sort/Group to their
    /// names, then show them as icons, then shrink the targets to numbered
    /// keycaps, then fall back to a Sort Into menu.
    private func bottomBar(_ result: OrganizeScanResult, groups: [OrganizeBoardGroup], ordered: [OrganizeStack], matched: Int) -> some View {
        let sorted = workspace.sortedFiles(in: result)
        let targets = workspace.targetStackIDs()
        let orderedIDs = ordered.map(\.id)
        let collisions = workspace.applyCollisions(in: result)
        let hint = ApplyStatusWording.boardHint(
            sortedFiles: sorted.files,
            sortedBytes: sorted.bytes,
            duplicates: collisions.duplicates,
            conflicts: collisions.conflicts
        ) ?? "Select items, then press 1–3, drag onto an event, or press N for a new event"
        return BoardBottomBar(model: model, workspace: workspace, hint: hint) {
            AdaptiveBar(id: "unsorted-board", tierCount: 6) { tier in
                let style: (EventAssignControls.Style, Bool, Bool) = switch tier {
                case 0: (.glass, false, false)
                case 1: (.glass, true, false)
                case 2: (.glass, true, true)
                case 3: (.glassNumbers, true, false)
                case 4: (.glassNumbers, true, true)
                default: (.menu, true, true)
                }
                bottomBarRow(result, groups: groups, orderedIDs: orderedIDs, matched: matched, targets: targets, sorted: sorted, assignStyle: style.0, compactControls: style.1, iconOnlyMenus: style.2)
                    .boardFilterPopover(
                        isPresented: $showFilters,
                        workspace: workspace,
                        stacks: result.stacks,
                        search: $workspace.search,
                        matchedCount: matched
                    )
                    .eventPickerSheet(
                        isPresented: $showEventPicker,
                        workspace: workspace,
                        verb: "Sort into",
                        canAssign: !targets.isEmpty,
                        onPick: { workspace.assign(stackIDs: targets, from: location.id, to: $0.id, orderedIDs: orderedIDs) },
                        onNewEvent: { workspace.requestNewEvent(from: location.id) }
                    )
            }
        }
    }

    private func bottomBarRow(
        _ result: OrganizeScanResult,
        groups: [OrganizeBoardGroup],
        orderedIDs: [String],
        matched: Int,
        targets: Set<String>,
        sorted: (files: Int, bytes: Int64),
        assignStyle: EventAssignControls.Style,
        compactControls: Bool,
        iconOnlyMenus: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            // Leading: put the selection into an event.
            HStack(spacing: 6) {
                Text(targets.isEmpty ? "No Selection" : "\(targets.count) Selected")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(targets.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(targets.isEmpty ? "Select items, then press 1–3, drag onto an event, or press N for a new event." : "")
                EventAssignControls(
                    workspace: workspace,
                    verb: "Sort into",
                    canAssign: !targets.isEmpty,
                    style: assignStyle,
                    pickerPresented: $showEventPicker,
                    onAssign: { workspace.assign(stackIDs: targets, from: location.id, to: $0.id, orderedIDs: orderedIDs) },
                    onNewEvent: { workspace.requestNewEvent(from: location.id) }
                )
                Button {
                    workspace.unassign(stackIDs: targets, from: location.id)
                } label: {
                    Label("Unsort", systemImage: "tray.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .disabled(targets.isEmpty)
                .help("Remove the selection from its event (Delete)")
            }
            .fixedSize()
            .guideHighlight(.assignBar, in: workspace)
            Spacer(minLength: 0)
            BoardViewControls(
                workspace: workspace,
                filterPresented: $showFilters,
                groups: groups,
                mode: $boardMode,
                grouping: $grouping,
                groupings: OrganizeBoardGrouping.allCases,
                sort: Binding(get: { sort }, set: { sortKey = $0.key; sortAscending = $0.ascending }),
                tileWidth: $tileWidth,
                hideSorted: $hideSorted,
                compact: compactControls,
                iconOnlyMenus: iconOnlyMenus
            )
            .fixedSize()
            Spacer(minLength: 0)
            // Trailing: undo, and the one commit step.
            HStack(spacing: 6) {
                Button {
                    workspace.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .disabled(!workspace.canUndo)
                .help((workspace.undoMenuTitle ?? "Undo") + " (⌘Z)")
                // Apply only opens the plan sheet; nothing moves until the
                // plan is confirmed there.
                Button("Apply…") {
                    workspace.prepareApply(sourceLocationID: location.id)
                }
                .buttonStyle(.glassProminent)
                .disabled(sorted.files == 0 || model.isBusy)
                .help(sorted.files > 0
                    ? "\(sorted.files) sorted file\(sorted.files == 1 ? "" : "s") (\(sorted.bytes.formattedBytes)) still in \(location.name). Review the plan — nothing moves until you confirm it."
                    : "Sort items into events first — Apply moves sorted files into their event folders")
                .guideHighlight(.applyButton, in: workspace)
            }
            .fixedSize()
        }
    }

    private func board(groups: [OrganizeBoardGroup]) -> some View {
        OrganizeGrid(
            workspace: workspace,
            groups: groups,
            mode: boardMode,
            tileWidth: tileWidth,
            origin: .unsorted,
            containerID: location.id,
            rootPath: state.result?.rootPath,
            eventForStack: { workspace.assignedEvent(for: $0) },
            isDimmed: { !hideSorted && workspace.isSorted($0) && !workspace.selectedStackIDs.contains($0.id) },
            badge: { _ in nil },
            orientationForFile: { workspace.displayTurns(for: $0) },
            onOpen: { stack, frame in
                workspace.focus(stackID: stack.id)
                previewFrameIndex = frame
                previewStackID = stack.id
            },
            onKey: { press, orderedIDs in handleKey(press, orderedIDs: orderedIDs) },
            menu: { stack in LazyContextMenu { contextMenu(stack) } }
        )
    }

    private func openPreview(_ stackID: String, frame: Int = 0) {
        previewFrameIndex = frame
        previewStackID = stackID
    }

    /// Same filesystem-free menu construction as the event board: the
    /// workspace answers every row from its stack-id index, so the menu
    /// opens instantly even mid-scan.
    @ViewBuilder
    private func contextMenu(_ stack: OrganizeStack) -> some View {
        let menu = workspace.stackMenuState(forStackID: stack.id, inLocation: location.id)
        let targets = menu.targetIDs
        Menu("Sort Into") {
            ForEach(menu.eventTargets) { target in
                Button(target.title) {
                    workspace.assign(stackIDs: targets, from: location.id, to: target.id)
                }
            }
        }
        Button("New Event from Selection…") {
            if !workspace.selectedStackIDs.contains(stack.id) {
                workspace.selectStacks([stack.id])
            }
            workspace.requestNewEvent(from: location.id)
        }
        Button("Unsort") {
            workspace.unassign(stackIDs: targets, from: location.id)
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
        if DJIStudio.isOffered(for: stack.items.map(\.primary.url), resolver: BundleWorkspaceResolver.shared) {
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
        Button("Move to Trash…") {
            workspace.trash(stackIDs: targets, from: location.id)
        }
        .help("Move to the drive's Trash folder. Restorable from the Trash window.")
    }

    private func urls(for ids: Set<String>) -> [URL] {
        stacks(for: ids).flatMap { $0.items.map(\.primary.url) }
    }

    private func stacks(for ids: Set<String>) -> [OrganizeStack] {
        workspace.stacks(matching: ids, inLocation: location.id)
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

    private var scanningView: some View {
        ContentUnavailableView {
            if let progress = state.progress, progress.total > 0 {
                ProgressView(value: progress.fraction)
                    .frame(width: 280)
                Text("\(progress.phase) · \(progress.processed.formatted()) of \(progress.total.formatted())")
            } else {
                ProgressView()
                Text(state.progress.map { "\($0.phase)\($0.processed > 0 ? " · \($0.processed.formatted()) found" : "")…" } ?? "Reading \(location.name)…")
            }
        } description: {
            Text("Capture times are read from each RAW header and remembered, so reopening is fast.")
        }
        .frame(maxHeight: .infinity)
    }

    private func handleKey(_ press: KeyPress, orderedIDs: [String]) -> KeyPress.Result {
        // Never board keys while a text field owns typing — Delete edits
        // the field, it does not unsort the selection.
        guard !KeyboardTextFocus.isTypingInTextField() else { return .ignored }
        let targets = workspace.targetStackIDs()
        if press.key == .delete || press.key == .deleteForward {
            guard !targets.isEmpty else { return .ignored }
            workspace.unassign(stackIDs: targets, from: location.id)
            return .handled
        }
        guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        switch press.characters {
        case "]", "}", "r":
            return rotateTargets(targets, by: 1)
        case "[", "{", "R":
            return rotateTargets(targets, by: -1)
        default:
            break
        }
        if press.characters.lowercased() == "n" {
            workspace.requestNewEvent(from: location.id)
            return .handled
        }
        if let digit = press.characters.first?.wholeNumberValue, (1...3).contains(digit) {
            let recents = workspace.assignableRecents()
            guard digit <= recents.count, !targets.isEmpty else { return .handled }
            workspace.assign(stackIDs: targets, from: location.id, to: recents[digit - 1].id, orderedIDs: orderedIDs)
            return .handled
        }
        return .ignored
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
            workspace.scan(location, force: true)
        case .find:
            // The window's toolbar search field takes ⌘F (EventsRootView).
            break
        case .moveSelectionToTrash:
            workspace.trash(stackIDs: workspace.targetStackIDs(), from: location.id)
        }
    }
}

/// The unsorted board's toolbar: centered title with the count left to
/// sort, then search, Rescan, New Event, and the ··· menu.
private struct UnsortedBoardToolbar: ToolbarContent {
    let model: DashboardModel
    let workspace: EventsWorkspace
    let location: ConfiguredLocation
    let title: String
    let count: String
    let countHelp: String
    let help: String
    let isScanning: Bool
    let hasResult: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            BoardToolbarTitle(
                title: title,
                symbol: "tray.full",
                count: count,
                countHelp: countHelp,
                help: help
            )
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.scan(location, force: true)
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning || model.isBusy)
            .help("Re-read every file and rebuild the board. Disabled while a scan or job is running.")
            Button {
                workspace.requestNewEvent(from: location.id)
            } label: {
                Label("New Event", systemImage: "calendar.badge.plus")
            }
            .help("Make a new event from the selection (N)")
            Menu {
                UnsortedActionsMenu(model: model, workspace: workspace, location: location, isScanning: isScanning, hasResult: hasResult)
            } label: {
                Label("Folder Actions", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("Camera folder, bursts, faces, and more")
        }
    }
}

/// The unsorted board's ··· menu, in its own view so toolbar rebuilds do
/// not evaluate it; nothing here starts work until an item is chosen.
private struct UnsortedActionsMenu: View {
    let model: DashboardModel
    let workspace: EventsWorkspace
    let location: ConfiguredLocation
    let isScanning: Bool
    let hasResult: Bool

    var body: some View {
        Picker("Camera Folder", selection: Binding(
            get: { workspace.deviceID(for: location) },
            set: { workspace.setDevice($0, for: location.id) }
        )) {
            ForEach(DeviceChoice.all) { choice in
                Text(choice.name).tag(choice.id)
            }
        }
        .pickerStyle(.menu)
        .help("Camera folder name used when these files go into an event")
        Button("Regroup Bursts") {
            workspace.regroupBursts(location)
        }
        .disabled(isScanning || model.isBusy || !hasResult)
        .help("Re-run burst grouping on the scanned files with the current Settings sliders — Sony prefixes, the time gap, then the Vision check. Files are not re-read and nothing moves.")
        Button("Scan for Faces…") {
            workspace.requestFaceScan(location)
        }
        .disabled(workspace.faceScanBlocker(for: location) != nil)
        .help(workspace.faceScanBlocker(for: location)
            ?? "Detect and match faces on a sample of each burst — not every frame — plus single stills and, at MED and above, video frames. Writes only to the catalog — media is read, never touched.")
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: DashboardModel.expandedPath(location.path))])
        }
        Button(workspace.undoMenuTitle ?? "Undo") {
            workspace.undo()
        }
        .disabled(!workspace.canUndo || model.isBusy)
        Button(workspace.redoMenuTitle ?? "Redo") {
            workspace.redo()
        }
        .disabled(!workspace.canRedo || model.isBusy)
        Divider()
        Button("Move to Trash…", role: .destructive) {
            workspace.trash(stackIDs: workspace.targetStackIDs(), from: location.id)
        }
        .disabled(workspace.targetStackIDs().isEmpty)
        .help("Move the selected items to the drive's Trash folder. Restorable from the Trash window.")
        Button("Remove from Unsorted List", role: .destructive) {
            workspace.removeUnsortedFolder(location.id)
        }
        .help("Stop listing this folder here — no files change")
    }
}
