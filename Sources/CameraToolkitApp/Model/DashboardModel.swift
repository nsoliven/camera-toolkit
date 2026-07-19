import CameraToolkitCore
import AppKit
import Foundation
import Observation

private struct CopyToBufferJobResult: Sendable {
    var copy: LocalCopyResult
    var plan: CopyPlan
}

private struct QueueCopyJobResult: Sendable {
    var copy: LocalCopyResult
    var plan: CopyPlan
}

private struct SafeImportPreviewResult: Sendable {
    var buffer: CopyPlan
    var archive: OrganizedArchivePlan
}

private struct OrganizedArchiveJobResult: Sendable {
    var copy: OrganizedArchiveResult
    var plan: OrganizedArchivePlan
}

private struct BackgroundJobUpdate: Sendable {
    var progress: Double
    var note: String
    var detail: String
    var command: String
    var sourcePath: String?
    var destinationPath: String?
    var currentPath: String?
    var processedFiles: Int
    var totalFiles: Int
    var processedBytes: Int64
    var totalBytes: Int64
    var bytesPerSecond: Double

    init(
        progress: Double,
        note: String,
        detail: String = "",
        command: String = "",
        sourcePath: String? = nil,
        destinationPath: String? = nil,
        currentPath: String? = nil,
        processedFiles: Int = 0,
        totalFiles: Int = 0,
        processedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        bytesPerSecond: Double = 0
    ) {
        self.progress = progress
        self.note = note
        self.detail = detail
        self.command = command
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.currentPath = currentPath
        self.processedFiles = processedFiles
        self.totalFiles = totalFiles
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }
}

@MainActor
@Observable
final class DashboardModel {
    var isSidebarCollapsed: Bool = false
    var activePlan: CopyPlan
    var organizedArchivePlan = OrganizedArchivePlan()
    var queuedFilePaths: Set<String> = []
    var jobs: [JobSnapshot]
    var activityLog: [ActivityLogEntry]
    var configuration: AppConfiguration
    var configMessage: String = "Config is saved automatically."
    var statusMessage: String = "Ready. Choose folders in Settings to begin."
    var isBusy: Bool = false
    var immichAPIKeyDraft: String = ""
    var immichConnectionStatus: String = "Not connected. Add your server URL and API key in Config."
    var immichConnectionReport: ImmichConnectionReport?
    var immichIsTestingConnection: Bool = false
    var isRefreshing: Bool = false
    var lastRefreshedAt: Date?
    var catalogReport: CatalogBootstrapReport?
    var catalogMessage: String = "Photo list has not been prepared yet."
    var activeJob: JobSnapshot? {
        jobs.first { $0.state == .running || $0.state == .queued }
    }
    @ObservationIgnored private let configurationStore: ConfigurationStore
    @ObservationIgnored private let secretStore = KeychainSecretStore(service: "org.cameratoolkit.CameraToolkit")
    @ObservationIgnored private var catalogSyncTask: Task<Void, Never>?

    init(
        activePlan: CopyPlan,
        jobs: [JobSnapshot],
        activityLog: [ActivityLogEntry] = [],
        configuration: AppConfiguration = .defaults(applicationSupport: DashboardModel.defaultApplicationSupportURL),
        configurationStore: ConfigurationStore = ConfigurationStore(url: DashboardModel.defaultConfigurationURL),
        loadActivityLog: Bool = false
    ) {
        self.activePlan = activePlan
        self.jobs = jobs
        self.configuration = configuration
        self.configurationStore = configurationStore
        if loadActivityLog {
            self.activityLog = (try? ActivityLogStore(url: URL(fileURLWithPath: Self.expandedPath(configuration.activityLogPath))).load()) ?? activityLog
        } else {
            self.activityLog = activityLog
        }
        if !configuration.immichServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.immichConnectionStatus = "Immich URL is saved. Keychain is checked only when you click Test Connection."
        }
    }

    static func live() -> DashboardModel {
        let defaults = AppConfiguration.defaults(applicationSupport: defaultApplicationSupportURL)
        let store = ConfigurationStore(url: defaultConfigurationURL)
        let configuration = (try? store.load(defaults: defaults)) ?? defaults
        try? store.save(configuration)

        let model = DashboardModel(
            activePlan: CopyPlan(),
            jobs: [],
            configuration: configuration,
            configurationStore: store,
            loadActivityLog: true
        )
        model.scheduleCatalogSync(configuration: configuration)
        return model
    }
}

extension DashboardModel {
    var queuedFiles: [FileRecord] {
        var candidates: [String: FileRecord] = [:]
        for file in activePlan.new + selectedEventFiles {
            candidates[file.path] = file
        }
        return queuedFilePaths.compactMap { candidates[$0] }.sorted { $0.path < $1.path }
    }

    var savedEvents: [SavedCameraEvent] {
        configuration.savedEvents.sorted {
            if $0.eventDate == $1.eventDate { return $0.name < $1.name }
            return $0.eventDate > $1.eventDate
        }
    }

    var selectedEvent: SavedCameraEvent? {
        guard let id = configuration.selectedEventID else { return nil }
        return configuration.savedEvents.first { $0.id == id }
    }

    var selectedEventFiles: [FileRecord] {
        guard let eventID = configuration.selectedEventID else { return [] }
        let root = URL(fileURLWithPath: expandedImportSourcePath, isDirectory: true).standardizedFileURL.path
        return configuration.photoEventAssignments.compactMap { assignment in
            guard assignment.eventID == eventID,
                  URL(fileURLWithPath: assignment.sourceRootPath, isDirectory: true).standardizedFileURL.path == root,
                  (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else {
                return nil
            }
            return FileRecord(
                path: assignment.relativePath,
                size: assignment.fileSize,
                modifiedAt: assignment.modifiedAt
            )
        }.sorted { $0.path < $1.path }
    }

    func toggleSidebar() {
        isSidebarCollapsed.toggle()
    }

    func refreshAllIfStale(maxAge: TimeInterval = 15) {
        guard let lastRefreshedAt else {
            refreshAll()
            return
        }
        if Date().timeIntervalSince(lastRefreshedAt) >= maxAge {
            refreshAll()
        }
    }

    func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusMessage = "Refreshing latest app state..."

        Task { @MainActor in
            await refreshAllNow()
        }
    }

