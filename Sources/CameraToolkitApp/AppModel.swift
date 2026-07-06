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
    var safetyChecks: [SafetyCheck]
    var selectedDevice: String = "sony-a7v"
    var eventName: String = "Lee Canyon"
    var importDestination: TransferLocation = .nas
    var importSourcePath: String
    var simulationSummary: SimulationSummary?
    var statusMessage: String = "Ready. No real volumes are touched."
    var isBusy: Bool = false

    init(
        locations: [LocationCard],
        activePlan: CopyPlan,
        jobs: [JobSnapshot],
        safetyChecks: [SafetyCheck],
        importSourcePath: String = ""
    ) {
        self.locations = locations
        self.activePlan = activePlan
        self.jobs = jobs
        self.safetyChecks = safetyChecks
        self.importSourcePath = importSourcePath
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
        safetyChecks: [
            SafetyCheck(title: "Archive copy mode", detail: "rclone copy --checksum --immutable", state: .passed),
            SafetyCheck(title: "Free-up gate", detail: "Fresh checksum compare required before quarantine", state: .passed),
            SafetyCheck(title: "Permanent delete", detail: "Requires typed DELETE confirmation", state: .passed),
            SafetyCheck(title: "Real volumes", detail: "Disabled until temp-dir suite is green", state: .attention)
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
            statusMessage = "Selected \(url.lastPathComponent). Preview before running anything."
        }
    }

    func seedSimulation() {
        runJob(action: .ingestCard, runningNote: "Creating fake card, archive, and buffer") {
            try simulationWorkspace.resetAndSeed()
            importSourcePath = simulationWorkspace.sourceCard.path
            activePlan = try simulationWorkspace.previewImport()
            simulationSummary = nil
            statusMessage = "Simulation workspace is ready at \(simulationWorkspace.root.path)."
            refreshSimulationLocations()
        }
    }

    func previewImport() {
        runJob(action: .ingestCard, runningNote: "Planning immutable copy") {
            let source = URL(fileURLWithPath: expandedImportSourcePath)
            let destination = simulationWorkspace.archive
            activePlan = try ArchivePlanner().planCopy(source: source, destination: destination)
            statusMessage = "Preview ready: \(activePlan.new.count) new, \(activePlan.existing.count) already there, \(activePlan.conflicts.count) conflicts."
        }
    }

    func runSimulationImport() {
        runJob(action: .ingestCard, runningNote: "Copying into simulation archive") {
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
            statusMessage = "Simulation import verified. Manifest OK: \(result.manifest.ok ? "yes" : "no")."
            refreshSimulationLocations()
        }
    }

    func runSimulationFreeUp() {
        runJob(action: .freeUp, runningNote: "Checksum comparing buffer before quarantine") {
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
            statusMessage = "Free-up simulation quarantined \(report.moved.count) verified files and left \(simulationSummary?.leftUnsafeCount ?? 0) unsafe file(s)."
            refreshSimulationLocations()
        }
    }

    func runFullSimulation() {
        runJob(action: .verifyManifest, runningNote: "Running full safe workflow") {
            let summary = try simulationWorkspace.runFullSimulation()
            simulationSummary = summary
            importSourcePath = summary.sourcePath
            activePlan = try simulationWorkspace.previewImport()
            statusMessage = "Full simulation complete: \(summary.copiedCount) copied, \(summary.quarantinedCount) quarantined, \(summary.leftUnsafeCount) left unsafe."
            refreshSimulationLocations()
        }
    }

    private var expandedImportSourcePath: String {
        NSString(string: importSourcePath).expandingTildeInPath
    }

    private func runJob(action: JobAction, runningNote: String, operation: () throws -> Void) {
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
        jobs[0] = job
        isBusy = false
    }

    private func refreshSimulationLocations() {
        let workspace = simulationWorkspace
        locations = [
            LocationCard(kind: .card, title: "Fake Card", subtitle: workspace.sourceCard.lastPathComponent, status: .ready, detail: workspace.sourceCard.path),
            LocationCard(kind: .drive, title: "Simulation Buffer", subtitle: workspace.buffer.lastPathComponent, status: .warning, detail: "Local test folder"),
            LocationCard(kind: .nas, title: "Simulation Archive", subtitle: workspace.archive.lastPathComponent, status: .ready, detail: "Local checksum target"),
            LocationCard(kind: .immich, title: "Immich", subtitle: "Offline in simulation", status: .offline, detail: "No network calls")
        ]
    }

    private static var defaultSimulationRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CameraToolkit/Simulation", isDirectory: true)
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
