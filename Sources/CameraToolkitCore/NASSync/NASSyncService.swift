import Darwin
import Foundation

public struct NASSyncReport: Codable, Equatable, Sendable {
    /// Copied to the NAS and verified by re-reading the NAS copy.
    public var copied: [String] = []
    /// Already on the NAS at the same path with the same SHA-256; now
    /// recorded as verified.
    public var matchedExisting: [String] = []
    /// Verified by an earlier sync at the same size and drive modification
    /// time, and still on the NAS at that size; not re-read.
    public var alreadyVerified: [String] = []
    /// A different file sits at the NAS path. Never overwritten.
    public var conflicts: [NASSyncIssue] = []
    /// Could not be read, written, or verified; reported and skipped.
    public var failed: [NASSyncIssue] = []
    /// Not attempted because the NAS went away or the job was stopped.
    public var notAttempted: Int = 0
    public var stoppedReason: String?
    public var bytesCopied: Int64 = 0
    public var foldersCreated: Int = 0

    public var verifiedCount: Int { copied.count + matchedExisting.count + alreadyVerified.count }
    public var succeeded: Bool { conflicts.isEmpty && failed.isEmpty && notAttempted == 0 && stoppedReason == nil }
}

/// One-way Buffer → NAS copy of the files a `NASSyncPlan` lists, each to the
/// same relative path under the NAS mirror root.
///
/// Per file:
/// - verified before at the same size and drive mtime, and the NAS copy
///   still that size → skipped (a resumed sync does not re-read it);
/// - a file already at the NAS path → both hashed (the NAS copy with
///   `F_NOCACHE`); equal is recorded verified, different is a conflict and
///   is never overwritten;
/// - otherwise streamed into a temporary `.<name>.ctsync-<id>` in the
///   destination folder (created exclusively), flushed, re-read from the
///   NAS and hashed; only an exact SHA-256 match is renamed into place —
///   exclusively, never over a file. A temporary that fails verification is
///   removed (it is this sync's own partial file, never presented as
///   complete).
///
/// A file that fails is recorded and skipped; the job goes on. It stops
/// early only when the NAS itself disappears, and says how many files were
/// not attempted.
public struct NASSyncService {
    public typealias Progress = @Sendable (FileOperationProgress) -> Void

    private let store: NASSyncStore?
    private let now: () -> Date
    private let clock: () -> TimeInterval
    private let isCancelled: () -> Bool

    public init(
        store: NASSyncStore?,
        now: @escaping () -> Date = { Date() },
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) {
        self.store = store
        self.now = now
        self.clock = clock
        self.isCancelled = isCancelled
    }

