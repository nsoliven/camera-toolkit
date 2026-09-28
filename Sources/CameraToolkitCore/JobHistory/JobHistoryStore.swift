import Foundation
import GRDB

/// `job-history.sqlite`: every job the app ran, its per-second speed
/// samples, and (for Sync to NAS) one row per file — what the Jobs
/// window's History reads.
///
/// A database of its own beside the catalog, not tables inside it: a long
/// sync writes a sample a second and a row per file, and none of that
/// belongs in the catalog's backups. It shares the catalog's connection
/// setup (`CatalogDatabase`: WAL on a local volume, one writer per file,
/// checkpointed at quit).
///
/// History is never allowed to break a job: `shared(at:)` answers nil when
/// the file cannot be opened, and `JobHistoryRecorder` logs a failed write
/// and carries on.
///
/// Opening a store is what "launch" means for it: the schema is migrated,
/// any job still marked `running` (the app quit or crashed under it) is
/// marked `interrupted`, and samples older than `sampleRetention` are
/// pruned. Jobs and their file rows are kept.
public final class JobHistoryStore: @unchecked Sendable {
    public static let fileName = "job-history.sqlite"
    /// Per-second samples are dropped for jobs that started longer ago
    /// than this; the job row and its file rows stay.
    public static let sampleRetention: TimeInterval = 180 * 24 * 3600

    public let url: URL

    /// Opens (creating when missing) and migrates the store, then marks
    /// running jobs interrupted and prunes old samples.
    public init(url: URL, now: Date = Date()) throws {
        self.url = url
        try Self.migrator.migrate(writer())
        try markInterrupted()
        try pruneSamples(before: now.addingTimeInterval(-Self.sampleRetention))
    }

    /// The shared connection, looked up per call like the catalog's stores,
    /// so a file replaced underneath is reopened rather than written blind.
    private func writer() throws -> any DatabaseWriter {
        try CatalogDatabase.writer(for: url)
    }

    /// `job-history.sqlite` in the folder that holds the catalog.
    public static func defaultURL(catalogURL: URL) -> URL {
        catalogURL.deletingLastPathComponent().appendingPathComponent(fileName, isDirectory: false)
    }

    nonisolated(unsafe) private static var opened: [String: JobHistoryStore] = [:]
    private static let openLock = NSLock()

    /// The process's one store for `url`, opened — and so cleaned up — the
    /// first time it is asked for. Nil, logged, when it cannot be opened;
    /// the next call tries again.
    public static func shared(at url: URL) -> JobHistoryStore? {
        let path = url.standardizedFileURL.path
        return openLock.withLock {
            if let store = opened[path] { return store }
            do {
                let store = try JobHistoryStore(url: url)
                opened[path] = store
                return store
            } catch {
                DebugLog.shared.log("history.open", subsystem: .history, level: .error, outcome: .error, error: error.localizedDescription)
                return nil
            }
        }
    }

