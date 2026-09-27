@testable import CameraToolkitCore
import Darwin
import Foundation
import GRDB
import XCTest

/// Per-file mode of the NAS layout migration, on a synthetic library:
///
/// ```
/// Library/Originals/2026/2026-07_Trip/
///   Cam-A/RAW/A0001.ARW, A0001.XMP, ._A0001.ARW   twin not in the CSV → follows
///   Cam-A/JPEG/A0002.JPG, ._A0002.JPG             twin in the CSV → follows
///   notes.txt                                      the CSV leaves it in place
///   Extra/keep.txt                                 not in the CSV → stays
///   .DS_Store
/// Library/Originals/2026/2026-07-04 Party 2026/Sony A7V/RAW/DSC0001.ARW, DSC0001.XMP
///   catalog event "party-2026" (renamed to "Party 2026"); its assignment
///   says DCIM/100MSDCF/DSC0001.ARW → the file lands there, the XMP follows
/// Library/Shared/Pics/P0001.JPG                   a face photo row, and an
///   assignment whose source is this NAS file
/// ```
final class NASLayoutFileMappingTests: XCTestCase {
    override func tearDown() {
        NASFileIO.renameExclusivePrimitive = nil
        NASFileIO.verificationHashOverride = nil
        DirectoryListing.override = nil
        super.tearDown()
    }

    private struct Fixture {
        var root: URL
        var library: URL
        var support: URL
        var configurationURL: URL
        var catalogURL: URL
        var configuration: AppConfiguration
        var mapping: NASLayoutMapping
        var party: SavedCameraEvent
        var sharedAssignment: PhotoEventAssignment

        func plan() throws -> NASLayoutMigrationPlan {
            try NASLayoutMigrationPlanner().plan(.init(
                mapping: mapping, configuration: configuration, supportFolder: support,
                configurationURL: configurationURL, catalogURL: catalogURL
            ))
        }

        func executor(running: Bool = false, hooks: NASLayoutMigrationExecutor.Hooks = .init()) -> NASLayoutMigrationExecutor {
            NASLayoutMigrationExecutor(
                supportFolder: support, configurationURL: configurationURL, catalogURL: catalogURL,
                configuration: configuration, verifySamples: 2, isAppRunning: { running }, hooks: hooks
            )
        }

        func path(_ relative: String) -> String { library.appendingPathComponent(relative).path }
    }

    private static let trip = "Originals/2026/2026-07_Trip"
    private static let partySource = "Originals/2026/2026-07-04 Party 2026"