    @discardableResult
    func createEvent(named rawName: String, on eventDate: Date) -> Bool {
        let validation = EventNamePolicy.validate(rawName)
        guard validation.isValid else {
            statusMessage = validation.errorMessage ?? "Choose a different event name."
            return false
        }
        let name = validation.normalizedName

        var selectedID: UUID?
        updateConfiguration { configuration in
            if let index = configuration.savedEvents.firstIndex(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                    && Calendar.current.isDate($0.eventDate, inSameDayAs: eventDate)
            }) {
                configuration.savedEvents[index].lastUsedAt = Date()
                selectedID = configuration.savedEvents[index].id
            } else {
                let event = SavedCameraEvent(name: name, eventDate: eventDate)
                configuration.savedEvents.append(event)
                selectedID = event.id
            }
            configuration.selectedEventID = selectedID
            configuration.eventName = name
            configuration.beginNewBatch(now: eventDate)
        }
        activePlan = CopyPlan()
        organizedArchivePlan = OrganizedArchivePlan()
        queuedFilePaths = Set(selectedEventFiles.map(\.path))
        createSelectedEventFolders()
        return true
    }

    func selectEvent(_ id: UUID) {
        guard let event = configuration.savedEvents.first(where: { $0.id == id }) else { return }
        updateConfiguration { configuration in
            configuration.selectedEventID = event.id
            configuration.eventName = event.name
            configuration.beginNewBatch(now: event.eventDate)
            if let index = configuration.savedEvents.firstIndex(where: { $0.id == event.id }) {
                configuration.savedEvents[index].lastUsedAt = Date()
            }
        }
        activePlan = CopyPlan()
        organizedArchivePlan = OrganizedArchivePlan()
        queuedFilePaths = Set(selectedEventFiles.map(\.path))
        statusMessage = selectedEventFiles.isEmpty
            ? "Selected \(event.name). Select photos and assign them to this event."
            : "Selected \(event.name) with \(selectedEventFiles.count) assigned file(s)."
    }

    func assignFilesToSelectedEvent(_ files: [FileRecord]) {
        let root = URL(fileURLWithPath: expandedImportSourcePath, isDirectory: true).standardizedFileURL.path
        assignFilesToSelectedEvent(files.map {
            EventFileSelection(sourceRootPath: root, file: $0)
        })
    }

    func assignFilesToSelectedEvent(_ selections: [EventFileSelection]) {
        guard let event = selectedEvent, !selections.isEmpty else {
            statusMessage = selectedEvent == nil
                ? "Create or choose an event before assigning photos."
                : "Select one or more files first."
            return
        }

        let validSelections = selections.compactMap { selection -> EventFileSelection? in
            let root = URL(
                fileURLWithPath: Self.expandedPath(selection.sourceRootPath),
                isDirectory: true
            ).standardizedFileURL.path
            guard (try? PathSafety.validateRelativePath(selection.file.path)) != nil else { return nil }
            return EventFileSelection(sourceRootPath: root, file: selection.file)
        }
        guard !validSelections.isEmpty else {
            statusMessage = "None of the selected files had a safe path."
            return
        }

        updateConfiguration { configuration in
            for selection in validSelections {
                let root = selection.sourceRootPath
                let file = selection.file
                configuration.photoEventAssignments.removeAll {
                    $0.sourceRootPath == root
                        && $0.relativePath == file.path
                        && $0.fileSize == file.size
                        && abs($0.modifiedAt.timeIntervalSince(file.modifiedAt)) < 1
                }
                configuration.photoEventAssignments.append(
                    PhotoEventAssignment(
                        sourceRootPath: root,
                        relativePath: file.path,
                        fileSize: file.size,
                        modifiedAt: file.modifiedAt,
                        eventID: event.id,
                        deviceID: configuration.selectedDeviceID
                    )
                )
            }
        }
        let currentRoot = URL(fileURLWithPath: expandedImportSourcePath, isDirectory: true).standardizedFileURL.path
        queuedFilePaths.formUnion(
            validSelections
                .filter { $0.sourceRootPath == currentRoot }
                .map(\.file.path)
        )
        let sourceCount = Set(validSelections.map(\.sourceRootPath)).count
        let sourceNote = sourceCount == 1 ? "" : " across \(sourceCount) camera sources"
        statusMessage = "Assigned \(validSelections.count) file(s)\(sourceNote) to \(event.name)."
    }

    func queueSelectedEventFiles() {
        queuedFilePaths = Set(selectedEventFiles.map(\.path))
        statusMessage = selectedEventFiles.isEmpty
            ? "This event has no assigned files on the selected camera source."
            : "Queued \(selectedEventFiles.count) file(s) assigned to \(selectedEvent?.name ?? "the event")."
    }

    func setEventImmichUploadEnabled(_ eventID: UUID, enabled: Bool) {
        updateConfiguration { configuration in
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].immichUploadEnabled = enabled
            configuration.savedEvents[index].lastUsedAt = Date()
        }
        statusMessage = enabled
            ? "This event is marked for Immich. Nothing was uploaded."
            : "This event is storage-only. Nothing will be sent to Immich."
    }

    func setEventImmichAlbumPolicy(_ eventID: UUID, policy: ImmichAlbumPolicy) {
        updateConfiguration { configuration in
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].immichAlbumPolicy = policy
        }
        statusMessage = policy == .none
            ? "Immich uploads for this event will not create an album."
            : "Saved the Immich album preference. Nothing was uploaded."
    }

    func setEventImmichAlbumName(_ eventID: UUID, name: String) {
        updateConfiguration { configuration in
            guard let index = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) else { return }
            configuration.savedEvents[index].immichAlbumName = name
        }
    }

    func setAssignmentImmichOverride(_ assignment: PhotoEventAssignment, value: Bool?) {
        updateConfiguration { configuration in
            guard let index = configuration.photoEventAssignments.firstIndex(where: {
                CatalogStore.eventAssetID($0) == CatalogStore.eventAssetID(assignment)
            }) else { return }
            configuration.photoEventAssignments[index].immichUploadOverride = value
        }
    }

    func checkImmichPresence(_ assets: [ImmichChecksumQuery]) async throws -> [ImmichChecksumResult] {
        let serverURL = configuration.immichServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty else {
            throw ToolkitError.commandFailed("Add the Immich server URL in Settings first.")
        }
        var apiKey = immichAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty {
            apiKey = try secretStore.read(account: Self.immichAPIKeyAccount)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !apiKey.isEmpty else {
            throw ToolkitError.commandFailed("Save an Immich API key in Settings first.")
        }
        let client = try ImmichClient(serverURL: serverURL, apiKey: apiKey)
        var results: [ImmichChecksumResult] = []
        for start in stride(from: 0, to: assets.count, by: 100) {
            let end = min(start + 100, assets.count)
            results += try await client.checkBulkUpload(Array(assets[start..<end]))
        }
        return results
    }

    func createSelectedEventFolders() {
        guard let event = selectedEvent else {
            statusMessage = "Create or choose an event first."
            return
        }
        do {
            for path in configuration.eventWorkspaceFolderPaths() {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: Self.expandedPath(path), isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            statusMessage = "Created the \(event.name) card-copy, Photomator, Masters, Web, and Social folders."
        } catch {
            statusMessage = "Could not create folders for \(event.name): \(error.localizedDescription)"
        }
    }

    func openEventFolder(_ path: String) {
        createSelectedEventFolders()
        let url = URL(fileURLWithPath: Self.expandedPath(path), isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func chooseFolder(title: String, keyPath: WritableKeyPath<AppConfiguration, String>) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = title
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder for Camera Toolkit config."
        if panel.runModal() == .OK, let url = panel.url {
            setConfigPath(keyPath, to: url.path)
            return true
        }
        return false
    }

    func chooseActivityLogFile() {
        let panel = NSSavePanel()
        panel.title = "Choose Activity Log File"
        panel.prompt = "Use Log File"
        panel.nameFieldStringValue = URL(fileURLWithPath: Self.expandedPath(configuration.activityLogPath)).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: Self.expandedPath(configuration.activityLogPath)).deletingLastPathComponent()
        panel.message = "Choose where Camera Toolkit saves the permanent activity log."
        if panel.runModal() == .OK, let url = panel.url {
            setConfigPath(\.activityLogPath, to: url.path)
            activityLog = (try? ActivityLogStore(url: url).load()) ?? activityLog
        }
    }

    func chooseCatalogDatabaseFile() {
        let panel = NSSavePanel()
        panel.title = "Choose Photo List Database"
        panel.prompt = "Use Photo List"
        panel.nameFieldStringValue = URL(fileURLWithPath: Self.expandedPath(configuration.catalogDatabasePath)).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: Self.expandedPath(configuration.catalogDatabasePath)).deletingLastPathComponent()
        panel.message = "Choose where Camera Toolkit stores the local photo list database."
        if panel.runModal() == .OK, let url = panel.url {
            setConfigPath(\.catalogDatabasePath, to: url.path)
        }
    }

    func chooseCameraLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Camera Library"
        panel.prompt = "Use Library"
        panel.message = "Choose the folder that contains Inbox, Originals, Edited, Selects, Shared, and proof files."
        if panel.runModal() == .OK, let url = panel.url {
            setCameraLibraryRoot(url.path)
        }
    }

    func prepareLibraryCatalog() {
        prepareLibraryCatalog(createBackup: true)
    }

    func syncCatalogCache() {
        scheduleCatalogSync(configuration: configuration)
    }

    func prepareLibraryCatalog(createBackup: Bool) {
        catalogSyncTask?.cancel()
        let snapshot = configuration
        let catalogURL = URL(fileURLWithPath: Self.expandedPath(snapshot.catalogDatabasePath))
        catalogMessage = "Preparing the local photo list in the background…"
        catalogSyncTask = Task { @MainActor in
            let outcome = await Task.detached(priority: .utility) {
                do {
                    let report = try CatalogStore(url: catalogURL).bootstrap(
                        configuration: snapshot,
                        createBackup: createBackup
                    )
                    return (report: Optional(report), error: String?.none)
                } catch {
                    return (report: CatalogBootstrapReport?.none, error: Optional(error.localizedDescription))
                }
            }.value
            guard !Task.isCancelled else { return }
            if let report = outcome.report {
                catalogReport = report
                catalogMessage = "Photo list ready with \(report.storageLocationCount) saved place(s)."
                recordActivity(
                    action: .verifyManifest,
                    state: .done,
                    title: "Prepared photo list",
                    summary: catalogMessage,
                    detail: "Photo list: \(report.databasePath). Backup: \(report.backupPath ?? "not configured")."
                )
            } else {
                catalogMessage = "Could not prepare photo list: \(outcome.error ?? "Unknown catalog error")"
                statusMessage = catalogMessage
                recordActivity(
                    action: .verifyManifest,
                    state: .failed,
                    title: "Photo list setup failed",
                    summary: catalogMessage,
                    detail: "No photo files were moved."
                )
            }
        }
    }

    func setConfigPath(_ keyPath: WritableKeyPath<AppConfiguration, String>, to value: String) {
        if keyPath == \.importSourcePath {
            setSelectedLocationPath(role: .importSource, to: value)
            return
        }
        if keyPath == \.archivePath {
            setSelectedLocationPath(role: .archive, to: value)
            return
        }
        if keyPath == \.bufferPath {
            setSelectedLocationPath(role: .buffer, to: value)
            return
        }
        updateConfiguration { configuration in
            configuration[keyPath: keyPath] = value
        }
    }

    func setCameraLibraryRoot(_ path: String) {
        updateConfiguration { configuration in
            configuration.setCameraLibraryRoot(path)
        }
        statusMessage = "Camera library points at \(path)."
    }

    func addConfiguredLocation(role: ConfiguredLocationRole) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Add \(role.displayName)"
        panel.prompt = "Add"
        panel.message = "Choose a folder for this \(role.displayName.lowercased())."
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let location = ConfiguredLocation(
            role: role,
            name: defaultLocationName(for: url, role: role),
            path: url.path
        )
        updateConfiguration { configuration in
            configuration.configuredLocations.append(location)
            configuration.selectLocation(location)
        }
        statusMessage = "Added \(location.name) as \(role.displayName)."
    }

    func useConfiguredLocation(_ location: ConfiguredLocation) {
        updateConfiguration { configuration in
            configuration.selectLocation(location)
        }
        activePlan = CopyPlan()
        organizedArchivePlan = OrganizedArchivePlan()
        queuedFilePaths.removeAll()
        statusMessage = "Using \(location.name) for \(location.role.displayName)."
    }

    func useFolderAsImportSource(_ url: URL) {
        let name = url.lastPathComponent.isEmpty ? "Camera Source" : url.lastPathComponent
        updateConfiguration { configuration in
            configuration.upsertLocation(role: .importSource, name: name, path: url.path, select: true)
            configuration.beginNewBatch()
        }
        activePlan = CopyPlan()
        organizedArchivePlan = OrganizedArchivePlan()
        queuedFilePaths.removeAll()
        statusMessage = "Using \(name) as the camera source. Nothing has been copied yet."
    }

    func setConfiguredLocationName(_ location: ConfiguredLocation, to value: String) {
        updateConfiguration { configuration in
            guard let index = configuration.configuredLocations.firstIndex(where: { $0.id == location.id }) else {
                return
            }
            configuration.configuredLocations[index].name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func setConfiguredLocationPath(_ location: ConfiguredLocation, to value: String) {
        updateConfiguration { configuration in
            guard let index = configuration.configuredLocations.firstIndex(where: { $0.id == location.id }) else {
                return
            }
            configuration.configuredLocations[index].path = value
            if configuration.selectedLocationID(for: location.role) == location.id {
                configuration.selectLocation(configuration.configuredLocations[index])
            }
        }
    }

    func chooseConfiguredLocationFolder(_ location: ConfiguredLocation) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose \(location.role.displayName)"
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder for \(location.name)."
        panel.directoryURL = URL(fileURLWithPath: Self.expandedPath(location.path), isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        setConfiguredLocationPath(location, to: url.path)
    }

    func removeConfiguredLocation(_ location: ConfiguredLocation) {
        updateConfiguration { configuration in
            configuration.configuredLocations.removeAll { $0.id == location.id }
        }
        statusMessage = "Removed \(location.name) from \(location.role.displayName)."
    }

    func setDeviceID(_ value: String) {
        updateConfiguration { $0.selectedDeviceID = value }
        activePlan = CopyPlan()
        organizedArchivePlan = OrganizedArchivePlan()
        queuedFilePaths.removeAll()
        statusMessage = "Camera changed. Preview or copy again before archiving."
    }

    func setEventName(_ value: String) {
        updateConfiguration { configuration in
            configuration.eventName = value
            if let id = configuration.selectedEventID,
               let index = configuration.savedEvents.firstIndex(where: { $0.id == id }) {
                configuration.savedEvents[index].name = value
                configuration.savedEvents[index].lastUsedAt = Date()
            }
        }
        activePlan = CopyPlan()
        organizedArchivePlan = OrganizedArchivePlan()
        queuedFilePaths.removeAll()
        statusMessage = "Event folder changed. Preview or copy again before archiving."
    }

    func setImmichServerURL(_ value: String) {
        updateConfiguration { $0.immichServerURL = value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func saveImmichAPIKey() {
        do {
            try secretStore.save(immichAPIKeyDraft, account: Self.immichAPIKeyAccount)
            immichConnectionStatus = immichAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "API key removed from Keychain."
                : "API key saved in Keychain."
            configMessage = "Immich API key saved in macOS Keychain."
        } catch {
            immichConnectionStatus = "Could not save API key: \(error.localizedDescription)"
        }
    }

    func testImmichConnection() {
        let serverURL = configuration.immichServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty else {
            immichConnectionStatus = "Add an Immich server URL in Config first."
            return
        }

        var apiKey = immichAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if apiKey.isEmpty {
                apiKey = try secretStore.read(account: Self.immichAPIKeyAccount)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } else {
                try secretStore.save(apiKey, account: Self.immichAPIKeyAccount)
            }
        } catch {
            immichConnectionStatus = "Could not read Immich API key from Keychain: \(error.localizedDescription)"
            return
        }

        guard !apiKey.isEmpty else {
            immichConnectionStatus = "Paste an Immich API key, or save one first, then test again."
            return
        }

        Task { @MainActor in
            await performImmichConnectionCheck(serverURL: serverURL, apiKey: apiKey, shouldRecordActivity: true)
        }
    }

    func previewImport() {
        let sourcePath = expandedImportSourcePath
        let destinationPath = expandedBufferIngestPath
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
        let command = Self.commandLine(["plan-copy", "--checksum", sourcePath, destinationPath])
        runBackgroundJob(
            action: .previewFiles,
            runningNote: "Checking what would copy to buffer",
            logTitle: "Previewed copy to buffer",
            logDetail: "Checked the selected from folder and buffer. No files were copied.",
            command: command,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            operation: { progress in
                try ArchivePlanner().planCopy(source: source, destination: destination) { update in
                    let bounds = Self.planProgressBounds(for: update)
                    progress(Self.jobUpdate(from: update, lowerBound: bounds.lower, upperBound: bounds.upper, notePrefix: "Checking copy", command: command, sourcePath: sourcePath, destinationPath: destinationPath))
                }
            },
            completion: { plan in
                self.activePlan = plan
                self.queuedFilePaths = Set(plan.new.map(\.path))
                return "Preview ready: \(plan.new.count) new, \(plan.existing.count) already in buffer, \(plan.conflicts.count) conflicts. To: \(destinationPath)"
            }
        )
    }

    func previewSafeImport() {
        let sourcePath = expandedImportSourcePath
        let bufferPath = expandedBufferIngestPath
        let libraryPath = expandedLibraryRootPath
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let buffer = URL(fileURLWithPath: bufferPath, isDirectory: true)
        let library = URL(fileURLWithPath: libraryPath, isDirectory: true)
        let layout = OrganizedArchiveLayout(configuration: configuration)
        let command = Self.commandLine(["preview-safe-import", sourcePath, bufferPath, libraryPath])
        runBackgroundJob(
            action: .previewFiles,
            runningNote: "Checking the camera source, buffer, and library folders",
            logTitle: "Previewed safe import",
            logDetail: "Checked both destinations by checksum. No files were copied.",
            command: command,
            sourcePath: sourcePath,
            destinationPath: libraryPath,
            operation: { progress in
                let bufferPlan = try ArchivePlanner().planCopy(source: source, destination: buffer) { update in
                    let bounds = Self.planProgressBounds(for: update, lowerBound: 0.02, upperBound: 0.58)
                    progress(Self.jobUpdate(from: update, lowerBound: bounds.lower, upperBound: bounds.upper, notePrefix: "Checking workspace", command: command, sourcePath: sourcePath, destinationPath: bufferPath))
                }
                let sourceFiles = bufferPlan.new + bufferPlan.existing + bufferPlan.conflicts
                let archivePlan = try OrganizedArchivePlanner().plan(
                    source: source,
                    sourceFiles: sourceFiles,
                    libraryRoot: library,
                    layout: layout
                ) { update in
                    progress(Self.jobUpdate(from: update, lowerBound: 0.60, upperBound: 0.97, notePrefix: "Checking library folders", command: command, sourcePath: sourcePath, destinationPath: libraryPath))
                }
                return SafeImportPreviewResult(buffer: bufferPlan, archive: archivePlan)
            },
            completion: { result in
                self.activePlan = result.buffer
                self.organizedArchivePlan = result.archive
                self.queuedFilePaths = Set(result.buffer.new.map(\.path))
                return "Preview ready: \(result.buffer.new.count) need copying to the buffer; \(result.archive.new.count) need archiving to the library; \(result.buffer.conflicts.count + result.archive.conflicts.count) conflict(s)."
            }
        )
    }

    func previewSelectedEventImport() {
        let selectedFiles = selectedEventFiles
        guard !selectedFiles.isEmpty else {
            statusMessage = "Assign photos to the selected event before previewing it."
            return
        }

        let sourcePath = expandedImportSourcePath
        let bufferPath = expandedBufferIngestPath
        let libraryPath = expandedLibraryRootPath
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let buffer = URL(fileURLWithPath: bufferPath, isDirectory: true)
        let library = URL(fileURLWithPath: libraryPath, isDirectory: true)
        let layout = OrganizedArchiveLayout(configuration: configuration)
        let command = Self.commandLine(["preview-event-import", sourcePath, bufferPath, "\(selectedFiles.count) files"])
        runBackgroundJob(
            action: .previewFiles,
            runningNote: "Checking selected event files",
            logTitle: "Previewed event import",
            logDetail: "Checked only the photos assigned to the selected event. No files were copied.",
            command: command,
            sourcePath: sourcePath,
            destinationPath: libraryPath,
            operation: { progress in
                let bufferPlan = try ArchivePlanner().planCopyMetadata(
                    source: source,
                    destination: buffer,
                    files: selectedFiles
                ) { update in
                    progress(Self.jobUpdate(from: update, lowerBound: 0.03, upperBound: 0.62, notePrefix: "Reading event workspace", command: command, sourcePath: sourcePath, destinationPath: bufferPath))
                }
                let sourceFiles = bufferPlan.new + bufferPlan.existing + bufferPlan.conflicts
                let archivePlan = try OrganizedArchivePlanner().planMetadata(
                    sourceFiles: sourceFiles,
                    libraryRoot: library,
                    layout: layout
                ) { update in
                    progress(Self.jobUpdate(from: update, lowerBound: 0.64, upperBound: 0.97, notePrefix: "Reading event archive", command: command, sourcePath: sourcePath, destinationPath: libraryPath))
                }
                return SafeImportPreviewResult(buffer: bufferPlan, archive: archivePlan)
            },
            completion: { result in
                self.activePlan = result.buffer
                self.organizedArchivePlan = result.archive
                self.queuedFilePaths = Set(selectedFiles.map(\.path))
                return "Fast event preview ready: \(result.buffer.new.count) need copying to the buffer; \(result.archive.new.count) need archiving to the library; \(result.buffer.conflicts.count + result.archive.conflicts.count) size conflict(s). Copy + Verify performs the checksum check."
            }
        )
    }

    func copySourceToBuffer() {
        let sourcePath = expandedImportSourcePath
        let destinationPath = expandedBufferIngestPath
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
        let command = Self.commandLine(["copy-immutable", "--checksum", sourcePath, destinationPath])
        runBackgroundJob(
            action: .ingestCard,
            runningNote: "Copying files to buffer",
            logTitle: "Copied files to buffer",
            logDetail: "Copied only new files into the selected buffer batch. Existing conflicts were not overwritten.",
            command: command,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            operation: { progress in
                let result = try LocalTransferService().copyImmutable(source: source, destination: destination) { update in
                    let isHashing = update.phase.localizedCaseInsensitiveContains("hashing")
                    progress(Self.jobUpdate(from: update, lowerBound: isHashing ? 0.02 : 0.32, upperBound: isHashing ? 0.32 : 0.82, notePrefix: "Copying to buffer", command: command, sourcePath: sourcePath, destinationPath: destinationPath))
                }
                let plan = try ArchivePlanner().planCopy(source: source, destination: destination) { update in
                    let bounds = Self.planProgressBounds(for: update, lowerBound: 0.82, upperBound: 0.97)
                    progress(Self.jobUpdate(from: update, lowerBound: bounds.lower, upperBound: bounds.upper, notePrefix: "Checking buffer copy", command: command, sourcePath: sourcePath, destinationPath: destinationPath))
                }
                return CopyToBufferJobResult(copy: result, plan: plan)
            },
            completion: { result in
                self.activePlan = result.plan
                return "Copied \(result.copy.copied.count) file(s) to buffer, skipped \(result.copy.skippedIdentical.count) already there, left \(result.copy.conflicts.count) conflict(s) untouched. Buffer batch: \(destinationPath)"
            }
        )
    }

    func copyQueuedFilesToBuffer() {
        let selectedFiles = queuedFiles
        guard !selectedFiles.isEmpty else {
            statusMessage = "Queue is empty. Preview files, then add files to the queue."
            return
        }

        let sourcePath = expandedImportSourcePath
        let destinationPath = expandedBufferIngestPath
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
        let command = Self.commandLine(["copy-queue", sourcePath, destinationPath, "\(selectedFiles.count) files"])
        runBackgroundJob(
            action: .ingestCard,
            runningNote: "Copying queued files to buffer",
            logTitle: "Copied queue to buffer",
            logDetail: "Copied only the files selected in the queue. Nothing was deleted or overwritten.",
            command: command,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            operation: { progress in
                let result = try LocalTransferService().copyFiles(source: source, destination: destination, files: selectedFiles) { update in
                    progress(Self.jobUpdate(from: update, lowerBound: 0.04, upperBound: 0.78, notePrefix: "Copying queue", command: command, sourcePath: sourcePath, destinationPath: destinationPath))
                }
                let plan = try ArchivePlanner().planCopy(source: source, destination: destination, files: selectedFiles) { update in
                    let bounds = Self.planProgressBounds(for: update, lowerBound: 0.78, upperBound: 0.97)
                    progress(Self.jobUpdate(from: update, lowerBound: bounds.lower, upperBound: bounds.upper, notePrefix: "Checking buffer copy", command: command, sourcePath: sourcePath, destinationPath: destinationPath))
                }
                return QueueCopyJobResult(copy: result, plan: plan)
            },
            completion: { result in
                self.activePlan = result.plan
                self.queuedFilePaths.removeAll()
                return "Copied \(result.copy.copied.count) queued file(s) to buffer, skipped \(result.copy.skippedIdentical.count) already there, left \(result.copy.conflicts.count) conflict(s) untouched."
            }
        )
    }

    var isBufferVerifiedForArchive: Bool {
        !activePlan.existing.isEmpty
            && activePlan.new.isEmpty
            && activePlan.conflicts.isEmpty
            && activePlan.existing.allSatisfy { $0.sha256 != nil }
    }

    func archiveBufferToLibrary() {
        guard isBufferVerifiedForArchive else {
            statusMessage = "Copy and checksum-verify the event files in the buffer before archiving to the library."
            return
        }

        let sourcePath = expandedBufferIngestPath
        let libraryPath = expandedLibraryRootPath
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let library = URL(fileURLWithPath: libraryPath, isDirectory: true)
        let layout = OrganizedArchiveLayout(configuration: configuration)
        let command = Self.commandLine(["archive-organized", "--verify", sourcePath, libraryPath])
        runBackgroundJob(
            action: .syncBuffer,
            runningNote: "Organizing and verifying permanent library originals",
            logTitle: "Archived verified originals to the library",
            logDetail: "Copied from the verified buffer into event folders. Existing conflicts were never overwritten, and a checksum manifest was written.",
            command: command,
            sourcePath: sourcePath,
            destinationPath: libraryPath,
            operation: { progress in
                let planner = OrganizedArchivePlanner()
                let plan = try planner.plan(source: source, libraryRoot: library, layout: layout) { update in
                    progress(Self.jobUpdate(from: update, lowerBound: 0.02, upperBound: 0.34, notePrefix: "Planning library archive", command: command, sourcePath: sourcePath, destinationPath: libraryPath))
                }
                let result = try OrganizedArchiveService().archive(source: source, libraryRoot: library, plan: plan) { update in
                    progress(Self.jobUpdate(from: update, lowerBound: 0.34, upperBound: 0.88, notePrefix: "Archiving to the library", command: command, sourcePath: sourcePath, destinationPath: libraryPath))
                }
                let verifiedPlan = try planner.plan(source: source, libraryRoot: library, layout: layout) { update in
                    progress(Self.jobUpdate(from: update, lowerBound: 0.88, upperBound: 0.98, notePrefix: "Final library verification", command: command, sourcePath: sourcePath, destinationPath: libraryPath))
                }
                return OrganizedArchiveJobResult(copy: result, plan: verifiedPlan)
            },
            completion: { result in
                self.organizedArchivePlan = result.plan
                let proof = result.copy.manifestPath.map { " Proof: \($0)" } ?? ""
                return "Library archive verified: \(result.copy.copied.count) copied, \(result.copy.skippedIdentical.count) already safe, \(result.copy.conflicts.count) conflict(s) left untouched.\(proof)"
            }
        )
    }

    private var expandedImportSourcePath: String {
        Self.expandedPath(configuration.importSourcePath)
    }

    var expandedBufferIngestPath: String {
        Self.expandedPath(configuration.bufferIngestFolderPath())
    }

    var expandedBufferExportsPath: String {
        Self.expandedPath(configuration.bufferExportsFolderPath())
    }

    var expandedBufferEditsPath: String {
        Self.expandedPath(configuration.bufferEditsFolderPath())
    }

    var expandedLibraryRootPath: String {
        Self.expandedPath(configuration.cameraLibraryRootPath)
    }

    private func refreshAllNow() async {
        defer {
            isRefreshing = false
            lastRefreshedAt = Date()
        }

        var notes: [String] = []

        do {
            let defaults = AppConfiguration.defaults(applicationSupport: Self.defaultApplicationSupportURL)
            configuration = try configurationStore.load(defaults: defaults)
            configMessage = "Config reloaded at \(Self.defaultConfigurationURL.path)."
            notes.append("config")
        } catch {
            configMessage = "Could not reload config: \(error.localizedDescription)"
            notes.append("config failed")
        }

        do {
            activityLog = try ActivityLogStore(url: URL(fileURLWithPath: Self.expandedPath(configuration.activityLogPath))).load()
            notes.append("\(activityLog.count) log entries")
        } catch {
            notes.append("log unavailable")
        }

        notes.append("paths")
        if !configuration.immichServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.append("Immich configured")
            if immichConnectionReport == nil {
                immichConnectionStatus = "Immich URL is saved. Keychain is checked only when you click Test Connection."
            }
        }
        statusMessage = "Refreshed latest: \(notes.joined(separator: ", "))."
    }

    private func performImmichConnectionCheck(serverURL: String, apiKey: String, shouldRecordActivity: Bool) async {
        do {
            let client = try ImmichClient(serverURL: serverURL, apiKey: apiKey)
            immichIsTestingConnection = true
            immichConnectionStatus = "Testing Immich connection..."
            defer { immichIsTestingConnection = false }

            let report = try await client.testConnection()
            immichConnectionReport = report
            immichConnectionStatus = "Connected to Immich \(report.version) as \(report.userName) <\(report.userEmail)>."
            if shouldRecordActivity {
                recordActivity(
                    action: .immichScan,
                    state: .done,
                    title: "Tested Immich connection",
                    summary: immichConnectionStatus,
                    detail: "Called stable Immich endpoints for ping, server version, and current user. The API key stays in macOS Keychain and is not written to the activity log."
                )
            }
        } catch {
            immichConnectionReport = nil
            immichConnectionStatus = "Immich connection failed: \(error.localizedDescription)"
            if shouldRecordActivity {
                recordActivity(
                    action: .immichScan,
                    state: .failed,
                    title: "Immich connection failed",
                    summary: immichConnectionStatus,
                    detail: "No upload was attempted."
                )
            }
        }
    }

    nonisolated private static func jobUpdate(
        from update: FileOperationProgress,
        lowerBound: Double = 0.02,
        upperBound: Double = 0.95,
        notePrefix: String,
        command: String,
        sourcePath: String? = nil,
        destinationPath: String? = nil
    ) -> BackgroundJobUpdate {
        let span = max(upperBound - lowerBound, 0)
        let rawFraction: Double
        if update.totalBytes > 0 || update.totalFiles > 0 {
            rawFraction = update.fractionComplete
        } else {
            rawFraction = min(Double(update.processedFiles) / 1_000, 0.85)
        }
        let progress = lowerBound + min(max(rawFraction, 0), 1) * span

        var details: [String] = []
        if update.totalFiles > 0 {
            details.append("\(update.processedFiles)/\(update.totalFiles) files")
        } else if update.processedFiles > 0 {
            details.append("\(update.processedFiles) files")
        }
        if update.totalBytes > 0 {
            details.append("\(update.processedBytes.formattedBytes) / \(update.totalBytes.formattedBytes)")
        } else if update.processedBytes > 0 {
            details.append(update.processedBytes.formattedBytes)
        }
        if update.bytesPerSecond > 0 {
            details.append("\(Int64(update.bytesPerSecond).formattedBytes)/s")
        }

        let phase = displayPhase(update.phase)
        let note: String
        if let currentPath = update.currentPath {
            note = "\(notePrefix): \(phase) \(currentPath)"
        } else {
            note = "\(notePrefix): \(phase)"
        }

        return BackgroundJobUpdate(
            progress: progress,
            note: note,
            detail: details.joined(separator: " · "),
            command: command,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            currentPath: update.currentPath,
            processedFiles: update.processedFiles,
            totalFiles: update.totalFiles,
            processedBytes: update.processedBytes,
            totalBytes: update.totalBytes,
            bytesPerSecond: update.bytesPerSecond
        )
    }

    nonisolated private static func displayPhase(_ phase: String) -> String {
        switch phase.lowercased() {
        case "hashing source":
            "Reading from folder"
        case "hashing destination":
            "Checking to folder"
        case "checking source":
            "Checking from folder"
        case "checking destination":
            "Checking to folder"
        case "destination missing":
            "To folder will be created"
        case "hashing":
            "Checking file bytes"
        case "scanned metadata":
            "Read file info"
        case "comparing existing file":
            "Checking existing file"
        default:
            phase
        }
    }

    nonisolated private static func planProgressBounds(
        for update: FileOperationProgress,
        lowerBound: Double = 0.02,
        upperBound: Double = 0.95
    ) -> (lower: Double, upper: Double) {
        let span = upperBound - lowerBound
        let phase = update.phase.lowercased()
        if phase.contains("destination") {
            return (lowerBound + span * 0.58, upperBound)
        }
        if phase.contains("missing") {
            return (upperBound, upperBound)
        }
        return (lowerBound, lowerBound + span * 0.58)
    }

    nonisolated private static func commandLine(_ arguments: [String]) -> String {
        arguments.map(quoteForCommand).joined(separator: " ")
    }

    nonisolated private static func quoteForCommand(_ value: String) -> String {
        if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))) == nil {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func runBackgroundJob<Result: Sendable>(
        action: JobAction,
        runningNote: String,
        logTitle: String,
        logDetail: String,
        command: String = "",
        sourcePath: String? = nil,
        destinationPath: String? = nil,
        operation: @escaping @Sendable (@escaping @Sendable (BackgroundJobUpdate) -> Void) throws -> Result,
        completion: @escaping (Result) throws -> String
    ) {
        guard !isBusy else {
            statusMessage = "Another file job is already running. Wait for it to finish, then try again."
            return
        }

        isBusy = true
        statusMessage = runningNote

        let jobID = UUID()
        let startedJob = JobSnapshot(
            id: jobID,
            action: action,
            state: .running,
            progress: 0.02,
            note: runningNote,
            detail: logDetail,
            command: command,
            sourcePath: sourcePath,
            destinationPath: destinationPath
        )
        jobs.insert(startedJob, at: 0)

        let progressHandler: @Sendable (BackgroundJobUpdate) -> Void = { [weak self] update in
            Task { @MainActor in
                self?.updateJob(id: jobID, update: update)
            }
        }

        let worker = Task.detached(priority: .userInitiated) {
            try operation(progressHandler)
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let result = try await worker.value
                let summary = try completion(result)
                statusMessage = summary
                finishJob(
                    id: jobID,
                    action: action,
                    state: .done,
                    note: summary,
                    logTitle: logTitle,
                    logDetail: logDetail
                )
            } catch is CancellationError {
                let summary = "Cancelled."
                statusMessage = summary
                finishJob(
                    id: jobID,
                    action: action,
                    state: .cancelled,
                    note: summary,
                    logTitle: logTitle,
                    logDetail: logDetail
                )
            } catch {
                let summary = error.localizedDescription
                statusMessage = summary
                finishJob(
                    id: jobID,
                    action: action,
                    state: .failed,
                    note: summary,
                    logTitle: logTitle,
                    logDetail: logDetail
                )
            }
        }
    }

    private func updateJob(id: UUID, update: BackgroundJobUpdate) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        jobs[index].progress = min(max(update.progress, 0), 1)
        jobs[index].note = update.note
        jobs[index].detail = update.detail.isEmpty ? jobs[index].detail : update.detail
        jobs[index].command = update.command.isEmpty ? jobs[index].command : update.command
        jobs[index].sourcePath = update.sourcePath ?? jobs[index].sourcePath
        jobs[index].destinationPath = update.destinationPath ?? jobs[index].destinationPath
        jobs[index].currentPath = update.currentPath
        jobs[index].processedFiles = update.processedFiles
        jobs[index].totalFiles = update.totalFiles
        jobs[index].processedBytes = update.processedBytes
        jobs[index].totalBytes = update.totalBytes
        jobs[index].bytesPerSecond = update.bytesPerSecond
    }

    private func finishJob(
        id: UUID,
        action: JobAction,
        state: JobState,
        note: String,
        logTitle: String,
        logDetail: String
    ) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].state = state
            jobs[index].progress = 1
            jobs[index].note = note
            jobs[index].finishedAt = Date()
        }

        recordActivity(
            action: action,
            state: state,
            title: logTitle,
            summary: note,
            detail: logDetail
        )
        isBusy = false
    }

    private func recordActivity(action: JobAction, state: JobState, title: String, summary: String, detail: String) {
        let entry = ActivityLogEntry(
            action: action,
            state: state,
            title: title,
            summary: summary,
            detail: detail
        )
        activityLog.insert(entry, at: 0)
        do {
            try ActivityLogStore(url: URL(fileURLWithPath: Self.expandedPath(configuration.activityLogPath))).append(entry)
        } catch {
            statusMessage = "Saved action on screen, but could not write permanent log: \(error.localizedDescription)"
        }
    }

    private func updateConfiguration(_ mutate: (inout AppConfiguration) -> Void) {
        var next = configuration
        mutate(&next)
        next.normalizeLocationSelections()
        next.normalizeEventSelection()
        configuration = next
        do {
            try configurationStore.save(next)
            configMessage = "Config saved at \(Self.defaultConfigurationURL.path)."
        } catch {
            configMessage = "Could not save config: \(error.localizedDescription)"
        }
        scheduleCatalogSync(configuration: next)
    }

    private func scheduleCatalogSync(configuration: AppConfiguration) {
        let catalogURL = URL(fileURLWithPath: Self.expandedPath(configuration.catalogDatabasePath))
        catalogSyncTask?.cancel()
        catalogSyncTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let snapshot = configuration
            let errorMessage = await Task.detached(priority: .utility) {
                do {
                    _ = try CatalogStore(url: catalogURL).bootstrap(
                        configuration: snapshot,
                        createBackup: false,
                        createLibraryFolders: false
                    )
                    return String?.none
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let errorMessage {
                catalogMessage = "Config saved, but the photo list could not sync: \(errorMessage)"
            }
        }
    }

    private static var defaultApplicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private static var defaultConfigurationURL: URL {
        defaultApplicationSupportURL.appendingPathComponent("CameraToolkit/config.json")
    }

    private static let immichAPIKeyAccount = "immich-api-key"

    static func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private func setSelectedLocationPath(role: ConfiguredLocationRole, to value: String) {
        updateConfiguration { configuration in
            let selectedID = configuration.selectedLocationID(for: role)
            if let selectedID,
               let index = configuration.configuredLocations.firstIndex(where: { $0.id == selectedID }) {
                configuration.configuredLocations[index].path = value
                configuration.selectLocation(configuration.configuredLocations[index])
                return
            }

            let location = ConfiguredLocation(
                role: role,
                name: defaultLocationName(for: URL(fileURLWithPath: value), role: role),
                path: value
            )
            configuration.configuredLocations.append(location)
            configuration.selectLocation(location)
        }
    }

    private func defaultLocationName(for url: URL, role: ConfiguredLocationRole) -> String {
        let lastPathComponent = url.lastPathComponent
        if !lastPathComponent.isEmpty {
            return lastPathComponent
        }
        return role.displayName
    }
}

