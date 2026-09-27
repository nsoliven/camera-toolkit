@testable import CameraToolkitCore
import Darwin
import Foundation
import GRDB
import XCTest

/// A synthetic NAS in the legacy archive layout:
///
/// ```
/// NAS/Originals/2026/2026-07-01 Road Trip/
///   Sony-A7V/RAW/DSC0001.ARW, DSC0001.XMP (+ ._DSC0001.ARW), JPEG/DSC0001.JPG, Proxy/P0001.MP4
///   Sony A7V/RAW/DSC0001.ARW, DSC0001.XMP   a different DSC0001 from a second folder → "(2)"
///   DJI Osmo 360/Video/CAM_0001.OSV, Camera Support/CAM_0001.LRF, Photos/IMG_0001.DNG
///   DJI Nano/Video/Day 1/DJI_0001.MP4       a subfolder below a media folder is kept
///   Action-6/Saved Clips/AC_0001.MP4, DJI-Mini-2/Video/DJI_0002.MP4
///   Odd Cam/RAW/X0001.ARW                   unknown camera → kept verbatim
///   notes.txt, .DS_Store
///   2026-07-02 Day Two/Sony A7V/RAW/DSC0100.ARW   its own mapping entry
///   2026-07-03 Unlisted/…                   not in the mapping → left in place
/// NAS/Originals/2026/2026-08_Odd-Name/Sony A7V/RAW/DSC0200.ARW   renamed by the mapping
/// NAS/2026/2026-07-01 Road Trip/Originals/Osmo 360/CAM_0001.OSV  already synced → "(2)"
/// ```
final class NASLayoutMigrationTests: XCTestCase {
    override func tearDown() {
        NASFileIO.renameExclusivePrimitive = nil
        NASFileIO.verificationHashOverride = nil
        DirectoryListing.override = nil
        super.tearDown()
    }

    private struct Fixture {
        var root: URL
        var nas: URL
        var legacy: URL
        var support: URL
        var configurationURL: URL
        var catalogURL: URL
        var configuration: AppConfiguration
        var mapping: NASLayoutMapping
        var event: URL { legacy.appendingPathComponent("2026/2026-07-01 Road Trip") }
        var mirrorEvent: URL { nas.appendingPathComponent("2026/2026-07-01 Road Trip") }

        func planner() throws -> NASLayoutMigrationPlan {
            try NASLayoutMigrationPlanner().plan(.init(
                mapping: mapping,
                configuration: configuration,
                supportFolder: support,
                configurationURL: configurationURL,
                catalogURL: catalogURL
            ))
        }

        func executor(running: Bool = false, samples: Int = 2, hooks: NASLayoutMigrationExecutor.Hooks = .init()) -> NASLayoutMigrationExecutor {
            NASLayoutMigrationExecutor(
                supportFolder: support,
                configurationURL: configurationURL,
                catalogURL: catalogURL,
                configuration: configuration,
                verifySamples: samples,
                isAppRunning: { running },
                hooks: hooks
            )
        }
    }

