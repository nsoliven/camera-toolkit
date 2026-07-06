import CameraToolkitCore
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

    init(locations: [LocationCard], activePlan: CopyPlan, jobs: [JobSnapshot], safetyChecks: [SafetyCheck]) {
        self.locations = locations
        self.activePlan = activePlan
        self.jobs = jobs
        self.safetyChecks = safetyChecks
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
        ]
    )
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
