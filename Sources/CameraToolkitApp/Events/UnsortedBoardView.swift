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
    @State private var previewStackID: String?
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool

    private var state: UnsortedSourceState {
        workspace.sources[location.id] ?? UnsortedSourceState()
    }

    var body: some View {
        let result = state.result
        let days = result.map { workspace.visibleDays($0, hideSorted: hideSorted, matching: searchQuery) } ?? []
        let ordered = days.flatMap(\.stacks)
        let searching = !OrganizeSearch.needle(searchQuery).isEmpty

        VStack(spacing: 0) {
            header(result)
            Divider()
            if let result {
                assignBar(orderedIDs: ordered.map(\.id))
                    .guideHighlight(.assignBar, in: workspace)
                Divider()
                if days.isEmpty {
                    ContentUnavailableView(
                        searching ? "No Matches" : (hideSorted ? "Everything here is sorted" : "No photos or videos"),
                        systemImage: searching ? "magnifyingglass" : (hideSorted ? "checkmark.circle" : "photo"),
                        description: Text(searching
                            ? "Nothing in \(location.name) matches “\(searchQuery)”. Try a file name, burst, folder, or event."
                            : hideSorted
                                ? "Turn off Hide Sorted to review, or press Apply to move the files into their events."
                                : "This folder has no camera files.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    grid(days)
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
                }
                .frame(maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxHeight: .infinity)
            }
            OrganizeStatusLine(model: model)
        }
        .overlay {
            if previewStackID != nil {
                StackPreviewOverlay(
                    stacks: ordered,
                    stackID: $previewStackID,
                    quickEvents: workspace.quickEvents,
                    rootPath: result?.rootPath,
                    eventForStack: { workspace.assignedEvent(for: $0).event },
                    onAssign: { stack, event in
                        workspace.assign(stackIDs: [stack.id], from: location.id, to: event.id)
                    },
                    isPrivate: { workspace.resolvedPolicy(for: $0) == .archiveOnly },
                    onTrashItems: { items in
                        workspace.trashItems(items, from: location.id)
                    }
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
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .frame(width: 140)
                    .focused($searchFocused)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .font(.callout)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("Filter by file name, burst, folder, or event (⌘F)")
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
            Slider(value: $tileWidth, in: 140...460)
                .frame(width: 120)
                .help("Tile size")
            Button {
                workspace.scan(location, force: true)
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(state.isScanning)
            Menu {
                Button("Scan for Faces (Low · Fast)") {
                    workspace.faceScan(location)
                }
                .help("Detect and match faces on still photos. Writes only to the catalog — media is read, never touched.")
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
        guard let result else { return location.path }
        let bursts = result.stacks.count { $0.isBurst }
        let left = result.stacks.count { !workspace.isSorted($0) }
        return "\(result.stacks.count) items · \(bursts) bursts · \(result.fileCount) files · \(result.byteCount.formattedBytes) · \(result.days.count) day\(result.days.count == 1 ? "" : "s") · \(left) left to sort"
    }

    private func assignBar(orderedIDs: [String]) -> some View {
        let targets = workspace.targetStackIDs()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(targets.isEmpty ? "Select items to sort" : "\(targets.count) selected")
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 120, alignment: .leading)
                ForEach(Array(workspace.quickEvents.enumerated()), id: \.element.id) { index, event in
                    Button {
                        workspace.assign(stackIDs: targets, from: location.id, to: event.id, orderedIDs: orderedIDs)
                    } label: {
                        EventChip(event: event, number: index + 1, isPrivate: workspace.resolvedPolicy(for: event) == .archiveOnly)
                    }
                    .buttonStyle(.plain)
                    .opacity(targets.isEmpty ? 0.5 : 1)
                    .disabled(targets.isEmpty)
                    .help("Sort into \(workspace.eventTitle(event)) (press \(index + 1))")
                }
                Menu {
                    ForEach(workspace.sidebarEvents, id: \.event.id) { row in
                        Button(workspace.eventTitle(row.event)) {
                            workspace.assign(stackIDs: targets, from: location.id, to: row.event.id, orderedIDs: orderedIDs)
                        }
                    }
                } label: {
                    Label("All Events", systemImage: "calendar")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(targets.isEmpty || workspace.events.isEmpty)
                Button {
                    workspace.requestNewEvent(from: location.id)
                } label: {
                    Label("New Event…", systemImage: "plus")
                }
                .help("Create an event from the selection (N)")
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
    }

    private func grid(_ days: [OrganizeDay]) -> some View {
        OrganizeGrid(
            workspace: workspace,
            days: days,
            tileWidth: tileWidth,
            origin: .unsorted,
            containerID: location.id,
            rootPath: state.result?.rootPath,
            daySubtitle: { day in
                "\(day.stacks.count) items · \(day.frameCount) frames · \(day.byteCount.formattedBytes)"
            },
            eventForStack: { workspace.assignedEvent(for: $0) },
            isDimmed: { !hideSorted && workspace.isSorted($0) && !workspace.selectedStackIDs.contains($0.id) },
            badge: { _ in nil },
            onOpen: { stack in
                workspace.select(stackID: stack.id, orderedIDs: [], extend: false, toggle: false)
                previewStackID = stack.id
            },
            onKey: { press, orderedIDs in handleKey(press, orderedIDs: orderedIDs) },
            menu: { stack in contextMenu(stack) }
        )
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
        Divider()
        Button("Preview") { previewStackID = stack.id }
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
        (state.result?.stacks ?? []).filter { ids.contains($0.id) }.flatMap { $0.items.map(\.primary.url) }
    }

    private func applyBar(_ result: OrganizeScanResult) -> some View {
        let sorted = workspace.sortedFiles(in: result)
        return HStack(spacing: 12) {
            Image(systemName: sorted.files > 0 ? "arrow.down.doc" : "keyboard")
                .foregroundStyle(sorted.files > 0 ? Color.accentColor : .secondary)
            Text(sorted.files > 0
                ? "\(sorted.files) sorted file\(sorted.files == 1 ? "" : "s") (\(sorted.bytes.formattedBytes)) still in \(location.name). Nothing moves until you press Apply."
                : "Select items, then press 1–9, drag onto an event, or press N for a new event. Space previews a burst.")
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
        let targets = workspace.targetStackIDs()
        if press.key == .delete || press.key == .deleteForward {
            guard !targets.isEmpty else { return .ignored }
            workspace.unassign(stackIDs: targets, from: location.id)
            return .handled
        }
        guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        if press.characters.lowercased() == "n" {
            workspace.requestNewEvent(from: location.id)
            return .handled
        }
        if let digit = press.characters.first?.wholeNumberValue, (1...9).contains(digit) {
            let quick = workspace.quickEvents
            guard digit <= quick.count, !targets.isEmpty else { return .handled }
            workspace.assign(stackIDs: targets, from: location.id, to: quick[digit - 1].id, orderedIDs: orderedIDs)
            return .handled
        }
        return .ignored
    }

    private func handle(_ command: BrowserCommand, ordered: [OrganizeStack]) {
        switch command {
        case .selectAll:
            workspace.selectStacks(ordered.map(\.id))
        case .previewSelection:
            previewStackID = workspace.focusedStackID ?? workspace.selectedStackIDs.first
        case .openSelection:
            PhotomatorLauncher.open(urls(for: workspace.targetStackIDs()))
        case .revealSelection:
            NSWorkspace.shared.activateFileViewerSelecting(urls(for: workspace.targetStackIDs()))
        case .reload:
            workspace.scan(location, force: true)
        case .find:
            searchFocused = true
        default:
            break
        }
    }
}
