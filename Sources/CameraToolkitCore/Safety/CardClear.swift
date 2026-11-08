import Foundation

// "Clear from Card": permanently deleting camera originals from a card once
// every one of them is proven to be in its event on the drive AND on the NAS.
//
// Two steps, both read-only until the very last one:
// - `CardClearPlanner` decides what is eligible (shown on the board, and
//   re-run inside the job at click time — never a cached answer).
// - `CardClearService` re-hashes, item by item, and only then hands each item
//   to `SourceCleanupService`, which re-hashes the card file against its
//   drive copy and deletes the card file. Drive and NAS copies are only read.

/// One card file that may be cleared, with the copies that vouch for it.
public struct CardClearFile: Hashable, Sendable {
    /// The card file (absolute, standardized).
    public var sourcePath: String
    /// The catalog row's relative path, under `CardClearItem.sourceRoot` on
    /// the card and under `CardClearItem.driveRoot` on the drive.
    public var relativePath: String
    public var byteCount: Int64
    public var modifiedAt: Date
    /// The event's drive copy (Buffer or private staging).
    public var drivePath: String
    /// The NAS mirror copy Sync to NAS wrote and verified.
    public var nasPath: String
    /// The SHA-256 Sync to NAS recorded as verified for that drive copy.
    public var verifiedSHA256: String

    public init(sourcePath: String, relativePath: String, byteCount: Int64, modifiedAt: Date, drivePath: String, nasPath: String, verifiedSHA256: String) {
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.drivePath = drivePath
        self.nasPath = nasPath
        self.verifiedSHA256 = verifiedSHA256
    }
}

/// One board item — a photo with its RAW/JPEG twin, a clip with its XML —
/// cleared together or not at all.
public struct CardClearItem: Hashable, Sendable, Identifiable {
    /// The primary file's source path key.
    public var id: String
    public var eventID: UUID
    public var sourceRoot: String
    public var driveRoot: String
    public var files: [CardClearFile]

    public init(id: String, eventID: UUID, sourceRoot: String, driveRoot: String, files: [CardClearFile]) {
        self.id = id
        self.eventID = eventID
        self.sourceRoot = sourceRoot
        self.driveRoot = driveRoot
        self.files = files
    }

    public var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

/// One board item as the planner reads it: each file with its catalog row
/// (nil when it is not sorted).
public struct CardClearInput: Sendable {
    public struct Entry: Sendable {
        public var path: String
        public var assignment: PhotoEventAssignment?

        public init(path: String, assignment: PhotoEventAssignment?) {
            self.path = path
            self.assignment = assignment
        }
    }

    public var id: String
    public var entries: [Entry]

    public init(id: String, entries: [Entry]) {
        self.id = id
        self.entries = entries
    }
}

public struct CardClearPlan: Equatable, Sendable {
    /// Items whose every file is in its event on the drive and was verified
    /// on the NAS by Sync to NAS.
    public var clearable: [CardClearItem] = []
    /// Items whose every file is in its event on the drive, but not every
    /// file has a verified NAS copy yet: "waiting for Sync to NAS".
    public var waitingForNAS: [WaitingItem] = []
    /// `AppliedSourceCheck`'s answer for the same files, from the same pass.
    public var applied: [String: UUID] = [:]
    /// The drive's volume name, for "safe on <drive> and the NAS".
    public var driveName: String?

    public struct WaitingItem: Equatable, Sendable {
        public var id: String
        public var eventID: UUID
        public var fileCount: Int
        public var byteCount: Int64
    }

    public init() {}

