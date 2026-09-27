import Darwin
import Foundation
import GRDB

public struct NASLayoutMigrationReport: Sendable {
    public var succeeded: Bool
    public var phase: NASLayoutMigrationJournal.Phase?
    public var journalURL: URL?
    public var lines: [String]

    public var text: String { lines.joined(separator: "\n") }
}

/// Runs a reviewed `NASLayoutMigrationPlan` on the NAS, resumes one, or
/// undoes one. Server-side renames only — no byte is copied.
///
/// Order, each step proven before the next:
/// 1. refuse while Camera Toolkit runs or another migration holds the lock;
///    re-plan the recorded mapping and refuse when anything differs from the
///    reviewed plan (listings, sizes, modification times, catalog rows);
/// 2. a verified, pinned catalog backup;
/// 3. the journal, before the first rename;
/// 4. per event folder: exclusive renames (`RENAME_EXCL`, or a check that
///    the destination is free and then a rename where SMB answers
///    `ENOTSUP`), an optional sampled SHA-256 before and after, then a
///    re-listing of every destination and source folder proving each file
///    is at its destination with its size and modification time and gone
///    from its source (file ids are not stable over SMB). A rename that
///    fails is recorded and skipped; the run stops before the catalog until
///    a resume has moved it too;
/// 5. one catalog transaction with every path rewrite, checked before it
///    commits;
/// 6. the capture-date cache, then `rmdir` of source folders the renames
///    emptied — never a delete of anything with content.
public final class NASLayoutMigrationExecutor {
    public static let markerKey = "nasLayoutMigration"
    /// Largest file the sampled hash picks when an event has smaller ones.
    public static let sampleByteLimit: Int64 = 1 << 30

    public struct Hooks {
        public var afterJournal: (() throws -> Void)?
        public var afterMove: ((Int) throws -> Void)?
        public var afterEvent: ((String) throws -> Void)?
        public var afterMoves: (() throws -> Void)?
        public var beforeCatalogValidation: ((Database) throws -> Void)?
        public var afterCatalogCommit: (() throws -> Void)?

        public init(
            afterJournal: (() throws -> Void)? = nil,
            afterMove: ((Int) throws -> Void)? = nil,
            afterEvent: ((String) throws -> Void)? = nil,
            afterMoves: (() throws -> Void)? = nil,
            beforeCatalogValidation: ((Database) throws -> Void)? = nil,
            afterCatalogCommit: (() throws -> Void)? = nil
        ) {
            self.afterJournal = afterJournal
            self.afterMove = afterMove
            self.afterEvent = afterEvent
            self.afterMoves = afterMoves
            self.beforeCatalogValidation = beforeCatalogValidation
            self.afterCatalogCommit = afterCatalogCommit
        }
    }

    public let supportFolder: URL
    public let configurationURL: URL
    public let catalogURL: URL?
    public let configuration: AppConfiguration
    /// Files per event hashed before and after their rename.
    public let verifySamples: Int
    private let isAppRunning: () -> Bool
    private let hooks: Hooks
    private let now: () -> Date
    private let log: (String) -> Void

    public init(
        supportFolder: URL,
        configurationURL: URL,
        catalogURL: URL?,
        configuration: AppConfiguration,
        verifySamples: Int = 2,
        isAppRunning: @escaping () -> Bool,
        hooks: Hooks = Hooks(),
        now: @escaping () -> Date = { Date() },
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.supportFolder = supportFolder.standardizedFileURL
        self.configurationURL = configurationURL.standardizedFileURL
        self.catalogURL = catalogURL?.standardizedFileURL
        self.configuration = configuration
        self.verifySamples = max(verifySamples, 0)
        self.isAppRunning = isAppRunning
        self.hooks = hooks
        self.now = now
        self.log = log
    }

    var migrationsFolder: URL { NASLayoutMigrationJournal.folder(supportFolder: supportFolder) }

