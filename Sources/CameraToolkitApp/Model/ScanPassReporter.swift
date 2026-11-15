import CameraToolkitCore
import Foundation

/// Turns one scan pass's raw progress into what the Jobs window should show.
///
/// The scanner's reports describe the step at hand: its file counters run
/// for the files, then carry the number of *faces* while it matches and
/// groups, and its wording is the same for dogs as for faces. This keeps
/// each pass's counts on its files, holds them through matching and
/// grouping, derives the job's percent from those same counts so it can
/// only rise, and names what is running. Reporting only: the scan never
/// sees any of it.
final class ScanPassReporter: @unchecked Sendable {
    /// The job is not finished until it says so; matching the last pass
    /// still has to run after its last file.
    static let highestRunningProgress = 0.99
    /// Where a job's bar already sits when its first report arrives.
    static let startingProgress = 0.02

    private let lock = NSLock()
    private let pass: JobScanPass
    private var files = 0
    private var totalFiles = 0
    private var bytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var highestProgress: Double

    init(pass: JobScanPass) {
        self.pass = pass
        highestProgress = max(pass.jobFraction(passFraction: 0), Self.startingProgress)
    }

    /// Called from the scan's worker threads.
    func update(from update: FileOperationProgress) -> BackgroundJobUpdate {
        // The header check runs before the scan's own count starts, so it
        // reports only words and holds the bar where it is.
        if update.phase == FaceIndexService.orientationCheckPhase {
            var checking = DashboardModel.jobUpdate(from: update, lowerBound: 0, upperBound: 1, notePrefix: pass.subject.scanName, command: "")
            checking.progress = lock.withLock { highestProgress }
            checking.note = "\(pass.subject.scanName): \(Self.phrase(update.phase, subject: pass.subject))"
            return checking
        }
        // Only the per-file part of a scan estimates its work.
        let finishing = update.telemetry?.work == nil
        var reported = update
        let progress: Double = lock.withLock {
            if finishing {
                reported.processedFiles = files
                reported.totalFiles = totalFiles
                reported.processedBytes = bytes
                reported.totalBytes = totalBytes
                reported.bytesPerSecond = 0
            } else {
                files = update.processedFiles
                totalFiles = update.totalFiles
                bytes = update.processedBytes
                totalBytes = update.totalBytes
            }
            let passFraction = finishing ? 1 : (update.totalFiles > 0 ? Double(update.processedFiles) / Double(update.totalFiles) : 0)
            let reached = min(pass.jobFraction(passFraction: passFraction), Self.highestRunningProgress)
            highestProgress = max(highestProgress, reached)
            return highestProgress
        }

        var result = DashboardModel.jobUpdate(from: reported, lowerBound: 0, upperBound: 1, notePrefix: pass.subject.scanName, command: "")
        result.progress = progress
        result.note = "\(pass.subject.scanName): \(Self.phrase(update.phase, subject: pass.subject))"
        result.telemetry = update.telemetry.map { Self.relabelled($0, pass: pass) }
        return result
    }

    /// The scanner's step in words that fit what is being scanned.
    static func phrase(_ phase: String, subject: JobScanPass.Subject) -> String {
        guard subject == .dogs else { return phase }
        return switch phase {
        case "Detecting faces": "Detecting dogs"
        case "Matching people": "Matching dogs"
        case "Grouping faces": "Grouping dogs"
        default: phase
        }
    }

    /// The telemetry with this pass stamped on it, and a dog pass's labels
    /// saying dogs. The scan shares its code, and its words, with faces.
    static func relabelled(_ telemetry: JobTelemetry, pass: JobScanPass) -> JobTelemetry {
        var result = telemetry
        result.scanPass = pass
        guard pass.subject == .dogs else { return result }
        result.counters = telemetry.counters.map { counter in
            counter.label == "Faces" ? JobCounter(label: "Dogs", value: counter.value) : counter
        }
        result.facts = telemetry.facts.map { $0.replacingOccurrences(of: "min face", with: "min dog") }
        return result
    }
}
