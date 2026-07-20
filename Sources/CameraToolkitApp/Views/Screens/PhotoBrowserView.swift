import AppKit
import CameraToolkitCore
import QuickLookUI
import SwiftUI

private struct BrowserItem: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    var url: URL
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modifiedAt: Date
    var kind: String
}

private struct BrowserFileIdentity: Hashable {
    var relativePath: String
    var size: Int64
    var modifiedSecond: Int64
}

enum EventMediaSupport {
    static let extensions: Set<String> = [
        "arw", "dng", "cr2", "cr3", "nef",
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp",
        "mp4", "mov", "m4v", "insv", "lrf", "lrv", "osv",
    ]

    static func canAssign(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}

private enum BrowserLocationKind: Hashable {
    case source(UUID)
    case workspace
    case library
    case favorite
}

private struct BrowserLocation: Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var symbol: String
    var kind: BrowserLocationKind
}

private struct PlannedFolder: Identifiable {
    enum State {
        case source
        case preview
        case willCreate
        case exists
        case verified
        case conflict

        var label: String {
            switch self {
            case .source: "ON CARD"
            case .preview: "PREVIEW"
            case .willCreate: "WILL CREATE"
            case .exists: "EXISTS"
            case .verified: "VERIFIED"
            case .conflict: "CONFLICT"
            }
        }

        var color: Color {
            switch self {
            case .source: .blue
            case .preview: .secondary
            case .willCreate: .orange
            case .exists: .blue
            case .verified: .green
            case .conflict: .red
            }
        }

        var priority: Int {
            switch self {
            case .source, .preview: 0
            case .verified, .exists: 1
            case .willCreate: 2
            case .conflict: 3
            }
        }
    }

    var id: String { path }
    var path: String
    var state: State
}

private struct ImportFolderMapping: Identifiable {
    var id: String { sourceFolder + "→" + archiveFolder }
    var sourceFolder: String
    var workspaceFolder: String
    var archiveFolder: String
    var workspaceState: PlannedFolder.State
    var archiveState: PlannedFolder.State
    var fileCount: Int
}

private struct ImportPreviewIndex {
    var folderMappings: [ImportFolderMapping]
    var destinationFoldersBySourceFile: [String: Set<String>]

    static let empty = ImportPreviewIndex(
        folderMappings: [],
        destinationFoldersBySourceFile: [:]
    )
}

struct PhotoBrowserView: View {
    @Bindable var model: DashboardModel
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var currentURL: URL
    @State private var items: [BrowserItem] = []
    @State private var selectedItemIDs: Set<String> = []
    @State private var selectedLocationID: String?
    @State private var backHistory: [URL] = []
    @State private var forwardHistory: [URL] = []
    @State private var isLoading = false
    @State private var loadingDirectoryURL: URL?
    @State private var loadedDirectoryURL: URL?
    @State private var browserError: String?
    @State private var hasRequestedImportPreview = false
    @State private var isCreatingEvent = false
    @State private var isCollectingEventFiles = false
    @State private var collectedEventFiles: [String: EventFileSelection] = [:]
    @State private var isShowingCollectedFiles = false
    @State private var previewPaneWidth: CGFloat = 390
    @State private var browserOperationLabel: String?
    @AppStorage("CameraToolkit.browserThumbnailHeight") private var thumbnailHeight = BrowserThumbnailSizing.defaultHeight
    @FocusState private var isFileTableFocused: Bool

