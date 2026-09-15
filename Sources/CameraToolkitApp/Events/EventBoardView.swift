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
    @State private var previewStackID: String?

    var body: some View {
        if let event = workspace.event(eventID) {
            let stacks = workspace.eventStacks[eventID]
            let days = stacks.map { OrganizeStacker.days(for: $0) } ?? []
            let ordered = days.flatMap(\.stacks)
            VStack(spacing: 0) {
                header(event)
                StorageStrip(model: model, workspace: workspace, event: event, summary: workspace.presence[eventID])
                    .guideHighlight(.storageStrip, in: workspace)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                Divider()
                if let stacks {
                    if stacks.isEmpty {
                        emptyState(event)
                    } else {
                        grid(days: days)
                    }
                } else {
                    ProgressView("Checking every copy of \(event.name)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                OrganizeStatusLine(model: model)
            }
            .overlay {
                if previewStackID != nil {
                    StackPreviewOverlay(
                        stacks: ordered,
                        stackID: $previewStackID,
                        quickEvents: workspace.quickEvents.filter { $0.id != eventID },
                        eventForStack: { _ in event },
                        onAssign: { stack, target in
                            workspace.moveStacks([stack.id], fromEvent: eventID, toEvent: target.id)
                        }
                    )
                }
            }
            .task(id: "\(eventID.uuidString)-\(workspace.assignmentCount(for: eventID))-\(event.resolvedStoragePolicy.rawValue)") {
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
                Text(event.name)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text("\(event.eventDate.formatted(date: .complete, time: .omitted)) · \(workspace.assignmentCount(for: eventID)) files · \(workspace.assignmentBytes(for: eventID).formattedBytes)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Keep on drive", selection: Binding(
                get: { event.resolvedStoragePolicy },
                set: { workspace.setPolicy(eventID, $0) }
            )) {
                Label("Shared Buffer", systemImage: "externaldrive").tag(EventStoragePolicy.buffer)
                Label("Private · NAS only", systemImage: "lock.fill").tag(EventStoragePolicy.archiveOnly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .help("Shared events live in the Buffer everyone browses. Private events stay hidden on the drive until they are archived to the NAS.")
            Slider(value: $tileWidth, in: 140...460)
                .frame(width: 110)
                .help("Tile size")
            Button {
                Task { await workspace.refreshEvent(eventID) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Menu {
                Button("Rename or Change Date…") {
                    workspace.renameRequest = RenameEventRequest(eventID: eventID)
                }
                Button("Reveal Drive Folder") {
                    reveal(workspace.locations.eventFolder(for: event, policy: event.resolvedStoragePolicy))
                }
                Button("Reveal NAS Folder") {
                    let layout = workspace.locations.layout(for: event, deviceID: nil)
                    reveal(workspace.locations.libraryRoot
                        .appendingPathComponent("Originals", isDirectory: true)
                        .appendingPathComponent(layout.year, isDirectory: true)
                        .appendingPathComponent(layout.eventFolder, isDirectory: true))
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
        }
        .frame(maxHeight: .infinity)
    }

    private func grid(days: [OrganizeDay]) -> some View {
        OrganizeGrid(
            workspace: workspace,
            days: days,
            tileWidth: tileWidth,
            origin: .event,
            containerID: eventID,
            daySubtitle: { day in
                "\(day.stacks.count) items · \(day.frameCount) frames · \(day.byteCount.formattedBytes)"
            },
            eventForStack: { _ in (nil, false) },
            isDimmed: { _ in false },
            badge: { workspace.badge(for: $0, in: eventID) },
            onOpen: { stack in
                workspace.select(stackID: stack.id, orderedIDs: [], extend: false, toggle: false)
                previewStackID = stack.id
            },
            onKey: { press, _ in handleKey(press) },
            menu: { stack in contextMenu(stack) }
        )
    }

    @ViewBuilder
    private func contextMenu(_ stack: OrganizeStack) -> some View {
        let targets = workspace.targetStackIDs(including: stack.id)
        Menu("Move to Event") {
            ForEach(workspace.events.filter { $0.id != eventID }) { event in
                Button(event.name) {
                    workspace.moveStacks(targets, fromEvent: eventID, toEvent: event.id)
                }
            }
        }
        Button("Return to Unsorted") {
            workspace.returnToUnsorted(targets, eventID: eventID)
        }
        Divider()
        Button("Preview") { previewStackID = stack.id }
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
              (1...9).contains(digit) else { return .ignored }
        let quick = workspace.quickEvents.filter { $0.id != eventID }
        let targets = workspace.targetStackIDs()
        guard digit <= quick.count, !targets.isEmpty else { return .handled }
        workspace.moveStacks(targets, fromEvent: eventID, toEvent: quick[digit - 1].id)
        return .handled
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

/// Source, drive, NAS, and Immich: where this event's originals are and the
/// one action that moves each place forward.
struct StorageStrip: View {
    @Bindable var model: DashboardModel
    @Bindable var workspace: EventsWorkspace
    let event: SavedCameraEvent
    let summary: EventPresenceSummary?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            sourceCard
            driveCard
            nasCard
            immichCard
        }
    }

    private var assets: [EventAssetPresence] { summary?.assets ?? [] }

    private var sourceCard: some View {
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
        return StorageSlotCard(
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
        }
    }

    private var driveCard: some View {
        let policy = event.resolvedStoragePolicy
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
        return StorageSlotCard(
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
        }
    }

    private var nasCard: some View {
        let total = assets.count
        let onNAS = assets.count { $0.archive == .present }
        let offline = summary?.archiveOffline ?? false
        let reachable = assets.count { $0.archive != .present && ($0.drive == .present || $0.otherDrive == .present || $0.source == .present) }
        return StorageSlotCard(
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
        }
    }

    private var immichCard: some View {
        let statuses = workspace.eventImmichStatuses[event.id] ?? [:]
        let present = statuses.values.count { $0.status == "present" && !$0.isTrashed }
        let albumText: String = switch event.resolvedImmichAlbumPolicy {
        case .none: "No album"
        case .event: "Album “\(event.name)”"
        case .custom: "Album “\(event.immichAlbumName ?? event.name)”"
        }
        return StorageSlotCard(
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
            .toggleStyle(.switch)
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

struct StorageSlotCard<Actions: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    let detail: String
    let state: StorageSlotState
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                stateIcon
            }
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                actions()
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(state == .complete ? tint.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: state == .complete ? 1.5 : 1)
        )
    }

    @ViewBuilder
    private var stateIcon: some View {
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
