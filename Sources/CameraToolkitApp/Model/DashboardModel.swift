import CameraToolkitCore
import AppKit
import Foundation
import Observation

private struct QueueCopyJobResult: Sendable {
    var copy: LocalCopyResult
    var plan: CopyPlan
}

/// What the refresh pass read from disk — produced off the main actor so
/// decoding a large configuration can never freeze the UI.
private struct RefreshedDiskState: Sendable {
    var configuration: AppConfiguration?
    var configurationError: String?
    var activityLog: [ActivityLogEntry]?
    var activityLogError: String?
}

struct BackgroundJobUpdate: Sendable {
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
    var telemetry: JobTelemetry?

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
        bytesPerSecond: Double = 0,
        telemetry: JobTelemetry? = nil
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
        self.telemetry = telemetry
    }
}

@MainActor
@Observable
final class DashboardModel {
    var isSidebarCollapsed: Bool = false
    /// Power assertions for in-flight file jobs — one token per job id so
    /// App Nap and idle sleep cannot stall a copy, archive, take-off-drive,
    /// face scan, or Immich upload the user explicitly asked for.
    private(set) var jobActivityAssertions: [UUID: any NSObjectProtocol] = [:]
    var jobs: [JobSnapshot]
    var activityLog: [ActivityLogEntry]
    var configuration: AppConfiguration
    var configMessage: String = "Config is saved automatically."
    var statusMessage: String = "Ready. Choose folders in Settings to begin."
    var isBusy: Bool = false
    var isStorageBenchmarkRunning: Bool = false {
        // A speed test holds the job gate without being a job, so nothing
        // calls `onJobFinished` when it lets go — work that queued behind
        // it (a clicked Move to Event, NAS renames) hears it here instead
        // of waiting for some other job to end.
        didSet {
            if oldValue, !isStorageBenchmarkRunning { onGateReleased?() }
        }
    }
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
    /// The config file's (modification date, size) as last written or read
    /// by this process — the activation check compares the on-disk stamp
    /// against this before paying for a reload.
    private var configurationFileStamp: (modifiedAt: Date, byteCount: Int64)?
    var catalogReport: CatalogBootstrapReport?
    var catalogMessage: String = "Photo list has not been prepared yet."
    /// Newest local/NAS backup times and the last failure, for Settings.
    var catalogBackupSummary: CatalogBackupSummary?
    var isBackingUpCatalog: Bool = false
    var transferQueue: TransferQueueSnapshot?
    var pendingTransferBatches: [PendingTransferBatch]
    var storageCapacityRevision: Int = 0
    /// Increments on every saved configuration change so views can cheaply
    /// rebuild indexes derived from events and assignments.
    var configurationRevision: Int = 0
    /// Increments only when the catalog-owned state — events, assignments,
    /// display rotations, burst splits — actually changes. Settings writes
    /// bump `configurationRevision` alone, so a slider or server URL never
    /// rebuilds the assignment-derived indexes.
    var catalogStateRevision: Int = 0
    var sourceCleanupMessage: String?
    var sourceCleanupError: String?
    var activeJob: JobSnapshot? {
        jobs.first { $0.state == .running || $0.state == .queued }
    }
    var sourceCleanupJob: JobSnapshot? {
        jobs.first { $0.action == .freeUp }
    }
    var isSourceCleanupRunning: Bool {
        sourceCleanupJob?.state == .running || sourceCleanupJob?.state == .queued
    }
    @ObservationIgnored let configurationStore: ConfigurationStore
    @ObservationIgnored private let transferQueueStore: TransferQueueStore
    @ObservationIgnored private let pendingTransferQueueStore: PendingTransferQueueStore
    @ObservationIgnored let secretStore = KeychainSecretStore(service: "org.cameratoolkit.CameraToolkit")
    @ObservationIgnored private var catalogSyncTask: Task<Void, Never>?
    @ObservationIgnored private var configurationSaveTask: Task<Void, Never>?
    /// True when `configuration` holds changes the debounced save has not
    /// written yet — `flushConfigurationSave()` writes only then.
    @ObservationIgnored private var configurationSaveIsDirty = false
    /// Test seam: substitutes the on-disk config reload inside
    /// `refreshAllNow`'s background pass — production reads through
    /// `ConfigurationStore` there. Lets a test prove the decode happens
    /// off the main actor.
    @ObservationIgnored var configurationLoader: (@Sendable (URL, AppConfiguration) throws -> AppConfiguration)?
    @ObservationIgnored private var lastTransferQueuePersistence = Date.distantPast
    @ObservationIgnored private var lastStorageCapacityRefreshRequest = Date.distantPast
    /// The debounced after-writes backup (see `noteCatalogWrite`).
    @ObservationIgnored var catalogBackupDebounceTask: Task<Void, Never>?
    /// Where events and assignments are durably saved (see
    /// `CatalogStateStartup`). Tests and previews stay on `.legacy`, the
    /// config.json path.
    @ObservationIgnored var catalogStateMode: CatalogStateMode = .legacy
    @ObservationIgnored var lastCatalogBackupAt: Date?
    /// Records jobs into `job-history.sqlite` beside the catalog. Only the
    /// live app turns it on; tests and previews never write one.
    @ObservationIgnored var jobHistoryEnabled = false
    /// Hears every background job start and finish (after `isBusy` has
    /// changed) — the NAS presence check pauses for jobs and recounts
    /// after them.
    @ObservationIgnored var onJobStarted: (@MainActor (JobAction) -> Void)?
    @ObservationIgnored var onJobFinished: (@MainActor (JobAction) -> Void)?
    /// Heard when a speed test releases the job gate (see
    /// `isStorageBenchmarkRunning`).
    @ObservationIgnored var onGateReleased: (@MainActor () -> Void)?
    /// This session's job recorders by job id: the running job's, and the
    /// last few finished ones so their whole-run chart stays drawable.
    @ObservationIgnored var jobHistoryRecorders: [UUID: JobHistoryRecorder] = [:]
    @ObservationIgnored var jobHistoryFinishedOrder: [UUID] = []
    /// Increments when a recorded job ends, so the History list reloads.
    var jobHistoryRevision: Int = 0

