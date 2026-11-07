import Foundation
import GRDB

public struct NASAdoptReport: Sendable {
    public var backupID: String
    public var eventsAdded: Int
    public var assignmentsAdded: Int
    /// Table → (rows before, rows after).
    public var counts: [String: (before: Int, after: Int)]
    public var lines: [String]

    public var text: String { lines.joined(separator: "\n") }
}

/// Writes a reviewed `NASAdoptPlan` into the catalog. Catalog rows only —
/// no file on the NAS or a drive is opened, moved or written.
///
/// Order, each step proven before the next:
/// 1. refuse while Camera Toolkit runs, while another NAS migration holds
///    the lock or is unfinished, and while NAS renames are queued (until
///    they land, an event's old NAS folder looks unowned);
/// 2. re-plan the plan's folders and refuse when anything in the
///    fingerprint differs (listings, sizes, modification times, catalog);
/// 3. a verified, pinned catalog backup;
/// 4. one transaction through `CatalogStateStore.write` adding exactly the
///    plan's events and assignments, checked before it commits: the
///    catalog digest still matches, exact row counts in every counted
///    table, `integrity_check`, no new foreign-key violations, and every
///    added row resolving to its planned NAS path. Any failure rolls back.
public struct NASAdoptExecutor {
    public let supportFolder: URL
    public let configurationURL: URL
    public let catalogURL: URL
    public let configuration: AppConfiguration
    private let isAppRunning: () -> Bool
    private let list: NASEventDiscovery.Lister
    /// Test seam: runs inside the transaction before its checks.
    var beforeValidation: ((Database) throws -> Void)?

    public init(
        supportFolder: URL,
        configurationURL: URL,
        catalogURL: URL,
        configuration: AppConfiguration,
        isAppRunning: @escaping () -> Bool,
        list: @escaping NASEventDiscovery.Lister = DirectoryListing.list
    ) {
        self.supportFolder = supportFolder.standardizedFileURL
        self.configurationURL = configurationURL.standardizedFileURL
        self.catalogURL = catalogURL.standardizedFileURL
        self.configuration = configuration
        self.isAppRunning = isAppRunning
        self.list = list
    }

    public func plan(folders: [String]) throws -> NASAdoptPlan {
        try NASAdoptPlanner.plan(
            .init(configuration: configuration, supportFolder: supportFolder, catalogURL: catalogURL, folders: folders),
            list: list
        )
    }

    public func execute(_ plan: NASAdoptPlan) throws -> NASAdoptReport {
        guard plan.isExecutable else {
            throw ToolkitError.commandFailed("The plan is not executable (nothing to add, or a requested folder was not found). Nothing was changed.")
        }
        if isAppRunning() {
            throw ToolkitError.commandFailed("Camera Toolkit is running. Quit it first (it checkpoints the catalog on quit). Nothing was changed.")
        }
        let migrations = NASLayoutMigrationJournal.folder(supportFolder: supportFolder)
        let lock = try LayoutMigrationLock(folder: migrations)
        defer { _ = lock }
        guard plan.supportFolderPath == supportFolder.path, plan.catalogPath == catalogURL.path else {
            throw ToolkitError.commandFailed("The plan was made for \(plan.catalogPath) in \(plan.supportFolderPath). Nothing was changed.")
        }
        if let unfinished = Self.unfinishedNASMigration(in: migrations) {
            throw ToolkitError.commandFailed("A NAS layout migration is not finished: \(unfinished.path). Resume or undo it first. Nothing was changed.")
        }
        let nasRoot = EventStorageLocations(configuration: configuration).nasRoot.path
        let pending = NASRenameQueue(journalFolder: LayoutMigrationPlanner.moveJournalFolder(supportFolder: supportFolder))
            .pendingRenameCount(nasRoot: nasRoot)
        guard pending == 0 else {
            throw ToolkitError.commandFailed("\(pending) NAS rename(s) are still queued. Open the app with the NAS connected so they run, then make a new plan. Nothing was changed.")
        }
        let problems = try differences(from: plan)
        guard problems.isEmpty else {
            throw ToolkitError.commandFailed(
                "The NAS or the catalog changed since the plan was made — make a new plan. Nothing was changed.\n- "
                    + problems.prefix(20).joined(separator: "\n- ")
            )
        }

        let backup = try CatalogBackupService(
            catalogURL: catalogURL,
            configurationURL: configurationURL,
            localFolder: supportFolder.appendingPathComponent("Backups", isDirectory: true),
            remoteFolder: nil
        ).backupNow(reason: .manual, pinned: true, mirrorToRemote: false)
        guard let backupFile = backup.catalogURL, FileManager.default.fileExists(atPath: backupFile.path) else {
            throw ToolkitError.commandFailed("The catalog backup did not produce a file. Nothing was changed.")
        }

        let counts = try commit(plan)
        CatalogDatabase.checkpointAndClose(url: catalogURL)
        var lines = ["Catalog backup \(backup.manifest.id) verified: \(backupFile.path)"]
        lines.append("Added \(plan.newEvents.count) event(s) and \(plan.rows.count) NAS-only assignment(s). No file was touched.")
        for (table, value) in counts.sorted(by: { $0.key < $1.key }) where value.before != value.after || ["events", "event_assets"].contains(table) {
            lines.append("    \(table): \(value.before) → \(value.after)")
        }
        lines.append("To take it back: quit the app and restore backup \(backup.manifest.id).")
        return NASAdoptReport(
            backupID: backup.manifest.id,
            eventsAdded: plan.newEvents.count,
            assignmentsAdded: plan.rows.count,
            counts: counts,
            lines: lines
        )
    }

