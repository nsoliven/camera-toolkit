import AppKit
import CameraToolkitCore
import SwiftUI

/// The main window: unsorted folders and events on the left; the selected
/// folder's burst board or the selected event on the right. Storage
/// locations live in Settings to keep this window simple.
struct EventsRootView: View {
    @Bindable var model: DashboardModel
    @Bindable var workspace: EventsWorkspace

    var body: some View {
        let panelAlignment: Alignment = (workspace.guide?.step.prefersTop ?? false) ? .topTrailing : .bottomTrailing
        NavigationSplitView {
            EventsSidebar(model: model, workspace: workspace)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            detail
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .overlay(alignment: panelAlignment) {
            if let guide = workspace.guide {
                SetupGuidePanel(guide: guide, workspace: workspace, model: model)
                    .padding(.horizontal, 20)
                    .padding(.vertical, guide.step.prefersTop ? 70 : 40)
            }
        }
        .onAppear { workspace.start() }
        .onReceive(NotificationCenter.default.publisher(for: .cameraToolkitUndoSort)) { _ in
            workspace.undoLastSort()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cameraToolkitStorageLocationsChanged)) { _ in
            workspace.discoverDriveEvents()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cameraToolkitMediaTrashChanged)) { _ in
            for location in workspace.unsortedLocations where workspace.sources[location.id]?.result != nil {
                workspace.scan(location, force: true)
            }
        }
        .sheet(item: $workspace.newEventRequest) { request in
            EventDetailsSheet(
                title: "New Event",
                confirmTitle: request.stackIDs.isEmpty ? "Create Event" : "Create and Sort \(request.stackIDs.count)",
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
        .sheet(item: $workspace.pendingRemoval) { request in
            RemovalConfirmSheet(
                request: request,
                eventName: workspace.event(request.eventID).map { workspace.eventTitle($0) } ?? "this event",
                onCancel: { workspace.pendingRemoval = nil },
                onConfirm: { workspace.confirmRemoval(request, confirmation: $0) }
            )
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
                    Label("Guide", systemImage: "questionmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open the step-by-step setup guide")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            List(selection: Binding(
                get: { workspace.selection },
                set: { workspace.selection = $0 }
            )) {
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
                            .tag(EventsSidebarSelection.unsorted(location.id) as EventsSidebarSelection?)
                            .contentShape(Rectangle())
                            .onTapGesture { workspace.selection = .unsorted(location.id) }
                            .contextMenu {
                                Button("Rescan") { workspace.scan(location, force: true) }
                                Button("Scan for Faces (Low · Fast)") { workspace.faceScan(location) }
                                    .help("Detect and match faces on still photos. Writes only to the catalog — media is read, never touched.")
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: DashboardModel.expandedPath(location.path))])
                                }
                                Divider()
                                Button("Remove from Unsorted List") { workspace.removeUnsortedFolder(location.id) }
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
                    // Parents newest-first; each subevent sits indented under
                    // its parent — the flat row style stays the same.
                    ForEach(workspace.sidebarRows(matching: searchText), id: \.event.id) { row in
                        eventRow(row.event, depth: row.depth)
                            .tag(EventsSidebarSelection.event(row.event.id) as EventsSidebarSelection?)
                            .contentShape(Rectangle())
                            .onTapGesture { workspace.selection = .event(row.event.id) }
                            .onDrop(of: [.text], isTargeted: Binding(
                                get: { targetedEventID == row.event.id },
                                set: { hovering in
                                    if hovering {
                                        targetedEventID = row.event.id
                                    } else if targetedEventID == row.event.id {
                                        targetedEventID = nil
                                    }
                                }
                            )) { providers in
                                Task { @MainActor in
                                    var strings: [String] = []
                                    for provider in providers {
                                        if let str = try? await provider.loadItem(forTypeIdentifier: "public.utf8-plain-text") as? String {
                                            strings.append(str)
                                        } else if let data = try? await provider.loadItem(forTypeIdentifier: "public.utf8-plain-text") as? Data,
                                                  let str = String(data: data, encoding: .utf8) {
                                            strings.append(str)
                                        }
                                    }
                                    _ = workspace.handleDrop(strings, onto: row.event.id)
                                }
                                return true
                            }
                            .contextMenu {
                                Button("New Subevent…") {
                                    workspace.requestNewEvent(from: nil, parentEventID: row.event.id)
                                }
                                Button("Rename or Change Date…") {
                                    workspace.renameRequest = RenameEventRequest(eventID: row.event.id)
                                }
                                Button("Delete Empty Event", role: .destructive) {
                                    workspace.deleteEmptyEvent(row.event.id)
                                }
                                .disabled(workspace.assignmentCount(for: row.event.id) > 0)
                            }
                    }
                } header: {
                    HStack {
                        Text("Events")
                        Spacer()
                        Button {
                            workspace.requestNewEvent(from: nil)
                        } label: {
                            Label("New Event", systemImage: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Make a new event")
                    }
                }
            }
            .listStyle(.sidebar)

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
                "Transfers",
                detail: model.transferQueue?.sidebarSummary.detail
                    ?? (model.pendingTransferFileCount > 0 ? "\(model.pendingTransferFileCount) waiting" : nil),
                symbol: model.transferQueue?.state == .running ? "arrow.down.circle.fill" : "arrow.down.circle"
            ) {
                TransferQueueWindowController.shared.show(model: model)
            }
            footerButton(
                "People",
                detail: workspace.faceModelInstalled ? nil : "model missing",
                symbol: "person.2"
            ) {
                PeopleWindowController.shared.show(model: model, workspace: workspace)
            }
            footerButton("File Browser", detail: nil, symbol: "folder") {
                AppShellMode.show(.files)
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
                    Label("Start Guided Setup", systemImage: "play.circle.fill")
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
                    Button("New Event") { workspace.requestNewEvent(from: nil) }
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

struct EventDetailsSheet: View {
    let title: String
    let confirmTitle: String
    /// Candidate parents in sidebar order (the edited event and its subevents
    /// are already excluded, so a parent loop can't be picked).
    let parents: [(event: SavedCameraEvent, depth: Int)]
    let onCancel: () -> Void
    /// (name, date, storagePolicy, parentEventID) — a nil policy follows the
    /// parent's setting for a subevent, or the shared Buffer at top level.
    let onSave: (String, Date, EventStoragePolicy?, UUID?) -> Void

    @State private var name: String
    @State private var date: Date
    @State private var policy: EventStoragePolicy?
    @State private var parentEventID: UUID?
    @FocusState private var isNameFocused: Bool

    init(
        title: String,
        confirmTitle: String,
        initialName: String,
        initialDate: Date,
        initialPolicy: EventStoragePolicy?,
        initialParentEventID: UUID?,
        parents: [(event: SavedCameraEvent, depth: Int)],
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, Date, EventStoragePolicy?, UUID?) -> Void
    ) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.parents = parents
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: initialName)
        _date = State(initialValue: initialDate)
        _policy = State(initialValue: initialPolicy)
        _parentEventID = State(initialValue: initialParentEventID)
    }

    private var validation: EventNameValidation {
        EventNamePolicy.validate(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())
            Form {
                TextField("Name", text: $name, prompt: Text("Beach day, Birthday, Client shoot…"))
                    .focused($isNameFocused)
                    .onSubmit(save)
                if !name.isEmpty, let error = validation.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Inside event", selection: $parentEventID) {
                    Text("None — top level").tag(UUID?.none)
                    ForEach(parents, id: \.event.id) { row in
                        Text(String(repeating: "    ", count: row.depth) + row.event.name)
                            .tag(UUID?.some(row.event.id))
                    }
                }
                .help("A subevent's folder lives inside its parent event's folder.")
                if parentEventID == nil {
                    Picker("Keep on drive", selection: Binding(
                        get: { policy ?? .buffer },
                        set: { policy = $0 }
                    )) {
                        Text("Shared Buffer").tag(EventStoragePolicy.buffer)
                        Text("Private · NAS only").tag(EventStoragePolicy.archiveOnly)
                    }
                    .pickerStyle(.radioGroup)
                } else {
                    Picker("Keep on drive", selection: $policy) {
                        Text("Same as parent").tag(EventStoragePolicy?.none)
                        Text("Shared Buffer").tag(EventStoragePolicy?.some(.buffer))
                        Text("Private · NAS only").tag(EventStoragePolicy?.some(.archiveOnly))
                    }
                    .pickerStyle(.radioGroup)
                }
                Text(policyHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validation.isValid)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { isNameFocused = true }
    }

    private var policyHelp: String {
        let shared = "Originals go into the shared Camera Buffer, where anyone browsing the drive can see them."
        let private_ = "Originals never enter the shared Buffer. They wait in a hidden folder on the drive until they are archived to the NAS, and then you can take them off the drive."
        if parentEventID != nil, policy == nil {
            let parent = parents.first { $0.event.id == parentEventID }?.event
            let resolved = parent.map {
                EventHierarchy.resolvedPolicy(of: $0, in: parents.map(\.event))
            } ?? .buffer
            return "Follows the parent event's setting (currently \(resolved == .buffer ? "Shared Buffer" : "Private · NAS only"))."
        }
        return (policy ?? .buffer) == .buffer ? shared : private_
    }

    private func save() {
        guard validation.isValid else { return }
        onSave(validation.normalizedName, date, policy, parentEventID)
    }
}

