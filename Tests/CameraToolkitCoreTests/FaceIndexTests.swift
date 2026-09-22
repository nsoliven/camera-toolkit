import CoreGraphics
import Foundation
import SQLite3
@testable import CameraToolkitCore
import XCTest

final class FaceIndexTests: XCTestCase {

    // MARK: - Schema

    func testBootstrapCreatesFaceSchemaWithForeignKeys() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )

            for table in ["face_photos", "people", "faces", "face_templates", "face_rejections"] {
                XCTAssertEqual(
                    scalarInt("SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name = '\(table)'", database: catalog),
                    1,
                    "missing table \(table)"
                )
            }
            XCTAssertEqual(
                scalarString("PRAGMA integrity_check", database: catalog),
                "ok"
            )

            // faces must reference a scanned photo and a real person.
            let faceKeys = scalarRows(
                "PRAGMA foreign_key_list(faces)", database: catalog
            ).flatMap { $0 }.compactMap { $0 }.joined(separator: ";")
            XCTAssertTrue(faceKeys.contains("face_photos"))
            XCTAssertTrue(faceKeys.contains("people"))

            // people carries the user-picked cover column.
            XCTAssertTrue(
                scalarRows("PRAGMA table_info(people)", database: catalog)
                    .contains { $0.count > 1 && $0[1] == "cover_face_id" }
            )

            // Re-running bootstrap is a no-op.
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            XCTAssertEqual(scalarString("PRAGMA integrity_check", database: catalog), "ok")
        }
    }

    func testBootstrapGraftsCoverColumnOntoOlderCatalogs() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )

            // Simulate a catalog from before the column existed.
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(catalog.path, &database), SQLITE_OK)
            XCTAssertEqual(
                sqlite3_exec(database, "ALTER TABLE people DROP COLUMN cover_face_id", nil, nil, nil),
                SQLITE_OK
            )
            sqlite3_close(database)
            XCTAssertFalse(
                scalarRows("PRAGMA table_info(people)", database: catalog)
                    .contains { $0.count > 1 && $0[1] == "cover_face_id" }
            )

            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            XCTAssertTrue(
                scalarRows("PRAGMA table_info(people)", database: catalog)
                    .contains { $0.count > 1 && $0[1] == "cover_face_id" }
            )
            XCTAssertEqual(scalarString("PRAGMA integrity_check", database: catalog), "ok")
        }
    }

    // MARK: - Person cover

    func testCoverFacePrefersPinnedChoice() throws {
        try withFaceStore { store, _ in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let photo = photoRecord("COV1.JPG")
            let sharp = faceRecord(photo, detScore: 0.95, state: .confirmed, personID: dad.id)
            let blurry = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                detScore: 0.5,
                state: .confirmed,
                personID: dad.id
            )
            try store.replaceFaces(photo: photo, faces: [sharp, blurry])

            // Auto-pick: the most confident detection.
            XCTAssertEqual(try store.coverFace(personID: dad.id)?.id, sharp.id)
            XCTAssertNil(try store.person(dad.id)?.coverFaceID)

            // The pinned face wins over det_score and persists on the person.
            XCTAssertTrue(try store.setCoverFace(personID: dad.id, faceID: blurry.id))
            XCTAssertEqual(try store.coverFace(personID: dad.id)?.id, blurry.id)
            XCTAssertEqual(try store.person(dad.id)?.coverFaceID, blurry.id)
        }
    }

    func testCoverFaceFallsBackWhenPinnedFaceLeaves() throws {
        try withFaceStore { store, _ in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let photo = photoRecord("COV2.JPG")
            let sharp = faceRecord(photo, detScore: 0.95, state: .confirmed, personID: dad.id)
            let loose = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                detScore: 0.5,
                state: .proposed,
                personID: dad.id
            )
            try store.replaceFaces(photo: photo, faces: [sharp, loose])
            XCTAssertTrue(try store.setCoverFace(personID: dad.id, faceID: loose.id))
            XCTAssertEqual(try store.coverFace(personID: dad.id)?.id, loose.id)

            // Rejecting the cover face unpins it; the highest-score member
            // stands in again.
            try store.unassignFace(loose.id)
            XCTAssertNil(try store.person(dad.id)?.coverFaceID)
            XCTAssertEqual(try store.coverFace(personID: dad.id)?.id, sharp.id)

            // A rescan that drops the pinned face falls back the same way —
            // the stale id on the row matches nothing of this person.
            let pinned = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                detScore: 0.5,
                state: .proposed,
                personID: dad.id
            )
            try store.replaceFaces(photo: photo, faces: [pinned])
            XCTAssertTrue(try store.setCoverFace(personID: dad.id, faceID: pinned.id))
            try store.replaceFaces(photo: photo, faces: [])
            XCTAssertEqual(try store.coverFace(personID: dad.id)?.id, sharp.id)
        }
    }

    func testSetCoverFaceRefusesAFaceOwnedBySomeoneElse() throws {
        try withFaceStore { store, _ in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let mom = try store.createPerson(name: "Mom", isRoster: true)
            let photo = photoRecord("COV3.JPG")
            let momFace = faceRecord(photo, state: .confirmed, personID: mom.id)
            try store.replaceFaces(photo: photo, faces: [momFace])

            XCTAssertFalse(try store.setCoverFace(personID: dad.id, faceID: momFace.id))
            XCTAssertNil(try store.person(dad.id)?.coverFaceID)
            // Dad's cover stays on the automatic pick — which is nil here
            // since Dad has no faces at all.
            XCTAssertNil(try store.coverFace(personID: dad.id))
        }
    }

    // MARK: - Embedding math

    func testCosineAndCentroidMath() throws {
        let a = testEmbedding(seed: 1)
        let sameA = testEmbedding(seed: 1)
        let nearA = testEmbedding(seed: 1, noise: 0.2)
        let other = testEmbedding(seed: 2)

        XCTAssertEqual(FaceEmbeddingMath.cosine(a, sameA), 1, accuracy: 0.001)
        XCTAssertGreaterThan(FaceEmbeddingMath.cosine(a, nearA), 0.9)
        XCTAssertLessThan(FaceEmbeddingMath.cosine(a, other), 0.2)
        XCTAssertEqual(FaceEmbeddingMath.cosine(a, []), -1)

        let normalized = FaceEmbeddingMath.l2Normalized([3, 4])
        XCTAssertEqual(sqrt(normalized[0] * normalized[0] + normalized[1] * normalized[1]), 1, accuracy: 0.0001)

        let centroid = FaceEmbeddingMath.centroid([a, nearA])!
        XCTAssertEqual(centroid.count, 512)
        XCTAssertGreaterThan(FaceEmbeddingMath.cosine(centroid, a), 0.95)
        XCTAssertNil(FaceEmbeddingMath.centroid([]))

        // The SQLite BLOB round-trip preserves the vector bit-for-bit.
        let record = FaceRecord(
            photoID: "p",
            box: NormalizedFaceBox(x: 0, y: 0, width: 1, height: 1),
            detScore: 1,
            embedding: a
        )
        XCTAssertEqual(FaceRecord.embedding(from: try XCTUnwrap(record.embeddingData)), a)
    }

    // MARK: - Confirmed faces are frozen

    func testConfirmedFacesAreFrozen() throws {
        try withFaceStore { store, _ in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let photo = photoRecord("DSC00001.ARW")
            let confirmed = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.10, y: 0.10, width: 0.20, height: 0.20),
                embedding: testEmbedding(seed: 7),
                state: .confirmed,
                personID: dad.id
            )
            try store.replaceFaces(photo: photo, faces: [confirmed])

            // A rescan of the same photo detects the overlapping face again
            // plus a disjoint new one. The confirmed row keeps its id and
            // label — the overlap refreshes it in place, never duplicates it.
            let redetected = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.11, y: 0.11, width: 0.20, height: 0.20),
                embedding: testEmbedding(seed: 8)
            )
            let fresh = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.60, y: 0.60, width: 0.15, height: 0.15),
                embedding: testEmbedding(seed: 9)
            )
            try store.replaceFaces(photo: photo, faces: [redetected, fresh])

            let stored = try store.faces(photoID: photo.pathKey)
            XCTAssertEqual(stored.count, 2)
            XCTAssertTrue(stored.contains { $0.id == confirmed.id && $0.state == .confirmed && $0.personID == dad.id })
            XCTAssertTrue(stored.contains { $0.id == fresh.id && $0.state == .cached })
            XCTAssertFalse(stored.contains { $0.id == redetected.id })
            XCTAssertEqual(try store.photos(pathKeys: [photo.pathKey])[photo.pathKey]?.faceCount, 2)

            // Confirmed faces cannot be reassigned or unassigned.
            let mom = try store.createPerson(name: "Mom", isRoster: true)
            try store.assignFace(confirmed.id, to: mom.id, state: .proposed, score: 0.9)
            try store.unassignFace(confirmed.id)
            let after = try store.face(id: confirmed.id)
            XCTAssertEqual(after?.state, .confirmed)
            XCTAssertEqual(after?.personID, dad.id)

            // Junk never removes a roster person or their confirmed faces.
            try store.deletePersonAndFaces(dad.id)
            XCTAssertNotNil(try store.person(dad.id))
            XCTAssertEqual(try store.face(id: confirmed.id)?.state, .confirmed)
        }
    }

    /// A rescan that finds a confirmed face again refreshes that row in
    /// place: the id and label the owner reviewed stay, the measurement
    /// (box, score, vector, quality, engine) becomes the new detection's.
    /// This is how a named gallery migrates into a new engine's embedding
    /// space without anyone re-tagging.
    func testRescanRefreshesConfirmedFaceInPlace() throws {
        try withFaceStore { store, _ in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let photo = photoRecord("RF1.JPG")
            // A row from the previous engine, confirmed by the owner.
            let original = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.10, y: 0.10, width: 0.20, height: 0.20),
                detScore: 0.9,
                embedding: testEmbedding(seed: 7),
                quality: 12,
                facePixels: 90,
                model: "w600k_r50"
            )
            try store.replaceFaces(photo: photo, faces: [original])
            try store.assignFace(original.id, to: dad.id, state: .confirmed, score: 0.9)
            XCTAssertEqual(try store.face(id: original.id)?.state, .confirmed)

            let refreshed = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.12, y: 0.12, width: 0.20, height: 0.20),
                detScore: 0.97,
                embedding: testEmbedding(seed: 8),
                quality: 21,
                facePixels: 130
            )
            let elsewhere = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.60, y: 0.60, width: 0.15, height: 0.15),
                detScore: 0.8,
                embedding: testEmbedding(seed: 9),
                quality: 18,
                facePixels: 96
            )
            try store.replaceFaces(photo: photo, faces: [refreshed, elsewhere])

            let stored = try store.faces(photoID: photo.pathKey)
            XCTAssertEqual(stored.count, 2)
            XCTAssertEqual(stored.filter { $0.state == .confirmed }.count, 1)
            let kept = try XCTUnwrap(store.face(id: original.id))
            XCTAssertEqual(kept.state, .confirmed)
            XCTAssertEqual(kept.personID, dad.id)
            XCTAssertEqual(kept.embedding, testEmbedding(seed: 8))
            XCTAssertEqual(kept.quality, 21)
            XCTAssertEqual(kept.facePixels, 130)
            XCTAssertEqual(kept.detScore, 0.97)
            XCTAssertEqual(kept.box.x, 0.12, accuracy: 1e-9)
            XCTAssertEqual(kept.model, FaceEngine.identifier)
            // The overlapping detection was folded in, not inserted; the
            // disjoint one is a fresh cached row.
            XCTAssertNil(try store.face(id: refreshed.id))
            let added = try XCTUnwrap(store.face(id: elsewhere.id))
            XCTAssertEqual(added.state, .cached)
            XCTAssertNil(added.personID)
            XCTAssertEqual(try store.photos(pathKeys: [photo.pathKey])[photo.pathKey]?.faceCount, 2)
        }
    }

    /// Rows from another engine live in a different embedding space:
    /// matching, grouping, and the roster gallery read only the current
    /// engine's vectors.
    func testMatchingIgnoresRowsFromAnotherEngine() throws {
        try withFaceStore { store, _ in
            let photo = photoRecord("ENG1.JPG")
            let stale = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                embedding: testEmbedding(seed: 1),
                model: "w600k_r50"
            )
            let current = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                embedding: testEmbedding(seed: 2)
            )
            try store.replaceFaces(photo: photo, faces: [stale, current])
            XCTAssertEqual(try store.matchableFaces().map(\.id), [current.id])

            let group = try store.createPerson(name: "Person 1", isRoster: false)
            try store.assignFace(stale.id, to: group.id, state: .other, score: 0.9)
            try store.assignFace(current.id, to: group.id, state: .other, score: 0.9)
            let embeddings = try store.groupEmbeddings()
            XCTAssertEqual(embeddings[group.id]?.count, 1)
            XCTAssertEqual(embeddings[group.id]?.first, testEmbedding(seed: 2))

            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let gallery = photoRecord("ENG2.JPG")
            let staleTemplate = faceRecord(
                gallery,
                box: NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                embedding: testEmbedding(seed: 3),
                state: .confirmed,
                personID: dad.id,
                model: "w600k_r50"
            )
            let currentTemplate = faceRecord(
                gallery,
                box: NormalizedFaceBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                embedding: testEmbedding(seed: 4),
                state: .confirmed,
                personID: dad.id
            )
            try store.replaceFaces(photo: gallery, faces: [staleTemplate, currentTemplate])
            try store.addTemplate(personID: dad.id, faceID: staleTemplate.id)
            try store.addTemplate(personID: dad.id, faceID: currentTemplate.id)
            let templates = try store.rosterTemplates()
            XCTAssertEqual(templates.count, 1)
            XCTAssertEqual(templates.first?.embedding, testEmbedding(seed: 4))
        }
    }

    // MARK: - Scan skip rules

    func testScanGradeOrderingAndFileIdentity() throws {
        XCTAssertTrue(FaceScanGrade.low.covers(.low))
        XCTAssertTrue(FaceScanGrade.high.covers(.med))
        XCTAssertFalse(FaceScanGrade.low.covers(.med))
        XCTAssertFalse(FaceScanGrade.none.covers(.low))

        let modified = Date(timeIntervalSince1970: 1_752_000_000)
        let record = FacePhotoRecord(
            pathKey: EventStorageLocations.pathKey("/card/DCIM/DSC1.ARW"),
            path: "/card/DCIM/DSC1.ARW",
            fileName: "DSC1.ARW",
            byteCount: 100,
            modifiedAt: modified
        )
        XCTAssertTrue(record.describes(path: "/card/DCIM/DSC1.ARW", size: 100, modifiedAt: modified))
        XCTAssertFalse(record.describes(path: "/card/DCIM/DSC1.ARW", size: 101, modifiedAt: modified))
        XCTAssertFalse(record.describes(path: "/card/DCIM/DSC1.ARW", size: 100, modifiedAt: modified.addingTimeInterval(120)))
        XCTAssertFalse(record.describes(path: "/other/DSC1.ARW", size: 100, modifiedAt: modified))
    }

    func testScanProcessesNewPhotosAndSkipsKnownOnes() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )

            // A flat-gradient JPEG is decodable but contains no faces — the
            // photo is still recorded so a replug never rescans it.
            let jpegURL = root.appendingPathComponent("card/DSC00001.JPG")
            try writeJPEG(jpegURL, seed: 1)
            let item = try organizeItem(forFileAt: jpegURL)
            let service = FaceIndexService(catalogURL: catalog)

            var report = try service.scan(stacks: [OrganizeStack(items: [item])], analyzer: StubAnalyzer())
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(report.photosSkipped, 0)
            XCTAssertEqual(report.facesDetected, 0)

            // Same file identity + grade covers the mode → skipped.
            report = try service.scan(stacks: [OrganizeStack(items: [try organizeItem(forFileAt: jpegURL)])], analyzer: StubAnalyzer())
            XCTAssertEqual(report.photosProcessed, 0)
            XCTAssertEqual(report.photosSkipped, 1)

            // A changed file (new bytes, new mtime) is not "already scanned".
            try writeJPEG(jpegURL, seed: 2)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(3_600)],
                ofItemAtPath: jpegURL.path
            )
            report = try service.scan(stacks: [OrganizeStack(items: [try organizeItem(forFileAt: jpegURL)])], analyzer: StubAnalyzer())
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(report.photosSkipped, 0)
        }
    }

    /// The skip rule is engine-aware: a photo stamped by another engine —
    /// even at the top grade — is re-read, because its rows live in a
    /// different embedding space. A current-engine stamp at that grade
    /// skips as before.
    func testScanRescansPhotosStampedByAnotherEngine() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            let jpegURL = root.appendingPathComponent("card/DSC00031.JPG")
            try writeJPEG(jpegURL, seed: 1)
            let item = try organizeItem(forFileAt: jpegURL)
            let file = item.primary
            let store = FaceIndexStore(url: catalog)
            func stamp(_ grade: FaceScanGrade, engine: String) throws {
                try store.replaceFaces(
                    photo: FacePhotoRecord(
                        pathKey: file.pathKey,
                        path: file.path,
                        fileName: file.name,
                        byteCount: file.size,
                        modifiedAt: file.modifiedAt,
                        scanGrade: grade,
                        engine: engine
                    ),
                    faces: []
                )
            }

            // XHIGH from the old engine does not cover a LOW request.
            try stamp(.xhigh, engine: "")
            let analyzer = StubAnalyzer()
            let service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .low))
            var report = try service.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.photosSkipped, 0)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(analyzer.calls, 1)
            let restamped = try XCTUnwrap(store.photos(pathKeys: [file.pathKey])[file.pathKey])
            XCTAssertEqual(restamped.engine, FaceEngine.identifier)
            XCTAssertEqual(restamped.scanGrade, .low)

            // The same grade from the current engine is covered and skipped
            // — the engine is never called.
            try stamp(.xhigh, engine: FaceEngine.identifier)
            report = try service.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.photosSkipped, 1)
            XCTAssertEqual(report.photosProcessed, 0)
            XCTAssertEqual(analyzer.calls, 1)
        }
    }

    /// An engine failure counts the photo failed and leaves no
    /// `face_photos` row behind — the next pass must pick it up again
    /// instead of treating a crash as "scanned, no faces".
    func testEngineFailureLeavesThePhotoUnstamped() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            let jpegURL = root.appendingPathComponent("card/DSC00032.JPG")
            try writeJPEG(jpegURL, seed: 2)
            let item = try organizeItem(forFileAt: jpegURL)
            let store = FaceIndexStore(url: catalog)
            let service = FaceIndexService(catalogURL: catalog)

            let failing = StubAnalyzer(error: FaceIndexError.engineFailed("The face sidecar exited."))
            var report = try service.scan(items: [item], analyzer: failing)
            XCTAssertEqual(report.photosFailed, 1)
            XCTAssertEqual(report.photosProcessed, 0)
            XCTAssertEqual(report.photosSkipped, 0)
            XCTAssertEqual(failing.calls, 1)
            XCTAssertNil(try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey])

            // A working engine on the next pass reads the photo.
            let working = StubAnalyzer(faces: [analyzedFace()])
            report = try service.scan(items: [item], analyzer: working)
            XCTAssertEqual(report.photosSkipped, 0)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(report.facesDetected, 1)
            XCTAssertEqual(working.calls, 1)
            XCTAssertEqual(
                try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade,
                .low
            )
        }
    }

    /// The mode's size floor is measured on the native image: a face the
    /// engine returns below it is dropped before storage; one above it is
    /// stored with the engine's quality and pixel size readable back.
    func testScanAppliesTheSizeFloorAndStoresQuality() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            // writeJPEG paints 640 px, so 0.02 of it is 12.8 px — under
            // LOW's 64 px floor.
            let jpegURL = root.appendingPathComponent("card/DSC00033.JPG")
            try writeJPEG(jpegURL, seed: 3)
            let item = try organizeItem(forFileAt: jpegURL)
            let store = FaceIndexStore(url: catalog)

            let tiny = analyzedFace(
                box: NormalizedFaceBox(x: 0.4, y: 0.4, width: 0.02, height: 0.02),
                facePixels: 12.8
            )
            var service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .low))
            var report = try service.scan(items: [item], analyzer: StubAnalyzer(faces: [tiny]))
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(report.facesDetected, 0)
            XCTAssertTrue(try store.faces(photoID: item.primary.pathKey).isEmpty)
            let stamped = try XCTUnwrap(store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey])
            XCTAssertEqual(stamped.scanGrade, .low)
            XCTAssertEqual(stamped.faceCount, 0)

            // 0.25 of 640 px is 160 px — comfortably over MED's 40 px floor.
            // MED re-reads the photo (LOW does not cover it).
            let big = analyzedFace(
                box: NormalizedFaceBox(x: 0.3, y: 0.3, width: 0.25, height: 0.25),
                detScore: 0.93,
                quality: 23.5,
                facePixels: 160
            )
            service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .med))
            report = try service.scan(items: [item], analyzer: StubAnalyzer(faces: [big]))
            XCTAssertEqual(report.facesDetected, 1)
            let stored = try XCTUnwrap(store.faces(photoID: item.primary.pathKey).first)
            XCTAssertEqual(stored.detScore, 0.93)
            XCTAssertEqual(stored.quality, 23.5)
            XCTAssertEqual(stored.facePixels, 160)
            XCTAssertEqual(stored.embedding?.count, 512)
            XCTAssertEqual(stored.model, FaceEngine.identifier)
            XCTAssertEqual(stored.scanGrade, .med)
            XCTAssertEqual(stored.state, .cached)
        }
    }

    // MARK: - Burst sampling

    func testScanTargetsSampleFirstMiddleLastOfABurst() {
        // Same burst, same scene: LOW/MED decode a first/middle/last sample,
        // never all eighty frames.
        let burst = OrganizeStack(items: (0..<80).map { stubItem("B0001_DSC\($0).ARW") })
        let targets = FaceIndexService.scanTargets(for: [burst], mode: .low)
        XCTAssertEqual(targets.map(\.primary.name), ["B0001_DSC0.ARW", "B0001_DSC40.ARW", "B0001_DSC79.ARW"])
        XCTAssertEqual(FaceIndexService.scanTargets(for: [burst], mode: .med).count, 3)

        // HIGH and above still walk every frame.
        XCTAssertEqual(FaceIndexService.scanTargets(for: [burst], mode: .high).count, 80)
        XCTAssertEqual(FaceIndexService.scanTargets(for: [burst], mode: .xhigh).count, 80)
    }

    func testScanTargetsSinglesVideosAndCorruptFrames() {
        let single = OrganizeStack(items: [stubItem("DSC00001.JPG", kind: .photo)])
        let video = OrganizeStack(items: [stubItem("C0001.MP4", kind: .video)])
        let sidecar = OrganizeStack(items: [stubItem("DSC00001.XMP", kind: .other)])
        var targets = FaceIndexService.scanTargets(for: [single, video, sidecar], mode: .low)
        XCTAssertEqual(targets.map(\.primary.name), ["DSC00001.JPG", "C0001.MP4"])

        // Tiny sample frames drop out — but the burst keeps at least one.
        let burst = OrganizeStack(items: [
            stubItem("B0001_DSC1.ARW", size: 1_000),       // corrupt/tiny
            stubItem("B0001_DSC2.ARW"),
            stubItem("B0001_DSC3.ARW"),
            stubItem("B0001_DSC4.ARW", size: 1_000),       // corrupt/tiny
        ])
        targets = FaceIndexService.scanTargets(for: [burst], mode: .low)
        XCTAssertEqual(targets.map(\.primary.name), ["B0001_DSC2.ARW", "B0001_DSC3.ARW"])

        let allTiny = OrganizeStack(items: [
            stubItem("B0001_DSC1.ARW", size: 1_000),
            stubItem("B0001_DSC2.ARW", size: 1_000),
        ])
        XCTAssertEqual(FaceIndexService.scanTargets(for: [allTiny], mode: .low).count, 1)
    }

    func testScanProcessesSampledBurstFramesOnly() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )

            // Six-frame burst + one single. Sampling touches frames 0, 3, 5
            // and the single — frames 1, 2, 4 are never decoded or recorded.
            var burstItems: [OrganizeItem] = []
            for index in 0..<6 {
                let url = root.appendingPathComponent("card/B0001_DSC0000\(index).JPG")
                try writeJPEG(url, seed: UInt8(index + 1), padToBytes: 70_000)
                burstItems.append(try organizeItem(forFileAt: url))
            }
            let singleURL = root.appendingPathComponent("card/DSC00050.JPG")
            try writeJPEG(singleURL, seed: 9)
            let single = try organizeItem(forFileAt: singleURL)

            let service = FaceIndexService(catalogURL: catalog)
            let report = try service.scan(
                stacks: [OrganizeStack(items: burstItems), OrganizeStack(items: [single])],
                analyzer: StubAnalyzer()
            )
            XCTAssertEqual(report.photosConsidered, 4)
            XCTAssertEqual(report.photosProcessed, 4)

            let recorded = try FaceIndexStore(url: catalog).photos(pathKeys: burstItems.map(\.primary.pathKey))
            XCTAssertEqual(
                Set(recorded.keys),
                Set([burstItems[0], burstItems[3], burstItems[5]].map(\.primary.pathKey))
            )
        }
    }

    // MARK: - Jobs telemetry

    /// The scan reports live detail for the Jobs window on the existing
    /// progress channel: the pipeline step, real counters, byte totals,
    /// and — in the debug pane — the engine that ran.
    func testScanReportsTelemetryOnProgressUpdates() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )

            let urlA = root.appendingPathComponent("card/DSC_A.JPG")
            let urlB = root.appendingPathComponent("card/DSC_B.JPG")
            try writeJPEG(urlA, seed: 1)
            try writeJPEG(urlB, seed: 2)
            let itemA = try organizeItem(forFileAt: urlA)
            let itemB = try organizeItem(forFileAt: urlB)
            let totalBytes = itemA.primary.size + itemB.primary.size

            // One canned face per photo, so the counter is predictable.
            let detection = analyzedFace(
                box: NormalizedFaceBox(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                detScore: 0.9
            )
            let recorder = ProgressRecorder()
            let service = FaceIndexService(catalogURL: catalog)
            let report = try service.scan(
                // One item per stack — a multi-item stack is a burst and
                // LOW samples it instead of scanning every frame.
                stacks: [OrganizeStack(items: [itemA]), OrganizeStack(items: [itemB])],
                analyzer: StubAnalyzer(faces: [detection]),
                progress: recorder.handler
            )
            XCTAssertEqual(report.photosProcessed, 2)
            XCTAssertEqual(report.facesDetected, 2)

            let updates = recorder.updates
            XCTAssertFalse(updates.isEmpty)
            // Every emission during the scan carries telemetry — the pane
            // never shows a bare "Detecting faces" with nothing behind it.
            let telemetryUpdates = updates.compactMap(\.telemetry)
            XCTAssertEqual(telemetryUpdates.count, updates.count)

            let last = try XCTUnwrap(telemetryUpdates.last)
            // Test doubles name themselves; a real run lists the sidecar.
            XCTAssertEqual(last.models, ["StubAnalyzer"])
            XCTAssertTrue(last.facts.contains { $0.contains("LOW") })
            XCTAssertEqual(last.counter("Faces"), 2)
            // The scan ended in the match/group stage with nothing in flight.
            XCTAssertTrue(last.activeItems.isEmpty)

            // Byte counters cover every scanned file — the graph's input.
            // (The trailing Match/Group updates count faces, not bytes.)
            let lastScanUpdate = try XCTUnwrap(updates.last { $0.phase == "Detecting faces" })
            XCTAssertEqual(lastScanUpdate.totalBytes, totalBytes)
            XCTAssertEqual(lastScanUpdate.processedBytes, totalBytes)
            XCTAssertEqual(lastScanUpdate.processedFiles, 2)
        }
    }

    /// The vectors-only rematch still describes itself — "Match"/"Group"
    /// stage, no fake decode work.
    func testRematchRosterReportsMatchGroupTelemetry() throws {
        try withFaceStore { store, catalog in
            let photo = photoRecord("R1.JPG")
            let face = faceRecord(photo, embedding: testEmbedding(seed: 71))
            try store.replaceFaces(photo: photo, faces: [face])

            let recorder = ProgressRecorder()
            try FaceIndexService(catalogURL: catalog).rematchRoster(progress: recorder.handler)

            let telemetryUpdates = recorder.updates.compactMap(\.telemetry)
            XCTAssertFalse(telemetryUpdates.isEmpty)
            XCTAssertTrue(telemetryUpdates.contains { $0.step == "Match" })
            XCTAssertEqual(telemetryUpdates.last?.step, "Group")
            XCTAssertTrue(
                telemetryUpdates.allSatisfy { $0.facts.contains("Vectors only — no decode, no ML") }
            )
        }
    }

    // MARK: - Match, cluster, review

    func testRosterMatchProposesAndGroupsLeftovers() throws {
        try withFaceStore { store, catalog in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let galleryPhoto = photoRecord("G1.JPG")
            let galleryFace = faceRecord(
                galleryPhoto,
                embedding: testEmbedding(seed: 11),
                state: .confirmed,
                personID: dad.id
            )
            try store.replaceFaces(photo: galleryPhoto, faces: [galleryFace])
            try store.addTemplate(personID: dad.id, faceID: galleryFace.id)

            let newPhoto = photoRecord("N1.JPG")
            let nearDad = faceRecord(newPhoto, embedding: testEmbedding(seed: 11, noise: 0.15))
            let stranger = faceRecord(newPhoto, embedding: testEmbedding(seed: 99))
            try store.replaceFaces(photo: newPhoto, faces: [nearDad, stranger])

            // One stranger is a cluster of one; the roster match is the
            // point here, so let a singleton become a group.
            try FaceIndexService(
                catalogURL: catalog,
                options: FaceScanOptions(minimumGroupFaces: 1)
            ).rematchRoster()

            let proposed = try store.face(id: nearDad.id)
            XCTAssertEqual(proposed?.state, .proposed)
            XCTAssertEqual(proposed?.personID, dad.id)
            XCTAssertGreaterThan(proposed?.matchScore ?? 0, 0.48)

            let grouped = try store.face(id: stranger.id)
            XCTAssertEqual(grouped?.state, .other)
            XCTAssertNotNil(grouped?.personID)
            let group = try store.person(grouped!.personID!)
            XCTAssertEqual(group?.isRoster, false)

            XCTAssertEqual(try store.unsureFaces().map(\.id), [nearDad.id])
            XCTAssertEqual(try store.otherGroups().count, 1)
        }
    }

    func testClusteringGroupsBySimilarity() throws {
        try withFaceStore { store, catalog in
            let photo = photoRecord("C1.JPG")
            let a1 = faceRecord(photo, detScore: 0.95, embedding: testEmbedding(seed: 21))
            let a2 = faceRecord(photo, detScore: 0.90, embedding: testEmbedding(seed: 21, noise: 0.1))
            let b1 = faceRecord(photo, detScore: 0.85, embedding: testEmbedding(seed: 42))
            let loner = faceRecord(photo, detScore: 0.80, embedding: testEmbedding(seed: 77))
            try store.replaceFaces(photo: photo, faces: [a1, a2, b1, loner])

            // Similarity is under test, not the group-size floor.
            try FaceIndexService(
                catalogURL: catalog,
                options: FaceScanOptions(minimumGroupFaces: 1)
            ).rematchRoster()

            let storedA1 = try store.face(id: a1.id)
            let storedA2 = try store.face(id: a2.id)
            let storedB1 = try store.face(id: b1.id)
            let storedLoner = try store.face(id: loner.id)

            XCTAssertEqual(storedA1?.state, .other)
            XCTAssertEqual(storedA1?.personID, storedA2?.personID)
            XCTAssertNotEqual(storedA1?.personID, storedB1?.personID)
            XCTAssertNotEqual(storedA1?.personID, storedLoner?.personID)
            XCTAssertNotEqual(storedB1?.personID, storedLoner?.personID)

            // Groups get stable "Person N" labels.
            let names = try store.otherGroups().map(\.name).sorted()
            XCTAssertEqual(names, ["Person 1", "Person 2", "Person 3"])
        }
    }

    /// Neighbors are similar enough to join a walking average, but the
    /// first and last face are different people. They must not land in
    /// one Person N drawer. Average linkage splits a 50° chain into
    /// pairs, so the floor is lowered to let pairs persist.
    func testSimilarChainDoesNotCollapseIntoOneGroup() throws {
        try withFaceStore { store, catalog in
            let photo = photoRecord("CHAIN.JPG")
            let step = Float.pi / 180 * 50
            var faces: [FaceRecord] = []
            for index in 0..<6 {
                let angle = step * Float(index)
                var vector = [Float](repeating: 0, count: 8)
                vector[0] = cos(angle)
                vector[1] = sin(angle)
                let box = NormalizedFaceBox(x: 0.05 + Double(index) * 0.12, y: 0.1, width: 0.1, height: 0.1)
                faces.append(faceRecord(
                    photo,
                    box: box,
                    detScore: 0.95 - Double(index) * 0.02,
                    embedding: FaceEmbeddingMath.l2Normalized(vector)
                ))
            }
            try store.replaceFaces(photo: photo, faces: faces)
            try FaceIndexService(
                catalogURL: catalog,
                options: FaceScanOptions(minimumGroupFaces: 1)
            ).rematchRoster()

            let personIDs = Set(try faces.compactMap { try store.face(id: $0.id)?.personID })
            XCTAssertGreaterThan(personIDs.count, 1)
            let first = try XCTUnwrap(store.face(id: faces[0].id)?.personID)
            let last = try XCTUnwrap(store.face(id: faces[5].id)?.personID)
            XCTAssertNotEqual(first, last)
            // The immediate neighbor still belongs with the first face.
            XCTAssertEqual(try store.face(id: faces[1].id)?.personID, first)
        }
    }

    /// Two faces can each resemble a third and not resemble each other.
    /// They must not share a group. That is the Person 418 pile: every
    /// member was close to one face, and many pairs were not.
    func testFacesAroundOneCenterDoNotShareAGroup() throws {
        try withFaceStore { store, catalog in
            func unit(_ x: Float, _ y: Float) -> [Float] {
                var vector = [Float](repeating: 0, count: 8)
                vector[0] = x
                vector[1] = y
                return FaceEmbeddingMath.l2Normalized(vector)
            }
            let photo = photoRecord("STAR.JPG")
            let center = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.1, height: 0.1),
                detScore: 0.99,
                embedding: unit(1, 0)
            )
            let left = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.4, y: 0.1, width: 0.1, height: 0.1),
                detScore: 0.9,
                embedding: unit(0.6, 0.8)
            )
            let right = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.7, y: 0.1, width: 0.1, height: 0.1),
                detScore: 0.8,
                embedding: unit(0.6, -0.8)
            )
            try store.replaceFaces(photo: photo, faces: [center, left, right])
            try FaceIndexService(
                catalogURL: catalog,
                options: FaceScanOptions(minimumGroupFaces: 1)
            ).rematchRoster()

            let centerGroup = try XCTUnwrap(store.face(id: center.id)?.personID)
            XCTAssertEqual(try store.face(id: left.id)?.personID, centerGroup)
            XCTAssertNotEqual(try store.face(id: right.id)?.personID, centerGroup)
        }
    }

    // MARK: - Average-linkage grouping

    /// A unit vector in a small space — cosines are exact and easy to
    /// reason about by hand.
    private func unit8(_ x: Float, _ y: Float) -> [Float] {
        var vector = [Float](repeating: 0, count: 8)
        vector[0] = x
        vector[1] = y
        return FaceEmbeddingMath.l2Normalized(vector)
    }

    /// Average linkage: the join score is the mean cosine to every member.
    /// Two strangers who each resemble a hub (0.6) but not each other
    /// (−0.28) never share a group — the mean for the second is 0.16. A
    /// face close to both the hub and the first joiner still gets in,
    /// because the rule admits real matches, not just the first look.
    func testAverageLinkageKeepsHubResemblersApart() throws {
        try withFaceStore { store, catalog in
            let photo = photoRecord("HUB.JPG")
            let hub = faceRecord(photo, detScore: 0.99, embedding: unit8(1, 0))
            let first = faceRecord(photo, detScore: 0.9, embedding: unit8(0.6, 0.8))
            let stranger = faceRecord(photo, detScore: 0.8, embedding: unit8(0.6, -0.8))
            // 0.8 to the hub, 0.96 to `first`: mean 0.88 clears the bar.
            let kin = faceRecord(photo, detScore: 0.75, embedding: unit8(0.8, 0.6))
            try store.replaceFaces(photo: photo, faces: [hub, first, stranger, kin])

            let report = try FaceIndexService(
                catalogURL: catalog,
                options: FaceScanOptions(minimumGroupFaces: 1)
            ).rematchRoster()

            let hubGroup = try XCTUnwrap(store.face(id: hub.id)?.personID)
            XCTAssertEqual(try store.face(id: first.id)?.personID, hubGroup)
            XCTAssertEqual(try store.face(id: kin.id)?.personID, hubGroup)
            let strangerGroup = try XCTUnwrap(store.face(id: stranger.id)?.personID)
            XCTAssertNotEqual(strangerGroup, hubGroup)
            XCTAssertEqual(report.groupsCreated, 2)
            XCTAssertEqual(try store.faces(personID: hubGroup).count, 3)
            XCTAssertEqual(try store.faces(personID: strangerGroup).count, 1)
        }
    }

    /// A chain stepping 50° apart: each neighbor clears the bar alone
    /// (cos 50° ≈ 0.64) but the mean to a two-member cluster does not
    /// (≈ 0.23), so the chain breaks into pairs instead of one drawer.
    func testChainOfNeighborsSplitsIntoPairs() throws {
        try withFaceStore { store, catalog in
            let photo = photoRecord("CHAIN2.JPG")
            let step = Float.pi / 180 * 50
            var faces: [FaceRecord] = []
            for index in 0..<6 {
                let angle = step * Float(index)
                faces.append(faceRecord(
                    photo,
                    box: NormalizedFaceBox(x: 0.05 + Double(index) * 0.12, y: 0.1, width: 0.1, height: 0.1),
                    detScore: 0.95 - Double(index) * 0.02,
                    embedding: unit8(cos(angle), sin(angle))
                ))
            }
            try store.replaceFaces(photo: photo, faces: faces)

            let report = try FaceIndexService(
                catalogURL: catalog,
                options: FaceScanOptions(minimumGroupFaces: 1)
            ).rematchRoster()

            let groups = try faces.map { try XCTUnwrap(store.face(id: $0.id)?.personID) }
            XCTAssertEqual(report.groupsCreated, 3)
            XCTAssertEqual(Set(groups).count, 3)
            // Exactly {0,1}, {2,3}, {4,5}: the neighbor of the first face
            // stays with it, and the first and last never meet.
            XCTAssertEqual(groups[0], groups[1])
            XCTAssertEqual(groups[2], groups[3])
            XCTAssertEqual(groups[4], groups[5])
            XCTAssertNotEqual(groups[0], groups[2])
            XCTAssertNotEqual(groups[2], groups[4])
            XCTAssertNotEqual(groups[0], groups[5])
        }
    }

    /// Under the shipped defaults one identity with mild noise across
    /// several photos forms exactly one group, and a near-orthogonal seed
    /// forms its own.
    func testSameIdentityWithNoiseFormsOneGroupUnderDefaults() throws {
        try withFaceStore { store, catalog in
            // Distinct noise levels give distinct vectors of the same seed;
            // 0.2 still sits above cosine 0.9 to the clean vector.
            let alex = try (0..<4).map { index in
                let photo = photoRecord("ALEX_\(index).JPG")
                let face = faceRecord(
                    photo,
                    detScore: 0.95 - Double(index) * 0.01,
                    embedding: testEmbedding(seed: 21, noise: Float(index) * 0.05 + 0.05)
                )
                try store.replaceFaces(photo: photo, faces: [face])
                return face
            }
            let sam = try (0..<3).map { index in
                let photo = photoRecord("SAM_\(index).JPG")
                let face = faceRecord(
                    photo,
                    detScore: 0.9 - Double(index) * 0.01,
                    embedding: testEmbedding(seed: 42, noise: Float(index) * 0.05 + 0.05)
                )
                try store.replaceFaces(photo: photo, faces: [face])
                return face
            }

            let report = try FaceIndexService(catalogURL: catalog).rematchRoster()

            let alexGroup = try XCTUnwrap(store.face(id: alex[0].id)?.personID)
            let samGroup = try XCTUnwrap(store.face(id: sam[0].id)?.personID)
            XCTAssertNotEqual(alexGroup, samGroup)
            for face in alex {
                XCTAssertEqual(try store.face(id: face.id)?.personID, alexGroup)
                XCTAssertEqual(try store.face(id: face.id)?.state, .other)
            }
            for face in sam {
                XCTAssertEqual(try store.face(id: face.id)?.personID, samGroup)
            }
            XCTAssertEqual(report.groupsCreated, 2)
            XCTAssertEqual(report.facesGrouped, 7)
            XCTAssertEqual(try store.otherGroups().map(\.name).sorted(), ["Person 1", "Person 2"])
        }
    }

    /// The group-size floor: a matching pair stays unassigned — no "Person
    /// N" row, nothing grouped — until a third face makes it a cluster
    /// worth showing.
    func testSmallClustersStayUnassignedUntilTheMinimum() throws {
        try withFaceStore { store, catalog in
            let p1 = photoRecord("MIN1.JPG")
            let p2 = photoRecord("MIN2.JPG")
            let f1 = faceRecord(p1, embedding: testEmbedding(seed: 31))
            let f2 = faceRecord(p2, detScore: 0.85, embedding: testEmbedding(seed: 31, noise: 0.1))
            try store.replaceFaces(photo: p1, faces: [f1])
            try store.replaceFaces(photo: p2, faces: [f2])
            let service = FaceIndexService(catalogURL: catalog)

            var report = try service.rematchRoster()
            XCTAssertEqual(report.groupsCreated, 0)
            XCTAssertEqual(report.facesGrouped, 0)
            for face in [f1, f2] {
                let stored = try XCTUnwrap(store.face(id: face.id))
                XCTAssertNil(stored.personID)
                XCTAssertEqual(stored.state, .cached)
            }
            XCTAssertTrue(try store.otherGroups().isEmpty)
            XCTAssertEqual(try store.faceIndexCounts().unnamedGroups, 0)

            // The third sighting tips the cluster over the floor.
            let p3 = photoRecord("MIN3.JPG")
            let f3 = faceRecord(p3, detScore: 0.8, embedding: testEmbedding(seed: 31, noise: 0.15))
            try store.replaceFaces(photo: p3, faces: [f3])
            report = try service.rematchRoster()
            XCTAssertEqual(report.groupsCreated, 1)
            XCTAssertEqual(report.facesGrouped, 3)
            let group = try XCTUnwrap(store.face(id: f1.id)?.personID)
            for face in [f1, f2, f3] {
                XCTAssertEqual(try store.face(id: face.id)?.personID, group)
                XCTAssertEqual(try store.face(id: face.id)?.state, .other)
            }
            XCTAssertEqual(try store.otherGroups().map(\.name), ["Person 1"])
        }
    }

    /// The grouping quality gate: a weak detection or a tiny face is never
    /// grouped, even as an exact copy of a member. A face of unknown size
    /// (older rows, manual tags) passes the pixel check.
    func testGroupingQualityGateSkipsWeakOrTinyFaces() throws {
        let options = FaceScanOptions()
        func probe(detScore: Double, facePixels: Double?) -> Bool {
            FaceIndexService.qualifiesForGrouping(
                FaceRecord(
                    photoID: "p",
                    box: NormalizedFaceBox(x: 0, y: 0, width: 0.1, height: 0.1),
                    detScore: detScore,
                    facePixels: facePixels
                ),
                options: options
            )
        }
        XCTAssertTrue(probe(detScore: 0.9, facePixels: 200))
        XCTAssertTrue(probe(detScore: 0.7, facePixels: 48))
        XCTAssertTrue(probe(detScore: 0.9, facePixels: nil))
        XCTAssertFalse(probe(detScore: 0.65, facePixels: 200))
        XCTAssertFalse(probe(detScore: 0.9, facePixels: 30))

        try withFaceStore { store, catalog in
            // Three clean sightings make a real group first.
            let members = try (0..<3).map { index in
                let photo = photoRecord("GATE_\(index).JPG")
                let face = faceRecord(
                    photo,
                    detScore: 0.95,
                    embedding: testEmbedding(seed: 21, noise: Float(index) * 0.05),
                    quality: 20,
                    facePixels: 120
                )
                try store.replaceFaces(photo: photo, faces: [face])
                return face
            }
            let service = FaceIndexService(catalogURL: catalog)
            try service.rematchRoster()
            let group = try XCTUnwrap(store.face(id: members[0].id)?.personID)

            // Exact copies of a member that fail one gate each, plus one of
            // unknown size.
            let photo = photoRecord("GATE_X.JPG")
            let weak = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                detScore: 0.65,
                embedding: testEmbedding(seed: 21),
                facePixels: 120
            )
            let tiny = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.4, y: 0.1, width: 0.2, height: 0.2),
                detScore: 0.9,
                embedding: testEmbedding(seed: 21),
                facePixels: 30
            )
            let unknownSize = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.7, y: 0.1, width: 0.2, height: 0.2),
                detScore: 0.9,
                embedding: testEmbedding(seed: 21)
            )
            try store.replaceFaces(photo: photo, faces: [weak, tiny, unknownSize])
            try service.rematchRoster()

            for face in [weak, tiny] {
                let stored = try XCTUnwrap(store.face(id: face.id))
                XCTAssertNil(stored.personID, "a gated face must never be grouped")
                XCTAssertEqual(stored.state, .cached)
            }
            XCTAssertEqual(try store.face(id: unknownSize.id)?.personID, group)
            XCTAssertEqual(try store.face(id: unknownSize.id)?.state, .other)
            for face in members {
                XCTAssertEqual(try store.face(id: face.id)?.personID, group)
            }
        }
    }

    func testPromoteGroupConfirmsFacesAndBuildsTemplates() throws {
        try withFaceStore { store, catalog in
            // Two faces of the same cluster on different photos.
            let p1 = photoRecord("P1.JPG")
            let p2 = photoRecord("P2.JPG")
            let f1 = faceRecord(p1, embedding: testEmbedding(seed: 31))
            let f2 = faceRecord(p2, detScore: 0.8, embedding: testEmbedding(seed: 31, noise: 0.1))
            try store.replaceFaces(photo: p1, faces: [f1])
            try store.replaceFaces(photo: p2, faces: [f2])
            // Two faces are under the default group-size floor; promotion
            // is the subject, so let the pair form a group.
            let service = FaceIndexService(
                catalogURL: catalog,
                options: FaceScanOptions(minimumGroupFaces: 1)
            )
            try service.rematchRoster()

            let groupID = try XCTUnwrap(store.face(id: f1.id)?.personID)
            try store.promoteGroup(groupID, name: "Alex", templateCap: 8)

            let person = try XCTUnwrap(store.person(groupID))
            XCTAssertTrue(person.isRoster)
            XCTAssertEqual(person.name, "Alex")

            // Naming the group is the review: members are confirmed, and
            // distinct photos become match templates.
            XCTAssertEqual(try store.face(id: f1.id)?.state, .confirmed)
            XCTAssertEqual(try store.face(id: f2.id)?.state, .confirmed)
            XCTAssertEqual(try store.rosterTemplates().count, 2)

            // The new gallery immediately matches a similar cached face.
            let p3 = photoRecord("P3.JPG")
            let f3 = faceRecord(p3, embedding: testEmbedding(seed: 31, noise: 0.12))
            try store.replaceFaces(photo: p3, faces: [f3])
            try service.rematchRoster()
            let matched = try store.face(id: f3.id)
            XCTAssertEqual(matched?.state, .proposed)
            XCTAssertEqual(matched?.personID, groupID)
        }
    }

    func testMergeIntoRosterKeepsFacesAsProposed() throws {
        try withFaceStore { store, _ in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let mom = try store.createPerson(name: "Mom", isRoster: true)

            let photo = photoRecord("M1.JPG")
            let confirmedDad = faceRecord(photo, embedding: testEmbedding(seed: 51), state: .confirmed, personID: dad.id)
            let looseDad = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                embedding: testEmbedding(seed: 52),
                state: .other,
                personID: dad.id
            )
            try store.replaceFaces(photo: photo, faces: [confirmedDad, looseDad])

            try store.mergePerson(dad.id, into: mom.id)

            XCTAssertNil(try store.person(dad.id))
            // Confirmed stays frozen; the unconfirmed face stays attached as
            // a reviewable proposal on the roster target.
            XCTAssertEqual(try store.face(id: confirmedDad.id)?.state, .confirmed)
            let moved = try store.face(id: looseDad.id)
            XCTAssertEqual(moved?.personID, mom.id)
            XCTAssertEqual(moved?.state, .proposed)
        }
    }

    /// Pulling a proposal off a person sends the face back through the
    /// grouping pass. Alone, it is a cluster of one — under the group-size
    /// floor — so it returns to the unassigned pool rather than minting a
    /// "Person N" of its own.
    func testRegroupReturnsALoneFaceToTheUnassignedPool() throws {
        try withFaceStore { store, catalog in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let galleryPhoto = photoRecord("G9.JPG")
            let galleryFace = faceRecord(galleryPhoto, embedding: testEmbedding(seed: 61), state: .confirmed, personID: dad.id)
            try store.replaceFaces(photo: galleryPhoto, faces: [galleryFace])
            try store.addTemplate(personID: dad.id, faceID: galleryFace.id)

            let photo = photoRecord("N9.JPG")
            let wrongMatch = faceRecord(photo, embedding: testEmbedding(seed: 61, noise: 0.15))
            try store.replaceFaces(photo: photo, faces: [wrongMatch])
            let service = FaceIndexService(catalogURL: catalog)
            try service.rematchRoster()
            XCTAssertEqual(try store.face(id: wrongMatch.id)?.state, .proposed)

            try service.regroup([wrongMatch.id])
            let regrouped = try XCTUnwrap(store.face(id: wrongMatch.id))
            XCTAssertEqual(regrouped.state, .cached)
            XCTAssertNil(regrouped.personID)
            XCTAssertTrue(try store.otherGroups().isEmpty)
        }
    }

    // MARK: - Rejections and rebundle

    /// "Not this person" moves the face out immediately — and the
    /// persisted verdict keeps it off that person through later re-matches.
    func testRejectFaceLeavesAndStaysOffThePerson() throws {
        try withFaceStore { store, catalog in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let galleryPhoto = photoRecord("RJ1.JPG")
            let galleryFace = faceRecord(
                galleryPhoto,
                embedding: testEmbedding(seed: 61),
                state: .confirmed,
                personID: dad.id
            )
            try store.replaceFaces(photo: galleryPhoto, faces: [galleryFace])
            try store.addTemplate(personID: dad.id, faceID: galleryFace.id)

            let photo = photoRecord("RJ2.JPG")
            let wrongMatch = faceRecord(photo, embedding: testEmbedding(seed: 61, noise: 0.15))
            try store.replaceFaces(photo: photo, faces: [wrongMatch])
            let service = FaceIndexService(catalogURL: catalog)
            try service.rematchRoster()
            XCTAssertEqual(try store.face(id: wrongMatch.id)?.personID, dad.id)

            // The face leaves Dad at once. Alone it is under the group-size
            // floor, so it waits unassigned rather than minting a group.
            try service.reject([wrongMatch.id])
            let rejected = try XCTUnwrap(store.face(id: wrongMatch.id))
            XCTAssertEqual(rejected.state, .cached)
            XCTAssertNil(rejected.personID)
            XCTAssertTrue(try store.otherGroups().isEmpty)

            // The verdict is persisted: no later pass can put it back.
            XCTAssertTrue(try store.faceRejections().blocks(faceID: wrongMatch.id, personID: dad.id))
            try service.rematchRoster()
            let after = try XCTUnwrap(store.face(id: wrongMatch.id))
            XCTAssertNotEqual(after.state, .proposed)
            XCTAssertNotEqual(after.personID, dad.id)

            // The frozen face refuses the same path — confirmed never
            // moves, and no rejection row is written for it.
            try service.reject([galleryFace.id])
            XCTAssertEqual(try store.face(id: galleryFace.id)?.state, .confirmed)
            XCTAssertEqual(try store.face(id: galleryFace.id)?.personID, dad.id)
            XCTAssertFalse(try store.faceRejections().blocks(faceID: galleryFace.id, personID: dad.id))
        }
    }

    /// A face closer to a person's rejected face than to that person's
    /// templates is never proposed — the rejection is a negative example.
    func testLookalikeOfRejectedFaceIsNotProposed() throws {
        try withFaceStore { store, catalog in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let galleryPhoto = photoRecord("NG1.JPG")
            let galleryFace = faceRecord(
                galleryPhoto,
                embedding: testEmbedding(seed: 61),
                state: .confirmed,
                personID: dad.id
            )
            try store.replaceFaces(photo: galleryPhoto, faces: [galleryFace])
            try store.addTemplate(personID: dad.id, faceID: galleryFace.id)

            // This look clears the template bar on score alone — only the
            // veto can keep it off Dad.
            let look = testEmbedding(seed: 61, noise: 0.15)
            XCTAssertGreaterThan(
                FaceEmbeddingMath.cosine(look, testEmbedding(seed: 61)),
                FaceScanOptions().matchThreshold
            )

            let service = FaceIndexService(catalogURL: catalog)
            let rejectedPhoto = photoRecord("NG2.JPG")
            let rejected = faceRecord(rejectedPhoto, embedding: look)
            try store.replaceFaces(photo: rejectedPhoto, faces: [rejected])
            try store.assignFace(rejected.id, to: dad.id, state: .proposed, score: 0.8)
            try service.reject([rejected.id])

            let twinPhoto = photoRecord("NG3.JPG")
            let twin = faceRecord(twinPhoto, embedding: look)
            try store.replaceFaces(photo: twinPhoto, faces: [twin])
            try service.rematchRoster()

            // Vetoed off Dad; with only the rejected face for company it is
            // a pair, under the group-size floor, so it stays unassigned.
            let stored = try XCTUnwrap(store.face(id: twin.id))
            XCTAssertNotEqual(stored.state, .proposed)
            XCTAssertNotEqual(stored.personID, dad.id)
            XCTAssertNil(stored.personID)
        }
    }

    /// The group-level veto: a group whose rejected face describes a
    /// candidate better than its members refuses the join. The group is
    /// user-named so the re-match leaves it standing — auto "Person N"
    /// rows dissolve and re-form on every pass, and a cluster formed
    /// within a pass has no row yet for a verdict to attach to.
    func testGroupJoinVetoedByRejectedMember() throws {
        try withFaceStore { store, catalog in
            let group = try store.createPerson(name: "Book club", isRoster: false)
            let photo = photoRecord("VJ1.JPG")
            let member = faceRecord(photo, detScore: 0.95, embedding: testEmbedding(seed: 21))
            let misfit = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.5, y: 0.1, width: 0.2, height: 0.2),
                detScore: 0.9,
                embedding: testEmbedding(seed: 21, noise: 0.1)
            )
            try store.replaceFaces(photo: photo, faces: [member, misfit])
            try store.assignFace(member.id, to: group.id, state: .other, score: 0.9)
            try store.assignFace(misfit.id, to: group.id, state: .other, score: 0.9)

            // The pair the veto pushes away must be allowed to form a group
            // of its own, so the size floor is lowered.
            let service = FaceIndexService(
                catalogURL: catalog,
                options: FaceScanOptions(minimumGroupFaces: 1)
            )
            try service.reject([misfit.id])
            XCTAssertNotEqual(try store.face(id: misfit.id)?.personID, group.id)

            // A face identical to the rejected one clears the mean-cosine
            // bar on score alone — the veto keeps it out of the group.
            let twinPhoto = photoRecord("VJ2.JPG")
            let twin = faceRecord(twinPhoto, embedding: testEmbedding(seed: 21, noise: 0.1))
            try store.replaceFaces(photo: twinPhoto, faces: [twin])
            try service.rematchRoster()

            let stored = try XCTUnwrap(store.face(id: twin.id))
            XCTAssertEqual(stored.state, .other)
            XCTAssertNotEqual(stored.personID, group.id)
            // The group kept its real member, and the group row survived.
            XCTAssertEqual(try store.face(id: member.id)?.personID, group.id)
            XCTAssertNotNil(try store.person(group.id))
        }
    }

    /// "Not this person" on an automatic group must outlive Re-match. The
    /// rebundle dissolves "Person N" and its members re-cluster from
    /// scratch; the rejected face — and any lookalike of it — stays out of
    /// the cluster its former group-mates form, and that cluster keeps the
    /// original row so the verdict rows recorded against it survive.
    func testRejectionFromAutoGroupSurvivesRematch() throws {
        try withFaceStore { store, catalog in
            // One identity with distinct noise per sighting, plus a misfit
            // that resembles them less than they resemble each other.
            let base = testEmbedding(seed: 21)
            func sighting(_ seed: UInt64, spread: Float) -> [Float] {
                let noise = testEmbedding(seed: seed)
                return FaceEmbeddingMath.l2Normalized(zip(base, noise).map { $0 + spread * $1 })
            }
            let group = try store.createPerson(name: "Person 7", isRoster: false)
            let photo = photoRecord("RJ1.JPG")
            let members = (0..<3).map { index in
                faceRecord(
                    photo,
                    box: NormalizedFaceBox(x: 0.05 + Double(index) * 0.2, y: 0.1, width: 0.1, height: 0.1),
                    detScore: 0.95 - Double(index) * 0.01,
                    embedding: sighting(UInt64(100 + index), spread: 0.1)
                )
            }
            let misfit = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.7, y: 0.1, width: 0.1, height: 0.1),
                detScore: 0.9,
                embedding: sighting(200, spread: 0.3)
            )
            try store.replaceFaces(photo: photo, faces: members + [misfit])
            for face in members + [misfit] {
                try store.assignFace(face.id, to: group.id, state: .other, score: 0.9)
            }

            let service = FaceIndexService(catalogURL: catalog)
            try service.reject([misfit.id])
            XCTAssertNil(try store.face(id: misfit.id)?.personID)

            let report = try service.rematchRoster()
            XCTAssertEqual(report.groupsDissolved, 0, "the rebuilt cluster reuses its own row")
            let rebuilt = try XCTUnwrap(store.face(id: members[0].id)?.personID)
            XCTAssertEqual(rebuilt, group.id)
            for face in members {
                XCTAssertEqual(try store.face(id: face.id)?.personID, group.id)
            }
            XCTAssertNil(try store.face(id: misfit.id)?.personID, "the rejected face must not rejoin its former group-mates")
            XCTAssertNotNil(try store.person(group.id))

            // A near-copy of the rejected face arrives later: closer to the
            // rejected example than to the group, so the veto keeps it out.
            let twinPhoto = photoRecord("RJ2.JPG")
            let twin = faceRecord(twinPhoto, embedding: sighting(200, spread: 0.31))
            try store.replaceFaces(photo: twinPhoto, faces: [twin])
            try service.rematchRoster()
            XCTAssertNotEqual(try store.face(id: twin.id)?.personID, group.id)
            XCTAssertNil(try store.face(id: misfit.id)?.personID)
            XCTAssertEqual(try store.faces(personID: group.id).count, 3)
        }
    }

    /// A drifted "Person N" drawer — two identities forced into one auto
    /// group — splits back into real groups on re-match.
    func testRematchRebundlesDriftedAutoGroup() throws {
        try withFaceStore { store, catalog in
            let drawer = try store.createPerson(name: "Person 27", isRoster: false)
            let photo = photoRecord("RB1.JPG")
            // Three sightings of each identity — enough for both to clear
            // the group-size floor once they split.
            let alex = (0..<3).map { index in
                faceRecord(
                    photo,
                    box: NormalizedFaceBox(x: 0.1 + Double(index) * 0.3, y: 0.1, width: 0.2, height: 0.2),
                    detScore: 0.95 - Double(index) * 0.02,
                    embedding: testEmbedding(seed: 21, noise: Float(index) * 0.05)
                )
            }
            let sam = (0..<3).map { index in
                faceRecord(
                    photo,
                    box: NormalizedFaceBox(x: 0.1 + Double(index) * 0.3, y: 0.5, width: 0.2, height: 0.2),
                    detScore: 0.85 - Double(index) * 0.02,
                    embedding: testEmbedding(seed: 42, noise: Float(index) * 0.05)
                )
            }
            try store.replaceFaces(photo: photo, faces: alex + sam)
            for face in alex + sam {
                try store.assignFace(face.id, to: drawer.id, state: .other, score: 0.9)
            }

            try FaceIndexService(catalogURL: catalog).rematchRoster()

            let storedA = try XCTUnwrap(store.face(id: alex[0].id)).personID
            let storedB = try XCTUnwrap(store.face(id: sam[0].id)).personID
            for face in alex {
                XCTAssertEqual(try store.face(id: face.id)?.personID, storedA)
            }
            for face in sam {
                XCTAssertEqual(try store.face(id: face.id)?.personID, storedB)
            }
            XCTAssertNotEqual(storedA, storedB)
            // The identity that re-forms first — led by the most confident
            // face — keeps the recycled "Person 27" row; the other lands on
            // a fresh unnamed group.
            XCTAssertEqual(storedA, drawer.id)
            XCTAssertEqual(try store.faces(personID: drawer.id).count, 3)
            let otherGroup = try XCTUnwrap(storedB.flatMap { try? store.person($0) })
            XCTAssertFalse(otherGroup.isRoster)
        }
    }

    /// A group the user named is never dissolved — a demoted roster person
    /// keeps its name and its faces through a re-match, even when the
    /// members are different identities.
    func testRematchLeavesUserNamedGroupsIntact() throws {
        try withFaceStore { store, catalog in
            let named = try store.createPerson(name: "Eileen", isRoster: false)
            let photo = photoRecord("RB2.JPG")
            let m1 = faceRecord(photo, detScore: 0.95, embedding: testEmbedding(seed: 21))
            let m2 = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                detScore: 0.9,
                embedding: testEmbedding(seed: 42)
            )
            try store.replaceFaces(photo: photo, faces: [m1, m2])
            try store.assignFace(m1.id, to: named.id, state: .other, score: 0.9)
            try store.assignFace(m2.id, to: named.id, state: .other, score: 0.9)

            try FaceIndexService(catalogURL: catalog).rematchRoster()

            XCTAssertEqual(try store.face(id: m1.id)?.personID, named.id)
            XCTAssertEqual(try store.face(id: m2.id)?.personID, named.id)
            XCTAssertNotNil(try store.person(named.id))
        }
    }

    /// A second re-match on a settled catalog is a true no-op — recycled
    /// rows keep their members, so the report can honestly say nothing
    /// moved.
    func testRematchOnASettledCatalogMovesNothing() throws {
        try withFaceStore { store, catalog in
            let photo = photoRecord("ST1.JPG")
            // Two identities, three sightings each — real groups under the
            // default floor.
            let alex = (0..<3).map { index in
                faceRecord(
                    photo,
                    box: NormalizedFaceBox(x: 0.1 + Double(index) * 0.3, y: 0.1, width: 0.2, height: 0.2),
                    detScore: 0.95 - Double(index) * 0.02,
                    embedding: testEmbedding(seed: 21, noise: Float(index) * 0.05)
                )
            }
            let sam = (0..<3).map { index in
                faceRecord(
                    photo,
                    box: NormalizedFaceBox(x: 0.1 + Double(index) * 0.3, y: 0.5, width: 0.2, height: 0.2),
                    detScore: 0.85 - Double(index) * 0.02,
                    embedding: testEmbedding(seed: 42, noise: Float(index) * 0.05)
                )
            }
            try store.replaceFaces(photo: photo, faces: alex + sam)
            let service = FaceIndexService(catalogURL: catalog)

            let first = try service.rematchRoster()
            XCTAssertEqual(first.facesMoved, 6)
            XCTAssertEqual(first.groupsCreated, 2)

            let second = try service.rematchRoster()
            XCTAssertEqual(second.facesMoved, 0)
            XCTAssertEqual(second.groupsDissolved, 0)
            XCTAssertEqual(try store.face(id: alex[0].id)?.personID, try store.face(id: alex[2].id)?.personID)
            XCTAssertEqual(try store.face(id: sam[0].id)?.personID, try store.face(id: sam[2].id)?.personID)
            XCTAssertNotEqual(try store.face(id: alex[0].id)?.personID, try store.face(id: sam[0].id)?.personID)
        }
    }

    /// Junk drops exactly the group the user confirmed — the other group,
    /// its faces, the photos' scan grades, and the event row all stay.
    func testJunkDeletesOneGroupAndLeavesTheRest() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            var configuration = faceTestConfiguration(root: root, catalog: catalog)
            configuration.savedEvents = [
                SavedCameraEvent(name: "Beach Day", eventDate: Date(timeIntervalSince1970: 1_752_000_000)),
            ]
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = FaceIndexStore(url: catalog)

            let junk = try store.createPerson(name: "Person 3", isRoster: false)
            let keep = try store.createPerson(name: "Person 4", isRoster: false)
            var photoA = photoRecord("JK1.JPG")
            photoA.scanGrade = .med
            var photoB = photoRecord("JK2.JPG")
            photoB.scanGrade = .med
            let junkFace = faceRecord(photoA, embedding: testEmbedding(seed: 5), state: .other, personID: junk.id)
            let keepFace = faceRecord(photoB, embedding: testEmbedding(seed: 6), state: .other, personID: keep.id)
            try store.replaceFaces(photo: photoA, faces: [junkFace])
            try store.replaceFaces(photo: photoB, faces: [keepFace])

            try store.deletePersonAndFaces(junk.id)

            XCTAssertNil(try store.person(junk.id))
            XCTAssertNil(try store.face(id: junkFace.id))
            XCTAssertNotNil(try store.person(keep.id))
            XCTAssertEqual(try store.face(id: keepFace.id)?.personID, keep.id)
            XCTAssertEqual(try store.face(id: keepFace.id)?.state, .other)
            // The event row and the photos' scan grades are untouched, and
            // no Junk person was minted.
            XCTAssertEqual(scalarInt("SELECT COUNT(*) FROM events", database: catalog), 1)
            XCTAssertEqual(
                try store.photos(pathKeys: [photoB.pathKey])[photoB.pathKey]?.scanGrade,
                .med
            )
            XCTAssertEqual(try store.otherGroups().map(\.name), ["Person 4"])
        }
    }

    // MARK: - event.people

    func testEventPeopleListsRosterOnly() throws {
        try withFaceStore { store, _ in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let mom = try store.createPerson(name: "Mom", isRoster: true)
            let stranger = try store.createPerson(name: "Person 1", isRoster: false)

            let modified = Date(timeIntervalSince1970: 1_752_000_000)
            let photo = photoRecord("DSC00077.ARW", size: 4_096, modified: modified)
            let faces = [
                faceRecord(photo, embedding: testEmbedding(seed: 71), state: .confirmed, personID: dad.id),
                faceRecord(
                    photo,
                    box: NormalizedFaceBox(x: 0.5, y: 0.1, width: 0.2, height: 0.2),
                    embedding: testEmbedding(seed: 72),
                    state: .proposed,
                    personID: mom.id
                ),
                // A stranger grouped automatically — must not show on chips.
                faceRecord(
                    photo,
                    box: NormalizedFaceBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                    embedding: testEmbedding(seed: 73),
                    state: .other,
                    personID: stranger.id
                ),
                // An ungrouped cached face — must not show either.
                faceRecord(
                    photo,
                    box: NormalizedFaceBox(x: 0.1, y: 0.5, width: 0.15, height: 0.15),
                    embedding: testEmbedding(seed: 74)
                ),
            ]
            try store.replaceFaces(photo: photo, faces: faces)

            // The file moved into an event folder — the same name+size+mtime
            // file key still links the faces to the event.
            let movedKey = FaceIndexStore.fileKey(
                fileName: "DSC00077.ARW",
                byteCount: 4_096,
                modifiedAt: modified
            )
            let people = try store.eventPeople(fileKeys: [movedKey])
            XCTAssertEqual(people.map(\.name), ["Dad", "Mom"])
            XCTAssertTrue(people.allSatisfy(\.isRoster))
            XCTAssertEqual(people.first(where: { $0.name == "Dad" })?.faceCount, 1)

            // No file-key match → no people.
            XCTAssertEqual(
                try store.eventPeople(fileKeys: [FaceIndexStore.fileKey(fileName: "OTHER.ARW", byteCount: 1, modifiedAt: modified)]),
                []
            )
        }
    }

    func testPersonNamesByFileKeyCoversRosterAndGroups() throws {
        try withFaceStore { store, _ in
            let eileen = try store.createPerson(name: "Eileen", isRoster: true)
            let group = try store.createPerson(name: "Person 1", isRoster: false)

            let modified = Date(timeIntervalSince1970: 1_752_000_000)
            let photoA = photoRecord("DSC00001.ARW", size: 4_096, modified: modified)
            let photoB = photoRecord("DSC00002.ARW", size: 8_192, modified: modified)
            let photoC = photoRecord("DSC00003.ARW", size: 2_048, modified: modified)

            try store.replaceFaces(photo: photoA, faces: [
                faceRecord(photoA, embedding: testEmbedding(seed: 81), state: .confirmed, personID: eileen.id),
                faceRecord(
                    photoA,
                    box: NormalizedFaceBox(x: 0.6, y: 0.1, width: 0.2, height: 0.2),
                    embedding: testEmbedding(seed: 82),
                    state: .proposed,
                    personID: eileen.id
                ),
            ])
            try store.replaceFaces(photo: photoB, faces: [
                faceRecord(photoB, embedding: testEmbedding(seed: 83), state: .other, personID: group.id),
            ])
            // A cached face with no person contributes no name.
            try store.replaceFaces(photo: photoC, faces: [
                faceRecord(photoC, embedding: testEmbedding(seed: 84)),
            ])

            let names = try store.personNamesByFileKey()
            let keyA = FaceIndexStore.fileKey(fileName: "DSC00001.ARW", byteCount: 4_096, modifiedAt: modified)
            let keyB = FaceIndexStore.fileKey(fileName: "DSC00002.ARW", byteCount: 8_192, modifiedAt: modified)
            let keyC = FaceIndexStore.fileKey(fileName: "DSC00003.ARW", byteCount: 2_048, modifiedAt: modified)

            // Roster and unnamed-group names both land on their photo keys —
            // the board search can keep a burst for either kind of person.
            XCTAssertEqual(names[keyA], ["Eileen"])
            XCTAssertEqual(names[keyB], ["Person 1"])
            XCTAssertNil(names[keyC])
            XCTAssertNil(names[FaceIndexStore.fileKey(fileName: "OTHER.ARW", byteCount: 1, modifiedAt: modified)])
        }
    }

    func testPeopleByFileKeyMapsRosterAndGroupsPerPhoto() throws {
        try withFaceStore { store, _ in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let group = try store.createPerson(name: "Person 1", isRoster: false)

            let modified = Date(timeIntervalSince1970: 1_752_000_000)
            let first = photoRecord("A1.JPG", modified: modified)
            let second = photoRecord("A2.JPG", modified: modified)
            try store.replaceFaces(photo: first, faces: [
                faceRecord(first, embedding: testEmbedding(seed: 81), state: .confirmed, personID: dad.id),
                faceRecord(
                    first,
                    box: NormalizedFaceBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                    embedding: testEmbedding(seed: 82),
                    state: .proposed,
                    personID: dad.id
                ),
                // An ungrouped cached face contributes no person.
                faceRecord(
                    first,
                    box: NormalizedFaceBox(x: 0.5, y: 0.1, width: 0.15, height: 0.15),
                    embedding: testEmbedding(seed: 83)
                ),
            ])
            try store.replaceFaces(photo: second, faces: [
                faceRecord(second, embedding: testEmbedding(seed: 84), state: .other, personID: group.id),
            ])

            let key1 = FaceIndexStore.fileKey(fileName: "A1.JPG", byteCount: first.byteCount, modifiedAt: modified)
            let key2 = FaceIndexStore.fileKey(fileName: "A2.JPG", byteCount: second.byteCount, modifiedAt: modified)
            let byKey = try store.peopleByFileKey(fileKeys: [key1, key2])
            XCTAssertEqual(byKey[key1]?.map(\.id), [dad.id])
            XCTAssertEqual(byKey[key1]?.first?.faceCount, 2)
            XCTAssertEqual(byKey[key2]?.map(\.id), [group.id])
            XCTAssertEqual(byKey[key2]?.first?.isRoster, false)

            // Unqueried and unmatched keys return nothing.
            XCTAssertNil(byKey[FaceIndexStore.fileKey(fileName: "OTHER.JPG", byteCount: 1, modifiedAt: modified)])
            XCTAssertNil(try store.peopleByFileKey(fileKeys: [key1])[key2])
            XCTAssertTrue(try store.peopleByFileKey(fileKeys: []).isEmpty)
        }
    }

    // MARK: - Quality modes (MED / HIGH)

    func testModeDefaultsMatchThePlan() throws {
        let low = FaceScanOptions(mode: .low)
        XCTAssertEqual(low.minimumFacePixels, 64)
        XCTAssertEqual(low.detectorScales, [640])
        XCTAssertNil(low.videoFrameStride)
        XCTAssertFalse(low.scansVideo)

        let med = FaceScanOptions(mode: .med)
        XCTAssertEqual(med.minimumFacePixels, 40)
        XCTAssertEqual(med.detectorScales, [640])
        XCTAssertEqual(med.videoFrameStride, 30)
        XCTAssertTrue(med.scansVideo)

        let high = FaceScanOptions(mode: .high)
        XCTAssertEqual(high.minimumFacePixels, 30)
        XCTAssertEqual(high.detectorScales, [640, 960])
        XCTAssertEqual(high.videoFrameStride, 1)
        XCTAssertTrue(high.scansVideo)
        XCTAssertFalse(high.flipTTA)
        XCTAssertFalse(high.rebuildTemplates)

        let xhigh = FaceScanOptions(mode: .xhigh)
        XCTAssertEqual(xhigh.minimumFacePixels, 30)
        XCTAssertEqual(xhigh.detectorScales, [640, 960, 1024])
        XCTAssertEqual(xhigh.videoFrameStride, 0.5)
        XCTAssertTrue(xhigh.scansVideo)
        XCTAssertTrue(xhigh.flipTTA)
        XCTAssertTrue(xhigh.rebuildTemplates)
        XCTAssertEqual(xhigh.templateCap, 15)

        // The matching and grouping knobs are the same at every grade.
        for options in [low, med, high, xhigh] {
            XCTAssertEqual(options.matchThreshold, 0.45)
            XCTAssertEqual(options.clusterThreshold, 0.40)
            XCTAssertEqual(options.detScoreThreshold, 0.6)
            XCTAssertEqual(options.groupingMinDetScore, 0.7)
            XCTAssertEqual(options.groupingMinFacePixels, 48)
            XCTAssertEqual(options.minimumGroupFaces, 3)
        }

        // FAST pins the Mac; off is the quiet two-wide pass.
        XCTAssertGreaterThan(FaceScanOptions(mode: .med, fast: true).concurrency, 2)
        XCTAssertEqual(FaceScanOptions(mode: .med, fast: false).concurrency, 2)

        // Every pipeline through XHIGH is implemented — a request stamps
        // itself so a repeat pass skips the photo.
        XCTAssertEqual(FaceScanOptions.implementedGrade, .xhigh)
    }

    func testScanSkipsByRecordedGrade() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            let jpegURL = root.appendingPathComponent("card/DSC00042.JPG")
            try writeJPEG(jpegURL, seed: 3)
            let item = try organizeItem(forFileAt: jpegURL)
            let store = FaceIndexStore(url: catalog)
            let analyzer = StubAnalyzer()

            // LOW stamps low; a repeat LOW pass skips.
            var service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .low))
            var report = try service.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade, .low)

            report = try service.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.photosSkipped, 1)
            XCTAssertEqual(report.photosProcessed, 0)

            // MED re-runs (low does not cover med), then stamps med.
            service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .med))
            report = try service.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade, .med)

            report = try service.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.photosSkipped, 1)

            // HIGH re-runs; afterwards a MED request is covered and skipped.
            service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .high))
            report = try service.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade, .high)

            service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .med))
            report = try service.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.photosSkipped, 1)

            // XHIGH re-runs (high does not cover xhigh) and stamps .xhigh.
            service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .xhigh))
            report = try service.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade, .xhigh)

            // A repeat XHIGH request is covered and skipped — nothing
            // outranks xhigh, so the photo is done.
            report = try service.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.photosSkipped, 1)
            XCTAssertEqual(report.photosProcessed, 0)
        }
    }

    func testLowModeSkipsVideoEntirely() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            let jpegURL = root.appendingPathComponent("card/DSC00001.JPG")
            try writeJPEG(jpegURL, seed: 4)
            // Bytes never get decoded at LOW — a bogus video file is enough
            // to prove the item never enters the pipeline.
            let videoURL = root.appendingPathComponent("card/C0001.MP4")
            try writeFile(videoURL, Data("not a real video".utf8))
            let photoItem = try organizeItem(forFileAt: jpegURL)
            var videoItem = try organizeItem(forFileAt: videoURL)
            videoItem = OrganizeItem(
                primary: videoItem.primary,
                kind: .video,
                captureDate: videoItem.captureDate,
                hasCameraDate: false
            )

            let service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .low))
            let report = try service.scan(items: [photoItem, videoItem], analyzer: StubAnalyzer())
            XCTAssertEqual(report.photosConsidered, 1)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(report.videoFramesRead, 0)
            XCTAssertNil(try FaceIndexStore(url: catalog).photos(pathKeys: [videoItem.primary.pathKey])[videoItem.primary.pathKey])
        }
    }

    /// Higher grades re-detect a photo the owner already reviewed: the
    /// confirmed face keeps its id and label while the overlapping
    /// detection refreshes its measurement, a new face elsewhere is
    /// added, and the photo restamps at the grade that ran.
    func testHigherGradesRefreshConfirmedFacesAndRestamp() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            let jpegURL = root.appendingPathComponent("card/DSC00010.JPG")
            try writeJPEG(jpegURL, seed: 5)
            let item = try organizeItem(forFileAt: jpegURL)
            let store = FaceIndexStore(url: catalog)

            // First pass finds one face; the owner confirms it as Dad.
            let box = NormalizedFaceBox(x: 0.1, y: 0.6, width: 0.2, height: 0.2)
            let medService = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .med))
            var report = try medService.scan(
                items: [item],
                analyzer: StubAnalyzer(faces: [analyzedFace(box: box, detScore: 0.95, quality: 15)])
            )
            XCTAssertEqual(report.facesDetected, 1)

            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let detected = try XCTUnwrap(store.faces(photoID: item.primary.pathKey).first)
            try store.assignFace(detected.id, to: dad.id, state: .proposed, score: 0.9)
            try store.confirmFace(detected.id)

            // HIGH re-detects the same spot (overlapping box) plus a new
            // face elsewhere. The confirmed row is refreshed in place — no
            // duplicate — and the photo is now stamped high.
            let analyzer = StubAnalyzer(faces: [
                analyzedFace(
                    box: NormalizedFaceBox(x: 0.11, y: 0.61, width: 0.2, height: 0.2),
                    detScore: 0.9,
                    quality: 25
                ),
                analyzedFace(box: NormalizedFaceBox(x: 0.6, y: 0.6, width: 0.15, height: 0.15), detScore: 0.8),
            ])
            let highService = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .high))
            report = try highService.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.photosProcessed, 1)

            let faces = try store.faces(photoID: item.primary.pathKey)
            XCTAssertEqual(faces.count, 2)
            let confirmed = try XCTUnwrap(store.face(id: detected.id))
            XCTAssertEqual(confirmed.state, .confirmed)
            XCTAssertEqual(confirmed.personID, dad.id)
            XCTAssertEqual(confirmed.box.x, 0.11, accuracy: 1e-9)
            XCTAssertEqual(confirmed.quality, 25)
            XCTAssertEqual(confirmed.scanGrade, .high)
            XCTAssertEqual(faces.filter { $0.state != .confirmed }.count, 1)
            XCTAssertEqual(
                try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade,
                .high
            )

            // XHIGH re-runs one more time — the confirmed face is still
            // frozen, its overlap still folds in, and the photo now stamps
            // xhigh so every later mode skips it.
            let xhighService = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .xhigh))
            report = try xhighService.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(try store.face(id: detected.id)?.state, .confirmed)
            XCTAssertEqual(try store.face(id: detected.id)?.personID, dad.id)
            XCTAssertEqual(try store.faces(photoID: item.primary.pathKey).count, 2)
            XCTAssertEqual(
                try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade,
                .xhigh
            )
            report = try xhighService.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.photosSkipped, 1)
            XCTAssertEqual(report.photosProcessed, 0)
        }
    }

    func testBurstStacksSampleAndCoverTheRest() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            // A six-frame burst plus a single still — the burst decodes
            // three spread frames and the rest are covered by the sample.
            var items: [OrganizeItem] = []
            for index in 1...6 {
                let url = root.appendingPathComponent("card/B0001_DSC000\(index).JPG")
                try writeJPEG(url, seed: UInt8(index))
                items.append(try organizeItem(forFileAt: url))
            }
            let singleURL = root.appendingPathComponent("card/DSC00099.JPG")
            try writeJPEG(singleURL, seed: 9)
            items.append(try organizeItem(forFileAt: singleURL))

            let stacks = [
                OrganizeStack(items: Array(items.prefix(6))),
                OrganizeStack(items: [items[6]]),
            ]
            let store = FaceIndexStore(url: catalog)
            let analyzer = StubAnalyzer(faces: [
                analyzedFace(box: NormalizedFaceBox(x: 0.2, y: 0.2, width: 0.2, height: 0.2)),
            ])
            let service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .med))

            var report = try service.scan(items: items, analyzer: analyzer, stacks: stacks)
            XCTAssertEqual(report.photosConsidered, 7)
            XCTAssertEqual(report.photosProcessed, 4)   // 3 sampled burst frames + the single
            XCTAssertEqual(report.photosBurstCovered, 3)
            // Every file — scanned or covered — carries the executed grade.
            for item in items {
                XCTAssertEqual(
                    try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade,
                    .med
                )
            }
            // Covered frames got no face rows of their own — six frames
            // sample to {0, 3, 5}, leaving {1, 2, 4} covered.
            let coveredKeys = Set([items[1], items[2], items[4]].map(\.primary.pathKey))
            for key in coveredKeys {
                XCTAssertTrue(try store.faces(photoID: key).isEmpty)
            }

            // A repeat pass skips everything — covered frames never rescan.
            report = try service.scan(items: items, analyzer: analyzer, stacks: stacks)
            XCTAssertEqual(report.photosProcessed, 0)
            XCTAssertEqual(report.photosBurstCovered, 0)
            XCTAssertEqual(report.photosSkipped, 7)
        }
    }

    func testBurstCoverageKeepsEarlierFacesAndGateNeedsStacks() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            var items: [OrganizeItem] = []
            for index in 1...4 {
                let url = root.appendingPathComponent("card/B0007_DSC000\(index).JPG")
                try writeJPEG(url, seed: UInt8(index))
                items.append(try organizeItem(forFileAt: url))
            }
            let store = FaceIndexStore(url: catalog)
            let analyzer = StubAnalyzer(faces: [
                analyzedFace(box: NormalizedFaceBox(x: 0.3, y: 0.3, width: 0.2, height: 0.2)),
            ])

            // Without a scan result's stacks every still is scanned — the
            // Phase 1 behavior bare item lists keep.
            let lowService = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .low))
            var report = try lowService.scan(items: items, analyzer: analyzer)
            XCTAssertEqual(report.photosProcessed, 4)
            XCTAssertEqual(report.photosBurstCovered, 0)
            for item in items {
                XCTAssertEqual(try store.faces(photoID: item.primary.pathKey).count, 1)
            }

            // MED with burst grouping: 4 frames sample to {0, 2, 3}; index 1
            // is covered and keeps the face LOW found on it.
            let stacks = [OrganizeStack(items: items)]
            let medService = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .med))
            report = try medService.scan(items: items, analyzer: analyzer, stacks: stacks)
            XCTAssertEqual(report.photosProcessed, 3)
            XCTAssertEqual(report.photosBurstCovered, 1)

            let covered = items[1]
            XCTAssertEqual(try store.faces(photoID: covered.primary.pathKey).count, 1)
            XCTAssertEqual(
                try store.photos(pathKeys: [covered.primary.pathKey])[covered.primary.pathKey]?.scanGrade,
                .med
            )
        }
    }

    // MARK: - Video sampling

    func testVideoSampleTimes() throws {
        // MED: half-stride start, sparse coverage, capped.
        XCTAssertEqual(
            FaceVideoSampler.sampleTimes(duration: 100, stride: 30, maxFrames: 12),
            [15, 45, 75]
        )
        // HIGH: ~1 fps.
        XCTAssertEqual(
            FaceVideoSampler.sampleTimes(duration: 5.5, stride: 1, maxFrames: .max),
            [0.5, 1.5, 2.5, 3.5, 4.5]
        )
        // XHIGH: ~2 fps.
        XCTAssertEqual(
            FaceVideoSampler.sampleTimes(duration: 2.4, stride: 0.5, maxFrames: .max),
            [0.25, 0.75, 1.25, 1.75, 2.25]
        )
        // A clip shorter than the stride still contributes one mid frame.
        XCTAssertEqual(
            FaceVideoSampler.sampleTimes(duration: 10, stride: 30, maxFrames: 12),
            [5]
        )
        // The cap is respected on long clips.
        XCTAssertEqual(FaceVideoSampler.sampleTimes(duration: 600, stride: 30, maxFrames: 12).count, 12)
        XCTAssertTrue(FaceVideoSampler.sampleTimes(duration: 0, stride: 30, maxFrames: 12).isEmpty)
    }

    // MARK: - XHIGH extras

    func testXHighScansEveryBurstMember() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            var items: [OrganizeItem] = []
            for index in 1...4 {
                let url = root.appendingPathComponent("card/B0002_DSC000\(index).JPG")
                try writeJPEG(url, seed: UInt8(index))
                items.append(try organizeItem(forFileAt: url))
            }
            let stacks = [OrganizeStack(items: items)]
            let store = FaceIndexStore(url: catalog)
            let analyzer = StubAnalyzer()

            // MED samples first/middle/last and covers the rest…
            let medService = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .med))
            var report = try medService.scan(items: items, analyzer: analyzer, stacks: stacks)
            XCTAssertEqual(report.photosProcessed, 3)
            XCTAssertEqual(report.photosBurstCovered, 1)

            // …but XHIGH walks every burst still — no covered members.
            let xhighService = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .xhigh))
            report = try xhighService.scan(items: items, analyzer: analyzer, stacks: stacks)
            XCTAssertEqual(report.photosProcessed, 4)
            XCTAssertEqual(report.photosBurstCovered, 0)
            for item in items {
                XCTAssertEqual(
                    try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade,
                    .xhigh
                )
            }
        }
    }

    /// Flip TTA runs inside the engine; the pass only forwards the switch
    /// and the detector scales for the grade. HIGH asks for neither the
    /// mirror nor the 1024 scale, XHIGH asks for both, and the photo
    /// carries the grade that ran.
    func testXHighForwardsFlipTTAAndScalesToTheEngine() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            let jpegURL = root.appendingPathComponent("card/DSC00021.JPG")
            try writeJPEG(jpegURL, seed: 6)
            let item = try organizeItem(forFileAt: jpegURL)
            let analyzer = StubAnalyzer(faces: [
                analyzedFace(box: NormalizedFaceBox(x: 0.2, y: 0.2, width: 0.3, height: 0.3)),
            ])

            var service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .high))
            var report = try service.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.facesDetected, 1)
            XCTAssertEqual(analyzer.calls, 1)
            XCTAssertEqual(analyzer.lastOptions?.flipTTA, false)
            XCTAssertEqual(analyzer.lastOptions?.detectorScales, [640, 960])
            XCTAssertEqual(report.detectorSummary, "\(FaceEngine.identifier) scales 640/960")

            service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .xhigh))
            report = try service.scan(items: [item], analyzer: analyzer)
            XCTAssertEqual(report.facesDetected, 1)
            XCTAssertEqual(analyzer.calls, 2)
            XCTAssertEqual(analyzer.lastOptions?.flipTTA, true)
            XCTAssertEqual(analyzer.lastOptions?.detectorScales, [640, 960, 1024])
            XCTAssertEqual(report.detectorSummary, "insightface/buffalo_l scales 640/960/1024")
            // And the photo now carries the real grade — xhigh itself.
            XCTAssertEqual(
                try FaceIndexStore(url: catalog)
                    .photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade,
                .xhigh
            )
        }
    }

    func testXHighRebuildsRosterTemplatesFromConfirmedFaces() throws {
        try withFaceStore { store, catalog in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            // Confirmed faces across photos split between two
            // near-orthogonal "views". One photo holds two confirmed faces
            // — only its best may become a template.
            let viewA = testEmbedding(seed: 1)
            let viewB = testEmbedding(seed: 2)
            var expectedPhotos: Set<String> = []
            for index in 0..<3 {
                let photo = photoRecord("VA_\(index).JPG")
                var faces = [
                    faceRecord(
                        photo,
                        detScore: 0.9 - Double(index) * 0.05,
                        embedding: testEmbedding(seed: 1, noise: Float(index) * 0.03),
                        state: .confirmed,
                        personID: dad.id
                    ),
                ]
                if index == 0 {
                    // A second confirmed face on the same photo — a valid
                    // face but never a second template for that photo.
                    faces.append(faceRecord(
                        photo,
                        box: NormalizedFaceBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                        detScore: 0.5,
                        embedding: testEmbedding(seed: 1, noise: 0.5),
                        state: .confirmed,
                        personID: dad.id
                    ))
                }
                try store.replaceFaces(photo: photo, faces: faces)
                expectedPhotos.insert(photo.pathKey)
            }
            for index in 0..<6 {
                let photo = photoRecord("VB_\(index).JPG")
                try store.replaceFaces(photo: photo, faces: [
                    faceRecord(
                        photo,
                        detScore: 0.7,
                        embedding: testEmbedding(seed: 2, noise: Float(index) * 0.03),
                        state: .confirmed,
                        personID: dad.id
                    ),
                ])
                expectedPhotos.insert(photo.pathKey)
            }
            // An unconfirmed face and another person's confirmed face must
            // never seed Dad's templates.
            let uncleared = photoRecord("U1.JPG")
            try store.replaceFaces(photo: uncleared, faces: [
                faceRecord(uncleared, embedding: testEmbedding(seed: 3), personID: dad.id),
            ])
            let mom = try store.createPerson(name: "Mom", isRoster: true)
            let momPhoto = photoRecord("M1.JPG")
            try store.replaceFaces(photo: momPhoto, faces: [
                faceRecord(momPhoto, embedding: testEmbedding(seed: 4), state: .confirmed, personID: mom.id),
            ])

            // A stale pin from before — the rebuild replaces the set.
            let stale = try XCTUnwrap(store.faces(personID: dad.id).first)
            try store.addTemplate(personID: dad.id, faceID: stale.id)
            XCTAssertEqual(try store.rosterTemplates().count, 1)

            // An empty XHIGH pass still runs the rebuild.
            let service = FaceIndexService(
                catalogURL: catalog,
                options: FaceScanOptions(mode: .xhigh)
            )
            _ = try service.scan(items: [], analyzer: StubAnalyzer())

            // The rebuild runs for every roster person — Mom's single
            // confirmed face becomes her one template — so scope the
            // assertions to Dad's set.
            let templates = try store.rosterTemplates().filter { $0.personID == dad.id }
            // 9 eligible photos → 9 templates (under the 15 cap): every
            // view-B face plus the view-A spread.
            XCTAssertEqual(templates.count, 9)
            let viewBPicks = templates.filter {
                FaceEmbeddingMath.cosine($0.embedding, viewB)
                    > FaceEmbeddingMath.cosine($0.embedding, viewA)
            }
            XCTAssertEqual(viewBPicks.count, 6)

            // One template per photo, and only confirmed faces are picked.
            let ids = scalarRows(
                "SELECT face_id FROM face_templates WHERE person_id = '\(dad.id.uuidString)'",
                database: catalog
            ).compactMap { $0.first ?? nil }
            let photoIDs = ids.compactMap {
                scalarString("SELECT photo_id FROM faces WHERE id = '\($0)'", database: catalog)
            }
            XCTAssertEqual(Set(photoIDs), expectedPhotos)
            let states = ids.compactMap {
                scalarString("SELECT state FROM faces WHERE id = '\($0)'", database: catalog)
            }
            XCTAssertTrue(states.allSatisfy { $0 == "confirmed" })
        }
    }

    // MARK: - File-identity face lookup (burst preview overlay)

    func testFacesLookedUpByFileIdentitySurviveMoves() throws {
        try withFaceStore { store, _ in
            // Scanned in the unsorted folder at /card/DCIM.
            let atScan = photoRecord("DSC00001.ARW", size: 4_096, directory: "/card/DCIM")
            let face = faceRecord(
                atScan,
                box: NormalizedFaceBox(x: 0.2, y: 0.3, width: 0.15, height: 0.15),
                embedding: testEmbedding(seed: 3)
            )
            try store.replaceFaces(photo: atScan, faces: [face])

            // After the move the path key changed; the identity did not.
            let moved = photoRecord("DSC00001.ARW", size: 4_096, directory: "/library/event")
            let faces = try store.faces(
                fileName: moved.fileName,
                byteCount: moved.byteCount,
                modifiedAt: moved.modifiedAt,
                preferredPathKey: moved.pathKey
            )
            XCTAssertEqual(faces.map(\.id), [face.id])
            XCTAssertEqual(faces.first?.photoPath, atScan.path)

            // A same-named file of a different size is a different file.
            let other = try store.faces(
                fileName: "DSC00001.ARW",
                byteCount: 9_999,
                modifiedAt: moved.modifiedAt
            )
            XCTAssertTrue(other.isEmpty)

            // And a file that was never scanned yields no boxes.
            let unscanned = try store.faces(
                fileName: "DSC99999.ARW",
                byteCount: 4_096,
                modifiedAt: moved.modifiedAt
            )
            XCTAssertTrue(unscanned.isEmpty)
        }
    }

    func testFacesByFileIdentityDedupeAcrossPhotoRows() throws {
        try withFaceStore { store, _ in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            // The same file scanned twice — before and after its move — has
            // two photo rows with overlapping detections.
            let before = photoRecord("DSC00002.ARW", size: 2_048, directory: "/card/DCIM")
            let confirmed = faceRecord(
                before,
                box: NormalizedFaceBox(x: 0.2, y: 0.3, width: 0.15, height: 0.15),
                embedding: testEmbedding(seed: 4),
                state: .confirmed,
                personID: dad.id
            )
            try store.replaceFaces(photo: before, faces: [confirmed])

            let after = photoRecord("DSC00002.ARW", size: 2_048, directory: "/library/event")
            let redetected = faceRecord(
                after,
                box: NormalizedFaceBox(x: 0.21, y: 0.31, width: 0.15, height: 0.15),
                embedding: testEmbedding(seed: 5)
            )
            let fresh = faceRecord(
                after,
                box: NormalizedFaceBox(x: 0.7, y: 0.7, width: 0.1, height: 0.1),
                embedding: testEmbedding(seed: 6)
            )
            try store.replaceFaces(photo: after, faces: [redetected, fresh])

            // Confirmed wins the overlap regardless of which path it was
            // scanned under — the bare re-detection is deduped away and the
            // disjoint second face still shows.
            let faces = try store.faces(
                fileName: after.fileName,
                byteCount: after.byteCount,
                modifiedAt: after.modifiedAt,
                preferredPathKey: after.pathKey
            )
            XCTAssertEqual(Set(faces.map(\.id)), [confirmed.id, fresh.id])
        }
    }

    // MARK: - Manual face tagging (burst preview overlay)

    func testAddManualFaceOnUnscannedFile() throws {
        try withFaceStore { store, _ in
            let mom = try store.createPerson(name: "Mom", isRoster: true)
            let photo = photoRecord("DSC00010.ARW", size: 5_000, directory: "/card/DCIM")
            let box = NormalizedFaceBox(x: 0.3, y: 0.3, width: 0.2, height: 0.2)

            let face = try store.addManualFace(photo: photo, box: box, personID: mom.id)

            XCTAssertEqual(face.state, .confirmed)
            XCTAssertEqual(face.personID, mom.id)
            XCTAssertEqual(face.photoID, photo.pathKey)

            // The photo row exists now at grade .none — a real scan still
            // runs on the file later.
            let stored = try XCTUnwrap(try store.photos(pathKeys: [photo.pathKey])[photo.pathKey])
            XCTAssertEqual(stored.scanGrade, .none)
            XCTAssertEqual(stored.faceCount, 1)
            XCTAssertEqual(try store.faces(photoID: photo.pathKey).first?.state, .confirmed)
            XCTAssertEqual(try store.faces(personID: mom.id).count, 1)

            // A rescan keeps the confirmed face frozen and does not insert
            // an overlapping re-detection on top of it.
            let redetected = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.31, y: 0.31, width: 0.2, height: 0.2),
                embedding: testEmbedding(seed: 8)
            )
            try store.replaceFaces(
                photo: FacePhotoRecord(
                    pathKey: photo.pathKey,
                    path: photo.path,
                    fileName: photo.fileName,
                    byteCount: photo.byteCount,
                    modifiedAt: photo.modifiedAt,
                    scanGrade: .low
                ),
                faces: [redetected]
            )
            let after = try store.faces(photoID: photo.pathKey)
            XCTAssertEqual(after.count, 1)
            XCTAssertEqual(after.first?.id, face.id)
            XCTAssertEqual(after.first?.state, .confirmed)
            XCTAssertEqual(
                try store.photos(pathKeys: [photo.pathKey])[photo.pathKey]?.scanGrade,
                .low
            )
        }
    }

    func testAddManualFaceClaimsOverlappingDetection() throws {
        try withFaceStore { store, _ in
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            var photo = photoRecord("DSC00011.ARW", size: 5_000, directory: "/card/DCIM")
            photo.scanGrade = .low
            let detected = faceRecord(
                photo,
                box: NormalizedFaceBox(x: 0.3, y: 0.3, width: 0.2, height: 0.2),
                embedding: testEmbedding(seed: 9),
                state: .cached
            )
            try store.replaceFaces(photo: photo, faces: [detected])

            // Drawing over the detected face claims it: same row id, now
            // confirmed for the person, keeping its embedding.
            let box = NormalizedFaceBox(x: 0.31, y: 0.29, width: 0.2, height: 0.2)
            let claimed = try store.addManualFace(photo: photo, box: box, personID: dad.id)
            XCTAssertEqual(claimed.id, detected.id)
            XCTAssertEqual(claimed.state, .confirmed)
            XCTAssertEqual(claimed.personID, dad.id)
            XCTAssertEqual(try store.faces(photoID: photo.pathKey).count, 1)
            XCTAssertEqual(try store.face(id: detected.id)?.embedding?.count, 512)

            // The scan grade survives the manual tag — manual rows never
            // stamp a grade.
            XCTAssertEqual(
                try store.photos(pathKeys: [photo.pathKey])[photo.pathKey]?.scanGrade,
                .low
            )

            // A box over a confirmed face is a no-op — confirmed is frozen.
            let other = try store.createPerson(name: "Mom", isRoster: true)
            let frozen = try store.addManualFace(photo: photo, box: box, personID: other.id)
            XCTAssertEqual(frozen.id, detected.id)
            XCTAssertEqual(frozen.personID, dad.id)
            XCTAssertEqual(try store.faces(personID: other.id).count, 0)
        }
    }

    func testAddManualFaceDropsStaleUnconfirmedFaces() throws {
        try withFaceStore { store, _ in
            let person = try store.createPerson(name: "A", isRoster: true)
            let scanned = photoRecord("DSC00012.ARW", size: 5_000, directory: "/card/DCIM")
            let old = faceRecord(
                scanned,
                box: NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.1, height: 0.1),
                embedding: testEmbedding(seed: 11)
            )
            try store.replaceFaces(photo: scanned, faces: [old])

            // The file changed on disk (new size): the old unconfirmed row
            // described different bytes and is dropped; the new tag stays.
            let changed = photoRecord("DSC00012.ARW", size: 6_000, directory: "/card/DCIM")
            let drawn = NormalizedFaceBox(x: 0.5, y: 0.5, width: 0.15, height: 0.15)
            let face = try store.addManualFace(photo: changed, box: drawn, personID: person.id)
            let faces = try store.faces(photoID: changed.pathKey)
            XCTAssertEqual(faces.map(\.id), [face.id])
        }
    }

    // MARK: - Clear face index

    /// The wipe empties exactly the face tables — an `events` row in the
    /// same database survives untouched.
    func testClearFaceIndexWipesOnlyTheFaceTables() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            var configuration = faceTestConfiguration(root: root, catalog: catalog)
            configuration.savedEvents = [
                SavedCameraEvent(name: "Beach Day", eventDate: Date(timeIntervalSince1970: 1_752_000_000)),
            ]
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = FaceIndexStore(url: catalog)

            // Seed every face table: a named person with a confirmed face
            // and a template, plus an unnamed group on a second photo.
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let group = try store.createPerson(name: "Person 1", isRoster: false)
            var photoA = photoRecord("CLR0001.ARW")
            photoA.scanGrade = .med
            var photoB = photoRecord("CLR0002.ARW")
            photoB.scanGrade = .med
            let dadFace = faceRecord(photoA, embedding: testEmbedding(seed: 5), state: .confirmed, personID: dad.id)
            let groupFace = faceRecord(
                photoB,
                box: NormalizedFaceBox(x: 0.6, y: 0.6, width: 0.15, height: 0.15),
                embedding: testEmbedding(seed: 6),
                state: .other,
                personID: group.id
            )
            try store.replaceFaces(photo: photoA, faces: [dadFace])
            try store.replaceFaces(photo: photoB, faces: [groupFace])
            try store.addTemplate(personID: dad.id, faceID: dadFace.id)
            try store.recordRejection(personID: group.id, faceID: groupFace.id)

            XCTAssertEqual(
                try store.faceIndexCounts(),
                FaceIndexCounts(scannedPhotos: 2, faces: 2, namedPeople: 1, unnamedGroups: 1)
            )
            XCTAssertEqual(try store.storedScanGrades(), [.med])
            XCTAssertEqual(scalarInt("SELECT COUNT(*) FROM events", database: catalog), 1)
            XCTAssertEqual(scalarInt("SELECT COUNT(*) FROM face_rejections", database: catalog), 1)

            try store.clearFaceIndex()

            for table in ["face_photos", "faces", "people", "face_templates", "face_rejections"] {
                XCTAssertEqual(
                    scalarInt("SELECT COUNT(*) FROM \(table)", database: catalog),
                    0,
                    "\(table) still has rows"
                )
            }
            XCTAssertEqual(scalarInt("SELECT COUNT(*) FROM events", database: catalog), 1)
            XCTAssertEqual(scalarString("SELECT name FROM events", database: catalog), "Beach Day")
            XCTAssertEqual(scalarString("PRAGMA integrity_check", database: catalog), "ok")
            XCTAssertEqual(try store.faceIndexCounts(), FaceIndexCounts())
            XCTAssertEqual(try store.storedScanGrades(), [])
        }
    }

    /// The footer's grade list comes from `face_photos.scan_grade`:
    /// distinct values, lowest first, and the `none` marker manual tags
    /// leave on never-scanned files stays out — it is not a scan grade.
    func testStoredScanGradesListsDistinctGradesLowestFirst() throws {
        try withFaceStore { store, _ in
            var medium = photoRecord("GRD0001.ARW")
            medium.scanGrade = .med
            var low = photoRecord("GRD0002.ARW")
            low.scanGrade = .low
            var extraHigh = photoRecord("GRD0003.ARW")
            extraHigh.scanGrade = .xhigh
            try store.replaceFaces(photo: medium, faces: [])
            try store.replaceFaces(photo: low, faces: [])
            try store.replaceFaces(photo: extraHigh, faces: [])

            // A manual tag stamps 'none' on a never-scanned file.
            let person = try store.createPerson(name: "Dad", isRoster: true)
            _ = try store.addManualFace(
                photo: photoRecord("GRD0004.ARW"),
                box: NormalizedFaceBox(x: 0.3, y: 0.3, width: 0.2, height: 0.2),
                personID: person.id
            )

            XCTAssertEqual(try store.storedScanGrades(), [.low, .med, .xhigh])
        }
    }

    // MARK: - Helpers

    /// Opens a bootstrapped catalog + face store inside a temp folder.
    private func withFaceStore(_ body: (FaceIndexStore, URL) throws -> Void) throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            try body(FaceIndexStore(url: catalog), catalog)
        }
    }

    private func faceTestConfiguration(root: URL, catalog: URL) -> AppConfiguration {
        var configuration = testConfiguration(root: root)
        configuration.catalogDatabasePath = catalog.path
        return configuration
    }

    private func photoRecord(
        _ name: String,
        size: Int64 = 1_024,
        modified: Date = Date(timeIntervalSince1970: 1_752_000_000),
        directory: String = "/tmp/faces"
    ) -> FacePhotoRecord {
        let path = "\(directory)/\(name)"
        return FacePhotoRecord(
            pathKey: EventStorageLocations.pathKey(path),
            path: path,
            fileName: name,
            byteCount: size,
            modifiedAt: modified
        )
    }

    private func faceRecord(
        _ photo: FacePhotoRecord,
        box: NormalizedFaceBox = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
        detScore: Double = 0.9,
        embedding: [Float]? = nil,
        state: FaceState = .cached,
        personID: UUID? = nil,
        quality: Double? = nil,
        facePixels: Double? = nil,
        model: String = FaceEngine.identifier
    ) -> FaceRecord {
        FaceRecord(
            photoID: photo.pathKey,
            personID: personID,
            box: box,
            detScore: detScore,
            quality: quality,
            facePixels: facePixels,
            embedding: embedding,
            model: model,
            state: state,
            photoPath: photo.path
        )
    }

    /// One canned engine result. The defaults describe a clean, large
    /// face — unit embedding, healthy quality, well above every size gate
    /// — so a test about a gate sets only the field it is probing.
    private func analyzedFace(
        box: NormalizedFaceBox = NormalizedFaceBox(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
        detScore: Double = 0.9,
        embedding: [Float]? = nil,
        quality: Double = 20,
        facePixels: Double = 200
    ) -> AnalyzedFace {
        AnalyzedFace(
            box: box,
            detScore: detScore,
            embedding: embedding ?? FaceEmbeddingMath.l2Normalized([Float](repeating: 1, count: 512)),
            quality: quality,
            facePixels: facePixels
        )
    }

    /// Builds an OrganizeItem without touching disk — for scan-target
    /// sampling tests where only name, size, and kind matter.
    private func stubItem(
        _ name: String,
        size: Int64 = 10_000_000,
        kind: OrganizeMediaKind = .photo
    ) -> OrganizeItem {
        let modified = Date(timeIntervalSince1970: 1_752_000_000)
        return OrganizeItem(
            primary: OrganizeFile(path: "/card/DCIM/\(name)", size: size, modifiedAt: modified),
            kind: kind,
            captureDate: modified,
            hasCameraDate: true
        )
    }

    /// Builds a real OrganizeItem from a file on disk so size/mtime match the
    /// bytes the scan pipeline will stat.
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

    /// A deterministic 512-d vector. Different seeds are near-orthogonal;
    /// `noise` produces a slightly perturbed copy of the same seed's vector.
    private func testEmbedding(seed: UInt64, noise: Float = 0) -> [Float] {
        var generator = SplitMix64(seed: seed)
        var vector = (0..<512).map { _ in
            Float(generator.next() >> 40) / Float(1 << 24) * 2 - 1
        }
        if noise > 0 {
            var noiseGenerator = SplitMix64(seed: seed ^ 0x9E3779B97F4A7C15)
            for index in vector.indices {
                vector[index] += noise * (Float(noiseGenerator.next() >> 40) / Float(1 << 24) * 2 - 1)
            }
        }
        return FaceEmbeddingMath.l2Normalized(vector)
    }

    /// Writes a flat-gradient JPEG — decodable, and guaranteed to contain no
    /// faces so the scan exercises the pipeline without needing real media.
    /// `padToBytes` pads the tail (harmless to decoders) so a file clears the
    /// scan's tiny-sample size floor.
    private func writeJPEG(_ url: URL, seed: UInt8, padToBytes: Int = 0) throws {
        let size = 640
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not create a test bitmap")
        }
        // Paint a few flat bands so the output is a valid non-empty JPEG.
        for band in 0..<8 {
            let shade = CGFloat((Int(seed) + band * 31) % 255) / 255
            context.setFillColor(CGColor(red: shade, green: shade, blue: 1 - shade, alpha: 1))
            context.fill(CGRect(x: 0, y: band * size / 8, width: size, height: size / 8))
        }
        let painted = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw XCTSkip("Could not create a JPEG destination")
        }
        CGImageDestinationAddImage(destination, painted, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("Could not finalize a JPEG")
        }
        var bytes = data as Data
        if bytes.count < padToBytes {
            bytes.append(Data(repeating: 0, count: padToBytes - bytes.count))
        }
        try writeFile(url, bytes)
    }

    private func scalarInt(_ sql: String, database url: URL) -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { return -1 }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return -1 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }

    private func scalarString(_ sql: String, database url: URL) -> String? {
        scalarRows(sql, database: url).first?.first ?? nil
    }

    private func scalarRows(_ sql: String, database url: URL) -> [[String?]] {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { return [] }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String?] = []
            let columns = sqlite3_column_count(statement)
            for index in 0..<columns {
                if sqlite3_column_type(statement, index) == SQLITE_NULL {
                    row.append(nil)
                } else if let text = sqlite3_column_text(statement, index) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }
}

/// Deterministic PRNG for synthetic embeddings — no crypto needed.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Canned engine results so service tests exercise the real scan path
/// without the sidecar. `error` makes every call throw — the engine
/// failure path. Records each call so a test can prove a skipped photo
/// never reached the engine and see what the pass asked for.
private final class StubAnalyzer: FaceAnalyzing, @unchecked Sendable {
    let displayName = "StubAnalyzer"
    var faces: [AnalyzedFace]
    var error: Error?
    private let lock = NSLock()
    private var seen: [FaceScanOptions] = []

    init(faces: [AnalyzedFace] = [], error: Error? = nil) {
        self.faces = faces
        self.error = error
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.count
    }

    /// The options the most recent call carried.
    var lastOptions: FaceScanOptions? {
        lock.lock()
        defer { lock.unlock() }
        return seen.last
    }

    func analyze(_ image: CGImage, options: FaceScanOptions) throws -> [AnalyzedFace] {
        lock.lock()
        seen.append(options)
        lock.unlock()
        if let error { throw error }
        return faces
    }
}
