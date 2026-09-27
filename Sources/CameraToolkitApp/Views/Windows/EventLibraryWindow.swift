import AppKit
import CameraToolkitCore
import SwiftUI

@MainActor
final class EventLibraryWindowController: NSObject, NSWindowDelegate {
    static let shared = EventLibraryWindowController()

    private var window: NSWindow?

    func show(model: DashboardModel) {
        if let window {
            CameraToolkitWindowFactory.present(window)
            return
        }

        let window = CameraToolkitWindowFactory.make(
            .eventLibrary,
            identifier: "CameraToolkitEventLibraryWindow",
            title: "Event Library",
            initialContentSize: NSSize(width: 1_260, height: 760),
            rootView: EventLibraryView(model: model)
        )
        window.delegate = self
        self.window = window
        CameraToolkitWindowFactory.present(window)
    }
}

private struct EventAssetRow: Identifiable, Sendable {
    var id: String
    var assignment: PhotoEventAssignment
    var name: String
    var sourceURL: URL
    var bufferURL: URL
    /// The NAS mirror copy.
    var archiveURL: URL
    /// The legacy NAS archive copy, for events archived before the mirror
    /// layout; presence falls back to it.
    var legacyArchiveURL: URL?
    var sourcePresence: CatalogPresenceState
    var bufferPresence: CatalogPresenceState
    var archivePresence: CatalogPresenceState

    var sourceExists: Bool { sourcePresence == .present }
    var bufferExists: Bool { bufferPresence == .present }
    var archiveExists: Bool { archivePresence == .present }

    var bestExistingURL: URL? {
        if archiveExists {
            if let legacyArchiveURL, !FileManager.default.fileExists(atPath: archiveURL.path) { return legacyArchiveURL }
            return archiveURL
        }
        if bufferExists { return bufferURL }
        if sourceExists { return sourceURL }
        return nil
    }
}

private struct EventLocationScanResult: Sendable {
    var location: CatalogAssetLocation
    var observations: [CatalogPresenceObservation]
}

private struct EventLibraryView: View {
    @Bindable var model: DashboardModel
    @State private var selectedEventID: UUID?
    @State private var selectedAssetID: String?
    @State private var rows: [EventAssetRow] = []
    @State private var immichStatuses: [String: ImmichCatalogStatus] = [:]
    @State private var isScanningLocations = false
    @State private var isCheckingImmich = false
    @State private var statusText = "Choose an event to see every saved photo location."
    @State private var customAlbumName = ""
    @State private var activeRefreshID: UUID?

    private var catalogURL: URL {
        URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
    }
    private var selectedEvent: SavedCameraEvent? {
        guard let selectedEventID else { return nil }
        return model.configuration.savedEvents.first { $0.id == selectedEventID }
    }
    private var selectedRow: EventAssetRow? { rows.first { $0.id == selectedAssetID } }

