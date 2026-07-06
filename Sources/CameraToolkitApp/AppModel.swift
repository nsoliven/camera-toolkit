import CameraToolkitCore
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class DashboardModel {
    var selectedSection: AppSection = .overview
    var locations: [LocationCard]
    var activePlan: CopyPlan
    var jobs: [JobSnapshot]
    var activityLog: [ActivityLogEntry]
    var safetyChecks: [SafetyCheck]
    var selectedDevice: String = "sony-a7v"
    var eventName: String = "Lee Canyon"
    var importDestination: TransferLocation = .nas
    var importSourcePath: String
    var simulationSummary: SimulationSummary?
    var statusMessage: String = "Ready. Demo mode only uses fake local folders."
    var isBusy: Bool = false
    @ObservationIgnored private let activityLogStore: ActivityLogStore

    init(
        locations: [LocationCard],
        activePlan: CopyPlan,
        jobs: [JobSnapshot],
        activityLog: [ActivityLogEntry] = [],
        safetyChecks: [SafetyCheck],
        importSourcePath: String = "",
        activityLogStore: ActivityLogStore = ActivityLogStore(url: DashboardModel.defaultActivityLogURL),
        loadActivityLog: Bool = false
    ) {
        self.locations = locations
        self.activePlan = activePlan
        self.jobs = jobs
        self.safetyChecks = safetyChecks
        self.importSourcePath = importSourcePath
        self.activityLogStore = activityLogStore
        if loadActivityLog {
            self.activityLog = (try? activityLogStore.load()) ?? activityLog
        } else {
            self.activityLog = activityLog
        }
    }

    static func live() -> DashboardModel {
        DashboardModel(
            locations: preview.locations,
            activePlan: preview.activePlan,
            jobs: [],
            safetyChecks: preview.safetyChecks,
            importSourcePath: "~/Library/Application Support/CameraToolkit/Simulation/Fake Card",
            loadActivityLog: true
        )
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
                title: "Completed safe demo",
                summary: "4 copied, 1 quarantined, 1 left alone.",
                detail: "Created fake files, verified the demo archive manifest, and moved only verified buffer files to quarantine."
            ),
            ActivityLogEntry(
                action: .ingestCard,
                state: .done,
                title: "Previewed copy plan",
                summary: "3 new files, 1 already archived, 0 conflicts.",
                detail: "No files were copied during preview."
            )
        ],
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
                helpText: "The real delete path stays behind an explicit typed confirmation. The current demo moves files to quarantine only."
            ),
            SafetyCheck(
                title: "Real volumes",
                detail: "Disabled while the demo workflow is being hardened",
                state: .attention,
                helpText: "Real camera cards, drives, NAS folders, and Immich calls are intentionally locked out in this build."
            )
        ],
        importSourcePath: "~/Library/Application Support/CameraToolkit/Simulation/Fake Card"
    )
}

extension DashboardModel {
    var simulationWorkspace: SimulationWorkspace {
        SimulationWorkspace(root: Self.defaultSimulationRoot)
    }