    private var catalogExists: Bool {
        catalogURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    // MARK: - Execute

    public func execute(_ plan: NASLayoutMigrationPlan) throws -> NASLayoutMigrationReport {
        guard plan.isExecutable else {
            throw ToolkitError.commandFailed("The plan is not executable:\n- " + plan.blockers.joined(separator: "\n- "))
        }
        try refuseIfAppRunning()
        let lock = try LayoutMigrationLock(folder: migrationsFolder)
        defer { _ = lock }
        guard plan.supportFolderPath == supportFolder.path, plan.catalogPath == catalogURL?.path else {
            throw ToolkitError.commandFailed("The plan was made for \(plan.catalogPath ?? "no catalog") in \(plan.supportFolderPath). Nothing was changed.")
        }
        if let unfinished = unfinishedJournals().first {
            throw ToolkitError.commandFailed("An earlier NAS migration is not finished: \(unfinished.path). Resume it (--resume) or undo it (--undo) first. Nothing was changed.")
        }
        let problems = try verifyUnchanged(plan)
        guard problems.isEmpty else {
            throw ToolkitError.commandFailed(
                "The NAS or the catalog changed since the plan was made — make a new plan. Nothing was changed.\n- "
                    + problems.prefix(20).joined(separator: "\n- ")
            )
        }

        var backupID: String?
        var backupPath: String?
        var backupCounts: [String: Int] = [:]
        if catalogExists, let catalogURL {
            let backup = try CatalogBackupService(
                catalogURL: catalogURL,
                configurationURL: configurationURL,
                localFolder: supportFolder.appendingPathComponent("Backups", isDirectory: true),
                remoteFolder: nil
            ).backupNow(reason: .migration, pinned: true, mirrorToRemote: false)
            guard let file = backup.catalogURL, FileManager.default.fileExists(atPath: file.path) else {
                throw ToolkitError.commandFailed("The catalog backup did not produce a file. Nothing was changed.")
            }
            backupID = backup.manifest.id
            backupPath = file.path
            backupCounts = backup.manifest.tableCounts
            log("Catalog backup \(backup.manifest.id) verified: \(file.path)")
        }

        let folder = migrationsFolder.appendingPathComponent("\(LayoutMigrationExecutor.stamp(now()))-\(plan.id.uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let planData = try plan.jsonData()
        try LayoutMigrationDurable.writeNew(planData, to: folder.appendingPathComponent("plan.json"))
        var journal = NASLayoutMigrationJournal(
            format: NASLayoutMigrationJournal.formatName,
            version: NASLayoutMigrationJournal.currentVersion,
            id: UUID(),
            planID: plan.id,
            planDigest: LayoutMigrationHash.sha256(planData),
            createdAt: now(),
            updatedAt: now(),
            phase: .prepared,
            backupID: backupID,
            backupCatalogPath: backupPath,
            backupTableCounts: backupCounts,
            verifiedEvents: [],
            failedMoves: [],
            sampleChecks: [],
            createdDirectories: [],
            removedDirectories: [],
            keptDirectories: [],
            catalogCommittedAt: nil,
            postCommitCatalogDigest: nil,
            captureDateBackupPath: nil,
            captureDateKeysRewritten: 0,
            undoSafetyBackupID: nil,
            lastError: nil,
            notes: []
        )
        let journalURL = folder.appendingPathComponent("journal.json")
        try NASLayoutMigrationJournal.write(journal, to: journalURL)
        log("Journal: \(journalURL.path)")
        try hooks.afterJournal?()
        return try run(plan: plan, journal: &journal, journalURL: journalURL)
    }

    // MARK: - Resume

    public func resume(journalURL: URL) throws -> NASLayoutMigrationReport {
        try refuseIfAppRunning()
        let lock = try LayoutMigrationLock(folder: migrationsFolder)
        defer { _ = lock }
        var journal = try NASLayoutMigrationJournal.read(journalURL)
        let plan = try readPlan(beside: journalURL, journal: journal)
        switch journal.phase {
        case .completed, .undone:
            return .init(succeeded: true, phase: journal.phase, journalURL: journalURL, lines: ["Nothing to resume: the migration is \(journal.phase.rawValue)."])
        case .undoing:
            throw ToolkitError.commandFailed("An undo of this migration was interrupted. Run --undo again to finish it.")
        case .prepared, .moving, .movesVerified:
            if catalogExists, try catalogMarker() != plan.id, try currentCatalogDigest() != plan.fingerprint.catalogDigest {
                throw ToolkitError.commandFailed("The catalog changed since the migration started (and it was not this migration). Undo instead (--undo).")
            }
        case .catalogCommitted:
            break
        }
        log("Resuming from \(journal.phase.rawValue).")
        return try run(plan: plan, journal: &journal, journalURL: journalURL)
    }

    private func run(plan: NASLayoutMigrationPlan, journal: inout NASLayoutMigrationJournal, journalURL: URL) throws -> NASLayoutMigrationReport {
        var lines: [String] = []
        do {
            if journal.phase == .prepared || journal.phase == .moving {
                try moveFiles(plan: plan, journal: &journal, journalURL: journalURL)
                guard journal.failedMoves.isEmpty else {
                    lines.append("Moved and verified every other file; \(journal.failedMoves.count) could not be moved and were skipped:")
                    lines += journal.failedMoves.prefix(30).map { "  - \($0.source): \($0.reason)" }
                    if journal.failedMoves.count > 30 { lines.append("  … and \(journal.failedMoves.count - 30) more (see the journal)") }
                    lines.append("The catalog is untouched. Fix them and run --resume, or run --undo to put everything back. Journal: \(journalURL.path)")
                    return .init(succeeded: false, phase: journal.phase, journalURL: journalURL, lines: lines)
                }
                journal.phase = .movesVerified
                try save(&journal, to: journalURL)
                lines.append("Renamed and verified \(plan.summary.files) files in \(plan.events.count) event folders.")
                try hooks.afterMoves?()
            }
            if journal.phase == .movesVerified {
                if catalogExists {
                    if try catalogMarker() == plan.id {
                        journal.notes.append("The catalog commit had landed before the interruption; it was not repeated.")
                    } else {
                        try commitCatalog(plan: plan)
                    }
                    journal.postCommitCatalogDigest = try currentCatalogDigest()
                }
                journal.catalogCommittedAt = now()
                journal.phase = .catalogCommitted
                try save(&journal, to: journalURL)
                lines.append("Catalog: \(plan.catalog.facePhotoRewrites.count) face photo rows, \(plan.catalog.syncRecordRewrites.count) sync records, \((plan.catalog.assignmentRewrites ?? []).count) assignments and \((plan.catalog.eventRenames ?? []).count) event renames rewritten and verified.")
                try hooks.afterCatalogCommit?()
            }
            if journal.phase == .catalogCommitted {
                rewriteCaptureDates(plan: plan, journal: &journal, journalURL: journalURL)
                removeEmptiedFolders(plan: plan, journal: &journal)
                journal.phase = .completed
                try save(&journal, to: journalURL)
                lines.append("Removed \(journal.removedDirectories.count) emptied legacy folders; kept \(journal.keptDirectories.count) that still hold something.")
                for kept in journal.keptDirectories.prefix(30) { lines.append("  kept \(kept.path) — \(kept.reason)") }
            }
        } catch {
            journal.lastError = error.localizedDescription
            try? save(&journal, to: journalURL)
            lines.append("STOPPED at \(journal.phase.rawValue): \(error.localizedDescription)")
            lines.append("Journal: \(journalURL.path) — run --resume to continue from the last proven step or --undo to put everything back.")
            return .init(succeeded: false, phase: journal.phase, journalURL: journalURL, lines: lines)
        }
        lines.append("NAS layout migration complete. Journal: \(journalURL.path)")
        lines.append("Undo with: --migrate-nas-layout --undo \"\(journalURL.path)\"")
        return .init(succeeded: true, phase: journal.phase, journalURL: journalURL, lines: lines)
    }

    // MARK: - Moves

    enum MoveState: Equatable {
        case pending
        case done
        case conflict(String)
    }

    /// Where one planned file is now, by size and modification time.
    static func state(of move: NASLayoutMigrationPlan.Move) -> MoveState {
        let source = LayoutMigrationDisk.lstatEntry(move.source)
        let destination = LayoutMigrationDisk.lstatEntry(move.destination)
        func matches(_ entry: LayoutMigrationEntry?) -> Bool {
            entry.map { $0.kind == .file && $0.size == move.byteCount && abs($0.modifiedAt - move.modifiedAt) < 2 } ?? false
        }
        switch (source, destination) {
        case (_?, nil) where matches(source): return .pending
        case (nil, _?) where matches(destination): return .done
        case (nil, nil): return .conflict("\(move.source) is at neither its source nor its destination")
        case (_?, _?): return .conflict("both \(move.source) and \(move.destination) exist")
        default: return .conflict("\(source == nil ? move.destination : move.source) is not the planned file (size or modification time differs)")
        }
    }

    private func moveFiles(plan: NASLayoutMigrationPlan, journal: inout NASLayoutMigrationJournal, journalURL: URL) throws {
        if journal.phase == .prepared {
            journal.phase = .moving
            try save(&journal, to: journalURL)
        }
        journal.failedMoves = []
        let moveLog = try LayoutMigrationMoveLog(url: journalURL.deletingLastPathComponent().appendingPathComponent("moves.log"))
        var completed = 0
        var created = Set(journal.createdDirectories)
        for event in plan.events where !journal.verifiedEvents.contains(event.id) {
            let order = event.moves.indices.filter { event.moves[$0].companionOf == nil }
                + event.moves.indices.filter { event.moves[$0].companionOf != nil }
            let samples = sampleIndices(event)
            var failed = Set<Int>()
            for index in order {
                let move = event.moves[index]
                if let file = move.companionOf, failed.contains(file) {
                    failed.insert(index)
                    continue
                }
                switch Self.state(of: move) {
                case .done:
                    continue
                case .conflict(let reason):
                    failed.insert(index)
                    journal.failedMoves.append(.init(eventID: event.id, index: index, source: move.source, reason: reason))
                    continue
                case .pending:
                    break
                }
                do {
                    for directory in try NASFileIO.makeDirectories((move.destination as NSString).deletingLastPathComponent)
                    where created.insert(directory).inserted {
                        journal.createdDirectories.append(directory)
                        moveLog.append("mkdir\t\(directory)")
                    }
                    var before: String?
                    if samples.contains(index) {
                        do {
                            before = try NASFileIO.sha256(move.source, uncached: true, expectedByteCount: move.byteCount)
                        } catch {
                            journal.notes.append("Sample hash of \(move.source) skipped: \(error.localizedDescription)")
                        }
                    }
                    try NASFileIO.renameExclusive(from: move.source, to: move.destination)
                    moveLog.append("done\t\(event.id)\t\(index)")
                    if let before {
                        let after = try? NASFileIO.sha256(move.destination, uncached: true, expectedByteCount: move.byteCount)
                        journal.sampleChecks.append(.init(path: move.destination, sha256Before: before, sha256After: after))
                        if let after, after != before {
                            throw SampleMismatch(path: move.destination)
                        }
                    }
                } catch let mismatch as SampleMismatch {
                    throw ToolkitError.commandFailed("\(mismatch.path) reads back different bytes after its rename. Stopped; check the NAS pool before going on.")
                } catch {
                    failed.insert(index)
                    journal.failedMoves.append(.init(eventID: event.id, index: index, source: move.source, reason: error.localizedDescription))
                    continue
                }
                completed += 1
                try hooks.afterMove?(completed)
            }
            moveLog.sync()
            // Prove the event: one listing per destination and source folder.
            try verify(event: event, skipping: failed)
            if failed.isEmpty {
                journal.verifiedEvents.append(event.id)
            }
            try save(&journal, to: journalURL)
            log("Verified \(event.id) \(event.source) → \(event.destination) (\(event.moves.count - failed.count) of \(event.moves.count) files)")
            try hooks.afterEvent?(event.id)
        }
    }

    private struct SampleMismatch: Error { var path: String }

    /// Up to `verifySamples` media files per event, spread over the event.
    private func sampleIndices(_ event: NASLayoutMigrationPlan.Event) -> Set<Int> {
        let allMedia = event.moves.indices.filter { event.moves[$0].kind == .media && event.moves[$0].companionOf == nil }
        // Up to 1 GiB each where the event has such files: a rename moves no
        // bytes, and a sample of a 17 GB clip would cost minutes over SMB.
        let small = allMedia.filter { event.moves[$0].byteCount <= Self.sampleByteLimit }
        let media = small.isEmpty ? Array(allMedia.sorted { event.moves[$0].byteCount < event.moves[$1].byteCount }.prefix(1)) : small
        guard verifySamples > 0, !media.isEmpty else { return [] }
        let count = min(verifySamples, media.count)
        return Set((0..<count).map { media[($0 * media.count) / count] })
    }

    /// Every moved file is listed at its destination with its planned size
    /// and modification time, and no longer listed at its source.
    private func verify(event: NASLayoutMigrationPlan.Event, skipping failed: Set<Int>) throws {
        var listings: [String: [String: DirectoryListingEntry]] = [:]
        func listing(_ folder: String) -> [String: DirectoryListingEntry] {
            if let cached = listings[folder] { return cached }
            let entries = (try? DirectoryListing.list(folder)) ?? []
            let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            listings[folder] = byName
            return byName
        }
        var problems: [String] = []
        for (index, move) in event.moves.enumerated() where !failed.contains(index) {
            let destination = listing((move.destination as NSString).deletingLastPathComponent)[(move.destination as NSString).lastPathComponent]
            if destination?.kind != .file || destination?.size != move.byteCount
                || abs((destination?.modifiedAt ?? 0) - move.modifiedAt) >= 2 {
                problems.append("\(move.destination) is not there with its size and modification time")
            }
            if listing((move.source as NSString).deletingLastPathComponent)[(move.source as NSString).lastPathComponent] != nil {
                problems.append("\(move.source) is still at its source")
            }
        }
        guard problems.isEmpty else {
            throw ToolkitError.commandFailed("Verification of \(event.source) failed:\n- " + problems.prefix(20).joined(separator: "\n- "))
        }
    }

    // MARK: - Fingerprint

    /// Re-plans the recorded mapping; anything that differs from the
    /// reviewed plan is a problem.
    func verifyUnchanged(_ plan: NASLayoutMigrationPlan) throws -> [String] {
        let replanned = try NASLayoutMigrationPlanner(now: now).plan(.init(
            mapping: plan.mapping,
            configuration: configuration,
            supportFolder: supportFolder,
            configurationURL: configurationURL,
            catalogURL: catalogURL
        ))
        var problems = replanned.blockers
        if replanned.fingerprint.catalogDigest != plan.fingerprint.catalogDigest {
            problems.append("the catalog's face photos, rotations, burst splits or sync records changed")
        }
        for (folder, digest) in plan.fingerprint.folderListings.sorted(by: { $0.key < $1.key })
        where replanned.fingerprint.folderListings[folder] != digest {
            problems.append("the contents of \(folder) changed")
        }
        if replanned.events != plan.events {
            problems.append("the planned renames differ (a destination was taken or a file changed)")
        }
        if !replanned.unreadable.isEmpty, replanned.unreadable != plan.unreadable {
            problems.append("\(replanned.unreadable.count) folder(s) are unreadable now")
        }
        return problems
    }

    // MARK: - Catalog

    private func writer() throws -> any DatabaseWriter {
        guard let catalogURL else { throw ToolkitError.commandFailed("There is no catalog.") }
        return try CatalogDatabase.writer(for: catalogURL)
    }

    func currentCatalogDigest() throws -> String? {
        guard catalogExists else { return nil }
        return try writer().read { try NASLayoutMigrationCatalog.digest(database: $0) }
    }

    func catalogMarker() throws -> UUID? {
        guard catalogExists else { return nil }
        return try writer().read { db -> UUID? in
            guard try db.tableExists("app_state"),
                  let value = try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = ?", arguments: [Self.markerKey]),
                  let data = value.data(using: .utf8),
                  let marker = try? JSONDecoder().decode(LayoutMigrationExecutor.Marker.self, from: data) else { return nil }
            return marker.planID
        }
    }

    private func commitCatalog(plan: NASLayoutMigrationPlan) throws {
        let changes = plan.catalog
        let nowText = ISO8601DateFormatter().string(from: now())
        try writer().write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            guard try NASLayoutMigrationCatalog.digest(database: db) == plan.fingerprint.catalogDigest else {
                throw ToolkitError.commandFailed("The catalog changed since the plan was made; nothing was written to it.")
            }
            var countsBefore: [String: Int] = [:]
            for table in LayoutMigrationCatalog.countedTables + [NASSyncStore.tableName] where try db.tableExists(table) {
                countsBefore[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
            }
            let violationsBefore = Set(try CatalogStateStore.foreignKeyViolations(db))
            let confirmedBefore = try db.tableExists("faces") ? try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM faces WHERE state = 'confirmed'") ?? 0 : 0
            let temporary = "nas-layout-migration-tmp|"
            // Assignments whose source is a moved NAS file: two steps
            // through a temporary id; presence and Immich rows follow.
            let assignmentRewrites = changes.assignmentRewrites ?? []
            for rewrite in assignmentRewrites {
                try db.execute(
                    sql: "UPDATE event_assets SET id = ?, source_root_path = ?, relative_path = ?, updated_at = ? WHERE id = ?",
                    arguments: [temporary + rewrite.newID, rewrite.newSourceRootPath, rewrite.newRelativePath, nowText, rewrite.oldID]
                )
                guard db.changesCount == 1 else {
                    throw ToolkitError.commandFailed("Assignment \(rewrite.oldID) was not found; nothing was written to the catalog.")
                }
                for table in ["event_asset_locations", "immich_assets"] where try db.tableExists(table) {
                    try db.execute(sql: "UPDATE \(table) SET event_asset_id = ? WHERE event_asset_id = ?", arguments: [temporary + rewrite.newID, rewrite.oldID])
                }
            }
            for rewrite in assignmentRewrites {
                try db.execute(sql: "UPDATE event_assets SET id = ? WHERE id = ?", arguments: [rewrite.newID, temporary + rewrite.newID])
                for table in ["event_asset_locations", "immich_assets"] where try db.tableExists(table) {
                    try db.execute(sql: "UPDATE \(table) SET event_asset_id = ? WHERE event_asset_id = ?", arguments: [rewrite.newID, temporary + rewrite.newID])
                }
            }
            // Catalog event renames, through the store the app writes
            // events with: only the renamed events' rows change.
            let renames = changes.eventRenames ?? []
            if !renames.isEmpty {
                let stateBefore = try CatalogStateStore.load(db)
                var stateAfter = stateBefore
                for rename in renames {
                    guard let index = stateAfter.savedEvents.firstIndex(where: { $0.id == rename.eventID }),
                          stateAfter.savedEvents[index].name == rename.oldName else {
                        throw ToolkitError.commandFailed("The catalog event \(rename.oldName) changed; nothing was written to the catalog.")
                    }
                    stateAfter.savedEvents[index].name = rename.newName
                }
                let written = try CatalogStateStore.write(from: stateBefore, to: stateAfter, database: db)
                guard written.eventsWritten == renames.count, written.eventsDeleted == 0, written.assignmentsWritten == 0,
                      written.assignmentsDeleted == 0 else {
                    throw ToolkitError.commandFailed("The event renames touched more than the renamed events; nothing was written to the catalog.")
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
            for rewrite in changes.syncRecordRewrites {
                try db.execute(
                    sql: "UPDATE nas_sync_files SET path_key = ?, relative_path = ? WHERE nas_root = ? AND path_key = ?",
                    arguments: [temporary + NASSyncStore.pathKey(rewrite.newRelativePath), rewrite.newRelativePath, rewrite.nasRoot, rewrite.oldPathKey]
                )
                guard db.changesCount == 1 else {
                    throw ToolkitError.commandFailed("Sync record \(rewrite.oldPathKey) was not found; nothing was written to the catalog.")
                }
            }
            for rewrite in changes.syncRecordRewrites {
                try db.execute(
                    sql: "UPDATE nas_sync_files SET path_key = ? WHERE nas_root = ? AND path_key = ?",
                    arguments: [NASSyncStore.pathKey(rewrite.newRelativePath), rewrite.nasRoot, temporary + NASSyncStore.pathKey(rewrite.newRelativePath)]
                )
            }
            let marker = String(decoding: try JSONEncoder().encode(LayoutMigrationExecutor.Marker(planID: plan.id, committedAt: nowText)), as: UTF8.self)
            try db.execute(
                sql: """
                INSERT INTO app_state(key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """,
                arguments: [Self.markerKey, marker, nowText]
            )
            try hooks.beforeCatalogValidation?(db)

            var failures: [String] = []
            for (table, before) in countsBefore {
                let after = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? -1
                let expected = table == "display_orientations" ? before + changes.orientationCopies.count : before
                if after != expected { failures.append("\(table) has \(after) rows, \(expected) expected") }
            }
            let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check").joined(separator: "; ")
            if integrity != "ok" { failures.append("integrity_check: \(integrity)") }
            let introduced = try CatalogStateStore.foreignKeyViolations(db).filter { !violationsBefore.contains($0) }
            if !introduced.isEmpty { failures.append("new foreign-key violations: \(introduced.prefix(5).joined(separator: ", "))") }
            if try db.tableExists("faces") {
                let confirmedAfter = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM faces WHERE state = 'confirmed'") ?? -1
                if confirmedAfter != confirmedBefore { failures.append("\(confirmedAfter) confirmed faces, \(confirmedBefore) before") }
            }
            for rewrite in changes.facePhotoRewrites {
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM face_photos WHERE path_key = ?", arguments: [rewrite.newPathKey]) != 1 {
                    failures.append("face photo \(rewrite.newPathKey) is missing")
                }
                if LayoutMigrationDisk.lstatEntry(rewrite.newPath)?.kind != .file {
                    failures.append("face photo \(rewrite.newPath) points at a file that is not there")
                }
            }
            for rewrite in assignmentRewrites {
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_assets WHERE id = ?", arguments: [rewrite.newID]) != 1 {
                    failures.append("assignment \(rewrite.newID) is missing")
                }
            }
            if !renames.isEmpty {
                // The app computes each renamed event's NAS folder from the
                // catalog as it now reads.
                let state = try CatalogStateStore.load(db)
                var configuration = self.configuration
                configuration.savedEvents = state.savedEvents
                let locations = EventStorageLocations(configuration: configuration)
                for rename in renames {
                    guard let event = state.savedEvents.first(where: { $0.id == rename.eventID }) else {
                        failures.append("event \(rename.eventID) is missing")
                        continue
                    }
                    if event.name != rename.newName { failures.append("event \(rename.eventID) is named \(event.name), not \(rename.newName)") }
                    let folder = locations.layout(for: event, deviceID: nil).mirrorEventFolderPath
                    if folder != rename.newMirrorFolder { failures.append("event \(rename.newName) resolves to \(folder), not \(rename.newMirrorFolder)") }
                }
            }
            // Relative paths made portable: the app, reading the catalog as
            // it now is, must compute each file's NAS path as the moved file.
            let portable = assignmentRewrites.filter {
                $0.oldSourceRootPath == $0.newSourceRootPath && $0.oldRelativePath != $0.newRelativePath
            }
            if !portable.isEmpty {
                let state = try CatalogStateStore.load(db)
                var configuration = self.configuration
                configuration.savedEvents = state.savedEvents
                let locations = EventStorageLocations(configuration: configuration)
                let byID = Dictionary(state.photoEventAssignments.map { (CatalogStore.eventAssetID($0), $0) }, uniquingKeysWith: { first, _ in first })
                for rewrite in portable {
                    guard let assignment = byID[rewrite.newID],
                          let event = state.savedEvents.first(where: { $0.id == assignment.eventID }),
                          let archive = locations.archiveURL(for: assignment, event: event) else {
                        failures.append("assignment \(rewrite.newID) does not resolve to a NAS path")
                        continue
                    }
                    if archive.path != rewrite.destination {
                        failures.append("assignment \(rewrite.newRelativePath) resolves to \(archive.path), not \(rewrite.destination)")
                    }
                }
            }
            guard failures.isEmpty else {
                throw ToolkitError.commandFailed("The catalog rewrite failed its checks and was rolled back:\n- " + failures.joined(separator: "\n- "))
            }
        }
        if let catalogURL { CatalogDatabase.checkpointAndClose(url: catalogURL) }
    }

    // MARK: - Stores and folders

    private func rewriteCaptureDates(plan: NASLayoutMigrationPlan, journal: inout NASLayoutMigrationJournal, journalURL: URL) {
        let captureURL = LayoutMigrationPlanner.captureDateCacheURL(supportFolder: supportFolder)
        guard journal.captureDateBackupPath == nil, FileManager.default.fileExists(atPath: captureURL.path) else { return }
        let backupURL = journalURL.deletingLastPathComponent().appendingPathComponent("capture-dates.before.json")
        do {
            if !FileManager.default.fileExists(atPath: backupURL.path) {
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
    }

    private func removeEmptiedFolders(plan: NASLayoutMigrationPlan, journal: inout NASLayoutMigrationJournal) {
        var removed = Set(journal.removedDirectories)
        // Every event's folders together, deepest first: a parent shared by
        // two events is tried only after both emptied their folders.
        let all = Set(plan.events.flatMap(\.sourceDirectories) + (plan.sourceDirectories ?? [])).sorted {
            let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
            return a == b ? $0 > $1 : a > b
        }
        do {
            for path in all where !removed.contains(path) {
                guard LayoutMigrationDisk.lstatEntry(path)?.kind == .directory else { continue }
                if rmdir(path) == 0 {
                    journal.removedDirectories.append(path)
                    removed.insert(path)
                } else {
                    let code = errno
                    let names = LayoutMigrationDisk.names(in: path, fileManager: .default)
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

    public func undo(journalURL: URL) throws -> NASLayoutMigrationReport {
        try refuseIfAppRunning()
        let lock = try LayoutMigrationLock(folder: migrationsFolder)
        defer { _ = lock }
        var journal = try NASLayoutMigrationJournal.read(journalURL)
        let plan = try readPlan(beside: journalURL, journal: journal)
        if journal.phase == .undone {
            return .init(succeeded: true, phase: .undone, journalURL: journalURL, lines: ["Already undone."])
        }
        var lines: [String] = []
        let committed = try catalogMarker() == plan.id
        if committed, journal.phase != .undoing, let expected = journal.postCommitCatalogDigest, try currentCatalogDigest() != expected {
            throw ToolkitError.commandFailed(
                "The catalog changed after the migration. Restoring the pre-migration backup would discard those changes, so nothing was undone. Restore by hand from \(journal.backupCatalogPath ?? "the backup") if that is what you want."
            )
        }
        journal.phase = .undoing
        journal.lastError = nil
        try save(&journal, to: journalURL)

        if committed, let catalogURL, let backupPath = journal.backupCatalogPath {
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
            try LayoutMigrationExecutor.restoreCatalog(catalogURL: catalogURL, from: URL(fileURLWithPath: backupPath), expectedCounts: journal.backupTableCounts)
            guard try currentCatalogDigest() == plan.fingerprint.catalogDigest else {
                throw ToolkitError.commandFailed("The restored catalog does not match the pre-migration state the plan recorded. Stopped; the files were not moved back.")
            }
            lines.append("Catalog restored from backup \(journal.backupID ?? "?") and verified against the plan.")
        }
        if let backup = journal.captureDateBackupPath, FileManager.default.fileExists(atPath: backup) {
            try LayoutMigrationDurable.write(
                try Data(contentsOf: URL(fileURLWithPath: backup)),
                to: LayoutMigrationPlanner.captureDateCacheURL(supportFolder: supportFolder)
            )
            lines.append("capture-dates.json restored.")
        }
        for directory in journal.removedDirectories.reversed() where !LayoutMigrationDisk.exists(directory) {
            _ = try NASFileIO.makeDirectories(directory)
        }
        var failures: [String] = []
        var movedBack = 0
        for event in plan.events.reversed() {
            let order = event.moves.indices.reversed().filter { event.moves[$0].companionOf == nil }
                + event.moves.indices.reversed().filter { event.moves[$0].companionOf != nil }
            for index in order {
                let move = event.moves[index]
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
                    _ = try NASFileIO.makeDirectories((move.source as NSString).deletingLastPathComponent)
                    try NASFileIO.renameExclusive(from: move.destination, to: move.source)
                    movedBack += 1
                } catch {
                    failures.append("\(move.destination): \(error.localizedDescription)")
                }
            }
        }
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
            return .init(succeeded: false, phase: .undoing, journalURL: journalURL, lines: lines)
        }
        journal.phase = .undone
        try save(&journal, to: journalURL)
        lines.append("Undo complete. Every planned file is back at its original path.")
        return .init(succeeded: true, phase: .undone, journalURL: journalURL, lines: lines)
    }

    // MARK: - Helpers

    private func refuseIfAppRunning() throws {
        if isAppRunning() {
            throw ToolkitError.commandFailed("Camera Toolkit is running. Quit it first (it checkpoints the catalog on quit). Nothing was changed.")
        }
    }

    private func unfinishedJournals() -> [URL] {
        LayoutMigrationDisk.names(in: migrationsFolder.path, fileManager: .default).compactMap { name -> URL? in
            let url = migrationsFolder.appendingPathComponent(name, isDirectory: true).appendingPathComponent("journal.json")
            guard let journal = try? NASLayoutMigrationJournal.read(url) else { return nil }
            return journal.phase == .completed || journal.phase == .undone ? nil : url
        }
    }

    private func readPlan(beside journalURL: URL, journal: NASLayoutMigrationJournal) throws -> NASLayoutMigrationPlan {
        let url = journalURL.deletingLastPathComponent().appendingPathComponent("plan.json")
        let data = try Data(contentsOf: url)
        guard LayoutMigrationHash.sha256(data) == journal.planDigest else {
            throw ToolkitError.commandFailed("\(url.path) is not the plan this journal recorded (checksum differs). Nothing was changed.")
        }
        let plan = try NASLayoutMigrationPlan.read(url)
        guard plan.catalogPath == catalogURL?.path else {
            throw ToolkitError.commandFailed("The journal belongs to the catalog at \(plan.catalogPath ?? "none"), not \(catalogURL?.path ?? "none").")
        }
        return plan
    }

    private func save(_ journal: inout NASLayoutMigrationJournal, to url: URL) throws {
        journal.updatedAt = now()
        try NASLayoutMigrationJournal.write(journal, to: url)
    }
}