    private func fixture(_ root: URL) throws -> Fixture {
        let nas = root.appendingPathComponent("NAS", isDirectory: true)
        let legacy = nas.appendingPathComponent("Originals", isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let event = legacy.appendingPathComponent("2026/2026-07-01 Road Trip")
        let files: [(String, String)] = [
            ("Sony-A7V/RAW/DSC0001.ARW", "sony raw one"),
            ("Sony-A7V/RAW/DSC0001.XMP", "sony xmp one"),
            ("Sony-A7V/RAW/._DSC0001.ARW", "apple double"),
            ("Sony-A7V/JPEG/DSC0001.JPG", "sony jpeg one"),
            ("Sony-A7V/Proxy/P0001.MP4", "proxy"),
            ("Sony A7V/RAW/DSC0001.ARW", "second card raw"),
            ("Sony A7V/RAW/DSC0001.XMP", "second card xmp"),
            ("DJI Osmo 360/Video/CAM_0001.OSV", "osmo video"),
            ("DJI Osmo 360/Camera Support/CAM_0001.LRF", "osmo lrf"),
            ("DJI Osmo 360/Photos/IMG_0001.DNG", "osmo photo"),
            ("DJI Nano/Video/Day 1/DJI_0001.MP4", "nano clip"),
            ("Action-6/Saved Clips/AC_0001.MP4", "action clip"),
            ("DJI-Mini-2/Video/DJI_0002.MP4", "mini clip"),
            ("Odd Cam/RAW/X0001.ARW", "odd raw"),
            ("notes.txt", "notes"),
            (".DS_Store", "finder"),
            ("2026-07-02 Day Two/Sony A7V/RAW/DSC0100.ARW", "day two raw"),
            ("2026-07-03 Unlisted/Sony A7V/RAW/DSC0300.ARW", "unlisted raw"),
        ]
        for (path, text) in files {
            try writeFile(event.appendingPathComponent(path), text)
        }
        try writeFile(legacy.appendingPathComponent("2026/2026-08_Odd-Name/Sony A7V/RAW/DSC0200.ARW"), "odd name raw")
        try writeFile(nas.appendingPathComponent("2026/2026-07-01 Road Trip/Originals/Osmo 360/CAM_0001.OSV"), "already synced, different")

        let catalogURL = support.appendingPathComponent("catalog.sqlite")
        var configuration = AppConfiguration.testConfiguration(root: root, catalog: catalogURL)
        configuration.cameraLibraryRootPath = nas.path
        configuration.archiveLayoutRootPath = nas.path
        let configurationURL = support.appendingPathComponent("config.json")
        try JSONEncoder().encode(configuration).write(to: configurationURL)
        try CatalogStore(url: catalogURL).prepareSchema()
        // A face photo scanned from the legacy NAS copy, with a confirmed
        // face; a sync record under the mirror root that names a legacy
        // path; a rotation on the file that will be renamed "(2)".
        let jpeg = event.appendingPathComponent("Sony-A7V/JPEG/DSC0001.JPG").standardizedFileURL.path
        let secondRaw = event.appendingPathComponent("Sony A7V/RAW/DSC0001.ARW")
        let secondRawDate = try XCTUnwrap(LayoutMigrationDisk.lstatEntry(secondRaw.path)).modifiedDate
        let secondRawSize = try XCTUnwrap(LayoutMigrationDisk.lstatEntry(secondRaw.path)).size
        let now = ISO8601DateFormatter().string(from: Date())
        try CatalogDatabase.writer(for: catalogURL).write { db in
            try db.execute(sql: "INSERT INTO people(id, name, is_roster, face_count, created_at, updated_at) VALUES ('P1', 'Person A', 1, 1, ?, ?)", arguments: [now, now])
            try db.execute(
                sql: """
                INSERT INTO face_photos(path_key, path, file_name, byte_count, modified_at, scan_grade, face_count, engine, indexed_at, updated_at)
                VALUES (?, ?, 'DSC0001.JPG', 13, ?, 'med', 1, 'insightface/buffalo_l', ?, ?)
                """,
                arguments: [EventStorageLocations.pathKey(jpeg), jpeg, now, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO faces(id, photo_id, person_id, box_x, box_y, box_w, box_h, det_score, state, created_at, updated_at)
                VALUES ('F1', ?, 'P1', 0.1, 0.1, 0.2, 0.2, 0.9, 'confirmed', ?, ?)
                """,
                arguments: [EventStorageLocations.pathKey(jpeg), now, now]
            )
            try db.execute(
                sql: "INSERT INTO display_orientations(file_key, quarter_turns, updated_at) VALUES (?, 1, ?)",
                arguments: [FaceIndexStore.fileKey(fileName: "DSC0001.ARW", byteCount: secondRawSize, modifiedAt: secondRawDate), now]
            )
        }
        let store = try NASSyncStore(catalogURL: catalogURL)
        try store.upsert([NASSyncRecord(
            nasRoot: nas.standardizedFileURL.path,
            relativePath: "Originals/2026/2026-07-01 Road Trip/notes.txt",
            byteCount: 5,
            state: .verified,
            checkedAt: Date(),
            verifiedAt: Date()
        )])
        CatalogDatabase.checkpointAndClose(url: catalogURL)

        let mapping = NASLayoutMapping(
            legacyRoot: legacy.path,
            mirrorRoot: nas.path,
            events: [
                .init(source: "2026/2026-07-01 Road Trip", destination: "2026/2026-07-01 Road Trip"),
                .init(source: "2026/2026-07-01 Road Trip/2026-07-02 Day Two", destination: "2026/2026-07-01 Road Trip/2026-07-02 Day Two"),
                .init(source: "2026/2026-08_Odd-Name", destination: "2026/2026-08-03 Proper Name"),
            ]
        )
        return Fixture(
            root: root, nas: nas, legacy: legacy, support: support,
            configurationURL: configurationURL, catalogURL: catalogURL,
            configuration: configuration, mapping: mapping
        )
    }

    /// Relative path → contents, `._` files included.
    private func tree(_ root: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        for entry in LayoutMigrationDisk.walk(root.path, fileManager: .default) where entry.kind == .file {
            result[String(entry.path.dropFirst(root.path.count + 1))] = FileManager.default.contents(atPath: entry.path)
        }
        return result
    }

    private func text(_ url: URL) -> String? {
        FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Names and mapping

    func testCameraFolderNamesNormalizeAndUnknownNamesStay() {
        for (legacy, current) in [
            ("Sony-A7V", "Sony A7V"), ("Sony A7V", "Sony A7V"), ("sony_a7v", "Sony A7V"),
            ("DJI Osmo 360", "Osmo 360"), ("Osmo-360", "Osmo 360"), ("osmo 360", "Osmo 360"),
            ("DJI Nano", "Osmo Nano"), ("DJI-Nano", "Osmo Nano"),
            ("DJI-Mini-2", "DJI Mini 2"), ("DJI Mini 2", "DJI Mini 2"),
            ("Action-6", "Osmo Action 6"), ("DJI Action 6", "Osmo Action 6"),
            ("iPhone", "iPhone"),
        ] {
            let normalized = NASCameraNames.normalized(legacy)
            XCTAssertEqual(normalized.name, current, legacy)
            XCTAssertTrue(normalized.known, legacy)
        }
        XCTAssertEqual(NASCameraNames.normalized("Odd Cam").name, "Odd Cam")
        XCTAssertFalse(NASCameraNames.normalized("Odd Cam").known)
        XCTAssertEqual(NASCameraNames.normalized("odd-cam", extra: ["Odd Cam": "Odd Camera"]).name, "Odd Camera")
    }

    func testMappingProblemsAreBlockers() throws {
        try withTemporaryDirectory { root in
            var f = try fixture(root)
            f.mapping.events.append(.init(source: "2026/2026-08_Odd-Name", destination: "../escape"))
            f.mapping.events.append(.init(source: "2026/Missing Folder", destination: "2026/2026-08-03 Proper Name"))
            let plan = try f.planner()
            XCTAssertFalse(plan.isExecutable)
            XCTAssertTrue(plan.blockers.contains { $0.contains("\"../escape\" is not a clean relative path") })
            XCTAssertTrue(plan.blockers.contains { $0.contains("listed twice") })
            XCTAssertTrue(plan.blockers.contains { $0.contains("Missing Folder") })
        }
    }

    // MARK: - Planner

    func testPlannerFlattensNormalizesResolvesCollisionsAndWritesNothing() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            // One folder that cannot be listed: reported and skipped.
            let unreadable = f.event.appendingPathComponent("DJI-Mini-2/Video")
            chmod(unreadable.path, 0)
            defer { chmod(unreadable.path, 0o755) }
            let before = tree(f.nas)

            let plan = try f.planner()
            XCTAssertEqual(tree(f.nas).keys.sorted(), before.keys.sorted(), "the dry run wrote nothing")
            XCTAssertTrue(plan.isExecutable, plan.blockers.joined(separator: "\n"))

            let moves = Dictionary(uniqueKeysWithValues: plan.allMoves.map {
                (String($0.source.dropFirst(f.legacy.path.count + 1)), String($0.destination.dropFirst(f.nas.path.count + 1)))
            })
            let e = "2026/2026-07-01 Road Trip"
            XCTAssertEqual(moves["\(e)/Sony A7V/RAW/DSC0001.ARW"], "\(e)/Originals/Sony A7V/DSC0001.ARW")
            XCTAssertEqual(moves["\(e)/Sony A7V/RAW/DSC0001.XMP"], "\(e)/Originals/Sony A7V/DSC0001.XMP")
            // The second folder that normalizes to "Sony A7V" collides and
            // its whole group, sidecar and AppleDouble twin, takes (2).
            XCTAssertEqual(moves["\(e)/Sony-A7V/RAW/DSC0001.ARW"], "\(e)/Originals/Sony A7V/DSC0001 (2).ARW")
            XCTAssertEqual(moves["\(e)/Sony-A7V/RAW/DSC0001.XMP"], "\(e)/Originals/Sony A7V/DSC0001 (2).XMP")
            XCTAssertEqual(moves["\(e)/Sony-A7V/JPEG/DSC0001.JPG"], "\(e)/Originals/Sony A7V/DSC0001 (2).JPG")
            XCTAssertEqual(moves["\(e)/Sony-A7V/RAW/._DSC0001.ARW"], "\(e)/Originals/Sony A7V/._DSC0001 (2).ARW")
            // A subfolder that is not a media folder is kept.
            XCTAssertEqual(moves["\(e)/Sony-A7V/Proxy/P0001.MP4"], "\(e)/Originals/Sony A7V/Proxy/P0001.MP4")
            // A file already synced to the mirror path: the legacy copy and
            // its sidecar take (2); the synced file is never touched.
            XCTAssertEqual(moves["\(e)/DJI Osmo 360/Video/CAM_0001.OSV"], "\(e)/Originals/Osmo 360/CAM_0001 (2).OSV")
            XCTAssertEqual(moves["\(e)/DJI Osmo 360/Camera Support/CAM_0001.LRF"], "\(e)/Originals/Osmo 360/CAM_0001 (2).LRF")
            XCTAssertEqual(moves["\(e)/DJI Osmo 360/Photos/IMG_0001.DNG"], "\(e)/Originals/Osmo 360/IMG_0001.DNG")
            XCTAssertEqual(moves["\(e)/DJI Nano/Video/Day 1/DJI_0001.MP4"], "\(e)/Originals/Osmo Nano/Day 1/DJI_0001.MP4")
            XCTAssertEqual(moves["\(e)/Action-6/Saved Clips/AC_0001.MP4"], "\(e)/Originals/Osmo Action 6/AC_0001.MP4")
            XCTAssertEqual(moves["\(e)/Odd Cam/RAW/X0001.ARW"], "\(e)/Originals/Odd Cam/X0001.ARW")
            XCTAssertEqual(moves["\(e)/notes.txt"], "\(e)/notes.txt")
            // The subevent migrates through its own entry; the mapping-driven
            // rename takes the reviewed name, never a guessed one.
            XCTAssertEqual(moves["\(e)/2026-07-02 Day Two/Sony A7V/RAW/DSC0100.ARW"], "\(e)/2026-07-02 Day Two/Originals/Sony A7V/DSC0100.ARW")
            XCTAssertEqual(moves["2026/2026-08_Odd-Name/Sony A7V/RAW/DSC0200.ARW"], "2026/2026-08-03 Proper Name/Originals/Sony A7V/DSC0200.ARW")
            XCTAssertNil(moves["\(e)/2026-07-03 Unlisted/Sony A7V/RAW/DSC0300.ARW"])
            XCTAssertNil(moves["\(e)/DJI-Mini-2/Video/DJI_0002.MP4"])
            XCTAssertNil(moves["\(e)/.DS_Store"])

            XCTAssertEqual(plan.unknownCameras.map(\.name), ["Odd Cam"])
            XCTAssertEqual(plan.unreadable.map(\.path), [unreadable.path])
            XCTAssertTrue(plan.leftInPlace.contains { $0.path.hasSuffix("2026-07-03 Unlisted") })
            XCTAssertTrue(plan.leftInPlace.contains { $0.path.hasSuffix(".DS_Store") })
            XCTAssertEqual(plan.events.first?.keptSubfolders, ["Sony-A7V/Proxy"])
            XCTAssertEqual(Set(plan.conflicts.map(\.reason)), [.claimedByAnotherFile, .travelsWithConflict, .destinationExists])
            XCTAssertEqual(plan.summary.renamedFiles, 6)

            // Catalog rows naming moved NAS paths.
            XCTAssertEqual(plan.catalog.facePhotoRewrites.map { ($0.newPath as NSString).lastPathComponent }, ["DSC0001 (2).JPG"])
            XCTAssertEqual(plan.catalog.syncRecordRewrites.map(\.newRelativePath), ["\(e)/notes.txt"])
            XCTAssertEqual(plan.catalog.orientationCopies.count, 0, "the rotated file keeps its name")
            // One listing per folder — every source folder once, every
            // destination folder once — never one call per file.
            let sourceFolders = plan.events.reduce(0) { $0 + $1.sourceDirectories.count }
            let destinationFolders = Set(plan.allMoves.map { ($0.destination as NSString).deletingLastPathComponent }).count
            XCTAssertLessThanOrEqual(plan.summary.foldersListed, sourceFolders + destinationFolders + plan.unreadable.count)

            // The plan round-trips as reviewed.
            let url = root.appendingPathComponent("plan.json")
            try plan.jsonData().write(to: url)
            XCTAssertEqual(try NASLayoutMigrationPlan.read(url).jsonData(), try plan.jsonData())
            XCTAssertEqual(try NASLayoutMigrationPlan.read(url).events, plan.events)
        }
    }

    func testACatalogEventNamedByTheMappingPutsFlattenedFilesBackInTheirSubfolders() throws {
        try withTemporaryDirectory { root in
            var f = try fixture(root)
            try writeFile(f.event.appendingPathComponent("DJI Osmo 360/Photos/IMG_0001.XMP"), "osmo photo sidecar")
            let event = SavedCameraEvent(name: "Road Trip", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-07-01")))
            let assignments = [
                // Unique on the NAS: goes back to its subfolder, the
                // unlisted XMP of the same name follows.
                PhotoEventAssignment(sourceRootPath: "/Volumes/Card", relativePath: "Transfer 7/IMG_0001.DNG", fileSize: 10, modifiedAt: Date(), eventID: event.id, deviceID: "osmo-360"),
                // Two legacy DSC0001.ARW match this name: ambiguous, flat.
                PhotoEventAssignment(sourceRootPath: "/Volumes/Card", relativePath: "Transfer 2/DSC0001.ARW", fileSize: 12, modifiedAt: Date(), eventID: event.id, deviceID: "sony-a7v"),
            ]
            _ = try CatalogStateStore(url: f.catalogURL).migrate(
                state: CatalogOwnedState(savedEvents: [event], photoEventAssignments: assignments),
                configurationURL: nil,
                backups: CatalogBackupService(catalogURL: f.catalogURL, configurationURL: nil, localFolder: f.support.appendingPathComponent("Backups"), remoteFolder: nil)
            )
            CatalogDatabase.checkpointAndClose(url: f.catalogURL)
            f.mapping.events[0].eventID = event.id

            let plan = try f.planner()
            XCTAssertTrue(plan.isExecutable, plan.blockers.joined(separator: "\n"))
            let e = "2026/2026-07-01 Road Trip"
            let moves = Dictionary(uniqueKeysWithValues: plan.allMoves.map {
                (String($0.source.dropFirst(f.legacy.path.count + 1)), String($0.destination.dropFirst(f.nas.path.count + 1)))
            })
            XCTAssertEqual(moves["\(e)/DJI Osmo 360/Photos/IMG_0001.DNG"], "\(e)/Originals/Osmo 360/Transfer 7/IMG_0001.DNG")
            XCTAssertEqual(moves["\(e)/DJI Osmo 360/Photos/IMG_0001.XMP"], "\(e)/Originals/Osmo 360/Transfer 7/IMG_0001.XMP")
            XCTAssertEqual(moves["\(e)/Sony A7V/RAW/DSC0001.ARW"], "\(e)/Originals/Sony A7V/DSC0001.ARW")
            XCTAssertEqual(plan.events.first?.knownSubfolderFiles, 2)
            XCTAssertEqual(plan.events.first?.ambiguousKnownNames, 1)
            XCTAssertTrue(plan.notes.isEmpty, plan.notes.joined())
            // After the migration, presence finds the file where the app
            // expects it.
            let report = try f.executor().execute(plan)
            XCTAssertTrue(report.succeeded, report.text)
            var configuration = f.configuration
            configuration.savedEvents = [event]
            let locations = EventStorageLocations(configuration: configuration)
            let osmo = try XCTUnwrap(assignments.first)
            XCTAssertEqual(locations.archiveURL(for: osmo, event: event)?.path, f.mirrorEvent.appendingPathComponent("Originals/Osmo 360/Transfer 7/IMG_0001.DNG").path)
            XCTAssertNotNil(LayoutMigrationDisk.lstatEntry(try XCTUnwrap(locations.archiveURL(for: osmo, event: event)).path))

            // An event id the catalog does not know is a blocker, and a
            // destination other than the event's own folder is a note.
            f.mapping.events[0].eventID = UUID()
            XCTAssertTrue(try f.planner().blockers.contains { $0.contains("the catalog has no event") })
        }
    }

    // MARK: - Execute, verify, undo

    func testExecuteRenamesVerifiesRewritesTheCatalogAndUndoPutsEverythingBack() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let original = tree(f.nas)
            let plan = try f.planner()
            let report = try f.executor().execute(plan)
            XCTAssertTrue(report.succeeded, report.text)
            XCTAssertEqual(report.phase, .completed)

            for move in plan.allMoves {
                XCTAssertNil(LayoutMigrationDisk.lstatEntry(move.source), move.source)
                XCTAssertEqual(
                    FileManager.default.contents(atPath: move.destination),
                    original[String(move.source.dropFirst(f.nas.path.count + 1))],
                    move.destination
                )
            }
            XCTAssertEqual(text(f.mirrorEvent.appendingPathComponent("Originals/Osmo 360/CAM_0001.OSV")), "already synced, different")
            // Emptied legacy folders are gone; ones still holding something stay.
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(f.event.appendingPathComponent("Sony-A7V").path))
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(f.legacy.appendingPathComponent("2026/2026-08_Odd-Name").path))
            XCTAssertNotNil(LayoutMigrationDisk.lstatEntry(f.event.appendingPathComponent("2026-07-03 Unlisted/Sony A7V/RAW/DSC0300.ARW").path))
            XCTAssertNotNil(LayoutMigrationDisk.lstatEntry(f.event.appendingPathComponent(".DS_Store").path))

            // The catalog follows in one verified transaction.
            let newJPEG = f.mirrorEvent.appendingPathComponent("Originals/Sony A7V/DSC0001 (2).JPG").path
            try CatalogDatabase.writer(for: f.catalogURL).read { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT path FROM face_photos"), newJPEG)
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT photo_id FROM faces WHERE id = 'F1'"), EventStorageLocations.pathKey(newJPEG))
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT relative_path FROM nas_sync_files"), "2026/2026-07-01 Road Trip/notes.txt")
                XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = ?", arguments: [NASLayoutMigrationExecutor.markerKey]))
            }
            let journalURL = try XCTUnwrap(report.journalURL)
            let journal = try NASLayoutMigrationJournal.read(journalURL)
            XCTAssertEqual(journal.sampleChecks.count, 4, "two samples on the big event, one on each one-file event")
            XCTAssertTrue(journal.sampleChecks.allSatisfy { $0.sha256After == $0.sha256Before })

            let undone = try f.executor().undo(journalURL: journalURL)
            XCTAssertTrue(undone.succeeded, undone.text)
            XCTAssertEqual(tree(f.nas), original)
            try CatalogDatabase.writer(for: f.catalogURL).read { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT relative_path FROM nas_sync_files"), "Originals/2026/2026-07-01 Road Trip/notes.txt")
                XCTAssertTrue(try String.fetchOne(db, sql: "SELECT path FROM face_photos")?.hasSuffix("Sony-A7V/JPEG/DSC0001.JPG") == true)
            }
        }
    }

    func testACrashMidRenameResumesAndACrashAfterTheCommitDoesNotRepeatIt() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let original = tree(f.nas)
            let plan = try f.planner()
            struct Crash: Error {}
            let crashed = try f.executor(hooks: .init(afterMove: { count in if count == 5 { throw Crash() } })).execute(plan)
            XCTAssertFalse(crashed.succeeded)
            XCTAssertEqual(crashed.phase, .moving)
            let journalURL = try XCTUnwrap(crashed.journalURL)
            // A new plan cannot start while this one is unfinished.
            XCTAssertThrowsError(try f.executor().execute(plan))

            let committedCrash = try f.executor(hooks: .init(afterCatalogCommit: { throw Crash() })).resume(journalURL: journalURL)
            XCTAssertFalse(committedCrash.succeeded)
            XCTAssertEqual(committedCrash.phase, .catalogCommitted)

            let resumed = try f.executor().resume(journalURL: journalURL)
            XCTAssertTrue(resumed.succeeded, resumed.text)
            XCTAssertEqual(resumed.phase, .completed)
            for move in plan.allMoves {
                XCTAssertEqual(FileManager.default.contents(atPath: move.destination), original[String(move.source.dropFirst(f.nas.path.count + 1))])
            }
            try CatalogDatabase.writer(for: f.catalogURL).read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM face_photos"), 1)
                XCTAssertTrue(try String.fetchOne(db, sql: "SELECT path FROM face_photos")?.hasSuffix("DSC0001 (2).JPG") == true)
            }
            XCTAssertTrue(try f.executor().undo(journalURL: journalURL).succeeded)
            XCTAssertEqual(tree(f.nas), original)
        }
    }

    func testARenameThatFailsIsSkippedReportedAndResumed() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let plan = try f.planner()
            // SMB without RENAME_EXCL for every file, and one file the NAS
            // refuses to rename (an I/O error).
            NASFileIO.renameExclusivePrimitive = { source, _ in
                errno = source.hasSuffix("IMG_0001.DNG") ? EIO : ENOTSUP
                return -1
            }
            let report = try f.executor().execute(plan)
            XCTAssertFalse(report.succeeded)
            XCTAssertEqual(report.phase, .moving)
            let journalURL = try XCTUnwrap(report.journalURL)
            let journal = try NASLayoutMigrationJournal.read(journalURL)
            XCTAssertEqual(journal.failedMoves.map { ($0.source as NSString).lastPathComponent }, ["IMG_0001.DNG"])
            // Every other file moved through the check-then-rename fallback.
            let others = plan.allMoves.filter { !$0.source.hasSuffix("IMG_0001.DNG") }
            XCTAssertTrue(others.allSatisfy { LayoutMigrationDisk.lstatEntry($0.destination) != nil && LayoutMigrationDisk.lstatEntry($0.source) == nil })
            // The catalog waits until every file is across.
            try CatalogDatabase.writer(for: f.catalogURL).read { db in
                XCTAssertNil(try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = ?", arguments: [NASLayoutMigrationExecutor.markerKey]))
            }

            NASFileIO.renameExclusivePrimitive = nil
            let resumed = try f.executor().resume(journalURL: journalURL)
            XCTAssertTrue(resumed.succeeded, resumed.text)
            XCTAssertTrue(plan.allMoves.allSatisfy { LayoutMigrationDisk.lstatEntry($0.destination) != nil })
        }
    }

    func testExecuteRefusesWhileTheAppRunsOrWhenTheNASChangedSinceThePlan() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let original = tree(f.nas)
            let plan = try f.planner()
            XCTAssertThrowsError(try f.executor(running: true).execute(plan)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Camera Toolkit is running"))
            }
            try writeFile(f.event.appendingPathComponent("DJI Nano/Video/Day 1/DJI_0009.MP4"), "a new clip")
            XCTAssertThrowsError(try f.executor().execute(plan)) { error in
                XCTAssertTrue(error.localizedDescription.contains("changed since the plan"), error.localizedDescription)
            }
            var expected = original
            expected["Originals/2026/2026-07-01 Road Trip/DJI Nano/Video/Day 1/DJI_0009.MP4"] = Data("a new clip".utf8)
            XCTAssertEqual(tree(f.nas), expected)
        }
    }

    func testASampledHashMismatchStopsTheRun() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let plan = try f.planner()
            var reads = 0
            NASFileIO.verificationHashOverride = { _ in
                reads += 1
                return reads == 2 ? String(repeating: "f", count: 64) : nil
            }
            let report = try f.executor(samples: 1).execute(plan)
            XCTAssertFalse(report.succeeded)
            XCTAssertTrue(report.text.contains("reads back different bytes"), report.text)
        }
    }

    // MARK: - Command line

    func testCommandLineParsesAndTheDryRunWritesOnlyThePlan() throws {
        XCTAssertEqual(
            try NASLayoutMigrationCommand.parse(["app", "--migrate-nas-layout", "--dry-run", "--mapping", "m.json", "--json", "p.json"]).mode,
            .dryRun(mappingPath: "m.json", jsonPath: "p.json")
        )
        XCTAssertEqual(try NASLayoutMigrationCommand.parse(["app", "--migrate-nas-layout", "--execute", "--plan", "p.json", "--verify-sample", "5"]).verifySamples, 5)
        XCTAssertEqual(try NASLayoutMigrationCommand.parse(["app", "--migrate-nas-layout", "--undo", "j.json"]).mode, .undo(journalPath: "j.json"))
        XCTAssertThrowsError(try NASLayoutMigrationCommand.parse(["app", "--migrate-nas-layout", "--dry-run"]))
        XCTAssertThrowsError(try NASLayoutMigrationCommand.parse(["app", "--migrate-nas-layout", "--execute"]))
        XCTAssertThrowsError(try NASLayoutMigrationCommand.parse(["app", "--migrate-nas-layout", "--dry-run", "--mapping", "m", "--undo", "j"]))

        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let original = tree(f.nas)
            let mappingURL = root.appendingPathComponent("mapping.json")
            try JSONEncoder().encode(f.mapping).write(to: mappingURL)
            let planURL = root.appendingPathComponent("plan.json")
            var output: [String] = []
            let status = NASLayoutMigrationCommand.run(
                arguments: ["app", "--migrate-nas-layout", "--dry-run", "--mapping", mappingURL.path, "--json", planURL.path, "--support-dir", f.support.path],
                environment: [:],
                defaultSupportFolder: root.appendingPathComponent("Unused"),
                output: { output.append($0) }
            )
            XCTAssertEqual(status, 0, output.joined(separator: "\n"))
            XCTAssertTrue(output.joined().contains("Executable: yes"))
            XCTAssertEqual(tree(f.nas), original)
            let plan = try NASLayoutMigrationPlan.read(planURL)
            XCTAssertEqual(plan.events.count, 3)
            // The plan file is never overwritten.
            XCTAssertEqual(NASLayoutMigrationCommand.run(
                arguments: ["app", "--migrate-nas-layout", "--dry-run", "--mapping", mappingURL.path, "--json", planURL.path, "--support-dir", f.support.path],
                environment: [:],
                defaultSupportFolder: root,
                output: { _ in }
            ), 1)
        }
    }
}
