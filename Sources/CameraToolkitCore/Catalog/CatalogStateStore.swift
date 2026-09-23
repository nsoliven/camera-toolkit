import Foundation
import GRDB

/// The part of `AppConfiguration` whose only durable home is the catalog:
/// events, photo-to-event assignments, display rotations, and burst
/// splits. Everything else in the configuration is settings and stays in
/// `config.json`.
public struct CatalogOwnedState: Codable, Equatable, Sendable {
    public var savedEvents: [SavedCameraEvent]
    public var photoEventAssignments: [PhotoEventAssignment]
    public var displayOrientations: [String: Int]
    public var burstSplits: [BurstSplit]

    public init(
        savedEvents: [SavedCameraEvent] = [],
        photoEventAssignments: [PhotoEventAssignment] = [],
        displayOrientations: [String: Int] = [:],
        burstSplits: [BurstSplit] = []
    ) {
        self.savedEvents = savedEvents
        self.photoEventAssignments = photoEventAssignments
        self.displayOrientations = displayOrientations
        self.burstSplits = burstSplits
    }

    public init(configuration: AppConfiguration) {
        self.init(
            savedEvents: configuration.savedEvents,
            photoEventAssignments: configuration.photoEventAssignments,
            displayOrientations: configuration.displayOrientations,
            burstSplits: configuration.burstSplits
        )
    }

    /// Lays this state onto `configuration` and re-validates the event
    /// selection against the events it now has.
    public func apply(to configuration: inout AppConfiguration) {
        configuration.savedEvents = savedEvents
        configuration.photoEventAssignments = photoEventAssignments
        configuration.displayOrientations = displayOrientations
        configuration.burstSplits = burstSplits
        configuration.normalizeEventSelection()
    }

    public var isEmpty: Bool {
        savedEvents.isEmpty && photoEventAssignments.isEmpty && displayOrientations.isEmpty && burstSplits.isEmpty
    }

    /// What the catalog can hold for this state, and what did not fit:
    /// the first of any duplicate event id, the first of any duplicate
    /// assignment (same `CatalogStore.eventAssetID`), only assignments whose
    /// event exists (the catalog's foreign key), and the first of any
    /// duplicate burst split id.
    public struct Canonical: Equatable, Sendable {
        public var state: CatalogOwnedState
        public var duplicateEventsDropped: Int
        public var duplicateAssignmentsDropped: Int
        public var orphanAssignmentsDropped: Int
        public var duplicateBurstSplitsDropped: Int
    }

    public func canonical() -> Canonical {
        var eventIDs: Set<UUID> = []
        let events = savedEvents.filter { eventIDs.insert($0.id).inserted }
        var assignmentIDs: Set<String> = []
        var duplicates = 0
        var orphans = 0
        var assignments: [PhotoEventAssignment] = []
        assignments.reserveCapacity(photoEventAssignments.count)
        for assignment in photoEventAssignments {
            guard eventIDs.contains(assignment.eventID) else {
                orphans += 1
                continue
            }
            guard assignmentIDs.insert(CatalogStore.eventAssetID(assignment)).inserted else {
                duplicates += 1
                continue
            }
            assignments.append(assignment)
        }
        var splitIDs: Set<UUID> = []
        let splits = burstSplits.filter { splitIDs.insert($0.id).inserted }
        return Canonical(
            state: CatalogOwnedState(
                savedEvents: events,
                photoEventAssignments: assignments,
                displayOrientations: displayOrientations,
                burstSplits: splits
            ),
            duplicateEventsDropped: savedEvents.count - events.count,
            duplicateAssignmentsDropped: duplicates,
            orphanAssignmentsDropped: orphans,
            duplicateBurstSplitsDropped: burstSplits.count - splits.count
        )
    }
}

