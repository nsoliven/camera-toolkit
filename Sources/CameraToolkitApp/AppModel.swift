import CameraToolkitCore
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class DashboardModel {
    var selectedSection: AppSection = .overview
    var isSidebarCollapsed: Bool = false
    var locations: [LocationCard]
    var activePlan: CopyPlan
    var workflowPlans: [WorkflowPlan] = []
    var jobs: [JobSnapshot]
    var activityLog: [ActivityLogEntry]
    var configuration: AppConfiguration
    var configMessage: String = "Config is saved automatically."
    var safetyChecks: [SafetyCheck]
    var simulationSummary: SimulationSummary?
    var statusMessage: String = "Ready. Configured workflows are pointed and locked; safety tests are available for disposable checks."
    var isBusy: Bool = false
    var libraryFiles: [FileRecord] = []
    var lastOpenedWorkingCopyPath: String?
    var immichAPIKeyDraft: String = ""
    var immichConnectionStatus: String = "Not connected. Add your server URL and API key in Config."
    var immichConnectionReport: ImmichConnectionReport?
    var immichIsTestingConnection: Bool = false
    var isRefreshing: Bool = false
    var lastRefreshedAt: Date?
    @ObservationIgnored private let configurationStore: ConfigurationStore
    @ObservationIgnored private let secretStore = KeychainSecretStore(service: "org.cameratoolkit.CameraToolkit")
    @ObservationIgnored private let editorLauncher = ExternalEditorLauncher()

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
        self.immichAPIKeyDraft = (try? secretStore.read(account: Self.immichAPIKeyAccount)) ?? ""
        if !immichAPIKeyDraft.isEmpty {
            self.immichConnectionStatus = "API key is saved in Keychain. Test the connection when the server is reachable."
        }
        rebuildWorkflowPlans()
    }

    static func live() -> DashboardModel {
        let defaults = AppConfiguration.defaults(applicationSupport: defaultApplicationSupportURL)
        let store = ConfigurationStore(url: defaultConfigurationURL)
        let configuration = (try? store.load(defaults: defaults)) ?? defaults
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
        return model
    }

    static let preview = DashboardModel(
        locations: [
            LocationCard(kind: .card, title: "Camera Card", subtitle: "Sony A7V detected", status: .ready, detail: "5 new files · 48.2 GB"),
            LocationCard(kind: .drive, title: "Portable Drive", subtitle: "Photo Workspace", status: .warning, detail: "312 GB free"),
            LocationCard(kind: .nas, title: "Home Server", subtitle: "Camera Archive", status: .ready, detail: "Mounted · checksum-ready"),
            LocationCard(kind: .immich, title: "Immich", subtitle: "Camera Archive library", status: .ready, detail: "Connected")
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
            JobSnapshot(action: .ingestCard, state: .running, progress: 0.42, note: "Hash verifying copied files"),
            JobSnapshot(action: .immichScan, state: .done, progress: 1, note: "Library scan queued")
        ],
        activityLog: [
            ActivityLogEntry(
                action: .verifyManifest,
                state: .done,
                title: "Completed safety test",
                summary: "4 copied, 1 quarantined, 1 left alone.",
                detail: "Created disposable test files, verified the archive manifest, and moved only verified buffer files to quarantine."
            ),
            ActivityLogEntry(
                action: .ingestCard,
                state: .done,
                title: "Previewed copy plan",
                summary: "3 new files, 1 already archived, 0 conflicts.",
                detail: "No files were copied during preview."
            )
        ],
        configuration: .defaults(applicationSupport: defaultApplicationSupportURL),
        safetyChecks: [
            SafetyCheck(
                title: "Archive copy mode",
                detail: "rclone copy --checksum --immutable",
                state: .passed,
                helpText: "Archive writes must copy by checksum and refuse overwrites. If a file already exists with different bytes, the app reports a conflict instead of replacing it."
            ),
            SafetyCheck(
                title: "Free-up gate",
                detail: "Fresh checksum compare required before quarantine",
                state: .passed,
                helpText: "Free-up means making space on temporary storage. The app only quarantines a buffer file after proving the archive has the same bytes."
            ),
            SafetyCheck(
                title: "Permanent delete",
                detail: "Requires typed DELETE confirmation",
                state: .passed,
                helpText: "The real delete path stays behind an explicit typed confirmation. Safety tests move files to quarantine only."
            ),
            SafetyCheck(
                title: "Execution lock",
                detail: "Real writes and uploads require deliberate unlock",
                state: .attention,
                helpText: "Real camera cards, drives, NAS folders, and Immich uploads are represented by locked workflow plans. Immich connection checks are allowed because they do not move files."
            )
        ]
    )
}