    func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder to preview locally. Real archive writes are still disabled."
        if panel.runModal() == .OK, let url = panel.url {
            importSourcePath = url.path
            statusMessage = "Selected \(url.lastPathComponent). Use Preview Copy before running the demo import."
            recordActivity(
                action: .ingestCard,
                state: .done,
                title: "Selected source folder",
                summary: statusMessage,
                detail: "The selected folder will be scanned locally. Demo mode still writes only to the fake archive."
            )
        }
    }

    func seedSimulation() {
        runJob(
            action: .ingestCard,
            runningNote: "Creating fake card, archive, and buffer",
            logTitle: "Made demo files",
            logDetail: "Recreated the fake card, fake archive, and fake buffer under Application Support."
        ) {
            try simulationWorkspace.resetAndSeed()
            importSourcePath = simulationWorkspace.sourceCard.path
            activePlan = try simulationWorkspace.previewImport()
            simulationSummary = nil
            statusMessage = "Demo files are ready at \(simulationWorkspace.root.path)."
            refreshSimulationLocations()
        }
    }

    func previewImport() {
        runJob(
            action: .ingestCard,
            runningNote: "Planning immutable copy",
            logTitle: "Previewed copy plan",
            logDetail: "Scanned the source and demo archive. No files were copied during preview."
        ) {
            let source = URL(fileURLWithPath: expandedImportSourcePath)
            let destination = simulationWorkspace.archive
            activePlan = try ArchivePlanner().planCopy(source: source, destination: destination)
            statusMessage = "Preview ready: \(activePlan.new.count) new, \(activePlan.existing.count) already archived, \(activePlan.conflicts.count) conflicts."
        }
    }

    func runSimulationImport() {
        runJob(
            action: .ingestCard,
            runningNote: "Copying into demo archive",
            logTitle: "Ran demo import",
            logDetail: "Copied new files into the demo archive, refused overwrites, verified checksums, and wrote a manifest."
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
            statusMessage = "Demo import verified. Manifest OK: \(result.manifest.ok ? "yes" : "no")."
            refreshSimulationLocations()
        }
    }

    func runSimulationFreeUp() {
        runJob(
            action: .freeUp,
            runningNote: "Checksum comparing buffer before quarantine",
            logTitle: "Ran free-up demo",
            logDetail: "Moved only buffer files that matched the demo archive checksum into local quarantine."
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
            statusMessage = "Free-up demo quarantined \(report.moved.count) verified files and left \(simulationSummary?.leftUnsafeCount ?? 0) unsafe file(s) alone."
            refreshSimulationLocations()
        }
    }

    func runFullSimulation() {
        runJob(
            action: .verifyManifest,
            runningNote: "Running safe demo",
            logTitle: "Completed safe demo",
            logDetail: "Created fake files, copied new files to the demo archive, verified the manifest, and quarantined only proven-safe buffer files."
        ) {
            let summary = try simulationWorkspace.runFullSimulation()
            simulationSummary = summary
            importSourcePath = summary.sourcePath
            activePlan = try simulationWorkspace.previewImport()
            statusMessage = "Safe demo complete: \(summary.copiedCount) copied, \(summary.quarantinedCount) quarantined, \(summary.leftUnsafeCount) left alone."
            refreshSimulationLocations()
        }
    }

    private var expandedImportSourcePath: String {
        NSString(string: importSourcePath).expandingTildeInPath
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
            try activityLogStore.append(entry)
        } catch {
            statusMessage = "Saved action on screen, but could not write permanent log: \(error.localizedDescription)"
        }
    }

    private func refreshSimulationLocations() {
        let workspace = simulationWorkspace
        locations = [
            LocationCard(kind: .card, title: "Fake Card", subtitle: workspace.sourceCard.lastPathComponent, status: .ready, detail: workspace.sourceCard.path),
            LocationCard(kind: .drive, title: "Demo Buffer", subtitle: workspace.buffer.lastPathComponent, status: .warning, detail: "Local test folder"),
            LocationCard(kind: .nas, title: "Demo Archive", subtitle: workspace.archive.lastPathComponent, status: .ready, detail: "Local checksum target"),
            LocationCard(kind: .immich, title: "Immich", subtitle: "Offline in demo", status: .offline, detail: "No network calls")
        ]
    }

    private static var defaultSimulationRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CameraToolkit/Simulation", isDirectory: true)
    }

    private static var defaultActivityLogURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CameraToolkit/activity-log.jsonl")
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case `import` = "Import"
    case library = "Library"
    case drive = "Drive"
    case immich = "Immich"
    case jobs = "Jobs"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .import: "square.and.arrow.down"
        case .library: "photo.stack"
        case .drive: "externaldrive"
        case .immich: "sparkles.rectangle.stack"
        case .jobs: "list.bullet.clipboard"
        case .settings: "gearshape"
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
