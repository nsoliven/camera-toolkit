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
        case willCreate
        case exists
        case verified

        var label: String {
            switch self {
            case .willCreate: "WILL CREATE"
            case .exists: "EXISTS"
            case .verified: "VERIFIED"
            }
        }

        var color: Color {
            switch self {
            case .willCreate: .secondary
            case .exists: .blue
            case .verified: .green
            }
        }
    }

    var id: String { path }
    var path: String
    var state: State
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
    @State private var showFolderPlan = true

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
                VSplitView {
                    fileTable
                        .frame(minHeight: 220)
                    safeImportArea
                        .frame(minHeight: 190, idealHeight: 245, maxHeight: 310)
                }
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
        Group {
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
                    .width(min: 220, ideal: 440)

                    TableColumn("Date Modified") { item in
                        Text(item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 130, ideal: 175, max: 210)

                    TableColumn("Size") { item in
                        Text(item.isDirectory ? "—" : item.size.formattedBytes)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 70, ideal: 90, max: 110)

                    TableColumn("Kind") { item in
                        Text(item.kind)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 90, ideal: 130, max: 190)
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

                Button("Preview") {
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

            Divider()

            DisclosureGroup(isExpanded: $showFolderPlan) {
                folderPlan
            } label: {
                HStack {
                    Text("Folders for this import")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if model.organizedArchivePlan.isVerified {
                        Label("NAS verified", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, showFolderPlan ? 10 : 7)
        }
        .background(.bar)
    }

    private var folderPlan: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Temporary workspace", systemImage: "externaldrive.fill")
                    .font(.caption.weight(.semibold))
                Text(model.expandedBufferRootPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.expandedBufferRootPath)
                folderPlanRow(workspaceFolder, relativeTo: model.expandedBufferRootPath)
                Text("Keeps the complete camera-card folder structure until the NAS copy is proven safe.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Label("Permanent NAS organization", systemImage: "network")
                    .font(.caption.weight(.semibold))
                Text(model.expandedLibraryRootPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.expandedLibraryRootPath)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(nasFolders) { folder in
                            folderPlanRow(folder, relativeTo: model.expandedLibraryRootPath)
                        }
                    }
                }
                .frame(maxHeight: 118)
                Text("Immich indexes these stable NAS folders; Camera Toolkit does not upload a second copy.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
    }

    private func folderPlanRow(_ folder: PlannedFolder, relativeTo root: String) -> some View {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let displayPath = folder.path.hasPrefix(prefix) ? String(folder.path.dropFirst(prefix.count)) : folder.path
        return HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(displayPath)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folder.path)
            Spacer(minLength: 8)
            Text(folder.state.label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(folder.state.color)
        }
    }

    private var workspaceFolder: PlannedFolder {
        let path = model.expandedBufferIngestPath
        let state: PlannedFolder.State = model.isBufferVerifiedForArchive
            ? .verified
            : (folderExists(path) ? .exists : .willCreate)
        return PlannedFolder(path: path, state: state)
    }

    private var nasFolders: [PlannedFolder] {
        let planPaths = model.organizedArchivePlan.folders
        let sourcePaths = (model.activePlan.new + model.activePlan.existing + model.activePlan.conflicts).map(\.path)
        let layout = OrganizedArchiveLayout(configuration: model.configuration)
        let relativePaths = planPaths.isEmpty ? layout.requiredFolders(for: sourcePaths) : planPaths
        let root = URL(fileURLWithPath: model.expandedLibraryRootPath, isDirectory: true)
        return relativePaths.map { relative in
            let absolute = root.appendingPathComponent(relative, isDirectory: true).path
            let state: PlannedFolder.State
            if model.organizedArchivePlan.isVerified && relative.hasPrefix("Originals/") {
                state = .verified
            } else {
                state = folderExists(absolute) ? .exists : .willCreate
            }
            return PlannedFolder(path: absolute, state: state)
        }
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
