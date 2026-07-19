import CameraToolkitCore
import AppKit
import Foundation
import Observation

private struct SeedSimulationJobResult: Sendable {
    var sourcePath: String
    var plan: CopyPlan
}

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

private struct SimulationJobResult: Sendable {
    var summary: SimulationSummary
    var plan: CopyPlan
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
    var selectedSection: AppSection = .overview
    var isSidebarCollapsed: Bool = false
    var locations: [LocationCard]
    var activePlan: CopyPlan
    var organizedArchivePlan = OrganizedArchivePlan()
    var queuedFilePaths: Set<String> = []
    var workflowPlans: [WorkflowPlan] = []
    var jobs: [JobSnapshot]
    var activityLog: [ActivityLogEntry]
    var configuration: AppConfiguration
    var configMessage: String = "Config is saved automatically."
    var safetyChecks: [SafetyCheck]
    var simulationSummary: SimulationSummary?
    var statusMessage: String = "Ready. Setup is loaded; real write/delete/upload buttons stay locked unless explicitly enabled."
    var isBusy: Bool = false
    var libraryFiles: [FileRecord] = []
    var lastOpenedWorkingCopyPath: String?
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
    @ObservationIgnored private let editorLauncher = ExternalEditorLauncher()
    @ObservationIgnored private var immichHasUsableAPIKey: Bool = false
    @ObservationIgnored private var catalogSyncTask: Task<Void, Never>?
    @ObservationIgnored private var locationRefreshTask: Task<Void, Never>?

    init(
        locations: [LocationCard],
        activePlan: CopyPlan,
        jobs: [JobSnapshot],
        activityLog: [ActivityLogEntry] = [],
        configuration: AppConfiguration = .defaults(applicationSupport: DashboardModel.defaultApplicationSupportURL),
        safetyChecks: [SafetyCheck],
        configurationStore: ConfigurationStore = ConfigurationStore(url: DashboardModel.defaultConfigurationURL),
        loadActivityLog: Bool = false
    ) {
        self.locations = locations
        self.activePlan = activePlan
        self.jobs = jobs
        self.safetyChecks = safetyChecks
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
        rebuildWorkflowPlans()
    }

    static func live() -> DashboardModel {
        let defaults = AppConfiguration.defaults(applicationSupport: defaultApplicationSupportURL)
        let store = ConfigurationStore(url: defaultConfigurationURL)
        var configuration = (try? store.load(defaults: defaults)) ?? defaults
        configuration.migrateKnownCameraToolkitPaths()
        try? store.save(configuration)

        let model = DashboardModel(
            locations: preview.locations,
            activePlan: preview.activePlan,
            jobs: [],
            configuration: configuration,
            safetyChecks: preview.safetyChecks,
            configurationStore: store,
            loadActivityLog: true
        )
        model.refreshLocationCards()
        model.scheduleCatalogSync(configuration: configuration)
        return model
    }

    static let preview = DashboardModel(
        locations: [
            LocationCard(kind: .card, title: "Camera Folder", subtitle: "Sony A7V detected", status: .ready, detail: "5 new files · 48.2 GB"),
            LocationCard(kind: .drive, title: "Portable Drive", subtitle: "Photo Workspace", status: .warning, detail: "312 GB free"),
            LocationCard(kind: .nas, title: "Home Server", subtitle: "Photo Library", status: .ready, detail: "Mounted · ready to check"),
            LocationCard(kind: .immich, title: "Immich", subtitle: "Photo library", status: .ready, detail: "Connected")
        ],
        activePlan: CopyPlan(
            new: [
                FileRecord(path: "DCIM/100MSDCF/DSC00001.ARW", size: 44_200_000, modifiedAt: .now),
                FileRecord(path: "DCIM/100MSDCF/DSC00002.ARW", size: 45_100_000, modifiedAt: .now),
                FileRecord(path: "M4ROOT/CLIP/C0001.MP4", size: 2_800_000_000, modifiedAt: .now)
            ],
            existing: [
                FileRecord(path: "DCIM/100MSDCF/DSC00003.JPG", size: 8_200_000, modifiedAt: .now)
            ],
            conflicts: []
        ),
        jobs: [
            JobSnapshot(action: .previewFiles, state: .running, progress: 0.42, note: "Checking what would copy"),
            JobSnapshot(action: .immichScan, state: .done, progress: 1, note: "Library scan queued")
        ],
        activityLog: [
            ActivityLogEntry(
                action: .verifyManifest,
                state: .done,
                title: "Completed safety test",
                summary: "4 copied, 1 moved aside, 1 left alone.",
                detail: "Created disposable test files, checked the proof file, and moved aside only verified buffer files."
            ),
            ActivityLogEntry(
                action: .previewFiles,
                state: .done,
                title: "Previewed copy to buffer",
                summary: "3 new files, 1 already in buffer, 0 conflicts.",
                detail: "No files were copied during preview."
            )
        ],
        configuration: .defaults(applicationSupport: defaultApplicationSupportURL),
        safetyChecks: [
            SafetyCheck(
                title: "No-overwrite copy",
                detail: "Copy checks bytes and refuses overwrites.",
                state: .passed,
                helpText: "Photo library writes must check bytes and refuse overwrites. If a file already exists with different bytes, the app reports a conflict instead of replacing it."
            ),
            SafetyCheck(
                title: "Clear-space check",
                detail: "Compare files before moving anything aside",
                state: .passed,
                helpText: "Clearing space means making room on temporary storage. The app only moves a buffer file aside after proving the photo library has the same bytes."
            ),
            SafetyCheck(
                title: "Permanent delete",
                detail: "Requires typed DELETE confirmation",
                state: .passed,
                helpText: "The real delete path stays behind an explicit typed confirmation. Safety tests move files aside only."
            ),
            SafetyCheck(
                title: "Real writes lock",
                detail: "Real writes and uploads require deliberate unlock",
                state: .attention,
                helpText: "Real camera folders, drives, photo libraries, and Immich uploads are represented by locked move plans. Immich connection checks are allowed because they do not move files."
            )
        ]
    )
}

