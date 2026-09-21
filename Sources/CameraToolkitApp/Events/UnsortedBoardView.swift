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
    @AppStorage("CameraToolkit.organize.order") private var sortOrder: OrganizeBoardOrder = .oldestFirst
    @State private var previewStackID: String?
    @State private var previewFrameIndex = 0
    @FocusState private var searchFocused: Bool

    private var state: UnsortedSourceState {
        workspace.sources[location.id] ?? UnsortedSourceState()
    }

    private var groups: [OrganizeBoardGroup] {
        guard let result = state.result else { return [] }
        return OrganizeBoardPlan.groups(
            for: workspace.visibleStacks(result, hideSorted: hideSorted, search: workspace.search),
            grouping: grouping,
            order: sortOrder,
            rootPath: result.rootPath,
            eventBucket: { workspace.eventBucket(for: $0) }
        )
    }

    /// Stacks in display order — collapsed groups contribute nothing, so
    /// selection ranges, keyboard focus, and the preview follow what the
    /// owner actually sees.
    private var orderedStacks: [OrganizeStack] {
        groups
            .filter { !workspace.collapsedGroupIDs.contains($0.id) }
            .flatMap(\.stacks)
    }

    var body: some View {
        let result = state.result
        let ordered = orderedStacks
        let searching = !workspace.search.isEmpty

        VStack(spacing: 0) {
            header(result)
            Divider()
            if let result {
                assignBar(orderedIDs: ordered.map(\.id))
                    .guideHighlight(.assignBar, in: workspace)
                Divider()
                if groups.isEmpty {
                    ContentUnavailableView(
                        searching ? "No Matches" : (hideSorted ? "Everything here is sorted" : "No photos or videos"),
                        systemImage: searching ? "magnifyingglass" : (hideSorted ? "checkmark.circle" : "photo"),
                        description: Text(searching
                            ? "Nothing in \(location.name) matches the current search and filters — Clear All resets them."
                            : hideSorted
                                ? "Turn off Hide Sorted to review, or press Apply to move the files into their events."
                                : "This folder has no camera files.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    board()
                        .guideHighlight(.grid, in: workspace)
                }
                Divider()
                applyBar(result)
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
            OrganizeStatusLine(model: model, workspace: workspace)
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
        .task(id: location.id) {
            workspace.scan(location)
        }
        .onReceive(NotificationCenter.default.publisher(for: BrowserCommand.notification)) { notification in
            guard let raw = notification.object as? String, let command = BrowserCommand(rawValue: raw) else { return }
            handle(command, ordered: ordered)
        }
    }

    private func header(_ result: OrganizeScanResult?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full.fill")
                        .foregroundStyle(.orange)
                    Text(location.name)
                        .font(.title2.bold())
                        .lineLimit(1)
                }
                Text(summaryLine(result))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            OrganizeSearchBar(
                workspace: workspace,
                stacks: result?.stacks ?? [],
                search: $workspace.search,
                focused: $searchFocused,
                matchedCount: groups.reduce(0) { $0 + $1.stacks.count }
            )
            Picker("Camera", selection: Binding(
                get: { workspace.deviceID(for: location) },
                set: { workspace.setDevice($0, for: location.id) }
            )) {
                ForEach(DeviceChoice.all) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            .frame(width: 190)
            .help("Camera folder name used when these files go into an event")
            Toggle("Hide Sorted", isOn: $hideSorted)
                .toggleStyle(.switch)
                .controlSize(.small)
            Picker("View", selection: $boardMode) {
                ForEach(OrganizeBoardMode.allCases) { mode in
                    Image(systemName: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 64)
            .help("Tiles or a dense list")
            Menu {
                Section("Group By") {
                    ForEach(OrganizeBoardGrouping.allCases) { option in
                        Toggle(option.title, isOn: Binding(
                            get: { grouping == option },
                            set: { _ in grouping = option }
                        ))
                    }
                }
                Section("Order") {
                    ForEach(OrganizeBoardOrder.allCases) { option in
                        Toggle(option.title, isOn: Binding(
                            get: { sortOrder == option },
                            set: { _ in sortOrder = option }
                        ))
                    }
                }
                Divider()
                let anyCollapsed = groups.contains { workspace.collapsedGroupIDs.contains($0.id) }
                Button(anyCollapsed ? "Expand All Groups" : "Collapse All Groups") {
                    workspace.setAllGroupsCollapsed(!anyCollapsed, groups: groups)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.square")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Group, sort, and collapse the board")
            if boardMode == .tiles {
                Slider(value: $tileWidth, in: 88...460)
                    .frame(width: 110)
                    .help("Tile size — smaller fits more bursts on screen")
            }
            Button {
                workspace.scan(location, force: true)
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(state.isScanning || model.isBusy)
            .help("Re-read every file and rebuild the board. Disabled while a scan or job is running.")
            Button {
                workspace.regroupBursts(location)
            } label: {
                Label("Regroup Bursts", systemImage: "square.stack.3d.up")
            }
            .disabled(state.isScanning || model.isBusy || result == nil)
            .help("Re-run burst grouping on the scanned files with the current Settings sliders — Sony prefixes, the time gap, then the Vision check. Files are not re-read and nothing moves.")
            Menu {
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
                Button("Move to Trash…") {
                    workspace.trash(stackIDs: workspace.targetStackIDs(), from: location.id)
                }
                .disabled(workspace.targetStackIDs().isEmpty)
                .help("Move the selected items to the drive's Trash folder. Restorable from Settings.")
                Divider()
                Button("Remove from Unsorted List") {
                    workspace.removeUnsortedFolder(location.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    private func assignBar(orderedIDs: [String]) -> some View {
        let targets = workspace.targetStackIDs()
        return HStack(spacing: 8) {
            Text(targets.isEmpty ? "Select items to sort" : "\(targets.count) selected")
                .font(.callout.weight(.semibold))
                .frame(minWidth: 120, alignment: .leading)
            EventAssignControls(
                workspace: workspace,
                verb: "Sort into",
                canAssign: !targets.isEmpty,
                onAssign: { workspace.assign(stackIDs: targets, from: location.id, to: $0.id, orderedIDs: orderedIDs) },
                onNewEvent: { workspace.requestNewEvent(from: location.id) }
            )
            Spacer(minLength: 0)
            Button {
                workspace.unassign(stackIDs: targets, from: location.id)
            } label: {
                Label("Unsort", systemImage: "arrow.uturn.backward")
            }
            .disabled(targets.isEmpty)
            .help("Remove the selection from its event (Delete)")
            Button {
                workspace.undoLastSort()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.left")
            }
            .disabled(!workspace.canUndoSort)
            .help("Undo the last sort (Command-Z)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func board() -> some View {
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
                workspace.select(stackID: stack.id, orderedIDs: [], extend: false, toggle: false)
                previewFrameIndex = frame
                previewStackID = stack.id
            },
            onKey: { press, orderedIDs in handleKey(press, orderedIDs: orderedIDs) },
            menu: { stack in contextMenu(stack) }
        )
    }

    private func openPreview(_ stackID: String, frame: Int = 0) {
        previewFrameIndex = frame
        previewStackID = stackID
    }

    @ViewBuilder
    private func contextMenu(_ stack: OrganizeStack) -> some View {
        let targets = workspace.targetStackIDs(including: stack.id)
        Menu("Sort Into") {
            ForEach(workspace.sidebarEvents, id: \.event.id) { row in
                Button(workspace.eventTitle(row.event)) {
                    workspace.assign(stackIDs: targets, from: location.id, to: row.event.id)
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
        Menu(targets.count > 1 ? "Rotate Selection" : "Rotate Burst") {
            Button("Rotate All 90° Left") { rotate(targets, by: -1) }
            Button("Rotate All 180°") { rotate(targets, by: 2) }
            Button("Rotate All 90° Right") { rotate(targets, by: 1) }
        }
        .disabled(!stacks(for: targets).contains { !DisplayRotation.rotatableFiles(in: $0).isEmpty })
        Divider()
        Button("Preview") { openPreview(stack.id) }
        Button("Open in Photomator") {
            PhotomatorLauncher.open(urls(for: targets))
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(urls(for: targets))
        }
        Divider()
        Button("Move to Trash…") {
            workspace.trash(stackIDs: targets, from: location.id)
        }
        .help("Move to the drive's Trash folder. Restorable from Settings.")
    }

    private func urls(for ids: Set<String>) -> [URL] {
        stacks(for: ids).flatMap { $0.items.map(\.primary.url) }
    }

    private func stacks(for ids: Set<String>) -> [OrganizeStack] {
        (state.result?.stacks ?? []).filter { ids.contains($0.id) }
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

    private func applyBar(_ result: OrganizeScanResult) -> some View {
        let sorted = workspace.sortedFiles(in: result)
        return HStack(spacing: 12) {
            Image(systemName: sorted.files > 0 ? "arrow.down.doc" : "keyboard")
                .foregroundStyle(sorted.files > 0 ? Color.accentColor : .secondary)
            Text(sorted.files > 0
                ? "\(sorted.files) sorted file\(sorted.files == 1 ? "" : "s") (\(sorted.bytes.formattedBytes)) still in \(location.name). Nothing moves until you press Apply."
                : "Select items, then press 1–3, drag onto an event, or press N for a new event. Space previews a burst, E or the count badge expands it in place.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if let title = workspace.latestMoveJournalTitle {
                Button("Undo “\(title)”") { workspace.undoLastMove() }
                    .disabled(model.isBusy)
            }
            Button("Apply…") {
                workspace.prepareApply(sourceLocationID: location.id)
            }
            .buttonStyle(.borderedProminent)
            .disabled(sorted.files == 0 || model.isBusy)
            .guideHighlight(.applyButton, in: workspace)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var scanningView: some View {
        VStack(spacing: 12) {
            if let progress = state.progress, progress.total > 0 {
                ProgressView(value: progress.fraction)
                    .frame(width: 320)
                Text("\(progress.phase) · \(progress.processed.formatted()) of \(progress.total.formatted())")
            } else {
                ProgressView()
                Text(state.progress.map { "\($0.phase)\($0.processed > 0 ? " · \($0.processed.formatted()) found" : "")…" } ?? "Reading \(location.name)…")
            }
            Text("Capture times are read from each RAW header and remembered, so reopening is fast.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        guard command.isAllowedWhileTyping || !KeyboardTextFocus.isTypingInTextField() else { return }
        switch command {
        case .selectAll:
            workspace.selectStacks(ordered.map(\.id))
        case .previewSelection:
            if let id = workspace.focusedStackID ?? workspace.selectedStackIDs.first {
                openPreview(id)
            }
        case .openSelection:
            PhotomatorLauncher.open(urls(for: workspace.targetStackIDs()))
        case .revealSelection:
            NSWorkspace.shared.activateFileViewerSelecting(urls(for: workspace.targetStackIDs()))
        case .reload:
            workspace.scan(location, force: true)
        case .find:
            searchFocused = true
        case .moveSelectionToTrash:
            workspace.trash(stackIDs: workspace.targetStackIDs(), from: location.id)
        default:
            break
        }
    }
}