    /// Re-plans the same folders; anything that differs is a problem.
    func differences(from plan: NASAdoptPlan) throws -> [String] {
        let replanned = try self.plan(folders: plan.requestedFolders)
        var problems: [String] = []
        if replanned.fingerprint.catalogDigest != plan.fingerprint.catalogDigest {
            problems.append("the catalog's events, assignments, faces, rotations or burst splits changed")
        }
        for folder in Set(plan.fingerprint.folderListings.keys).union(replanned.fingerprint.folderListings.keys).sorted()
        where replanned.fingerprint.folderListings[folder] != plan.fingerprint.folderListings[folder] {
            problems.append("the files to add in \(folder) changed")
        }
        if replanned.fingerprint.outcomeDigest != plan.fingerprint.outcomeDigest {
            problems.append("the events or rows the plan adds differ now")
        }
        if replanned.notFound != plan.notFound { problems.append("a requested folder is no longer offered") }
        return problems
    }

    private func commit(_ plan: NASAdoptPlan) throws -> [String: (before: Int, after: Int)] {
        let tables = LayoutMigrationCatalog.countedTables + [NASSyncStore.tableName]
        return try CatalogDatabase.writer(for: catalogURL).write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            guard try CatalogStateStore.ownsState(db) else {
                throw ToolkitError.commandFailed("The catalog does not hold the events; nothing was written to it.")
            }
            guard try LayoutMigrationCatalog.digest(database: db) == plan.fingerprint.catalogDigest else {
                throw ToolkitError.commandFailed("The catalog changed since the plan was made; nothing was written to it.")
            }
            var before: [String: Int] = [:]
            for table in tables where try db.tableExists(table) {
                before[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
            }
            let violationsBefore = Set(try CatalogStateStore.foreignKeyViolations(db))

            let stateBefore = try CatalogStateStore.load(db)
            var stateAfter = stateBefore
            let existingIDs = Set(stateBefore.photoEventAssignments.map(CatalogStore.eventAssetID))
            let existingEvents = Set(stateBefore.savedEvents.map(\.id))
            guard plan.rows.allSatisfy({ !existingIDs.contains(CatalogStore.eventAssetID($0.assignment)) }),
                  plan.newEvents.allSatisfy({ !existingEvents.contains($0.id) }) else {
                throw ToolkitError.commandFailed("A planned row or event is already in the catalog; nothing was written to it.")
            }
            stateAfter.savedEvents += plan.newEvents
            stateAfter.photoEventAssignments += plan.rows.map(\.assignment)
            let written = try CatalogStateStore.write(from: stateBefore, to: stateAfter, database: db)
            try beforeValidation?(db)

            var failures: [String] = []
            var expectedWritten = CatalogStateChangeSummary()
            expectedWritten.eventsWritten = plan.newEvents.count
            expectedWritten.assignmentsWritten = plan.rows.count
            if written != expectedWritten { failures.append("the write touched more than the planned rows: \(written)") }
            var counts: [String: (before: Int, after: Int)] = [:]
            for (table, count) in before {
                let after = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? -1
                counts[table] = (count, after)
                let expected = count + (table == "events" ? plan.newEvents.count : table == "event_assets" ? plan.rows.count : 0)
                if after != expected { failures.append("\(table) has \(after) rows, \(expected) expected") }
            }
            let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check").joined(separator: "; ")
            if integrity != "ok" { failures.append("integrity_check: \(integrity)") }
            let introduced = try CatalogStateStore.foreignKeyViolations(db).filter { !violationsBefore.contains($0) }
            if !introduced.isEmpty { failures.append("new foreign-key violations: \(introduced.prefix(5).joined(separator: ", "))") }

            // The app, reading the catalog as it now is, must put every
            // added row at the NAS file it was planned for.
            let state = try CatalogStateStore.load(db)
            var configuration = self.configuration
            state.apply(to: &configuration)
            let locations = EventStorageLocations(configuration: configuration)
            let byID = Dictionary(state.photoEventAssignments.map { (CatalogStore.eventAssetID($0), $0) }, uniquingKeysWith: { first, _ in first })
            let events = EventHierarchy.index(state.savedEvents)
            for row in plan.rows {
                let id = CatalogStore.eventAssetID(row.assignment)
                guard let assignment = byID[id], let event = events[assignment.eventID],
                      let archive = locations.archiveURL(for: assignment, event: event) else {
                    failures.append("row \(row.nasRelativePath) is missing after the write")
                    continue
                }
                if archive.path != locations.nasRoot.appendingPathComponent(row.nasRelativePath).standardizedFileURL.path {
                    failures.append("row \(row.nasRelativePath) resolves to \(archive.path)")
                }
            }
            guard failures.isEmpty else {
                throw ToolkitError.commandFailed("The catalog write failed its checks and was rolled back:\n- " + failures.prefix(20).joined(separator: "\n- "))
            }
            return counts
        }
    }

    static func unfinishedNASMigration(in folder: URL) -> URL? {
        LayoutMigrationDisk.names(in: folder.path, fileManager: .default).lazy.compactMap { name -> URL? in
            let url = folder.appendingPathComponent(name, isDirectory: true).appendingPathComponent("journal.json")
            guard let journal = try? NASLayoutMigrationJournal.read(url) else { return nil }
            return journal.phase == .completed || journal.phase == .undone ? nil : url
        }.first
    }
}
