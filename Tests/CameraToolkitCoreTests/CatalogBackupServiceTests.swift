@testable import CameraToolkitCore
import Foundation
import GRDB
import XCTest

final class CatalogBackupServiceTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func makeCatalog(in root: URL) throws -> URL {
        let catalog = root.appendingPathComponent("catalog.sqlite")
        var configuration = AppConfiguration.testConfiguration(root: root, catalog: catalog)
        let event = SavedCameraEvent(name: "Trip", eventDate: Date(timeIntervalSince1970: 1_750_000_000))
        configuration.savedEvents = [event]
        configuration.photoEventAssignments = (0..<25).map {
            PhotoEventAssignment(
                sourceRootPath: "/cards/a",
                relativePath: "DCIM/\($0).ARW",
                fileSize: Int64($0 + 1),
                modifiedAt: Date(timeIntervalSince1970: 1_750_000_000 + Double($0)),
                eventID: event.id
            )
        }
        _ = try CatalogStore(url: catalog).bootstrap(configuration: configuration, createLibraryFolders: false)
        let store = FaceIndexStore(url: catalog)
        _ = try store.createPerson(name: "Ada", isRoster: true)
        _ = try store.createPerson(name: "Grace", isRoster: true)
        return catalog
    }

    private func service(
        root: URL,
        catalog: URL,
        remote: URL? = nil,
        clock: Clock? = nil,
        configuration: URL? = nil
    ) -> CatalogBackupService {
        let clock = clock ?? Clock(Date())
        let now: @Sendable () -> Date = { clock.now }
        return CatalogBackupService(
            catalogURL: catalog,
            configurationURL: configuration,
            localFolder: root.appendingPathComponent("Backups", isDirectory: true),
            remoteFolder: remote,
            now: now
        )
    }

    func testBackupIsASelfContainedVerifiedSnapshotIncludingUncheckpointedWALWrites() throws {
        try withTemporaryDirectory { root in
            let catalog = try makeCatalog(in: root)
            // Written through the shared WAL connection and not yet
            // checkpointed: a plain file copy of catalog.sqlite would miss it.
            _ = try FaceIndexStore(url: catalog).createPerson(name: "Hedy", isRoster: true)

            let result = try service(root: root, catalog: catalog).backupNow(reason: .manual)

            let backup = try XCTUnwrap(result.catalogURL)
            XCTAssertEqual(result.manifest.integrityCheck, "ok")
            XCTAssertEqual(result.manifest.tableCounts["people"], 3)
            XCTAssertEqual(result.manifest.tableCounts["event_assets"], 25)
            XCTAssertEqual(result.manifest.tableCounts["events"], 1)
            XCTAssertEqual(result.remote, .notConfigured)
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path + "-wal"))

            let queue = try DatabaseQueue(path: backup.path, configuration: {
                var configuration = Configuration()
                configuration.readonly = true
                return configuration
            }())
            try queue.read { database in
                XCTAssertEqual(try String.fetchOne(database, sql: "PRAGMA journal_mode"), "delete")
                XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM people"), 3)
            }
            XCTAssertEqual(
                try FileScanner.sha256(backup),
                result.manifest.file(.catalog)?.sha256
            )
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testBackupDuringConcurrentWritesStillMatchesItsOwnSnapshot() throws {
        try withTemporaryDirectory { root in
            let catalog = try makeCatalog(in: root)
            let store = FaceIndexStore(url: catalog)
            let done = DispatchSemaphore(value: 0)
            let stop = NSLock()
            nonisolated(unsafe) var stopped = false
            DispatchQueue.global().async {
                var index = 0
                while true {
                    stop.lock(); let finished = stopped; stop.unlock()
                    if finished { break }
                    _ = try? store.createPerson(name: "Writer \(index)", isRoster: false)
                    index += 1
                }
                done.signal()
            }
            let backups = service(root: root, catalog: catalog)
            for _ in 0..<5 {
                let result = try backups.backupNow(reason: .afterWrites)
                XCTAssertEqual(result.manifest.integrityCheck, "ok")
                XCTAssertGreaterThanOrEqual(result.manifest.tableCounts["people"] ?? 0, 2)
            }
            stop.lock(); stopped = true; stop.unlock()
            done.wait()
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testConfigJSONIsBackedUpBesideTheCatalogAndChecksummed() throws {
        try withTemporaryDirectory { root in
            let catalog = try makeCatalog(in: root)
            let configURL = root.appendingPathComponent("config.json")
            try ConfigurationStore(url: configURL).save(.testConfiguration(root: root, catalog: catalog))

            let result = try service(root: root, catalog: catalog, configuration: configURL).backupNow(reason: .manual)

            let file = try XCTUnwrap(result.manifest.file(.configuration))
            let copy = result.localFolder.appendingPathComponent(file.name)
            XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: configURL))
            XCTAssertEqual(result.manifest.configurationDecodes, true)
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testLegacyForeignKeyViolationIsRecordedNotFatal() throws {
        try withTemporaryDirectory { root in
            let catalog = try makeCatalog(in: root)
            try DatabaseQueue(path: catalog.path).writeWithoutTransaction { database in
                try database.execute(sql: "PRAGMA foreign_keys = OFF")
                try database.execute(sql: """
                    INSERT INTO import_batches(id, name, source_location_id, created_at)
                    VALUES ('legacy', 'Old import', 'missing-location', '2025-01-01T00:00:00Z')
                    """)
            }

            let result = try service(root: root, catalog: catalog).backupNow(reason: .manual)

            XCTAssertEqual(result.manifest.integrityCheck, "ok")
            XCTAssertEqual(result.manifest.foreignKeyViolations, 1)
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testVerificationRejectsACountMismatchAndLeavesNoSetBehind() throws {
        try withTemporaryDirectory { root in
            let catalog = try makeCatalog(in: root)
            let partial = root.appendingPathComponent("probe.sqlite")
            let counts = try CatalogBackupService.snapshot(from: catalog, to: partial)
            XCTAssertNoThrow(try CatalogBackupService.verify(backup: partial, expectedCounts: counts))
            var wrong = counts
            wrong["people"] = 99
            XCTAssertThrowsError(try CatalogBackupService.verify(backup: partial, expectedCounts: wrong))

            // A missing catalog fails loudly and leaves nothing that looks
            // like a backup.
            let backups = root.appendingPathComponent("Backups")
            let missing = CatalogBackupService(
                catalogURL: root.appendingPathComponent("nope.sqlite"),
                configurationURL: nil,
                localFolder: backups,
                remoteFolder: nil
            )
            XCTAssertThrowsError(try missing.backupNow(reason: .manual))
            XCTAssertTrue(missing.manifests(in: backups).isEmpty)
            XCTAssertNotNil(missing.summary().lastError)
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testOfflineNASIsSkippedQuietlyAndCaughtUpLater() throws {
        try withTemporaryDirectory { root in
            let catalog = try makeCatalog(in: root)
            let offline = URL(fileURLWithPath: "/Volumes/CameraToolkit-Not-Mounted-\(UUID().uuidString)/backups")
            let clock = Clock(Date())

            let first = try service(root: root, catalog: catalog, remote: offline, clock: clock).backupNow(reason: .manual)
            XCTAssertEqual(first.remote, .offline)
            XCTAssertFalse(FileManager.default.fileExists(atPath: offline.deletingLastPathComponent().path))

            // The NAS comes back (modelled by a reachable folder).
            let nas = root.appendingPathComponent("NAS/catalog-backups", isDirectory: true)
            let online = service(root: root, catalog: catalog, remote: nas, clock: clock)
            XCTAssertNil(try online.backupIfStale(), "a fresh local set is not redone")
            let mirrored = try XCTUnwrap(online.newestManifest(in: nas))
            XCTAssertEqual(mirrored.id, first.manifest.id)
            for file in mirrored.files {
                XCTAssertEqual(try FileScanner.sha256(nas.appendingPathComponent(file.name)), file.sha256)
            }
            XCTAssertEqual(online.catchUpRemote(), .alreadyPresent(nas))
            let summary = online.summary()
            XCTAssertEqual(summary.lastLocal, summary.lastRemote)
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testNASConflictIsLeftUntouched() throws {
        try withTemporaryDirectory { root in
            let catalog = try makeCatalog(in: root)
            let clock = Clock(Date(timeIntervalSince1970: 1_790_000_000))
            let nas = root.appendingPathComponent("NAS", isDirectory: true)
            let local = service(root: root, catalog: catalog, clock: clock)
            let set = try local.backupNow(reason: .manual).manifest
            let catalogName = try XCTUnwrap(set.file(.catalog)?.name)
            try writeFile(nas.appendingPathComponent(catalogName), "someone else's file")

            let remote = service(root: root, catalog: catalog, remote: nas, clock: clock).catchUpRemote()

            guard case .failed = remote else { return XCTFail("expected a failed NAS copy, got \(remote)") }
            XCTAssertEqual(try String(contentsOf: nas.appendingPathComponent(catalogName), encoding: .utf8), "someone else's file")
            XCTAssertFalse(FileManager.default.fileExists(atPath: nas.appendingPathComponent("\(set.id).manifest.json").path))
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testStaleCheckBacksUpOnlyAfterADay() throws {
        try withTemporaryDirectory { root in
            let catalog = try makeCatalog(in: root)
            let clock = Clock(Date(timeIntervalSince1970: 1_790_000_000))
            let backups = service(root: root, catalog: catalog, clock: clock)
            XCTAssertNotNil(try backups.backupIfStale(), "no backup yet → back up")
            clock.now += 23 * 3600
            XCTAssertNil(try backups.backupIfStale())
            clock.now += 2 * 3600
            let second = try XCTUnwrap(try backups.backupIfStale())
            XCTAssertEqual(second.manifest.reason, .launch)
            XCTAssertEqual(backups.manifests(in: root.appendingPathComponent("Backups")).count, 2)
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testRollingRetentionKeepsDailiesWeekliesAndPinnedAndNeverTouchesOtherFiles() throws {
        try withTemporaryDirectory { root in
            let catalog = try makeCatalog(in: root)
            let backupsFolder = root.appendingPathComponent("Backups", isDirectory: true)
            let nas = root.appendingPathComponent("NAS", isDirectory: true)
            // Hand-made files that must survive every prune.
            let handMade = [
                "catalog-before-sqlite-truth.sqlite",
                "config-before-migration.json",
                "catalog-20260922T223715.sqlite",
                "ctbackup-notes.txt",
                "ctbackup-20250101T000000Z.catalog.sqlite"
            ]
            for name in handMade {
                try writeFile(backupsFolder.appendingPathComponent(name), "keep me")
                try writeFile(nas.appendingPathComponent(name), "keep me")
            }

            let clock = Clock(Date(timeIntervalSince1970: 1_790_000_000))
            let backups = service(root: root, catalog: catalog, remote: nas, clock: clock)
            let pinned = try backups.backupNow(reason: .migration, pinned: true).manifest
            // Two backups a day for 60 days.
            for _ in 0..<120 {
                clock.now += 12 * 3600
                try backups.backupNow(reason: .afterWrites)
            }

            for folder in [backupsFolder, nas] {
                let kept = backups.manifests(in: folder)
                XCTAssertTrue(kept.contains { $0.id == pinned.id }, "the migration snapshot is pinned")
                // 7 dailies + 2–3 older weeklies (recent weeks overlap the
                // dailies) + the pinned set.
                XCTAssertLessThanOrEqual(kept.count, 7 + 4 + 1)
                XCTAssertGreaterThanOrEqual(kept.count, 7 + 2 + 1)
                for name in handMade {
                    XCTAssertEqual(
                        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
                        "keep me",
                        "\(name) was not made by the backup service"
                    )
                }
                // Every remaining ctbackup file belongs to a kept set.
                let keptIDs = Set(kept.map(\.id))
                let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                for name in names where name.hasPrefix("ctbackup-") && !handMade.contains(name) {
                    let id = String(name.prefix { $0 != "." })
                    XCTAssertTrue(keptIDs.contains(id), "\(name) should have been pruned")
                }
            }
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testRetentionPicksNewestPerDayAndWeek() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let sets = (0..<30).map { day in
            CatalogBackupManifest(
                format: CatalogBackupManifest.formatName,
                version: 1,
                id: "set-\(day)",
                createdAt: start + Double(day) * 86_400,
                reason: .launch,
                pinned: false,
                files: [],
                tableCounts: [:],
                integrityCheck: "ok",
                foreignKeyViolations: 0
            )
        }
        let keep = CatalogBackupService.idsToKeep(sets, calendar: calendar)
        for day in 23..<30 { XCTAssertTrue(keep.contains("set-\(day)")) }
        XCTAssertFalse(keep.contains("set-0"))
        XCTAssertLessThanOrEqual(keep.count, 11)
    }

    func testOnlyServiceNamedIDsQualify() {
        XCTAssertTrue(CatalogBackupService.isSetID("ctbackup-20260922T224400Z"))
        XCTAssertTrue(CatalogBackupService.isSetID("ctbackup-20260922T224400Z-3"))
        XCTAssertFalse(CatalogBackupService.isSetID("catalog-before-20260922"))
        XCTAssertFalse(CatalogBackupService.isSetID("ctbackup-notes"))
    }
}
