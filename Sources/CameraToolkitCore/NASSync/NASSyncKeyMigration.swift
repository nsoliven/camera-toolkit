import Foundation
import GRDB

/// What re-keying the NAS sync records did.
public struct NASSyncKeyMigrationReport: Equatable, Sendable {
    public var rowsBefore = 0
    /// Rows whose key was another spelling of the same path and now holds
    /// the current one.
    public var rowsRekeyed = 0
    /// Rows dropped because two spellings of one path both had a record;
    /// the verified, then the newer, record was kept.
    public var rowsMerged = 0
    public var rowsAfter = 0
    public var backupID: String?
}

/// Sync records used to be keyed by `relativePath.lowercased()`. The drive
/// listing spells "é" as e plus an accent while the app's event names spell
/// it as one character, and SQLite compares bytes — so an accented event's
/// records were invisible to presence, Take Off Drive, folder renames and
/// merges. `NASSyncStore.pathKey` now also composes the path (NFC); this
/// moves the records already stored under the old spelling.
///
/// Only rows with a non-ASCII path can change, and most catalogs have none:
/// then nothing is read past one query and nothing is written. Otherwise,
/// following the catalog rules of this repository:
///
/// 1. a verified, pinned backup through `backups`;
/// 2. a candidate copy of the catalog (SQLite's backup API), re-keyed and
///    checked on its own: `integrity_check` is `ok`, no new foreign-key
///    violation, and the row count is exactly the old count minus the rows
///    merged;
/// 3. only then the same change in one transaction on the live catalog,
///    checked again before it commits (any mismatch rolls it back).
///
/// The candidate is a reproducible artifact and is removed afterwards.
public enum NASSyncKeyMigration {
    struct Row: Equatable {
        var rowID: Int64
        var nasRoot: String
        var pathKey: String
        var relativePath: String
        var state: String
        var checkedAt: String
    }

    /// The change the rows call for.
    struct Plan {
        /// Rows to delete: the losers of a merge.
        var delete: [Int64] = []
        /// Rows whose key changes: rowid → the key it takes.
        var rekey: [(rowID: Int64, key: String)] = []
        var rowsBefore = 0

        var isEmpty: Bool { delete.isEmpty && rekey.isEmpty }
        var expectedRows: Int { rowsBefore - delete.count }
    }

    /// Swift compares strings by canonical equivalence (composed equals
    /// decomposed), which is exactly what SQLite does not: keys are equal
    /// here only when their bytes are.
    static func sameBytes(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    /// Rows that can need a new key: any with a non-ASCII path. The
    /// characters outside space…tilde are matched by GLOB.
    static let nonASCII = "relative_path GLOB '*[^ -~]*' OR path_key GLOB '*[^ -~]*'"

    static func candidateRows(_ database: Database) throws -> [Row] {
        guard try database.tableExists(NASSyncStore.tableName) else { return [] }
        return try GRDB.Row.fetchAll(
            database,
            sql: "SELECT rowid, nas_root, path_key, relative_path, state, checked_at FROM \(NASSyncStore.tableName) WHERE \(nonASCII)"
        ).map {
            Row(rowID: $0[0], nasRoot: $0[1], pathKey: $0[2], relativePath: $0[3], state: $0[4], checkedAt: $0[5])
        }
    }

    /// Groups rows by root and current key; a group with more than one
    /// row, or a row whose key changes, is work. Rows that are already
    /// at the new key but not candidates (ASCII-only paths) cannot
    /// collide with a non-ASCII key, so only candidates are read.
    static func plan(_ candidates: [Row], totalRows: Int) -> Plan {
        var plan = Plan()
        plan.rowsBefore = totalRows
        var groups: [String: [Row]] = [:]
        for row in candidates {
            groups[row.nasRoot + "\u{0}" + NASSyncStore.pathKey(row.relativePath), default: []].append(row)
        }
        for key in groups.keys.sorted() {
            let rows = groups[key] ?? []
            let newKey = NASSyncStore.pathKey(rows[0].relativePath)
            // The verified record, then the most recently checked, wins.
            let ranked = rows.sorted {
                ($0.state == "verified" ? 0 : 1, $1.checkedAt, $0.rowID) < ($1.state == "verified" ? 0 : 1, $0.checkedAt, $1.rowID)
            }
            guard let winner = ranked.first else { continue }
            plan.delete += ranked.dropFirst().map(\.rowID)
            if !sameBytes(winner.pathKey, newKey) { plan.rekey.append((winner.rowID, newKey)) }
        }
        return plan
    }

    static func apply(_ plan: Plan, to database: Database) throws {
        for rowID in plan.delete {
            try database.execute(sql: "DELETE FROM \(NASSyncStore.tableName) WHERE rowid = ?", arguments: [rowID])
        }
        for change in plan.rekey {
            try database.execute(sql: "UPDATE \(NASSyncStore.tableName) SET path_key = ? WHERE rowid = ?", arguments: [change.key, change.rowID])
        }
    }

    static func validate(_ plan: Plan, database: Database, foreignKeyViolationsBefore: Set<String>) throws {
        let rows = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(NASSyncStore.tableName)") ?? -1
        guard rows == plan.expectedRows else {
            throw ToolkitError.commandFailed("NAS sync record migration check failed: \(rows) records after, \(plan.expectedRows) expected.")
        }
        let stale = try candidateRows(database).filter { !sameBytes($0.pathKey, NASSyncStore.pathKey($0.relativePath)) }
        guard stale.isEmpty else {
            throw ToolkitError.commandFailed("NAS sync record migration check failed: \(stale.count) records are still under the old key.")
        }
        let integrity = try String.fetchAll(database, sql: "PRAGMA integrity_check").joined(separator: "; ")
        guard integrity == "ok" else {
            throw ToolkitError.commandFailed("NAS sync record migration check failed: integrity_check reported \(integrity).")
        }
        let introduced = try CatalogStateStore.foreignKeyViolations(database).filter { !foreignKeyViolationsBefore.contains($0) }
        guard introduced.isEmpty else {
            throw ToolkitError.commandFailed("NAS sync record migration check failed: new foreign-key violations \(introduced.joined(separator: ", ")).")
        }
    }

    /// True when some record is under another spelling than its path's
    /// current key. One query; nothing is written.
    public static func needsMigration(catalogURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: catalogURL.path),
              let writer = try? CatalogDatabase.writer(for: catalogURL) else { return false }
        let stale = try? writer.read { database in
            try candidateRows(database).contains { !sameBytes($0.pathKey, NASSyncStore.pathKey($0.relativePath)) }
        }
        return stale == true
    }

