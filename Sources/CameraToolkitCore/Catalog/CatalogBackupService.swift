import CryptoKit
import Foundation
import GRDB
import SQLite3

/// Why a backup ran. Recorded in each set's manifest.
public enum CatalogBackupReason: String, Codable, Sendable {
    /// The newest backup was older than a day when the app launched.
    case launch
    /// A debounced backup after a write-heavy session (face review, bulk
    /// moves, trash).
    case afterWrites
    /// Settings › Back Up Now or Prepare Photo List.
    case manual
    /// The verified snapshot taken before the events/assignments migration.
    case migration
}

/// One file inside a backup set.
public struct CatalogBackupFile: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case catalog
        case configuration
        case faceLabels
    }

    public var role: Role
    public var name: String
    public var byteCount: Int64
    public var sha256: String
}

/// The manifest written last into every backup set. A set without a
/// manifest is incomplete and never counts as a backup. The manifest is
/// also the proof of ownership: pruning only ever deletes files a manifest
/// written by this service lists.
public struct CatalogBackupManifest: Codable, Equatable, Sendable {
    public static let formatName = "camera-toolkit-catalog-backup"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var id: String
    public var createdAt: Date
    public var reason: CatalogBackupReason
    /// Pinned sets (the pre-migration snapshot) are never pruned.
    public var pinned: Bool
    public var files: [CatalogBackupFile]
    /// Row counts read in the same snapshot the backup copied, and matched
    /// against the backup file before it was accepted.
    public var tableCounts: [String: Int]
    public var integrityCheck: String
    /// `PRAGMA foreign_key_check` rows in the backup. Recorded, not fatal:
    /// catalogs can carry a legacy dangling `import_batches` reference.
    public var foreignKeyViolations: Int
    /// False when `config.json` was backed up but did not decode.
    public var configurationDecodes: Bool?

    public func file(_ role: CatalogBackupFile.Role) -> CatalogBackupFile? {
        files.first { $0.role == role }
    }
}

/// Where a backup set was written, and what happened on the NAS side.
public struct CatalogBackupResult: Equatable, Sendable {
    public enum Remote: Equatable, Sendable {
        case copied(URL)
        /// Already on the NAS (a catch-up found nothing to do).
        case alreadyPresent(URL)
        case notConfigured
        /// The NAS volume is not mounted; a later run catches up.
        case offline
        case failed(String)
    }

    public var manifest: CatalogBackupManifest
    public var localFolder: URL
    public var remote: Remote

    public var catalogURL: URL? {
        manifest.file(.catalog).map { localFolder.appendingPathComponent($0.name) }
    }
}

/// What Settings shows about backups.
public struct CatalogBackupSummary: Equatable, Sendable {
    public var lastLocal: Date?
    public var lastRemote: Date?
    public var remoteReachable: Bool
    public var remoteConfigured: Bool
    public var lastError: String?
    public var lastErrorAt: Date?

    public init(
        lastLocal: Date?,
        lastRemote: Date?,
        remoteReachable: Bool,
        remoteConfigured: Bool,
        lastError: String?,
        lastErrorAt: Date?
    ) {
        self.lastLocal = lastLocal
        self.lastRemote = lastRemote
        self.remoteReachable = remoteReachable
        self.remoteConfigured = remoteConfigured
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
    }

    /// True when the newest verified local backup is older than `maxAge`
    /// (or there is none).
    public func isStale(now: Date = Date(), maxAge: TimeInterval = CatalogBackupService.staleAfter) -> Bool {
        guard let lastLocal else { return true }
        return now.timeIntervalSince(lastLocal) > maxAge
    }
}