    init(
        jobs: [JobSnapshot],
        activityLog: [ActivityLogEntry] = [],
        configuration: AppConfiguration = .defaults(applicationSupport: DashboardModel.defaultApplicationSupportURL),
        configurationStore: ConfigurationStore = ConfigurationStore(url: DashboardModel.defaultConfigurationURL),
        transferQueueStore: TransferQueueStore? = nil,
        pendingTransferQueueStore: PendingTransferQueueStore? = nil,
        loadActivityLog: Bool = false
    ) {
        self.jobs = jobs
        self.configuration = configuration
        self.configurationStore = configurationStore
        self.configurationFileStamp = configurationStore.fileStamp()
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
        // Events and assignments load from the catalog; the first launch
        // after the upgrade migrates them there from config.json.
        let backupsFolder = store.url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let outcome = CatalogStateStartup.resolve(
            configurationURL: store.url,
            defaults: defaults,
            backups: { catalogURL in
                CatalogBackupService(
                    catalogURL: catalogURL,
                    configurationURL: store.url,
                    localFolder: backupsFolder,
                    remoteFolder: nil
                )
            }
        )
        let configuration = outcome.configuration

        let model = DashboardModel(
            jobs: [],
            configuration: configuration,
            configurationStore: store,
            loadActivityLog: true
        )
        model.adoptCatalogState(outcome)
        model.scheduleCatalogSync(configuration: configuration)
        model.removeStaleSpeedTestFiles()
        model.scheduleLaunchCatalogBackup()
        model.jobHistoryEnabled = true
        model.openJobHistorySoon()
        return model
    }

