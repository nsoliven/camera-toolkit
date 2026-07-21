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
    var phase: String
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
        phase: String = "",
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
        self.phase = phase
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
    var isStorageBenchmarkRunning: Bool = false
    var immichAPIKeyDraft: String = ""
    var immichConnectionStatus: String = "Not connected. Add your server URL and API key in Config."
    var immichConnectionReport: ImmichConnectionReport?
    var immichIsTestingConnection: Bool = false
    var trueNASAPIKeyDraft: String = ""
    var trueNASConnectionStatus: String = "Not configured. Add the TrueNAS server in Settings."
    var trueNASConnectionReport: TrueNASCapacityReport?
    var trueNASIsTestingConnection: Bool = false
    var trueNASIsInspectingCertificate: Bool = false
    var isRefreshing: Bool = false
    var lastRefreshedAt: Date?
    var catalogReport: CatalogBootstrapReport?
    var catalogMessage: String = "Photo list has not been prepared yet."
    var transferQueue: TransferQueueSnapshot?
    var pendingTransferBatches: [PendingTransferBatch]
    var storageCapacityRevision: Int = 0
    var sourceCleanupMessage: String?
    var sourceCleanupError: String?
    var selectedEventCopyAvailability = EventCopyAvailability()
    var activeJob: JobSnapshot? {
        jobs.first { $0.state == .running || $0.state == .queued }
    }
    var sourceCleanupJob: JobSnapshot? {
        jobs.first { $0.action == .freeUp }
    }
    var isSourceCleanupRunning: Bool {
        sourceCleanupJob?.state == .running || sourceCleanupJob?.state == .queued
    }
    @ObservationIgnored private let configurationStore: ConfigurationStore
    @ObservationIgnored private let transferQueueStore: TransferQueueStore
    @ObservationIgnored private let pendingTransferQueueStore: PendingTransferQueueStore
    @ObservationIgnored private let secretStore = KeychainSecretStore(service: "org.cameratoolkit.CameraToolkit")
    @ObservationIgnored private var catalogSyncTask: Task<Void, Never>?
    @ObservationIgnored private var lastTransferQueuePersistence = Date.distantPast
    @ObservationIgnored private var lastStorageCapacityRefreshRequest = Date.distantPast
    @ObservationIgnored private var eventCopyAvailabilityTask: Task<EventCopyAvailability, Never>?
    @ObservationIgnored private var eventCopyAvailabilityGeneration = UUID()

    init(
        activePlan: CopyPlan,
        jobs: [JobSnapshot],
        activityLog: [ActivityLogEntry] = [],
        configuration: AppConfiguration = .defaults(applicationSupport: DashboardModel.defaultApplicationSupportURL),
        configurationStore: ConfigurationStore = ConfigurationStore(url: DashboardModel.defaultConfigurationURL),
        transferQueueStore: TransferQueueStore? = nil,
        pendingTransferQueueStore: PendingTransferQueueStore? = nil,
        loadActivityLog: Bool = false
    ) {
        self.activePlan = activePlan
        self.jobs = jobs
        self.configuration = configuration
        self.configurationStore = configurationStore
        let resolvedTransferQueueStore = transferQueueStore ?? TransferQueueStore(
            url: configurationStore.url.deletingLastPathComponent().appendingPathComponent("transfer-queue.json")
        )
        self.transferQueueStore = resolvedTransferQueueStore
        let resolvedPendingTransferQueueStore = pendingTransferQueueStore ?? PendingTransferQueueStore(
            url: configurationStore.url.deletingLastPathComponent().appendingPathComponent("pending-transfers.json")
        )
        self.pendingTransferQueueStore = resolvedPendingTransferQueueStore
        self.pendingTransferBatches = (try? resolvedPendingTransferQueueStore.load()) ?? []
        var restoredTransferQueue = try? resolvedTransferQueueStore.load()
        if var legacyQueue = restoredTransferQueue,
           legacyQueue.phaseProcessedBytes == nil || legacyQueue.phaseTotalBytes == nil {
            legacyQueue.phaseProcessedBytes = legacyQueue.processedBytes
            legacyQueue.phaseTotalBytes = legacyQueue.totalBytes
            legacyQueue.progress = Self.transferProgress(
                processedBytes: legacyQueue.processedBytes,
                totalBytes: legacyQueue.totalBytes
            )
            restoredTransferQueue = legacyQueue
            try? resolvedTransferQueueStore.save(legacyQueue)
        }
        if var interruptedQueue = restoredTransferQueue, interruptedQueue.state == .running {
            interruptedQueue.state = .failed
            interruptedQueue.phase = "Transfer interrupted"
            interruptedQueue.message = "Camera Toolkit closed before this transfer finished. Reconnect both drives, then retry. Camera originals were untouched."
            interruptedQueue.bytesPerSecond = 0
            interruptedQueue.updatedAt = Date()
            if let activeIndex = interruptedQueue.items.firstIndex(where: {
                $0.state == .copying || $0.state == .verifying
            }) {
                interruptedQueue.items[activeIndex].state = .failed
                interruptedQueue.items[activeIndex].detail = interruptedQueue.message
            }
            restoredTransferQueue = interruptedQueue
            try? resolvedTransferQueueStore.save(interruptedQueue)
        }
        self.transferQueue = restoredTransferQueue
        if loadActivityLog {
            self.activityLog = (try? ActivityLogStore(url: URL(fileURLWithPath: Self.expandedPath(configuration.activityLogPath))).load()) ?? activityLog
        } else {
            self.activityLog = activityLog
        }
        if !configuration.immichServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.immichConnectionStatus = "Immich URL is saved. Keychain is checked only when you click Test Connection."
        }
        if !configuration.trueNASServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.trueNASConnectionStatus = "TrueNAS settings are saved. The sidebar will verify the mounted SMB dataset with the Keychain API key."
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

    private static func transferProgress(processedBytes: Int64, totalBytes: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(processedBytes) / Double(totalBytes), 0), 1)
    }

    private static func eventFileFingerprint(_ files: [FileRecord]) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for file in files.sorted(by: { $0.path < $1.path }) {
            for byte in file.path.utf8 {
                value ^= UInt64(byte)
                value &*= 1_099_511_628_211
            }
            value ^= UInt64(bitPattern: file.size)
            value &*= 1_099_511_628_211
            value ^= UInt64(bitPattern: Int64(file.modifiedAt.timeIntervalSince1970.rounded()))
            value &*= 1_099_511_628_211
        }
        return value
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

    var pendingTransferFileCount: Int {
        pendingTransferBatches.reduce(0) { $0 + $1.files.count }
    }

    var pendingTransferByteCount: Int64 {
        pendingTransferBatches.reduce(Int64(0)) { $0 + $1.totalBytes }
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

    var selectedEventCopyAvailabilityRefreshID: String {
        let eventID = configuration.selectedEventID?.uuidString ?? "none"
        let source = URL(fileURLWithPath: expandedImportSourcePath, isDirectory: true).standardizedFileURL.path
        let destination = URL(fileURLWithPath: expandedBufferIngestPath, isDirectory: true).standardizedFileURL.path
        let assignments = selectedEventFiles
        let fingerprint = Self.eventFileFingerprint(assignments)
        let transferRevision = transferQueue.map {
            "\($0.id.uuidString):\($0.state.rawValue):\($0.items.count):\($0.sourceRemovedCount)"
        } ?? "none"
        return [
            eventID,
            source,
            destination,
            String(assignments.count),
            String(fingerprint),
            String(storageCapacityRevision),
            transferRevision,
            String(pendingTransferFileCount),
        ].joined(separator: "|")
    }

    var hasSelectedEventFilesReadyToCopy: Bool {
        selectedEventCopyAvailability.phase == .ready
            && selectedEventCopyAvailability.contextID == selectedEventCopyAvailabilityRefreshID
            && selectedEventCopyAvailability.hasFilesReadyToCopy
    }

    func refreshSelectedEventCopyAvailability() async {
        let contextID = selectedEventCopyAvailabilityRefreshID
        let files = selectedEventFiles
        guard configuration.selectedEventID != nil, !files.isEmpty else {
            eventCopyAvailabilityTask?.cancel()
            selectedEventCopyAvailability = EventCopyAvailability(
                phase: .ready,
                contextID: contextID,
                assignedCount: files.count
            )
            return
        }

        selectedEventCopyAvailability = .checking(
            contextID: contextID,
            assignedCount: files.count
        )
        eventCopyAvailabilityTask?.cancel()
        let generation = UUID()
        eventCopyAvailabilityGeneration = generation

        let source = URL(fileURLWithPath: expandedImportSourcePath, isDirectory: true)
        let destination = URL(fileURLWithPath: expandedBufferIngestPath, isDirectory: true)
        let scheduledPaths = scheduledTransferPaths(sourcePath: source.path, destinationPath: destination.path)
        let task = Task.detached(priority: .utility) {
            EventCopyAvailabilityScanner.scan(
                contextID: contextID,
                files: files,
                sourceRoot: source,
                bufferRoot: destination,
                scheduledPaths: scheduledPaths
            )
        }
        eventCopyAvailabilityTask = task
        let result = await task.value

        guard !Task.isCancelled,
              generation == eventCopyAvailabilityGeneration,
              result.contextID == selectedEventCopyAvailabilityRefreshID else {
            return
        }
        selectedEventCopyAvailability = result
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
        queuedFilePaths.removeAll()
        selectedEventCopyAvailability = EventCopyAvailability()
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
        queuedFilePaths.removeAll()
        selectedEventCopyAvailability = EventCopyAvailability()
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
        selectedEventCopyAvailability = EventCopyAvailability()
        statusMessage = "Assigned \(validSelections.count) file(s)\(sourceNote) to \(event.name)."
    }

    func queueSelectedEventFiles() {
        guard selectedEventCopyAvailability.contextID == selectedEventCopyAvailabilityRefreshID,
              selectedEventCopyAvailability.phase == .ready else {
            statusMessage = "Checking which assigned files are still on the source and need copying…"
            Task { await refreshSelectedEventCopyAvailability() }
            return
        }
        let files = selectedEventCopyAvailability.filesReadyToCopy
        queuedFilePaths = Set(files.map(\.path))
        statusMessage = files.isEmpty
            ? "Nothing needs copying from this source."
            : "Queued \(files.count) file(s) that are present on the source and not already in the Buffer."
    }

    func copySelectedEventFilesToBuffer() {
        guard selectedEventCopyAvailability.contextID == selectedEventCopyAvailabilityRefreshID,
              selectedEventCopyAvailability.phase == .ready else {
            statusMessage = "Checking which assigned files are still on the source and need copying…"
            Task { await refreshSelectedEventCopyAvailability() }
            return
        }
        let files = selectedEventCopyAvailability.filesReadyToCopy
        guard !files.isEmpty else {
            statusMessage = "Nothing needs copying. Assigned files are already in the Buffer, unavailable, missing, or already queued."
            return
        }
        queuedFilePaths = Set(files.map(\.path))
        enqueueTransfer(
            files: files,
            sourcePath: expandedImportSourcePath,
            destinationPath: expandedBufferIngestPath,
            eventID: selectedEvent?.id,
            eventName: selectedEvent?.name ?? configuration.eventName,
            deviceID: configuration.selectedDeviceID
        )
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
            if location.role == .importSource,
               let inferredDeviceID = Self.inferredDeviceID(for: location) {
                configuration.selectedDeviceID = inferredDeviceID
            }
        }
        activePlan = CopyPlan()
        organizedArchivePlan = OrganizedArchivePlan()
        queuedFilePaths.removeAll()
        statusMessage = "Using \(location.name) for \(location.role.displayName)."
    }

    func matchCameraToSelectedImportSource() {
        guard let selectedID = configuration.selectedImportSourceID,
              let location = configuration.configuredLocations.first(where: { $0.id == selectedID }),
              let inferredDeviceID = Self.inferredDeviceID(for: location),
              inferredDeviceID != configuration.selectedDeviceID else {
            return
        }

        updateConfiguration { configuration in
            configuration.selectedDeviceID = inferredDeviceID
        }
        activePlan = CopyPlan()
        organizedArchivePlan = OrganizedArchivePlan()
        queuedFilePaths.removeAll()
        statusMessage = "Matched \(location.name) to \(Self.cameraDisplayName(for: inferredDeviceID))."
    }

    static func inferredDeviceID(for location: ConfiguredLocation) -> String? {
        let fingerprint = "\(location.name) \(location.path)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if fingerprint.contains("osmo") { return "osmo-360" }
        if fingerprint.contains("sony") || fingerprint.contains("a7v") { return "sony-a7v" }
        if fingerprint.contains("mini 2") || fingerprint.contains("mini-2") || fingerprint.contains("mini_2") {
            return "dji-mini-2"
        }
        if fingerprint.contains("action 6") || fingerprint.contains("action-6") || fingerprint.contains("action_6") {
            return "action-6"
        }
        if fingerprint.contains("iphone") { return "iphone" }
        return nil
    }

    private static func cameraDisplayName(for deviceID: String) -> String {
        switch deviceID {
        case "sony-a7v": "Sony A7V"
        case "osmo-360": "DJI Osmo 360"
        case "dji-mini-2": "DJI Mini 2"
        case "action-6": "DJI Action 6"
        case "iphone": "iPhone"
        default: "the selected camera"
        }
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

    func setTrueNASServerURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        updateConfiguration { configuration in
            if configuration.trueNASServerURL != trimmed {
                configuration.trueNASTLSPinnedCertificateSHA256 = ""
            }
            configuration.trueNASServerURL = trimmed
        }
        trueNASConnectionReport = nil
        trueNASConnectionStatus = trimmed.isEmpty
            ? "Not configured. Add the TrueNAS server in Settings."
            : "Server saved. Trust its certificate, save the API key, then test the NAS."
        storageCapacityRevision &+= 1
    }

    func setTrueNASUsername(_ value: String) {
        updateConfiguration { $0.trueNASUsername = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        trueNASConnectionReport = nil
        storageCapacityRevision &+= 1
    }

    func setTrueNASDataset(_ value: String) {
        updateConfiguration { $0.trueNASDataset = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        trueNASConnectionReport = nil
        storageCapacityRevision &+= 1
    }

    func trustCurrentTrueNASCertificate() {
        let serverURL = configuration.trueNASServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty else {
            trueNASConnectionStatus = "Add the TrueNAS server URL first."
            return
        }
        trueNASIsInspectingCertificate = true
        trueNASConnectionStatus = "Reading the TrueNAS TLS certificate…"
        Task { @MainActor in
            defer { trueNASIsInspectingCertificate = false }
            do {
                let fingerprint = try await TrueNASClient.certificateFingerprint(serverURL: serverURL)
                updateConfiguration { $0.trueNASTLSPinnedCertificateSHA256 = fingerprint }
                trueNASConnectionStatus = "Trusted this server certificate: \(Self.shortFingerprint(fingerprint))."
            } catch {
                trueNASConnectionStatus = "Could not trust the TrueNAS certificate: \(error.localizedDescription)"
            }
        }
    }

    func saveTrueNASAPIKey() {
        do {
            try secretStore.save(trueNASAPIKeyDraft, account: Self.trueNASAPIKeyAccount)
            trueNASConnectionStatus = trueNASAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "TrueNAS API key removed from Keychain."
                : "TrueNAS API key saved in Keychain."
            configMessage = "TrueNAS API key saved in macOS Keychain."
        } catch {
            trueNASConnectionStatus = "Could not save the TrueNAS API key: \(error.localizedDescription)"
        }
    }

    func testTrueNASConnection() {
        Task { @MainActor in
            trueNASIsTestingConnection = true
            trueNASConnectionStatus = "Testing exact TrueNAS capacity…"
            defer { trueNASIsTestingConnection = false }
            if let snapshot = await readAuthoritativeTrueNASCapacity() {
                trueNASConnectionStatus = trueNASConnectionSummary(snapshot: snapshot)
                storageCapacityRevision &+= 1
            }
        }
    }

    func readAuthoritativeTrueNASCapacity() async -> StorageCapacitySnapshot? {
        let serverURL = configuration.trueNASServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let dataset = configuration.trueNASDataset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty else {
            trueNASConnectionReport = nil
            return nil
        }

        var apiKey = trueNASAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if apiKey.isEmpty {
                apiKey = try secretStore.read(account: Self.trueNASAPIKeyAccount)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } else {
                try secretStore.save(apiKey, account: Self.trueNASAPIKeyAccount)
            }
            guard !apiKey.isEmpty else {
                trueNASConnectionReport = nil
                trueNASConnectionStatus = "The SMB folder is mounted, but no TrueNAS API key is saved. Capacity is only an SMB estimate."
                return nil
            }

            let client = try TrueNASClient(
                serverURL: serverURL,
                username: configuration.trueNASUsername,
                apiKey: apiKey,
                pinnedCertificateSHA256: configuration.trueNASTLSPinnedCertificateSHA256
            )
            let report = try await client.readCapacity(
                dataset: dataset,
                smbShareName: StorageCapacityReader.mountedVolumeName(for: configuration.cameraLibraryRootPath)
            )
            if dataset.isEmpty {
                updateConfiguration { $0.trueNASDataset = report.dataset }
            }
            trueNASConnectionReport = report
            let snapshot = StorageCapacitySnapshot(
                availableBytes: report.datasetAvailableBytes,
                totalBytes: report.datasetTotalBytes,
                source: .trueNAS(
                    dataset: report.dataset,
                    pool: report.poolName,
                    poolAvailableBytes: report.poolFreeBytes,
                    poolTotalBytes: report.poolTotalBytes,
                    poolHealthy: report.poolHealthy
                )
            )
            trueNASConnectionStatus = trueNASConnectionSummary(snapshot: snapshot)
            return snapshot
        } catch {
            trueNASConnectionReport = nil
            let certificateHint = configuration.trueNASTLSPinnedCertificateSHA256.isEmpty
                ? " If this NAS uses its default self-signed certificate, click Trust Current Certificate first."
                : ""
            trueNASConnectionStatus = "TrueNAS capacity check failed: \(error.localizedDescription)\(certificateHint)"
            return nil
        }
    }

    private func trueNASConnectionSummary(snapshot: StorageCapacitySnapshot) -> String {
        guard let report = trueNASConnectionReport else { return "TrueNAS dataset connected." }
        let health = report.poolHealthy ? report.poolStatus : "\(report.poolStatus), needs attention"
        return "Connected to \(report.dataset) on pool \(report.poolName) (\(health)): \(snapshot.availableBytes.formattedWholeStorage) free."
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
        guard selectedEventCopyAvailability.contextID == selectedEventCopyAvailabilityRefreshID,
              selectedEventCopyAvailability.phase == .ready else {
            statusMessage = "Checking which assigned files are still available for preview…"
            Task { await refreshSelectedEventCopyAvailability() }
            return
        }
        let selectedFiles = selectedEventCopyAvailability.presentFiles
        guard !selectedFiles.isEmpty else {
            statusMessage = "No assigned files are currently present on this source."
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
        enqueueTransfer(
            files: selectedFiles,
            sourcePath: expandedImportSourcePath,
            destinationPath: expandedBufferIngestPath,
            eventID: selectedEvent?.id,
            eventName: selectedEvent?.name ?? configuration.eventName,
            deviceID: configuration.selectedDeviceID
        )
    }

    func resumePendingTransfers() {
        guard !pendingTransferBatches.isEmpty else {
            statusMessage = "There are no waiting transfers."
            return
        }
        guard !isBusy, !isStorageBenchmarkRunning else {
            statusMessage = "The queued transfers will start when the current job finishes."
            return
        }
        startNextPendingTransferIfPossible()
    }

    func removePendingTransferBatch(_ id: UUID) {
        guard let batch = pendingTransferBatches.first(where: { $0.id == id }) else { return }
        pendingTransferBatches.removeAll { $0.id == id }
        persistPendingTransfers()
        statusMessage = "Removed \(batch.files.count) waiting file(s) from the transfer queue. No files were changed."
    }

    func enqueueTransferBatch(_ batch: PendingTransferBatch) {
        enqueueTransfer(
            files: batch.files,
            sourcePath: batch.sourcePath,
            destinationPath: batch.destinationPath,
            eventID: batch.eventID,
            eventName: batch.eventName,
            deviceID: batch.deviceID
        )
    }

    private func scheduledTransferPaths(sourcePath: String, destinationPath: String) -> Set<String> {
        let standardizedSource = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL.path
        let standardizedDestination = URL(fileURLWithPath: destinationPath, isDirectory: true).standardizedFileURL.path
        var paths = Set<String>()

        if let active = transferQueue,
           active.state == .running,
           URL(fileURLWithPath: active.sourcePath, isDirectory: true).standardizedFileURL.path == standardizedSource,
           URL(fileURLWithPath: active.destinationPath, isDirectory: true).standardizedFileURL.path == standardizedDestination {
            paths.formUnion(active.items.map(\.relativePath))
        }
        for batch in pendingTransferBatches
        where batch.sourcePath == standardizedSource && batch.destinationPath == standardizedDestination {
            paths.formUnion(batch.files.map(\.path))
        }
        return paths
    }

    private func enqueueTransfer(
        files: [FileRecord],
        sourcePath: String,
        destinationPath: String,
        eventID: UUID?,
        eventName: String,
        deviceID: String
    ) {
        let standardizedSource = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL.path
        let standardizedDestination = URL(fileURLWithPath: destinationPath, isDirectory: true).standardizedFileURL.path
        var alreadyScheduled = Set<String>()

        if let active = transferQueue,
           active.state == .running,
           URL(fileURLWithPath: active.sourcePath, isDirectory: true).standardizedFileURL.path == standardizedSource,
           URL(fileURLWithPath: active.destinationPath, isDirectory: true).standardizedFileURL.path == standardizedDestination {
            alreadyScheduled.formUnion(active.items.map(\.relativePath))
        }
        for batch in pendingTransferBatches
        where batch.sourcePath == standardizedSource && batch.destinationPath == standardizedDestination {
            alreadyScheduled.formUnion(batch.files.map(\.path))
        }

        var uniqueFiles: [String: FileRecord] = [:]
        for file in files where (try? PathSafety.validateRelativePath(file.path)) != nil {
            guard !alreadyScheduled.contains(file.path) else { continue }
            uniqueFiles[file.path] = file
        }
        let unscheduledFiles = uniqueFiles.values.sorted { $0.path < $1.path }
        guard !unscheduledFiles.isEmpty else {
            statusMessage = "Those files are already transferring or waiting in the transfer queue."
            NotificationCenter.default.post(name: .cameraToolkitShowTransferQueue, object: nil)
            return
        }

        if let existingIndex = pendingTransferBatches.firstIndex(where: {
            $0.eventID == eventID
                && $0.sourcePath == standardizedSource
                && $0.destinationPath == standardizedDestination
        }) {
            pendingTransferBatches[existingIndex].files.append(contentsOf: unscheduledFiles)
            pendingTransferBatches[existingIndex].files.sort { $0.path < $1.path }
        } else {
            pendingTransferBatches.append(PendingTransferBatch(
                eventID: eventID,
                eventName: eventName,
                deviceID: deviceID,
                sourcePath: standardizedSource,
                destinationPath: standardizedDestination,
                files: unscheduledFiles
            ))
        }
        persistPendingTransfers()
        queuedFilePaths.formUnion(unscheduledFiles.map(\.path))
        NotificationCenter.default.post(name: .cameraToolkitShowTransferQueue, object: nil)

        if isBusy || isStorageBenchmarkRunning {
            statusMessage = "Added \(unscheduledFiles.count) file(s) to the transfer queue. Keep browsing and assigning more while the current job runs."
        } else {
            startNextPendingTransferIfPossible()
        }
    }

    func startNextPendingTransferIfPossible() {
        guard !isBusy, !isStorageBenchmarkRunning, let batch = pendingTransferBatches.first else { return }
        pendingTransferBatches.removeFirst()
        persistPendingTransfers()
        runTransfer(batch)
    }

    private func runTransfer(_ batch: PendingTransferBatch) {
        let selectedFiles = batch.files
        let sourcePath = batch.sourcePath
        let destinationPath = batch.destinationPath
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
        let command = Self.commandLine(["copy-queue", sourcePath, destinationPath, "\(selectedFiles.count) files"])
        startTransferQueue(files: selectedFiles, sourcePath: sourcePath, destinationPath: destinationPath)
        runBackgroundJob(
            action: .ingestCard,
            runningNote: "Copying queued files to buffer",
            logTitle: "Copied queue to buffer",
            logDetail: "Copied only the files selected in the queue. Nothing was deleted or overwritten.",
            command: command,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            tracksTransferQueue: true,
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
                self.queuedFilePaths.subtract(selectedFiles.map(\.path))
                self.completeTransferQueue(copy: result.copy, plan: result.plan)
                return "Copied \(result.copy.copied.count) queued file(s) to buffer, skipped \(result.copy.skippedIdentical.count) already there, left \(result.copy.conflicts.count) conflict(s) untouched."
            }
        )
    }

    private func persistPendingTransfers() {
        do {
            try pendingTransferQueueStore.save(pendingTransferBatches)
        } catch {
            statusMessage = "The transfer was queued in this session, but its waiting list could not be saved: \(error.localizedDescription)"
        }
    }

    func dismissTransferQueue() {
        guard transferQueue?.state != .running else { return }
        transferQueue = nil
        try? transferQueueStore.remove()
    }

    func prepareSourceCleanup() {
        guard !isSourceCleanupRunning else { return }
        sourceCleanupMessage = nil
        sourceCleanupError = nil
    }

    func removeVerifiedSourceFiles(queueID: UUID, confirmation: String) {
        guard !isBusy, !isSourceCleanupRunning, !isStorageBenchmarkRunning else {
            sourceCleanupError = "Another file job is already running. Wait for it to finish, then try again."
            return
        }
        guard let queue = transferQueue,
              queue.id == queueID,
              queue.state == .completed,
              queue.verifiedCount == queue.items.count else {
            sourceCleanupError = "Every selected file must be checksum verified in the Buffer first."
            return
        }

        let removableItems = queue.items.filter {
            $0.state == .verified || $0.state == .alreadyPresent
        }
        guard !removableItems.isEmpty else {
            sourceCleanupError = "These source files have already been removed from the camera."
            return
        }

        let records = removableItems.map {
            FileRecord(path: $0.relativePath, size: $0.size, modifiedAt: .distantPast)
        }
        let sourcePath = queue.sourcePath
        let bufferPath = queue.destinationPath
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let buffer = URL(fileURLWithPath: bufferPath, isDirectory: true)
        let command = Self.commandLine([
            "free-up-camera", "--recheck", sourcePath, bufferPath, "\(records.count) files"
        ])

        sourceCleanupMessage = nil
        sourceCleanupError = nil

        runBackgroundJob(
            action: .freeUp,
            runningNote: "Rechecking camera files against the Buffer before removal",
            logTitle: "Freed verified camera space",
            logDetail: "Re-hashed the explicit source and Buffer files before permanently removing only matching camera originals.",
            command: command,
            sourcePath: sourcePath,
            destinationPath: bufferPath,
            operation: { jobProgress in
                try SourceCleanupService().removeVerifiedFiles(
                    sourceRoot: source,
                    bufferRoot: buffer,
                    files: records,
                    confirmation: confirmation
                ) { update in
                    jobProgress(Self.jobUpdate(
                        from: update,
                        lowerBound: 0.02,
                        upperBound: 0.98,
                        notePrefix: "Safely freeing camera space",
                        command: command,
                        sourcePath: sourcePath,
                        destinationPath: bufferPath
                    ))
                }
            },
            completion: { report in
                self.applySourceCleanupReport(report, queueID: queueID)

                guard report.removed.count == records.count else {
                    let summary = Self.sourceCleanupFailureSummary(
                        report,
                        requestedCount: records.count
                    )
                    self.sourceCleanupError = summary
                    throw ToolkitError.commandFailed(summary)
                }

                let summary = "Removed \(report.removed.count) checksum-matched file(s) from the camera and freed \(report.removedBytes.formattedBytes). Buffer copies remain verified."
                self.sourceCleanupMessage = summary
                return summary
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
            phase: update.phase,
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

    private func startTransferQueue(files: [FileRecord], sourcePath: String, destinationPath: String) {
        let sorted = files.sorted { $0.path < $1.path }
        transferQueue = TransferQueueSnapshot(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            items: sorted.map { TransferQueueItem(relativePath: $0.path, size: $0.size) },
            totalBytes: sorted.reduce(Int64(0)) { $0 + $1.size },
            phaseProcessedBytes: 0,
            phaseTotalBytes: sorted.reduce(Int64(0)) { $0 + $1.size }
        )
        persistTransferQueue(force: true)
        NotificationCenter.default.post(name: .cameraToolkitShowTransferQueue, object: nil)
    }

    private func updateTransferQueue(_ update: BackgroundJobUpdate) {
        guard var queue = transferQueue, queue.state == .running else { return }
        if update.totalBytes > 0 {
            queue.progress = min(max(Double(update.processedBytes) / Double(update.totalBytes), 0), 1)
        } else {
            queue.progress = min(max(update.progress, 0), 1)
        }
        queue.phaseProcessedBytes = update.processedBytes
        queue.phaseTotalBytes = update.totalBytes
        queue.bytesPerSecond = update.bytesPerSecond
        queue.phase = Self.displayPhase(update.phase)
        queue.updatedAt = Date()

        let phase = update.phase.lowercased()
        if phase.contains("copy") {
            queue.processedBytes = min(max(update.processedBytes, 0), queue.totalBytes)
            for index in queue.items.indices where index < update.processedFiles {
                queue.items[index].state = .copied
                queue.items[index].copiedBytes = queue.items[index].size
            }
            if let currentPath = update.currentPath,
               let currentIndex = queue.items.firstIndex(where: { $0.relativePath == currentPath }) {
                if update.processedFiles > currentIndex {
                    queue.items[currentIndex].state = .copied
                    queue.items[currentIndex].copiedBytes = queue.items[currentIndex].size
                } else {
                    let earlierBytes = queue.items[..<currentIndex].reduce(Int64(0)) { $0 + $1.size }
                    queue.items[currentIndex].state = .copying
                    queue.items[currentIndex].copiedBytes = min(
                        max(update.processedBytes - earlierBytes, 0),
                        queue.items[currentIndex].size
                    )
                }
            }
        } else if phase.contains("verif") || phase.contains("check") {
            for index in queue.items.indices where index < update.processedFiles {
                queue.items[index].state = .verified
                queue.items[index].copiedBytes = queue.items[index].size
            }
            if let currentPath = update.currentPath,
               let currentIndex = queue.items.firstIndex(where: { $0.relativePath == currentPath }),
               update.processedFiles <= currentIndex {
                queue.items[currentIndex].state = .verifying
                queue.items[currentIndex].copiedBytes = queue.items[currentIndex].size
            }
        }

        transferQueue = queue
        persistTransferQueue()
    }

    private func completeTransferQueue(copy: LocalCopyResult, plan: CopyPlan) {
        guard var queue = transferQueue else { return }
        let skipped = Set(copy.skippedIdentical)
        let verified = Set(plan.existing.map(\.path))
        let conflicts = Set(plan.conflicts.map(\.path))

        for index in queue.items.indices {
            let path = queue.items[index].relativePath
            queue.items[index].copiedBytes = queue.items[index].size
            if conflicts.contains(path) {
                queue.items[index].state = .conflict
                queue.items[index].detail = "A different file already exists at the Buffer destination."
            } else if verified.contains(path) {
                queue.items[index].state = skipped.contains(path) ? .alreadyPresent : .verified
            } else {
                queue.items[index].state = .failed
                queue.items[index].detail = "The file was not present in the verified Buffer result."
            }
        }

        let issueCount = queue.items.count { $0.state == .conflict || $0.state == .failed }
        queue.state = issueCount == 0 ? .completed : .failed
        queue.progress = 1
        queue.processedBytes = queue.totalBytes
        queue.phaseProcessedBytes = queue.totalBytes
        queue.phaseTotalBytes = queue.totalBytes
        queue.bytesPerSecond = 0
        queue.phase = issueCount == 0 ? "Transfer complete" : "Completed with issues"
        queue.message = issueCount == 0
            ? "All \(queue.items.count) files are checksum-verified in the Buffer. Camera originals were untouched."
            : "\(issueCount) file(s) need attention. Existing files were not overwritten."
        queue.updatedAt = Date()
        transferQueue = queue
        persistTransferQueue(force: true)
        NotificationCenter.default.post(name: .cameraToolkitShowTransferQueue, object: nil)
    }

    private func applySourceCleanupReport(_ report: SourceCleanupReport, queueID: UUID) {
        guard var queue = transferQueue, queue.id == queueID else { return }
        let removed = Set(report.removed)
        for index in queue.items.indices where removed.contains(queue.items[index].relativePath) {
            queue.items[index].state = .sourceRemoved
            queue.items[index].detail = "Removed from the camera after a fresh checksum match with the Buffer."
        }
        if !removed.isEmpty {
            queue.phase = report.removed.count == queue.items.count
                ? "Camera space freed"
                : "Some camera files removed"
            queue.message = "Removed \(report.removed.count) checksum-matched source file(s), freeing \(report.removedBytes.formattedBytes). Buffer copies remain verified."
            queue.technicalDetail = report.errors.isEmpty
                ? nil
                : report.errors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            queue.updatedAt = Date()
            transferQueue = queue
            persistTransferQueue(force: true)
            BrowserCommand.post(.reload)
        }
    }

    nonisolated private static func sourceCleanupFailureSummary(
        _ report: SourceCleanupReport,
        requestedCount: Int
    ) -> String {
        var reasons: [String] = []
        if !report.missingSource.isEmpty {
            reasons.append("\(report.missingSource.count) source file(s) are already missing")
        }
        if !report.missingBuffer.isEmpty {
            reasons.append("\(report.missingBuffer.count) Buffer copy/copies are missing")
        }
        if !report.differ.isEmpty {
            reasons.append("\(report.differ.count) checksum(s) differ")
        }
        if !report.errors.isEmpty {
            reasons.append("\(report.errors.count) file(s) changed or could not be checked")
        }
        if report.removed.count < requestedCount, reasons.isEmpty {
            reasons.append("not every source file could be removed")
        }
        let prefix = report.removed.isEmpty
            ? "Nothing was removed."
            : "Removed \(report.removed.count) file(s), then stopped safely."
        return "\(prefix) \(reasons.joined(separator: "; ")). Buffer copies were untouched."
    }

    private func failTransferQueue(error: Error, message: String) {
        guard var queue = transferQueue else { return }
        if let activeIndex = queue.items.firstIndex(where: { $0.state == .copying || $0.state == .verifying })
            ?? queue.items.firstIndex(where: { $0.state == .waiting }) {
            queue.items[activeIndex].state = .failed
            queue.items[activeIndex].detail = message
        }
        queue.state = .failed
        queue.phase = "Transfer stopped"
        queue.message = message
        queue.technicalDetail = error.localizedDescription
        queue.bytesPerSecond = 0
        queue.updatedAt = Date()
        transferQueue = queue
        persistTransferQueue(force: true)
        NotificationCenter.default.post(name: .cameraToolkitShowTransferQueue, object: nil)
    }

    private func cancelTransferQueue() {
        guard var queue = transferQueue else { return }
        queue.state = .cancelled
        queue.phase = "Cancelled"
        queue.message = "Transfer cancelled. Camera originals were untouched."
        queue.bytesPerSecond = 0
        queue.updatedAt = Date()
        transferQueue = queue
        persistTransferQueue(force: true)
    }

    private func persistTransferQueue(force: Bool = false) {
        guard let queue = transferQueue else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastTransferQueuePersistence) >= 1 else { return }
        try? transferQueueStore.save(queue)
        lastTransferQueuePersistence = now
    }

    nonisolated private static func transferFailureSummary(_ error: Error) -> String {
        let detail = error.localizedDescription
        let normalized = detail.lowercased()
        let looksLikeDisconnect = [
            "disconnect", "not attached", "no such file", "input/output", "couldn’t be moved", "couldn't be moved"
        ].contains { normalized.contains($0) }
        if looksLikeDisconnect {
            return "A camera or Buffer drive disconnected while copying. Reconnect both drives, then retry. Camera originals were untouched."
        }
        return "The transfer stopped safely: \(detail) Camera originals were untouched."
    }

    private func runBackgroundJob<Result: Sendable>(
        action: JobAction,
        runningNote: String,
        logTitle: String,
        logDetail: String,
        command: String = "",
        sourcePath: String? = nil,
        destinationPath: String? = nil,
        tracksTransferQueue: Bool = false,
        operation: @escaping @Sendable (@escaping @Sendable (BackgroundJobUpdate) -> Void) throws -> Result,
        completion: @escaping (Result) throws -> String
    ) {
        guard !isBusy, !isStorageBenchmarkRunning else {
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
                guard let self else { return }
                self.updateJob(id: jobID, update: update)
                if tracksTransferQueue {
                    self.updateTransferQueue(update)
                }
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
                if !tracksTransferQueue || transferQueue?.state == .completed {
                    startNextPendingTransferIfPossible()
                }
            } catch is CancellationError {
                let summary = "Cancelled."
                statusMessage = summary
                if tracksTransferQueue {
                    cancelTransferQueue()
                }
                finishJob(
                    id: jobID,
                    action: action,
                    state: .cancelled,
                    note: summary,
                    logTitle: logTitle,
                    logDetail: logDetail
                )
            } catch {
                let summary = tracksTransferQueue ? Self.transferFailureSummary(error) : error.localizedDescription
                statusMessage = summary
                if tracksTransferQueue {
                    failTransferQueue(error: error, message: summary)
                }
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

        let phase = update.phase.lowercased()
        let changesStoredBytes = phase.contains("copying") || phase.contains("removing from camera")
        let now = Date()
        if changesStoredBytes, now.timeIntervalSince(lastStorageCapacityRefreshRequest) >= 1 {
            storageCapacityRevision &+= 1
            lastStorageCapacityRefreshRequest = now
        }
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
            if state == .done {
                jobs[index].progress = 1
            }
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
        storageCapacityRevision &+= 1
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
    private static let trueNASAPIKeyAccount = "truenas-api-key"

    private static func shortFingerprint(_ fingerprint: String) -> String {
        let compact = fingerprint.uppercased().filter(\.isHexDigit)
        let groups = stride(from: 0, to: min(compact.count, 16), by: 2).map { offset -> String in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(2, compact.distance(from: start, to: compact.endIndex)))
            return String(compact[start..<end])
        }
        return groups.joined(separator: ":") + (compact.count > 16 ? "…" : "")
    }

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