/// Row counts one `CatalogStateStore.apply` wrote and deleted.
public struct CatalogStateChangeSummary: Equatable, Sendable {
    public var eventsWritten = 0
    public var eventsDeleted = 0
    public var assignmentsWritten = 0
    public var assignmentsDeleted = 0
    public var orientationsWritten = 0
    public var orientationsDeleted = 0
    public var burstSplitsWritten = 0
    public var burstSplitsDeleted = 0

    public init() {}

    public var isEmpty: Bool { self == CatalogStateChangeSummary() }
}

/// What the one-time migration found and did.
public struct CatalogStateMigrationReport: Equatable, Sendable {
    public var events: Int
    public var assignments: Int
    public var displayOrientations: Int
    public var burstSplits: Int
    public var duplicateEventsDropped: Int
    public var duplicateAssignmentsDropped: Int
    public var orphanAssignmentsDropped: Int
    public var duplicateBurstSplitsDropped: Int
    /// `PRAGMA foreign_key_check` rows that existed before the migration
    /// (a legacy dangling `import_batches` reference, for example). They
    /// are reported and left alone; the migration only refuses *new* ones.
    public var preexistingForeignKeyViolations: [String]
    public var backupID: String
    public var legacyConfigurationCopy: URL?
}

/// Reads and writes the catalog-owned state (`CatalogOwnedState`) once the
/// catalog is its only durable home.
///
/// - `load()` reads it back exactly: events from their JSON payload,
///   assignments with their exact modification time.
/// - `apply(from:to:)` writes only the rows that differ between two
///   states, in one transaction.
/// - `migrate(...)` moves a legacy `config.json`'s state in, once, behind a
///   verified backup and a validation that must pass before it commits.
///
/// All access goes through the shared catalog connection.
public struct CatalogStateStore: Sendable {
    /// `app_state` row that marks the catalog as the owner of the state.
    static let ownershipKey = "eventStateSource"
    static let ownershipValue = "catalog"
    static let migratedAtKey = "eventStateMigratedAt"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    private func writer() throws -> any DatabaseWriter {
        try CatalogDatabase.writer(for: url)
    }

    // MARK: - Ownership

