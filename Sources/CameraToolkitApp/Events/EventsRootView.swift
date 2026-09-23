import AppKit
import CameraToolkitCore
import SwiftUI

/// The main window: unsorted folders and events on the left; the selected
/// folder's burst board or the selected event on the right. Storage
/// locations live in Settings to keep this window simple.
struct EventsRootView: View {
    @Bindable var model: DashboardModel
    @Bindable var workspace: EventsWorkspace

    /// The column's opening width, read once — a live AppStorage value here
    /// would move `ideal` during a drag and make the divider jump.
    @State private var initialSidebarWidth = OrganizeChromeSizing.storedSidebarWidth()
    @State private var measuredSidebarWidth: Double?
    /// Measured content width vs. the column width asked for: the glass
    /// sidebar can inset its content, so the first measurement sets the
    /// offset that turns later measurements back into column widths.
    @State private var sidebarWidthInset: Double?

    /// ⌘B, the View menu, and the toolbar's sidebar button all flow through
    /// `isSidebarCollapsed`, so the menu stays deterministic.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.isSidebarCollapsed ? .detailOnly : .all },
            set: { model.isSidebarCollapsed = ($0 == .detailOnly) }
        )
    }

    var body: some View {
        let panelAlignment: Alignment = (workspace.guide?.step.prefersTop ?? false) ? .topTrailing : .bottomTrailing
        NavigationSplitView(columnVisibility: columnVisibility) {
            EventsSidebar(model: model, workspace: workspace)
                .onGeometryChange(for: Double.self) { $0.size.width.rounded() } action: { width in
                    measuredSidebarWidth = width
                }
                .navigationSplitViewColumnWidth(
                    min: OrganizeChromeSizing.sidebarWidthRange.lowerBound,
                    ideal: initialSidebarWidth,
                    max: OrganizeChromeSizing.sidebarWidthRange.upperBound
                )
        } detail: {
            // minWidth 0 + clipped: a board too wide for the window is cut
            // on its own right edge instead of pushing the whole window
            // wider and cutting the sidebar off on the left.
            detail
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        // Debounced write-back of a dragged width — never a body side effect.
        .task(id: measuredSidebarWidth) {
            guard let measured = measuredSidebarWidth, measured > 0 else { return }
            if sidebarWidthInset == nil {
                sidebarWidthInset = initialSidebarWidth - measured
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled,
                  let width = OrganizeChromeSizing.persistableSidebarWidth(measured + (sidebarWidthInset ?? 0)) else { return }
            UserDefaults.standard.set(width, forKey: OrganizeChromeSizing.sidebarWidthDefaultsKey)
        }
        .overlay(alignment: panelAlignment) {
            if let guide = workspace.guide {
                SetupGuidePanel(guide: guide, workspace: workspace, model: model)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 72)
            }
        }
        .onAppear { workspace.start() }
        .onReceive(NotificationCenter.default.publisher(for: .cameraToolkitUndoSort)) { _ in
            workspace.undoLastSort()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cameraToolkitStorageLocationsChanged)) { _ in
            workspace.discoverDriveEvents()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cameraToolkitMediaTrashChanged)) { notification in
            // A move already removed those tiles. Rescanning here would
            // read every unsorted folder again, which is what a restore
            // needs and a move does not.
            if notification.userInfo?["rescanUnsorted"] as? Bool == false { return }
            for location in workspace.unsortedLocations where workspace.sources[location.id]?.result != nil {
                workspace.scan(location, force: true)
            }
        }
        .sheet(item: $workspace.newEventRequest) { request in
            EventDetailsSheet(
                title: "New Event",
                confirmTitle: "Create Event",
                initialName: "",
                initialDate: request.suggestedDate,
                initialPolicy: request.parentEventID == nil ? .buffer : nil,
                initialParentEventID: request.parentEventID,
                parents: workspace.parentCandidates(excluding: nil),
                onCancel: { workspace.newEventRequest = nil },
                onSave: { name, date, policy, parentEventID in
                    workspace.completeNewEvent(request, name: name, date: date, policy: policy, parentEventID: parentEventID)
                }
            )
        }
        .sheet(item: $workspace.renameRequest) { request in
            if let event = workspace.event(request.eventID) {
                EventDetailsSheet(
                    title: "Edit Event",
                    confirmTitle: "Save",
                    initialName: event.name,
                    initialDate: event.eventDate,
                    initialPolicy: event.storagePolicy,
                    initialParentEventID: event.parentEventID,
                    parents: workspace.parentCandidates(excluding: event.id),
                    onCancel: { workspace.renameRequest = nil },
                    onSave: { name, date, policy, parentEventID in
                        workspace.renameEvent(request.eventID, name: name, date: date, policy: policy, parentEventID: parentEventID)
                    }
                )
            }
        }
        .sheet(item: $workspace.pendingApplyPlan) { plan in
            ApplyPlanSheet(
                plan: plan,
                onCancel: { workspace.pendingApplyPlan = nil },
                onApply: { workspace.performApply(plan) }
            )
        }
        .sheet(item: $workspace.pendingTrash) { request in
            TrashConfirmSheet(
                request: request,
                onCancel: { workspace.pendingTrash = nil },
                onConfirm: { workspace.confirmTrash(request) }
            )
        }
        .sheet(item: $workspace.pendingRemoval) { request in
            RemovalConfirmSheet(
                request: request,
                eventName: workspace.event(request.eventID).map { workspace.eventTitle($0) } ?? "this event",
                onCancel: { workspace.pendingRemoval = nil },
                onConfirm: { workspace.confirmRemoval(request, confirmation: $0) }
            )
        }
        .sheet(item: $workspace.faceScanRequest) { request in
            switch request.subject {
            case .location(let locationID):
                if let location = workspace.location(locationID) {
                    FaceScanSheet(
                        name: location.name,
                        engineInstalled: workspace.faceEngineInstalled,
                        onCancel: { workspace.faceScanRequest = nil },
                        onScan: { options in
                            workspace.faceScanRequest = nil
                            workspace.faceScan(location, options: options)
                        }
                    )
                }
            case .event(let eventID):
                if let event = workspace.event(eventID) {
                    FaceScanSheet(
                        name: workspace.eventTitle(event),
                        engineInstalled: workspace.faceEngineInstalled,
                        onCancel: { workspace.faceScanRequest = nil },
                        onScan: { options in
                            workspace.faceScanRequest = nil
                            workspace.faceScan(event, options: options)
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch workspace.selection {
        case .unsorted(let id):
            if let location = workspace.location(id) {
                UnsortedBoardView(model: model, workspace: workspace, location: location)
                    .id(id)
            } else {
                EventsWelcomeView(model: model, workspace: workspace)
            }
        case .event(let id):
            EventBoardView(model: model, workspace: workspace, eventID: id)
                .id(id)
        case nil:
            EventsWelcomeView(model: model, workspace: workspace)
        }
    }
}

struct EventsSidebar: View {
    @Bindable var model: DashboardModel
    @Bindable var workspace: EventsWorkspace
    @State private var targetedEventID: UUID?
    @State private var searchText = ""

    /// A local mirror of `workspace.selection`, synced both ways with
    /// `onChange`. Binding the AppKit-backed List straight to the model
    /// dropped writes in both directions: clicks did not always reach the
    /// model, and a selection made in the model (the guide, New Event) did
    /// not move the highlight, because nothing in the sidebar body read it.
    /// Rows also set the selection on tap as a fallback.
    @State private var listSelection: EventsSidebarSelection?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.3.group")
                    .foregroundStyle(.blue)
                Text("Organize")
                    .font(.headline)
                Spacer()
                Button {
                    workspace.startGuide()
                } label: {
                    Label("Guide…", systemImage: "questionmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open the step-by-step setup guide")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            List(selection: $listSelection) {
                let discovered = workspace.discoveredDriveEvents(matching: searchText)
                if !discovered.isEmpty {
                    Section("Found on Your Drive") {
                        discoveryBanner(discovered)
                            .guideHighlight(.discovered, in: workspace)
                    }
                }

                Section("Unsorted Photos") {
                    ForEach(workspace.unsortedLocations(matching: searchText)) { location in
                        unsortedRow(location)
                            .tag(EventsSidebarSelection.unsorted(location.id))
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture().onEnded {
                                workspace.selection = .unsorted(location.id)
                            })
                            .contextMenu {
                                UnsortedSidebarMenu(location: location, workspace: workspace, model: model)
                            }
                    }
                    Button {
                        workspace.addUnsortedFolder()
                    } label: {
                        Label("Add Folder or Card…", systemImage: "plus.rectangle.on.folder")
                    }
                    .buttonStyle(.borderless)
                    .guideHighlight(.addFolder, in: workspace)
                }

                Section {
                    if workspace.events.isEmpty {
                        Text("No events yet")
                            .foregroundStyle(.secondary)
                    }
                    // A board popover's condition rows narrow this list —
                    // events are tested against the same OR-of-AND groups.
                    if workspace.search.hasActiveConditions {
                        Button {
                            workspace.search.groups = []
                        } label: {
                            Label("Filtered — clear", systemImage: "line.3.horizontal.decrease.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                        .help("A board's filter is hiding events that don't match — click to show every event")
                    }
                    // Parents newest-first; each subevent sits indented under
                    // its parent — the flat row style stays the same.
                    ForEach(workspace.sidebarRows(matching: searchText, applying: workspace.search), id: \.event.id) { row in
                        eventRow(row.event, depth: row.depth)
                            .tag(EventsSidebarSelection.event(row.event.id))
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture().onEnded {
                                workspace.selection = .event(row.event.id)
                            })
                            .dropDestination(for: String.self) { items, _ in
                                workspace.handleDrop(items, onto: row.event.id)
                            } isTargeted: { targeted in
                                if targeted {
                                    targetedEventID = row.event.id
                                } else if targetedEventID == row.event.id {
                                    targetedEventID = nil
                                }
                            }
                            .contextMenu {
                                EventSidebarMenu(event: row.event, workspace: workspace)
                            }
                    }
                } header: {
                    HStack {
                        Text("Events")
                        Spacer()
                        Button {
                            workspace.requestNewEvent(from: nil)
                        } label: {
                            Label("New Event…", systemImage: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Make a new event")
                    }
                }
            }
            .listStyle(.sidebar)
            .onAppear { listSelection = workspace.selection }
            .onChange(of: listSelection) { _, selection in
                if workspace.selection != selection { workspace.selection = selection }
            }
            .onChange(of: workspace.selection) { _, selection in
                if listSelection != selection { listSelection = selection }
            }

            Divider()
            footer
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
    }

    private func discoveryBanner(_ found: [DiscoveredDriveEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(found.count) event folder\(found.count == 1 ? " is" : "s are") on your drive but not in the list yet.")
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(found.prefix(3)) { event in
                Text("\(event.name) · \(event.files.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if found.count > 3 {
                Text("and \(found.count - 3) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Add to Events") { workspace.adoptDiscoveredDriveEvents() }
                .controlSize(.small)
                .help("Lists these folders as events. No files move.")
        }
        .padding(.vertical, 4)
    }

    private func unsortedRow(_ location: ConfiguredLocation) -> some View {
        let connected = workspace.isConnected(location)
        return HStack(spacing: 8) {
            Image(systemName: connected ? "tray.full" : "externaldrive.badge.xmark")
                .foregroundStyle(connected ? Color.orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(location.name)
                    .lineLimit(1)
                Text(workspace.unsortedDetail(for: location))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if workspace.sources[location.id]?.isScanning == true {
                ProgressView()
                    .controlSize(.mini)
            } else if !connected {
                Button {
                    workspace.refreshConnectivity()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .help("Check again — the drive or card may have just connected")
            }
        }
        .padding(.vertical, 2)
    }

    private func eventRow(_ event: SavedCameraEvent, depth: Int = 0) -> some View {
        let count = workspace.assignmentCount(for: event.id)
        let summary = workspace.presence[event.id]
        let names = workspace.eventPeople(event.id).map(\.name).joined(separator: ", ")
        return HStack(spacing: 8) {
            Circle()
                .fill(EventPalette.color(for: event.id))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.name)
                    .lineLimit(1)
                Text("\(event.eventDate.formatted(date: .abbreviated, time: .omitted)) · \(count) file\(count == 1 ? "" : "s")\(names.isEmpty ? "" : " · \(names)")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if workspace.resolvedPolicy(for: event) == .archiveOnly {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .help("Private · NAS only")
            }
            if let summary, summary.total > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(summary.onDrive == summary.total ? Color.green : Color.secondary.opacity(0.5))
                    Image(systemName: "server.rack")
                        .foregroundStyle(summary.onArchive == summary.total ? Color.green : Color.secondary.opacity(0.5))
                }
                .font(.caption2)
                .help("Drive \(summary.onDrive) of \(summary.total) · NAS \(summary.onArchive) of \(summary.total)")
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .padding(.leading, CGFloat(depth) * 16)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(targetedEventID == event.id ? Color.accentColor.opacity(0.25) : Color.clear)
                .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            footerButton(
                "Jobs…",
                detail: model.activeJob?.note
                    ?? model.transferQueue?.sidebarSummary.detail
                    ?? (model.pendingTransferFileCount > 0 ? "\(model.pendingTransferFileCount) waiting" : nil),
                symbol: model.activeJob != nil ? "list.bullet.clipboard.fill" : "list.bullet.clipboard"
            ) {
                TransferQueueWindowController.shared.show(model: model)
            }
            footerButton(
                "People…",
                detail: workspace.faceEngineInstalled ? nil : "engine missing",
                symbol: "person.2"
            ) {
                PeopleWindowController.shared.show(model: model, workspace: workspace)
            }
            footerButton("Trash…", detail: nil, symbol: "trash") {
                TrashWindowController.shared.show(model: model)
            }
            footerButton("Speed Tests…", detail: nil, symbol: "gauge.with.dots.needle.50percent") {
                StorageBenchmarkWindowController.shared.show(model: model)
            }
            footerButton("Settings…", detail: nil, symbol: "gearshape") {
                CameraToolkitConfigWindow.shared.show(model: model)
            }
        }
        .buttonStyle(.plain)
        .padding(12)
    }

    private func footerButton(_ title: String, detail: String?, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}

struct EventsWelcomeView: View {
    @Bindable var model: DashboardModel
    @Bindable var workspace: EventsWorkspace

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 52))
                    .foregroundStyle(.blue)
                    .padding(.top, 40)
                Text("Welcome to Camera Toolkit")
                    .font(.largeTitle.bold())
                Text("Sort your photos into events, then keep each event on your drive, your NAS, and Immich.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)

                Button {
                    workspace.startGuide()
                } label: {
                    Label("Start Guided Setup…", systemImage: "play.circle.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("It checks your drives, finds your unsorted photos, and walks you through sorting your first burst. Nothing moves or gets deleted without a plan you confirm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Where your photos go")
                            .font(.headline)
                        PlacesExplainer()
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 600)

                HStack {
                    Button("Add Folder or Card…") { workspace.addUnsortedFolder() }
                    Button("New Event…") { workspace.requestNewEvent(from: nil) }
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The Unsorted row's context menu, in its own view so its buttons are
/// built when the menu opens instead of on every sidebar render — a row
/// that never gets right-clicked never pays for them.
private struct UnsortedSidebarMenu: View {
    let location: ConfiguredLocation
    let workspace: EventsWorkspace
    let model: DashboardModel

    var body: some View {
        Button("Rescan") { workspace.scan(location, force: true) }
            .disabled(workspace.sources[location.id]?.isScanning == true || model.isBusy)
        Button("Regroup Bursts") { workspace.regroupBursts(location) }
            .disabled(workspace.sources[location.id]?.isScanning == true || model.isBusy || workspace.sources[location.id]?.result == nil)
            .help("Re-run burst grouping on the scanned files with the current Settings sliders — files are not re-read.")
        Button("Scan for Faces…") { workspace.requestFaceScan(location) }
            .disabled(workspace.faceScanBlocker(for: location) != nil)
            .help(workspace.faceScanBlocker(for: location)
                ?? "Detect and match faces on a sample of each burst — not every frame. Writes only to the catalog — media is read, never touched.")
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: DashboardModel.expandedPath(location.path))])
        }
        Divider()
        Button("Remove from Unsorted List") { workspace.removeUnsortedFolder(location.id) }
    }
}

/// The event row's context menu — same deferral, plus the one legitimate
/// Face Scan kick: opening the menu is when the check that unlocks the
/// item should start, so `prepareFaceScanStatus` runs here and never on
/// a row render (at launch that swept every event just to draw the list).
private struct EventSidebarMenu: View {
    let event: SavedCameraEvent
    let workspace: EventsWorkspace

    var body: some View {
        Button("New Subevent…") {
            workspace.requestNewEvent(from: nil, parentEventID: event.id)
        }
        Button("Rename or Change Date…") {
            workspace.renameRequest = RenameEventRequest(eventID: event.id)
        }
        Button("Scan for Faces…") { workspace.requestFaceScan(event) }
            .disabled(workspace.faceScanBlocker(for: event) != nil)
            .help(workspace.faceScanBlocker(for: event)
                ?? "Detect and match faces on a sample of each burst — not every frame. Writes only to the catalog — media is read, never touched.")
        Button("Delete Empty Event", role: .destructive) {
            workspace.deleteEmptyEvent(event.id)
        }
        .disabled(workspace.assignmentCount(for: event.id) > 0)
        .task { workspace.prepareFaceScanStatus(for: event) }
    }
}