struct ApplyPlanSheet: View {
    let plan: OrganizeApplyPlan
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plan.title)
                .font(.title2.bold())
            Text(summary)
                .foregroundStyle(.secondary)
            List(plan.groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        EventChip(event: group.event, isPrivate: group.isPrivate)
                        Text(group.event.eventDate.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(group.byteCount.formattedBytes)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(line(for: group))
                        .font(.callout)
                    Text(group.destinationFolder)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 220)
            Label(
                "Moves on the same drive are instant renames. Copies from another drive are checksum-verified and leave the originals in place. Nothing is overwritten, and Undo can move files back.",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 540)
    }

    private var summary: String {
        var parts: [String] = []
        if plan.moveCount > 0 {
            parts.append("\(plan.moveCount) instant move\(plan.moveCount == 1 ? "" : "s")")
        }
        if plan.copyCount > 0 {
            parts.append("\(plan.copyCount) verified cop\(plan.copyCount == 1 ? "y" : "ies")")
        }
        let events = plan.groups.count { !$0.moves.isEmpty || !$0.copies.isEmpty }
        return parts.joined(separator: " and ") + " · \(plan.byteCount.formattedBytes) into \(events) event\(events == 1 ? "" : "s")"
    }

    private func line(for group: OrganizeApplyPlan.EventGroup) -> String {
        [
            group.moves.isEmpty ? nil : "\(group.moves.count) move on this drive",
            group.copyFileCount == 0 ? nil : "\(group.copyFileCount) copy from another drive",
            group.alreadyThere == 0 ? nil : "\(group.alreadyThere) already there",
            group.unavailable == 0 ? nil : "\(group.unavailable) on a disconnected drive",
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

struct RemovalConfirmSheet: View {
    let request: RemovalRequest
    let eventName: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.kind == .drive ? "Take \(eventName) off the drive?" : "Free up the source for \(eventName)?")
                .font(.title2.bold())
            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(request.fileCount) file\(request.fileCount == 1 ? "" : "s") · \(request.byteCount.formattedBytes)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            TextField("Type \(VerifiedRemovalService.confirmationToken) to continue", text: $confirmation)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(request.kind == .drive ? "Verify and Take Off Drive" : "Verify and Remove from Source", role: .destructive) {
                    onConfirm(confirmation)
                }
                .disabled(confirmation != VerifiedRemovalService.confirmationToken)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var explanation: String {
        switch request.kind {
        case .drive:
            "Camera Toolkit re-hashes every drive copy against its NAS copy. Only if all of them match, the drive copies move into the hidden _Trash folder on the same drive. They stay recoverable there until you empty it in Settings."
        case .source:
            "Camera Toolkit re-hashes every file on the card or unsorted folder against its drive copy. Only if all of them match, the source originals are permanently deleted. The drive copies stay."
        }
    }
}
