import Darwin
import Foundation
import GRDB
import SQLite3

public struct LayoutMigrationReport: Sendable {
    public var succeeded: Bool
    public var phase: LayoutMigrationJournal.Phase?
    public var journalURL: URL?
    public var lines: [String]

    public var text: String { lines.joined(separator: "\n") }
}

/// Runs a reviewed `LayoutMigrationPlan`, resumes one after a crash, or
/// undoes one.
///
/// Order of a run, each step proven before the next:
/// 1. refuse when Camera Toolkit is running, another migration holds the
///    lock, or anything the plan fingerprinted changed;
/// 2. a verified, pinned catalog backup through `CatalogBackupService`;
/// 3. the journal (plan copy + state), fsynced, before any rename;
/// 4. per folder: exclusive same-volume renames (`renameExclusive`, never
///    over an existing file), then proof that every planned file sits at
///    its destination with its size and inode and is gone from its source;
/// 5. one catalog transaction with every path rewrite, checked before it
///    commits (`integrity_check`, no new foreign-key violations, exact row
///    counts, every confirmed face still on a file that exists);
/// 6. the capture-date cache, trash manifests and the Apply-journal barrier;
/// 7. `rmdir` of legacy folders the renames emptied — never a delete of
///    anything with content.
public final class LayoutMigrationExecutor {
    public struct Hooks {
        /// After the journal is written, before the first rename.
        public var afterJournal: (() throws -> Void)?
        /// After each completed rename; the argument counts them.
        public var afterMove: ((Int) throws -> Void)?
        public var afterFolder: ((String) throws -> Void)?
        public var afterMoves: (() throws -> Void)?
        /// Inside the catalog transaction, after the rewrite, before checks.
        public var beforeCatalogValidation: ((Database) throws -> Void)?
        public var afterCatalogCommit: (() throws -> Void)?
        public var afterStores: (() throws -> Void)?

        public init(
            afterJournal: (() throws -> Void)? = nil,
            afterMove: ((Int) throws -> Void)? = nil,
            afterFolder: ((String) throws -> Void)? = nil,
            afterMoves: (() throws -> Void)? = nil,
            beforeCatalogValidation: ((Database) throws -> Void)? = nil,
            afterCatalogCommit: (() throws -> Void)? = nil,
            afterStores: (() throws -> Void)? = nil
        ) {
            self.afterJournal = afterJournal
            self.afterMove = afterMove
            self.afterFolder = afterFolder
            self.afterMoves = afterMoves
            self.beforeCatalogValidation = beforeCatalogValidation
            self.afterCatalogCommit = afterCatalogCommit
            self.afterStores = afterStores
        }
    }

    public let supportFolder: URL
    public let configurationURL: URL
    public let catalogURL: URL
    private let isAppRunning: () -> Bool
    private let hooks: Hooks
    private let fileManager: FileManager
    private let now: () -> Date
    private let log: (String) -> Void