extension DashboardModel {
    var setupPresets: [CameraSetupPreset] {
        CameraSetupPreset.defaults.map { preset in
            var preset = preset
            preset.isAvailable = preset.requiredPaths.allSatisfy(folderExists)
            preset.isApplied = preset.matches(configuration)
            return preset
        }
    }

    var setupChecklist: [SetupChecklistItem] {
        let sourceCount = configuration.locations(role: .importSource).count
        return [
            SetupChecklistItem(
                title: "Camera Library",
                detail: configuration.cameraLibraryRootPath,
                isReady: folderExists(configuration.cameraLibraryRootPath)
            ),
            SetupChecklistItem(
                title: "From Folders",
                detail: sourceCount == 1 ? "1 folder" : "\(sourceCount) folders",
                isReady: sourceCount > 0 && folderExists(configuration.importSourcePath)
            ),
            SetupChecklistItem(
                title: "Buffer",
                detail: configuration.bufferPath,
                isReady: folderExists(configuration.bufferPath)
            ),
            SetupChecklistItem(
                title: "Photo List",
                detail: configuration.catalogDatabasePath,
                isReady: catalogDatabaseExists
            ),
            SetupChecklistItem(
                title: "Photo List Backup",
                detail: configuration.catalogBackupFolderPath,
                isReady: catalogBackupFolderExists
            )
        ]
    }

    var queuedFiles: [FileRecord] {
        var candidates: [String: FileRecord] = [:]
        for file in activePlan.new + selectedEventFiles {
            candidates[file.path] = file
        }
        return queuedFilePaths.compactMap { candidates[$0] }.sorted { $0.path < $1.path }
    }

    var queuedBytes: Int64 {
        queuedFiles.reduce(0) { $0 + $1.size }
    }