    public func sync(_ plan: NASSyncPlan, nasRoot: URL, progress: Progress? = nil) throws -> NASSyncReport {
        let root = nasRoot.standardizedFileURL.path
        guard LayoutMigrationDisk.lstatEntry(root)?.kind == .directory else {
            throw ToolkitError.commandFailed("The NAS folder \(root) is not connected. Nothing was copied.")
        }
        let known = try store?.records(nasRoot: root) ?? [:]
        var report = NASSyncReport()
        var pending: [NASSyncRecord] = []
        func flush(force: Bool = false) {
            guard force || pending.count >= 64 else { return }
            do {
                try store?.upsert(pending)
                pending.removeAll(keepingCapacity: true)
            } catch {
                // The files themselves are proven on the NAS; a later sync
                // re-derives any state that did not land.
                report.stoppedReason = report.stoppedReason ?? "Could not record sync state in the catalog: \(error.localizedDescription)"
            }
        }

        // Work in bytes: a copy reads the drive copy and re-reads the NAS
        // copy; a match hashes both. Skips take their bytes off the total.
        var totalWork = plan.items.reduce(Int64(0)) { $0 + 2 * $1.byteCount }
        var doneWork: Int64 = 0
        var estimator = ScanRateEstimator()
        estimator.start(at: clock())
        var limiter = FileOperationProgressLimiter()
        var folderListings: [String: [String: DirectoryListingEntry]] = [:]
        var createdFolders = Set<String>()
        // Where the time goes, per file: listing and metadata ("Check"),
        // streaming the copy, flushing it to the share, re-reading it from
        // the NAS, hashing a drive copy that is already there, renaming it
        // into place. One clock read per phase change.
        var phases = JobPhaseTimer(order: ["Check", "Copy", "Flush", "Verify", "Hash", "Rename"])
        func phase(_ label: String) { phases.begin(label, at: clock()) }
        func moved(_ count: Int) {
            doneWork += Int64(count)
            phases.addBytes(Int64(count))
        }

        func emit(_ index: Int, _ phase: String, _ path: String, force: Bool = false) {
            guard let progress, limiter.shouldEmit(force: force) else { return }
            let t = clock()
            estimator.record(units: Double(doneWork), at: t)
            let counters = [
                JobCounter(label: "Copied", value: report.copied.count),
                JobCounter(label: "Already on NAS", value: report.matchedExisting.count + report.alreadyVerified.count),
                JobCounter(label: "Conflicts", value: report.conflicts.count),
                JobCounter(label: "Failed", value: report.failed.count),
            ]
            progress(FileOperationProgress(
                phase: phase,
                currentPath: (path as NSString).lastPathComponent,
                processedFiles: index,
                totalFiles: plan.items.count,
                processedBytes: doneWork,
                totalBytes: totalWork,
                bytesPerSecond: 0,
                telemetry: JobTelemetry(
                    step: phase,
                    activeItems: [JobActiveItem(name: (path as NSString).lastPathComponent, path: path, step: phase)],
                    counters: counters,
                    work: JobWorkEstimate(
                        unitsDone: Int(doneWork),
                        unitsTotal: Int(totalWork),
                        secondsRemaining: estimator.secondsRemaining(Double(max(totalWork - doneWork, 0)), at: t)
                    ),
                    phases: phases.snapshot(at: t)
                )
            ))
        }

        func listing(of folder: String) -> [String: DirectoryListingEntry]? {
            if let cached = folderListings[folder] { return cached }
            guard let entries = try? DirectoryListing.list(folder) else { return nil }
            let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            folderListings[folder] = byName
            return byName
        }

        for (index, item) in plan.items.enumerated() {
            if isCancelled() {
                report.notAttempted = plan.items.count - index
                report.stoppedReason = "Stopped before \(item.relativePath)."
                break
            }
            // Relative paths come from the planner, but a stale plan must
            // never escape the root.
            guard EventStorageLocations.isLexicallyClean(item.relativePath),
                  (try? PathSafety.validateRelativePath(item.relativePath)) != nil else {
                report.failed.append(NASSyncIssue(path: item.relativePath, reason: "Unsafe relative path."))
                continue
            }
            let destination = root + "/" + item.relativePath
            let folder = (destination as NSString).deletingLastPathComponent
            let name = (destination as NSString).lastPathComponent
            let record = { (state: NASSyncRecord.State, sha: String?, nasSHA: String?, detail: String?, verified: Bool) in
                pending.append(NASSyncRecord(
                    nasRoot: root,
                    relativePath: item.relativePath,
                    eventID: item.eventID,
                    byteCount: item.byteCount,
                    sourceModifiedAt: item.modifiedAt,
                    sha256: sha,
                    nasSHA256: nasSHA,
                    state: state,
                    detail: detail,
                    checkedAt: now(),
                    verifiedAt: verified ? now() : nil
                ))
                flush()
            }
            phase("Check")
            emit(index, "Checking NAS", item.relativePath)
            // One listing per destination folder answers "is it there, at
            // what size" for every file in it.
            let existing = listing(of: folder)?[name]

            // Resume: verified earlier at this size and drive mtime.
            if let previous = known[NASSyncStore.pathKey(item.relativePath)],
               previous.state == .verified,
               previous.byteCount == item.byteCount,
               previous.sourceModifiedAt.map({ abs($0 - item.modifiedAt) < 0.001 }) == true,
               let existing, existing.kind == .file, existing.size == item.byteCount {
                report.alreadyVerified.append(item.relativePath)
                totalWork -= 2 * item.byteCount
                emit(index + 1, "Already verified", item.relativePath)
                continue
            }

            if let existing {
                guard existing.kind == .file else {
                    report.conflicts.append(NASSyncIssue(path: item.relativePath, reason: "Something that is not a file is at the NAS path."))
                    record(.conflict, nil, nil, "not a file on the NAS", false)
                    totalWork -= 2 * item.byteCount
                    continue
                }
                guard existing.size == item.byteCount else {
                    let reason = "A different file (\(existing.size) bytes, the drive copy is \(item.byteCount)) is already on the NAS. It was not overwritten."
                    report.conflicts.append(NASSyncIssue(path: item.relativePath, reason: reason))
                    record(.conflict, nil, nil, reason, false)
                    totalWork -= 2 * item.byteCount
                    continue
                }
                do {
                    phase("Hash")
                    emit(index, "Hashing drive copy", item.relativePath)
                    let sourceHash = try NASFileIO.sha256(item.sourcePath, uncached: false, expectedByteCount: item.byteCount) { moved($0); emit(index, "Hashing drive copy", item.relativePath) }
                    phase("Verify")
                    emit(index, "Re-reading NAS copy", item.relativePath)
                    let nasHash = try NASFileIO.sha256(destination, uncached: true, expectedByteCount: item.byteCount) { moved($0); emit(index, "Re-reading NAS copy", item.relativePath) }
                    phase("Check")
                    if sourceHash == nasHash {
                        report.matchedExisting.append(item.relativePath)
                        record(.verified, sourceHash, nil, nil, true)
                    } else {
                        let reason = "A different file with the same size is already on the NAS. It was not overwritten."
                        report.conflicts.append(NASSyncIssue(path: item.relativePath, reason: reason))
                        record(.conflict, sourceHash, nasHash, reason, false)
                    }
                } catch {
                    report.failed.append(NASSyncIssue(path: item.relativePath, reason: error.localizedDescription))
                    record(.failed, nil, nil, error.localizedDescription, false)
                    if nasIsGone(root) { stop(&report, remaining: plan.items.count - index - 1); break }
                }
                emit(index + 1, "Checked", item.relativePath, force: true)
                continue
            }

            // Missing on the NAS: copy, verify by re-reading, rename in.
            let temporary = (folder as NSString).appendingPathComponent(".\(name)\(NASSyncPlanner.temporaryMarker)\(UUID().uuidString.prefix(8))")
            var temporaryExists = false
            do {
                for made in try NASFileIO.makeDirectories(folder) where createdFolders.insert(made).inserted {
                    report.foldersCreated += 1
                    folderListings[made] = [:]
                }
                removeStaleTemporaries(for: name, in: folder, listing: listing(of: folder))
                phase("Copy")
                emit(index, "Copying to NAS", item.relativePath)
                temporaryExists = true
                let sourceHash = try NASFileIO.copyNew(
                    from: item.sourcePath,
                    to: temporary,
                    expectedByteCount: item.byteCount,
                    progress: { moved($0); emit(index, "Copying to NAS", item.relativePath) },
                    willFlush: { phase("Flush"); emit(index, "Flushing to NAS", item.relativePath, force: true) }
                )
                phase("Check")
                // The drive copy must be the file the plan saw.
                if let current = LayoutMigrationDisk.lstatEntry(item.sourcePath),
                   current.size != item.byteCount || abs(current.modifiedAt - item.modifiedAt) >= 0.001 {
                    throw ToolkitError.commandFailed("The drive copy changed while it was copied.")
                }
                _ = setModificationTime(temporary, item.modifiedAt)
                phase("Verify")
                emit(index, "Re-reading NAS copy", item.relativePath)
                let nasHash = try NASFileIO.sha256(temporary, uncached: true, expectedByteCount: item.byteCount) { moved($0); emit(index, "Re-reading NAS copy", item.relativePath) }
                guard nasHash == sourceHash else {
                    throw ToolkitError.commandFailed("The NAS copy did not verify: its SHA-256 differs from the drive copy's when re-read from the NAS.")
                }
                phase("Rename")
                do {
                    try NASFileIO.renameExclusive(from: temporary, to: destination)
                    temporaryExists = false
                } catch {
                    // Someone else put a file there meanwhile: compare, never replace.
                    guard LayoutMigrationDisk.lstatEntry(destination) != nil else { throw error }
                    phase("Verify")
                    let other = try NASFileIO.sha256(destination, uncached: true)
                    if other == sourceHash {
                        report.matchedExisting.append(item.relativePath)
                        record(.verified, sourceHash, nil, nil, true)
                    } else {
                        let reason = "A different file appeared at the NAS path during the copy. It was not overwritten."
                        report.conflicts.append(NASSyncIssue(path: item.relativePath, reason: reason))
                        record(.conflict, sourceHash, other, reason, false)
                    }
                    unlink(temporary)
                    temporaryExists = false
                    emit(index + 1, "Checked", item.relativePath, force: true)
                    continue
                }
                guard LayoutMigrationDisk.lstatEntry(destination).map({ $0.kind == .file && $0.size == item.byteCount }) == true else {
                    throw ToolkitError.commandFailed("The NAS copy is not at its final path after the rename.")
                }
                folderListings[folder]?[name] = DirectoryListingEntry(name: name, kind: .file, size: item.byteCount, modifiedAt: item.modifiedAt, fileID: 0)
                report.copied.append(item.relativePath)
                report.bytesCopied += item.byteCount
                record(.verified, sourceHash, nil, nil, true)
            } catch {
                if temporaryExists { unlink(temporary) }
                report.failed.append(NASSyncIssue(path: item.relativePath, reason: error.localizedDescription))
                record(.failed, nil, nil, error.localizedDescription, false)
                if nasIsGone(root) { stop(&report, remaining: plan.items.count - index - 1); break }
            }
            emit(index + 1, "Verified on NAS", item.relativePath, force: true)
        }
        phases.end(at: clock())
        flush(force: true)
        return report
    }

    private func nasIsGone(_ root: String) -> Bool {
        LayoutMigrationDisk.lstatEntry(root)?.kind != .directory || !VolumeInfo.isAvailable(URL(fileURLWithPath: root))
    }

    private func stop(_ report: inout NASSyncReport, remaining: Int) {
        report.notAttempted = remaining
        report.stoppedReason = "The NAS disconnected. Sync again once it is back; verified files are skipped."
    }

    /// A crashed or quit sync can leave its own `.<name>.ctsync-<id>`
    /// temporary behind. Only exactly that pattern, for exactly this file
    /// name, is removed — never anything else.
    private func removeStaleTemporaries(for name: String, in folder: String, listing: [String: DirectoryListingEntry]?) {
        let prefix = ".\(name)\(NASSyncPlanner.temporaryMarker)"
        for entry in (listing ?? [:]).values where entry.kind == .file && entry.name.hasPrefix(prefix)
            && entry.name.count == prefix.count + 8 {
            unlink((folder as NSString).appendingPathComponent(entry.name))
        }
    }

    private func setModificationTime(_ path: String, _ modifiedAt: Double) -> Bool {
        let date = Date(timeIntervalSinceReferenceDate: modifiedAt)
        return (try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)) != nil
    }
}