extension DashboardModel {
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

    func chooseImportFolder() {
        if chooseFolder(title: "Choose Import Source", keyPath: \.importSourcePath) {
            statusMessage = "Selected \(URL(fileURLWithPath: configuration.importSourcePath).lastPathComponent). Use Preview Copy Plan to inspect the configured archive comparison."
            recordActivity(
                action: .ingestCard,
                state: .done,
                title: "Selected source folder",
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

    func chooseEditorWorkingFolder() {
        _ = chooseFolder(title: "Choose Editor Working Folder", keyPath: \.editorWorkingFolderPath)
    }

    func setConfigPath(_ keyPath: WritableKeyPath<AppConfiguration, String>, to value: String) {
        updateConfiguration { configuration in
            configuration[keyPath: keyPath] = value
        }
    }

    func setDeviceID(_ value: String) {
        updateConfiguration { $0.selectedDeviceID = value }
    }

    func setEventName(_ value: String) {
        updateConfiguration { $0.eventName = value }
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
            rebuildWorkflowPlans()
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
        let apiKey = immichAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty else {
            immichConnectionStatus = "Add an Immich server URL in Config first."
            return
        }
        guard !apiKey.isEmpty else {
            immichConnectionStatus = "Add an Immich API key first. It will be stored in Keychain."
            return
        }

        do {
            try secretStore.save(apiKey, account: Self.immichAPIKeyAccount)
            Task { @MainActor in
                await performImmichConnectionCheck(serverURL: serverURL, apiKey: apiKey, shouldRecordActivity: true)
            }
        } catch {
            immichConnectionStatus = "Could not prepare Immich connection: \(error.localizedDescription)"
        }
    }

    func refreshLibraryFiles() {
        do {
            let records = try loadLibraryFiles()
            statusMessage = records.isEmpty
                ? "No supported photo files found in \(expandedImportSourcePath)."
                : "Found \(records.count) supported photo file(s) in \(expandedImportSourcePath)."
        } catch {
            libraryFiles = []
            statusMessage = "Could not scan library source: \(error.localizedDescription)"
        }
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
            statusMessage = "Opened \(file.path) in \(configuration.externalEditor.displayName) from a protected working copy."
            recordActivity(
                action: .checkout,
                state: .done,
                title: "Opened photo for editing",
                summary: statusMessage,
                detail: "Source stayed untouched. Working copy: \(copyURL.path)"
            )
        } catch {
            statusMessage = "Could not open \(file.path): \(error.localizedDescription)"
            recordActivity(
                action: .checkout,
                state: .failed,
                title: "Photo open failed",
                summary: statusMessage,
                detail: "No source file was changed."
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
            statusMessage = "Opened \(file.path) from Copy Plan in \(configuration.externalEditor.displayName)."
            recordActivity(
                action: .checkout,
                state: .done,
                title: "Opened copy-plan file",
                summary: statusMessage,
                detail: "Source stayed untouched. Working copy: \(copyURL.path)"
            )
        } catch {
            statusMessage = "Could not open \(file.path): \(error.localizedDescription)"
            recordActivity(
                action: .checkout,
                state: .failed,
                title: "Copy-plan open failed",
                summary: statusMessage,
                detail: "No source file was changed."
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
                title: "Revealed copy-plan file",
                summary: statusMessage,
                detail: "No files were changed. Source: \(source.path)"
            )
        } catch {
            statusMessage = "Could not reveal \(file.path): \(error.localizedDescription)"
            recordActivity(
                action: .checkout,
                state: .failed,
                title: "Copy-plan reveal failed",
                summary: statusMessage,
                detail: "No source file was changed."
            )
        }
    }

    func seedSimulation() {
        runJob(
            action: .ingestCard,
            runningNote: "Creating disposable source, archive, and buffer",
            logTitle: "Created test data",
            logDetail: "Recreated the disposable source, archive, and buffer under Application Support."
        ) {
            try simulationWorkspace.resetAndSeed()
            setConfigPath(\.importSourcePath, to: simulationWorkspace.sourceCard.path)
            activePlan = try simulationWorkspace.previewImport()
            simulationSummary = nil
            statusMessage = "Test data is ready at \(simulationWorkspace.root.path)."
            refreshLocationCards()
        }
    }

    func previewImport() {
        runJob(
            action: .ingestCard,
            runningNote: "Planning immutable copy",
            logTitle: "Previewed copy plan",
            logDetail: "Scanned the configured source and archive. No files were copied during preview."
        ) {
            let source = URL(fileURLWithPath: expandedImportSourcePath)
            let destination = URL(fileURLWithPath: Self.expandedPath(configuration.archivePath), isDirectory: true)
            activePlan = try ArchivePlanner().planCopy(source: source, destination: destination)
            statusMessage = "Preview ready: \(activePlan.new.count) new, \(activePlan.existing.count) already archived, \(activePlan.conflicts.count) conflicts."
        }
    }

    func runSimulationImport() {
        runJob(
            action: .ingestCard,
            runningNote: "Copying into test archive",
            logTitle: "Ran import safety test",
            logDetail: "Copied new files into the test archive, refused overwrites, verified checksums, and wrote a manifest."
        ) {
            let result = try simulationWorkspace.runImport()
            simulationSummary = SimulationSummary(
                root: simulationWorkspace.root.path,
                sourcePath: simulationWorkspace.sourceCard.path,
                archivePath: simulationWorkspace.archive.path,
                bufferPath: simulationWorkspace.buffer.path,
                manifestOK: result.manifest.ok,
                copiedCount: result.copy.copied.count,
                quarantinedCount: simulationSummary?.quarantinedCount ?? 0,
                leftUnsafeCount: 0
            )
            activePlan = try simulationWorkspace.previewImport()
            statusMessage = "Import safety test verified. Manifest OK: \(result.manifest.ok ? "yes" : "no")."
            refreshLocationCards()
        }
    }

    func runSimulationFreeUp() {
        runJob(
            action: .freeUp,
            runningNote: "Checksum comparing buffer before quarantine",
            logTitle: "Ran free-up safety test",
            logDetail: "Moved only disposable buffer files that matched the archive checksum into quarantine."
        ) {
            let report = try simulationWorkspace.runFreeUp()
            simulationSummary = SimulationSummary(
                root: simulationWorkspace.root.path,
                sourcePath: simulationWorkspace.sourceCard.path,
                archivePath: simulationWorkspace.archive.path,
                bufferPath: simulationWorkspace.buffer.path,
                manifestOK: simulationSummary?.manifestOK ?? false,
                copiedCount: simulationSummary?.copiedCount ?? 0,
                quarantinedCount: report.moved.count,
                leftUnsafeCount: report.notOnArchive.count + report.differ.count + report.errors.count
            )
            statusMessage = "Free-up safety test quarantined \(report.moved.count) verified files and left \(simulationSummary?.leftUnsafeCount ?? 0) unsafe file(s) alone."
            refreshLocationCards()
        }
    }

    func runFullSimulation() {
        runJob(
            action: .verifyManifest,
            runningNote: "Running safety test",
            logTitle: "Completed safety test",
            logDetail: "Created disposable test files, copied new files to the archive, verified the manifest, and quarantined only proven-safe buffer files."
        ) {
            let summary = try simulationWorkspace.runFullSimulation()
            simulationSummary = summary
            setConfigPath(\.importSourcePath, to: summary.sourcePath)
            activePlan = try simulationWorkspace.previewImport()
            statusMessage = "Safety test complete: \(summary.copiedCount) copied, \(summary.quarantinedCount) quarantined, \(summary.leftUnsafeCount) left alone."
            refreshLocationCards()
        }
    }

    private var expandedImportSourcePath: String {
        Self.expandedPath(configuration.importSourcePath)
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
            immichAPIKeyDraft = try secretStore.read(account: Self.immichAPIKeyAccount) ?? ""
            if !immichAPIKeyDraft.isEmpty, immichConnectionReport == nil {
                immichConnectionStatus = "API key is saved in Keychain. Test the connection when the server is reachable."
            }
        } catch {
            immichConnectionStatus = "Could not reload Immich API key from Keychain: \(error.localizedDescription)"
        }

        do {
            activityLog = try ActivityLogStore(url: URL(fileURLWithPath: Self.expandedPath(configuration.activityLogPath))).load()
            notes.append("\(activityLog.count) log entries")
        } catch {
            notes.append("log unavailable")
        }

        do {
            let records = try loadLibraryFiles()
            notes.append("\(records.count) photos")
        } catch {
            libraryFiles = []
            notes.append("library unavailable")
        }

        if let planNote = refreshCopyPlanIfPossible() {
            notes.append(planNote)
        }
        rebuildWorkflowPlans()

        let serverURL = configuration.immichServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = immichAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverURL.isEmpty, !apiKey.isEmpty {
            await performImmichConnectionCheck(serverURL: serverURL, apiKey: apiKey, shouldRecordActivity: false)
            notes.append("Immich")
        }

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

    private func refreshCopyPlanIfPossible() -> String? {
        do {
            let source = URL(fileURLWithPath: expandedImportSourcePath)
            let destination = URL(fileURLWithPath: Self.expandedPath(configuration.archivePath), isDirectory: true)
            activePlan = try ArchivePlanner().planCopy(source: source, destination: destination)
            return "\(activePlan.new.count) new in plan"
        } catch {
            return nil
        }
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

    private func runJob(
        action: JobAction,
        runningNote: String,
        logTitle: String,
        logDetail: String,
        operation: () throws -> Void
    ) {
        isBusy = true
        var job = JobSnapshot(action: action, state: .running, progress: 0.35, note: runningNote)
        jobs.insert(job, at: 0)
        do {
            try operation()
            job.state = .done
            job.progress = 1
            job.note = "Done"
            job.finishedAt = Date()
        } catch {
            job.state = .failed
            job.progress = 1
            job.note = String(describing: error)
            job.finishedAt = Date()
            statusMessage = job.note
        }
        let summary = statusMessage
        job.note = summary
        jobs[0] = job
        recordActivity(
            action: action,
            state: job.state,
            title: logTitle,
            summary: summary,
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
        configuration = next
        do {
            try configurationStore.save(next)
            configMessage = "Config saved at \(Self.defaultConfigurationURL.path)."
        } catch {
            configMessage = "Could not save config: \(error.localizedDescription)"
        }
        rebuildWorkflowPlans()
        refreshLocationCards()
    }

    private func rebuildWorkflowPlans() {
        workflowPlans = WorkflowPlanner().plans(
            for: configuration,
            hasImmichAPIKey: !immichAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private func refreshLocationCards() {
        let source = URL(fileURLWithPath: expandedImportSourcePath, isDirectory: true)
        let archive = URL(fileURLWithPath: Self.expandedPath(configuration.archivePath), isDirectory: true)
        let buffer = URL(fileURLWithPath: Self.expandedPath(configuration.bufferPath), isDirectory: true)
        locations = [
            LocationCard(kind: .card, title: "Import Source", subtitle: displayName(for: source), status: status(forFolder: source), detail: source.path),
            LocationCard(kind: .drive, title: "Buffer", subtitle: displayName(for: buffer), status: .warning, detail: "Locked free-up plan: \(buffer.path)"),
            LocationCard(kind: .nas, title: "Archive", subtitle: displayName(for: archive), status: status(forFolder: archive), detail: archive.path),
            immichLocationCard
        ]
    }

    private func status(forFolder url: URL) -> LocationStatus {
        FileManager.default.fileExists(atPath: url.path) ? .ready : .warning
    }

    private func displayName(for url: URL) -> String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
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

    private static func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}

enum AppSection: String, CaseIterable, Identifiable {
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