/// Verified catalog backups through the SQLite online backup API.
///
/// Each run writes one *set* — the catalog snapshot, the face labels
/// exported from it (`FaceLabelExport`), a copy of `config.json` while it
/// exists, and a manifest — into the local backups
/// folder, verifies it (`integrity_check = ok` and table row counts equal to
/// the source snapshot's), then copies the set to the NAS folder when that
/// volume is mounted and checksum-verifies the copy. A rolling set of
/// `dailyKeep` daily and `weeklyKeep` weekly backups is kept in both
/// places.
///
/// Pruning deletes only files named in a manifest this service wrote, under
/// the service's own `ctbackup-<UTC stamp>` naming. Hand-made files such
/// as `*-before-*` snapshots, or anything else in those folders, are never
/// touched.
public struct CatalogBackupService: Sendable {
    public static let staleAfter: TimeInterval = 24 * 60 * 60
    public static let dailyKeep = 7
    public static let weeklyKeep = 4
    /// Tables whose row counts must match between source and backup.
    public static let verifiedTables = [
        "events", "event_assets", "people", "faces", "face_templates",
        "face_rejections", "face_photos", "storage_locations"
    ]

    public let catalogURL: URL
    public let configurationURL: URL?
    public let localFolder: URL
    public let remoteFolder: URL?
    private let now: @Sendable () -> Date

    /// Serializes backups process-wide: the launch check, a debounced
    /// after-writes run, and a manual click never interleave.
    private static let runLock = NSLock()

    public init(
        catalogURL: URL,
        configurationURL: URL?,
        localFolder: URL,
        remoteFolder: URL?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.catalogURL = catalogURL
        self.configurationURL = configurationURL
        self.localFolder = localFolder
        self.remoteFolder = remoteFolder
        self.now = now
    }

    // MARK: - Running backups

    /// Writes, verifies, and (when the NAS is mounted) mirrors a new set,
    /// then prunes old sets this service made. Throws when the local set
    /// cannot be written or fails verification; the NAS side never throws
    /// and is reported in the result.
    @discardableResult
    ///
    /// `mirrorToRemote: false` writes only the local set; the next launch
    /// check (`backupIfStale` → `catchUpRemote`) copies it to the NAS.
    public func backupNow(
        reason: CatalogBackupReason,
        pinned: Bool = false,
        mirrorToRemote: Bool = true
    ) throws -> CatalogBackupResult {
        Self.runLock.lock()
        defer { Self.runLock.unlock() }
        do {
            let manifest = try writeLocalSet(reason: reason, pinned: pinned)
            let remote = mirrorToRemote ? mirror(manifest) : (remoteFolder == nil ? .notConfigured : .offline)
            prune(folder: localFolder)
            if let remoteFolder, case .copied = remote {
                prune(folder: remoteFolder)
            }
            recordStatus { status in
                status.lastError = nil
                status.lastErrorAt = nil
                if case .copied = remote { status.lastRemote = manifest.createdAt }
                if case .failed(let message) = remote {
                    status.lastError = "NAS copy failed: \(message)"
                    status.lastErrorAt = now()
                }
            }
            return CatalogBackupResult(manifest: manifest, localFolder: localFolder, remote: remote)
        } catch {
            recordStatus { status in
                status.lastError = error.localizedDescription
                status.lastErrorAt = now()
            }
            throw error
        }
    }

    /// The launch check: a full backup when the newest local set is older
    /// than `maxAge`; otherwise only a catch-up copy of the newest set to a
    /// NAS that was offline last time. Returns nil when nothing was written.
    @discardableResult
    public func backupIfStale(maxAge: TimeInterval = staleAfter) throws -> CatalogBackupResult? {
        if let newest = newestManifest(in: localFolder), now().timeIntervalSince(newest.createdAt) <= maxAge {
            catchUpRemote()
            return nil
        }
        return try backupNow(reason: .launch)
    }

    /// Copies the newest local set to the NAS when the NAS is mounted and
    /// does not have it yet.
    @discardableResult
    public func catchUpRemote() -> CatalogBackupResult.Remote {
        Self.runLock.lock()
        defer { Self.runLock.unlock() }
        guard let newest = newestManifest(in: localFolder) else { return .notConfigured }
        let remote = mirror(newest)
        if case .copied = remote, let remoteFolder {
            prune(folder: remoteFolder)
            recordStatus { $0.lastRemote = newest.createdAt }
        }
        return remote
    }

