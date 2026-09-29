import Foundation

/// What a scrub of the NAS copies found.
public struct NASScrubReport: Equatable, Sendable {
    /// Verified records considered.
    public var checked = 0
    /// Copies whose SHA-256 still equals the one recorded.
    public var verified = 0
    /// No file at the recorded path (moved, renamed or removed since).
    public var missing: [NASSyncIssue] = []
    /// A file of another size than the record: not the file that was verified.
    public var sizeChanged: [NASSyncIssue] = []
    /// Same size, other bytes: the copy has changed since it was verified.
    public var hashMismatches: [NASSyncIssue] = []
    /// Could not be read this time.
    public var unreadable: [NASSyncIssue] = []
    /// Records the scrub stopped trusting (the mismatches and size changes).
    public var recordsDowngraded = 0
    public var notAttempted = 0
    public var stoppedReason: String?
    /// "NAS SHA-256 (<label>)" or "SMB re-read".
    public var method = ""
    public var bytesHashed: Int64 = 0

    public init() {}

    /// Files that no longer match what was verified.
    public var problemCount: Int { hashMismatches.count + sizeChanged.count }
    public var succeeded: Bool { problemCount == 0 && unreadable.isEmpty && notAttempted == 0 && stoppedReason == nil }

    public var summary: String {
        var parts = ["\(verified) of \(checked) NAS cop\(checked == 1 ? "y" : "ies") still match what was verified"]
        if !hashMismatches.isEmpty { parts.append("\(hashMismatches.count) CHANGED since they were verified (same size, other bytes)") }
        if !sizeChanged.isEmpty { parts.append("\(sizeChanged.count) changed size") }
        if !missing.isEmpty { parts.append("\(missing.count) no longer at the recorded path") }
        if !unreadable.isEmpty { parts.append("\(unreadable.count) could not be read") }
        if notAttempted > 0 { parts.append("\(notAttempted) not checked") }
        var text = parts.joined(separator: ", ") + "."
        if problemCount > 0 { text += " Nothing was deleted or replaced; those records are no longer trusted, so Take Off Drive will not rely on them and Sync to NAS reports them." }
        if let stoppedReason { text += " " + stoppedReason }
        return text
    }
}

/// The NAS has shown rare corruption, and a sync record only says what the
/// file was when it was verified. The scrub re-hashes the NAS copies the
/// records call verified — on the NAS itself over SSH when set up (only the
/// answers cross the wire), else by re-reading them over SMB — and compares
/// with the recorded SHA-256.
///
/// It never deletes, moves or rewrites a media file. A copy that no longer
/// matches has its record turned into a `conflict` (so presence stops
/// counting it verified, Take Off Drive refuses it, and the Sync All
/// confirmation lists it as "different"); the file stays exactly as it is
/// for the owner to look at.
public struct NASVerifyScrub {
    public typealias Progress = @Sendable (FileOperationProgress) -> Void

    private let store: NASSyncStore
    private let remoteVerifier: NASRemoteVerifier?
    private let now: @Sendable () -> Date
    private let isCancelled: @Sendable () -> Bool
    private let batchFiles: Int
    private let batchBytes: Int64

    public init(
        store: NASSyncStore,
        remoteVerifier: NASRemoteVerifier? = nil,
        batchFiles: Int = 32,
        batchBytes: Int64 = 512 * 1024 * 1024,
        now: @escaping @Sendable () -> Date = { Date() },
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) {
        self.store = store
        self.remoteVerifier = remoteVerifier
        self.batchFiles = max(1, batchFiles)
        self.batchBytes = max(1, batchBytes)
        self.now = now
        self.isCancelled = isCancelled
    }