    var body: some View {
        NavigationSplitView {
            eventSidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let event = selectedEvent {
                    eventControls(event)
                    Divider()
                }
                if selectedEvent == nil {
                    ContentUnavailableView(
                        "Choose an Event",
                        systemImage: "calendar",
                        description: Text("Events collect photos from multiple folders and camera cards without moving the originals.")
                    )
                    .frame(maxHeight: .infinity)
                } else if rows.isEmpty && !isScanningLocations {
                    ContentUnavailableView(
                        "No Photos Assigned",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Use the + selection basket in the main browser, then assign those photos to this event.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    assetTable
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    selectionInspector
                    Divider()
                    statusBar
                }
                .background(.bar)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(selectedEvent.map { EventHierarchy.displayName(of: $0, in: model.configuration.savedEvents) } ?? "Event Library")
        .navigationSubtitle(windowSubtitle)
        .toolbar { toolbar }
        .task(id: selectedEventID) {
            guard selectedEventID != nil else {
                selectedEventID = model.configuration.selectedEventID ?? model.savedEvents.first?.id
                return
            }
            selectedAssetID = nil
            await refreshEvent()
        }
    }

    private var windowSubtitle: String {
        guard let event = selectedEvent else {
            return "\(model.savedEvents.count) event\(model.savedEvents.count == 1 ? "" : "s")"
        }
        return "\(event.eventDate.formatted(date: .long, time: .omitted)) · \(rows.count) assigned item\(rows.count == 1 ? "" : "s")"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isScanningLocations || isCheckingImmich {
            ToolbarItem {
                ProgressView()
                    .controlSize(.small)
                    .help(isCheckingImmich ? "Checking Immich…" : "Checking drives…")
            }
        }
        ToolbarItem {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await refreshEvent() }
            }
            .disabled(selectedEvent == nil)
            .help("Re-check every saved location of this event's photos")
        }
        ToolbarItem {
            Button {
                Task { await checkImmich() }
            } label: {
                Label(isCheckingImmich ? "Checking…" : "Check Immich", systemImage: "checkmark.icloud")
            }
            .disabled(isCheckingImmich || rows.isEmpty)
            .help("Hash local files in bounded chunks and ask Immich whether that exact content already exists. No upload is performed.")
        }
        ToolbarItem {
            Button("SQL Inspector", systemImage: "cylinder.split.1x2") {
                CatalogInspectorWindowController.shared.show(model: model)
            }
            .help("Browse the SQLite photo list, schema, and read-only SQL queries (⇧⌘I)")
        }
    }