    /// Re-keys the records, or returns nil when none needs it.
    /// `workFolder` holds the candidate catalog while it is checked.
    @discardableResult
    public static func migrateIfNeeded(
        catalogURL: URL,
        backups: CatalogBackupService,
        workFolder: URL = FileManager.default.temporaryDirectory
    ) throws -> NASSyncKeyMigrationReport? {
        guard needsMigration(catalogURL: catalogURL) else { return nil }
        let writer = try CatalogDatabase.writer(for: catalogURL)

        // 1. Backup before anything is decided or changed.
        let backup = try backups.backupNow(reason: .migration, pinned: true, mirrorToRemote: false)

        // 2. The candidate: a consistent copy, changed and checked alone.
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let candidateURL = workFolder.appendingPathComponent("nas-sync-keys-candidate-\(UUID().uuidString.prefix(8)).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: candidateURL.path + suffix)
            }
        }
        _ = try CatalogBackupService.snapshot(from: catalogURL, to: candidateURL)
        let candidate = try DatabaseQueue(path: candidateURL.path)
        let candidatePlan = try candidate.write { database -> Plan in
            let before = Set(try CatalogStateStore.foreignKeyViolations(database))
            let total = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(NASSyncStore.tableName)") ?? 0
            let plan = plan(try candidateRows(database), totalRows: total)
            try apply(plan, to: database)
            try validate(plan, database: database, foreignKeyViolationsBefore: before)
            return plan
        }
        try candidate.close()

        // 3. The live catalog, in one transaction that checks itself.
        let live = try CatalogTransactionRetry.run {
            try writer.write { database -> Plan in
                let before = Set(try CatalogStateStore.foreignKeyViolations(database))
                let total = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(NASSyncStore.tableName)") ?? 0
                let plan = plan(try candidateRows(database), totalRows: total)
                try apply(plan, to: database)
                try validate(plan, database: database, foreignKeyViolationsBefore: before)
                return plan
            }
        }
        var report = NASSyncKeyMigrationReport()
        report.rowsBefore = live.rowsBefore
        report.rowsRekeyed = live.rekey.count
        report.rowsMerged = live.delete.count
        report.rowsAfter = live.expectedRows
        report.backupID = backup.manifest.id
        // The candidate and the live catalog agreed on what the change was
        // whenever the catalog was quiet; a difference only means records
        // were written between the two, and the live checks above decide.
        _ = candidatePlan
        return report
    }
}
