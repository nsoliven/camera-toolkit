@testable import CameraToolkitCore
import Foundation
import GRDB
import XCTest

/// The one-time move of events, assignments, rotations, and burst splits
/// from config.json into the catalog, and the incremental writes after it.
final class CatalogStateMigrationTests: XCTestCase {
    private struct Fixture {
        var root: URL
        var configURL: URL
        var catalogURL: URL
        var backups: URL
        var configuration: AppConfiguration

        var backupService: CatalogBackupService {
            CatalogBackupService(catalogURL: catalogURL, configurationURL: configURL, localFolder: backups, remoteFolder: nil)
        }

        func resolve(hooks: CatalogStateStore.MigrationHooks = .init()) -> CatalogStateStartup.Outcome {
            CatalogStateStartup.resolve(
                configurationURL: configURL,
                defaults: .testConfiguration(root: root, catalog: catalogURL),
                backups: { _ in backupService },
                hooks: hooks
            )
        }

        func rowCount(_ table: String) throws -> Int {
            try CatalogDatabase.writer(for: catalogURL).read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            }
        }
    }

    /// A synthetic library the size of the owner's: 8 events (one a
    /// subevent, mixed optional fields), about 15k assignments with
    /// sub-millisecond modification times and every optional combination,
    /// a few hundred rotations and some burst splits. The catalog starts as
    /// the legacy mirror, with faces, presence rows, and one legacy dangling
    /// foreign key — like a real catalog before the upgrade.
    private func makeLegacyLibrary(in root: URL, assignments count: Int = 15_000) throws -> Fixture {
        let support = root.appendingPathComponent("CameraToolkit", isDirectory: true)
        let catalogURL = support.appendingPathComponent("catalog.sqlite")
        let configURL = support.appendingPathComponent("config.json")
        var configuration = AppConfiguration.testConfiguration(root: root, catalog: catalogURL)

        let base = Date(timeIntervalSinceReferenceDate: 780_000_000.123_456_7)
        var events: [SavedCameraEvent] = []
        for index in 0..<7 {
            let offset = Double(index)
            let upload: Bool? = index.isMultiple(of: 3) ? nil : index.isMultiple(of: 2)
            let policy: ImmichAlbumPolicy? = index == 1 ? .custom : nil
            let album: String? = index == 1 ? "Album Ω" : nil
            let storage: EventStoragePolicy? = index == 4 ? .archiveOnly : nil
            events.append(SavedCameraEvent(
                name: "Event \(index)",
                eventDate: base + offset * 86_400.25,
                createdAt: base + offset * 0.000_3,
                lastUsedAt: base + offset * 7.77,
                immichUploadEnabled: upload,
                immichAlbumPolicy: policy,
                immichAlbumName: album,
                storagePolicy: storage
            ))
        }
        events.append(SavedCameraEvent(name: "Sub", eventDate: base, parentEventID: events[2].id))
        configuration.savedEvents = events
        var assignments: [PhotoEventAssignment] = []
        assignments.reserveCapacity(count)
        for index in 0..<count {
            let device: String? = index.isMultiple(of: 5) ? nil : "sony-a7v"
            let override: Bool? = index.isMultiple(of: 7) ? index.isMultiple(of: 2) : nil
            let modified = base + Double(index) * 1.000_000_3
            assignments.append(PhotoEventAssignment(
                sourceRootPath: "/Volumes/Card\(index % 3)/DCIM",
                relativePath: String(format: "%03d/DSC%05d.ARW", index / 1_000, index),
                fileSize: Int64(20_000_000 + index),
                modifiedAt: modified,
                eventID: events[index % events.count].id,
                deviceID: device,
                immichUploadOverride: override
            ))
        }
        configuration.photoEventAssignments = assignments
        configuration.displayOrientations = Dictionary(uniqueKeysWithValues: (0..<300).map { ("DSC\($0).ARW|123|\($0)", $0 % 4) })
        configuration.burstSplits = (0..<20).map {
            BurstSplit(createdAt: base + Double($0) * 0.5, memberPathKeys: ["a\($0)", "b\($0)", "c\($0)"])
        }
        configuration.selectedEventID = events[3].id
        configuration.normalizeEventSelection()
        try ConfigurationStore(url: configURL).save(configuration)

        // The legacy mirror, plus the catalog-only data a real one holds.
        _ = try CatalogStore(url: catalogURL).bootstrap(configuration: configuration, createLibraryFolders: false)
        let faces = FaceIndexStore(url: catalogURL)
        _ = try faces.createPerson(name: "Ada", isRoster: true)
        try CatalogInspector(url: catalogURL).savePresenceObservations(
            configuration.photoEventAssignments.prefix(50).map {
                CatalogPresenceObservation(eventAssetID: CatalogStore.eventAssetID($0), location: .buffer, state: .present)
            }
        )
        try CatalogDatabase.writer(for: catalogURL).writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA foreign_keys = OFF")
            try database.execute(sql: """
                INSERT INTO import_batches(id, name, source_location_id, created_at)
                VALUES ('legacy', 'Old import', 'gone', '2025-01-01T00:00:00Z')
                """)
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return Fixture(
            root: root,
            configURL: configURL,
            catalogURL: catalogURL,
            backups: support.appendingPathComponent("Backups", isDirectory: true),
            configuration: configuration
        )
    }

    private func legacyCopies(_ fixture: Fixture) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixture.configURL.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("config.pre-sqlite-") }
    }

    // MARK: - First and second launch

    func testFirstLaunchMigratesAbout15kAssignmentsExactlyBehindAVerifiedBackup() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root)
            let originalBytes = try Data(contentsOf: fixture.configURL)
            let expected = CatalogOwnedState(configuration: fixture.configuration)

            let started = Date()
            let outcome = fixture.resolve()
            let elapsed = Date().timeIntervalSince(started)

            guard case .catalog(let baseline) = outcome.mode else {
                return XCTFail("expected the catalog to own the state: \(outcome.message ?? "")")
            }
            XCTAssertEqual(baseline, expected, "every field round-trips exactly")
            XCTAssertEqual(CatalogOwnedState(configuration: outcome.configuration), expected)
            XCTAssertEqual(outcome.configuration.selectedEventID, fixture.configuration.selectedEventID)
            XCTAssertTrue(outcome.shouldRewriteConfiguration)
            let report = try XCTUnwrap(outcome.migration)
            XCTAssertEqual(report.events, 8)
            XCTAssertEqual(report.assignments, 15_000)
            XCTAssertEqual(report.displayOrientations, 300)
            XCTAssertEqual(report.burstSplits, 20)
            XCTAssertEqual(report.duplicateAssignmentsDropped + report.orphanAssignmentsDropped, 0)
            XCTAssertEqual(report.preexistingForeignKeyViolations.count, 1, "the legacy import_batches link is reported, not fatal")
            XCTAssertEqual(try fixture.rowCount("event_assets"), 15_000)
            XCTAssertEqual(try fixture.rowCount("events"), 8)
            XCTAssertEqual(try fixture.rowCount("people"), 1, "face data is untouched")
            XCTAssertEqual(try fixture.rowCount("event_asset_locations"), 50, "presence rows of kept assignments survive")
            print("Migrated 15k assignments in \(String(format: "%.2f", elapsed)) s")

            // The pinned backup holds the catalog and the legacy config.
            let sets = fixture.backupService.manifests(in: fixture.backups)
            let migrationSet = try XCTUnwrap(sets.first { $0.id == report.backupID })
            XCTAssertTrue(migrationSet.pinned)
            XCTAssertEqual(migrationSet.reason, .migration)
            let configCopy = try XCTUnwrap(migrationSet.file(.configuration))
            XCTAssertEqual(try Data(contentsOf: fixture.backups.appendingPathComponent(configCopy.name)), originalBytes)

            // The timestamped legacy copy is byte-identical, and config.json
            // itself was not touched by the migration.
            let legacy = try XCTUnwrap(report.legacyConfigurationCopy)
            XCTAssertEqual(try Data(contentsOf: legacy), originalBytes)
            XCTAssertEqual(try Data(contentsOf: fixture.configURL), originalBytes)
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    func testSecondLaunchLoadsFromTheCatalogWithoutMigratingAgain() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 2_000)
            let first = fixture.resolve()
            XCTAssertNotNil(first.migration)
            // The app rewrites config.json settings-only after the move.
            try ConfigurationStore(url: fixture.configURL).save(first.configuration, settingsOnly: true)
            let settingsOnly = try Data(contentsOf: fixture.configURL)
            XCTAssertTrue(ConfigurationStore.isSettingsOnly(settingsOnly))
            XCTAssertFalse(String(decoding: settingsOnly, as: UTF8.self).contains("photoEventAssignments"))
            XCTAssertLessThan(settingsOnly.count, 10_000, "config.json is back to settings")
            let setsAfterFirst = fixture.backupService.manifests(in: fixture.backups).count

            let second = fixture.resolve()

            XCTAssertNil(second.migration)
            XCTAssertNil(second.message)
            XCTAssertFalse(second.shouldRewriteConfiguration)
            guard case .catalog(let baseline) = second.mode else { return XCTFail("expected catalog mode") }
            XCTAssertEqual(baseline, CatalogOwnedState(configuration: fixture.configuration))
            XCTAssertEqual(second.configuration.selectedEventID, fixture.configuration.selectedEventID)
            XCTAssertEqual(second.configuration.eventName, fixture.configuration.eventName)
            XCTAssertEqual(fixture.backupService.manifests(in: fixture.backups).count, setsAfterFirst, "no second migration backup")
            XCTAssertEqual(try legacyCopies(fixture).count, 1)
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    // MARK: - Failure paths

    func testCountMismatchRollsBackAndKeepsTheOldPath() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 3_000)
            let originalBytes = try Data(contentsOf: fixture.configURL)
            let mirrorBefore = try fixture.rowCount("event_assets")

            let outcome = fixture.resolve(hooks: .init(beforeValidation: { database in
                try database.execute(sql: "DELETE FROM event_assets WHERE rowid = (SELECT MIN(rowid) FROM event_assets)")
            }))

            XCTAssertEqual(outcome.mode, .legacy)
            XCTAssertTrue(outcome.message?.contains("2999 assignments in the catalog, 3000 expected") == true, outcome.message ?? "")
            XCTAssertFalse(try CatalogStateStore(url: fixture.catalogURL).catalogOwnsState(), "rolled back")
            XCTAssertEqual(try fixture.rowCount("event_assets"), mirrorBefore, "the mirror is exactly as before")
            XCTAssertEqual(try Data(contentsOf: fixture.configURL), originalBytes)
            XCTAssertEqual(CatalogOwnedState(configuration: outcome.configuration), CatalogOwnedState(configuration: fixture.configuration))

            // Next launch, without the fault, migrates.
            let retry = fixture.resolve()
            guard case .catalog = retry.mode else { return XCTFail("the retry should migrate: \(retry.message ?? "")") }
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    func testChangedRowReadBackRollsBack() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 500)
            let outcome = fixture.resolve(hooks: .init(beforeValidation: { database in
                try database.execute(sql: "UPDATE event_assets SET device_id = 'tampered' WHERE rowid = (SELECT MIN(rowid) FROM event_assets)")
            }))
            XCTAssertEqual(outcome.mode, .legacy)
            XCTAssertTrue(outcome.message?.contains("differ from config.json") == true, outcome.message ?? "")
            XCTAssertFalse(try CatalogStateStore(url: fixture.catalogURL).catalogOwnsState())
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    func testNewForeignKeyViolationRollsBack() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 500)
            let outcome = fixture.resolve(hooks: .init(beforeValidation: { database in
                try database.execute(sql: "PRAGMA defer_foreign_keys = ON")
                try database.execute(sql: """
                    INSERT INTO face_templates(person_id, face_id, created_at) VALUES ('nobody', 'nothing', 'now')
                    """)
            }))
            XCTAssertEqual(outcome.mode, .legacy)
            XCTAssertTrue(outcome.message?.contains("foreign") == true || outcome.message?.contains("FOREIGN") == true, outcome.message ?? "")
            XCTAssertFalse(try CatalogStateStore(url: fixture.catalogURL).catalogOwnsState())
            XCTAssertEqual(try fixture.rowCount("face_templates"), 0)
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    func testACrashBetweenStepsResumesCleanlyOnTheNextLaunch() throws {
        struct Crash: Error {}
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 1_000)
            let originalBytes = try Data(contentsOf: fixture.configURL)

            // Crash right after the backup.
            let afterBackup = fixture.resolve(hooks: .init(afterBackup: { throw Crash() }))
            XCTAssertEqual(afterBackup.mode, .legacy)
            XCTAssertTrue(try legacyCopies(fixture).isEmpty)

            // Crash right after the legacy copy.
            let afterCopy = fixture.resolve(hooks: .init(afterLegacyCopy: { throw Crash() }))
            XCTAssertEqual(afterCopy.mode, .legacy)
            XCTAssertEqual(try legacyCopies(fixture).count, 1)
            XCTAssertFalse(try CatalogStateStore(url: fixture.catalogURL).catalogOwnsState())
            XCTAssertEqual(try Data(contentsOf: fixture.configURL), originalBytes)

            // Then a clean launch migrates, reusing the identical legacy copy.
            let clean = fixture.resolve()
            guard case .catalog(let baseline) = clean.mode else { return XCTFail("expected catalog mode") }
            XCTAssertEqual(baseline, CatalogOwnedState(configuration: fixture.configuration))
            XCTAssertEqual(try legacyCopies(fixture).count, 1)
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    func testCrashAfterCommitBeforeConfigShrinksTrustsTheCatalog() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 1_000)
            guard case .catalog(let baseline) = fixture.resolve().mode else { return XCTFail("expected catalog mode") }
            // The session edits a row, then the app dies before config.json
            // was ever rewritten: it still holds the legacy state.
            var edited = baseline
            edited.photoEventAssignments[0].deviceID = "edited-after-migration"
            try CatalogStateStore(url: fixture.catalogURL).apply(from: baseline, to: edited)

            let relaunch = fixture.resolve()

            guard case .catalog(let loaded) = relaunch.mode else { return XCTFail("expected catalog mode") }
            XCTAssertEqual(loaded, edited, "the catalog wins over the stale JSON")
            XCTAssertNil(relaunch.migration)
            XCTAssertTrue(relaunch.shouldRewriteConfiguration, "the stale JSON shrinks now")
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    func testEmptyConfigNeverMigratesOverAPopulatedCatalog() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 200)
            try FileManager.default.removeItem(at: fixture.configURL)

            let outcome = CatalogStateStartup.resolve(
                configurationURL: fixture.configURL,
                defaults: .testConfiguration(root: root, catalog: fixture.catalogURL),
                backups: { _ in fixture.backupService }
            )

            XCTAssertEqual(outcome.mode, .legacy)
            XCTAssertEqual(try fixture.rowCount("event_assets"), 200)
            XCTAssertFalse(try CatalogStateStore(url: fixture.catalogURL).catalogOwnsState())
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    func testUnreadableConfigSuspendsWithoutTouchingIt() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 100)
            try writeFile(fixture.configURL, "{ not json")
            let outcome = fixture.resolve()
            XCTAssertEqual(outcome.mode, .suspended)
            XCTAssertEqual(try String(contentsOf: fixture.configURL, encoding: .utf8), "{ not json")
            XCTAssertFalse(try CatalogStateStore(url: fixture.catalogURL).catalogOwnsState())
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    func testSettingsOnlyConfigOverAReplacedCatalogSuspends() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 100)
            try ConfigurationStore(url: fixture.configURL).save(fixture.configuration, settingsOnly: true)
            let outcome = fixture.resolve()
            XCTAssertEqual(outcome.mode, .suspended)
            XCTAssertEqual(try fixture.rowCount("event_assets"), 100, "the old catalog's rows are untouched")
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    func testFreshInstallStartsOnTheCatalog() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("CameraToolkit/catalog.sqlite")
            let outcome = CatalogStateStartup.resolve(
                configurationURL: root.appendingPathComponent("CameraToolkit/config.json"),
                defaults: .testConfiguration(root: root, catalog: catalog),
                backups: { url in
                    CatalogBackupService(catalogURL: url, configurationURL: nil, localFolder: root.appendingPathComponent("Backups"), remoteFolder: nil)
                }
            )
            XCTAssertEqual(outcome.mode, .catalog(baseline: CatalogOwnedState()))
            XCTAssertFalse(outcome.shouldRewriteConfiguration)
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    // MARK: - Steady state

    func testMovesTrashAndTagsWriteOnlyTheChangedRows() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 5_000)
            guard case .catalog(let baseline) = fixture.resolve().mode else { return XCTFail("expected catalog mode") }
            let store = CatalogStateStore(url: fixture.catalogURL)
            var next = baseline

            // Move three photos to another event.
            let target = next.savedEvents[5].id
            for index in 0..<3 { next.photoEventAssignments[index].eventID = target }
            // Trash two.
            next.photoEventAssignments.removeSubrange(10..<12)
            // Tag one as storage-only.
            next.photoEventAssignments[20].immichUploadOverride = false
            // Rotate one, split one burst.
            next.displayOrientations["new|1|1"] = 1
            next.burstSplits.append(BurstSplit(memberPathKeys: ["x", "y"]))
            // Rename an event.
            next.savedEvents[0].name = "Renamed"

            let summary = try store.apply(from: baseline, to: next)

            XCTAssertEqual(summary.assignmentsDeleted, 3 + 2, "a moved photo's old row goes, the trashed ones go")
            XCTAssertEqual(summary.assignmentsWritten, 3 + 1)
            XCTAssertEqual(summary.eventsWritten, 1)
            XCTAssertEqual(summary.eventsDeleted, 0)
            XCTAssertEqual(summary.orientationsWritten, 1)
            XCTAssertEqual(summary.burstSplitsWritten, 1)
            // Rows keep insertion order: a moved photo reloads at the end.
            XCTAssertEqual(Self.orderInsensitive(try store.load()), Self.orderInsensitive(next.canonical().state))
            XCTAssertEqual(try fixture.rowCount("event_asset_locations"), 50 - 3 - 2 + 0, "untouched rows keep their presence")

            // Nothing changed → nothing written.
            XCTAssertTrue(try store.apply(from: next, to: next).isEmpty)
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    func testApplyRefusesToEraseEverythingOrWriteToAnUnmigratedCatalog() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 100)
            let store = CatalogStateStore(url: fixture.catalogURL)
            let legacy = CatalogOwnedState(configuration: fixture.configuration)
            var edited = legacy
            edited.savedEvents[0].name = "x"
            XCTAssertThrowsError(try store.apply(from: legacy, to: edited), "the catalog does not own the state yet")

            guard case .catalog(let baseline) = fixture.resolve().mode else { return XCTFail("expected catalog mode") }
            XCTAssertThrowsError(try store.apply(from: baseline, to: CatalogOwnedState()))
            XCTAssertEqual(try store.load(), baseline)
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    func testBootstrapNoLongerMirrorsAStaleConfigurationOverTheCatalog() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 300)
            guard case .catalog(let baseline) = fixture.resolve().mode else { return XCTFail("expected catalog mode") }
            var stale = fixture.configuration
            stale.photoEventAssignments.removeAll()
            stale.savedEvents.removeLast()

            _ = try CatalogStore(url: fixture.catalogURL).bootstrap(configuration: stale, createLibraryFolders: false)

            XCTAssertEqual(try CatalogStateStore(url: fixture.catalogURL).load(), baseline)
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    func testLegacyBootstrapNeverEmptiesTheMirrorFromAnEmptyConfiguration() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 100)
            _ = try CatalogStore(url: fixture.catalogURL).bootstrap(
                configuration: .testConfiguration(root: root, catalog: fixture.catalogURL),
                createLibraryFolders: false
            )
            XCTAssertEqual(try fixture.rowCount("event_assets"), 100)
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    func testWriterCoalescesSavesAndKeepsUnsavedStateOnFailure() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeLegacyLibrary(in: root, assignments: 300)
            guard case .catalog(let baseline) = fixture.resolve().mode else { return XCTFail("expected catalog mode") }
            let results = ResultBox()
            let emergency = root.appendingPathComponent("Emergency")
            let writer = CatalogStateWriter(
                store: CatalogStateStore(url: fixture.catalogURL),
                baseline: baseline,
                emergencyFolder: emergency,
                onResult: { results.append($0) }
            )
            var state = baseline
            for index in 0..<20 {
                state.photoEventAssignments[index].deviceID = "burst-\(index)"
                writer.submit(state)
            }
            writer.flush()
            XCTAssertEqual(try CatalogStateStore(url: fixture.catalogURL).load(), state)
            XCTAssertLessThanOrEqual(results.count, 20)

            // A refused write (erasing everything) changes nothing and
            // leaves the unsaved state on disk.
            writer.submit(CatalogOwnedState())
            writer.flush()
            XCTAssertEqual(try CatalogStateStore(url: fixture.catalogURL).load(), state)
            let files = try FileManager.default.contentsOfDirectory(atPath: emergency.path)
            XCTAssertEqual(files.filter { $0.hasPrefix("unsaved-events-") }.count, 1)
            XCTAssertTrue(results.lastIsFailure)

            // The next good save retries from the last written state.
            state.savedEvents[0].name = "Recovered"
            writer.submit(state)
            writer.flush()
            XCTAssertEqual(try CatalogStateStore(url: fixture.catalogURL).load(), state)
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
        }
    }

    private static func orderInsensitive(_ state: CatalogOwnedState) -> CatalogOwnedState {
        var sorted = state
        sorted.photoEventAssignments.sort { CatalogStore.eventAssetID($0) < CatalogStore.eventAssetID($1) }
        return sorted
    }

    // MARK: - Settings-only config.json

    func testSettingsOnlyEncodingRoundTripsSettingsAndKeepsTheSelection() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            var configuration = AppConfiguration.testConfiguration(root: root, catalog: catalog)
            let event = SavedCameraEvent(name: "Trip", eventDate: Date(timeIntervalSince1970: 1_750_000_000))
            configuration.savedEvents = [event]
            configuration.selectedEventID = event.id
            configuration.normalizeEventSelection()
            configuration.immichServerURL = "https://immich.example"

            let full = try ConfigurationStore.encode(configuration)
            XCTAssertEqual(try JSONDecoder().decode(AppConfiguration.self, from: full), configuration)

            let settings = try ConfigurationStore.encode(configuration, settingsOnly: true)
            var decoded = try JSONDecoder().decode(AppConfiguration.self, from: settings)
            XCTAssertTrue(decoded.savedEvents.isEmpty, "no event is invented from eventName")
            XCTAssertEqual(decoded.selectedEventID, event.id)
            XCTAssertEqual(decoded.immichServerURL, "https://immich.example")
            CatalogOwnedState(configuration: configuration).apply(to: &decoded)
            XCTAssertEqual(decoded, configuration)
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<CatalogStateChangeSummary, Error>] = []

    func append(_ result: Result<CatalogStateChangeSummary, Error>) {
        lock.lock(); results.append(result); lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return results.count
    }

    var lastIsFailure: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .failure = results.last { return true }
        return false
    }
}