    public func summary() -> CatalogBackupSummary {
        let status = loadStatus()
        let remoteReachable = remoteFolder.map { CatalogStore.configuredVolumeIsAvailable(for: $0) } ?? false
        var lastRemote = status.lastRemote
        if remoteReachable, let remoteFolder {
            lastRemote = newestManifest(in: remoteFolder)?.createdAt
        }
        return CatalogBackupSummary(
            lastLocal: newestManifest(in: localFolder)?.createdAt,
            lastRemote: lastRemote,
            remoteReachable: remoteReachable,
            remoteConfigured: remoteFolder != nil,
            lastError: status.lastError,
            lastErrorAt: status.lastErrorAt
        )
    }

    /// Every verified set in `folder`, newest first.
    public func manifests(in folder: URL) -> [CatalogBackupManifest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasSuffix(".manifest.json") && Self.isSetID(String($0.dropLast(".manifest.json".count))) }
            .compactMap { name -> CatalogBackupManifest? in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                      let manifest = try? Self.decoder().decode(CatalogBackupManifest.self, from: data),
                      manifest.format == CatalogBackupManifest.formatName,
                      "\(manifest.id).manifest.json" == name
                else { return nil }
                return manifest
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func newestManifest(in folder: URL) -> CatalogBackupManifest? {
        manifests(in: folder).first
    }

    // MARK: - Local set

    private func writeLocalSet(reason: CatalogBackupReason, pinned: Bool) throws -> CatalogBackupManifest {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            throw ToolkitError.commandFailed("There is no catalog to back up at \(catalogURL.path).")
        }
        try fileManager.createDirectory(at: localFolder, withIntermediateDirectories: true)
        let createdAt = now()
        let id = uniqueSetID(for: createdAt)
        var written: [URL] = []
        do {
            var files: [CatalogBackupFile] = []

            let catalogName = "\(id).catalog.sqlite"
            let partial = localFolder.appendingPathComponent(catalogName + ".partial")
            written.append(partial)
            let expectedCounts = try Self.snapshot(from: catalogURL, to: partial)
            let verification = try Self.verify(backup: partial, expectedCounts: expectedCounts)
            let catalogFinal = localFolder.appendingPathComponent(catalogName)
            try fileManager.moveItem(at: partial, to: catalogFinal)
            written.append(catalogFinal)
            files.append(try Self.describe(catalogFinal, role: .catalog))

            // The face labels, exported from the verified snapshot itself so
            // they describe exactly the catalog beside them.
            let labelsURL = localFolder.appendingPathComponent("\(id).faces.json")
            written.append(labelsURL)
            try Self.exportFaceLabels(from: catalogFinal, now: createdAt).encoded()
                .write(to: labelsURL, options: .atomic)
            files.append(try Self.describe(labelsURL, role: .faceLabels))

            var configurationDecodes: Bool?
            if let configurationURL, fileManager.fileExists(atPath: configurationURL.path) {
                let data = try Data(contentsOf: configurationURL)
                configurationDecodes = (try? JSONDecoder().decode(AppConfiguration.self, from: data)) != nil
                let configurationFinal = localFolder.appendingPathComponent("\(id).config.json")
                written.append(configurationFinal)
                try data.write(to: configurationFinal, options: .atomic)
                let described = try Self.describe(configurationFinal, role: .configuration)
                guard described.sha256 == Self.sha256(data) else {
                    throw ToolkitError.commandFailed("The config.json backup did not read back identically.")
                }
                files.append(described)
            }

            let manifest = CatalogBackupManifest(
                format: CatalogBackupManifest.formatName,
                version: CatalogBackupManifest.currentVersion,
                id: id,
                createdAt: createdAt,
                reason: reason,
                pinned: pinned,
                files: files,
                tableCounts: expectedCounts,
                integrityCheck: verification.integrity,
                foreignKeyViolations: verification.foreignKeyViolations,
                configurationDecodes: configurationDecodes
            )
            let manifestURL = localFolder.appendingPathComponent("\(id).manifest.json")
            written.append(manifestURL)
            try Self.encoder().encode(manifest).write(to: manifestURL, options: .atomic)
            return manifest
        } catch {
            // Remove only what this run created; a failed set is never left
            // looking like a backup.
            for url in written {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    /// Copies the live catalog into `destination` with `sqlite3_backup_*`
    /// and returns the verified tables' row counts read inside the same read
    /// transaction the backup copied, so they describe exactly the snapshot
    /// in the file.
    static func snapshot(from source: URL, to destination: URL) throws -> [String: Int] {
        try? FileManager.default.removeItem(at: destination)
        var sourceDB: OpaquePointer?
        guard sqlite3_open_v2(source.path, &sourceDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let sourceDB else {
            sqlite3_close(sourceDB)
            throw ToolkitError.commandFailed("Could not open the catalog for backup.")
        }
        defer { sqlite3_close(sourceDB) }
        sqlite3_busy_timeout(sourceDB, Int32(CatalogDatabase.busyTimeout * 1_000))

        var destinationDB: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &destinationDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let destinationDB else {
            sqlite3_close(destinationDB)
            throw ToolkitError.commandFailed("Could not create the backup file.")
        }
        var destinationOpen = true
        defer { if destinationOpen { sqlite3_close(destinationDB) } }

        try exec("BEGIN;", sourceDB)
        var counts: [String: Int] = [:]
        do {
            let tables = try tableNames(sourceDB)
            for table in verifiedTables where tables.contains(table) {
                counts[table] = try integer("SELECT COUNT(*) FROM \"\(table)\"", sourceDB)
            }
            guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
                throw ToolkitError.commandFailed("Could not start the backup: \(String(cString: sqlite3_errmsg(destinationDB)))")
            }
            let step = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            guard step == SQLITE_DONE, finish == SQLITE_OK else {
                throw ToolkitError.commandFailed("The backup copy stopped early: \(String(cString: sqlite3_errmsg(destinationDB)))")
            }
            try exec("COMMIT;", sourceDB)
        } catch {
            try? exec("ROLLBACK;", sourceDB)
            throw error
        }
        // A backup is a single self-contained file: the copied header
        // still says WAL, so switch it back to the rollback journal, close,
        // and require that no WAL content is left beside it.
        try exec("PRAGMA journal_mode = DELETE;", destinationDB)
        sqlite3_close(destinationDB)
        destinationOpen = false
        let wal = URL(fileURLWithPath: destination.path + "-wal")
        let walSize = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber)?.intValue ?? 0
        guard walSize == 0 else {
            throw ToolkitError.commandFailed("The backup left WAL content behind; it was not accepted.")
        }
        // The shared-memory index is scratch space, never data.
        try? FileManager.default.removeItem(at: wal)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: destination.path + "-shm"))
        return counts
    }