private extension AppConfiguration {
    mutating func setCameraLibraryRoot(_ path: String) {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        cameraLibraryRootPath = root.path
        archivePath = root.appendingPathComponent(CameraLibraryFolder.originals.rawValue, isDirectory: true).path
        catalogBackupFolderPath = root
            .appendingPathComponent(CameraLibraryFolder.manifests.rawValue, isDirectory: true)
            .appendingPathComponent("CameraToolkit", isDirectory: true)
            .appendingPathComponent("catalog-backups", isDirectory: true)
            .path
        upsertLocation(role: .archive, name: "Library Originals", path: archivePath, select: true)
    }

    mutating func upsertLocation(role: ConfiguredLocationRole, name: String, path: String, select: Bool) {
        if let index = configuredLocations.firstIndex(where: { $0.role == role && ($0.path == path || $0.name == name) }) {
            configuredLocations[index].name = name
            configuredLocations[index].path = path
            if select {
                selectLocation(configuredLocations[index])
            }
            return
        }

        let location = ConfiguredLocation(role: role, name: name, path: path)
        configuredLocations.append(location)
        if select {
            selectLocation(location)
        }
    }

    mutating func selectLocation(_ location: ConfiguredLocation) {
        switch location.role {
        case .importSource:
            selectedImportSourceID = location.id
            importSourcePath = location.path
        case .archive:
            selectedArchiveID = location.id
            archivePath = location.path
        case .buffer:
            selectedBufferID = location.id
            bufferPath = location.path
        }
    }
}