    // MARK: Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE jobs (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                outcome TEXT NOT NULL CHECK(outcome IN ('running', 'succeeded', 'failed', 'cancelled', 'interrupted')),
                total_files INTEGER NOT NULL DEFAULT 0,
                total_bytes INTEGER NOT NULL DEFAULT 0,
                bytes_done INTEGER NOT NULL DEFAULT 0,
                transfer_bytes INTEGER,
                copied INTEGER NOT NULL DEFAULT 0,
                matched_existing INTEGER NOT NULL DEFAULT 0,
                already_verified INTEGER NOT NULL DEFAULT 0,
                conflicts INTEGER NOT NULL DEFAULT 0,
                failed INTEGER NOT NULL DEFAULT 0,
                config TEXT,
                summary TEXT
            );
            CREATE INDEX jobs_started_at ON jobs(started_at);
            CREATE INDEX jobs_outcome ON jobs(outcome);

            -- One row a second while a job runs. `t` is seconds since the
            -- job started; rates are decimal MB/s.
            CREATE TABLE job_samples (
                job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
                t REAL NOT NULL,
                combined_mbps REAL,
                copy_mbps REAL,
                verify_mbps REAL,
                hash_mbps REAL,
                remote_verify_mbps REAL,
                files_per_second REAL,
                active_transfers INTEGER NOT NULL DEFAULT 0,
                cpu REAL,
                gpu REAL,
                transfer_bytes INTEGER,
                done_bytes INTEGER NOT NULL DEFAULT 0,
                done_files INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX job_samples_job_id ON job_samples(job_id, t);

            -- One row per file when it settles. `started_at`/`ended_at`
            -- are seconds since the job started, like `job_samples.t`.
            CREATE TABLE job_items (
                job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
                relative_path TEXT NOT NULL,
                file_name TEXT NOT NULL,
                byte_count INTEGER NOT NULL,
                started_at REAL,
                ended_at REAL NOT NULL,
                slot INTEGER,
                outcome TEXT NOT NULL CHECK(outcome IN ('copied', 'matched', 'alreadyVerified', 'conflict', 'failed')),
                verify_method TEXT,
                copy_seconds REAL,
                verify_seconds REAL,
                avg_mbps REAL,
                error TEXT
            );
            CREATE INDEX job_items_job_id ON job_items(job_id, started_at);
            """)
        }
        migrator.registerMigration("v2-estimates") { db in
            try db.execute(sql: "ALTER TABLE job_samples ADD COLUMN seconds_remaining REAL")
        }
        return migrator
    }

    // MARK: Writes

    /// Adds a job, or rewrites the row of the same id.
    public func insert(_ job: JobHistoryJob) throws {
        try writer().write { db in
            try Self.upsert(job, in: db)
        }
    }

    /// An upsert, never `INSERT OR REPLACE`: a replace deletes the row
    /// first, and the delete would cascade to the job's samples and files.
    private static func upsert(_ job: JobHistoryJob, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO jobs(
                id, kind, title, started_at, ended_at, outcome, total_files, total_bytes, bytes_done,
                transfer_bytes, copied, matched_existing, already_verified, conflicts, failed, config, summary
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind, title = excluded.title, started_at = excluded.started_at,
                ended_at = excluded.ended_at, outcome = excluded.outcome, total_files = excluded.total_files,
                total_bytes = excluded.total_bytes, bytes_done = excluded.bytes_done,
                transfer_bytes = excluded.transfer_bytes, copied = excluded.copied,
                matched_existing = excluded.matched_existing, already_verified = excluded.already_verified,
                conflicts = excluded.conflicts, failed = excluded.failed, config = excluded.config,
                summary = excluded.summary
            """,
            arguments: arguments(job)
        )
    }

    /// Rewrites a job's row, then appends `samples` and `items` — all in
    /// one transaction, so a batch lands whole or not at all.
    public func write(job: JobHistoryJob?, samples: [JobHistorySample], items: [JobHistoryItem], jobID: UUID) throws {
        guard job != nil || !samples.isEmpty || !items.isEmpty else { return }
        let id = jobID.uuidString
        try writer().write { db in
            if let job {
                try Self.upsert(job, in: db)
            }
            let sampleStatement = try db.cachedStatement(sql: """
            INSERT INTO job_samples(
                job_id, t, combined_mbps, copy_mbps, verify_mbps, hash_mbps, remote_verify_mbps, files_per_second,
                active_transfers, cpu, gpu, transfer_bytes, done_bytes, done_files, seconds_remaining
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
            for sample in samples {
                try sampleStatement.execute(arguments: [
                    id, sample.t, sample.combined, sample.copy, sample.verify, sample.hash, sample.remoteVerify,
                    sample.filesPerSecond, sample.activeTransfers, sample.cpu, sample.gpu, sample.transferBytes,
                    sample.doneBytes, sample.doneFiles, sample.secondsRemaining,
                ])
            }
            let itemStatement = try db.cachedStatement(sql: """
            INSERT INTO job_items(
                job_id, relative_path, file_name, byte_count, started_at, ended_at, slot, outcome, verify_method,
                copy_seconds, verify_seconds, avg_mbps, error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
            for item in items {
                try itemStatement.execute(arguments: [
                    id, item.relativePath, item.fileName, item.byteCount, item.start, item.end, item.slot,
                    item.outcome.rawValue, item.verifyMethod, item.copySeconds, item.verifySeconds,
                    item.averageMegabytesPerSecond, item.error,
                ])
            }
        }
    }

    /// Jobs still marked running belong to a run of the app that is gone:
    /// they become `interrupted`, ending at their last recorded second.
    @discardableResult
    public func markInterrupted() throws -> Int {
        try writer().write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, started_at FROM jobs WHERE outcome = 'running'")
            for row in rows {
                let id: String = row["id"]
                let started = Self.parse(row["started_at"]) ?? Date()
                let lastSample = try Double.fetchOne(db, sql: "SELECT MAX(t) FROM job_samples WHERE job_id = ?", arguments: [id]) ?? 0
                let lastItem = try Double.fetchOne(db, sql: "SELECT MAX(ended_at) FROM job_items WHERE job_id = ?", arguments: [id]) ?? 0
                try db.execute(
                    sql: "UPDATE jobs SET outcome = 'interrupted', ended_at = COALESCE(ended_at, ?) WHERE id = ?",
                    arguments: [Self.timestamp(started.addingTimeInterval(max(lastSample, lastItem))), id]
                )
            }
            return rows.count
        }
    }

    /// Drops the samples of jobs that started before `cutoff`.
    @discardableResult
    public func pruneSamples(before cutoff: Date) throws -> Int {
        try writer().write { db in
            try db.execute(
                sql: "DELETE FROM job_samples WHERE job_id IN (SELECT id FROM jobs WHERE started_at < ?)",
                arguments: [Self.timestamp(cutoff)]
            )
            return db.changesCount
        }
    }

    // MARK: Reads

    /// Newest first.
    public func jobs(limit: Int = 500) throws -> [JobHistoryJob] {
        try writer().read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM jobs ORDER BY started_at DESC LIMIT ?", arguments: [limit]).map(Self.job)
        }
    }

    public func job(id: UUID) throws -> JobHistoryJob? {
        try writer().read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id.uuidString]).map(Self.job)
        }
    }

    /// In time order.
    public func samples(jobID: UUID) throws -> [JobHistorySample] {
        try writer().read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM job_samples WHERE job_id = ? ORDER BY t", arguments: [jobID.uuidString]).map { row in
                JobHistorySample(
                    t: row["t"],
                    combined: row["combined_mbps"],
                    copy: row["copy_mbps"],
                    verify: row["verify_mbps"],
                    hash: row["hash_mbps"],
                    remoteVerify: row["remote_verify_mbps"],
                    filesPerSecond: row["files_per_second"],
                    activeTransfers: row["active_transfers"],
                    cpu: row["cpu"],
                    gpu: row["gpu"],
                    transferBytes: row["transfer_bytes"],
                    doneBytes: row["done_bytes"],
                    doneFiles: row["done_files"],
                    secondsRemaining: row["seconds_remaining"]
                )
            }
        }
    }

    /// In the order they settled.
    public func items(jobID: UUID) throws -> [JobHistoryItem] {
        try writer().read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM job_items WHERE job_id = ? ORDER BY rowid", arguments: [jobID.uuidString]).map { row in
                let outcome: String = row["outcome"]
                return JobHistoryItem(
                    relativePath: row["relative_path"],
                    fileName: row["file_name"],
                    byteCount: row["byte_count"],
                    start: row["started_at"],
                    end: row["ended_at"],
                    slot: row["slot"],
                    outcome: JobHistoryItemOutcome(rawValue: outcome) ?? .failed,
                    verifyMethod: row["verify_method"],
                    copySeconds: row["copy_seconds"],
                    verifySeconds: row["verify_seconds"],
                    averageMegabytesPerSecond: row["avg_mbps"],
                    error: row["error"]
                )
            }
        }
    }

    // MARK: Rows

    private static func arguments(_ job: JobHistoryJob) -> StatementArguments {
        let summary = job.summary.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        return [
            job.id.uuidString, job.kind, job.title, timestamp(job.startedAt), job.endedAt.map(timestamp),
            job.outcome.rawValue, job.totalFiles, job.totalBytes, job.bytesDone, job.transferBytes, job.copied,
            job.matchedExisting, job.alreadyVerified, job.conflicts, job.failed, job.configuration, summary,
        ]
    }

    private static func job(_ row: Row) -> JobHistoryJob {
        let id: String = row["id"]
        let started: String = row["started_at"]
        let ended: String? = row["ended_at"]
        let outcome: String = row["outcome"]
        let summary: String? = row["summary"]
        return JobHistoryJob(
            id: UUID(uuidString: id) ?? UUID(),
            kind: row["kind"],
            title: row["title"],
            startedAt: parse(started) ?? .distantPast,
            endedAt: ended.flatMap(parse),
            outcome: JobHistoryOutcome(rawValue: outcome) ?? .interrupted,
            totalFiles: row["total_files"],
            totalBytes: row["total_bytes"],
            bytesDone: row["bytes_done"],
            transferBytes: row["transfer_bytes"],
            copied: row["copied"],
            matchedExisting: row["matched_existing"],
            alreadyVerified: row["already_verified"],
            conflicts: row["conflicts"],
            failed: row["failed"],
            configuration: row["config"],
            summary: summary.flatMap { try? JSONDecoder().decode(JobHistorySummary.self, from: Data($0.utf8)) }
        )
    }

    static func timestamp(_ date: Date) -> String {
        NASSyncStore.timestamp(date)
    }

    static func parse(_ text: String?) -> Date? {
        text.flatMap(NASSyncStore.parse)
    }
}