    private static func transferProgress(processedBytes: Int64, totalBytes: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(processedBytes) / Double(totalBytes), 0), 1)
    }
}

extension DashboardModel {
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

    func toggleSidebar() {
        isSidebarCollapsed.toggle()
    }

    func refreshAllIfStale(maxAge: TimeInterval = 15) {
        guard let lastRefreshedAt else {
            refreshAll()
            return
        }
        guard Date().timeIntervalSince(lastRefreshedAt) >= maxAge else { return }
        // A reactivation whose config file is byte-for-byte what this
        // process last read or wrote has nothing to apply — in-memory
        // state is already current, so the reload is skipped entirely.
        let stamp = configurationStore.fileStamp()
        if stamp?.modifiedAt == configurationFileStamp?.modifiedAt,
           stamp?.byteCount == configurationFileStamp?.byteCount {
            self.lastRefreshedAt = Date()
            return
        }
        refreshAll()
    }

    func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusMessage = "Refreshing latest app state..."

        Task { @MainActor in
            await refreshAllNow()
        }
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
        let backupService = catalogBackupService(for: snapshot)
        catalogSyncTask = Task { @MainActor in
            let outcome = await Task.detached(priority: .utility) {
                do {
                    var report = try CatalogStore(url: catalogURL).bootstrap(
                        configuration: snapshot,
                        createBackup: false
                    )
                    if createBackup {
                        // Same verified backup service as the automatic runs.
                        let result = try backupService.backupNow(reason: .manual)
                        report.backupPath = result.catalogURL?.path
                    }
                    return (report: Optional(report), error: String?.none)
                } catch {
                    return (report: CatalogBootstrapReport?.none, error: Optional(error.localizedDescription))
                }
            }.value
            guard !Task.isCancelled else { return }
            if createBackup { refreshCatalogBackupSummary() }
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
        if keyPath == \.catalogDatabasePath, !catalogStateMode.isLegacy,
           Self.expandedPath(value) != Self.expandedPath(configuration.catalogDatabasePath) {
            // Events live in this catalog now; pointing the app at another
            // file would leave them behind.
            statusMessage = "The photo list holds your events, so it can't be switched while Camera Toolkit is running. Quit, move catalog.sqlite and config.json together, then relaunch."
            return
        }
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
        statusMessage = "Using \(location.name) for \(location.role.displayName)."
    }