    static func exportFaceLabels(from backup: URL, now: Date) throws -> FaceLabelExport {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: backup.path, configuration: configuration)
        defer { try? queue.close() }
        return try FaceIndexStore(url: backup, queue: queue).exportFaceLabels(now: now)
    }

    struct Verification {
        var integrity: String
        var foreignKeyViolations: Int
    }

    /// Opens `backup` read-only and requires `integrity_check = ok` and the
    /// same row count for every table in `expectedCounts`.
    static func verify(backup: URL, expectedCounts: [String: Int]) throws -> Verification {
        var database: OpaquePointer?
        guard sqlite3_open_v2(backup.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw ToolkitError.commandFailed("Could not open the backup to verify it.")
        }
        defer { sqlite3_close(database) }
        let journal = try strings("PRAGMA journal_mode", database).first ?? ""
        guard journal == "delete" else {
            throw ToolkitError.commandFailed("The backup is in \(journal) mode, not a self-contained file.")
        }
        let integrity = try strings("PRAGMA integrity_check", database).joined(separator: "; ")
        guard integrity == "ok" else {
            throw ToolkitError.commandFailed("The backup failed integrity_check: \(integrity)")
        }
        for (table, expected) in expectedCounts {
            let actual = try integer("SELECT COUNT(*) FROM \"\(table)\"", database)
            guard actual == expected else {
                throw ToolkitError.commandFailed("The backup has \(actual) \(table) rows; the catalog had \(expected).")
            }
        }
        let violations = try strings("PRAGMA foreign_key_check", database).count
        return Verification(integrity: integrity, foreignKeyViolations: violations)
    }

    // MARK: - NAS mirror

    /// Copies `manifest`'s set to the NAS folder: each file lands under a
    /// `.partial` name, is checksum-compared against the manifest by reading
    /// it back from the NAS, and only then takes its final name. The
    /// manifest goes last, so an interrupted copy never looks complete.
    private func mirror(_ manifest: CatalogBackupManifest) -> CatalogBackupResult.Remote {
        guard let remoteFolder else { return .notConfigured }
        guard CatalogStore.configuredVolumeIsAvailable(for: remoteFolder) else { return .offline }
        let fileManager = FileManager.default
        let remoteManifest = remoteFolder.appendingPathComponent("\(manifest.id).manifest.json")
        if fileManager.fileExists(atPath: remoteManifest.path) {
            return .alreadyPresent(remoteFolder)
        }
        var created: [URL] = []
        do {
            try fileManager.createDirectory(at: remoteFolder, withIntermediateDirectories: true)
            for file in manifest.files {
                let source = localFolder.appendingPathComponent(file.name)
                let partial = remoteFolder.appendingPathComponent(file.name + ".partial")
                let final = remoteFolder.appendingPathComponent(file.name)
                try? fileManager.removeItem(at: partial)
                created.append(partial)
                try fileManager.copyItem(at: source, to: partial)
                let copied = try FileScanner.sha256(partial)
                guard copied == file.sha256 else {
                    throw ToolkitError.commandFailed("\(file.name) did not match its checksum on the NAS.")
                }
                if fileManager.fileExists(atPath: final.path) {
                    // Never replace an existing file: an identical copy is
                    // kept, a different one stops the copy untouched.
                    try fileManager.removeItem(at: partial)
                    created.removeLast()
                    guard (try? FileScanner.sha256(final)) == file.sha256 else {
                        throw ToolkitError.commandFailed("\(file.name) already exists on the NAS with different contents; left untouched.")
                    }
                    continue
                }
                try fileManager.moveItem(at: partial, to: final)
                created.removeLast()
                created.append(final)
            }
            let manifestData = try Self.encoder().encode(manifest)
            created.append(remoteManifest)
            try manifestData.write(to: remoteManifest, options: .atomic)
            guard try Data(contentsOf: remoteManifest) == manifestData else {
                throw ToolkitError.commandFailed("The backup manifest did not read back from the NAS.")
            }
            return .copied(remoteFolder)
        } catch {
            for url in created {
                try? fileManager.removeItem(at: url)
            }
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Retention

    /// Deletes sets this service wrote that fall outside the rolling
    /// window. Only files a valid manifest lists (all prefixed with the
    /// set's `ctbackup-` id) and the manifest itself are removed, plus
    /// this service's own leftover `.partial` files older than a day.
    @discardableResult
    public func prune(folder: URL) -> [String] {
        let fileManager = FileManager.default
        let sets = manifests(in: folder)
        let keep = Self.idsToKeep(sets, calendar: Self.calendar)
        var deleted: [String] = []
        for manifest in sets where !keep.contains(manifest.id) {
            for file in manifest.files where file.name.hasPrefix(manifest.id + ".") && !file.name.contains("/") {
                if (try? fileManager.removeItem(at: folder.appendingPathComponent(file.name))) != nil {
                    deleted.append(file.name)
                }
            }
            let manifestName = "\(manifest.id).manifest.json"
            if (try? fileManager.removeItem(at: folder.appendingPathComponent(manifestName))) != nil {
                deleted.append(manifestName)
            }
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(".partial") {
            guard let id = name.split(separator: ".").first.map(String.init), Self.isSetID(id) else { continue }
            let url = folder.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now().timeIntervalSince(modified) > 24 * 60 * 60 else { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                deleted.append(name)
            }
        }
        return deleted
    }

    /// Grandfather-father retention: always the newest set and every
    /// pinned set, the newest set of each of the `dailyKeep` most recent
    /// days that have one, and the newest set of each of the `weeklyKeep`
    /// most recent ISO weeks that have one.
    static func idsToKeep(_ sets: [CatalogBackupManifest], calendar: Calendar) -> Set<String> {
        let sorted = sets.sorted { $0.createdAt > $1.createdAt }
        var keep = Set(sorted.filter(\.pinned).map(\.id))
        if let newest = sorted.first { keep.insert(newest.id) }
        var days: [DateComponents] = []
        var weeks: [DateComponents] = []
        for set in sorted {
            let day = calendar.dateComponents([.year, .month, .day], from: set.createdAt)
            if !days.contains(day), days.count < dailyKeep {
                days.append(day)
                keep.insert(set.id)
            }
            let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: set.createdAt)
            if !weeks.contains(week), weeks.count < weeklyKeep {
                weeks.append(week)
                keep.insert(set.id)
            }
        }
        return keep
    }

    // MARK: - Status

    private struct Status: Codable {
        var lastRemote: Date?
        var lastError: String?
        var lastErrorAt: Date?
    }

    private var statusURL: URL { localFolder.appendingPathComponent("backup-status.json") }

    private func loadStatus() -> Status {
        guard let data = try? Data(contentsOf: statusURL),
              let status = try? Self.decoder().decode(Status.self, from: data)
        else { return Status() }
        return status
    }

    private func recordStatus(_ update: (inout Status) -> Void) {
        var status = loadStatus()
        update(&status)
        try? FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        try? Self.encoder().encode(status).write(to: statusURL, options: .atomic)
    }

    // MARK: - Naming

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }()

    /// `ctbackup-20260922T224400Z`, with `-2`, `-3`… for sets made within
    /// the same second.
    private func uniqueSetID(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let base = "ctbackup-" + formatter.string(from: date)
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: localFolder.path)) ?? [])
        var candidate = base
        var suffix = 2
        while names.contains(where: { $0.hasPrefix(candidate + ".") }) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// True for ids this service generates, and nothing else.
    static func isSetID(_ id: String) -> Bool {
        id.range(of: #"^ctbackup-\d{8}T\d{6}Z(-\d+)?$"#, options: .regularExpression) != nil
    }

    // MARK: - Helpers

    private static func describe(_ url: URL, role: CatalogBackupFile.Role) throws -> CatalogBackupFile {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return CatalogBackupFile(
            role: role,
            name: url.lastPathComponent,
            byteCount: size?.int64Value ?? 0,
            sha256: try FileScanner.sha256(url)
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func exec(_ sql: String, _ database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw ToolkitError.commandFailed("Backup SQL failed: \(message)")
        }
    }

    private static func integer(_ sql: String, _ database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ToolkitError.commandFailed("Backup SQL failed: \(String(cString: sqlite3_errmsg(database)))")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func strings(_ sql: String, _ database: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ToolkitError.commandFailed("Backup SQL failed: \(String(cString: sqlite3_errmsg(database)))")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw ToolkitError.commandFailed("Backup SQL failed: \(String(cString: sqlite3_errmsg(database)))")
            }
            rows.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
        }
        return rows
    }

    private static func tableNames(_ database: OpaquePointer) throws -> Set<String> {
        Set(try strings("SELECT name FROM sqlite_schema WHERE type = 'table'", database))
    }
}