    var queueSummary: String {
        if queuedFiles.isEmpty {
            return "No files queued."
        }
        return "\(queuedFiles.count) file(s), \(queuedBytes.formattedBytes)"
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

    func assignedEvent(for file: FileRecord) -> SavedCameraEvent? {
        let root = URL(fileURLWithPath: expandedImportSourcePath, isDirectory: true).standardizedFileURL.path
        guard let assignment = configuration.photoEventAssignments.last(where: {
            $0.matches(sourceRootPath: root, file: file)
        }) else { return nil }
        return configuration.savedEvents.first { $0.id == assignment.eventID }
    }

    var cameraLibraryFolderRows: [SetupPathStatus] {
        CameraLibraryFolder.allCases.map { folder in
            let path = configuration.libraryFolderPath(folder).path
            return SetupPathStatus(
                title: folder.displayName,
                path: path,
                exists: folderExists(path),
                symbol: folder.symbolName
            )
        }
    }

    var catalogDatabaseExists: Bool {
        FileManager.default.fileExists(atPath: Self.expandedPath(configuration.catalogDatabasePath))
    }

    var catalogBackupFolderExists: Bool {
        folderExists(configuration.catalogBackupFolderPath)
    }

    var simulationWorkspace: SimulationWorkspace {
        SimulationWorkspace(root: URL(fileURLWithPath: Self.expandedPath(configuration.demoRootPath)))
    }

    func toggleSidebar() {
        isSidebarCollapsed.toggle()
    }

    func workflowPlan(_ kind: WorkflowPlanKind) -> WorkflowPlan? {
        workflowPlans.first { $0.kind == kind }
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

    func isQueued(_ file: FileRecord) -> Bool {
        queuedFilePaths.contains(file.path)
    }

    func toggleQueuedFile(_ file: FileRecord) {
        if queuedFilePaths.contains(file.path) {
            queuedFilePaths.remove(file.path)
        } else {
            queuedFilePaths.insert(file.path)
        }
    }

    func queueAllNewFiles() {
        queuedFilePaths = Set(activePlan.new.map(\.path))
        statusMessage = activePlan.new.isEmpty
            ? "No new files to queue. Preview files first, or pick a different from folder."
            : "Queued \(activePlan.new.count) new file(s) for the next copy."
    }

    func clearQueue() {
        queuedFilePaths.removeAll()
        statusMessage = "Queue cleared."
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
            refreshLocationCards()
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

    func chooseImportFolder() {
        if chooseFolder(title: "Choose From Folder", keyPath: \.importSourcePath) {
            statusMessage = "Selected \(URL(fileURLWithPath: configuration.importSourcePath).lastPathComponent). Use Preview Copy to check what would go into the buffer."
            recordActivity(
                action: .previewFiles,
                state: .done,
                title: "Selected from folder",
                summary: statusMessage,
                detail: "The selected folder will be scanned locally. Real writes remain locked; safety tests use disposable local folders."
            )
        }
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

    func chooseEditorWorkingFolder() {
        if chooseFolder(title: "Choose Edit Folder", keyPath: \.editorWorkingFolderPath) {
            statusMessage = "Edit copies will open from \(configuration.editorWorkingFolderPath)."
        }
    }

    func chooseBufferFolder() {
        if chooseFolder(title: "Choose Buffer Folder", keyPath: \.bufferPath) {
            statusMessage = "Buffer set to \(configuration.bufferPath)."
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

    func applyRecommendedCameraSetup() {
        let recommended = RecommendedCameraSetup.detect()
        updateConfiguration { configuration in
            if let libraryRoot = recommended.libraryRoot {
                configuration.setCameraLibraryRoot(libraryRoot.path)
            }
            if let osmo = recommended.osmoSource {
                configuration.upsertLocation(role: .importSource, name: "Osmo 360", path: osmo.path, select: true)
            }
            if let lexar = recommended.lexarSource {
                configuration.upsertLocation(role: .importSource, name: "Camera Card", path: lexar.path, select: recommended.osmoSource == nil)
            }
            if let buffer = recommended.buffer {
                configuration.upsertLocation(role: .buffer, name: "Photo Workspace Photos", path: buffer.path, select: true)
            }
        }
        statusMessage = recommended.summary
    }

    func applySetupPreset(_ preset: CameraSetupPreset) {
        updateConfiguration { configuration in
            if let sourcePath = preset.sourcePath {
                configuration.upsertLocation(
                    role: .importSource,
                    name: preset.sourceName ?? preset.title,
                    path: sourcePath,
                    select: true
                )
            }
            if let bufferPath = preset.bufferPath {
                configuration.upsertLocation(
                    role: .buffer,
                    name: preset.bufferName ?? "Buffer",
                    path: bufferPath,
                    select: true
                )
            }
            if let libraryRootPath = preset.libraryRootPath {
                configuration.setCameraLibraryRoot(libraryRootPath)
            }
            if let deviceID = preset.deviceID {
                configuration.selectedDeviceID = deviceID
            }
            if let destination = preset.importDestination {
                configuration.importDestination = destination
            }
            configuration.beginNewBatch()
        }
        activePlan = CopyPlan()
        queuedFilePaths.removeAll()
        statusMessage = "Applied \(preset.title). No files were moved. Preview Files before copying anything."
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
            refreshLocationCards()
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

    func setImportDestination(_ value: TransferLocation) {
        updateConfiguration { $0.importDestination = value }
    }

    func setImmichServerURL(_ value: String) {
        updateConfiguration { $0.immichServerURL = value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func setExternalEditor(_ value: ExternalEditor) {
        updateConfiguration { $0.externalEditor = value }
    }

    func setRcloneBinaryPath(_ value: String) {
        updateConfiguration { $0.rcloneBinaryPath = value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func setExiftoolBinaryPath(_ value: String) {
        updateConfiguration { $0.exiftoolBinaryPath = value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func saveImmichAPIKey() {
        do {
            try secretStore.save(immichAPIKeyDraft, account: Self.immichAPIKeyAccount)
            immichHasUsableAPIKey = !immichAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            rebuildWorkflowPlans()
            immichConnectionStatus = immichAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "API key removed from Keychain."
                : "API key saved in Keychain."
            configMessage = "Immich API key saved in macOS Keychain."
        } catch {
            immichHasUsableAPIKey = false
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
            immichHasUsableAPIKey = false
            rebuildWorkflowPlans()
            immichConnectionStatus = "Could not read Immich API key from Keychain: \(error.localizedDescription)"
            return
        }

        guard !apiKey.isEmpty else {
            immichHasUsableAPIKey = false
            rebuildWorkflowPlans()
            immichConnectionStatus = "Paste an Immich API key, or save one first, then test again."
            return
        }

        immichHasUsableAPIKey = true
        rebuildWorkflowPlans()
        Task { @MainActor in
            await performImmichConnectionCheck(serverURL: serverURL, apiKey: apiKey, shouldRecordActivity: true)
        }
    }

    func refreshLibraryFiles() {
        let sourcePath = expandedImportSourcePath
        let root = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let command = Self.commandLine(["scan-photos", sourcePath])
        runBackgroundJob(
            action: .checkout,
            runningNote: "Scanning photos in the background",
            logTitle: "Scanned photos",
            logDetail: "Read file info from \(sourcePath). No files were moved.",
            command: command,
            sourcePath: sourcePath,
            operation: { progress in
                try FileScanner().scan(root: root) { update in
                    progress(Self.jobUpdate(from: update, notePrefix: "Scanning photos", command: command, sourcePath: sourcePath))
                }
                    .filter { MediaFileMatcher.isSupportedPhotoPath($0.path) }
            },
            completion: { records in
                self.libraryFiles = records
                return records.isEmpty
                    ? "No supported photo files found in \(sourcePath)."
                    : "Found \(records.count) supported photo file(s) in \(sourcePath)."
            }
        )
    }

    func openLibraryFile(_ file: FileRecord) {
        do {
            let source = try sourceURL(for: file)
            let workingRoot = URL(
                fileURLWithPath: Self.expandedPath(configuration.editorWorkingFolderPath),
                isDirectory: true
            )
            let copyURL = try editorLauncher.openWorkingCopy(
                source: source,
                editor: configuration.externalEditor,
                workingRoot: workingRoot
            )
            lastOpenedWorkingCopyPath = copyURL.path
            statusMessage = "Opened \(file.path) in \(configuration.externalEditor.displayName) from a protected edit copy."
            recordActivity(
                action: .checkout,
                state: .done,
                title: "Opened photo for editing",
                summary: statusMessage,
                detail: "Original stayed untouched. Edit copy: \(copyURL.path)"
            )
        } catch {
            statusMessage = "Could not open \(file.path): \(error.localizedDescription)"
            recordActivity(
                action: .checkout,
                state: .failed,
                title: "Photo open failed",
                summary: statusMessage,
                detail: "No original file was changed."
            )
        }
    }

    func planFileSourceURL(_ file: FileRecord) -> URL? {
        guard let source = try? sourceURL(for: file),
              FileManager.default.fileExists(atPath: source.path) else {
            return nil
        }
        return source
    }

    func openPlanFile(_ file: FileRecord) {
        do {
            let source = try existingSourceURL(for: file)
            let workingRoot = URL(
                fileURLWithPath: Self.expandedPath(configuration.editorWorkingFolderPath),
                isDirectory: true
            )
            let copyURL = try editorLauncher.openWorkingCopy(
                source: source,
                editor: configuration.externalEditor,
                workingRoot: workingRoot
            )
            lastOpenedWorkingCopyPath = copyURL.path
            statusMessage = "Opened \(file.path) from Preview Copy in \(configuration.externalEditor.displayName)."
            recordActivity(
                action: .checkout,
                state: .done,
                title: "Opened previewed file",
                summary: statusMessage,
                detail: "Original stayed untouched. Edit copy: \(copyURL.path)"
            )
        } catch {
            statusMessage = "Could not open \(file.path): \(error.localizedDescription)"
            recordActivity(
                action: .checkout,
                state: .failed,
                title: "Previewed file open failed",
                summary: statusMessage,
                detail: "No original file was changed."
            )
        }
    }

    func revealPlanFileInFinder(_ file: FileRecord) {
        do {
            let source = try existingSourceURL(for: file)
            NSWorkspace.shared.activateFileViewerSelecting([source])
            statusMessage = "Revealed \(file.path) in Finder."
            recordActivity(
                action: .checkout,
                state: .done,
                title: "Revealed previewed file",
                summary: statusMessage,
                detail: "No files were changed. Original: \(source.path)"
            )
        } catch {
            statusMessage = "Could not reveal \(file.path): \(error.localizedDescription)"
            recordActivity(
                action: .checkout,
                state: .failed,
                title: "Previewed file reveal failed",
                summary: statusMessage,
                detail: "No original file was changed."
            )
        }
    }

    func seedSimulation() {
        let rootPath = Self.expandedPath(configuration.demoRootPath)
        let command = Self.commandLine(["seed-test-data", rootPath])
        runBackgroundJob(
            action: .prepareTestData,
            runningNote: "Creating disposable from folder, test library, and buffer",
            logTitle: "Created test data",
            logDetail: "Recreated the disposable from folder, test library, and buffer under Application Support.",
            command: command,
            destinationPath: rootPath,
            operation: { progress in
                progress(BackgroundJobUpdate(progress: 0.15, note: "Resetting disposable folders", command: command, destinationPath: rootPath))
                let workspace = SimulationWorkspace(root: URL(fileURLWithPath: rootPath, isDirectory: true))
                try workspace.resetAndSeed()
                let source = workspace.sourceCard
                let archive = workspace.archive
                let sourcePath = source.path
                let archivePath = archive.path
                progress(BackgroundJobUpdate(progress: 0.7, note: "Building initial copy preview", command: command, sourcePath: sourcePath, destinationPath: archivePath))
                return SeedSimulationJobResult(
                    sourcePath: sourcePath,
                    plan: try ArchivePlanner().planCopy(source: source, destination: archive) { update in
                        progress(Self.jobUpdate(from: update, lowerBound: 0.7, upperBound: 0.95, notePrefix: "Checking test files", command: command, sourcePath: sourcePath, destinationPath: archivePath))
                    }
                )
            },
            completion: { result in
                self.setConfigPath(\.importSourcePath, to: result.sourcePath)
                self.activePlan = result.plan
                self.simulationSummary = nil
                self.refreshLocationCards()
                return "Test data is ready at \(rootPath)."
            }
        )
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
            runningNote: "Checking the card, workspace, and NAS folders",
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
                    progress(Self.jobUpdate(from: update, lowerBound: 0.60, upperBound: 0.97, notePrefix: "Checking NAS folders", command: command, sourcePath: sourcePath, destinationPath: libraryPath))
                }
                return SafeImportPreviewResult(buffer: bufferPlan, archive: archivePlan)
            },
            completion: { result in
                self.activePlan = result.buffer
                self.organizedArchivePlan = result.archive
                self.queuedFilePaths = Set(result.buffer.new.map(\.path))
                return "Preview ready: \(result.buffer.new.count) need copying to Crucial; \(result.archive.new.count) need archiving to NAS; \(result.buffer.conflicts.count + result.archive.conflicts.count) conflict(s)."
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
                return "Fast event preview ready: \(result.buffer.new.count) need copying to Crucial; \(result.archive.new.count) need archiving to NAS; \(result.buffer.conflicts.count + result.archive.conflicts.count) size conflict(s). Copy + Verify performs the checksum check."
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
                self.refreshLocationCards()
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
                self.refreshLocationCards()
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
            statusMessage = "Copy and checksum-verify the event files on Crucial before archiving to the NAS."
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
            runningNote: "Organizing and verifying permanent originals on the NAS",
            logTitle: "Archived verified originals to NAS",
            logDetail: "Copied from the verified Crucial workspace into event folders. Existing conflicts were never overwritten, and a checksum manifest was written.",
            command: command,
            sourcePath: sourcePath,
            destinationPath: libraryPath,
            operation: { progress in
                let planner = OrganizedArchivePlanner()
                let plan = try planner.plan(source: source, libraryRoot: library, layout: layout) { update in
                    progress(Self.jobUpdate(from: update, lowerBound: 0.02, upperBound: 0.34, notePrefix: "Planning NAS archive", command: command, sourcePath: sourcePath, destinationPath: libraryPath))
                }
                let result = try OrganizedArchiveService().archive(source: source, libraryRoot: library, plan: plan) { update in
                    progress(Self.jobUpdate(from: update, lowerBound: 0.34, upperBound: 0.88, notePrefix: "Archiving to NAS", command: command, sourcePath: sourcePath, destinationPath: libraryPath))
                }
                let verifiedPlan = try planner.plan(source: source, libraryRoot: library, layout: layout) { update in
                    progress(Self.jobUpdate(from: update, lowerBound: 0.88, upperBound: 0.98, notePrefix: "Final NAS verification", command: command, sourcePath: sourcePath, destinationPath: libraryPath))
                }
                return OrganizedArchiveJobResult(copy: result, plan: verifiedPlan)
            },
            completion: { result in
                self.organizedArchivePlan = result.plan
                self.refreshLocationCards()
                let proof = result.copy.manifestPath.map { " Proof: \($0)" } ?? ""
                return "NAS archive verified: \(result.copy.copied.count) copied, \(result.copy.skippedIdentical.count) already safe, \(result.copy.conflicts.count) conflict(s) left untouched.\(proof)"
            }
        )
    }

    func runBufferSpeedTest() {
        let folderPath = expandedBufferRootPath
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let command = Self.commandLine(["disk-speed-test", "--write-read", folderPath])
        runBackgroundJob(
            action: .diskSpeed,
            runningNote: "Measuring buffer write and read speed",
            logTitle: "Measured buffer speed",
            logDetail: "Wrote and read a temporary test file in the configured buffer folder, then removed it.",
            command: command,
            sourcePath: folderPath,
            operation: { progress in
                try DiskSpeedTester().run(folder: folder) { update in
                    progress(Self.jobUpdate(from: update, notePrefix: "Testing buffer speed", command: command, sourcePath: folderPath))
                }
            },
            completion: { report in
                let write = Int64(report.writeBytesPerSecond).formattedBytes
                let read = Int64(report.readBytesPerSecond).formattedBytes
                return "Buffer speed: write \(write)/s, read \(read)/s at \(report.path)."
            }
        )
    }

    func runLibraryNetworkSpeedTest() {
        let folderPath = expandedLibraryRootPath
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let command = Self.commandLine(["network-speed-test", "--write-read", folderPath])
        runBackgroundJob(
            action: .networkSpeed,
            runningNote: "Measuring photo library write and read speed",
            logTitle: "Measured photo library speed",
            logDetail: "Wrote and read a temporary test file in the configured library folder, then removed it.",
            command: command,
            sourcePath: folderPath,
            operation: { progress in
                try DiskSpeedTester().run(folder: folder) { update in
                    progress(Self.jobUpdate(from: update, notePrefix: "Testing photo library speed", command: command, sourcePath: folderPath))
                }
            },
            completion: { report in
                let write = Int64(report.writeBytesPerSecond).formattedBytes
                let read = Int64(report.readBytesPerSecond).formattedBytes
                return "Photo library speed: write \(write)/s, read \(read)/s at \(report.path)."
            }
        )
    }

    func runSimulationImport() {
        let rootPath = Self.expandedPath(configuration.demoRootPath)
        let existingQuarantinedCount = simulationSummary?.quarantinedCount ?? 0
        let command = Self.commandLine(["run-safety-import", rootPath])
        runBackgroundJob(
            action: .ingestCard,
            runningNote: "Copying into the test library",
            logTitle: "Ran copy test",
            logDetail: "Copied new files into the test library, refused overwrites, checked bytes, and wrote a proof file.",
            command: command,
            destinationPath: rootPath,
            operation: { progress in
                let workspace = SimulationWorkspace(root: URL(fileURLWithPath: rootPath, isDirectory: true))
                let source = workspace.sourceCard
                let archive = workspace.archive
                let sourcePath = source.path
                let archivePath = archive.path
                progress(BackgroundJobUpdate(progress: 0.12, note: "Preparing disposable import test", command: command, sourcePath: sourcePath, destinationPath: archivePath))
                let result = try workspace.runImport()
                progress(BackgroundJobUpdate(progress: 0.8, note: "Refreshing import test plan", command: command, sourcePath: sourcePath, destinationPath: archivePath))
                let summary = SimulationSummary(
                    root: workspace.root.path,
                    sourcePath: sourcePath,
                    archivePath: archivePath,
                    bufferPath: workspace.buffer.path,
                    manifestOK: result.manifest.ok,
                    copiedCount: result.copy.copied.count,
                    quarantinedCount: existingQuarantinedCount,
                    leftUnsafeCount: 0
                )
                return SimulationJobResult(
                    summary: summary,
                    plan: try ArchivePlanner().planCopy(source: source, destination: archive) { update in
                        progress(Self.jobUpdate(from: update, lowerBound: 0.8, upperBound: 0.95, notePrefix: "Checking test library", command: command, sourcePath: sourcePath, destinationPath: archivePath))
                    }
                )
            },
            completion: { result in
                self.simulationSummary = result.summary
                self.activePlan = result.plan
                self.refreshLocationCards()
                return "Copy test passed. Proof file: \(result.summary.manifestOK ? "yes" : "no")."
            }
        )
    }

    func runSimulationFreeUp() {
        let rootPath = Self.expandedPath(configuration.demoRootPath)
        let manifestOK = simulationSummary?.manifestOK ?? false
        let copiedCount = simulationSummary?.copiedCount ?? 0
        let command = Self.commandLine(["run-free-up-test", rootPath])
        runBackgroundJob(
            action: .freeUp,
            runningNote: "Checking buffer files before moving them aside",
            logTitle: "Ran clear-space test",
            logDetail: "Moved only disposable buffer files that matched the test library into the move-aside folder.",
            command: command,
            destinationPath: rootPath,
            operation: { progress in
                let workspace = SimulationWorkspace(root: URL(fileURLWithPath: rootPath, isDirectory: true))
                let bufferPath = workspace.buffer.path
                let archivePath = workspace.archive.path
                progress(BackgroundJobUpdate(progress: 0.18, note: "Comparing buffer against library", command: command, sourcePath: bufferPath, destinationPath: archivePath))
                let report = try workspace.runFreeUp()
                progress(BackgroundJobUpdate(progress: 0.92, note: "Finishing move-aside report", command: command, sourcePath: bufferPath, destinationPath: archivePath))
                return SimulationSummary(
                    root: workspace.root.path,
                    sourcePath: workspace.sourceCard.path,
                    archivePath: workspace.archive.path,
                    bufferPath: workspace.buffer.path,
                    manifestOK: manifestOK,
                    copiedCount: copiedCount,
                    quarantinedCount: report.moved.count,
                    leftUnsafeCount: report.notOnArchive.count + report.differ.count + report.errors.count
                )
            },
            completion: { summary in
                self.simulationSummary = summary
                self.refreshLocationCards()
                return "Clear-space test moved aside \(summary.quarantinedCount) verified files and left \(summary.leftUnsafeCount) file(s) alone."
            }
        )
    }

    func runFullSimulation() {
        let rootPath = Self.expandedPath(configuration.demoRootPath)
        let command = Self.commandLine(["run-full-safety-test", rootPath])
        runBackgroundJob(
            action: .verifyManifest,
            runningNote: "Running the full safety test in the background",
            logTitle: "Completed safety test",
            logDetail: "Created disposable test files, copied new files to the test library, checked the proof file, and moved aside only proven-safe buffer files.",
            command: command,
            destinationPath: rootPath,
            operation: { progress in
                let workspace = SimulationWorkspace(root: URL(fileURLWithPath: rootPath, isDirectory: true))
                progress(BackgroundJobUpdate(progress: 0.08, note: "Creating disposable safety test data", command: command, destinationPath: workspace.root.path))
                let summary = try workspace.runFullSimulation()
                let source = workspace.sourceCard
                let archive = workspace.archive
                let sourcePath = source.path
                let archivePath = archive.path
                progress(BackgroundJobUpdate(progress: 0.84, note: "Refreshing final safety plan", command: command, sourcePath: sourcePath, destinationPath: archivePath))
                return SimulationJobResult(
                    summary: summary,
                    plan: try ArchivePlanner().planCopy(source: source, destination: archive) { update in
                        progress(Self.jobUpdate(from: update, lowerBound: 0.84, upperBound: 0.96, notePrefix: "Checking final test state", command: command, sourcePath: sourcePath, destinationPath: archivePath))
                    }
                )
            },
            completion: { result in
                self.simulationSummary = result.summary
                self.setConfigPath(\.importSourcePath, to: result.summary.sourcePath)
                self.activePlan = result.plan
                self.refreshLocationCards()
                return "Safety test complete: \(result.summary.copiedCount) copied, \(result.summary.quarantinedCount) moved aside, \(result.summary.leftUnsafeCount) left alone."
            }
        )
    }

    private var expandedImportSourcePath: String {
        Self.expandedPath(configuration.importSourcePath)
    }

    var expandedBufferIngestPath: String {
        Self.expandedPath(configuration.bufferIngestFolderPath())
    }

    var expandedBufferRootPath: String {
        Self.expandedPath(configuration.bufferPath)
    }

    var expandedBufferExportsPath: String {
        Self.expandedPath(configuration.bufferExportsFolderPath())
    }

    var expandedBufferEditsPath: String {
        Self.expandedPath(configuration.bufferEditsFolderPath())
    }

    var expandedLibraryOriginalsPath: String {
        Self.expandedPath(configuration.libraryBatchFolderPath(.originals))
    }

    var expandedLibraryRootPath: String {
        Self.expandedPath(configuration.cameraLibraryRootPath)
    }

    var expandedLibraryEditedPath: String {
        Self.expandedPath(configuration.libraryBatchFolderPath(.edited))
    }

    var expandedEditorWorkingFolderPath: String {
        Self.expandedPath(configuration.editorWorkingFolderPath)
    }

    private func refreshAllNow() async {
        defer {
            isRefreshing = false
            lastRefreshedAt = Date()
            refreshLocationCards()
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
        rebuildWorkflowPlans()

        statusMessage = "Refreshed latest: \(notes.joined(separator: ", "))."
        rebuildWorkflowPlans()
    }

    @discardableResult
    private func loadLibraryFiles() throws -> [FileRecord] {
        let root = URL(fileURLWithPath: expandedImportSourcePath, isDirectory: true)
        let records = try FileScanner().scan(root: root)
            .filter { MediaFileMatcher.isSupportedPhotoPath($0.path) }
        libraryFiles = records
        return records
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
            refreshLocationCards()
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
            refreshLocationCards()
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
        rebuildWorkflowPlans()
    }

    private func existingSourceURL(for file: FileRecord) throws -> URL {
        let source = try sourceURL(for: file)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ToolkitError.pathNotFound(source.path)
        }
        return source
    }

    private func sourceURL(for file: FileRecord) throws -> URL {
        guard !file.path.hasPrefix("/") && !file.path.contains("..") else {
            throw ToolkitError.unsafeRelativePath(file.path)
        }
        let root = URL(fileURLWithPath: expandedImportSourcePath, isDirectory: true).standardizedFileURL
        let source = root.appendingPathComponent(file.path).standardizedFileURL
        guard source.path.hasPrefix(root.path + "/") else {
            throw ToolkitError.unsafeRelativePath(file.path)
        }
        return source
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
        rebuildWorkflowPlans()
        refreshLocationCards()
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

    private func rebuildWorkflowPlans() {
        workflowPlans = WorkflowPlanner().plans(
            for: configuration,
            hasImmichAPIKey: immichHasUsableAPIKey || !immichAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private func refreshLocationCards() {
        let source = URL(fileURLWithPath: expandedImportSourcePath, isDirectory: true)
        let archive = URL(fileURLWithPath: Self.expandedPath(configuration.archivePath), isDirectory: true)
        let buffer = URL(fileURLWithPath: Self.expandedPath(configuration.bufferPath), isDirectory: true)
        let library = URL(fileURLWithPath: Self.expandedPath(configuration.cameraLibraryRootPath), isDirectory: true)
        let catalog = URL(fileURLWithPath: Self.expandedPath(configuration.catalogDatabasePath))
        let batchPath = Self.expandedPath(configuration.bufferBatchFolderPath())
        let immichCard = immichLocationCard
        locationRefreshTask?.cancel()
        locationRefreshTask = Task { @MainActor in
            let availability = await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                return (
                    source: fileManager.fileExists(atPath: source.path),
                    buffer: fileManager.fileExists(atPath: buffer.path),
                    library: fileManager.fileExists(atPath: library.path),
                    catalog: fileManager.fileExists(atPath: catalog.path)
                )
            }.value
            guard !Task.isCancelled else { return }
            locations = [
                LocationCard(kind: .card, title: "From Folder", subtitle: displayName(for: source), status: availability.source ? .ready : .warning, detail: source.path),
                LocationCard(kind: .drive, title: "Buffer", subtitle: displayName(for: buffer), status: availability.buffer ? .ready : .warning, detail: "Batch: \(batchPath)"),
                LocationCard(kind: .nas, title: "Photo Library", subtitle: displayName(for: library), status: availability.library ? .ready : .warning, detail: archive.path),
                LocationCard(kind: .mac, title: "Photo List", subtitle: displayName(for: catalog), status: availability.catalog ? .ready : .warning, detail: catalog.path),
                immichCard
            ]
        }
    }

    private func displayName(for url: URL) -> String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    private func folderExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: Self.expandedPath(path), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private var immichLocationCard: LocationCard {
        if let report = immichConnectionReport {
            return LocationCard(
                kind: .immich,
                title: "Immich",
                subtitle: report.userEmail,
                status: .ready,
                detail: "API \(report.version) at \(report.baseURL)"
            )
        }
        return LocationCard(
            kind: .immich,
            title: "Immich",
            subtitle: "Not connected",
            status: .offline,
            detail: configuration.immichServerURL.isEmpty ? "Configure in Config" : configuration.immichServerURL
        )
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
    mutating func migrateKnownCameraToolkitPaths() {
        let pathMigrations: [String: (name: String, path: String)] = [
            "/Volumes/CAMERA_CARD/TEMP": ("Camera Card · Sony A7V", "/Volumes/CAMERA_CARD"),
            "/Volumes/ACTION_CAMERA/DCIM/CAM_001": ("Action Camera · DJI Osmo 360", "/Volumes/ACTION_CAMERA"),
            "/Volumes/PHOTO_WORKSPACE/Photos": ("Photo Workspace · Camera Buffer", "/Volumes/PHOTO_WORKSPACE/Camera Buffer")
        ]

        for index in configuredLocations.indices {
            guard let migration = pathMigrations[configuredLocations[index].path] else { continue }
            configuredLocations[index].name = migration.name
            configuredLocations[index].path = migration.path
        }

        if let migration = pathMigrations[importSourcePath] {
            importSourcePath = migration.path
        }
        if let migration = pathMigrations[bufferPath] {
            bufferPath = migration.path
        }

        var seen: Set<String> = []
        configuredLocations = configuredLocations.filter { location in
            let key = "\(location.role.rawValue)|\(location.path)"
            return seen.insert(key).inserted
        }
        normalizeLocationSelections()
    }

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

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case setup = "Setup"
    case overview = "Overview"
    case `import` = "Import"
    case library = "Library"
    case drive = "Drive"
    case immich = "Immich"
    case jobs = "Jobs"
    case config = "Config"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .setup: "checklist"
        case .overview: "rectangle.grid.2x2"
        case .import: "square.and.arrow.down"
        case .library: "photo.stack"
        case .drive: "externaldrive"
        case .immich: "sparkles.rectangle.stack"
        case .jobs: "list.bullet.clipboard"
        case .config: "slider.horizontal.3"
        }
    }
}

struct SetupChecklistItem: Identifiable, Hashable {
    var id: String { title }
    var title: String
    var detail: String
    var isReady: Bool
}

struct SetupPathStatus: Identifiable, Hashable {
    var id: String { title }
    var title: String
    var path: String
    var exists: Bool
    var symbol: String
}

struct CameraSetupPreset: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String
    var effect: String
    var symbol: String
    var sourceName: String?
    var sourcePath: String?
    var bufferName: String?
    var bufferPath: String?
    var libraryRootPath: String?
    var deviceID: String?
    var importDestination: TransferLocation?
    var requiredPaths: [String]
    var isAvailable: Bool = false
    var isApplied: Bool = false

    static let defaults: [CameraSetupPreset] = [
        CameraSetupPreset(
            id: "lexar-sony-buffer",
            title: "Import Sony A7V",
            subtitle: "Camera Card card → Photo Workspace camera buffer",
            effect: "Copies the complete card, including DCIM stills, M4ROOT video, sidecars, and camera folders. The card is never changed.",
            symbol: "sdcard",
            sourceName: "Camera Card · Sony A7V",
            sourcePath: "/Volumes/CAMERA_CARD",
            bufferName: "Photo Workspace · Camera Buffer",
            bufferPath: "/Volumes/PHOTO_WORKSPACE/Camera Buffer",
            deviceID: "sony-a7v",
            importDestination: .drive,
            requiredPaths: ["/Volumes/CAMERA_CARD", "/Volumes/PHOTO_WORKSPACE"]
        ),
        CameraSetupPreset(
            id: "osmo-360-buffer",
            title: "Import DJI Osmo 360",
            subtitle: "Action Camera card → Photo Workspace camera buffer",
            effect: "Copies the complete card so full-resolution OSV/video files and MISC thumbnails or indexes remain together. The card is never changed.",
            symbol: "camera.aperture",
            sourceName: "Action Camera · DJI Osmo 360",
            sourcePath: "/Volumes/ACTION_CAMERA",
            bufferName: "Photo Workspace · Camera Buffer",
            bufferPath: "/Volumes/PHOTO_WORKSPACE/Camera Buffer",
            deviceID: "osmo-360",
            importDestination: .drive,
            requiredPaths: ["/Volumes/ACTION_CAMERA", "/Volumes/PHOTO_WORKSPACE"]
        )
    ]

    func matches(_ configuration: AppConfiguration) -> Bool {
        if let sourcePath, configuration.importSourcePath != sourcePath { return false }
        if let bufferPath, configuration.bufferPath != bufferPath { return false }
        if let libraryRootPath, configuration.cameraLibraryRootPath != libraryRootPath { return false }
        if let deviceID, configuration.selectedDeviceID != deviceID { return false }
        if let importDestination, configuration.importDestination != importDestination { return false }
        return true
    }
}

private struct RecommendedCameraSetup {
    var libraryRoot: URL?
    var osmoSource: URL?
    var lexarSource: URL?
    var buffer: URL?

    var summary: String {
        var pieces: [String] = []
        if libraryRoot != nil { pieces.append("photo library") }
        if osmoSource != nil { pieces.append("Action Camera") }
        if lexarSource != nil { pieces.append("Camera Card") }
        if buffer != nil { pieces.append("Photo Workspace") }
        if pieces.isEmpty {
            return "No recommended mounted camera folders were found."
        }
        return "Configured \(pieces.joined(separator: ", ")). No files were moved."
    }

    static func detect(fileManager: FileManager = .default) -> RecommendedCameraSetup {
        func existingDirectory(_ path: String) -> URL? {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        return RecommendedCameraSetup(
            libraryRoot: existingDirectory("/Volumes/PHOTO_LIBRARY"),
            osmoSource: existingDirectory("/Volumes/ACTION_CAMERA"),
            lexarSource: existingDirectory("/Volumes/CAMERA_CARD"),
            buffer: existingDirectory("/Volumes/PHOTO_WORKSPACE").map { $0.appendingPathComponent("Camera Buffer", isDirectory: true) }
        )
    }
}

private extension CameraLibraryFolder {
    var symbolName: String {
        switch self {
        case .inbox: "tray.and.arrow.down"
        case .manifests: "checklist.checked"
        case .originals: "archivebox"
        case .edited: "paintbrush.pointed"
        case .selects: "star"
        case .shared: "person.2"
        }
    }
}

struct LocationCard: Identifiable, Hashable {
    var id: TransferLocation { kind }
    var kind: TransferLocation
    var title: String
    var subtitle: String
    var status: LocationStatus
    var detail: String
}

enum LocationStatus: String {
    case ready = "Ready"
    case warning = "Check"
    case offline = "Offline"

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .offline: "xmark.circle.fill"
        }
    }
}

struct SafetyCheck: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var detail: String
    var state: SafetyState
    var helpText: String
}

enum SafetyState {
    case passed
    case attention
    case blocked

    var symbol: String {
        switch self {
        case .passed: "checkmark.shield.fill"
        case .attention: "clock.badge.exclamationmark"
        case .blocked: "xmark.shield.fill"
        }
    }
}
