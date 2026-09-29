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

    /// The window's one search field. In the board scope its text is the
    /// open board's `workspace.search.text`; in the sidebar scope it
    /// narrows the sidebar's folders and events.
    @State private var searchScope: OrganizeSearchScope
    @State private var sidebarQuery = ""
    @AppStorage(EventInfoInspector.visibilityDefaultsKey) private var showInspector = false
    @FocusState private var searchFocused: Bool

    init(model: DashboardModel, workspace: EventsWorkspace) {
        self.model = model
        self.workspace = workspace
        _searchScope = State(initialValue: .defaultScope(hasBoard: workspace.selection != nil))
    }

    private var searchText: Binding<String> {
        Binding(
            get: { searchScope == .board ? workspace.search.text : sidebarQuery },
            set: { text in
                if searchScope == .board {
                    workspace.search.text = text
                } else {
                    sidebarQuery = text
                }
            }
        )
    }

    private var searchPrompt: String {
        guard searchScope == .board else { return "Search Events & Folders" }
        switch workspace.selection {
        case .event(let id):
            return workspace.event(id).map { "Search \(workspace.eventTitle($0))" } ?? "Search"
        case .unsorted(let id):
            return workspace.location(id).map { "Search \($0.name)" } ?? "Search"
        case nil:
            return "Search"
        }
    }

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
            EventsSidebar(model: model, workspace: workspace, query: searchScope == .sidebar ? sidebarQuery : "")
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
            // wider and cutting the sidebar off on the left. minHeight 0
            // does the same vertically: the split view measures this column
            // at its minimum width, where the board's top bar wraps every
            // chip and notice word onto its own line, and a column minimum
            // taller than the window made the hosting view lay the whole
            // split view out taller than the window — sidebar rows under
            // the traffic lights, the storage strip under the toolbar.
            detail
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
                // On the detail column, outside the per-board `.id`, so the
                // field keeps its text and focus across selection changes
                // and each board's toolbar can place it.
                .searchable(text: searchText, placement: .toolbar, prompt: Text(searchPrompt))
                .searchScopes($searchScope, activation: .onSearchPresentation) {
                    Text("This Board").tag(OrganizeSearchScope.board)
                    Text("Events & Folders").tag(OrganizeSearchScope.sidebar)
                }
                .searchFocused($searchFocused)
        }
        // On the split view rather than the board: inside the detail column
        // the inspector dropped the floating sidebar's safe-area inset and
        // laid the board out beneath the sidebar.
        .inspector(isPresented: inspectorPresented) {
            inspector
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        // Return hands the keyboard back to the board.
        .onSubmit(of: .search) {
            searchFocused = false
            workspace.requestBoardFocus()
        }
        // Switching scope carries the typed text over to the new target.
        .onChange(of: searchScope) { oldScope, newScope in
            let text = oldScope == .board ? workspace.search.text : sidebarQuery
            if newScope == .board {
                sidebarQuery = ""
                workspace.search.text = text
            } else {
                workspace.search.text = ""
                sidebarQuery = text
            }
        }
        // No board open: search the sidebar. Opening a board with an empty
        // field returns to searching the board.
        .onChange(of: workspace.selection) { _, selection in
            if selection == nil {
                searchScope = .sidebar
            } else if searchText.wrappedValue.isEmpty {
                searchScope = .board
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: BrowserCommand.notification)) { notification in
            guard notification.object as? String == BrowserCommand.find.rawValue,
                  BrowserCommand.targetsMainWindow() else { return }
            searchFocused = true
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
                onApply: { decisions in workspace.performApply(plan, resolving: decisions) }
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
        .sheet(item: $workspace.syncAllRequest) { _ in
            SyncAllConfirmSheet(
                workspace: workspace,
                onCancel: { workspace.syncAllRequest = nil },
                onConfirm: {
                    workspace.syncAllRequest = nil
                    workspace.syncAllToNAS()
                }
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

    /// The Event Info inspector exists only for an open event.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: {
                guard showInspector, case .event(let id) = workspace.selection else { return false }
                return workspace.event(id) != nil
            },
            set: { showInspector = $0 }
        )
    }

    @ViewBuilder
    private var inspector: some View {
        if case .event(let id) = workspace.selection, let event = workspace.event(id) {
            EventInfoInspector(model: model, workspace: workspace, event: event)
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
    /// The window search's text while it is scoped to Events & Folders.
    var query: String = ""
    @State private var targetedEventID: UUID?
    @AppStorage("CameraToolkit.organize.sidebar.unsortedExpanded") private var unsortedExpanded = true
    @AppStorage("CameraToolkit.organize.sidebar.eventsExpanded") private var eventsExpanded = true

    /// A local mirror of `workspace.selection`, synced both ways with
    /// `onChange`. Binding the AppKit-backed List straight to the model
    /// dropped writes in both directions: clicks did not always reach the
    /// model, and a selection made in the model (the guide, New Event) did
    /// not move the highlight, because nothing in the sidebar body read it.
    /// Rows also set the selection on tap as a fallback.
    @State private var listSelection: EventsSidebarSelection?

    var body: some View {
        let locations = workspace.unsortedLocations(matching: query)
        let hasLocations = !workspace.unsortedLocations.isEmpty
        List(selection: $listSelection) {
            let discovered = workspace.discoveredDriveEvents(matching: query)
            let legacyFolders = workspace.legacyLayoutFolders
            if !discovered.isEmpty || !legacyFolders.isEmpty {
                Section("Found on Your Drive") {
                    if !discovered.isEmpty {
                        discoveryBanner(discovered)
                            .guideHighlight(.discovered, in: workspace)
                    }
                    if !legacyFolders.isEmpty {
                        legacyLayoutBanner(legacyFolders)
                    }
                }
            }

            Section(isExpanded: $unsortedExpanded) {
                ForEach(locations) { location in
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
                // First run: a full-width row is a stronger guide target
                // than the header's small +.
                if !hasLocations {
                    Button {
                        workspace.addUnsortedFolder()
                    } label: {
                        Label("Add Folder or Card…", systemImage: "plus.rectangle.on.folder")
                    }
                    .buttonStyle(.borderless)
                    .guideHighlight(.addFolder, in: workspace)
                }
            } header: {
                SidebarSectionHeader(
                    title: "Unsorted",
                    addLabel: "Add Folder or Card…",
                    forceVisible: hasLocations && workspace.guide?.step.highlight == .addFolder,
                    action: { workspace.addUnsortedFolder() }
                )
                .modifier(GuideHighlightModifier(isActive: hasLocations && workspace.guide?.step.highlight == .addFolder))
            }

            Section(isExpanded: $eventsExpanded) {
                if workspace.events.isEmpty {
                    Text("No Events Yet")
                        .foregroundStyle(.secondary)
                }
                // A board popover's condition rows narrow this list —
                // events are tested against the same OR-of-AND groups.
                if workspace.search.hasActiveConditions {
                    Button {
                        workspace.search.clearConditions()
                    } label: {
                        Label("Filtered — Clear", systemImage: "line.3.horizontal.decrease.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .help("A board's filter is hiding events that don't match — click to show every event")
                }
                // Parents newest-first; each subevent sits indented under
                // its parent.
                ForEach(workspace.sidebarRows(matching: query, applying: workspace.search), id: \.event.id) { row in
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
                SidebarSectionHeader(
                    title: "Events",
                    addLabel: "New Event…",
                    action: { workspace.requestNewEvent(from: nil) }
                )
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
        .safeAreaBar(edge: .bottom) {
            SidebarFooter(model: model, workspace: workspace)
        }
    }

    /// Camera folders still in `<device>/Card Copy`. Their files keep
    /// working in the meantime; the layout migration moves them into
    /// `Originals/<Camera>` with journaled, undoable renames.
    private func legacyLayoutBanner(_ folders: [DriveCameraFolder]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(folders.count) camera folder\(folders.count == 1 ? " uses" : "s use") the old Card Copy layout.")
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Files there still show on their events. The layout migration moves them into Originals/<Camera> without copying, and can be undone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .help(folders.prefix(8).map(\.cameraFolderPath).joined(separator: "\n"))
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
        let state = workspace.sources[location.id]
        let connected = workspace.isConnected(location)
        let leftToSort = state?.result.map { result in result.stacks.count { !workspace.isSorted($0) } }
        return UnsortedSidebarRow(
            name: location.name,
            isConnected: connected,
            isScanning: state?.isScanning == true,
            leftToSort: leftToSort ?? 0,
            help: "\(workspace.unsortedDetail(for: location)) · \(DashboardModel.expandedPath(location.path))"
        )
    }

    private func eventRow(_ event: SavedCameraEvent, depth: Int) -> some View {
        let count = workspace.assignmentCount(for: event.id)
        let summary = workspace.presence[event.id]
        let names = workspace.eventPeople(event.id).map(\.name).joined(separator: ", ")
        let isPrivate = workspace.resolvedPolicy(for: event) == .archiveOnly
        var details = [
            event.eventDate.formatted(date: .abbreviated, time: .omitted),
            "\(count.formatted()) file\(count == 1 ? "" : "s")",
        ]
        if !names.isEmpty { details.append(names) }
        if let summary, summary.total > 0 {
            details.append("Drive \(summary.onDrive) of \(summary.total)")
            details.append("NAS \(summary.onArchive) of \(summary.total)")
        }
        if isPrivate { details.append("Private · NAS only") }
        // The event's own folder, so a parent and its subevents never
        // count one file twice.
        let nasTotals = workspace.nasPendingTotals(for: event.id)
        let nasPending = nasTotals?.pendingFiles ?? 0
        if let nasTotals, nasPending > 0 { details.append(NASPendingText.badgeHelp(nasTotals)) }
        return EventSidebarRow(
            name: event.name,
            color: EventPalette.color(for: event.id),
            isPrivate: isPrivate,
            fileCount: count,
            nasPending: nasPending,
            depth: depth,
            isDropTarget: targetedEventID == event.id,
            help: details.joined(separator: " · ")
        )
    }
}

/// A sidebar section title with a + that shows on hover — where Finder and
/// Music put "add" for a section.
private struct SidebarSectionHeader: View {
    let title: String
    let addLabel: String
    /// Keeps the + visible while the setup guide points at it.
    var forceVisible = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: action) {
                Label(addLabel, systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .opacity(isHovering || forceVisible ? 1 : 0)
            .help(addLabel)
            .accessibilityLabel(addLabel)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

/// One unsorted folder or card: its name, and the count still to sort as
/// the row's badge. Values only, so a row re-renders only when they change.
private struct UnsortedSidebarRow: View {
    let name: String
    let isConnected: Bool
    let isScanning: Bool
    let leftToSort: Int
    let help: String

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(name)
                    .lineLimit(1)
            } icon: {
                Image(systemName: isConnected ? "tray.full" : "externaldrive.badge.xmark")
                    .foregroundStyle(isConnected ? Color.orange : Color.secondary)
            }
            .foregroundStyle(isConnected ? Color.primary : Color.secondary)
            if isScanning {
                Spacer(minLength: 0)
                ProgressView()
                    .controlSize(.small)
            }
        }
        .badge(isScanning || !isConnected ? 0 : leftToSort)
        .help(help)
    }
}

/// One event: its palette color (a lock for private events), its name, and
/// its file count as the badge. Date, people, and drive/NAS status are in
/// the tooltip and the board's inspector.
private struct EventSidebarRow: View {
    let name: String
    let color: Color
    let isPrivate: Bool
    let fileCount: Int
    /// Files of this event not on the NAS yet; 0 shows nothing.
    var nasPending = 0
    let depth: Int
    let isDropTarget: Bool
    let help: String

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(name)
                    .lineLimit(1)
                if nasPending > 0 {
                    Spacer(minLength: 4)
                    NASPendingBadge(count: nasPending)
                }
            }
        } icon: {
            Image(systemName: isPrivate ? "lock.fill" : "circle.fill")
                .imageScale(isPrivate ? .medium : .small)
                .foregroundStyle(color)
        }
        .badge(fileCount)
        .padding(.leading, CGFloat(depth) * 14)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.accentColor.opacity(0.25) : Color.clear)
                .padding(.horizontal, -4)
                .allowsHitTesting(false)
        }
        .help(help)
    }
}

/// The sidebar's footer: Jobs (with the running job's progress) and one
/// gear menu for the windows that used to be five stacked buttons. Every
/// entry is also in the menu bar.
private struct SidebarFooter: View {
    @Bindable var model: DashboardModel
    let workspace: EventsWorkspace

    var body: some View {
        let job = model.activeJob
        let detail = job?.note
            ?? model.transferQueue?.sidebarSummary.detail
            ?? (model.pendingTransferFileCount > 0 ? "\(model.pendingTransferFileCount) waiting" : nil)
        VStack(alignment: .leading, spacing: 6) {
            NASStatusFooterRow(connection: workspace.nasConnection)
            if !model.configuration.savedEvents.isEmpty {
                NASSyncAllFooterRow(workspace: workspace)
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        TransferQueueWindowController.shared.show(model: model)
                    } label: {
                        HStack(spacing: 6) {
                            Label("Jobs", systemImage: "list.bullet.clipboard")
                                .symbolVariant(job != nil ? .fill : .none)
                            if let job {
                                ProgressView(value: job.progress)
                                    .frame(width: 44)
                            } else if let detail {
                                Text(detail)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.glass)
                    .help(detail.map { "Jobs — \($0)" } ?? "Show copy, archive, and scan jobs")
                    Spacer(minLength: 0)
                    Menu {
                        Button(workspace.faceEngineInstalled ? "People…" : "People… (Face Engine Missing)") {
                            PeopleWindowController.shared.show(model: model, workspace: workspace)
                        }
                        Button("Trash…") { TrashWindowController.shared.show(model: model) }
                        Button("Duplicates…") { DuplicatesWindowController.shared.show(model: model, workspace: workspace) }
                        Button("Storage Speed Tests…") { StorageBenchmarkWindowController.shared.show(model: model) }
                        Divider()
                        Button("Setup Guide…") { workspace.startGuide() }
                        Button("Settings…") { CameraToolkitConfigWindow.shared.show(model: model) }
                    } label: {
                        Label("More", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("People, Trash, Duplicates, Speed Tests, the setup guide, and Settings")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // The footer is the list's bottom inset; keep its height its own
        // (see NASSyncAllFooterRow) so relayouts never nudge the list.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A sidebar event's "not on the NAS yet" mark: an up arrow and the count.
private struct NASPendingBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: "arrow.up")
                .imageScale(.small)
            Text(NASPendingText.badge(count))
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .foregroundStyle(.orange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(NASPendingText.files(count)) not on the NAS")
    }
}

/// "Sync All to NAS" with what is not on the NAS yet — "312 files · 48 GB
/// not on NAS" — from the background presence index. Opens the
/// confirmation; disabled, with the reason as its help, while the NAS is
/// offline or another job runs. Reads published state only.
private struct NASSyncAllFooterRow: View {
    let workspace: EventsWorkspace

    var body: some View {
        let presence = workspace.nasPresence
        let blocker = workspace.syncAllBlocker
        let pending = presence.report?.total.pendingFiles ?? 0
        let synced = presence.report.map { $0.total.isSynced && $0.total.files > 0 } ?? false
        let detail = NASPendingText.syncAllDetail(report: presence.report, isChecking: presence.isChecking, nasAvailable: workspace.nasIsConnected)
        Button {
            workspace.requestSyncAllToNAS()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: synced ? "checkmark.circle" : "arrow.up.to.line.circle")
                    .imageScale(.large)
                    .foregroundStyle(pending > 0 ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sync All to NAS")
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if presence.isChecking {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
        // One fixed height whatever the sidebar's width mid-relayout: a
        // footer height that wobbles while the split view resizes changes
        // the list's bottom inset, and the list then scrolls a little
        // further each time (rows creeping under the traffic lights).
        .fixedSize(horizontal: false, vertical: true)
        .disabled(blocker != nil)
        .help(blocker ?? help(presence))
        .accessibilityLabel("Sync All to NAS, \(detail)")
    }

    private func help(_ presence: NASPresenceModel) -> String {
        var lines = ["Copy every event's files that are not on the NAS yet, verifying each copy's SHA-256. Existing files are never overwritten."]
        if let report = presence.report { lines.append("Counts \(NASPendingText.freshness(report, now: Date())).") }
        if let note = presence.note { lines.append(note) }
        return lines.joined(separator: "\n")
    }
}

/// Always-visible NAS line: how the share is connected and how fast it
/// last measured ("NAS · Ethernet 1 GbE · 75 MB/s"), with Connect when it
/// is offline and the Wi-Fi banner when a wired link would be faster.
/// Reads the published status only — no filesystem calls here.
private struct NASStatusFooterRow: View {
    let connection: NASConnectionModel

    var body: some View {
        let status = connection.status
        if status.phase != .notConfigured {
            VStack(alignment: .leading, spacing: 6) {
                if status.isOnSlowWiFi, status.banner != nil || status.isWaitingToReconnect {
                    NASWiFiBanner(status: status, connection: connection)
                }
                HStack(spacing: 6) {
                    Button {
                        connection.statusClicked()
                    } label: {
                        Label {
                            Text(status.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: symbol(for: status))
                                .foregroundStyle(tint(for: status))
                        }
                        .font(.caption)
                        .foregroundStyle(status.phase == .connected ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(help(for: status))
                    .accessibilityLabel(status.title)
                    Spacer(minLength: 0)
                    if status.phase == .connecting || status.phase == .reconnecting || status.isTestingSpeed {
                        ProgressView()
                            .controlSize(.mini)
                    } else if status.phase == .offline, status.hasShareURL {
                        Button("Connect") { connection.connect() }
                            .controlSize(.small)
                            .buttonStyle(.glass)
                            .help("Mount the NAS share with the password saved in your keychain (Finder asks when there is none)")
                    }
                }
            }
        }
    }

    private func symbol(for status: NASConnectionStatus) -> String {
        switch status.phase {
        case .offline, .notConfigured: return "externaldrive.badge.xmark"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .notSMB: return "externaldrive"
        case .connected:
            switch status.snapshot?.sessionKind {
            case .wifi: return "wifi.exclamationmark"
            case .ethernet: return "cable.connector"
            case .thunderbolt: return "bolt.horizontal"
            case .other, nil: return "server.rack"
            }
        }
    }

    private func tint(for status: NASConnectionStatus) -> Color {
        guard status.phase == .connected else { return .secondary }
        return status.snapshot?.sessionKind == .wifi ? .orange : .green
    }

    private func help(for status: NASConnectionStatus) -> String {
        var text = status.detail(now: Date())
        if status.phase == .connected {
            let hint = "Click to run the speed test again (at most every 30 minutes)."
            text = text.isEmpty ? hint : text + "\n" + hint
        }
        return text.isEmpty ? status.title : text
    }
}

/// "NAS is connected over Wi-Fi (slow)." with the button that waits for
/// NAS jobs to finish and then reconnects over Ethernet. Never blocks.
private struct NASWiFiBanner: View {
    let status: NASConnectionStatus
    let connection: NASConnectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("NAS is connected over Wi-Fi (slow).", systemImage: "wifi.exclamationmark")
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let reason = reasonText {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status.isWaitingToReconnect {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Waiting for NAS jobs to finish…")
                        .font(.caption)
                    Spacer(minLength: 0)
                    Button("Cancel") { connection.cancelReconnect() }
                        .controlSize(.small)
                }
            } else {
                Button("Reconnect over Ethernet") { connection.reconnectOverEthernet() }
                    .controlSize(.small)
                    .help("Waits until no job uses the NAS, then disconnects the share and mounts it again over the wired link")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var reasonText: String? {
        switch status.banner {
        case .nasInUse: "A job is using the NAS, so it was not reconnected."
        case .gaveUp: "Two reconnects did not move it to Ethernet."
        case .rateLimited: status.message
        case .automaticOff: "Automatic reconnects are off in Settings."
        case .noShareAddress: "Set the NAS share address in Settings to reconnect it."
        case nil: nil
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
                    .font(.largeTitle)
                    .imageScale(.large)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
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
                    Label("Start Guided Setup…", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)

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

                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button("Add Folder or Card…", systemImage: "plus.rectangle.on.folder") {
                            workspace.addUnsortedFolder()
                        }
                        Button("New Event…", systemImage: "calendar.badge.plus") {
                            workspace.requestNewEvent(from: nil)
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Camera Toolkit")
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
        if !workspace.isConnected(location) {
            Button("Check Again") { workspace.refreshConnectivity() }
                .help("Check again — the drive or card may have just connected")
            Divider()
        }
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
