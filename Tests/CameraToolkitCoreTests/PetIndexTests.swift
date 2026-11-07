import CoreGraphics
import Foundation
import GRDB
import ImageIO
@testable import CameraToolkitCore
import XCTest

/// The pet index: its own file, the face index's tables, additive GRDB
/// migrations with a backup first, and a scan that never reaches the
/// catalog, the face data, or a photo.
final class PetIndexTests: XCTestCase {

    // MARK: - Schema and migrations

    /// `FaceIndexStore` runs unchanged on the pet index only while the
    /// tables match the catalog's face tables column for column.
    func testPetIndexHasTheCatalogFaceTablesColumnForColumn() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            try CatalogStore(url: catalog).prepareSchema()
            let pets = PetIndexDatabase.url(besideCatalog: catalog)
            XCTAssertEqual(pets.deletingLastPathComponent(), catalog.deletingLastPathComponent())
            try PetIndexDatabase.migrate(url: pets)

            for table in Self.faceTables {
                let catalogColumns = try columns(table, in: catalog)
                let petColumns = try columns(table, in: pets)
                XCTAssertFalse(catalogColumns.isEmpty, table)
                XCTAssertEqual(
                    petColumns.map(\.description),
                    catalogColumns.map(\.description),
                    "\(table) drifted from the catalog's face table"
                )
            }
            XCTAssertEqual(try indexNames(in: pets), try indexNames(in: catalog).filter { $0.hasPrefix("face") })
            XCTAssertEqual(try scalar("PRAGMA integrity_check", in: pets), "ok")
        }
    }

    func testANewPetIndexNeedsNoBackupAndACurrentOneIsNotBackedUpAgain() throws {
        try withTemporaryDirectory { root in
            let pets = root.appendingPathComponent(PetIndexDatabase.fileName)
            XCTAssertNil(try PetIndexDatabase.migrate(url: pets), "nothing to lose in a new file")
            XCTAssertNil(try PetIndexDatabase.migrate(url: pets), "an up-to-date file is left alone")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Backups").path))
            XCTAssertEqual(try appliedMigrations(in: pets), PetIndexDatabase.migrationIdentifiers)
        }
    }

    /// A later migration finds the file one step behind: the file is
    /// copied first (with every row), then upgraded in place.
    func testAPendingMigrationBacksUpTheIndexFirstAndKeepsEveryRow() throws {
        try withTemporaryDirectory { root in
            let pets = root.appendingPathComponent(PetIndexDatabase.fileName)
            let store = try PetIndexDatabase.open(url: pets)
            let pet = try store.createPerson(name: "Rex", isRoster: true)

            var next = PetIndexDatabase.migrator
            next.registerMigration("test-v2-additive") { database in
                try database.execute(sql: "ALTER TABLE faces ADD COLUMN test_note TEXT")
            }
            let now = Date(timeIntervalSince1970: 1_790_000_000)
            let backup = try XCTUnwrap(PetIndexDatabase.migrate(url: pets, now: now, using: next))

            XCTAssertEqual(backup.deletingLastPathComponent().lastPathComponent, PetIndexDatabase.backupFolderName)
            XCTAssertEqual(try scalar("PRAGMA integrity_check", in: backup), "ok")
            XCTAssertEqual(try scalar("SELECT name FROM people", in: backup), "Rex")
            XCTAssertFalse(try columns("faces", in: backup).contains { $0.name == "test_note" }, "the backup is the file as it was")

            XCTAssertTrue(try columns("faces", in: pets).contains { $0.name == "test_note" })
            XCTAssertEqual(try FaceIndexStore(url: pets, engine: PetFaceEngine.identifier).person(pet.id)?.name, "Rex")
            XCTAssertNil(try PetIndexDatabase.migrate(url: pets, now: now, using: next))
        }
    }

    // MARK: - Scanning

    /// The whole safety contract of a pet pass: dogs land in the pet index
    /// under "Dog N", the catalog's face tables come out byte-identical,
    /// the face skip rule still skips every photo, and no photo changed.
    func testAPetScanWritesOnlyThePetIndex() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            var configuration = testConfiguration(root: root)
            configuration.catalogDatabasePath = catalog.path
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let card = root.appendingPathComponent("card", isDirectory: true)
            var stacks: [OrganizeStack] = []
            for index in 1...3 {
                let url = card.appendingPathComponent(String(format: "DSC%05d.JPG", index))
                try writeJPEG(url, seed: UInt8(index))
                stacks.append(OrganizeStack(items: [try organizeItem(forFileAt: url)]))
            }
            let mediaBefore = try treeBytes(card)
            let datesBefore = try modificationDates(card)

            // People first, as the job runs them.
            let person = AnalyzedFace(
                box: NormalizedFaceBox(x: 0.4, y: 0.6, width: 0.1, height: 0.1),
                detScore: 0.9,
                embedding: FaceEmbeddingMath.l2Normalized([Float](repeating: 1, count: 512)),
                quality: 20,
                facePixels: 200
            )
            let faceReport = try FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .low))
                .scan(stacks: stacks, analyzer: CannedAnalyzer(faces: [person]))
            XCTAssertEqual(faceReport.facesDetected, 3)
            let catalogBefore = try faceTableDump(catalog)

            // Then dogs, into the pet index beside the catalog.
            let pets = PetIndexDatabase.url(besideCatalog: catalog)
            let petStore = try PetIndexDatabase.open(url: pets)
            let dog = AnalyzedFace(
                box: NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                detScore: 0.92,
                embedding: FaceEmbeddingMath.l2Normalized((0..<768).map { Float($0 % 7) + 1 }),
                quality: 40,
                facePixels: 320
            )
            let petOptions = FaceScanOptions.pets(mode: .low)
            let petReport = try FaceIndexService(store: petStore, options: petOptions)
                .scan(stacks: stacks, analyzer: CannedAnalyzer(faces: [dog]))
            XCTAssertEqual(petReport.photosProcessed, 3)
            XCTAssertEqual(petReport.facesDetected, 3)
            XCTAssertEqual(petReport.groupsCreated, 1)

            let groups = try petStore.otherGroups()
            XCTAssertEqual(groups.map(\.name), ["Dog 1"])
            XCTAssertEqual(groups.first?.faceCount, 3)
            XCTAssertEqual(try scalar("SELECT DISTINCT model FROM faces", in: pets), PetFaceEngine.identifier)
            XCTAssertEqual(try scalar("SELECT DISTINCT engine FROM face_photos", in: pets), PetFaceEngine.identifier)

            // Catalog: untouched, and the face skip rule still holds.
            XCTAssertEqual(try faceTableDump(catalog), catalogBefore)
            XCTAssertEqual(try scalar("SELECT DISTINCT model FROM faces", in: catalog), FaceEngine.identifier)
            let rescan = try FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .low))
                .scan(stacks: stacks, analyzer: CannedAnalyzer(faces: [person]))
            XCTAssertEqual(rescan.photosSkipped, 3)
            XCTAssertEqual(rescan.photosProcessed, 0)

            // Pets skip on their own stamp, too.
            let petRescan = try FaceIndexService(store: petStore, options: petOptions)
                .scan(stacks: stacks, analyzer: CannedAnalyzer(faces: [dog]))
            XCTAssertEqual(petRescan.photosSkipped, 3)

            // Media: same bytes, same dates.
            XCTAssertEqual(try treeBytes(card), mediaBefore)
            XCTAssertEqual(try modificationDates(card), datesBefore)
        }
    }

    /// Clearing the pet index removes pet rows only.
    func testClearingThePetIndexLeavesTheCatalogFaceIndexAlone() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            try CatalogStore(url: catalog).prepareSchema()
            let people = FaceIndexStore(url: catalog)
            _ = try people.createPerson(name: "Alex", isRoster: true)
            let petStore = try PetIndexDatabase.open(url: PetIndexDatabase.url(besideCatalog: catalog))
            _ = try petStore.createPerson(name: "Rex", isRoster: true)

            try petStore.clearFaceIndex()

            XCTAssertEqual(try petStore.faceIndexCounts().namedPeople, 0)
            XCTAssertEqual(try people.rosterPeople().map(\.name), ["Alex"])
        }
    }

    // MARK: - Engine rules

    func testScanStampsAreEngineSpecific() {
        let photo = FacePhotoRecord(
            pathKey: "k", path: "/card/DSC00001.JPG", fileName: "DSC00001.JPG",
            byteCount: 1, modifiedAt: Date(), scanGrade: .xhigh, engine: PetFaceEngine.identifier
        )
        XCTAssertFalse(photo.covers(.low), "a pet stamp never satisfies the face skip rule")
        XCTAssertTrue(photo.covers(.low, engine: PetFaceEngine.identifier))
        XCTAssertNotEqual(PetFaceEngine.identifier, FaceEngine.identifier)
    }

    func testPetClustersAreNamedDogN() throws {
        try withTemporaryDirectory { root in
            let petStore = try PetIndexDatabase.open(url: root.appendingPathComponent(PetIndexDatabase.fileName))
            XCTAssertEqual(petStore.groupNamePrefix, "Dog")
            XCTAssertEqual(try petStore.nextGroupName(), "Dog 1")
            _ = try petStore.createPerson(name: "Dog 4", isRoster: false)
            XCTAssertEqual(try petStore.nextGroupName(), "Dog 5")
            XCTAssertEqual(FaceIndexStore(url: root.appendingPathComponent("catalog.sqlite")).groupNamePrefix, "Person")

            XCTAssertTrue(FaceIndexService.isAutoGroupName("Dog 2", prefix: "Dog"))
            XCTAssertFalse(FaceIndexService.isAutoGroupName("Dog 2"), "a face re-match never dissolves a dog group")
            XCTAssertTrue(FaceIndexService.isAutoGroupName("Person 2"))
        }
    }

    func testPetScanOptionsCarryThePetDefaults() {
        let medium = FaceScanOptions.pets(mode: .med, fast: false)
        XCTAssertEqual(medium.mode, .med)
        XCTAssertFalse(medium.fast)
        XCTAssertEqual(medium.clusterThreshold, PetScanDefaults.clusterThreshold)
        XCTAssertEqual(medium.matchThreshold, PetScanDefaults.matchThreshold)
        XCTAssertEqual(medium.detScoreThreshold, PetScanDefaults.detScoreThreshold)
        XCTAssertEqual(medium.groupingMinFacePixels, PetScanDefaults.groupingMinDogPixels)
        XCTAssertEqual(medium.minimumFacePixels, 96)
        XCTAssertGreaterThan(medium.matchThreshold, medium.clusterThreshold)
        // Burst and video sampling follow the face grade unchanged.
        let faces = FaceScanOptions(mode: .high)
        let pets = FaceScanOptions.pets(mode: .high)
        XCTAssertEqual(pets.videoFrameStride, faces.videoFrameStride)
        XCTAssertEqual(pets.maximumVideoFrames, faces.maximumVideoFrames)
        XCTAssertEqual(pets.detectPixels, faces.detectPixels)
        XCTAssertEqual(FaceScanOptions.pets(mode: .xhigh).flipTTA, true)
    }

    // MARK: - Install contract

    func testThePetEngineCountsAsInstalledOnlyAfterItsReadyLine() throws {
        try withTemporaryDirectory { root in
            let installation = PetSidecarInstallation(root: root)
            let script = root.appendingPathComponent("pet_sidecar.py")
            XCTAssertFalse(installation.isInstalled(scriptURL: script))

            let python = installation.pythonURL
            try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: python)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
            XCTAssertFalse(installation.isInstalled(scriptURL: script), "no ready line yet")

            try Data().write(to: installation.readyMarkerURL)
            XCTAssertFalse(installation.isInstalled(scriptURL: script), "an empty ready line is a failed install")

            try Data("{\"event\":\"ready\"}".utf8).write(to: installation.readyMarkerURL)
            XCTAssertTrue(installation.isInstalled(scriptURL: script))
            XCTAssertFalse(installation.isInstalled(scriptURL: nil), "no bundled script, no engine")
        }
    }

    func testThePetSidecarScriptShipsWithCore() throws {
        let script = try XCTUnwrap(CoreResources.petSidecarScript.url)
        let source = try String(contentsOf: script, encoding: .utf8)
        // The script and the app must agree on the engine they stamp.
        XCTAssertTrue(source.contains("ENGINE = \"\(PetFaceEngine.identifier)\""))
        XCTAssertTrue(CoreResources.all.contains { $0.name == "pet_sidecar.py" })
    }

    // MARK: - Helpers

    private static let faceTables = ["face_photos", "people", "faces", "face_templates", "face_rejections"]

    private struct Column: CustomStringConvertible, Equatable {
        var name: String
        var type: String
        var notNull: Bool
        var primaryKey: Int
        var description: String { "\(name) \(type)\(notNull ? " NOT NULL" : "")\(primaryKey > 0 ? " PK\(primaryKey)" : "")" }
    }

    private func columns(_ table: String, in url: URL) throws -> [Column] {
        try CatalogDatabase.writer(for: url).read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))").map {
                Column(name: $0["name"], type: $0["type"], notNull: ($0["notnull"] as Int) == 1, primaryKey: $0["pk"])
            }
        }
    }

    private func indexNames(in url: URL) throws -> [String] {
        try CatalogDatabase.writer(for: url).read { database in
            try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name"
            )
        }
    }

    private func appliedMigrations(in url: URL) throws -> [String] {
        try CatalogDatabase.writer(for: url).read { database in
            try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    private func scalar(_ sql: String, in url: URL) throws -> String? {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read { try String.fetchOne($0, sql: sql) }
    }

    /// Every row of every face table, as text — what "untouched" compares.
    private func faceTableDump(_ url: URL) throws -> [String: [String]] {
        try CatalogDatabase.writer(for: url).read { database in
            var dump: [String: [String]] = [:]
            for table in Self.faceTables {
                dump[table] = try Row.fetchAll(database, sql: "SELECT * FROM \(table) ORDER BY 1, 2").map(\.description)
            }
            return dump
        }
    }

    private func modificationDates(_ root: URL) throws -> [String: Date] {
        var dates: [String: Date] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)
            dates[name] = attributes[.modificationDate] as? Date
        }
        return dates
    }

    private func organizeItem(forFileAt url: URL) throws -> OrganizeItem {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? Int64) ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        return OrganizeItem(
            primary: OrganizeFile(path: url.path, size: size, modifiedAt: modified),
            kind: .photo,
            captureDate: modified,
            hasCameraDate: false
        )
    }

    /// A decodable flat JPEG — the stub engines decide what is "in" it.
    private func writeJPEG(_ url: URL, seed: UInt8) throws {
        let size = 640
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("Could not create a test bitmap") }
        let shade = CGFloat(seed) / 10
        context.setFillColor(CGColor(red: shade, green: 0.5, blue: 1 - shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try writeFile(url, data as Data)
    }
}

/// Canned engine results: every image "contains" the same detections.
private final class CannedAnalyzer: FaceAnalyzing, @unchecked Sendable {
    let displayName = "CannedAnalyzer"
    let faces: [AnalyzedFace]

    init(faces: [AnalyzedFace]) {
        self.faces = faces
    }

    func analyze(_ image: CGImage, options: FaceScanOptions) throws -> [AnalyzedFace] {
        faces
    }
}