    static func inferredDeviceID(for location: ConfiguredLocation) -> String? {
        location.inferredDeviceID
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
        statusMessage = "Camera changed."
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
        statusMessage = "Event folder changed."
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

    func enqueueTransfer(
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

    private func refreshAllNow() async {
        defer {
            isRefreshing = false
            lastRefreshedAt = Date()
        }

        var notes: [String] = []

        // Flush first: a pending debounced save must reach disk before a
        // reload, or the read would revert mutations made moments ago.
        // The reload itself — decoding the whole configuration JSON and
        // the activity log — runs at utility priority off the main actor;
        // doing it here is what used to freeze the board on every
        // activation for libraries with thousands of assignments.
        flushConfigurationSave()
        let storeURL = configurationStore.url
        let logURL = URL(fileURLWithPath: Self.expandedPath(configuration.activityLogPath))
        let defaults = AppConfiguration.defaults(applicationSupport: Self.defaultApplicationSupportURL)
        let revisionBefore = configurationRevision
        let logCountBefore = activityLog.count
        let loader = configurationLoader
        // Continuation, not `await task.value` — awaiting a detached task
        // escalates it to the caller's priority, which would put the decode
        // right back on the tier it is being moved off of.
        let disk = await withCheckedContinuation { (cc: CheckedContinuation<RefreshedDiskState, Never>) in
            Task.detached(priority: .utility) {
                var state = RefreshedDiskState()
                do {
                    state.configuration = try loader?(storeURL, defaults)
                        ?? ConfigurationStore(url: storeURL).load(defaults: defaults)
                } catch {
                    state.configurationError = error.localizedDescription
                }
                do {
                    state.activityLog = try ActivityLogStore(url: logURL).load()
                } catch {
                    state.activityLogError = error.localizedDescription
                }
                cc.resume(returning: state)
            }
        }

        if var reloaded = disk.configuration {
            // A mutation that landed while the disk pass ran is newer than
            // what was read — keep it; its own scheduled save will persist.
            if configurationRevision == revisionBefore {
                let ownedBefore = CatalogOwnedState(configuration: configuration)
                if !catalogStateMode.isLegacy {
                    // config.json holds settings only; events stay as the
                    // catalog-backed memory has them.
                    CatalogOwnedState(configuration: configuration).apply(to: &reloaded)
                }
                configuration = reloaded
                configurationRevision &+= 1
                if CatalogOwnedState(configuration: reloaded) != ownedBefore {
                    catalogStateRevision &+= 1
                }
                configMessage = "Config reloaded at \(Self.defaultConfigurationURL.path)."
                notes.append("config")
            } else {
                notes.append("config kept local changes")
            }
        } else {
            configMessage = "Could not reload config: \(disk.configurationError ?? "unknown error")"
            notes.append("config failed")
        }

        if let entries = disk.activityLog {
            if activityLog.count == logCountBefore {
                activityLog = entries
            }
            notes.append("\(activityLog.count) log entries")
        } else {
            notes.append("log unavailable")
        }
        configurationFileStamp = configurationStore.fileStamp()

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

    nonisolated static func jobUpdate(
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
            bytesPerSecond: update.bytesPerSecond,
            telemetry: update.telemetry
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

    /// Runs a job on a worker task and reports progress on `jobs`. Returns the
    /// job's id so callers can correlate a running job with UI they show while
    /// it is in flight; nil when another job already occupies the model.
    @discardableResult
    func runBackgroundJob<Result: Sendable>(
        action: JobAction,
        runningNote: String,
        logTitle: String,
        logDetail: String,
        command: String = "",
        sourcePath: String? = nil,
        destinationPath: String? = nil,
        tracksTransferQueue: Bool = false,
        /// A recorder the job feeds itself (Sync to NAS); without one the
        /// job is recorded from its progress updates.
        history: JobHistoryRecorder? = nil,
        /// Runs after the job settles — done, failed, or cancelled — so
        /// callers can clear bookkeeping the success-only `completion`
        /// cannot cover.
        onSettled: (@MainActor @Sendable () -> Void)? = nil,
        operation: @escaping @Sendable (@escaping @Sendable (BackgroundJobUpdate) -> Void) throws -> Result,
        completion: @escaping (Result) throws -> String
    ) -> UUID? {
        guard !isBusy, !isStorageBenchmarkRunning else {
            statusMessage = "Another file job is already running. Wait for it to finish, then try again."
            return nil
        }

        isBusy = true
        statusMessage = runningNote
        onJobStarted?(action)

        let recorder = history ?? makeHistoryRecorder(action: action, title: logTitle)
        let jobID = recorder?.jobID ?? UUID()
        if let recorder {
            jobHistoryRecorders[jobID] = recorder
            recorder.start()
        }
        // A job that feeds its own recorder is not sampled twice.
        let sampledRecorder = history == nil ? recorder : nil
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
        beginJobActivity(id: jobID, reason: "\(logTitle) — a Camera Toolkit file job")

        let progressHandler: @Sendable (BackgroundJobUpdate) -> Void = { [weak self] update in
            sampledRecorder?.observe(update.historyObservation)
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
            defer { onSettled?() }
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
        return jobID
    }

    func beginJobActivity(id: UUID, reason: String) {
        jobActivityAssertions[id] = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        )
    }

    func endJobActivity(id: UUID) {
        guard let token = jobActivityAssertions.removeValue(forKey: id) else { return }
        ProcessInfo.processInfo.endActivity(token)
    }

    func updateJob(id: UUID, update: BackgroundJobUpdate) {
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
        if let telemetry = update.telemetry {
            jobs[index].telemetry = telemetry
        }

        let phase = update.phase.lowercased()
        let changesStoredBytes = phase.contains("copying") || phase.contains("removing from camera")
        let now = Date()
        if changesStoredBytes, now.timeIntervalSince(lastStorageCapacityRefreshRequest) >= 1 {
            storageCapacityRevision &+= 1
            lastStorageCapacityRefreshRequest = now
        }
    }

    func finishJob(
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
        finishJobHistory(id: id, state: state, note: note)

        recordActivity(
            action: action,
            state: state,
            title: logTitle,
            summary: note,
            detail: logDetail
        )
        endJobActivity(id: id)
        isBusy = false
        storageCapacityRevision &+= 1
        onJobFinished?(action)
    }

    func recordActivity(action: JobAction, state: JobState, title: String, summary: String, detail: String) {
        let entry = ActivityLogEntry(
            action: action,
            state: state,
            title: title,
            summary: summary,
            detail: detail
        )
        // Mirror the terminal state into the debug stream — action and
        // outcome only; user-facing strings stay in the activity log.
        DebugLog.shared.log(
            "job.finish",
            subsystem: .apply,
            level: state == .failed ? .error : .info,
            outcome: state == .done ? .ok : (state == .cancelled ? .cancel : .error),
            detail: "\(action.rawValue) \(state.rawValue)"
        )
        activityLog.insert(entry, at: 0)
        do {
            try ActivityLogStore(url: URL(fileURLWithPath: Self.expandedPath(configuration.activityLogPath))).append(entry)
        } catch {
            statusMessage = "Saved action on screen, but could not write permanent log: \(error.localizedDescription)"
        }
    }

    func updateConfiguration(_ mutate: (inout AppConfiguration) -> Void) {
        let catalogBefore = CatalogOwnedState(configuration: configuration)
        var next = configuration
        mutate(&next)
        next.normalizeLocationSelections()
        next.normalizeEventSelection()
        // A mutation that leaves the configuration untouched is not a
        // change: no revisions, no save, no catalog sync.
        guard next != configuration else { return }
        configuration = next
        configurationRevision &+= 1
        if CatalogOwnedState(configuration: next) != catalogBefore {
            catalogStateRevision &+= 1
        }
        noteCatalogWrite()
        scheduleConfigurationSave()
        scheduleCatalogSync(configuration: next)
    }

    /// Swaps assignments in place — the catalog change a move or a sort is —
    /// without `updateConfiguration`'s whole-configuration copy and two
    /// full-library comparisons (`removed` and `added` are known to differ,
    /// so there is nothing to compare). One pass over the assignments that
    /// looks at each element's event id first, so only the few rows that
    /// can match ever build an asset-id string. An added row whose asset id
    /// the library already has is skipped, exactly as before.
    /// Returns what actually changed: the rows that were there to remove
    /// and the rows that were new.
    @discardableResult
    func replaceAssignments(
        removing removed: [PhotoEventAssignment],
        adding added: [PhotoEventAssignment],
        touching eventID: UUID? = nil
    ) -> (removed: [PhotoEventAssignment], added: [PhotoEventAssignment]) {
        guard !removed.isEmpty || !added.isEmpty else { return ([], []) }
        let removedIDs = Set(removed.map(CatalogStore.eventAssetID))
        let removedEvents = Set(removed.map(\.eventID))
        let addedEvents = Set(added.map(\.eventID))
        let watchedEvents = removedEvents.union(addedEvents)
        var existingInAddedEvents: Set<String> = []
        var actuallyRemoved: [PhotoEventAssignment] = []
        var actuallyAdded: [PhotoEventAssignment] = []
        var index = 0
        var assignments = configuration.photoEventAssignments
        configuration.photoEventAssignments = []
        var kept = 0
        while index < assignments.count {
            let assignment = assignments[index]
            index += 1
            if watchedEvents.contains(assignment.eventID) {
                let id = CatalogStore.eventAssetID(assignment)
                if removedEvents.contains(assignment.eventID), removedIDs.contains(id) {
                    actuallyRemoved.append(assignment)
                    continue
                }
                if addedEvents.contains(assignment.eventID) { existingInAddedEvents.insert(id) }
            }
            assignments[kept] = assignment
            kept += 1
        }
        assignments.removeLast(assignments.count - kept)
        for assignment in added where existingInAddedEvents.insert(CatalogStore.eventAssetID(assignment)).inserted {
            assignments.append(assignment)
            actuallyAdded.append(assignment)
        }
        configuration.photoEventAssignments = assignments
        if let eventID, let position = configuration.savedEvents.firstIndex(where: { $0.id == eventID }) {
            configuration.savedEvents[position].lastUsedAt = Date()
        }
        configurationRevision &+= 1
        catalogStateRevision &+= 1
        noteCatalogWrite()
        scheduleConfigurationSave()
        scheduleCatalogSync(configuration: configuration)
        return (actuallyRemoved, actuallyAdded)
    }

    /// Config JSON writes are debounced so a burst of mutations (sorting,
    /// event edits, Settings changes) costs one disk write shortly after the
    /// last change. The write runs on the main actor, so saves stay in order;
    /// `flushConfigurationSave()` forces a synchronous write on termination.
    private func scheduleConfigurationSave() {
        configurationSaveIsDirty = true
        configurationSaveTask?.cancel()
        configurationSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            self?.saveConfigurationNow()
        }
    }

    /// Writes the current configuration synchronously, cancelling any pending
    /// debounced save. Called from `applicationWillTerminate` so the last
    /// mutations of a session always reach disk. Skips the write entirely
    /// when nothing changed since the last save — an unconditional encode
    /// of the whole config is wasted work, not a guarantee.
    func flushConfigurationSave() {
        configurationSaveTask?.cancel()
        configurationSaveTask = nil
        if configurationSaveIsDirty {
            saveConfigurationNow()
        }
        if case .catalog(let writer) = catalogStateMode {
            writer.flush()
        }
    }

    private func saveConfigurationNow() {
        switch catalogStateMode {
        case .legacy:
            do {
                try configurationStore.save(configuration)
                configurationSaveIsDirty = false
                configurationFileStamp = configurationStore.fileStamp()
                configMessage = "Config saved at \(Self.defaultConfigurationURL.path)."
            } catch {
                configMessage = "Could not save config: \(error.localizedDescription)"
            }
        case .catalog(let writer):
            // Events and assignments: only the changed rows, off the main
            // actor. Settings: the small config.json.
            writer.submit(CatalogOwnedState(configuration: configuration))
            do {
                try configurationStore.save(configuration, settingsOnly: true)
                configurationSaveIsDirty = false
                configurationFileStamp = configurationStore.fileStamp()
                configMessage = "Settings saved at \(Self.defaultConfigurationURL.path); events are saved in the photo list."
            } catch {
                configMessage = "Could not save settings: \(error.localizedDescription)"
            }
        case .suspended:
            configurationSaveIsDirty = false
            configMessage = "Changes are not being saved until the photo list and config.json are restored. See the status message."
        }
    }

    /// Deletes speed-test temp files left behind by an interrupted run —
    /// `.CameraToolkit-SpeedTest-*.tmp` names inside configured Buffer and
    /// Photo Library folders only, nothing else. Runs off the main actor.
    func removeStaleSpeedTestFiles() {
        let directories = configuration.configuredLocations
            .filter { $0.role == .buffer || $0.role == .archive }
            .map { URL(fileURLWithPath: Self.expandedPath($0.path), isDirectory: true) }
        guard !directories.isEmpty else { return }
        Task.detached(priority: .utility) {
            StorageBenchmarkService().removeStaleTemporaryFiles(in: directories)
        }
    }

    /// Writes pending event and assignment changes to the catalog now,
    /// without waiting for the debounced save. Callers that are about to
    /// write rows referencing `event_assets` (presence, Immich status) call
    /// this first so those rows exist. A no-op on the legacy path, where
    /// the catalog sync mirrors the configuration instead.
    func persistCatalogStateNow() {
        guard case .catalog(let writer) = catalogStateMode else { return }
        writer.submit(CatalogOwnedState(configuration: configuration))
        writer.flush()
    }

    /// Takes the launch decision: which store is durable, and the
    /// migration's message when one ran.
    func adoptCatalogState(_ outcome: CatalogStateStartup.Outcome) {
        switch outcome.mode {
        case .legacy:
            catalogStateMode = .legacy
            try? configurationStore.save(configuration)
            configurationFileStamp = configurationStore.fileStamp()
        case .suspended:
            catalogStateMode = .suspended
        case .catalog(let baseline):
            let catalogURL = URL(fileURLWithPath: Self.expandedPath(configuration.catalogDatabasePath))
            let writer = CatalogStateWriter(
                store: CatalogStateStore(url: catalogURL),
                baseline: baseline,
                emergencyFolder: localCatalogBackupFolder,
                onResult: { [weak self] result in
                    Task { @MainActor in self?.catalogStateWriteFinished(result) }
                }
            )
            catalogStateMode = .catalog(writer)
            if outcome.shouldRewriteConfiguration {
                // The legacy copy (config.pre-sqlite-*.json) and the pinned
                // migration backup both hold the old file.
                try? configurationStore.save(configuration, settingsOnly: true)
                configurationFileStamp = configurationStore.fileStamp()
            }
        }
        if let message = outcome.message {
            statusMessage = message
            configMessage = message
            recordActivity(
                action: .verifyManifest,
                state: outcome.mode.isSuspended ? .failed : .done,
                title: outcome.migration != nil ? "Moved events into the photo list" : "Photo list needs attention",
                summary: message,
                detail: "No photo files were touched."
            )
        }
    }

    private func catalogStateWriteFinished(_ result: Result<CatalogStateChangeSummary, Error>) {
        guard case .failure(let error) = result else { return }
        let message = "Could not save event changes to the photo list: \(error.localizedDescription) "
            + "They are kept in Backups/unsaved-events-*.json and will be retried with the next change."
        statusMessage = message
        configMessage = message
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

    static var defaultApplicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private static var defaultConfigurationURL: URL {
        defaultApplicationSupportURL.appendingPathComponent("CameraToolkit/config.json")
    }

    static let immichAPIKeyAccount = "immich-api-key"
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
        // A mirror root that simply followed the old library root follows
        // the new one; one the user set by hand stays.
        if archiveLayoutRootPath.isEmpty
            || archiveLayoutRootPath == Self.derivedArchiveLayoutRoot(cameraLibraryRootPath: cameraLibraryRootPath) {
            archiveLayoutRootPath = Self.derivedArchiveLayoutRoot(cameraLibraryRootPath: root.path)
        }
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

/// Where events and assignments are durably saved this session.
enum CatalogStateMode {
    /// Pre-migration: config.json holds everything; the catalog mirrors it.
    case legacy
    /// The catalog is the durable store, written through `writer`.
    case catalog(CatalogStateWriter)
    /// Nothing durable is written until the owner restores matching files.
    case suspended

    var isLegacy: Bool {
        if case .legacy = self { return true }
        return false
    }
}

extension CatalogStateStartup.Mode {
    var isSuspended: Bool {
        if case .suspended = self { return true }
        return false
    }
}