    private func fixture(_ root: URL) throws -> Fixture {
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let files: [(String, String)] = [
            ("\(Self.trip)/Cam-A/RAW/A0001.ARW", "raw one"),
            ("\(Self.trip)/Cam-A/RAW/A0001.XMP", "xmp one"),
            ("\(Self.trip)/Cam-A/RAW/._A0001.ARW", "apple double one"),
            ("\(Self.trip)/Cam-A/JPEG/A0002.JPG", "jpeg two"),
            ("\(Self.trip)/Cam-A/JPEG/._A0002.JPG", "apple double two"),
            ("\(Self.trip)/notes.txt", "notes"),
            ("\(Self.trip)/Extra/keep.txt", "keep"),
            ("\(Self.trip)/.DS_Store", "finder"),
            ("\(Self.partySource)/Sony A7V/RAW/DSC0001.ARW", "party raw"),
            ("\(Self.partySource)/Sony A7V/RAW/DSC0001.XMP", "party xmp"),
            ("Shared/Pics/P0001.JPG", "shared jpeg"),
        ]
        for (path, text) in files { try writeFile(library.appendingPathComponent(path), text) }

        let catalogURL = support.appendingPathComponent("catalog.sqlite")
        var configuration = AppConfiguration.testConfiguration(root: root, catalog: catalogURL)
        configuration.cameraLibraryRootPath = library.path
        configuration.archiveLayoutRootPath = library.path
        let configurationURL = support.appendingPathComponent("config.json")
        try JSONEncoder().encode(configuration).write(to: configurationURL)
        try CatalogStore(url: catalogURL).prepareSchema()

        let party = SavedCameraEvent(name: "party-2026", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-07-04")))
        let other = SavedCameraEvent(name: "Other", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-07-01")))
        let partyRaw = library.appendingPathComponent("\(Self.partySource)/Sony A7V/RAW/DSC0001.ARW")
        let shared = library.appendingPathComponent("Shared/Pics/P0001.JPG")
        let sharedEntry = try XCTUnwrap(LayoutMigrationDisk.lstatEntry(shared.path))
        let sharedAssignment = PhotoEventAssignment(
            sourceRootPath: library.appendingPathComponent("Shared").path, relativePath: "Pics/P0001.JPG",
            fileSize: sharedEntry.size, modifiedAt: sharedEntry.modifiedDate, eventID: other.id, deviceID: "sony-a7v"
        )
        _ = try CatalogStateStore(url: catalogURL).migrate(
            state: CatalogOwnedState(savedEvents: [party, other], photoEventAssignments: [
                PhotoEventAssignment(
                    sourceRootPath: "/Volumes/Card", relativePath: "DCIM/100MSDCF/DSC0001.ARW",
                    fileSize: try XCTUnwrap(LayoutMigrationDisk.lstatEntry(partyRaw.path)).size,
                    modifiedAt: Date(), eventID: party.id, deviceID: "sony-a7v"
                ),
                sharedAssignment,
            ]),
            configurationURL: nil,
            backups: CatalogBackupService(catalogURL: catalogURL, configurationURL: nil, localFolder: support.appendingPathComponent("Backups"), remoteFolder: nil)
        )
        let now = ISO8601DateFormatter().string(from: Date())
        try CatalogDatabase.writer(for: catalogURL).write { db in
            try db.execute(sql: "INSERT INTO people(id, name, is_roster, face_count, created_at, updated_at) VALUES ('P1', 'Person A', 1, 1, ?, ?)", arguments: [now, now])
            try db.execute(
                sql: """
                INSERT INTO face_photos(path_key, path, file_name, byte_count, modified_at, scan_grade, face_count, engine, indexed_at, updated_at)
                VALUES (?, ?, 'P0001.JPG', 11, ?, 'med', 1, 'insightface/buffalo_l', ?, ?)
                """,
                arguments: [EventStorageLocations.pathKey(shared.path), shared.path, now, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO faces(id, photo_id, person_id, box_x, box_y, box_w, box_h, det_score, state, created_at, updated_at)
                VALUES ('F1', ?, 'P1', 0.1, 0.1, 0.2, 0.2, 0.9, 'confirmed', ?, ?)
                """,
                arguments: [EventStorageLocations.pathKey(shared.path), now, now]
            )
            try db.execute(
                sql: "INSERT INTO event_asset_locations(event_asset_id, location, state, checked_at) VALUES (?, 'archive', 1, ?)",
                arguments: [CatalogStore.eventAssetID(sharedAssignment), now]
            )
        }
        CatalogDatabase.checkpointAndClose(url: catalogURL)

        let t = "2026/2026-07-01 Trip"
        let p = "2026/2026-07-04 Party 2026"
        let mapping = NASLayoutMapping(
            legacyRoot: library.path,
            mirrorRoot: library.path,
            events: [],
            files: [
                .init(source: "\(Self.trip)/Cam-A/RAW/A0001.ARW", byteCount: 7, destination: "\(t)/Originals/Cam A/A0001.ARW"),
                .init(source: "\(Self.trip)/Cam-A/RAW/A0001.XMP", byteCount: 7, destination: "\(t)/Originals/Cam A/A0001.XMP"),
                .init(source: "\(Self.trip)/Cam-A/JPEG/A0002.JPG", byteCount: 8, destination: "\(t)/Originals/Cam A/A0002.JPG"),
                .init(source: "\(Self.trip)/Cam-A/JPEG/._A0002.JPG", byteCount: 16, destination: "\(t)/Originals/Cam A/._A0002.JPG"),
                .init(source: "\(Self.trip)/notes.txt", byteCount: 5, destination: nil),
                .init(source: "\(Self.trip)/.DS_Store", byteCount: 6, destination: nil),
                .init(source: "\(Self.partySource)/Sony A7V/RAW/DSC0001.ARW", byteCount: 9, destination: "\(p)/Originals/Sony A7V/DSC0001.ARW"),
                .init(source: "\(Self.partySource)/Sony A7V/RAW/DSC0001.XMP", byteCount: 9, destination: "\(p)/Originals/Sony A7V/DSC0001.XMP"),
                .init(source: "Shared/Pics/P0001.JPG", byteCount: 11, destination: "\(t)/Originals/Cam A/P0001.JPG"),
            ],
            eventRenames: [.init(event: "party-2026", name: "Party 2026")]
        )
        return Fixture(
            root: root, library: library, support: support, configurationURL: configurationURL, catalogURL: catalogURL,
            configuration: configuration, mapping: mapping, party: party, sharedAssignment: sharedAssignment
        )
    }

    private func tree(_ root: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        for entry in LayoutMigrationDisk.walk(root.path, fileManager: .default) where entry.kind == .file {
            result[String(entry.path.dropFirst(root.path.count + 1))] = FileManager.default.contents(atPath: entry.path)
        }
        return result
    }

    private func relativeMoves(_ plan: NASLayoutMigrationPlan, _ f: Fixture) -> [String: String] {
        Dictionary(uniqueKeysWithValues: plan.allMoves.map {
            (String($0.source.dropFirst(f.library.path.count + 1)), String($0.destination.dropFirst(f.library.path.count + 1)))
        })
    }

    // MARK: - Planner

    func testPerFileMovesTwinsFollowCatalogEventsAlignAndTheDryRunWritesNothing() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let before = tree(f.library)
            let plan = try f.plan()
            XCTAssertEqual(tree(f.library), before, "the dry run wrote nothing")
            XCTAssertTrue(plan.isExecutable, plan.blockers.joined(separator: "\n"))

            let moves = relativeMoves(plan, f)
            let t = "2026/2026-07-01 Trip/Originals/Cam A"
            XCTAssertEqual(moves["\(Self.trip)/Cam-A/RAW/A0001.ARW"], "\(t)/A0001.ARW")
            XCTAssertEqual(moves["\(Self.trip)/Cam-A/RAW/._A0001.ARW"], "\(t)/._A0001.ARW", "an unlisted twin follows its file")
            XCTAssertEqual(moves["\(Self.trip)/Cam-A/JPEG/._A0002.JPG"], "\(t)/._A0002.JPG", "a listed twin goes with its file")
            XCTAssertEqual(moves["Shared/Pics/P0001.JPG"], "\(t)/P0001.JPG")
            XCTAssertNil(moves["\(Self.trip)/notes.txt"])
            XCTAssertNil(moves["\(Self.trip)/Extra/keep.txt"])
            // The catalog event, renamed, fills its NAS folder: its file
            // goes where the app looks, and the sidecar follows.
            let p = "2026/2026-07-04 Party 2026/Originals/Sony A7V"
            XCTAssertEqual(moves["\(Self.partySource)/Sony A7V/RAW/DSC0001.ARW"], "\(p)/DCIM/100MSDCF/DSC0001.ARW")
            XCTAssertEqual(moves["\(Self.partySource)/Sony A7V/RAW/DSC0001.XMP"], "\(p)/DCIM/100MSDCF/DSC0001.XMP")
            XCTAssertEqual(plan.fileMapping?.alignedToCatalog, 2)
            XCTAssertEqual(plan.fileMapping?.unlistedTwins, 1)
            XCTAssertEqual(plan.summary.appleDoubleFiles, 2)
            XCTAssertEqual(plan.summary.conflicts, 0)

            let rename = try XCTUnwrap(plan.catalog.eventRenames?.first)
            XCTAssertEqual(rename.eventID, f.party.id)
            XCTAssertEqual(rename.newMirrorFolder, "2026/2026-07-04 Party 2026")
            XCTAssertEqual(rename.oldMirrorFolder, "2026/2026-07-04 party-2026")
            XCTAssertEqual(rename.driveFolderState, .absent)
            XCTAssertEqual(plan.catalog.attachedEvents?.map(\.name), ["Party 2026"])
            XCTAssertEqual(plan.catalog.facePhotoRewrites.map { ($0.newPath as NSString).lastPathComponent }, ["P0001.JPG"])
            XCTAssertEqual(plan.catalog.assignmentRewrites?.map(\.newRelativePath), ["P0001.JPG"])
            XCTAssertEqual(plan.catalog.assignmentRewrites?.first?.newSourceRootPath, f.path(t))

            XCTAssertTrue(plan.leftInPlace.contains { $0.path == f.path("\(Self.trip)/notes.txt") })
            XCTAssertTrue(plan.leftInPlace.contains { $0.path == f.path("\(Self.trip)/Extra") })
            XCTAssertTrue(plan.sourceDirectories?.contains(f.path("\(Self.trip)/Cam-A/RAW")) == true)
            XCTAssertFalse(plan.sourceDirectories?.contains(f.path("Originals")) == true, "a top-level folder is never removed")
            XCTAssertEqual(plan.events.map(\.destination), ["2026/2026-07-01 Trip", "2026/2026-07-04 Party 2026"])

            let url = root.appendingPathComponent("plan.json")
            try plan.jsonData().write(to: url)
            XCTAssertEqual(try NASLayoutMigrationPlan.read(url).jsonData(), try plan.jsonData())
        }
    }

    func testCollisionsAndRenameOrderDependenciesAreRefused() throws {
        try withTemporaryDirectory { root in
            var f = try fixture(root)
            // Two rows onto one name, differing only by case (SMB).
            f.mapping.files?[1].destination = "2026/2026-07-01 Trip/Originals/Cam A/a0001.arw"
            var plan = try f.plan()
            XCTAssertFalse(plan.isExecutable)
            XCTAssertTrue(plan.blockers.contains { $0.contains("both go to") }, plan.blockers.joined(separator: "\n"))

            // A destination that is already taken on the NAS.
            f = try fixture(root.appendingPathComponent("b"))
            try writeFile(f.library.appendingPathComponent("2026/2026-07-01 Trip/Originals/Cam A/A0002.JPG"), "someone else")
            plan = try f.plan()
            XCTAssertFalse(plan.isExecutable)
            XCTAssertEqual(plan.conflicts.map(\.reason), [.destinationExists])
            XCTAssertTrue(plan.blockers.contains { $0.contains("already exists on the NAS") })

            // A destination inside the legacy tree, one that is another row's
            // source, and a twin left behind by its moving file.
            f = try fixture(root.appendingPathComponent("c"))
            f.mapping.files?[0].destination = "Originals/2026/Elsewhere/A0001.ARW"
            f.mapping.files?[2].destination = "\(Self.trip)/notes.txt"
            f.mapping.files?[3].destination = nil
            plan = try f.plan()
            XCTAssertTrue(plan.blockers.contains { $0.contains("inside the legacy tree") })
            XCTAssertTrue(plan.blockers.contains { $0.contains("is another row's source") })
            XCTAssertTrue(plan.blockers.contains { $0.contains("is left in place but its file moves") })

            // A rename across a dataset or share boundary.
            f = try fixture(root.appendingPathComponent("d"))
            f.mapping.boundaries = ["Shared"]
            plan = try f.plan()
            XCTAssertTrue(plan.blockers.contains { $0.contains("boundary") }, plan.blockers.joined(separator: "\n"))
        }
    }

    func testAStaleCSVOrASourceChangedAfterThePlanIsRefused() throws {
        try withTemporaryDirectory { root in
            var f = try fixture(root)
            f.mapping.files?[0].byteCount = 99
            f.mapping.files?.append(.init(source: "\(Self.trip)/Cam-A/RAW/GONE.ARW", byteCount: 1, destination: "2026/2026-07-01 Trip/Originals/Cam A/GONE.ARW"))
            var plan = try f.plan()
            XCTAssertTrue(plan.blockers.contains { $0.contains("changed size since the inventory") })
            XCTAssertTrue(plan.blockers.contains { $0.contains("not on the NAS") })

            f = try fixture(root.appendingPathComponent("b"))
            let original = tree(f.library)
            plan = try f.plan()
            XCTAssertTrue(plan.isExecutable, plan.blockers.joined(separator: "\n"))
            try writeFile(f.library.appendingPathComponent("\(Self.trip)/Cam-A/RAW/A0001.XMP"), "xmp one, edited")
            XCTAssertThrowsError(try f.executor().execute(plan)) { error in
                XCTAssertTrue(error.localizedDescription.contains("changed since the plan"), error.localizedDescription)
            }
            var expected = original
            expected["\(Self.trip)/Cam-A/RAW/A0001.XMP"] = Data("xmp one, edited".utf8)
            XCTAssertEqual(tree(f.library), expected, "nothing moved")
            // Finder rewriting .DS_Store does not stale a plan.
            f = try fixture(root.appendingPathComponent("c"))
            plan = try f.plan()
            try writeFile(f.library.appendingPathComponent("\(Self.trip)/.DS_Store"), "finder, rewritten")
            XCTAssertTrue(try f.executor().verifyUnchanged(plan).isEmpty)
        }
    }

    // MARK: - Execute, resume, undo

    func testACrashResumesRenamesTheCatalogEventAndUndoPutsEverythingBack() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let original = tree(f.library)
            let plan = try f.plan()
            struct Crash: Error {}
            let crashed = try f.executor(hooks: .init(afterMove: { count in if count == 2 { throw Crash() } })).execute(plan)
            XCTAssertFalse(crashed.succeeded)
            XCTAssertEqual(crashed.phase, .moving)
            let journalURL = try XCTUnwrap(crashed.journalURL)

            let resumed = try f.executor().resume(journalURL: journalURL)
            XCTAssertTrue(resumed.succeeded, resumed.text)
            XCTAssertEqual(resumed.phase, .completed)
            for move in plan.allMoves {
                XCTAssertNil(LayoutMigrationDisk.lstatEntry(move.source), move.source)
                XCTAssertEqual(FileManager.default.contents(atPath: move.destination), original[String(move.source.dropFirst(f.library.path.count + 1))])
            }
            // Emptied folders are gone (rmdir only); folders still holding
            // something stay with their files.
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(f.path("\(Self.trip)/Cam-A")))
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(f.path(Self.partySource)))
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(f.path("Shared/Pics")))
            XCTAssertNotNil(LayoutMigrationDisk.lstatEntry(f.path("Shared")), "top-level folders stay")
            XCTAssertEqual(FileManager.default.contents(atPath: f.path("\(Self.trip)/notes.txt")), Data("notes".utf8))
            XCTAssertEqual(FileManager.default.contents(atPath: f.path("\(Self.trip)/Extra/keep.txt")), Data("keep".utf8))
            let journal = try NASLayoutMigrationJournal.read(journalURL)
            XCTAssertTrue(journal.keptDirectories.contains { $0.path == f.path(Self.trip) })

            // The catalog: the event is renamed, and the app computes the
            // folder the files are in; faces stay on their photo; the
            // NAS-sourced assignment follows with its presence row.
            let state = try CatalogStateStore(url: f.catalogURL).load()
            let party = try XCTUnwrap(state.savedEvents.first { $0.id == f.party.id })
            XCTAssertEqual(party.name, "Party 2026")
            var configuration = f.configuration
            configuration.savedEvents = state.savedEvents
            let locations = EventStorageLocations(configuration: configuration)
            let assignment = try XCTUnwrap(state.photoEventAssignments.first { $0.eventID == f.party.id })
            let archived = try XCTUnwrap(locations.archiveURL(for: assignment, event: party))
            XCTAssertEqual(archived.path, f.path("2026/2026-07-04 Party 2026/Originals/Sony A7V/DCIM/100MSDCF/DSC0001.ARW"))
            XCTAssertEqual(FileManager.default.contents(atPath: archived.path), Data("party raw".utf8))
            let moved = try XCTUnwrap(state.photoEventAssignments.first { $0.eventID == f.sharedAssignment.eventID })
            XCTAssertEqual(moved.sourceRootPath, f.path("2026/2026-07-01 Trip/Originals/Cam A"))
            try CatalogDatabase.writer(for: f.catalogURL).read { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT path FROM face_photos"), f.path("2026/2026-07-01 Trip/Originals/Cam A/P0001.JPG"))
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM faces WHERE state = 'confirmed' AND photo_id = (SELECT path_key FROM face_photos)"), 1)
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT event_asset_id FROM event_asset_locations"), CatalogStore.eventAssetID(moved))
            }

            let undone = try f.executor().undo(journalURL: journalURL)
            XCTAssertTrue(undone.succeeded, undone.text)
            XCTAssertEqual(tree(f.library), original)
            XCTAssertEqual(try CatalogStateStore(url: f.catalogURL).load().savedEvents.first { $0.id == f.party.id }?.name, "party-2026")
        }
    }

    func testAnUnreadableFileIsSkippedAndReportedAndTheRestMoves() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let locked = f.path("\(Self.trip)/Cam-A/RAW/A0001.XMP")
            chmod(locked, 0)
            defer { chmod(locked, 0o644) }
            let plan = try f.plan()
            XCTAssertTrue(plan.isExecutable, plan.blockers.joined(separator: "\n"))
            XCTAssertEqual(plan.unreadable.map(\.path), [locked])
            XCTAssertFalse(plan.allMoves.contains { $0.source == locked })
            let report = try f.executor().execute(plan)
            XCTAssertTrue(report.succeeded, report.text)
            XCTAssertNotNil(LayoutMigrationDisk.lstatEntry(locked), "the unreadable file stays")
            XCTAssertNotNil(LayoutMigrationDisk.lstatEntry(f.path("\(Self.trip)/Cam-A/RAW")), "its folder is not empty and stays")
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(f.path("\(Self.trip)/Cam-A/JPEG")))
        }
    }

    func testARenameIsBlockedWhileADriveFolderStillHasTheOldName() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let old = URL(fileURLWithPath: f.configuration.bufferPath).appendingPathComponent("2026/2026-07-04 party-2026/Originals")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            let plan = try f.plan()
            XCTAssertEqual(plan.catalog.eventRenames?.first?.driveFolderState, .present)
            XCTAssertTrue(plan.blockers.contains { $0.contains("under the old name") }, plan.blockers.joined(separator: "\n"))

            var ambiguous = f
            ambiguous.mapping.eventRenames = [.init(event: "nobody", name: "Party 2026")]
            XCTAssertTrue(try ambiguous.plan().blockers.contains { $0.contains("matches 0 events") })
        }
    }

    // MARK: - Command line and CSV

    func testTheCommandLineReadsTheCSVAndWritesOnlyThePlan() throws {
        XCTAssertEqual(
            try NASLayoutMigrationCommand.parse([
                "app", "--migrate-nas-layout", "--dry-run", "--file-mapping", "f.csv",
                "--rename-event", "old-name=New Name", "--rename-event", "B=C", "--boundary", "Shared", "--json", "p.json",
            ]).mode,
            .dryRunFiles(csvPath: "f.csv", renames: [.init(event: "old-name", name: "New Name"), .init(event: "B", name: "C")], boundaries: ["Shared"], jsonPath: "p.json")
        )
        XCTAssertThrowsError(try NASLayoutMigrationCommand.parse(["app", "--migrate-nas-layout", "--dry-run", "--file-mapping", "f.csv", "--mapping", "m.json"]))
        XCTAssertThrowsError(try NASLayoutMigrationCommand.parse(["app", "--migrate-nas-layout", "--dry-run", "--file-mapping", "f.csv", "--rename-event", "no-equals"]))
        XCTAssertThrowsError(try NASLayoutMigrationCommand.parse(["app", "--migrate-nas-layout", "--execute", "--plan", "p", "--rename-event", "a=b"]))

        XCTAssertEqual(
            try CSVRows.parse("a,b\n\"x, \"\"y\"\"\",2\r\nlast,\n"),
            [["a", "b"], ["x, \"y\"", "2"], ["last", ""]]
        )

        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let original = tree(f.library)
            var csv = "current_path(rel. to Media/Camera),bytes,class,proposed_path(rel. to Media/Camera),note\n"
            for file in f.mapping.files ?? [] {
                let fields = [file.source, String(file.byteCount), "media", file.destination ?? "", "a note, with a comma"]
                csv += fields.map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: ",") + "\n"
            }
            let csvURL = root.appendingPathComponent("files.csv")
            try Data(csv.utf8).write(to: csvURL)
            let read = try NASLayoutMapping.readFileMapping(csv: csvURL)
            XCTAssertEqual(read.files, f.mapping.files)

            var configuration = f.configuration
            configuration.archiveLayoutRootPath = f.library.path
            try JSONEncoder().encode(configuration).write(to: f.configurationURL)
            let planURL = root.appendingPathComponent("plan.json")
            var output: [String] = []
            let status = NASLayoutMigrationCommand.run(
                arguments: [
                    "app", "--migrate-nas-layout", "--dry-run", "--file-mapping", csvURL.path,
                    "--rename-event", "party-2026=Party 2026", "--json", planURL.path, "--support-dir", f.support.path,
                ],
                environment: [:],
                defaultSupportFolder: root.appendingPathComponent("Unused"),
                output: { output.append($0) }
            )
            XCTAssertEqual(status, 0, output.joined(separator: "\n"))
            XCTAssertTrue(output.joined().contains("Executable: yes"))
            XCTAssertEqual(tree(f.library), original)
            let plan = try NASLayoutMigrationPlan.read(planURL)
            XCTAssertEqual(plan.mapping.fileMappingDigest, LayoutMigrationHash.sha256(try Data(contentsOf: csvURL)))
            XCTAssertEqual(plan.summary.files, 8)
        }
    }
}