    /// Checks every verified record, or only those under `prefixes` (NAS
    /// event folder paths).
    public func run(nasRoot: URL, prefixes: [String]? = nil, progress: Progress? = nil) throws -> NASScrubReport {
        let root = nasRoot.standardizedFileURL.path
        guard LayoutMigrationDisk.lstatEntry(root)?.kind == .directory else {
            throw ToolkitError.commandFailed("The NAS folder \(root) is not connected. Nothing was checked.")
        }
        var report = NASScrubReport()
        report.method = remoteVerifier.map { "NAS SHA-256 (\($0.label))" } ?? "SMB re-read"
        let records = try store.records(nasRoot: root, prefixes: prefixes)
            .values.filter { $0.state == .verified && $0.sha256 != nil }
            .sorted { $0.pathKey < $1.pathKey }
        report.checked = records.count
        var downgrade: [NASSyncRecord] = []
        var done = 0
        var pending: [(record: NASSyncRecord, path: String)] = []
        var pendingBytes: Int64 = 0

        func emit(_ path: String) {
            progress?(FileOperationProgress(
                phase: "Verifying NAS copies",
                currentPath: (path as NSString).lastPathComponent,
                processedFiles: done,
                totalFiles: records.count
            ))
        }

        func settle(_ record: NASSyncRecord, path: String, hash: String?, failure: String?) {
            done += 1
            if let hash {
                report.bytesHashed += record.byteCount
                if hash == record.sha256 {
                    report.verified += 1
                } else {
                    let reason = "The NAS copy's SHA-256 (\(hash)) differs from the one recorded when it was verified (\(record.sha256 ?? "")). It was left untouched."
                    report.hashMismatches.append(NASSyncIssue(path: record.relativePath, reason: reason))
                    var changed = record
                    changed.state = .conflict
                    changed.nasSHA256 = hash
                    changed.detail = reason
                    changed.checkedAt = now()
                    changed.verifiedAt = nil
                    downgrade.append(changed)
                }
            } else {
                report.unreadable.append(NASSyncIssue(path: record.relativePath, reason: failure ?? "Could not be read."))
            }
            emit(path)
        }

        func flush() {
            guard !pending.isEmpty else { return }
            let batch = pending
            pending = []
            pendingBytes = 0
            var hashes: [String: String] = [:]
            if let remoteVerifier, let answered = try? remoteVerifier.hashes(localPaths: batch.map(\.path)) { hashes = answered }
            for entry in batch {
                if isCancelled() { report.notAttempted += 1; continue }
                if let hash = hashes[entry.path] {
                    settle(entry.record, path: entry.path, hash: hash, failure: nil)
                    continue
                }
                // The NAS could not answer for this one: re-read it over SMB.
                do {
                    let hash = try NASFileIO.sha256(entry.path, uncached: true, expectedByteCount: entry.record.byteCount)
                    settle(entry.record, path: entry.path, hash: hash, failure: nil)
                } catch {
                    settle(entry.record, path: entry.path, hash: nil, failure: error.localizedDescription)
                    if nasIsGone(root) {
                        report.stoppedReason = "The NAS disconnected; the rest was not checked."
                    }
                }
            }
        }

        for record in records {
            if isCancelled() || report.stoppedReason != nil {
                report.notAttempted += 1
                continue
            }
            let path = root + "/" + record.relativePath
            guard let entry = LayoutMigrationDisk.lstatEntry(path) else {
                if nasIsGone(root) {
                    report.stoppedReason = "The NAS disconnected; the rest was not checked."
                    report.notAttempted += 1
                    continue
                }
                done += 1
                report.missing.append(NASSyncIssue(path: record.relativePath, reason: "No file at the recorded path."))
                continue
            }
            guard entry.kind == .file, entry.size == record.byteCount else {
                done += 1
                let reason = entry.kind == .file
                    ? "The file is \(entry.size) bytes; the verified copy was \(record.byteCount). It was left untouched."
                    : "Something that is not a file is at the recorded path."
                report.sizeChanged.append(NASSyncIssue(path: record.relativePath, reason: reason))
                var changed = record
                changed.state = .conflict
                changed.detail = reason
                changed.checkedAt = now()
                changed.verifiedAt = nil
                downgrade.append(changed)
                continue
            }
            pending.append((record, path))
            pendingBytes += record.byteCount
            if pending.count >= batchFiles || pendingBytes >= batchBytes { flush() }
        }
        flush()
        if !downgrade.isEmpty {
            do {
                try store.upsert(downgrade)
                report.recordsDowngraded = downgrade.count
            } catch {
                report.stoppedReason = (report.stoppedReason.map { $0 + " " } ?? "") + "Could not update the sync records: \(error.localizedDescription)"
            }
        }
        return report
    }
}