    public var clearableFiles: Int { clearable.reduce(0) { $0 + $1.files.count } }
    public var clearableBytes: Int64 { clearable.reduce(0) { $0 + $1.byteCount } }
    public var waitingFiles: Int { waitingForNAS.reduce(0) { $0 + $1.fileCount } }
    public var waitingBytes: Int64 { waitingForNAS.reduce(0) { $0 + $1.byteCount } }
}

public enum CardClearPlanner {
    /// Eligibility, per item and all-or-nothing within an item. A file is
    /// clearable only when every one of these holds:
    /// - it is sorted (`assignment`), lives under `sourceRoot`, and is not a
    ///   camera support file (`CameraSupportFiles`);
    /// - it is applied: `AppliedSourceCheck.appliedAssets` found its event's
    ///   drive copy at the recorded size, on another volume than the card,
    ///   and the source is not itself that copy;
    /// - its NAS mirror copy has a Sync to NAS record (`nas_sync_files`) in
    ///   state `verified`, with a verification date, the same byte count, a
    ///   SHA-256, and the drive copy's current modification time — the rule
    ///   `EventPresenceScanner` applies before Take Off Drive may trust it.
    /// The NAS share itself is not read here.
    public static func plan(
        inputs: [CardClearInput],
        sourceRoot: String,
        events: [UUID: SavedCameraEvent],
        locations: EventStorageLocations,
        catalogURL: URL?,
        mountedVolumes: Set<String>? = nil,
        pauseGate: DriveActivityGate? = nil,
        sameVolume: AppliedSourceCheck.SameVolume? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> CardClearPlan {
        var plan = CardClearPlan()
        let assignments = inputs.flatMap { $0.entries.compactMap(\.assignment) }
        guard !assignments.isEmpty else { return plan }
        let assets = AppliedSourceCheck.appliedAssets(
            assignments: assignments,
            events: events,
            locations: locations,
            mountedVolumes: mountedVolumes,
            pauseGate: pauseGate,
            sameVolume: sameVolume,
            isCancelled: isCancelled
        )
        plan.applied = assets.mapValues(\.assignment.eventID)
        guard !assets.isEmpty, !isCancelled() else { return plan }

        // One catalog read for every applied file's NAS record.
        var mirrorKeys: [String: String] = [:]
        for (sourceKey, asset) in assets {
            guard let event = events[asset.assignment.eventID],
                  let mirror = try? locations.layout(for: event, deviceID: asset.assignment.deviceID)
                    .mirrorRelativePath(for: asset.assignment.relativePath) else { continue }
            mirrorKeys[sourceKey] = NASSyncStore.pathKey(mirror)
        }
        let records = catalogURL.map {
            NASSyncStore.records(catalogURL: $0, nasRoot: locations.nasRoot.path, pathKeys: Array(Set(mirrorKeys.values)))
        } ?? [:]

        let root = URL(fileURLWithPath: sourceRoot, isDirectory: true).standardizedFileURL.path + "/"
        var driveRoots: [String] = []
        for input in inputs {
            guard !isCancelled() else { break }
            guard !input.entries.isEmpty,
                  input.entries.allSatisfy({ $0.assignment != nil }),
                  !input.entries.contains(where: { CameraSupportFiles.isCameraGenerated($0.path) }) else { continue }
            var files: [CardClearFile] = []
            var verified = true
            var applied = true
            var roots: Set<String> = []
            var eventIDs: Set<UUID> = []
            for entry in input.entries {
                let key = EventStorageLocations.pathKey(entry.path)
                guard let assignment = entry.assignment,
                      let asset = assets[key], asset.assignment.eventID == assignment.eventID,
                      let source = asset.sourcePath, source.hasPrefix(root),
                      let drivePath = asset.drivePath, let driveRoot = asset.driveRootPath,
                      !asset.driveIsLegacyLayout,
                      let nasPath = asset.archivePath, !asset.archiveIsLegacyLayout else {
                    applied = false
                    break
                }
                let sourceRootPath = URL(fileURLWithPath: NSString(string: assignment.sourceRootPath).expandingTildeInPath, isDirectory: true)
                    .standardizedFileURL.path
                // The cleanup service joins root + relative path on both
                // sides; it must name exactly this card file.
                guard EventStorageLocations.pathKey((sourceRootPath as NSString).appendingPathComponent(assignment.relativePath)) == key else {
                    applied = false
                    break
                }
                roots.insert(sourceRootPath + "\u{0}" + driveRoot)
                eventIDs.insert(assignment.eventID)
                guard let mirrorKey = mirrorKeys[key], let record = records[mirrorKey],
                      let sha = record.sha256, !sha.isEmpty,
                      isTrusted(record, assignment: assignment, drivePath: drivePath) else {
                    verified = false
                    continue
                }
                files.append(CardClearFile(
                    sourcePath: source,
                    relativePath: assignment.relativePath,
                    byteCount: assignment.fileSize,
                    modifiedAt: assignment.modifiedAt,
                    drivePath: drivePath,
                    nasPath: nasPath,
                    verifiedSHA256: sha.lowercased()
                ))
            }
            guard applied, let eventID = eventIDs.first else { continue }
            let bytes = input.entries.reduce(Int64(0)) { $0 + ($1.assignment?.fileSize ?? 0) }
            guard verified, files.count == input.entries.count else {
                plan.waitingForNAS.append(.init(id: input.id, eventID: eventID, fileCount: input.entries.count, byteCount: bytes))
                continue
            }
            // One item clears through one cleanup call: one card root, one
            // drive root, one event. Anything else is left alone.
            guard roots.count == 1, eventIDs.count == 1, let pair = roots.first else { continue }
            let parts = pair.components(separatedBy: "\u{0}")
            plan.clearable.append(CardClearItem(id: input.id, eventID: eventID, sourceRoot: parts[0], driveRoot: parts[1], files: files))
            driveRoots.append(parts[1])
        }
        if let first = driveRoots.first ?? assets.values.first?.driveRootPath {
            plan.driveName = try? URL(fileURLWithPath: first).resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
        }
        return plan
    }

    /// A verified Sync to NAS record about this very drive copy: verified,
    /// dated, same size, and made when the drive file had its current
    /// modification time (so a drive file replaced since does not inherit it).
    static func isTrusted(_ record: NASSyncRecord, assignment: PhotoEventAssignment, drivePath: String) -> Bool {
        guard record.state == .verified, record.verifiedAt != nil, record.byteCount == assignment.fileSize,
              let recorded = record.sourceModifiedAt,
              let modified = (try? URL(fileURLWithPath: drivePath).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSinceReferenceDate else { return false }
        return abs(recorded - modified) < 0.001
    }
}

/// How many files passed each of Clear from Card's checks — counted as the
/// checks run, never inferred. A file stops at its first failed check, so
/// each count is at most the one before it.
public struct CardClearChecks: Codable, Equatable, Hashable, Sendable {
    /// Files whose checks ran (passed or not).
    public var checked: Int
    /// Drive copies that re-hashed to the hash Sync to NAS verified.
    public var driveMatched: Int
    /// NAS copies that were read again and matched the drive copy. Zero
    /// when the NAS was not reachable.
    public var nasMatched: Int
    /// True when the NAS was read again; false when the recorded Sync to NAS
    /// hash stood in for it (the drive match is then the NAS answer too).
    public var nasReread: Bool
    /// Card files that hashed the same as their drive copy.
    public var cardMatched: Int
    /// Card files deleted.
    public var cleared: Int
    /// Card files that stayed, for any reason.
    public var skipped: Int
    /// The drive's volume name, when the caller knows it.
    public var driveName: String?

    public init(
        checked: Int = 0,
        driveMatched: Int = 0,
        nasMatched: Int = 0,
        nasReread: Bool = true,
        cardMatched: Int = 0,
        cleared: Int = 0,
        skipped: Int = 0,
        driveName: String? = nil
    ) {
        self.checked = checked
        self.driveMatched = driveMatched
        self.nasMatched = nasMatched
        self.nasReread = nasReread
        self.cardMatched = cardMatched
        self.cleared = cleared
        self.skipped = skipped
        self.driveName = driveName
    }

    /// Files the NAS side vouched for: fresh re-reads, or — with the NAS
    /// unreachable — drive copies that matched the recorded NAS hash.
    public var nasVouched: Int { nasReread ? nasMatched : driveMatched }
}

public struct CardClearReport: Equatable, Sendable {
    /// Card files deleted.
    public var cleared: [String] = []
    public var clearedBytes: Int64 = 0
    /// Card file → why it stayed. Nothing about it was changed.
    public var skipped: [String: String] = [:]
    /// The NAS was not reachable, so the NAS side rested on the hash Sync to
    /// NAS recorded as verified rather than a fresh read.
    public var usedRecordedNASHashes = false
    /// Busy seconds and bytes read per phase ("Verify", "Remove").
    public var phases: [JobPhaseTotal] = []
    /// Per-copy results of the checks that ran.
    public var checks = CardClearChecks()

    public init() {}
}

/// How one card file settled, as it settles — one job row each.
public struct CardClearFileResult: Equatable, Sendable {
    public var sourcePath: String
    public var relativePath: String
    public var byteCount: Int64
    /// "Verify" or "Remove": the phase that decided.
    public var phase: String
    public var removed: Bool
    /// Why it stayed; nil when removed.
    public var reason: String?
}

/// The final pass, in two phases.
///
/// **Verify** — per item, for every file: the card file and its drive copy
/// are re-hashed (`FileScanner.sha256`) and must be equal; the drive copy's
/// hash must equal the SHA-256 Sync to NAS recorded as verified; with the NAS
/// reachable its copy is re-hashed and must equal it too. Files must not
/// change while they are read.
///
/// **Remove** — per verified item: the card file and drive copy must still be
/// the files Verify read (size, modification time, file number); then
/// `SourceCleanupService` re-hashes the card file against the drive copy
/// once more and deletes the card file. A clip and its XML, or a RAW and its
/// JPEG, pass together or stay together.
///
/// Any mismatch, missing copy or read error skips that item, and the pass
/// goes on. Drive and NAS copies are only read.
public struct CardClearService {
    public static let verifyPhase = "Verify"
    public static let removePhase = "Remove"

    /// The check running this instant, reported as the telemetry step.
    public static let checkingDriveStep = "Checking drive copy"
    public static let checkingNASStep = "Checking NAS copy"
    public static let checkingCardStep = "Checking card file"
    public static let deletingStep = "Deleting from card"
    /// Telemetry counter: files whose checks ran so far.
    public static let checkedCounter = "Checked"

    private struct Identity: Equatable {
        var size: Int64
        var modified: Date?
        var fileNumber: UInt64?
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func clear(
        items: [CardClearItem],
        nasReachable: Bool,
        confirmation: String,
        progress: FileOperationProgressHandler? = nil,
        fileSettled: (@Sendable (CardClearFileResult) -> Void)? = nil
    ) throws -> CardClearReport {
        guard confirmation == FreeUpService.confirmationToken else {
            throw ToolkitError.confirmationRequired(expected: FreeUpService.confirmationToken, received: confirmation)
        }
        var report = CardClearReport()
        report.usedRecordedNASHashes = !nasReachable
        report.checks.nasReread = nasReachable
        let totalFiles = items.reduce(0) { $0 + $1.files.count }
        let readsPerFile: Int64 = nasReachable ? 3 : 2
        let verifyBytes = items.reduce(Int64(0)) { $0 + $1.byteCount } * readsPerFile
        var settledFiles = 0
        var verifyRead: Int64 = 0
        let verifyStarted = Date()

        func settle(_ file: CardClearFile, phase: String, reason: String?) {
            settledFiles += 1
            if let reason {
                report.skipped[file.sourcePath] = reason
            } else {
                report.cleared.append(file.sourcePath)
                report.clearedBytes += file.byteCount
            }
            report.checks.cleared = report.cleared.count
            report.checks.skipped = report.skipped.count
            fileSettled?(CardClearFileResult(
                sourcePath: file.sourcePath,
                relativePath: file.relativePath,
                byteCount: file.byteCount,
                phase: phase,
                removed: reason == nil,
                reason: reason
            ))
        }
        func telemetry(_ phase: String, step: String, read: Int64? = nil) -> JobTelemetry {
            JobTelemetry(
                step: step,
                counters: [
                    JobCounter(label: Self.checkedCounter, value: report.checks.checked),
                    JobCounter(label: "Cleared", value: report.cleared.count),
                    JobCounter(label: "Skipped", value: report.skipped.count),
                ],
                phases: report.phases + [JobPhaseTotal(
                    label: phase,
                    seconds: Date().timeIntervalSince(phase == Self.verifyPhase ? verifyStarted : removeStarted),
                    bytes: read ?? (phase == Self.verifyPhase ? verifyRead : removedSoFar)
                )]
            )
        }
        var removeStarted = Date()
        var removedSoFar: Int64 = 0

        // Verify.
        var verified: [(item: CardClearItem, identities: [String: Identity])] = []
        for item in items {
            guard !item.files.isEmpty, !item.files.contains(where: { CameraSupportFiles.isCameraGenerated($0.sourcePath) }) else {
                item.files.forEach { settle($0, phase: Self.verifyPhase, reason: "Not a photo or clip.") }
                continue
            }
            var identities: [String: Identity] = [:]
            var failure: String?
            for file in item.files {
                // Reports only: each check announces itself before it
                // reads, with the bytes read so far.
                let stage: (String, Int64) -> Void = { step, read in
                    progress?(FileOperationProgress(
                        phase: Self.verifyPhase,
                        currentPath: (file.sourcePath as NSString).lastPathComponent,
                        processedFiles: settledFiles,
                        totalFiles: totalFiles,
                        processedBytes: read,
                        totalBytes: verifyBytes,
                        telemetry: telemetry(Self.verifyPhase, step: step, read: read)
                    ))
                }
                var checks = report.checks
                let reason = verify(file, nasReachable: nasReachable, identities: &identities, read: &verifyRead, checks: &checks, stage: stage)
                checks.checked += 1
                report.checks = checks
                if let reason {
                    failure = "\((file.sourcePath as NSString).lastPathComponent): \(reason)"
                    break
                }
            }
            if let failure {
                item.files.forEach { settle($0, phase: Self.verifyPhase, reason: failure) }
            } else {
                verified.append((item, identities))
            }
        }
        report.phases.append(JobPhaseTotal(label: Self.verifyPhase, seconds: Date().timeIntervalSince(verifyStarted), bytes: verifyRead))

        // Remove.
        removeStarted = Date()
        for (item, identities) in verified {
            progress?(FileOperationProgress(
                phase: Self.removePhase,
                currentPath: item.files.first.map { ($0.sourcePath as NSString).lastPathComponent },
                processedFiles: settledFiles,
                totalFiles: totalFiles,
                telemetry: telemetry(Self.removePhase, step: Self.deletingStep)
            ))
            let unchanged = item.files.allSatisfy { file in
                (try? identity(file.sourcePath)) == identities[file.sourcePath]
                    && (try? identity(file.drivePath)) == identities[file.drivePath]
            }
            guard unchanged else {
                item.files.forEach { settle($0, phase: Self.removePhase, reason: "The card file or drive copy changed after it was verified.") }
                continue
            }
            do {
                let cleanup = try SourceCleanupService(fileManager: fileManager).removeVerifiedFiles(
                    sourceRoot: URL(fileURLWithPath: item.sourceRoot, isDirectory: true),
                    bufferRoot: URL(fileURLWithPath: item.driveRoot, isDirectory: true),
                    files: item.files.map { FileRecord(path: $0.relativePath, size: $0.byteCount, modifiedAt: $0.modifiedAt) },
                    confirmation: SourceCleanupService.confirmationToken
                )
                let removed = Set(cleanup.removed)
                for file in item.files {
                    if removed.contains(file.relativePath) {
                        removedSoFar += file.byteCount
                        settle(file, phase: Self.removePhase, reason: nil)
                    } else {
                        settle(file, phase: Self.removePhase, reason: Self.reason(for: file.relativePath, in: cleanup))
                    }
                }
            } catch {
                item.files.forEach { settle($0, phase: Self.removePhase, reason: "Could not be checked: \(error.localizedDescription)") }
            }
        }
        report.phases.append(JobPhaseTotal(label: Self.removePhase, seconds: Date().timeIntervalSince(removeStarted), bytes: removedSoFar))
        progress?(FileOperationProgress(
            phase: Self.removePhase,
            processedFiles: settledFiles,
            totalFiles: totalFiles,
            telemetry: JobTelemetry(
                step: Self.deletingStep,
                counters: [
                    JobCounter(label: Self.checkedCounter, value: report.checks.checked),
                    JobCounter(label: "Cleared", value: report.cleared.count),
                    JobCounter(label: "Skipped", value: report.skipped.count),
                ],
                phases: report.phases
            )
        ))
        report.cleared.sort()
        return report
    }

    /// Nil when the card file, its drive copy and (when reachable) its NAS
    /// copy all hash to exactly what Sync to NAS verified; otherwise why not.
    /// `checks` counts each check as it passes and `stage` names each one
    /// before it reads — reporting only, neither changes what is checked.
    private func verify(
        _ file: CardClearFile,
        nasReachable: Bool,
        identities: inout [String: Identity],
        read: inout Int64,
        checks: inout CardClearChecks,
        stage: (String, Int64) -> Void
    ) -> String? {
        guard fileManager.fileExists(atPath: file.sourcePath) else { return "The card file is gone." }
        guard fileManager.fileExists(atPath: file.drivePath) else { return "The drive copy is missing." }
        do {
            let cardBefore = try identity(file.sourcePath)
            let driveBefore = try identity(file.drivePath)
            guard cardBefore.size == file.byteCount else { return "The card file's size changed." }
            guard driveBefore.size == file.byteCount else { return "The drive copy's size changed." }
            stage(Self.checkingDriveStep, read)
            let driveHash = try FileScanner.sha256(URL(fileURLWithPath: file.drivePath)).lowercased()
            read += file.byteCount
            guard driveHash == file.verifiedSHA256.lowercased() else {
                return "The drive copy no longer matches the copy Sync to NAS verified."
            }
            checks.driveMatched += 1
            if nasReachable {
                guard fileManager.fileExists(atPath: file.nasPath) else { return "The NAS copy is missing." }
                stage(Self.checkingNASStep, read)
                let nasHash = try FileScanner.sha256(URL(fileURLWithPath: file.nasPath)).lowercased()
                read += file.byteCount
                guard nasHash == driveHash else { return "The NAS copy differs from the drive copy." }
                checks.nasMatched += 1
            }
            stage(Self.checkingCardStep, read)
            let cardHash = try FileScanner.sha256(URL(fileURLWithPath: file.sourcePath)).lowercased()
            read += file.byteCount
            guard cardHash == driveHash else { return "The card file differs from its drive copy." }
            checks.cardMatched += 1
            guard try identity(file.sourcePath) == cardBefore, try identity(file.drivePath) == driveBefore else {
                return "The card file or drive copy changed during the check."
            }
            identities[file.sourcePath] = cardBefore
            identities[file.drivePath] = driveBefore
            return nil
        } catch {
            return "Could not be read: \(error.localizedDescription)"
        }
    }

    private static func reason(for relativePath: String, in cleanup: SourceCleanupReport) -> String {
        if cleanup.differ.contains(relativePath) { return "The card file differs from its drive copy." }
        if cleanup.missingBuffer.contains(relativePath) { return "The drive copy is missing." }
        if cleanup.missingSource.contains(relativePath) { return "The card file is gone." }
        if let error = cleanup.errors[relativePath] { return error }
        if !cleanup.removed.isEmpty { return "Its other files were cleared, then the card refused this one." }
        return "Another file of the same item did not match, so both stay."
    }

    private func identity(_ path: String) throws -> Identity {
        let attributes = try fileManager.attributesOfItem(atPath: path)
        return Identity(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: attributes[.modificationDate] as? Date,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}