    init(model: DashboardModel) {
        self.model = model
        let initial = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.importSourcePath), isDirectory: true)
        _columnVisibility = State(initialValue: model.isSidebarCollapsed ? .detailOnly : .all)
        _currentURL = State(initialValue: initial)
        _selectedLocationID = State(initialValue: "source-\(model.configuration.selectedImportSourceID?.uuidString ?? "selected")")
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            VStack(spacing: 0) {
                browserToolbar
                Divider()
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        fileTable
                            .frame(minWidth: 420, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
                        if let selectedPreviewURL {
                        let maximumPreviewWidth = max(260, geometry.size.width - 420 - PreviewPaneResizeHandle.width)
                        let renderedPreviewWidth = min(max(previewPaneWidth, 260), maximumPreviewWidth)
                            PreviewPaneResizeHandle(
                                previewWidth: $previewPaneWidth,
                                renderedPreviewWidth: renderedPreviewWidth,
                                maximumPreviewWidth: maximumPreviewWidth
                            )
                            CameraSelectionPreview(url: selectedPreviewURL)
                                .frame(width: renderedPreviewWidth)
                        }
                    }
                }
                Divider()
                safeImportArea
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.accentColor)
        .onAppear {
            model.matchCameraToSelectedImportSource()
        }
        .onChange(of: model.isSidebarCollapsed) { _, isCollapsed in
            let requestedVisibility: NavigationSplitViewVisibility = isCollapsed ? .detailOnly : .all
            if columnVisibility != requestedVisibility {
                columnVisibility = requestedVisibility
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            let isCollapsed = visibility == .detailOnly
            if model.isSidebarCollapsed != isCollapsed {
                model.isSidebarCollapsed = isCollapsed
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: BrowserCommand.notification)) { notification in
            guard let rawValue = notification.object as? String,
                  let command = BrowserCommand(rawValue: rawValue) else {
                return
            }
            perform(command)
        }
        .onChange(of: selectedItemIDs) { _, selection in
            guard isCollectingEventFiles else { return }
            collectItems(withIDs: selection)
        }
        .task(id: currentURL.path) {
            await loadCurrentDirectory()
        }
        .onChange(of: selectedLocationID) { _, newValue in
            guard let location = locations.first(where: { $0.id == newValue }) else { return }
            hasRequestedImportPreview = false
            if case .source(let id) = location.kind,
               let configured = model.configuration.configuredLocations.first(where: { $0.id == id }) {
                model.useConfiguredLocation(configured)
            }
            navigate(to: URL(fileURLWithPath: DashboardModel.expandedPath(location.path), isDirectory: true))
        }
        .onChange(of: model.isBusy) { wasBusy, isBusy in
            if wasBusy && !isBusy {
                Task { await loadCurrentDirectory() }
            }
        }
        .onChange(of: model.isRefreshing) { wasRefreshing, isRefreshing in
            if wasRefreshing && !isRefreshing {
                Task { await loadCurrentDirectory() }
            }
        }
        .onChange(of: isCreatingEvent) { _, isPresented in
            if isPresented {
                isFileTableFocused = false
            }
        }
        .sheet(isPresented: $isCreatingEvent) {
            NewCameraEventSheet { name, date in
                model.createEvent(named: name, on: date)
                isCreatingEvent = false
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "camera.aperture")
                    .foregroundStyle(.blue)
                Text("Locations")
                    .font(.headline)
                Spacer()
                Button(action: selectPreviousSource) {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous Camera Source")
                .help("Previous camera source (Shift-Control-Tab)")
                Button(action: selectNextSource) {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next Camera Source")
                .help("Next camera source (Control-Tab)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            List(selection: $selectedLocationID) {
                Section("Camera Sources") {
                    ForEach(sourceLocations) { location in
                        locationRow(location)
                    }
                }

                Section("Workspace") {
                    ForEach(workspaceLocations) { location in
                        locationRow(location)
                    }
                }

                Section("Photo Library") {
                    ForEach(libraryLocations) { location in
                        locationRow(location)
                    }
                }

                Section("Favorites") {
                    ForEach(favoriteLocations) { location in
                        locationRow(location)
                    }
                }

                Section("Activity") {
                    sidebarActionButton(
                        title: "Transfers",
                        detail: transferSidebarDetail,
                        symbol: transferSidebarSymbol,
                        color: transferSidebarColor,
                        badge: transferSidebarBadge,
                        help: "Open the separate Transfer Queue window and see copy or checksum progress"
                    ) {
                        TransferQueueWindowController.shared.show(model: model)
                    }
                }

                Section("Tools") {
                    sidebarActionButton(
                        title: "Speed Tests",
                        detail: model.isStorageBenchmarkRunning ? "Measuring connected storage" : "Find the slowest drive or USB link",
                        symbol: "gauge.with.dots.needle.50percent",
                        color: model.isStorageBenchmarkRunning ? .blue : .secondary,
                        help: "Measure camera read speed and Buffer or library read/write speed in a separate window"
                    ) {
                        StorageBenchmarkWindowController.shared.show(model: model)
                    }

                    sidebarActionButton(
                        title: "Events",
                        detail: "Browse \(model.savedEvents.count) saved event\(model.savedEvents.count == 1 ? "" : "s")",
                        symbol: "calendar.badge.clock",
                        color: .blue,
                        help: "Open the Event Library in a separate window"
                    ) {
                        EventLibraryWindowController.shared.show(model: model)
                    }

                    sidebarActionButton(
                        title: "Photo Database",
                        detail: "Files, locations, and read-only SQL",
                        symbol: "cylinder.split.1x2",
                        color: .secondary,
                        help: "Open the photo database and read-only SQL inspector in a separate window"
                    ) {
                        CatalogInspectorWindowController.shared.show(model: model)
                    }

                    sidebarActionButton(
                        title: "Keyboard Shortcuts",
                        detail: "See every app shortcut",
                        symbol: "keyboard",
                        color: .secondary,
                        help: "Open the keyboard shortcut reference in a separate window"
                    ) {
                        KeyboardShortcutsWindowController.shared.show()
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            VStack(spacing: 2) {
                Button {
                    chooseAnyFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }

                Button {
                    CameraToolkitConfigWindow.shared.show(model: model)
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .help("Open Camera Toolkit settings (Command-,)")
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }

    @ViewBuilder
    private func locationRow(_ location: BrowserLocation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: location.symbol)
                .foregroundStyle(locationColor(location))
                .frame(width: 18)
            Text(location.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            Circle()
                .fill(folderExists(location.path) ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
                .help(folderExists(location.path) ? "Connected" : "Not mounted")
        }
        .tag(location.id)
    }

    private func sidebarActionButton(
        title: String,
        detail: String,
        symbol: String,
        color: Color,
        badge: String? = nil,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.12), in: Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(title), \(detail)")
    }

    private var transferSidebarDetail: String {
        model.transferQueue?.sidebarSummary.detail ?? "Nothing running"
    }

    private var transferSidebarBadge: String? {
        model.transferQueue?.sidebarSummary.badge
    }

    private var transferSidebarSymbol: String {
        switch model.transferQueue?.state {
        case .running: "arrow.down.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case nil: "arrow.down.circle"
        }
    }

    private var transferSidebarColor: Color {
        switch model.transferQueue?.state {
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .cancelled, nil: .secondary
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 8) {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(backHistory.isEmpty)
            .help("Back")

            Button(action: goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(forwardHistory.isEmpty)
            .help("Forward")

            Button(action: goUp) {
                Image(systemName: "chevron.up")
            }
            .disabled(currentURL.path == "/")
            .help("Enclosing Folder")

            Divider().frame(height: 18)

            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(currentURL.lastPathComponent.isEmpty ? currentURL.path : currentURL.lastPathComponent)
                    .font(.headline)
                Text(currentURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                isCollectingEventFiles.toggle()
                if isCollectingEventFiles {
                    collectItems(withIDs: selectedItemIDs)
                }
            } label: {
                Label(
                    isCollectingEventFiles ? "Selecting Across Folders" : "Select Across Folders",
                    systemImage: isCollectingEventFiles ? "checkmark.circle.fill" : "plus.circle"
                )
                .foregroundStyle(isCollectingEventFiles ? Color.accentColor : Color.primary)
            }
            .accessibilityLabel(isCollectingEventFiles ? "Stop Collecting Event Photos" : "Select Across Folders")
            .help(isCollectingEventFiles
                ? "Selection mode is on — click photos, then browse to another folder"
                : "Start selecting photos across multiple folders")

            if !collectedEventFiles.isEmpty {
                Button {
                    isShowingCollectedFiles = true
                } label: {
                    Text("\(collectedEventFiles.count)")
                        .font(.caption.bold().monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                .accessibilityLabel("Show \(collectedEventFiles.count) Collected Photos")
                .help("Review photos collected across folders")
                .popover(isPresented: $isShowingCollectedFiles, arrowEdge: .bottom) {
                    CollectedEventFilesView(
                        selections: collectedSelections,
                        onRemove: removeCollectedSelection,
                        onClear: clearCollectedSelections,
                        onDone: {
                            isCollectingEventFiles = false
                            isShowingCollectedFiles = false
                        }
                    )
                }
            }

            Divider().frame(height: 18)

            if !isCurrentImportSource {
                Button("Import This Folder") {
                    model.useFolderAsImportSource(currentURL)
                }
                .help("Use this folder as the camera source for the safe import below")
            }

            Button {
                createFolder()
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("New Folder")

            Button {
                previewSelection()
            } label: {
                Label("Preview", systemImage: "eye")
            }
            .disabled(selectedURLs.isEmpty)
            .help("Preview in Camera Toolkit (Space)")

            Button {
                revealSelection()
            } label: {
                Label("Show in Finder", systemImage: "arrow.right.circle")
            }
            .disabled(selectedURLs.isEmpty)
            .help("Reveal in Finder")

            Button {
                Task { await loadCurrentDirectory() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
            .help("Reload")

            Menu {
                Button("Larger Thumbnails") {
                    increaseThumbnailSize()
                }
                .disabled(thumbnailHeight >= BrowserThumbnailSizing.presets.last ?? thumbnailHeight)

                Button("Smaller Thumbnails") {
                    decreaseThumbnailSize()
                }
                .disabled(thumbnailHeight <= BrowserThumbnailSizing.presets.first ?? thumbnailHeight)

                Divider()

                ForEach(BrowserThumbnailSizing.presets, id: \.self) { height in
                    Button {
                        thumbnailHeight = height
                    } label: {
                        if abs(thumbnailHeight - height) < 0.5 {
                            Label("\(Int(height)) pt", systemImage: "checkmark")
                        } else {
                            Text("\(Int(height)) pt")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "photo.on.rectangle")
                    Text("Thumbnails \(Int(thumbnailHeight))")
                        .font(.caption.monospacedDigit())
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Thumbnail Size, \(Int(thumbnailHeight)) Points")
            .help("Thumbnail size: \(Int(thumbnailHeight)) pt (Command-Plus / Command-Minus)")

        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var fileTable: some View {
        let previewIndex = hasRequestedImportPreview && !model.isBusy
            ? importPreviewIndex
            : .empty
        let eventIndex = currentEventAssignmentIndex
        return Group {
            if isLoading && items.isEmpty {
                ProgressView("Loading \(currentURL.lastPathComponent)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contextMenu { browserBackgroundContextMenu }
            } else if let browserError {
                ContentUnavailableView(
                    "Folder Unavailable",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(browserError)
                )
                .contextMenu { browserBackgroundContextMenu }
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text(currentURL.path)
                )
                .contextMenu { browserBackgroundContextMenu }
            } else {
                Table(items, selection: $selectedItemIDs) {
                    TableColumn("Name") { item in
                        HStack(spacing: 7) {
                            if isCollectingEventFiles,
                               eventSelection(for: item) != nil {
                                Button {
                                    toggleCollectedItem(item)
                                } label: {
                                    Image(systemName: isCollected(item) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isCollected(item) ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(isCollected(item) ? "Remove from Event Selection" : "Add to Event Selection")
                                .help(isCollected(item) ? "Remove from event selection" : "Add to event selection")
                            }
                            if item.isDirectory {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.blue)
                                    .frame(
                                        width: BrowserThumbnailSizing.width(for: thumbnailHeight),
                                        height: thumbnailHeight
                                    )
                            } else {
                                CameraFileThumbnail(
                                    url: item.url,
                                    fallbackSymbol: fileSymbol(item.url),
                                    height: thumbnailHeight
                                )
                            }
                            Text(item.name)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .width(min: 180, ideal: 250, max: 300)

                    TableColumn("Date Modified") { item in
                        Text(item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 130, ideal: 160, max: 180)

                    TableColumn("Size") { item in
                        Text(item.isDirectory ? "—" : item.size.formattedBytes)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 70, ideal: 80, max: 90)

                    TableColumn("Kind") { item in
                        Text(item.kind)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 80, ideal: 90, max: 105)

                    TableColumn("Event") { item in
                        if item.isDirectory {
                            Text("—")
                                .foregroundStyle(.tertiary)
                        } else if isCollected(item) {
                            Label("Selected", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        } else if let identity = fileIdentity(for: item),
                                  let event = eventIndex[identity] {
                            Label(event.name, systemImage: "calendar.badge.checkmark")
                                .font(.caption)
                                .foregroundStyle(.blue)
                                .lineLimit(1)
                        } else {
                            Text("Unassigned")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 100, ideal: 135, max: 180)

                    TableColumn("Import To") { item in
                        if !hasRequestedImportPreview {
                            Text("Preview Import to see destination")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else if model.isBusy {
                            Label("Calculating…", systemImage: "arrow.triangle.branch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            inlineImportDestination(for: item, index: previewIndex)
                        }
                    }
                    .width(min: 330, ideal: 430)
                }
                .alternatingRowBackgrounds(.enabled)
                .contextMenu(forSelectionType: String.self) { selection in
                    browserContextMenu(for: selection)
                } primaryAction: { selection in
                    guard selection.count == 1,
                          let id = selection.first,
                          let item = items.first(where: { $0.id == id }) else {
                        return
                    }
                    open(item)
                }
                .focused($isFileTableFocused)
                .onAppear {
                    Task { @MainActor in
                        await Task.yield()
                        isFileTableFocused = true
                    }
                }
                .onKeyPress(.space) {
                    guard isFileTableFocused else { return .ignored }
                    previewSelection()
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard isFileTableFocused else { return .ignored }
                    selectAdjacentItem(offset: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard isFileTableFocused else { return .ignored }
                    selectAdjacentItem(offset: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard isFileTableFocused else { return .ignored }
                    openSelection()
                    return .handled
                }
                .overlay(alignment: .topTrailing) {
                    if isLoading || browserOperationLabel != nil {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(browserOperationLabel ?? "Loading folder…")
                                .font(.caption)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var browserBackgroundContextMenu: some View {
        Button {
            createFolder()
        } label: {
            Label("New Folder…", systemImage: "folder.badge.plus")
        }
        .disabled(browserOperationLabel != nil)

        Divider()

        Button {
            selectedItemIDs = Set(items.map(\.id))
        } label: {
            Label("Select All", systemImage: "checkmark.circle")
        }
        .disabled(items.isEmpty)

        Button {
            NSWorkspace.shared.open(currentURL)
        } label: {
            Label("Open Current Folder in Finder", systemImage: "finder")
        }

        Divider()

        Button {
            Task { await loadCurrentDirectory() }
        } label: {
            Label("Reload", systemImage: "arrow.clockwise")
        }
        .disabled(isLoading)
    }

    @ViewBuilder
    private func browserContextMenu(for selection: Set<String>) -> some View {
        let selectedItems = items.filter { selection.contains($0.id) }

        if selectedItems.isEmpty {
            browserBackgroundContextMenu
        } else {
            if selectedItems.count == 1, let item = selectedItems.first {
                Button {
                    open(item)
                } label: {
                    Label(item.isDirectory ? "Open" : "Open File", systemImage: item.isDirectory ? "folder" : "arrow.up.forward.app")
                }

                if !item.isDirectory, CameraPreviewSupport.canDecode(item.url) {
                    Button {
                        CameraPreviewController.shared.preview(previewableURLs, startingAt: item.url)
                    } label: {
                        Label("Preview in Camera Toolkit", systemImage: "eye")
                    }

                    Button {
                        PhotomatorLauncher.open(item.url)
                    } label: {
                        Label("Open in Photomator", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }

                Divider()

                Button {
                    rename(item)
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                .disabled(browserOperationLabel != nil)
            }

            Button {
                FileClipboardWriter.copy(selectedItems.map(\.url))
            } label: {
                Label(copyMenuTitle(for: selectedItems.count), systemImage: "doc.on.doc")
            }

            let assignableSelections = selectedItems.compactMap(eventSelection(for:))
            if let event = model.selectedEvent, !assignableSelections.isEmpty {
                Button {
                    model.assignFilesToSelectedEvent(assignableSelections)
                } label: {
                    Label(
                        "Assign \(assignableSelections.count) to \(event.name)",
                        systemImage: "calendar.badge.plus"
                    )
                }
            }

            Divider()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url))
            } label: {
                Label("Reveal in Finder", systemImage: "finder")
            }
        }
    }

    private func copyMenuTitle(for count: Int) -> String {
        count == 1 ? "Copy" : "Copy \(count) Items"
    }

    private var safeImportArea: some View {
        VStack(spacing: 0) {
            if let job = model.activeJob, job.action != .ingestCard {
                HStack(spacing: 10) {
                    ProgressView(value: job.progress)
                        .frame(width: 140)
                    Text(job.note)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    if job.totalBytes > 0 {
                        Text("\(job.processedBytes.formattedBytes) of \(job.totalBytes.formattedBytes)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                Divider()
            }
            eventControls
            if model.selectedEvent != nil {
                Divider()
                bufferDestinationRow
            }
            Divider()
            importActionRow
        }
        .background(.bar)
    }

    private var eventControls: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("1. Assign to Event")
                    .font(.headline)
                Text(eventSelectionGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 34)

            Picker("Event", selection: Binding<UUID?>(
                get: { model.configuration.selectedEventID },
                set: { id in
                    if let id { model.selectEvent(id) }
                }
            )) {
                Text("Choose an event").tag(UUID?.none)
                ForEach(model.savedEvents) { event in
                    Text("\(event.name) · \(event.eventDate.formatted(date: .abbreviated, time: .omitted))")
                        .tag(Optional(event.id))
                }
            }
            .frame(width: 250)

            Button {
                isCreatingEvent = true
            } label: {
                Label("New Event", systemImage: "plus")
            }

            Button {
                model.assignFilesToSelectedEvent(filesReadyForAssignment)
                if !collectedEventFiles.isEmpty {
                    clearCollectedSelections()
                }
            } label: {
                Label(assignmentButtonTitle, systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedEvent == nil || filesReadyForAssignment.isEmpty)

            if !collectedEventFiles.isEmpty {
                Button("Clear") {
                    clearCollectedSelections()
                }
                .help("Clear the cross-folder event selection")
            }

            Spacer()

            Picker("Camera", selection: Binding(
                get: { model.configuration.selectedDeviceID },
                set: { value in model.setDeviceID(value) }
            )) {
                Text("Generic Camera").tag("generic-camera")
                Text("Sony A7V").tag("sony-a7v")
                Text("DJI Osmo 360").tag("osmo-360")
                Text("DJI Mini 2").tag("dji-mini-2")
                Text("DJI Action 6").tag("action-6")
                Text("iPhone").tag("iphone")
            }
            .frame(width: 190)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var bufferDestinationRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.mint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Buffer Destination")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(model.expandedBufferIngestPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if model.isBufferVerifiedForArchive {
                Label("Verified", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }

            Button("Open Buffer") {
                model.openEventFolder(model.expandedBufferIngestPath)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var importActionRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("2. Copy to Buffer")
                    .font(.headline)
                Text(bufferCopyGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(hasRequestedImportPreview ? "Refresh Copy Preview" : "Preview Copy") {
                hasRequestedImportPreview = true
                model.previewSelectedEventImport()
            }
            .disabled(model.isBusy || model.selectedEventFiles.isEmpty)
            .help("Quickly compare assigned file paths and sizes; checksums run during Copy + Verify")

            Button("Copy \(model.selectedEventFiles.count) to Buffer + Verify") {
                model.copySelectedEventFilesToBuffer()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || model.selectedEventFiles.isEmpty)
            .help("Copy only the files assigned to this event into the Buffer, then checksum-verify them")

            if model.isBufferVerifiedForArchive {
                Button("Archive to Library + Verify") {
                    model.archiveBufferToLibrary()
                }
                .disabled(model.isBusy || !folderExists(model.configuration.cameraLibraryRootPath))
                .help("Optional: move the verified event copy from the Buffer into the permanent library")
            }

            Menu {
                if model.selectedEvent != nil {
                    Section("Optional Editing Folders") {
                        Button("Prepare Photomator and Export Folders") {
                            model.createSelectedEventFolders()
                        }
                        Button("Open Photomator Folder") {
                            model.openEventFolder(model.expandedBufferEditsPath)
                        }
                        Button("Open Exports") {
                            model.openEventFolder(model.expandedBufferExportsPath)
                        }
                    }

                    Divider()
                }

                Section("Full Card") {
                    Button("Preview Full Card") {
                        hasRequestedImportPreview = true
                        model.previewSafeImport()
                    }
                    Button("Copy Full Card + Verify") {
                        model.copySourceToBuffer()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("Optional editing-folder and full-card tools")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func inlineImportDestination(
        for item: BrowserItem,
        index: ImportPreviewIndex
    ) -> some View {
        let mappings = importMappings(for: item, index: index)
        if mappings.isEmpty {
            Text("Not included in this import")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            let state = destinationState(for: mappings)
            let workspaceFolders = shortFolderList(mappings.map(\.workspaceFolder))
            let archiveFolders = shortFolderList(mappings.map(\.archiveFolder))
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(state.color)
                    .font(.title3)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Buffer / \(workspaceFolders)")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Library / \(archiveFolders)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text(state.label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(state.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(state.color.opacity(0.12), in: Capsule())
            }
            .help("Temporary: \(model.expandedBufferIngestPath)/\(workspaceFolders)\nPermanent: \(archiveOriginalsBasePath)/\(archiveFolders)")
        }
    }

    private func importMappings(
        for item: BrowserItem,
        index: ImportPreviewIndex
    ) -> [ImportFolderMapping] {
        let sourceRoot = DashboardModel.expandedPath(model.configuration.importSourcePath)
        let relativeItemPath = relativePath(item.url.path, under: sourceRoot)
        guard relativeItemPath != item.url.path else { return [] }

        if item.isDirectory {
            let prefix = relativeItemPath + "/"
            return index.folderMappings.filter {
                $0.sourceFolder == relativeItemPath || $0.sourceFolder.hasPrefix(prefix)
            }
        }

        let destinationFolders = index.destinationFoldersBySourceFile[relativeItemPath] ?? []
        return index.folderMappings.filter {
            $0.sourceFolder == parentFolder(relativeItemPath)
                && destinationFolders.contains($0.archiveFolder)
        }
    }

    private func destinationState(for mappings: [ImportFolderMapping]) -> PlannedFolder.State {
        let states = mappings.flatMap { [$0.workspaceState, $0.archiveState] }
        return states.max { $0.priority < $1.priority } ?? .preview
    }

    private func shortFolderList(_ folders: [String]) -> String {
        let unique = Array(Set(folders)).sorted()
        guard unique.count > 2 else { return unique.joined(separator: ", ") }
        return "\(unique[0]), \(unique[1]) +\(unique.count - 2)"
    }

    private var archiveOriginalsRelativePath: String {
        let layout = OrganizedArchiveLayout(configuration: model.configuration)
        return ["Originals", layout.year, layout.eventFolder, layout.deviceFolder].joined(separator: "/")
    }

    private var archiveOriginalsBasePath: String {
        URL(fileURLWithPath: model.expandedLibraryRootPath, isDirectory: true)
            .appendingPathComponent(archiveOriginalsRelativePath, isDirectory: true)
            .path
    }

    private var importPreviewIndex: ImportPreviewIndex {
        let archiveFiles = model.organizedArchivePlan.new
            + model.organizedArchivePlan.existing
            + model.organizedArchivePlan.conflicts
        var destinationFoldersBySourceFile: [String: Set<String>] = [:]
        destinationFoldersBySourceFile.reserveCapacity(archiveFiles.count)
        for mapping in archiveFiles {
            let folder = relativePath(
                parentFolder(mapping.destinationPath),
                under: archiveOriginalsRelativePath
            )
            destinationFoldersBySourceFile[mapping.sourcePath, default: []].insert(folder)
        }
        return ImportPreviewIndex(
            folderMappings: importFolderMappings,
            destinationFoldersBySourceFile: destinationFoldersBySourceFile
        )
    }

    private var importFolderMappings: [ImportFolderMapping] {
        struct Group {
            var sourceFolder: String
            var workspaceFolder: String
            var archiveFolder: String
            var workspaceState: PlannedFolder.State
            var archiveState: PlannedFolder.State
            var fileCount: Int
        }

        let workspaceNew = Set(model.activePlan.new.map(\.path))
        let workspaceExisting = Set(model.activePlan.existing.map(\.path))
        let workspaceVerified = Set(model.activePlan.existing.filter { $0.sha256 != nil }.map(\.path))
        let workspaceConflicts = Set(model.activePlan.conflicts.map(\.path))
        let archiveNew = Set(model.organizedArchivePlan.new.map(\.sourcePath))
        let archiveExisting = Set(model.organizedArchivePlan.existing.map(\.sourcePath))
        let archiveVerified = Set(model.organizedArchivePlan.existing.filter { !$0.sha256.isEmpty }.map(\.sourcePath))
        let archiveConflicts = Set(model.organizedArchivePlan.conflicts.map(\.sourcePath))
        let archiveMappings = model.organizedArchivePlan.new
            + model.organizedArchivePlan.existing
            + model.organizedArchivePlan.conflicts

        var groups: [String: Group] = [:]
        for mapping in archiveMappings {
            let sourceFolder = parentFolder(mapping.sourcePath)
            let archiveFolder = parentFolder(mapping.destinationPath)
            let workspaceFolder = sourceFolder
            let displayedArchiveFolder = relativePath(archiveFolder, under: archiveOriginalsRelativePath)
            let workspaceState: PlannedFolder.State
            if workspaceConflicts.contains(mapping.sourcePath) {
                workspaceState = .conflict
            } else if workspaceNew.contains(mapping.sourcePath) {
                workspaceState = .willCreate
            } else if workspaceVerified.contains(mapping.sourcePath) {
                workspaceState = .verified
            } else if workspaceExisting.contains(mapping.sourcePath) {
                workspaceState = .exists
            } else {
                workspaceState = .exists
            }
            let archiveState: PlannedFolder.State
            if archiveConflicts.contains(mapping.sourcePath) {
                archiveState = .conflict
            } else if archiveNew.contains(mapping.sourcePath) {
                archiveState = .willCreate
            } else if archiveVerified.contains(mapping.sourcePath) {
                archiveState = .verified
            } else if archiveExisting.contains(mapping.sourcePath) {
                archiveState = .exists
            } else {
                archiveState = .exists
            }
            let key = sourceFolder + "→" + displayedArchiveFolder
            if var group = groups[key] {
                group.fileCount += 1
                if workspaceState.priority > group.workspaceState.priority { group.workspaceState = workspaceState }
                if archiveState.priority > group.archiveState.priority { group.archiveState = archiveState }
                groups[key] = group
            } else {
                groups[key] = Group(
                    sourceFolder: sourceFolder,
                    workspaceFolder: workspaceFolder,
                    archiveFolder: displayedArchiveFolder,
                    workspaceState: workspaceState,
                    archiveState: archiveState,
                    fileCount: 1
                )
            }
        }

        return groups.values.map {
            ImportFolderMapping(
                sourceFolder: $0.sourceFolder,
                workspaceFolder: $0.workspaceFolder,
                archiveFolder: $0.archiveFolder,
                workspaceState: $0.workspaceState,
                archiveState: $0.archiveState,
                fileCount: $0.fileCount
            )
        }.sorted {
            if $0.sourceFolder == $1.sourceFolder { return $0.archiveFolder < $1.archiveFolder }
            return $0.sourceFolder < $1.sourceFolder
        }
    }

    private func parentFolder(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
    }

    private func relativePath(_ path: String, under root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private var locations: [BrowserLocation] {
        sourceLocations + workspaceLocations + libraryLocations + favoriteLocations
    }

    private var sourceLocations: [BrowserLocation] {
        let configured = model.configuration.locations(role: .importSource)
        var chosen: [String: ConfiguredLocation] = [:]
        var order: [String] = []
        for location in configured {
            let key = sourceGroupKey(location.path)
            if chosen[key] == nil {
                order.append(key)
                chosen[key] = location
            } else if location.id == model.configuration.selectedImportSourceID {
                chosen[key] = location
            }
        }
        return order.compactMap { chosen[$0] }.map {
            BrowserLocation(
                id: "source-\($0.id.uuidString)",
                name: sourceDisplayName($0),
                path: $0.path,
                symbol: sourceSymbol($0),
                kind: .source($0.id)
            )
        }
    }

    private var workspaceLocations: [BrowserLocation] {
        [
            BrowserLocation(
                id: "workspace",
                name: "Buffer",
                path: model.configuration.bufferPath,
                symbol: "externaldrive.fill",
                kind: .workspace
            )
        ]
    }

    private var libraryLocations: [BrowserLocation] {
        let root = URL(fileURLWithPath: model.configuration.cameraLibraryRootPath, isDirectory: true)
        return [
            BrowserLocation(id: "library-originals", name: "Library Originals", path: root.appendingPathComponent("Originals").path, symbol: "photo.stack.fill", kind: .library),
            BrowserLocation(id: "library-edited", name: "Library Edited", path: root.appendingPathComponent("Edited").path, symbol: "slider.horizontal.3", kind: .library)
        ]
    }

    private var favoriteLocations: [BrowserLocation] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            BrowserLocation(id: "home", name: "Home", path: home.path, symbol: "house.fill", kind: .favorite),
            BrowserLocation(id: "pictures", name: "Pictures", path: home.appendingPathComponent("Pictures", isDirectory: true).path, symbol: "photo.fill", kind: .favorite)
        ]
    }

    private var selectedURLs: [URL] {
        items.filter { selectedItemIDs.contains($0.id) }.map(\.url)
    }

    private var selectedPreviewURL: URL? {
        guard selectedItemIDs.count == 1,
              let item = items.first(where: { selectedItemIDs.contains($0.id) }),
              !item.isDirectory,
              CameraPreviewSupport.canDecode(item.url) else {
            return nil
        }
        return item.url
    }

    private var selectedEventFileSelections: [EventFileSelection] {
        items
            .filter { selectedItemIDs.contains($0.id) }
            .compactMap(eventSelection(for:))
    }

    private var collectedSelections: [EventFileSelection] {
        collectedEventFiles.values.sorted {
            if $0.sourceRootPath == $1.sourceRootPath {
                return $0.file.path.localizedStandardCompare($1.file.path) == .orderedAscending
            }
            return $0.sourceRootPath.localizedStandardCompare($1.sourceRootPath) == .orderedAscending
        }
    }

    private var filesReadyForAssignment: [EventFileSelection] {
        collectedEventFiles.isEmpty ? selectedEventFileSelections : collectedSelections
    }

    private var assignmentButtonTitle: String {
        if collectedEventFiles.isEmpty {
            return "Assign \(selectedEventFileSelections.count) to Event"
        }
        return "Assign \(collectedEventFiles.count) Collected to Event"
    }

    private var eventSelectionGuidance: String {
        if isCollectingEventFiles {
            return "Selection mode on · click photos, browse folders, and keep collecting"
        }
        if !collectedEventFiles.isEmpty {
            let folderCount = Set(collectedSelections.map { selection in
                selection.sourceRootPath + "\u{0}" + URL(fileURLWithPath: selection.file.path).deletingLastPathComponent().path
            }).count
            return "\(collectedEventFiles.count) file(s) collected across \(folderCount) folder(s)"
        }
        if model.selectedEvent == nil {
            return "Choose an existing event or create a new one"
        }
        if !filesReadyForAssignment.isEmpty {
            return "\(filesReadyForAssignment.count) selected · ready to assign"
        }
        if !selectedItemIDs.isEmpty {
            return "The selected rows are folders or unsupported file types"
        }
        if !model.selectedEventFiles.isEmpty {
            return "\(model.selectedEventFiles.count) assigned · ready to copy to Buffer"
        }
        return "Select files in the list above, then assign them"
    }

    private var bufferCopyGuidance: String {
        if model.selectedEvent == nil {
            return "Choose an event and assign files first"
        }
        if model.selectedEventFiles.isEmpty {
            return "Nothing will move until files are assigned above"
        }
        if model.isBufferVerifiedForArchive {
            return "Verified in Buffer · the camera files remain untouched"
        }
        return "\(model.selectedEventFiles.count) assigned file(s) · camera stays untouched"
    }

    private var previewableURLs: [URL] {
        items.compactMap { item in
            guard !item.isDirectory, CameraPreviewSupport.canDecode(item.url) else { return nil }
            return item.url
        }
    }

    private func fileRecord(for item: BrowserItem) -> FileRecord? {
        guard !item.isDirectory else { return nil }
        let sourceRoot = URL(
            fileURLWithPath: DashboardModel.expandedPath(model.configuration.importSourcePath),
            isDirectory: true
        ).standardizedFileURL.path
        let relative = relativePath(item.url.standardizedFileURL.path, under: sourceRoot)
        guard relative != item.url.standardizedFileURL.path,
              (try? PathSafety.validateRelativePath(relative)) != nil else {
            return nil
        }
        return FileRecord(path: relative, size: item.size, modifiedAt: item.modifiedAt)
    }

    private func fileIdentity(for item: BrowserItem) -> BrowserFileIdentity? {
        guard let file = fileRecord(for: item) else { return nil }
        return BrowserFileIdentity(
            relativePath: file.path,
            size: file.size,
            modifiedSecond: Int64(file.modifiedAt.timeIntervalSinceReferenceDate.rounded())
        )
    }

    private var currentEventAssignmentIndex: [BrowserFileIdentity: SavedCameraEvent] {
        let root = URL(
            fileURLWithPath: DashboardModel.expandedPath(model.configuration.importSourcePath),
            isDirectory: true
        ).standardizedFileURL.path
        let eventsByID = Dictionary(uniqueKeysWithValues: model.savedEvents.map { ($0.id, $0) })
        var result: [BrowserFileIdentity: SavedCameraEvent] = [:]
        for assignment in model.configuration.photoEventAssignments where
            URL(fileURLWithPath: assignment.sourceRootPath, isDirectory: true).standardizedFileURL.path == root {
            guard let event = eventsByID[assignment.eventID] else { continue }
            result[BrowserFileIdentity(
                relativePath: assignment.relativePath,
                size: assignment.fileSize,
                modifiedSecond: Int64(assignment.modifiedAt.timeIntervalSinceReferenceDate.rounded())
            )] = event
        }
        return result
    }

    private func eventSelection(for item: BrowserItem) -> EventFileSelection? {
        guard EventMediaSupport.canAssign(item.url) else { return nil }
        guard let file = fileRecord(for: item) else { return nil }
        return EventFileSelection(
            sourceRootPath: URL(
                fileURLWithPath: DashboardModel.expandedPath(model.configuration.importSourcePath),
                isDirectory: true
            ).standardizedFileURL.path,
            file: file
        )
    }

    private func isCollected(_ item: BrowserItem) -> Bool {
        guard let selection = eventSelection(for: item) else { return false }
        return collectedEventFiles[selection.id] != nil
    }

    private func collectItems(withIDs ids: Set<String>) {
        for item in items where ids.contains(item.id) {
            guard let selection = eventSelection(for: item) else { continue }
            collectedEventFiles[selection.id] = selection
        }
    }

    private func toggleCollectedItem(_ item: BrowserItem) {
        guard let selection = eventSelection(for: item) else { return }
        if collectedEventFiles.removeValue(forKey: selection.id) == nil {
            collectedEventFiles[selection.id] = selection
        }
        isFileTableFocused = true
    }

    private func removeCollectedSelection(_ selection: EventFileSelection) {
        collectedEventFiles.removeValue(forKey: selection.id)
    }

    private func clearCollectedSelections() {
        collectedEventFiles.removeAll()
        isCollectingEventFiles = false
        isShowingCollectedFiles = false
    }

    private var isCurrentImportSource: Bool {
        currentURL.standardizedFileURL.path == URL(
            fileURLWithPath: DashboardModel.expandedPath(model.configuration.importSourcePath),
            isDirectory: true
        ).standardizedFileURL.path
    }

    @MainActor
    private func loadCurrentDirectory() async {
        let url = currentURL.standardizedFileURL
        guard loadingDirectoryURL?.standardizedFileURL != url else { return }

        let isRefreshingCurrentDirectory = loadedDirectoryURL?.standardizedFileURL == url
        loadingDirectoryURL = url
        isLoading = true
        browserError = nil
        if !isRefreshingCurrentDirectory {
            items = []
            selectedItemIDs.removeAll()
        }

        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .isHiddenKey]
                let urls = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                )
                return try urls.compactMap { child -> BrowserItem? in
                    let values = try child.resourceValues(forKeys: keys)
                    guard values.isDirectory == true || values.isRegularFile == true else { return nil }
                    return BrowserItem(
                        url: child,
                        name: child.lastPathComponent,
                        isDirectory: values.isDirectory == true,
                        size: Int64(values.fileSize ?? 0),
                        modifiedAt: values.contentModificationDate ?? .distantPast,
                        kind: values.isDirectory == true ? "Folder" : (values.localizedTypeDescription ?? child.pathExtension.uppercased())
                    )
                }
                .sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }.value
            guard currentURL.standardizedFileURL == url else { return }
            items = loaded
            loadedDirectoryURL = url
            if isRefreshingCurrentDirectory {
                let availableIDs = Set(loaded.map(\.id))
                selectedItemIDs.formIntersection(availableIDs)
            }
        } catch {
            guard currentURL.standardizedFileURL == url else { return }
            items = []
            browserError = error.localizedDescription
        }
        if loadingDirectoryURL?.standardizedFileURL == url {
            loadingDirectoryURL = nil
            isLoading = false
        }
    }

    private func navigate(to url: URL, recordingHistory: Bool = true) {
        let normalized = url.standardizedFileURL
        guard normalized != currentURL.standardizedFileURL else { return }
        if recordingHistory {
            backHistory.append(currentURL)
            forwardHistory.removeAll()
        }
        currentURL = normalized
    }

    private func goBack() {
        guard let destination = backHistory.popLast() else { return }
        forwardHistory.append(currentURL)
        navigate(to: destination, recordingHistory: false)
    }

    private func goForward() {
        guard let destination = forwardHistory.popLast() else { return }
        backHistory.append(currentURL)
        navigate(to: destination, recordingHistory: false)
    }

    private func goUp() {
        navigate(to: currentURL.deletingLastPathComponent())
    }

    private func selectAdjacentItem(offset: Int) {
        guard !items.isEmpty else { return }
        let selectedIndex = items.firstIndex { selectedItemIDs.contains($0.id) }
        let startingIndex = selectedIndex ?? (offset > 0 ? -1 : items.count)
        let destinationIndex = min(max(startingIndex + offset, 0), items.count - 1)
        selectedItemIDs = [items[destinationIndex].id]
        isFileTableFocused = true
    }

    private func selectPreviousSource() {
        selectAdjacentSource(offset: -1)
    }

    private func selectNextSource() {
        selectAdjacentSource(offset: 1)
    }

    private func selectAdjacentSource(offset: Int) {
        let connectedSources = sourceLocations.filter { folderExists($0.path) }
        guard !connectedSources.isEmpty else { return }
        let currentIndex = connectedSources.firstIndex { $0.id == selectedLocationID }
        let startingIndex = currentIndex ?? (offset > 0 ? -1 : 0)
        let destinationIndex = (startingIndex + offset + connectedSources.count) % connectedSources.count
        selectedLocationID = connectedSources[destinationIndex].id
    }

    private func perform(_ command: BrowserCommand) {
        switch command {
        case .copySelection:
            FileClipboardWriter.copy(selectedURLs)
        case .selectAll:
            selectedItemIDs = Set(items.map(\.id))
        case .openSelection:
            openSelection()
        case .previewSelection:
            previewSelection()
        case .revealSelection:
            revealSelection()
        case .createFolder:
            createFolder()
        case .goBack:
            goBack()
        case .goForward:
            goForward()
        case .goUp:
            goUp()
        case .previousSource:
            selectPreviousSource()
        case .nextSource:
            selectNextSource()
        case .increaseThumbnailSize:
            increaseThumbnailSize()
        case .decreaseThumbnailSize:
            decreaseThumbnailSize()
        case .reload:
            Task { await loadCurrentDirectory() }
        }
    }

    private func increaseThumbnailSize() {
        thumbnailHeight = BrowserThumbnailSizing.larger(than: thumbnailHeight)
    }

    private func decreaseThumbnailSize() {
        thumbnailHeight = BrowserThumbnailSizing.smaller(than: thumbnailHeight)
    }

    private func open(_ item: BrowserItem) {
        if item.isDirectory {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func previewSelection() {
        let selectedPreviewURL = selectedURLs.first { CameraPreviewSupport.canDecode($0) }
        CameraPreviewController.shared.preview(
            previewableURLs,
            startingAt: selectedPreviewURL
        )
    }

    private func openSelection() {
        guard selectedItemIDs.count == 1,
              let item = items.first(where: { selectedItemIDs.contains($0.id) }) else {
            return
        }
        open(item)
    }

    private func revealSelection() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedURLs)
    }

    private func chooseAnyFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Browse a Folder"
        panel.prompt = "Open"
        panel.directoryURL = currentURL
        if panel.runModal() == .OK, let url = panel.url {
            selectedLocationID = nil
            navigate(to: url)
        }
    }

    private func createFolder() {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Create a folder inside \(currentURL.lastPathComponent)."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "New Folder")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let name = BrowserItemNamePolicy.normalizedName(field.stringValue) else {
            showBrowserOperationError(
                title: "That Folder Name Can’t Be Used",
                message: "Use a name without / or : and do not use only dots."
            )
            return
        }
        let destination = currentURL.appendingPathComponent(name, isDirectory: true)
        runBrowserMutation(label: "Creating folder…", selecting: destination) {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        }
    }

    private func rename(_ item: BrowserItem) {
        let alert = NSAlert()
        alert.messageText = "Rename \(item.name)"
        alert.informativeText = "Renaming changes only the item’s name. Camera Toolkit will not read or rewrite its contents."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: item.name)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let name = BrowserItemNamePolicy.normalizedName(field.stringValue) else {
            showBrowserOperationError(
                title: "That Name Can’t Be Used",
                message: "Use a name without / or : and do not use only dots."
            )
            return
        }
        guard name != item.name else { return }

        let destination = item.url.deletingLastPathComponent().appendingPathComponent(
            name,
            isDirectory: item.isDirectory
        )
        runBrowserMutation(label: "Renaming…", selecting: destination) {
            if FileManager.default.fileExists(atPath: destination.path) {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: item.url, to: destination)
        }
    }

    private func runBrowserMutation(
        label: String,
        selecting destination: URL?,
        operation: @escaping @Sendable () throws -> Void
    ) {
        guard browserOperationLabel == nil else { return }
        browserOperationLabel = label

        Task { @MainActor in
            let errorMessage = await Task.detached(priority: .userInitiated) {
                do {
                    try operation()
                    return String?.none
                } catch {
                    return error.localizedDescription
                }
            }.value

            browserOperationLabel = nil
            if let errorMessage {
                showBrowserOperationError(title: "The File Operation Failed", message: errorMessage)
                return
            }

            await loadCurrentDirectory()
            if let destination {
                selectedItemIDs = [destination.path]
            }
        }
    }

    private func showBrowserOperationError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func folderExists(_ path: String) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: DashboardModel.expandedPath(path), isDirectory: &directory) && directory.boolValue
    }

    private func sourceDisplayName(_ location: ConfiguredLocation) -> String {
        let path = location.path.lowercased()
        if path.contains("/cameratoolkit/simulation/") { return "Safety Test Card" }
        return location.name
    }

    private func sourceGroupKey(_ path: String) -> String {
        let components = URL(fileURLWithPath: DashboardModel.expandedPath(path)).standardizedFileURL.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            return "/Volumes/\(components[2])"
        }
        return DashboardModel.expandedPath(path)
    }

    private func sourceSymbol(_ location: ConfiguredLocation) -> String {
        location.path.lowercased().contains("osmo") ? "camera.aperture" : "sdcard.fill"
    }

    private func locationColor(_ location: BrowserLocation) -> Color {
        switch location.kind {
        case .source: .blue
        case .workspace: .mint
        case .library: .orange
        case .favorite: .secondary
        }
    }

    private func fileSymbol(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "heic", "png", "tif", "tiff", "arw", "dng", "cr2", "cr3", "nef"].contains(ext) {
            return "photo"
        }
        if ["mp4", "mov", "m4v", "insv", "lrf", "lrv", "osv"].contains(ext) {
            return "film"
        }
        return "doc"
    }
}

private struct PreviewPaneResizeHandle: View {
    static let width: CGFloat = 10

    @Binding var previewWidth: CGFloat
    let renderedPreviewWidth: CGFloat
    let maximumPreviewWidth: CGFloat

    @State private var dragOriginWidth: CGFloat?
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 1)
                .fill(isHovering ? Color.accentColor : Color.primary.opacity(0.2))
                .frame(width: isHovering ? 3 : 1)
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragOriginWidth == nil {
                        dragOriginWidth = renderedPreviewWidth
                    }
                    let requestedWidth = (dragOriginWidth ?? renderedPreviewWidth) - value.translation.width
                    previewWidth = min(max(requestedWidth, 260), maximumPreviewWidth)
                }
                .onEnded { _ in
                    dragOriginWidth = nil
                }
        )
        .onHover { hovering in
            isHovering = hovering
            (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        }
        .help("Drag to resize the preview")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resize Preview")
        .accessibilityValue("\(Int(renderedPreviewWidth)) points wide")
    }
}

private struct CollectedEventFilesView: View {
    let selections: [EventFileSelection]
    let onRemove: (EventFileSelection) -> Void
    let onClear: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "photo.stack.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Event Selection")
                        .font(.headline)
                    Text("\(selections.count) photo(s) kept while you browse folders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear", role: .destructive, action: onClear)
                    .disabled(selections.isEmpty)
            }
            .padding(14)

            Divider()

            if selections.isEmpty {
                ContentUnavailableView(
                    "No Photos Selected",
                    systemImage: "plus.circle",
                    description: Text("Turn on selection mode, then click photos in any folder.")
                )
            } else {
                List(selections) { selection in
                    HStack(spacing: 10) {
                        Image(systemName: "photo")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: selection.file.path).lastPathComponent)
                                .lineLimit(1)
                            Text("\(URL(fileURLWithPath: selection.sourceRootPath).lastPathComponent) · \(selection.file.path)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(selection.file.size.formattedBytes)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button {
                            onRemove(selection)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(URL(fileURLWithPath: selection.file.path).lastPathComponent)")
                    }
                    .padding(.vertical, 3)
                }
            }

            Divider()

            HStack {
                Text("You can close this and continue in another folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done Selecting", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 390)
    }
}

private struct NewCameraEventSheet: View {
    var onCreate: (String, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var date = Date()
    @State private var hasAttemptedCreate = false
    @FocusState private var isNameFocused: Bool

    private var validation: EventNameValidation {
        EventNamePolicy.validate(name)
    }

    private var shouldShowError: Bool {
        hasAttemptedCreate || !name.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Event")
                    .font(.title2.bold())
                Text("This saves the event for reuse across camera sources and creates its buffer workspace folders.")
                    .foregroundStyle(.secondary)
            }

            Form {
                VStack(alignment: .leading, spacing: 7) {
                    TextField("Event name", text: $name, prompt: Text("Birthday, trip, client shoot…"))
                        .focused($isNameFocused)
                        .onSubmit(createEvent)

                    if shouldShowError, let errorMessage = validation.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)

                        if let suggestion = validation.suggestion {
                            Button("Use “\(suggestion)”") {
                                name = suggestion
                                isNameFocused = true
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            .accessibilityLabel("Use suggested event name \(suggestion)")
                        }
                    } else if !name.isEmpty {
                        Label("Spaces and normal punctuation are supported.", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                DatePicker("Event date", selection: $date, displayedComponents: .date)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create Event") {
                    createEvent()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            isNameFocused = true
        }
    }

    private func createEvent() {
        hasAttemptedCreate = true
        guard validation.isValid else {
            NSSound.beep()
            isNameFocused = true
            return
        }
        onCreate(validation.normalizedName, date)
    }
}

@MainActor
private final class CameraPreviewController: NSObject, QLPreviewPanelDataSource {
    static let shared = CameraPreviewController()
    private var urls: [URL] = []

    func preview(_ urls: [URL], startingAt selectedURL: URL? = nil) {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        if files.contains(where: { $0.pathExtension.lowercased() == "arw" }) {
            EmbeddedPreviewWindowController.shared.show(urls: files, startingAt: selectedURL)
            return
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        self.urls = files
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = selectedURL.flatMap { selected in
            files.firstIndex { $0.standardizedFileURL == selected.standardizedFileURL }
        } ?? 0
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}
