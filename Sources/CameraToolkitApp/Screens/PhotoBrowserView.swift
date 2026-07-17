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
    @State private var currentURL: URL
    @State private var items: [BrowserItem] = []
    @State private var selectedItemIDs: Set<String> = []
    @State private var selectedLocationID: String?
    @State private var backHistory: [URL] = []
    @State private var forwardHistory: [URL] = []
    @State private var isLoading = false
    @State private var browserError: String?
    @State private var hasRequestedImportPreview = false

    init(model: DashboardModel) {
        self.model = model
        let initial = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.importSourcePath), isDirectory: true)
        _currentURL = State(initialValue: initial)
        _selectedLocationID = State(initialValue: "source-\(model.configuration.selectedImportSourceID?.uuidString ?? "selected")")
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 270)
        } detail: {
            VStack(spacing: 0) {
                browserToolbar
                Divider()
                fileTable
                    .frame(minHeight: 320, maxHeight: .infinity)
                Divider()
                safeImportArea
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.accentColor)
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
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "camera.aperture")
                    .foregroundStyle(.blue)
                Text("Locations")
                    .font(.headline)
                Spacer()
            }
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
            }
            .listStyle(.sidebar)

            Divider()
            Button {
                chooseAnyFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
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

            if !isCurrentImportSource {
                Button("Import This Folder") {
                    model.useFolderAsImportSource(currentURL)
                }
                .help("Use this folder as the camera source for the safe import below")
            }

            Button {
                createFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New Folder")

            Button {
                previewSelection()
            } label: {
                Image(systemName: "eye")
            }
            .disabled(selectedURLs.isEmpty)
            .help("Quick Look")

            Button {
                revealSelection()
            } label: {
                Image(systemName: "arrow.right.circle")
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
        return Group {
            if isLoading && items.isEmpty {
                ProgressView("Loading \(currentURL.lastPathComponent)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let browserError {
                ContentUnavailableView(
                    "Folder Unavailable",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(browserError)
                )
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text(currentURL.path)
                )
            } else {
                Table(items, selection: $selectedItemIDs) {
                    TableColumn("Name") { item in
                        HStack(spacing: 7) {
                            Image(systemName: item.isDirectory ? "folder.fill" : fileSymbol(item.url))
                                .foregroundStyle(item.isDirectory ? .blue : .secondary)
                                .frame(width: 18)
                            Text(item.name)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            open(item)
                        }
                        .contextMenu {
                            Button(item.isDirectory ? "Open" : "Open File") { open(item) }
                            Button("Quick Look") { QuickLookPreviewController.shared.preview([item.url]) }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        }
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var safeImportArea: some View {
        VStack(spacing: 0) {
            if let job = model.activeJob {
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

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Safe Import")
                        .font(.headline)
                    Text("Camera stays untouched · Crucial is temporary · NAS originals are permanent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider().frame(height: 34)

                TextField("Event name", text: Binding(
                    get: { model.configuration.eventName },
                    set: { value in model.setEventName(value) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)

                Picker("Camera", selection: Binding(
                    get: { model.configuration.selectedDeviceID },
                    set: { value in model.setDeviceID(value) }
                )) {
                    Text("Sony A7V").tag("sony-a7v")
                    Text("DJI Osmo 360").tag("osmo-360")
                    Text("DJI Mini 2").tag("dji-mini-2")
                    Text("DJI Action 6").tag("action-6")
                    Text("iPhone").tag("iphone")
                }
                .labelsHidden()
                .frame(width: 145)

                Spacer()

                Button(hasRequestedImportPreview ? "Refresh Preview" : "Preview Import") {
                    hasRequestedImportPreview = true
                    model.previewSafeImport()
                }
                .disabled(model.isBusy || !folderExists(model.configuration.importSourcePath))
                .help("Checksum the source and compare both destinations without copying")

                Button("Copy + Verify") {
                    model.copySourceToBuffer()
                }
                .disabled(model.isBusy || !folderExists(model.configuration.importSourcePath))
                .help("Copy the full card to the temporary workspace, then verify every file")

                Button("Archive + Verify") {
                    model.archiveBufferToLibrary()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || !model.isBufferVerifiedForArchive || !folderExists(model.configuration.cameraLibraryRootPath))
                .help("Organize the verified Crucial copy into permanent NAS event folders and write a checksum manifest")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(.bar)
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
                    Text("Crucial / \(workspaceFolders)")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("NAS / \(archiveFolders)")
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
        let workspaceConflicts = Set(model.activePlan.conflicts.map(\.path))
        let archiveNew = Set(model.organizedArchivePlan.new.map(\.sourcePath))
        let archiveExisting = Set(model.organizedArchivePlan.existing.map(\.sourcePath))
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
            } else if workspaceExisting.contains(mapping.sourcePath) {
                workspaceState = .verified
            } else {
                workspaceState = .exists
            }
            let archiveState: PlannedFolder.State
            if archiveConflicts.contains(mapping.sourcePath) {
                archiveState = .conflict
            } else if archiveNew.contains(mapping.sourcePath) {
                archiveState = .willCreate
            } else if archiveExisting.contains(mapping.sourcePath) {
                archiveState = .verified
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
                name: "Photo Workspace",
                path: model.configuration.bufferPath,
                symbol: "externaldrive.fill",
                kind: .workspace
            )
        ]
    }

    private var libraryLocations: [BrowserLocation] {
        let root = URL(fileURLWithPath: model.configuration.cameraLibraryRootPath, isDirectory: true)
        return [
            BrowserLocation(id: "nas-originals", name: "NAS Originals", path: root.appendingPathComponent("Originals").path, symbol: "photo.stack.fill", kind: .library),
            BrowserLocation(id: "nas-edited", name: "NAS Edited", path: root.appendingPathComponent("Edited").path, symbol: "slider.horizontal.3", kind: .library)
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

    private var isCurrentImportSource: Bool {
        currentURL.standardizedFileURL.path == URL(
            fileURLWithPath: DashboardModel.expandedPath(model.configuration.importSourcePath),
            isDirectory: true
        ).standardizedFileURL.path
    }

    @MainActor
    private func loadCurrentDirectory() async {
        isLoading = true
        browserError = nil
        selectedItemIDs.removeAll()
        let url = currentURL
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
            guard currentURL == url else { return }
            items = loaded
        } catch {
            guard currentURL == url else { return }
            items = []
            browserError = error.localizedDescription
        }
        isLoading = false
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

    private func open(_ item: BrowserItem) {
        if item.isDirectory {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func previewSelection() {
        QuickLookPreviewController.shared.preview(selectedURLs)
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
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return }
        do {
            try FileManager.default.createDirectory(at: currentURL.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
            Task { await loadCurrentDirectory() }
        } catch {
            browserError = error.localizedDescription
        }
    }

    private func folderExists(_ path: String) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: DashboardModel.expandedPath(path), isDirectory: &directory) && directory.boolValue
    }

    private func sourceDisplayName(_ location: ConfiguredLocation) -> String {
        let path = location.path.lowercased()
        if path.contains("/cameratoolkit/simulation/") { return "Safety Test Card" }
        if path.contains("lexar") { return "Camera Card · Sony A7V" }
        if path.contains("osmo") { return "Action Camera · DJI 360" }
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
        if ["mp4", "mov", "m4v", "insv", "lrv"].contains(ext) {
            return "film"
        }
        return "doc"
    }
}

@MainActor
private final class QuickLookPreviewController: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPreviewController()
    private var urls: [URL] = []

    func preview(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}
