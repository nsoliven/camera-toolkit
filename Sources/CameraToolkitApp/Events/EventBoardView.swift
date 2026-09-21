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
    @AppStorage("CameraToolkit.organize.order") private var sortOrder: OrganizeBoardOrder = .oldestFirst
    @State private var previewStackID: String?
    @State private var previewFrameIndex = 0

    /// Grouping that makes sense inside one event — every stack belongs to
    /// it, so "by event" would be a single useless section.
    private static let groupings: [OrganizeBoardGrouping] = [.day, .kind]

    private var effectiveGrouping: OrganizeBoardGrouping {
        Self.groupings.contains(grouping) ? grouping : .day
    }

    private var boardGroups: [OrganizeBoardGroup] {
        OrganizeBoardPlan.groups(
            for: workspace.eventStacks[eventID] ?? [],
            grouping: effectiveGrouping,
            order: sortOrder
        )
    }

    var body: some View {
        if let event = workspace.event(eventID) {
            let stacks = workspace.eventStacks[eventID]
            let groups = boardGroups
            let ordered = groups
                .filter { !workspace.collapsedGroupIDs.contains($0.id) }
                .flatMap(\.stacks)
            VStack(spacing: 0) {
                header(event)
                StorageStrip(model: model, workspace: workspace, event: event, summary: workspace.presence[eventID])
                    .guideHighlight(.storageStrip, in: workspace)
                if stacks != nil {
                    if groups.isEmpty {
                        emptyState(event)
                    } else {
                        board(groups: groups)
                    }
                } else {
                    ProgressView("Checking every copy of \(event.name)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                OrganizeStatusLine(model: model, workspace: workspace)
            }
            .overlay {
                if previewStackID != nil {
                    StackPreviewOverlay(
                        workspace: workspace,
                        stacks: ordered,
                        stackID: $previewStackID,
                        excludedEventID: eventID,
                        assignVerb: "Move to",
                        eventForStack: { _ in event },
                        onAssign: { stack, target in
                            workspace.moveStacks([stack.id], fromEvent: eventID, toEvent: target.id)
                        },
                        onNewEvent: { stack in
                            workspace.requestNewEvent(stackIDs: [stack.id], movingFromEvent: eventID, suggestedDate: stack.captureDate)
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
            .task(id: "\(eventID.uuidString)-\(workspace.assignmentCount(for: eventID))-\(workspace.resolvedPolicy(for: event).rawValue)") {
                await workspace.refreshEvent(eventID)
            }
            .onReceive(NotificationCenter.default.publisher(for: BrowserCommand.notification)) { notification in
                guard let raw = notification.object as? String, let command = BrowserCommand(rawValue: raw) else { return }
                handle(command, ordered: ordered)
            }
        } else {
            ContentUnavailableView("Event Not Found", systemImage: "calendar.badge.exclamationmark")
        }
    }

    private func header(_ event: SavedCameraEvent) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(EventPalette.color(for: event.id))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.eventTitle(event))
                    .font(.title2.bold())
                    .lineLimit(1)
                Text("\(event.eventDate.formatted(date: .complete, time: .omitted)) · \(workspace.assignmentCount(for: eventID)) files · \(workspace.assignmentBytes(for: eventID).formattedBytes)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                let people = workspace.eventPeople(eventID)
                if !people.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(people.prefix(6)) { person in
                            PersonChip(person: person)
                        }
                        if people.count > 6 {
                            Text("+\(people.count - 6) more")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
            Picker("Keep on drive", selection: Binding(
                get: { workspace.resolvedPolicy(for: event) },
                set: { workspace.setPolicy(eventID, $0) }
            )) {
                Label("Shared Buffer", systemImage: "externaldrive").tag(EventStoragePolicy.buffer)
                Label("Private · NAS only", systemImage: "lock.fill").tag(EventStoragePolicy.archiveOnly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .help("Shared events live in the Buffer everyone browses. Private events stay hidden on the drive until they are archived to the NAS.")
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
                    ForEach(Self.groupings) { option in
                        Toggle(option.title, isOn: Binding(
                            get: { effectiveGrouping == option },
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
                let anyCollapsed = boardGroups.contains { workspace.collapsedGroupIDs.contains($0.id) }
                Button(anyCollapsed ? "Expand All Groups" : "Collapse All Groups") {
                    workspace.setAllGroupsCollapsed(!anyCollapsed, groups: boardGroups)
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
                Task { await workspace.refreshEvent(eventID) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Menu {
                Button("New Subevent…") {
                    workspace.requestNewEvent(from: nil, parentEventID: eventID)
                }
                Button("Rename or Change Date…") {
                    workspace.renameRequest = RenameEventRequest(eventID: eventID)
                }
                Button("Reveal Drive Folder") {
                    reveal(workspace.locations.eventFolder(for: event, policy: workspace.resolvedPolicy(for: event)))
                }
                Button("Reveal NAS Folder") {
                    let layout = workspace.locations.layout(for: event, deviceID: nil)
                    var url = workspace.locations.libraryRoot
                        .appendingPathComponent("Originals", isDirectory: true)
                        .appendingPathComponent(layout.year, isDirectory: true)
                    for folder in layout.parentEventFolders {
                        url.appendPathComponent(folder, isDirectory: true)
                    }
                    reveal(url.appendingPathComponent(layout.eventFolder, isDirectory: true))
                }
                Divider()
                Button("Undo Last Move") { workspace.undoLastMove() }
                    .disabled(workspace.latestMoveJournalTitle == nil || model.isBusy)
                Button("Delete Empty Event", role: .destructive) { workspace.deleteEmptyEvent(eventID) }
                    .disabled(workspace.assignmentCount(for: eventID) > 0)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(16)
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
            isDimmed: { _ in false },
            badge: { workspace.badge(for: $0, in: eventID) },
            orientationForFile: { workspace.displayTurns(for: $0) },
            onOpen: { stack, frame in
                workspace.select(stackID: stack.id, orderedIDs: [], extend: false, toggle: false)
                previewFrameIndex = frame
                previewStackID = stack.id
            },
            onKey: { press, _ in handleKey(press) },
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
        Menu("Move to Event") {
            ForEach(workspace.sidebarEvents.map(\.event).filter { $0.id != eventID }) { event in
                Button(workspace.eventTitle(event)) {
                    workspace.moveStacks(targets, fromEvent: eventID, toEvent: event.id)
                }
            }
        }
        Button("Return to Unsorted") {
            workspace.returnToUnsorted(targets, eventID: eventID)
        }
        Divider()
        Button("Preview") { openPreview(stack.id) }
        Button("Open in Photomator") {
            PhotomatorLauncher.open(urls(for: targets))
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(urls(for: targets))
        }
    }

    private func urls(for ids: Set<String>) -> [URL] {
        (workspace.eventStacks[eventID] ?? []).filter { ids.contains($0.id) }.flatMap { $0.items.map(\.primary.url) }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty,
              let digit = press.characters.first?.wholeNumberValue,
              (1...3).contains(digit) else { return .ignored }
        let recents = workspace.assignableRecents(excluding: eventID)
        let targets = workspace.targetStackIDs()
        guard digit <= recents.count, !targets.isEmpty else { return .handled }
        workspace.moveStacks(targets, fromEvent: eventID, toEvent: recents[digit - 1].id)
        return .handled
    }

    private func handle(_ command: BrowserCommand, ordered: [OrganizeStack]) {
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
            Task { await workspace.refreshEvent(eventID) }
        default:
            break
        }
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
/// as the numbers and actions both the compact strip pills and the full
/// cards draw from.
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
/// one action that moves each place forward. Rests as a one-line summary
/// bar so the photo board gets the window; the bottom edge drags open into
/// the four full cards, and the size is remembered.
struct StorageStrip: View {
    @Bindable var model: DashboardModel
    @Bindable var workspace: EventsWorkspace
    let event: SavedCameraEvent
    let summary: EventPresenceSummary?

    @AppStorage(OrganizeChromeSizing.storageStripDefaultsKey)
    private var stripHeight = OrganizeChromeSizing.collapsedStorageStripHeight

    private var isCollapsed: Bool {
        OrganizeChromeSizing.storageStripIsCollapsed(stripHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isCollapsed {
                compactBar
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: OrganizeChromeSizing.collapsedStorageStripHeight)
            } else {
                cardsRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: OrganizeChromeSizing.coercedStorageStripHeight(stripHeight))
            }
            ChromeResizeHandle(
                orientation: .horizontal,
                value: $stripHeight,
                transform: OrganizeChromeSizing.coercedStorageStripHeight,
                onDoubleClick: toggleCollapsed,
                help: isCollapsed
                    ? "Drag down for the full storage cards — double-click toggles"
                    : "Drag to resize the storage cards — double-click collapses",
                accessibilityLabel: "Resize Storage Summary"
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func toggleCollapsed() {
        withAnimation(.easeOut(duration: 0.15)) {
            stripHeight = isCollapsed
                ? OrganizeChromeSizing.defaultExpandedStorageStripHeight
                : OrganizeChromeSizing.collapsedStorageStripHeight
        }
    }

    /// The collapsed strip: one tinted count per place, each a menu holding
    /// that place's actions, so Free Up, Put on Buffer, Check Again, and the
    /// Immich send switch stay reachable without the tall cards.
    private var compactBar: some View {
        HStack(spacing: 8) {
            compactSlot(sourceSlot)
            compactSlot(driveSlot)
            compactSlot(nasSlot)
            compactSlot(immichSlot)
            Spacer(minLength: 8)
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    stripHeight = OrganizeChromeSizing.defaultExpandedStorageStripHeight
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Show the full storage cards — or drag the bottom edge down")
        }
    }

    private func compactSlot<Actions: View>(_ slot: StorageSlot<Actions>) -> some View {
        Menu {
            Text("\(slot.title) — \(slot.detail)")
            Divider()
            slot.actions()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: slot.symbol)
                    .foregroundStyle(slot.tint)
                Text(slot.value)
                    .font(.callout.monospacedDigit())
                    .lineLimit(1)
                StorageSlotStateIcon(state: slot.state)
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(slot.title) — \(slot.detail)")
    }

    private var cardsRow: some View {
        HStack(alignment: .top, spacing: 10) {
            StorageSlotCard(slot: sourceSlot)
            StorageSlotCard(slot: driveSlot)
            StorageSlotCard(slot: nasSlot)
            StorageSlotCard(slot: immichSlot)
        }
    }

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

    private var sourceSlot: StorageSlot<some View> {
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

    private var driveSlot: StorageSlot<some View> {
        let policy = workspace.resolvedPolicy(for: event)
        let total = assets.count
        let onDrive = assets.count { $0.drive == .present }
        let onOther = assets.count { $0.otherDrive == .present }
        let needsDrive = assets.count { $0.drive != .present && ($0.otherDrive == .present || $0.isOnSeparateSource) }
        let removable = assets.count { ($0.drive == .present || $0.otherDrive == .present) && $0.archive == .present }
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
                Button(policy == .buffer ? "Put on Buffer" : "Move to Private") {
                    workspace.prepareApply(
                        eventIDs: [event.id],
                        title: policy == .buffer ? "Put \(event.name) on the Buffer" : "Move \(event.name) to Private staging"
                    )
                }
                .disabled(model.isBusy)
            }
            if removable > 0 {
                Button("Take Off Drive…") { workspace.requestRemoveFromDrive(event.id) }
                    .disabled(model.isBusy)
                    .help("Only files whose NAS copy matches byte for byte leave the drive")
            }
            if offline {
                checkAgainButton
            }
        }
    }

    private var nasSlot: StorageSlot<some View> {
        let total = assets.count
        let onNAS = assets.count { $0.archive == .present }
        let offline = summary?.archiveOffline ?? false
        let reachable = assets.count { $0.archive != .present && ($0.drive == .present || $0.otherDrive == .present || $0.source == .present) }
        return StorageSlot(
            title: "NAS",
            symbol: "server.rack",
            tint: .green,
            value: summary == nil ? "Checking…" : (offline ? "Offline" : "\(onNAS) of \(total)"),
            detail: offline
                ? "Connect the NAS share to archive"
                : (total > 0 && onNAS == total ? "Verified in Library Originals" : "\(max(total - onNAS, 0)) not archived yet"),
            state: summary == nil ? .unknown : (offline ? .offline : (total > 0 && onNAS == total ? .complete : .partial))
        ) {
            if !offline && reachable > 0 {
                Button("Archive to NAS") { workspace.archiveToNAS(event.id) }
                    .disabled(model.isBusy)
                    .help("Copy with a SHA-256 check of every file. Existing different files are never overwritten.")
            }
            if offline {
                checkAgainButton
            }
        }
    }

    private var immichSlot: StorageSlot<some View> {
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
            .controlSize(.mini)
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
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .partial:
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
        case .offline:
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange)
        case .unknown:
            EmptyView()
        }
    }
}

struct StorageSlotCard<Actions: View>: View {
    let slot: StorageSlot<Actions>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: slot.symbol)
                    .foregroundStyle(slot.tint)
                Text(slot.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                StorageSlotStateIcon(state: slot.state)
            }
            Text(slot.value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(slot.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                slot.actions()
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(slot.state == .complete ? slot.tint.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: slot.state == .complete ? 1.5 : 1)
        )
    }
}