    public init(
        supportFolder: URL,
        configurationURL: URL,
        catalogURL: URL,
        isAppRunning: @escaping () -> Bool,
        hooks: Hooks = Hooks(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = { Date() },
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.supportFolder = supportFolder.standardizedFileURL
        self.configurationURL = configurationURL.standardizedFileURL
        self.catalogURL = catalogURL.standardizedFileURL
        self.isAppRunning = isAppRunning
        self.hooks = hooks
        self.fileManager = fileManager
        self.now = now
        self.log = log
    }

    public convenience init(
        context: LayoutMigrationCommand.Context,
        isAppRunning: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) {
        self.init(
            supportFolder: context.supportFolder,
            configurationURL: context.configurationURL,
            catalogURL: context.catalogURL,
            isAppRunning: isAppRunning,
            log: log
        )
    }

    var migrationsFolder: URL { LayoutMigrationJournal.folder(supportFolder: supportFolder) }

    // MARK: - Execute

    public func execute(_ plan: LayoutMigrationPlan) throws -> LayoutMigrationReport {
        guard plan.isExecutable else {
            throw ToolkitError.commandFailed("The plan is not executable:\n- " + plan.blockers.joined(separator: "\n- "))
        }
        try refuseIfAppRunning()
        let lock = try LayoutMigrationLock(folder: migrationsFolder)
        defer { _ = lock }
        guard plan.catalogPath == catalogURL.path, plan.supportFolderPath == supportFolder.path else {
            throw ToolkitError.commandFailed(
                "The plan was made for \(plan.catalogPath) in \(plan.supportFolderPath), not \(catalogURL.path). Nothing was changed."
            )
        }
        if let unfinished = try unfinishedJournals().first {
            throw ToolkitError.commandFailed(
                "An earlier migration is not finished: \(unfinished.path). Resume it (--resume) or undo it (--undo) first. Nothing was changed."
            )
        }
        let problems = try verifyUnchanged(plan)
        guard problems.isEmpty else {
            throw ToolkitError.commandFailed(
                "The drive or catalog changed since the plan was made — make a new plan. Nothing was changed.\n- "
                    + problems.prefix(20).joined(separator: "\n- ")
                    + (problems.count > 20 ? "\n- … and \(problems.count - 20) more" : "")
            )
        }

        // A verified, pinned backup of the catalog as it is now.
        let backups = CatalogBackupService(
            catalogURL: catalogURL,
            configurationURL: configurationURL,
            localFolder: supportFolder.appendingPathComponent("Backups", isDirectory: true),
            remoteFolder: nil
        )
        let backup = try backups.backupNow(reason: .migration, pinned: true, mirrorToRemote: false)
        guard let backupCatalog = backup.catalogURL, fileManager.fileExists(atPath: backupCatalog.path) else {
            throw ToolkitError.commandFailed("The catalog backup did not produce a file. Nothing was changed.")
        }
        log("Catalog backup \(backup.manifest.id) verified: \(backupCatalog.path)")

        // The journal, before anything moves.
        let stamp = Self.stamp(now())
        let folder = migrationsFolder.appendingPathComponent("\(stamp)-\(plan.id.uuidString.prefix(8))", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let planData = try plan.jsonData()
        try LayoutMigrationDurable.writeNew(planData, to: folder.appendingPathComponent("plan.json"))
        var journal = LayoutMigrationJournal(
            format: LayoutMigrationJournal.formatName,
            version: LayoutMigrationJournal.currentVersion,
            id: UUID(),
            planID: plan.id,
            planDigest: LayoutMigrationHash.sha256(planData),
            createdAt: now(),
            updatedAt: now(),
            phase: .prepared,
            backupID: backup.manifest.id,
            backupCatalogPath: backupCatalog.path,
            backupTableCounts: backup.manifest.tableCounts,
            verifiedFolders: [],
            createdDirectories: [],
            removedDirectories: [],
            keptDirectories: [],
            catalogCommittedAt: nil,
            postCommitCatalogDigest: nil,
            captureDateBackupPath: nil,
            captureDateKeysRewritten: 0,
            trashManifestBackups: [],
            barrierPath: nil,
            undoSafetyBackupID: nil,
            lastError: nil,
            notes: []
        )
        let journalURL = folder.appendingPathComponent("journal.json")
        try LayoutMigrationJournal.write(journal, to: journalURL)
        log("Journal: \(journalURL.path)")
        try hooks.afterJournal?()
        return try run(plan: plan, journal: &journal, journalURL: journalURL)
    }

    // MARK: - Resume

    public func resume(journalURL: URL) throws -> LayoutMigrationReport {
        try refuseIfAppRunning()
        let lock = try LayoutMigrationLock(folder: migrationsFolder)
        defer { _ = lock }
        var journal = try LayoutMigrationJournal.read(journalURL)
        let plan = try readPlan(beside: journalURL, journal: journal)
        switch journal.phase {
        case .completed, .undone:
            return LayoutMigrationReport(succeeded: true, phase: journal.phase, journalURL: journalURL, lines: ["Nothing to resume: the migration is \(journal.phase.rawValue)."])
        case .undoing:
            throw ToolkitError.commandFailed("An undo of this migration was interrupted. Run --undo again to finish it.")
        case .prepared, .moving, .movesVerified:
            // The catalog has not been rewritten unless the commit landed
            // just before a crash; the marker row tells.
            if try catalogMarker() != plan.id {
                let digest = try currentCatalogDigest()
                guard digest == plan.fingerprint.catalogDigest else {
                    throw ToolkitError.commandFailed("The catalog changed since the migration started (and it was not this migration). Undo instead (--undo).")
                }
            }
        case .catalogCommitted, .storesRewritten:
            break
        }
        log("Resuming from \(journal.phase.rawValue).")
        return try run(plan: plan, journal: &journal, journalURL: journalURL)
    }

    /// The steps after the journal, each skipping what is already proven.
    private func run(plan: LayoutMigrationPlan, journal: inout LayoutMigrationJournal, journalURL: URL) throws -> LayoutMigrationReport {
        var lines: [String] = []
        do {
            if journal.phase == .prepared || journal.phase == .moving {
                try moveFiles(plan: plan, journal: &journal, journalURL: journalURL)
                journal.phase = .movesVerified
                try save(&journal, to: journalURL)
                lines.append("Moved and verified \(plan.summary.files) files in \(plan.folders.count) folders.")
                try hooks.afterMoves?()
            }
            if journal.phase == .movesVerified {
                if try catalogMarker() == plan.id {
                    journal.notes.append("The catalog commit had landed before the interruption; it was not repeated.")
                } else {
                    try commitCatalog(plan: plan)
                }
                journal.catalogCommittedAt = now()
                journal.postCommitCatalogDigest = try currentCatalogDigest()
                journal.phase = .catalogCommitted
                try save(&journal, to: journalURL)
                lines.append("Catalog rewritten and verified: \(plan.catalog.assignmentRewrites.count) assignments, \(plan.catalog.facePhotoRewrites.count) face photos, \(plan.catalog.confirmedFaces) confirmed faces intact.")
                try hooks.afterCatalogCommit?()
            }
            if journal.phase == .catalogCommitted {
                try rewriteStores(plan: plan, journal: &journal, journalURL: journalURL)
                journal.phase = .storesRewritten
                try save(&journal, to: journalURL)
                lines.append("Capture-date cache: \(journal.captureDateKeysRewritten) keys moved. Trash manifests: \(journal.trashManifestBackups.count) rewritten. Older Apply journals are no longer undoable.")
                try hooks.afterStores?()
            }
            if journal.phase == .storesRewritten {
                removeEmptiedFolders(plan: plan, journal: &journal)
                journal.phase = .completed
                try save(&journal, to: journalURL)
                lines.append("Removed \(journal.removedDirectories.count) emptied legacy folders; kept \(journal.keptDirectories.count) that still hold something.")
                for kept in journal.keptDirectories.prefix(30) {
                    lines.append("  kept \(kept.path) — \(kept.reason)")
                }
            }
        } catch {
            journal.lastError = error.localizedDescription
            try? save(&journal, to: journalURL)
            lines.append("STOPPED at \(journal.phase.rawValue): \(error.localizedDescription)")
            lines.append("Journal: \(journalURL.path) — run --resume to continue from the last proven step or --undo to put everything back.")
            return LayoutMigrationReport(succeeded: false, phase: journal.phase, journalURL: journalURL, lines: lines)
        }
        lines.append("Layout migration complete. Journal: \(journalURL.path)")
        lines.append("Undo with: --migrate-layout --undo \"\(journalURL.path)\"")
        return LayoutMigrationReport(succeeded: true, phase: journal.phase, journalURL: journalURL, lines: lines)
    }

    // MARK: - Moves

    enum MoveState: Equatable {
        case pending
        case done
        case conflict(String)
    }

    /// Where one planned file is right now, by inode.
    static func state(of move: LayoutMigrationPlan.Move) -> MoveState {
        let source = LayoutMigrationDisk.lstatEntry(move.source)
        let destination = LayoutMigrationDisk.lstatEntry(move.destination)
        let sourceMatches = source.map { $0.kind == .file && $0.inode == move.inode && $0.size == move.byteCount } ?? false
        let destinationMatches = destination.map { $0.kind == .file && $0.inode == move.inode && $0.size == move.byteCount } ?? false
        switch (source, destination) {
        case (_?, nil) where sourceMatches: return .pending
        case (nil, _?) where destinationMatches: return .done
        case (nil, nil): return .conflict("\(move.source) is at neither its source nor its destination")
        case (_?, _?): return .conflict("both \(move.source) and \(move.destination) exist")
        default: return .conflict("\(sourceMatches ? move.destination : move.source) is not the planned file (size or inode differs)")
        }
    }

    private func moveFiles(plan: LayoutMigrationPlan, journal: inout LayoutMigrationJournal, journalURL: URL) throws {
        if journal.phase == .prepared {
            journal.phase = .moving
            try save(&journal, to: journalURL)
        }
        let moveLog = try LayoutMigrationMoveLog(url: journalURL.deletingLastPathComponent().appendingPathComponent("moves.log"))
        var completed = 0
        var created = Set(journal.createdDirectories)
        for folder in plan.folders where !journal.verifiedFolders.contains(folder.id) {
            // Files first, then their AppleDouble twins: on exFAT the
            // filesystem carries a twin with its file, elsewhere it is
            // renamed explicitly.
            let order = folder.moves.indices.filter { folder.moves[$0].companionOf == nil }
                + folder.moves.indices.filter { folder.moves[$0].companionOf != nil }
            for index in order {
                let move = folder.moves[index]
                switch Self.state(of: move) {
                case .done:
                    continue
                case .conflict(let reason):
                    throw ToolkitError.commandFailed("Stopped before \(move.source): \(reason).")
                case .pending:
                    break
                }
                let parent = (move.destination as NSString).deletingLastPathComponent
                for directory in try makeDirectories(parent) where created.insert(directory).inserted {
                    journal.createdDirectories.append(directory)
                    moveLog.append("mkdir\t\(directory)")
                }
                try DriveMoveService.renameExclusive(from: move.source, to: move.destination)
                moveLog.append("done\t\(folder.id)\t\(index)")
                completed += 1
                try hooks.afterMove?(completed)
            }
            moveLog.sync()
            // Prove the folder: every file at its destination, same size
            // and inode, gone from its source.
            for move in folder.moves where Self.state(of: move) != .done {
                throw ToolkitError.commandFailed("Verification failed for \(move.source) → \(move.destination): \(Self.state(of: move)).")
            }
            journal.verifiedFolders.append(folder.id)
            try save(&journal, to: journalURL)
            log("Verified \(folder.id) \(folder.legacyDeviceFolderPath) → \(folder.originalsPath) (\(folder.moves.count) files)")
            try hooks.afterFolder?(folder.id)
        }
    }

    /// Creates `path` and missing ancestors; returns the ones it created,
    /// outermost first.
    private func makeDirectories(_ path: String) throws -> [String] {
        var missing: [String] = []
        var current = path
        while !LayoutMigrationDisk.exists(current) {
            missing.append(current)
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        guard LayoutMigrationDisk.lstatEntry(current)?.kind == .directory else {
            throw ToolkitError.commandFailed("\(current) is not a folder; cannot create \(path).")
        }
        var made: [String] = []
        for directory in missing.reversed() {
            guard mkdir(directory, 0o755) == 0 || errno == EEXIST else {
                throw ToolkitError.commandFailed("Could not create \(directory): \(String(cString: strerror(errno)))")
            }
            made.append(directory)
        }
        return made
    }

    // MARK: - Fingerprint

    /// Everything that differs from what the plan saw. Empty means the plan
    /// still describes the drive and the catalog exactly.
    func verifyUnchanged(_ plan: LayoutMigrationPlan) throws -> [String] {
        var problems: [String] = []
        let digest = try currentCatalogDigest()
        if digest != plan.fingerprint.catalogDigest {
            problems.append("the catalog's events, assignments, faces, rotations or burst splits changed")
        }
        var legacyNow: Set<String> = []
        for root in plan.driveRoots {
            if root.scanned {
                guard VolumeInfo.isAvailable(URL(fileURLWithPath: root.path)), fileManager.fileExists(atPath: root.path) else {
                    problems.append("\(root.path) is not available")
                    continue
                }
                for folder in (try? DriveEventDiscovery.cameraFolders(driveRoot: URL(fileURLWithPath: root.path))) ?? []
                where folder.layout == .legacyCardCopy {
                    legacyNow.insert(folder.cameraFolderPath)
                }
            } else if VolumeInfo.isAvailable(URL(fileURLWithPath: root.path)), fileManager.fileExists(atPath: root.path) {
                problems.append("\(root.path) was offline when the plan was made and is available now")
            }
        }
        let planned = Set(plan.fingerprint.legacyCameraFolders)
        for added in legacyNow.subtracting(planned).sorted() {
            problems.append("a legacy camera folder appeared: \(added)")
        }
        for (folder, expected) in plan.fingerprint.folderListings.sorted(by: { $0.key < $1.key }) {
            if LayoutMigrationDisk.listingDigest(of: folder, fileManager: fileManager) != expected {
                problems.append("the contents of \(folder) changed")
            }
        }
        for folder in plan.folders {
            guard let eventDevice = VolumeInfo.deviceNumber(for: URL(fileURLWithPath: folder.eventFolderPath)) else {
                problems.append("\(folder.eventFolderPath) is not reachable")
                continue
            }
            for move in folder.moves {
                guard let source = LayoutMigrationDisk.lstatEntry(move.source) else {
                    problems.append("missing: \(move.source)")
                    continue
                }
                if source.kind != .file || source.size != move.byteCount || source.inode != move.inode || source.modifiedAt != move.modifiedAt {
                    problems.append("changed: \(move.source)")
                }
                if source.device != eventDevice {
                    problems.append("on another volume: \(move.source)")
                }
                if LayoutMigrationDisk.exists(move.destination) {
                    problems.append("destination taken: \(move.destination)")
                }
            }
        }
        return problems
    }

    // MARK: - Catalog

    private func writer() throws -> any DatabaseWriter {
        try CatalogDatabase.writer(for: catalogURL)
    }

    func currentCatalogDigest() throws -> String {
        try writer().read { try LayoutMigrationCatalog.digest(database: $0) }
    }

    /// The plan id the catalog's marker row names, when this migration's
    /// commit landed.
    func catalogMarker() throws -> UUID? {
        try writer().read { db -> UUID? in
            guard try db.tableExists("app_state"),
                  let value = try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = ?", arguments: [LayoutMigrationCatalog.markerKey]),
                  let data = value.data(using: .utf8),
                  let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return nil }
            return marker.planID
        }
    }

    struct Marker: Codable {
        var planID: UUID
        var committedAt: String
    }

    private func commitCatalog(plan: LayoutMigrationPlan) throws {
        let changes = plan.catalog
        let nowText = ISO8601DateFormatter().string(from: now())
        try writer().write { db in
            // Keys change in place; the children follow inside the same
            // transaction, so foreign keys are checked at commit.
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            guard try LayoutMigrationCatalog.digest(database: db) == plan.fingerprint.catalogDigest else {
                throw ToolkitError.commandFailed("The catalog changed since the plan was made; nothing was written to it.")
            }
            var countsBefore: [String: Int] = [:]
            for table in LayoutMigrationCatalog.countedTables where try db.tableExists(table) {
                countsBefore[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
            }
            let violationsBefore = Set(try CatalogStateStore.foreignKeyViolations(db))
            let confirmedBefore = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM faces WHERE state = 'confirmed'") ?? 0

            // Assignments: two steps through a temporary id, so no new id
            // can ever meet an old one mid-way.
            let temporary = "layout-migration-tmp|"
            for rewrite in changes.assignmentRewrites {
                try db.execute(
                    sql: "UPDATE event_assets SET id = ?, source_root_path = ?, relative_path = ?, updated_at = ? WHERE id = ?",
                    arguments: [temporary + rewrite.newID, rewrite.newSourceRootPath, rewrite.newRelativePath, nowText, rewrite.oldID]
                )
                guard db.changesCount == 1 else {
                    throw ToolkitError.commandFailed("Assignment \(rewrite.oldID) was not found; nothing was written to the catalog.")
                }
                for table in ["event_asset_locations", "immich_assets"] {
                    try db.execute(sql: "UPDATE \(table) SET event_asset_id = ? WHERE event_asset_id = ?", arguments: [temporary + rewrite.newID, rewrite.oldID])
                }
            }
            for rewrite in changes.assignmentRewrites {
                try db.execute(sql: "UPDATE event_assets SET id = ? WHERE id = ?", arguments: [rewrite.newID, temporary + rewrite.newID])
                for table in ["event_asset_locations", "immich_assets"] {
                    try db.execute(sql: "UPDATE \(table) SET event_asset_id = ? WHERE event_asset_id = ?", arguments: [rewrite.newID, temporary + rewrite.newID])
                }
            }

            for rewrite in changes.facePhotoRewrites {
                try db.execute(
                    sql: "UPDATE face_photos SET path_key = ?, path = ?, file_name = ?, updated_at = ? WHERE path_key = ?",
                    arguments: [temporary + rewrite.newPathKey, rewrite.newPath, rewrite.newFileName, nowText, rewrite.oldPathKey]
                )
                guard db.changesCount == 1 else {
                    throw ToolkitError.commandFailed("Face photo \(rewrite.oldPathKey) was not found; nothing was written to the catalog.")
                }
                try db.execute(sql: "UPDATE faces SET photo_id = ? WHERE photo_id = ?", arguments: [temporary + rewrite.newPathKey, rewrite.oldPathKey])
            }
            for rewrite in changes.facePhotoRewrites {
                try db.execute(sql: "UPDATE face_photos SET path_key = ? WHERE path_key = ?", arguments: [rewrite.newPathKey, temporary + rewrite.newPathKey])
                try db.execute(sql: "UPDATE faces SET photo_id = ? WHERE photo_id = ?", arguments: [rewrite.newPathKey, temporary + rewrite.newPathKey])
            }
            for rename in changes.faceIdentityRenames {
                try db.execute(
                    sql: "UPDATE face_photos SET file_name = ?, updated_at = ? WHERE path_key = ? AND file_name = ?",
                    arguments: [rename.newFileName, nowText, rename.pathKey, rename.oldFileName]
                )
                guard db.changesCount == 1 else {
                    throw ToolkitError.commandFailed("Face photo \(rename.pathKey) no longer has the name \(rename.oldFileName); nothing was written to the catalog.")
                }
            }
            for copy in changes.orientationCopies {
                try db.execute(
                    sql: "INSERT INTO display_orientations(file_key, quarter_turns, updated_at) VALUES (?, ?, ?)",
                    arguments: [copy.newKey, copy.quarterTurns, nowText]
                )
            }
            for rewrite in changes.burstSplitRewrites {
                let old = String(decoding: try JSONEncoder().encode(rewrite.oldMemberPathKeys), as: UTF8.self)
                let new = String(decoding: try JSONEncoder().encode(rewrite.newMemberPathKeys), as: UTF8.self)
                try db.execute(
                    sql: "UPDATE burst_splits SET member_path_keys = ?, updated_at = ? WHERE id = ? AND member_path_keys = ?",
                    arguments: [new, nowText, rewrite.id.uuidString, old]
                )
                guard db.changesCount == 1 else {
                    throw ToolkitError.commandFailed("Burst split \(rewrite.id) changed; nothing was written to the catalog.")
                }
            }
            let marker = String(decoding: try JSONEncoder().encode(Marker(planID: plan.id, committedAt: nowText)), as: UTF8.self)
            try db.execute(
                sql: """
                INSERT INTO app_state(key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """,
                arguments: [changes.markerKey, marker, nowText]
            )
            try hooks.beforeCatalogValidation?(db)
            try Self.validate(
                plan: plan,
                countsBefore: countsBefore,
                violationsBefore: violationsBefore,
                confirmedBefore: confirmedBefore,
                database: db
            )
        }
        // The commit is durable; fold the WAL in so a copy of the file alone
        // is complete.
        CatalogDatabase.checkpointAndClose(url: catalogURL)
    }

    /// The checks that must pass before the catalog transaction commits.
    static func validate(
        plan: LayoutMigrationPlan,
        countsBefore: [String: Int],
        violationsBefore: Set<String>,
        confirmedBefore: Int,
        database db: Database
    ) throws {
        var failures: [String] = []
        for (table, before) in countsBefore {
            let after = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? -1
            let expected = table == "display_orientations" ? before + plan.catalog.orientationCopies.count : before
            if after != expected { failures.append("\(table) has \(after) rows, \(expected) expected") }
        }
        let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check").joined(separator: "; ")
        if integrity != "ok" { failures.append("integrity_check: \(integrity)") }
        let introduced = try CatalogStateStore.foreignKeyViolations(db).filter { !violationsBefore.contains($0) }
        if !introduced.isEmpty { failures.append("new foreign-key violations: \(introduced.prefix(5).joined(separator: ", "))") }

        for rewrite in plan.catalog.assignmentRewrites {
            let row = try Row.fetchOne(db, sql: "SELECT source_root_path, relative_path FROM event_assets WHERE id = ?", arguments: [rewrite.newID])
            if row == nil { failures.append("assignment \(rewrite.newID) is missing") }
            if LayoutMigrationDisk.lstatEntry(rewrite.destination)?.kind != .file {
                failures.append("assignment \(rewrite.newID) points at \(rewrite.destination), which is not there")
            }
        }

        // Confirmed faces: the same number, and every one on a photo the
        // migration touched still attaches to a file that exists — by its
        // new path, or by file identity to a moved file under its new name.
        let confirmedAfter = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM faces WHERE state = 'confirmed'") ?? -1
        if confirmedAfter != confirmedBefore { failures.append("\(confirmedAfter) confirmed faces, \(confirmedBefore) before") }
        let orphaned = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM faces f LEFT JOIN face_photos p ON p.path_key = f.photo_id
            WHERE f.state = 'confirmed' AND p.path_key IS NULL
            """) ?? -1
        if orphaned != 0 { failures.append("\(orphaned) confirmed faces lost their photo row") }
        var oldKeys: Set<String> = []
        var newKeys: Set<String> = []
        for move in plan.allMoves where move.companionOf == nil && move.kind != .folderAppleDouble {
            let date = Date(timeIntervalSinceReferenceDate: move.modifiedAt)
            oldKeys.insert(FaceIndexStore.fileKey(fileName: (move.source as NSString).lastPathComponent, byteCount: move.byteCount, modifiedAt: date))
            newKeys.insert(FaceIndexStore.fileKey(fileName: (move.destination as NSString).lastPathComponent, byteCount: move.byteCount, modifiedAt: date))
        }
        let rewrittenKeys = Set(plan.catalog.facePhotoRewrites.map(\.newPathKey))
        let renamedKeys = Set(plan.catalog.faceIdentityRenames.map(\.pathKey))
        var attachedAffected = 0
        for row in try Row.fetchAll(db, sql: """
            SELECT p.path_key, p.path, p.file_name, p.byte_count, p.modified_at, COUNT(f.id) AS confirmed
            FROM face_photos p JOIN faces f ON f.photo_id = p.path_key AND f.state = 'confirmed'
            GROUP BY p.path_key
            """) {
            let key: String = row["path_key"]
            let path: String = row["path"]
            let confirmed: Int = row["confirmed"]
            let modified: String = row["modified_at"]
            let fileKey = FaceIndexStore.fileKey(
                fileName: row["file_name"],
                byteCount: row["byte_count"],
                modifiedAt: FaceIndexStore.parseTimestamp(modified) ?? .distantPast
            )
            if rewrittenKeys.contains(key) {
                if LayoutMigrationDisk.lstatEntry(path)?.kind == .file {
                    attachedAffected += confirmed
                } else {
                    failures.append("\(confirmed) confirmed face(s) point at \(path), which is not there")
                }
            } else if renamedKeys.contains(key) || oldKeys.contains(fileKey) || newKeys.contains(fileKey) {
                if newKeys.contains(fileKey) || LayoutMigrationDisk.lstatEntry(path)?.kind == .file {
                    attachedAffected += confirmed
                } else {
                    failures.append("\(confirmed) confirmed face(s) on \(row["file_name"] as String) no longer match a moved file")
                }
            }
        }
        if attachedAffected != plan.catalog.confirmedFacesAffected {
            failures.append("\(attachedAffected) affected confirmed faces attach to files, \(plan.catalog.confirmedFacesAffected) expected")
        }
        guard failures.isEmpty else {
            throw ToolkitError.commandFailed("The catalog rewrite failed its checks and was rolled back:\n- " + failures.joined(separator: "\n- "))
        }
    }

    // MARK: - Stores

    private func rewriteStores(plan: LayoutMigrationPlan, journal: inout LayoutMigrationJournal, journalURL: URL) throws {
        let folder = journalURL.deletingLastPathComponent()
        // Capture dates: a cache, so a failure here only costs a re-read.
        let captureURL = URL(fileURLWithPath: plan.stores.captureDatePath)
        if journal.captureDateBackupPath == nil, fileManager.fileExists(atPath: captureURL.path) {
            let backupURL = folder.appendingPathComponent("capture-dates.before.json")
            do {
                if !fileManager.fileExists(atPath: backupURL.path) {
                    try LayoutMigrationDurable.writeNew(try Data(contentsOf: captureURL), to: backupURL)
                }
                let cache = CaptureDateCache(url: captureURL)
                var mapping: [String: String] = [:]
                for move in plan.allMoves { mapping[move.source] = move.destination }
                journal.captureDateKeysRewritten = cache.rekey(mapping)
                try cache.save()
                journal.captureDateBackupPath = backupURL.path
            } catch {
                journal.notes.append("capture-dates.json was not rewritten (\(error.localizedDescription)); moved files will have their capture dates re-read once.")
            }
            try save(&journal, to: journalURL)
        }

        // Trash manifests: restores land in the new layout.
        let done = Set(journal.trashManifestBackups.map(\.manifestPath))
        for (index, rewrite) in plan.stores.trashManifests.enumerated() where !done.contains(rewrite.manifestPath) {
            let url = URL(fileURLWithPath: rewrite.manifestPath)
            guard let original = try? Data(contentsOf: url), var manifest = try? MediaTrashService.readManifest(url) else {
                journal.notes.append("Trash manifest \(rewrite.manifestPath) is gone or unreadable; left alone.")
                continue
            }
            let mapping = Dictionary(rewrite.entries.map { ($0.old, $0.new) }, uniquingKeysWith: { first, _ in first })
            var changed = 0
            for entryIndex in manifest.entries.indices {
                if let new = mapping[manifest.entries[entryIndex].originalAbsolutePath] {
                    manifest.entries[entryIndex].originalAbsolutePath = new
                    changed += 1
                }
            }
            guard changed > 0 else { continue }
            let backupURL = folder.appendingPathComponent(String(format: "trash-%03d.manifest.json", index + 1))
            if !fileManager.fileExists(atPath: backupURL.path) {
                try LayoutMigrationDurable.writeNew(original, to: backupURL)
            }
            try MediaTrashService.writeManifest(manifest, to: url)
            journal.trashManifestBackups.append(.init(
                manifestPath: rewrite.manifestPath,
                backupPath: backupURL.path,
                writtenSHA256: LayoutMigrationHash.sha256(try Data(contentsOf: url))
            ))
            try save(&journal, to: journalURL)
        }

        // Apply journals recorded before now name Card Copy paths.
        if journal.barrierPath == nil {
            let journals = URL(fileURLWithPath: plan.stores.moveJournalFolderPath, isDirectory: true)
            try fileManager.createDirectory(at: journals, withIntermediateDirectories: true)
            let barrierURL = journals.appendingPathComponent(DriveMoveService.layoutMigrationBarrierFileName)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // A whole second after now, so a journal written this second is
            // already behind the barrier.
            let barrier = DriveMoveService.LayoutMigrationBarrier(migrationID: journal.id, completedAt: now().addingTimeInterval(1))
            try LayoutMigrationDurable.write(try encoder.encode(barrier), to: barrierURL)
            journal.barrierPath = barrierURL.path
        }
    }

    // MARK: - Folder removal

    /// `rmdir` only: a folder that still holds anything fails to go and is
    /// reported. On exFAT the filesystem drops a removed folder's own `._`
    /// twin with it.
    private func removeEmptiedFolders(plan: LayoutMigrationPlan, journal: inout LayoutMigrationJournal) {
        var removed = Set(journal.removedDirectories)
        for folder in plan.folders {
            let nested = folder.legacyDirectories
                .sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
                .map { (folder.legacyFilesRootPath as NSString).appendingPathComponent($0) }
            for path in nested + [folder.legacyFilesRootPath, folder.legacyDeviceFolderPath] where !removed.contains(path) {
                guard LayoutMigrationDisk.lstatEntry(path)?.kind == .directory else { continue }
                if rmdir(path) == 0 {
                    journal.removedDirectories.append(path)
                    removed.insert(path)
                } else {
                    let code = errno
                    let names = LayoutMigrationDisk.names(in: path, fileManager: fileManager)
                    journal.keptDirectories.append(.init(
                        path: path,
                        reason: code == ENOTEMPTY || code == EEXIST
                            ? "still holds \(names.prefix(5).joined(separator: ", "))\(names.count > 5 ? ", …" : "")"
                            : String(cString: strerror(code))
                    ))
                }
            }
        }
    }

    // MARK: - Undo

    /// Renames every moved file back, restores the pre-migration catalog
    /// from the verified backup (after a safety backup of the current one),
    /// restores the capture-date cache and the trash manifests, removes the
    /// barrier, and recreates the legacy folders. Refuses when the catalog
    /// changed after the migration committed — restoring would discard
    /// those changes.
    public func undo(journalURL: URL) throws -> LayoutMigrationReport {
        try refuseIfAppRunning()
        let lock = try LayoutMigrationLock(folder: migrationsFolder)
        defer { _ = lock }
        var journal = try LayoutMigrationJournal.read(journalURL)
        let plan = try readPlan(beside: journalURL, journal: journal)
        if journal.phase == .undone {
            return LayoutMigrationReport(succeeded: true, phase: .undone, journalURL: journalURL, lines: ["Already undone."])
        }
        var lines: [String] = []
        let committed = try catalogMarker() == plan.id
        if committed, journal.phase != .undoing {
            let digest = try currentCatalogDigest()
            if let expected = journal.postCommitCatalogDigest, digest != expected {
                throw ToolkitError.commandFailed(
                    "The catalog changed after the migration (events, assignments, faces, rotations or splits). Restoring the pre-migration backup would discard those changes, so nothing was undone. Decide first, then restore by hand from \(journal.backupCatalogPath)."
                )
            }
        }
        journal.phase = .undoing
        journal.lastError = nil
        try save(&journal, to: journalURL)

        // 1. The catalog.
        if committed {
            if journal.undoSafetyBackupID == nil {
                let safety = try CatalogBackupService(
                    catalogURL: catalogURL,
                    configurationURL: configurationURL,
                    localFolder: supportFolder.appendingPathComponent("Backups", isDirectory: true),
                    remoteFolder: nil
                ).backupNow(reason: .migration, pinned: true, mirrorToRemote: false)
                journal.undoSafetyBackupID = safety.manifest.id
                try save(&journal, to: journalURL)
                lines.append("Safety backup of the migrated catalog: \(safety.manifest.id)")
            }
            try restoreCatalog(from: URL(fileURLWithPath: journal.backupCatalogPath), expectedCounts: journal.backupTableCounts)
            guard try currentCatalogDigest() == plan.fingerprint.catalogDigest else {
                throw ToolkitError.commandFailed("The restored catalog does not match the pre-migration state the plan recorded. Stopped; the files were not moved back.")
            }
            lines.append("Catalog restored from backup \(journal.backupID) and verified against the plan.")
        }

        // 2. Stores.
        if let backup = journal.captureDateBackupPath, fileManager.fileExists(atPath: backup) {
            try LayoutMigrationDurable.write(try Data(contentsOf: URL(fileURLWithPath: backup)), to: URL(fileURLWithPath: plan.stores.captureDatePath))
            lines.append("capture-dates.json restored.")
        }
        for backup in journal.trashManifestBackups {
            let url = URL(fileURLWithPath: backup.manifestPath)
            guard let current = try? Data(contentsOf: url) else {
                journal.notes.append("Trash manifest \(backup.manifestPath) is gone (emptied?); nothing to restore.")
                continue
            }
            if LayoutMigrationHash.sha256(current) == backup.writtenSHA256 {
                try LayoutMigrationDurable.write(try Data(contentsOf: URL(fileURLWithPath: backup.backupPath)), to: url)
            } else {
                journal.notes.append("Trash manifest \(backup.manifestPath) changed after the migration; left as it is (original in \(backup.backupPath)).")
            }
        }
        if let barrier = journal.barrierPath, let data = try? Data(contentsOf: URL(fileURLWithPath: barrier)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if (try? decoder.decode(DriveMoveService.LayoutMigrationBarrier.self, from: data))?.migrationID == journal.id {
                try fileManager.removeItem(atPath: barrier)
            }
        }

        // 3. Folders the migration removed, outermost first.
        for directory in journal.removedDirectories.reversed() where !LayoutMigrationDisk.exists(directory) {
            _ = try makeDirectories(directory)
        }

        // 4. Files, newest first; files before their twins so the
        // filesystem can carry a twin back with its file.
        var failures: [String] = []
        var movedBack = 0
        for folder in plan.folders.reversed() {
            let order = folder.moves.indices.reversed().filter { folder.moves[$0].companionOf == nil }
                + folder.moves.indices.reversed().filter { folder.moves[$0].companionOf != nil }
            for index in order {
                let move = folder.moves[index]
                switch Self.state(of: move) {
                case .pending:
                    continue
                case .conflict(let reason):
                    failures.append(reason)
                    continue
                case .done:
                    break
                }
                do {
                    _ = try makeDirectories((move.source as NSString).deletingLastPathComponent)
                    try DriveMoveService.renameExclusive(from: move.destination, to: move.source)
                    movedBack += 1
                } catch {
                    failures.append("\(move.destination): \(error.localizedDescription)")
                }
            }
        }
        // 5. Folders this run created, innermost first, when empty again.
        var createdKept = 0
        for directory in journal.createdDirectories.reversed() where LayoutMigrationDisk.exists(directory) {
            if rmdir(directory) != 0 { createdKept += 1 }
        }
        lines.append("Renamed \(movedBack) files back; \(createdKept) folder(s) the migration created still hold something and stay.")
        guard failures.isEmpty else {
            journal.lastError = "\(failures.count) file(s) could not be put back"
            try save(&journal, to: journalURL)
            lines.append("NOT FINISHED — \(failures.count) problem(s):")
            lines += failures.prefix(30).map { "  - " + $0 }
            lines.append("Fix them and run --undo again.")
            return LayoutMigrationReport(succeeded: false, phase: .undoing, journalURL: journalURL, lines: lines)
        }
        journal.phase = .undone
        try save(&journal, to: journalURL)
        lines.append("Undo complete. Every planned file is back at its original path.")
        return LayoutMigrationReport(succeeded: true, phase: .undone, journalURL: journalURL, lines: lines)
    }

    /// Copies the backup into the live catalog with the SQLite backup API
    /// and checks the result against the backup's recorded counts.
    private func restoreCatalog(from backup: URL, expectedCounts: [String: Int]) throws {
        CatalogDatabase.checkpointAndClose(url: catalogURL)
        var source: OpaquePointer?
        guard sqlite3_open_v2(backup.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let source else {
            sqlite3_close(source)
            throw ToolkitError.commandFailed("Could not open the backup \(backup.path).")
        }
        defer { sqlite3_close(source) }
        var destination: OpaquePointer?
        guard sqlite3_open_v2(catalogURL.path, &destination, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let destination else {
            sqlite3_close(destination)
            throw ToolkitError.commandFailed("Could not open the catalog to restore it.")
        }
        defer { sqlite3_close(destination) }
        sqlite3_busy_timeout(destination, Int32(CatalogDatabase.busyTimeout * 1_000))
        guard let handle = sqlite3_backup_init(destination, "main", source, "main") else {
            throw ToolkitError.commandFailed("Could not start the restore: \(String(cString: sqlite3_errmsg(destination)))")
        }
        let step = sqlite3_backup_step(handle, -1)
        let finish = sqlite3_backup_finish(handle)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw ToolkitError.commandFailed("The restore stopped early: \(String(cString: sqlite3_errmsg(destination)))")
        }
        CatalogDatabase.checkpointAndClose(url: catalogURL)
        let counts = try writer().read { db -> [String: Int] in
            var counts: [String: Int] = [:]
            for table in expectedCounts.keys where try db.tableExists(table) {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? -1
            }
            let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check").joined(separator: "; ")
            guard integrity == "ok" else {
                throw ToolkitError.commandFailed("The restored catalog failed integrity_check: \(integrity)")
            }
            return counts
        }
        for (table, expected) in expectedCounts where counts[table] != expected {
            throw ToolkitError.commandFailed("The restored catalog has \(counts[table] ?? -1) \(table) rows; the backup had \(expected).")
        }
    }

    // MARK: - Helpers

    private func refuseIfAppRunning() throws {
        if isAppRunning() {
            throw ToolkitError.commandFailed("Camera Toolkit is running. Quit it first (it checkpoints the catalog on quit). Nothing was changed.")
        }
    }

    private func unfinishedJournals() throws -> [URL] {
        LayoutMigrationDisk.names(in: migrationsFolder.path, fileManager: fileManager).compactMap { name -> URL? in
            let url = migrationsFolder.appendingPathComponent(name, isDirectory: true).appendingPathComponent("journal.json")
            guard let journal = try? LayoutMigrationJournal.read(url) else { return nil }
            return journal.phase == .completed || journal.phase == .undone ? nil : url
        }
    }

    private func readPlan(beside journalURL: URL, journal: LayoutMigrationJournal) throws -> LayoutMigrationPlan {
        let url = journalURL.deletingLastPathComponent().appendingPathComponent("plan.json")
        let data = try Data(contentsOf: url)
        guard LayoutMigrationHash.sha256(data) == journal.planDigest else {
            throw ToolkitError.commandFailed("\(url.path) is not the plan this journal recorded (checksum differs). Nothing was changed.")
        }
        let plan = try LayoutMigrationPlan.read(url)
        guard plan.catalogPath == catalogURL.path else {
            throw ToolkitError.commandFailed("The journal belongs to the catalog at \(plan.catalogPath), not \(catalogURL.path).")
        }
        return plan
    }

    private func save(_ journal: inout LayoutMigrationJournal, to url: URL) throws {
        journal.updatedAt = now()
        try LayoutMigrationJournal.write(journal, to: url)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