    /// True once the migration committed. Missing file → false.
    public func catalogOwnsState() throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try CatalogTransactionRetry.run {
            try writer().read { try Self.ownsState($0) }
        }
    }

    static func ownsState(_ database: Database) throws -> Bool {
        guard try database.tableExists("app_state") else { return false }
        return try String.fetchOne(
            database,
            sql: "SELECT value FROM app_state WHERE key = ?",
            arguments: [ownershipKey]
        ) == ownershipValue
    }

    /// Event and assignment rows present, whoever wrote them — the legacy
    /// mirror counts too.
    public func existingRowCounts() throws -> (events: Int, assignments: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (0, 0) }
        return try CatalogTransactionRetry.run {
            try writer().read { database in
                guard try database.tableExists("events"), try database.tableExists("event_assets") else { return (0, 0) }
                return (
                    try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM events") ?? 0,
                    try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM event_assets") ?? 0
                )
            }
        }
    }

    // MARK: - Reading

    public func load() throws -> CatalogOwnedState {
        try CatalogTransactionRetry.run {
            try writer().read { database in
                guard try Self.ownsState(database) else {
                    throw ToolkitError.commandFailed("The catalog does not hold the events yet; nothing was loaded.")
                }
                return try Self.load(database)
            }
        }
    }

    static func load(_ database: Database) throws -> CatalogOwnedState {
        let decoder = JSONDecoder()
        let events = try Row.fetchAll(
            database,
            sql: "SELECT id, payload FROM events ORDER BY ordinal, rowid"
        ).map { row -> SavedCameraEvent in
            guard let payload: String = row["payload"] else {
                throw ToolkitError.commandFailed("Catalog event \(row["id"] as String? ?? "?") has no saved details.")
            }
            return try decoder.decode(SavedCameraEvent.self, from: Data(payload.utf8))
        }

        let assignments = try Row.fetchAll(
            database,
            sql: """
            SELECT id, event_id, source_root_path, relative_path, byte_count, modified_at_ref,
                   device_id, immich_upload_override
            FROM event_assets ORDER BY ordinal, rowid
            """
        ).map { row -> PhotoEventAssignment in
            guard let eventID = UUID(uuidString: row["event_id"] as String? ?? ""),
                  let reference: Double = row["modified_at_ref"] else {
                throw ToolkitError.commandFailed("Catalog assignment \(row["id"] as String? ?? "?") is incomplete.")
            }
            let override = Self.override(row["immich_upload_override"] as DatabaseValue)
            return PhotoEventAssignment(
                sourceRootPath: row["source_root_path"],
                relativePath: row["relative_path"],
                fileSize: row["byte_count"],
                modifiedAt: Date(timeIntervalSinceReferenceDate: reference),
                eventID: eventID,
                deviceID: row["device_id"],
                immichUploadOverride: override
            )
        }

        var orientations: [String: Int] = [:]
        for row in try Row.fetchAll(database, sql: "SELECT file_key, quarter_turns FROM display_orientations") {
            orientations[row["file_key"]] = row["quarter_turns"]
        }

        let splits = try Row.fetchAll(
            database,
            sql: "SELECT id, created_at_ref, member_path_keys FROM burst_splits ORDER BY ordinal, rowid"
        ).map { row -> BurstSplit in
            guard let id = UUID(uuidString: row["id"] as String? ?? "") else {
                throw ToolkitError.commandFailed("Catalog burst split has an invalid id.")
            }
            let members = try decoder.decode([String].self, from: Data((row["member_path_keys"] as String).utf8))
            return BurstSplit(
                id: id,
                createdAt: Date(timeIntervalSinceReferenceDate: row["created_at_ref"]),
                memberPathKeys: members
            )
        }

        return CatalogOwnedState(
            savedEvents: events,
            photoEventAssignments: assignments,
            displayOrientations: orientations,
            burstSplits: splits
        )
    }

    // MARK: - Incremental writes

    /// Writes only the rows that differ between `old` (what the catalog
    /// holds) and `new`, in one transaction. Refuses — writing nothing —
    /// when the catalog does not own the state, or when `new` would erase
    /// every event and assignment at once, the signature of a caller that
    /// lost its state rather than a user edit.
    @discardableResult
    public func apply(from old: CatalogOwnedState, to new: CatalogOwnedState) throws -> CatalogStateChangeSummary {
        let before = old.canonical().state
        let after = new.canonical().state
        guard before != after else { return CatalogStateChangeSummary() }
        if before.savedEvents.count >= 2, after.savedEvents.isEmpty, after.photoEventAssignments.isEmpty {
            throw ToolkitError.commandFailed(
                "Refused to erase all \(before.savedEvents.count) events and \(before.photoEventAssignments.count) assignments in one save. Nothing was written."
            )
        }
        return try CatalogTransactionRetry.run {
            try writer().write { database in
                guard try Self.ownsState(database) else {
                    throw ToolkitError.commandFailed("The catalog no longer holds the events (was it replaced?). Nothing was written.")
                }
                return try Self.write(from: before, to: after, database: database)
            }
        }
    }

    static func write(
        from before: CatalogOwnedState,
        to after: CatalogOwnedState,
        database: Database
    ) throws -> CatalogStateChangeSummary {
        var summary = CatalogStateChangeSummary()
        let now = timestamp(Date())

        // Events: ordinal is the array position — a handful of rows.
        let oldEvents = Dictionary(before.savedEvents.enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { first, _ in first })
        for (index, event) in after.savedEvents.enumerated() {
            if let old = oldEvents[event.id], old.0 == index, old.1 == event { continue }
            try upsertEvent(event, ordinal: index, now: now, database: database)
            summary.eventsWritten += 1
        }

        // Assignments: keyed by catalog id; a changed id is a delete plus
        // an insert, exactly like the legacy mirror.
        var oldAssignments: [String: PhotoEventAssignment] = [:]
        oldAssignments.reserveCapacity(before.photoEventAssignments.count)
        for assignment in before.photoEventAssignments {
            oldAssignments[CatalogStore.eventAssetID(assignment)] = assignment
        }
        var newIDs: Set<String> = []
        newIDs.reserveCapacity(after.photoEventAssignments.count)
        var changed: [(String, PhotoEventAssignment)] = []
        for assignment in after.photoEventAssignments {
            let id = CatalogStore.eventAssetID(assignment)
            newIDs.insert(id)
            if oldAssignments[id] != assignment {
                changed.append((id, assignment))
            }
        }
        for id in oldAssignments.keys where !newIDs.contains(id) {
            try database.execute(sql: "DELETE FROM event_assets WHERE id = ?", arguments: [id])
            summary.assignmentsDeleted += 1
        }
        if !changed.isEmpty {
            var ordinal = (try Int.fetchOne(database, sql: "SELECT MAX(ordinal) FROM event_assets") ?? -1) + 1
            for (id, assignment) in changed {
                try upsertAssignment(id: id, assignment, ordinal: ordinal, now: now, database: database)
                ordinal += 1
                summary.assignmentsWritten += 1
            }
        }

        let newEventIDs = Set(after.savedEvents.map(\.id))
        for id in oldEvents.keys where !newEventIDs.contains(id) {
            try database.execute(sql: "DELETE FROM events WHERE id = ?", arguments: [id.uuidString])
            summary.eventsDeleted += 1
        }

        for (key, turns) in after.displayOrientations where before.displayOrientations[key] != turns {
            try database.execute(
                sql: """
                INSERT INTO display_orientations(file_key, quarter_turns, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(file_key) DO UPDATE SET quarter_turns = excluded.quarter_turns, updated_at = excluded.updated_at
                """,
                arguments: [key, turns, now]
            )
            summary.orientationsWritten += 1
        }
        for key in before.displayOrientations.keys where after.displayOrientations[key] == nil {
            try database.execute(sql: "DELETE FROM display_orientations WHERE file_key = ?", arguments: [key])
            summary.orientationsDeleted += 1
        }

        let oldSplits = Dictionary(before.burstSplits.enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { first, _ in first })
        for (index, split) in after.burstSplits.enumerated() {
            if let old = oldSplits[split.id], old.0 == index, old.1 == split { continue }
            try upsertSplit(split, ordinal: index, now: now, database: database)
            summary.burstSplitsWritten += 1
        }
        let newSplitIDs = Set(after.burstSplits.map(\.id))
        for id in oldSplits.keys where !newSplitIDs.contains(id) {
            try database.execute(sql: "DELETE FROM burst_splits WHERE id = ?", arguments: [id.uuidString])
            summary.burstSplitsDeleted += 1
        }
        return summary
    }

    // MARK: - Migration

    /// Test seams for the failure paths: each hook runs at its step and
    /// may throw to simulate a crash or a fault there.
    public struct MigrationHooks: Sendable {
        public var afterBackup: (@Sendable () throws -> Void)?
        public var afterLegacyCopy: (@Sendable () throws -> Void)?
        /// Runs inside the migration transaction, after the rows are
        /// written and before validation — a test can tamper here.
        public var beforeValidation: (@Sendable (Database) throws -> Void)?

        public init(
            afterBackup: (@Sendable () throws -> Void)? = nil,
            afterLegacyCopy: (@Sendable () throws -> Void)? = nil,
            beforeValidation: (@Sendable (Database) throws -> Void)? = nil
        ) {
            self.afterBackup = afterBackup
            self.afterLegacyCopy = afterLegacyCopy
            self.beforeValidation = beforeValidation
        }
    }

    /// Moves a legacy configuration's events, assignments, rotations, and
    /// burst splits into the catalog, once:
    ///
    /// 1. a verified, pinned backup of the catalog and `config.json`
    ///    through `backups` (the NAS copy follows with the next launch
    ///    check);
    /// 2. a timestamped, byte-verified copy of `config.json` beside it
    ///    (`config.pre-sqlite-<stamp>.json`), kept until a later release;
    /// 3. one transaction that writes every row, marks the catalog as the
    ///    owner, and validates before committing: the state read back
    ///    must equal the configuration's exactly, event and assignment
    ///    counts must match, `integrity_check` must be `ok`, and
    ///    `foreign_key_check` may only report violations that existed
    ///    before. Any mismatch rolls the whole transaction back.
    ///
    /// Safe to repeat after a crash at any step: nothing before the commit
    /// changes what the app reads, and once committed the ownership row
    /// makes the next launch load from the catalog instead.
    public func migrate(
        state: CatalogOwnedState,
        configurationURL: URL?,
        backups: CatalogBackupService,
        hooks: MigrationHooks = MigrationHooks()
    ) throws -> CatalogStateMigrationReport {
        let canonical = state.canonical()
        let target = canonical.state

        let existing = try existingRowCounts()
        if target.savedEvents.isEmpty, target.photoEventAssignments.isEmpty,
           existing.events > 0 || existing.assignments > 0 {
            throw ToolkitError.commandFailed(
                "config.json has no events, but the catalog lists \(existing.events) events and \(existing.assignments) assignments. Not migrating an empty configuration over them."
            )
        }

        let backup = try backups.backupNow(reason: .migration, pinned: true, mirrorToRemote: false)
        try hooks.afterBackup?()

        let legacyCopy = try configurationURL.flatMap { try Self.writeLegacyCopy(of: $0) }
        try hooks.afterLegacyCopy?()

        let preexisting = try CatalogTransactionRetry.run {
            try writer().write { database -> [String] in
                let violationsBefore = try Self.foreignKeyViolations(database)

                try Self.replaceAll(with: target, database: database)
                try database.execute(
                    sql: """
                    INSERT INTO app_state(key, value, updated_at) VALUES (?, ?, ?), (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                    """,
                    arguments: [
                        Self.ownershipKey, Self.ownershipValue, Self.timestamp(Date()),
                        Self.migratedAtKey, Self.timestamp(Date()), Self.timestamp(Date())
                    ]
                )
                try hooks.beforeValidation?(database)

                try Self.validate(target, violationsBefore: violationsBefore, database: database)
                return violationsBefore
            }
        }

        return CatalogStateMigrationReport(
            events: target.savedEvents.count,
            assignments: target.photoEventAssignments.count,
            displayOrientations: target.displayOrientations.count,
            burstSplits: target.burstSplits.count,
            duplicateEventsDropped: canonical.duplicateEventsDropped,
            duplicateAssignmentsDropped: canonical.duplicateAssignmentsDropped,
            orphanAssignmentsDropped: canonical.orphanAssignmentsDropped,
            duplicateBurstSplitsDropped: canonical.duplicateBurstSplitsDropped,
            preexistingForeignKeyViolations: preexisting,
            backupID: backup.manifest.id,
            legacyConfigurationCopy: legacyCopy
        )
    }

    /// Writes every row of `state` (upserts, so presence and Immich rows
    /// hanging off unchanged assignments survive) and deletes rows that
    /// are not in it.
    static func replaceAll(with state: CatalogOwnedState, database: Database) throws {
        let now = timestamp(Date())
        for (index, event) in state.savedEvents.enumerated() {
            try upsertEvent(event, ordinal: index, now: now, database: database)
        }
        try database.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS keep_ids (id TEXT PRIMARY KEY)")
        try database.execute(sql: "DELETE FROM keep_ids")
        for (index, assignment) in state.photoEventAssignments.enumerated() {
            let id = CatalogStore.eventAssetID(assignment)
            try upsertAssignment(id: id, assignment, ordinal: index, now: now, database: database, keepOrdinal: false)
            try database.execute(sql: "INSERT OR IGNORE INTO keep_ids(id) VALUES (?)", arguments: [id])
        }
        try database.execute(sql: "DELETE FROM event_assets WHERE id NOT IN (SELECT id FROM keep_ids)")
        try database.execute(sql: "DELETE FROM keep_ids")
        for event in state.savedEvents {
            try database.execute(sql: "INSERT OR IGNORE INTO keep_ids(id) VALUES (?)", arguments: [event.id.uuidString])
        }
        try database.execute(sql: "DELETE FROM events WHERE id NOT IN (SELECT id FROM keep_ids)")
        try database.execute(sql: "DROP TABLE keep_ids")

        try database.execute(sql: "DELETE FROM display_orientations")
        for (key, turns) in state.displayOrientations {
            try database.execute(
                sql: "INSERT INTO display_orientations(file_key, quarter_turns, updated_at) VALUES (?, ?, ?)",
                arguments: [key, turns, now]
            )
        }
        try database.execute(sql: "DELETE FROM burst_splits")
        for (index, split) in state.burstSplits.enumerated() {
            try upsertSplit(split, ordinal: index, now: now, database: database)
        }
    }

    static func validate(_ target: CatalogOwnedState, violationsBefore: [String], database: Database) throws {
        let eventCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM events") ?? -1
        let assignmentCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM event_assets") ?? -1
        guard eventCount == target.savedEvents.count else {
            throw ToolkitError.commandFailed("Migration check failed: \(eventCount) events in the catalog, \(target.savedEvents.count) expected.")
        }
        guard assignmentCount == target.photoEventAssignments.count else {
            throw ToolkitError.commandFailed(
                "Migration check failed: \(assignmentCount) assignments in the catalog, \(target.photoEventAssignments.count) expected."
            )
        }
        let readBack = try load(database)
        guard readBack == target else {
            throw ToolkitError.commandFailed("Migration check failed: the events read back from the catalog differ from config.json.")
        }
        let integrity = try String.fetchAll(database, sql: "PRAGMA integrity_check").joined(separator: "; ")
        guard integrity == "ok" else {
            throw ToolkitError.commandFailed("Migration check failed: integrity_check reported \(integrity).")
        }
        let before = Set(violationsBefore)
        let introduced = try foreignKeyViolations(database).filter { !before.contains($0) }
        guard introduced.isEmpty else {
            throw ToolkitError.commandFailed("Migration check failed: new foreign-key violations \(introduced.joined(separator: ", ")).")
        }
    }

    /// `table|rowid|parent` for each `foreign_key_check` row.
    static func foreignKeyViolations(_ database: Database) throws -> [String] {
        try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").map { row in
            let table: String = row[0]
            let rowid: Int64? = row[1]
            let parent: String = row[2]
            return "\(table)|\(rowid.map(String.init) ?? "-")|\(parent)"
        }
    }

    /// Copies `config.json` to `config.pre-sqlite-<UTC stamp>.json` beside
    /// it and verifies the copy byte for byte. An identical copy from an
    /// interrupted earlier attempt is reused instead of duplicated.
    static func writeLegacyCopy(of configurationURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configurationURL.path) else { return nil }
        let data = try Data(contentsOf: configurationURL)
        let folder = configurationURL.deletingLastPathComponent()
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.sorted() where name.hasPrefix("config.pre-sqlite-") && name.hasSuffix(".json") {
            let url = folder.appendingPathComponent(name)
            if (try? Data(contentsOf: url)) == data { return url }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var url = folder.appendingPathComponent("config.pre-sqlite-\(formatter.string(from: Date())).json")
        var suffix = 2
        while fileManager.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("config.pre-sqlite-\(formatter.string(from: Date()))-\(suffix).json")
            suffix += 1
        }
        try data.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == data else {
            throw ToolkitError.commandFailed("The legacy copy of config.json did not read back identically.")
        }
        return url
    }

    // MARK: - Row writers

    private static func upsertEvent(_ event: SavedCameraEvent, ordinal: Int, now: String, database: Database) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = String(decoding: try encoder.encode(event), as: UTF8.self)
        try database.execute(
            sql: """
            INSERT INTO events(
                id, name, event_date, immich_upload_enabled, immich_album_policy,
                immich_album_name, parent_event_id, created_at, last_used_at, updated_at,
                payload, ordinal
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                event_date = excluded.event_date,
                immich_upload_enabled = excluded.immich_upload_enabled,
                immich_album_policy = excluded.immich_album_policy,
                immich_album_name = excluded.immich_album_name,
                parent_event_id = excluded.parent_event_id,
                created_at = excluded.created_at,
                last_used_at = excluded.last_used_at,
                updated_at = excluded.updated_at,
                payload = excluded.payload,
                ordinal = excluded.ordinal
            """,
            arguments: [
                event.id.uuidString,
                event.name,
                timestamp(event.eventDate),
                event.sendsToImmich ? 1 : 0,
                event.resolvedImmichAlbumPolicy.rawValue,
                event.immichAlbumName ?? "",
                event.parentEventID?.uuidString,
                timestamp(event.createdAt),
                timestamp(event.lastUsedAt),
                now,
                payload,
                ordinal
            ]
        )
    }

    /// `keepOrdinal`: an update leaves an existing row's position alone,
    /// so editing one assignment never renumbers the rest.
    private static func upsertAssignment(
        id: String,
        _ assignment: PhotoEventAssignment,
        ordinal: Int,
        now: String,
        database: Database,
        keepOrdinal: Bool = true
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO event_assets(
                id, event_id, source_root_path, relative_path, byte_count,
                modified_at, modified_at_ref, device_id, immich_upload_override, updated_at, ordinal
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                event_id = excluded.event_id,
                source_root_path = excluded.source_root_path,
                relative_path = excluded.relative_path,
                byte_count = excluded.byte_count,
                modified_at = excluded.modified_at,
                modified_at_ref = excluded.modified_at_ref,
                device_id = excluded.device_id,
                immich_upload_override = excluded.immich_upload_override,
                updated_at = excluded.updated_at\(keepOrdinal ? "" : ",\n    ordinal = excluded.ordinal")
            """,
            arguments: [
                id,
                assignment.eventID.uuidString,
                assignment.sourceRootPath,
                assignment.relativePath,
                assignment.fileSize,
                timestamp(assignment.modifiedAt),
                assignment.modifiedAt.timeIntervalSinceReferenceDate,
                assignment.deviceID,
                assignment.immichUploadOverride.map { $0 ? 1 : 0 },
                now,
                ordinal
            ]
        )
    }

    private static func upsertSplit(_ split: BurstSplit, ordinal: Int, now: String, database: Database) throws {
        let members = String(decoding: try JSONEncoder().encode(split.memberPathKeys), as: UTF8.self)
        try database.execute(
            sql: """
            INSERT INTO burst_splits(id, created_at_ref, member_path_keys, ordinal, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                created_at_ref = excluded.created_at_ref,
                member_path_keys = excluded.member_path_keys,
                ordinal = excluded.ordinal,
                updated_at = excluded.updated_at
            """,
            arguments: [split.id.uuidString, split.createdAt.timeIntervalSinceReferenceDate, members, ordinal, now]
        )
    }

    /// ISO8601DateFormatter is thread-safe; one instance serves every row.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func timestamp(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// The override column as written by either writer: an integer 0/1
    /// from this store, or the legacy mirror's text `'1'`/`'0'`/`''`.
    private static func override(_ value: DatabaseValue) -> Bool? {
        switch value.storage {
        case .int64(let number): number != 0
        case .double(let number): number != 0
        case .string(let text): text == "1" ? true : (text == "0" ? false : nil)
        case .null, .blob: nil
        }
    }
}