    private var eventSidebar: some View {
        List(selection: $selectedEventID) {
            Section("Events") {
                ForEach(EventHierarchy.flattened(model.configuration.savedEvents), id: \.event.id) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.event.name)
                                .lineLimit(1)
                            Spacer()
                            Text("\(assignmentCount(for: row.event.id))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Text(row.event.eventDate.formatted(date: .abbreviated, time: .omitted))
                            Text("·")
                            Label(
                                row.event.sendsToImmich ? "Immich" : "Storage only",
                                systemImage: row.event.sendsToImmich ? "cloud" : "externaldrive"
                            )
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .padding(.leading, CGFloat(row.depth) * 14)
                    .tag(Optional(row.event.id))
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The selected event's Immich routing and its folders — settings of
    /// the event itself, above the table of its photos.
    private func eventControls(_ event: SavedCameraEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Toggle("Send to Immich", isOn: Binding(
                    get: { selectedEvent?.sendsToImmich ?? false },
                    set: { model.setEventImmichUploadEnabled(event.id, enabled: $0) }
                ))
                .toggleStyle(.switch)

                Divider().frame(height: 24)

                Picker("Album", selection: Binding(
                    get: { selectedEvent?.resolvedImmichAlbumPolicy ?? .none },
                    set: { model.setEventImmichAlbumPolicy(event.id, policy: $0) }
                )) {
                    ForEach(ImmichAlbumPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .frame(width: 210)
                .disabled(!event.sendsToImmich)

                if event.resolvedImmichAlbumPolicy == .custom {
                    TextField("Album name", text: $customAlbumName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 210)
                        .onSubmit { model.setEventImmichAlbumName(event.id, name: customAlbumName) }
                }

                Spacer()
                Text("Routing preference only · uploads remain locked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text("Event folders")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                eventFolderButton("Originals", systemImage: "camera", url: eventFolderURLs(event).originals)
                eventFolderButton("Edited", systemImage: "slider.horizontal.3", url: eventFolderURLs(event).edited)
                eventFolderButton("Library Edited", systemImage: "externaldrive", url: eventFolderURLs(event).libraryEdited)
                Spacer()
            }
        }
        .padding(14)
    }

    private var assetTable: some View {
        Table(rows, selection: $selectedAssetID) {
            TableColumn("Photo") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).lineLimit(1)
                    Text(row.assignment.relativePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 250)

            TableColumn("Camera / Folder") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceName(row.assignment.deviceID))
                    Text(URL(fileURLWithPath: row.assignment.sourceRootPath).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 125, ideal: 165)

            TableColumn("On Card") { row in
                locationBadge(row.sourcePresence, connectedTitle: "Present")
            }
            .width(90)

            TableColumn("Buffer") { row in
                locationBadge(row.bufferPresence, connectedTitle: "Copied")
            }
            .width(90)

            TableColumn("Library Originals") { row in
                locationBadge(row.archivePresence, connectedTitle: "Stored")
            }
            .width(110)

            TableColumn("Immich") { row in
                immichPolicyMenu(row)
            }
            .width(min: 125, ideal: 150)
        }
        .overlay {
            if isScanningLocations && rows.isEmpty {
                ProgressView("Checking connected locations…")
            }
        }
    }

    @ViewBuilder
    private var selectionInspector: some View {
        if let row = selectedRow {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(row.name).font(.headline)
                    Spacer()
                    if let url = row.bestExistingURL {
                        Button("Reveal Best Copy") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Open") { NSWorkspace.shared.open(url) }
                    }
                }
                HStack(spacing: 18) {
                    pathLink("Card", url: row.sourceURL, presence: row.sourcePresence)
                    pathLink("Buffer", url: row.bufferURL, presence: row.bufferPresence)
                    pathLink("Library", url: row.archiveURL, presence: row.archivePresence)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else {
            Text("Select a photo to inspect and reveal its exact paths.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    private var statusBar: some View {
        Text(statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
    }

    private func assignmentCount(for eventID: UUID) -> Int {
        model.configuration.photoEventAssignments.lazy.filter { $0.eventID == eventID }.count
    }

    private func effectiveImmichValue(for row: EventAssetRow) -> Bool {
        row.assignment.immichUploadOverride ?? selectedEvent?.sendsToImmich ?? false
    }

    @ViewBuilder
    private func immichPolicyMenu(_ row: EventAssetRow) -> some View {
        let isIncluded = effectiveImmichValue(for: row)
        Menu {
            Button("Follow event setting") { model.setAssignmentImmichOverride(row.assignment, value: nil) }
            Button("Include in Immich") { model.setAssignmentImmichOverride(row.assignment, value: true) }
            Button("Storage only") { model.setAssignmentImmichOverride(row.assignment, value: false) }
        } label: {
            if !isIncluded {
                Label("Storage only", systemImage: "externaldrive")
                    .foregroundStyle(.secondary)
            } else if let status = immichStatuses[row.id] {
                Label(
                    status.status == "present" ? (status.isTrashed ? "In trash" : "In Immich") : "Not in Immich",
                    systemImage: status.status == "present" ? (status.isTrashed ? "trash" : "checkmark.circle.fill") : "circle.dashed"
                )
                .foregroundStyle(status.status == "present" ? Color.green : Color.orange)
            } else {
                Label("Not checked", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func locationBadge(_ presence: CatalogPresenceState, connectedTitle: String) -> some View {
        switch presence {
        case .present:
            Label(connectedTitle, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.green)
        case .missing:
            Label("Missing", systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unavailable:
            Label("Offline", systemImage: "externaldrive.badge.xmark")
                .font(.caption)
                .foregroundStyle(Color.orange)
        case .unknown:
            Label("Checking", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func pathLink(_ title: String, url: URL, presence: CatalogPresenceState) -> some View {
        let exists = presence == .present
        return Button {
            if exists { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: exists ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(exists ? Color.green : Color.secondary)
                    .imageScale(.small)
                    .accessibilityLabel(exists ? "Present" : "Not present")
                Text("\(title): \(url.path)")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .help(presence == .unavailable ? "Drive is not currently available: \(url.path)" : url.path)
    }

    private func eventFolderButton(_ title: String, systemImage: String, url: URL) -> some View {
        Button {
            Task { await openEventFolder(url) }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.borderless)
        .help(url.path)
    }

    private func eventFolderURLs(_ event: SavedCameraEvent) -> (originals: URL, edited: URL, libraryEdited: URL) {
        // The shared resolver keeps subevent folders nested inside their
        // parent event folder on both the Buffer and the library.
        let locations = EventStorageLocations(configuration: model.configuration)
        let bufferEvent = locations.eventFolder(for: event, policy: .buffer)
        // The NAS mirror keeps edits inside the event folder, like the drive.
        let editedEvent = locations.nasEditedRoot(for: event)
        return (
            bufferEvent.appendingPathComponent(EventStorageLocations.originalsFolderName, isDirectory: true),
            locations.editedRoot(for: event, policy: .buffer),
            editedEvent
        )
    }

    @MainActor
    private func refreshEvent() async {
        guard let event = selectedEvent else {
            rows = []
            immichStatuses = [:]
            activeRefreshID = nil
            return
        }
        let refreshID = UUID()
        activeRefreshID = refreshID
        customAlbumName = event.immichAlbumName ?? ""
        // Presence rows written below reference the catalog's assignment
        // rows; make sure recent edits have reached it.
        model.persistCatalogStateNow()
        let configuration = model.configuration
        let configuredAssignments = configuration.photoEventAssignments.filter { $0.eventID == event.id }
        // Metadata is cheap and local. Put selectable rows on screen before any
        // database or drive work begins.
        rows = Self.resolveRows(
            event: event,
            assignments: configuredAssignments,
            configuration: configuration,
            cachedAssets: [:]
        )
        isScanningLocations = true
        statusText = "Photos ready. Loading saved location status…"
        let currentCatalogURL = catalogURL
        let catalogData = await Task.detached(priority: .utility) {
            var syncError: String?
            do {
                _ = try CatalogStore(url: currentCatalogURL).bootstrap(
                    configuration: configuration,
                    createBackup: false,
                    createLibraryFolders: false
                )
            } catch {
                syncError = error.localizedDescription
            }
            let inspector = CatalogInspector(url: currentCatalogURL)
            let assets = try? inspector.eventAssets(eventID: event.id)
            let immich = (try? inspector.immichStatuses(eventID: event.id)) ?? [:]
            return (assets: assets, immich: immich, syncError: syncError)
        }.value
        guard activeRefreshID == refreshID, selectedEventID == event.id, !Task.isCancelled else { return }

        if let catalogAssets = catalogData.assets,
           catalogData.syncError == nil || !catalogAssets.isEmpty || configuredAssignments.isEmpty {
            rows = Self.resolveRows(
                event: event,
                assignments: catalogAssets.map(\.assignment),
                configuration: configuration,
                cachedAssets: Dictionary(uniqueKeysWithValues: catalogAssets.map { ($0.id, $0) })
            )
        }
        immichStatuses = catalogData.immich
        let cachedCount = rows.count(where: { row in
            row.sourcePresence != .unknown || row.bufferPresence != .unknown || row.archivePresence != .unknown
        })
        statusText = cachedCount > 0
            ? "Showing saved status for \(cachedCount) item\(cachedCount == 1 ? "" : "s"); refreshing each drive in the background…"
            : "Photos ready. Checking each drive in the background…"

        await scanLocations(rows: rows, catalogURL: currentCatalogURL, eventID: event.id, refreshID: refreshID)
        guard activeRefreshID == refreshID, selectedEventID == event.id, !Task.isCancelled else { return }
        isScanningLocations = false
        let cardCount = rows.count(where: \.sourceExists)
        let bufferCount = rows.count(where: \.bufferExists)
        let archiveCount = rows.count(where: \.archiveExists)
        let offlineCount = rows.count(where: { row in
            row.sourcePresence == .unavailable || row.bufferPresence == .unavailable || row.archivePresence == .unavailable
        })
        let suffix = offlineCount > 0
            ? " \(offlineCount) item\(offlineCount == 1 ? " has" : "s have") an offline location; cached data was kept."
            : ""
        statusText = "Found \(cardCount) on source folders, \(bufferCount) in the buffer, and \(archiveCount) in Library Originals.\(suffix)"
    }

    @MainActor
    private func scanLocations(
        rows rowsToScan: [EventAssetRow],
        catalogURL: URL,
        eventID: UUID,
        refreshID: UUID
    ) async {
        await withTaskGroup(of: EventLocationScanResult.self) { group in
            for location in CatalogAssetLocation.allCases {
                group.addTask(priority: .utility) {
                    Self.scanLocation(location, rows: rowsToScan)
                }
            }
            for await result in group {
                guard activeRefreshID == refreshID, selectedEventID == eventID, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                apply(result.observations, for: result.location)
                do {
                    let observations = result.observations
                    try await Task.detached(priority: .utility) {
                        try CatalogInspector(url: catalogURL).savePresenceObservations(observations)
                    }.value
                } catch {
                    // The fresh in-memory result is still useful. A later
                    // refresh retries the local cache write.
                }
            }
        }
    }

    @MainActor
    private func apply(_ observations: [CatalogPresenceObservation], for location: CatalogAssetLocation) {
        let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.eventAssetID, $0.state) })
        for index in rows.indices {
            guard let state = byID[rows[index].id] else { continue }
            switch location {
            case .source: rows[index].sourcePresence = state
            case .buffer: rows[index].bufferPresence = state
            case .archive: rows[index].archivePresence = state
            }
        }
    }

    @MainActor
    private func checkImmich() async {
        guard selectedEvent != nil else { return }
        let candidates = rows.filter { effectiveImmichValue(for: $0) && $0.bestExistingURL != nil }
        guard !candidates.isEmpty else {
            statusText = "No Immich-included photos have a readable local copy to hash."
            return
        }
        isCheckingImmich = true
        statusText = "Hashing \(candidates.count) exact file\(candidates.count == 1 ? "" : "s") in 4 MB chunks…"
        do {
            let checks: [(String, String)] = try await Task.detached {
                try candidates.map { row in
                    guard let url = row.bestExistingURL else {
                        throw ToolkitError.commandFailed("No local copy exists for \(row.name)")
                    }
                    return (row.id, try FileSHA1.hexDigest(of: url))
                }
            }.value
            statusText = "Asking Immich whether those exact checksums already exist…"
            let results = try await model.checkImmichPresence(
                checks.map { ImmichChecksumQuery(id: $0.0, checksum: $0.1) }
            )
            let checksums = Dictionary(uniqueKeysWithValues: checks)
            let statuses = results.map {
                ImmichCatalogStatus(
                    eventAssetID: $0.id,
                    status: $0.isPresent ? "present" : "missing",
                    immichAssetID: $0.assetID,
                    checksumSHA1: checksums[$0.id],
                    isTrashed: $0.isTrashed
                )
            }
            let currentCatalogURL = catalogURL
            try await Task.detached {
                try CatalogInspector(url: currentCatalogURL).saveImmichStatuses(statuses)
            }.value
            immichStatuses.merge(Dictionary(uniqueKeysWithValues: statuses.map { ($0.eventAssetID, $0) })) { _, new in new }
            let present = statuses.count(where: { $0.status == "present" })
            statusText = "Immich check complete: \(present) present, \(statuses.count - present) not present. No files or albums were changed."
        } catch {
            statusText = "Immich check failed: \(error.localizedDescription)"
        }
        isCheckingImmich = false
    }

    nonisolated private static func resolveRows(
        event: SavedCameraEvent,
        assignments: [PhotoEventAssignment],
        configuration: AppConfiguration,
        cachedAssets: [String: CatalogEventAsset]
    ) -> [EventAssetRow] {
        let locations = EventStorageLocations(configuration: configuration)

        return assignments.compactMap { assignment in
            guard (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else { return nil }
            let deviceID = assignment.deviceID ?? configuration.selectedDeviceID
            let layout = locations.layout(for: event, deviceID: deviceID)
            let sourceRoot = NSString(string: assignment.sourceRootPath).expandingTildeInPath
            let sourceURL = URL(fileURLWithPath: sourceRoot, isDirectory: true)
                .appendingPathComponent(assignment.relativePath)
            let bufferURL = locations.originalsRoot(for: event, deviceID: deviceID, policy: .buffer)
                .appendingPathComponent(assignment.relativePath)
            guard let archiveRelativePath = try? layout.mirrorRelativePath(for: assignment.relativePath) else { return nil }
            let archiveURL = locations.nasRoot
                .appendingPathComponent(archiveRelativePath)
            let legacyArchiveURL = (try? layout.legacyArchiveRelativePath(for: assignment.relativePath))
                .map { locations.libraryRoot.appendingPathComponent($0) }
            let id = CatalogStore.eventAssetID(assignment)
            let cached = cachedAssets[id]
            return EventAssetRow(
                id: id,
                assignment: assignment,
                name: URL(fileURLWithPath: assignment.relativePath).lastPathComponent,
                sourceURL: sourceURL,
                bufferURL: bufferURL,
                archiveURL: archiveURL,
                legacyArchiveURL: legacyArchiveURL,
                sourcePresence: cached?.sourcePresence?.state ?? .unknown,
                bufferPresence: cached?.bufferPresence?.state ?? .unknown,
                archivePresence: cached?.archivePresence?.state ?? .unknown
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func scanLocation(
        _ location: CatalogAssetLocation,
        rows: [EventAssetRow]
    ) -> EventLocationScanResult {
        let fileManager = FileManager.default
        let mountedVolumePaths = Set(
            (fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
                .map { $0.standardizedFileURL.path }
        )
        let checkedAt = Date()
        var observations: [CatalogPresenceObservation] = []
        observations.reserveCapacity(rows.count)

        for row in rows {
            if Task.isCancelled { break }
            let url: URL
            switch location {
            case .source: url = row.sourceURL
            case .buffer: url = row.bufferURL
            case .archive: url = row.archiveURL
            }
            let state: CatalogPresenceState
            if let volumeRoot = volumeRootPath(for: url), !mountedVolumePaths.contains(volumeRoot) {
                state = .unavailable
            } else {
                state = fileManager.fileExists(atPath: url.path)
                    || (location == .archive && row.legacyArchiveURL.map { fileManager.fileExists(atPath: $0.path) } == true)
                    ? .present : .missing
            }
            observations.append(
                CatalogPresenceObservation(
                    eventAssetID: row.id,
                    location: location,
                    state: state,
                    checkedAt: checkedAt
                )
            )
        }
        return EventLocationScanResult(location: location, observations: observations)
    }

    nonisolated private static func volumeRootPath(for url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes", isDirectory: true)
            .appendingPathComponent(components[2], isDirectory: true)
            .standardizedFileURL.path
    }

    @MainActor
    private func openEventFolder(_ url: URL) async {
        let exists = await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: url.path)
        }.value
        if exists {
            NSWorkspace.shared.open(url)
        } else {
            statusText = "That event folder has not been created yet: \(url.path)"
        }
    }

    private func deviceName(_ id: String?) -> String {
        switch id {
        case "sony-a7v": "Sony A7V"
        case "osmo-360": "DJI Osmo 360"
        case "dji-mini-2": "DJI Mini 2"
        case "dji-nano": "DJI Nano"
        case "action-6": "DJI Action 6"
        case "iphone": "iPhone"
        case .some(let value): value
        case nil: "Camera"
        }
    }
}
