import CoreGraphics
import Foundation
import GRDB
import ImageIO
@testable import CameraToolkitCore
import XCTest

/// Dogs are detected on an upright picture; people are not. Stored boxes
/// stay in one space, and the one-time rescan of sideways-read RAWs keeps
/// the user's sorting.
final class PetUprightDetectionTests: XCTestCase {

    // MARK: - The option is pets only

    func testUprightDetectionIsAPetOnlyOption() {
        for mode in FaceScanGrade.allCases {
            XCTAssertFalse(FaceScanOptions(mode: mode).uprightRawDetection, "people keep the sideways decode")
            XCTAssertTrue(FaceScanOptions.pets(mode: mode).uprightRawDetection)
        }
    }

    /// The people pass sees exactly the picture it always saw, and its box
    /// is stored as the engine returned it.
    func testAFaceScanStillDetectsOnTheUnturnedPreview() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: testConfiguration(root: root),
                createBackup: false,
                createLibraryFolders: false
            )
            let raw = root.appendingPathComponent("DSC00001.ARW")
            try writeOrientedRAW(raw, orientation: 6)
            let box = NormalizedFaceBox(x: 0.1, y: 0.2, width: 0.3, height: 0.2)
            let analyzer = RecordingAnalyzer(results: [[Self.detection(box, seed: 1)]])
            let report = try FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .low))
                .scan(stacks: [OrganizeStack(items: [try item(raw)])], analyzer: analyzer)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(report.photosRescannedUpright, 0)
            let size = try XCTUnwrap(analyzer.sizes.first)
            XCTAssertGreaterThan(size.width, size.height, "a face scan must not turn the picture")
            let stored = try FaceIndexStore(url: catalog).faces(photoID: try item(raw).primary.pathKey)
            XCTAssertEqual(stored.first?.box, box)
            XCTAssertFalse(try hasMarkerTable(catalog), "the catalog is untouched by the pet marker")
        }
    }

    // MARK: - Upright detection

    func testAPetScanDetectsUprightAndStoresTheBoxInTheUnturnedSpace() throws {
        try withFixture { fixture in
            let raw = fixture.root.appendingPathComponent("DSC00001.ARW")
            try writeOrientedRAW(raw, orientation: 6)
            let upright = NormalizedFaceBox(x: 0.1, y: 0.2, width: 0.3, height: 0.2)
            let analyzer = RecordingAnalyzer(results: [[Self.detection(upright, seed: 1)]])
            let report = try fixture.service().scan(stacks: [OrganizeStack(items: [try item(raw)])], analyzer: analyzer)

            XCTAssertEqual(report.photosProcessed, 1)
            let size = try XCTUnwrap(analyzer.sizes.first)
            XCTAssertLessThan(size.width, size.height, "the detector must see a standing picture")
            let key = try item(raw).primary.pathKey
            let stored = try XCTUnwrap(try fixture.store.faces(photoID: key).first)
            let expected = FaceBoxProjection.storedBox(fromTurned: upright, quarterTurnsCW: 1)
            XCTAssertEqual(stored.box, expected)
            XCTAssertEqual(try fixture.markerTurns(key), 1, "a photo scanned after the fix is marked")
            // Drawn back at the camera's turn, the box is where the detector found the dog.
            let drawn = FaceBoxProjection.rotatedTopLeftRect(FaceBoxProjection.topLeftRect(of: stored.box), quarterTurnsCW: 1)
            assertClose(FaceBoxProjection.box(ofTopLeftRect: drawn), upright)
            XCTAssertNotNil(stored.crop, "the crop the sidecar cut comes from the upright picture")
        }
    }

    func testAnUprightOrdinaryPhotoIsNotTurnedAndIsMarkedWithoutAHeaderRead() throws {
        try withFixture { fixture in
            let jpeg = fixture.root.appendingPathComponent("DSC00002.JPG")
            try writeLandscapeJPEG(jpeg, width: 640, height: 400)
            let analyzer = RecordingAnalyzer(results: [[]])
            let reads = ReadCounter(turns: 3)
            var service = fixture.service()
            service.cameraTurnsReader = reads.read
            _ = try service.scan(stacks: [OrganizeStack(items: [try item(jpeg, kind: .photo)])], analyzer: analyzer)
            XCTAssertEqual(analyzer.sizes.first?.width, 640)
            XCTAssertEqual(reads.count, 0, "a non-RAW photo costs no header read")
            XCTAssertEqual(try fixture.markerTurns(try item(jpeg, kind: .photo).primary.pathKey), 0)
        }
    }

    /// The whole table is one space: the round trip holds for every turn.
    func testBoxesRoundTripToTheStoredSpaceForEveryTurn() {
        let original = NormalizedFaceBox(x: 0.11, y: 0.27, width: 0.31, height: 0.43)
        for turns in 0...3 {
            let upright = FaceBoxProjection.box(ofTopLeftRect: FaceBoxProjection.rotatedTopLeftRect(
                FaceBoxProjection.topLeftRect(of: original),
                quarterTurnsCW: turns
            ))
            assertClose(FaceBoxProjection.storedBox(fromTurned: upright, quarterTurnsCW: turns), original, "turn \(turns)")
        }
    }

    // MARK: - Which photos are re-read

    func testOnlyUnmarkedRawsWithACameraTurnAreRescanned() throws {
        try withFixture { fixture in
            let vertical = try fixture.scanned("DSC00010.ARW", orientation: 6, faces: [])
            let upright = try fixture.scanned("DSC00011.ARW", orientation: 1, faces: [])
            let jpeg = try fixture.scanned("DSC00012.JPG", orientation: nil, faces: [], kind: .photo)
            let marked = try fixture.scanned("DSC00013.ARW", orientation: 8, faces: [])
            try fixture.mark(marked.primary.pathKey, turns: 3)

            let reads = ReadCounter(turns: nil, realFirst: true)
            let analyzer = RecordingAnalyzer(results: [[]])
            var service = fixture.service()
            service.cameraTurnsReader = reads.read
            let report = try service.scan(
                stacks: [vertical, upright, jpeg, marked].map { OrganizeStack(items: [$0]) },
                analyzer: analyzer
            )

            XCTAssertEqual(report.photosRescannedUpright, 1)
            XCTAssertEqual(report.photosSkipped, 3)
            XCTAssertEqual(analyzer.sizes.count, 1, "only the vertical unmarked RAW reaches the detector")
            XCTAssertEqual(reads.urls.sorted(), [vertical.primary.url.path, upright.primary.url.path].sorted(), "header reads go to unmarked RAWs only")
            XCTAssertEqual(try fixture.markerTurns(upright.primary.pathKey), 0, "an upright RAW is marked done")
            XCTAssertEqual(try fixture.markerTurns(vertical.primary.pathKey), 1)

            // A second pass reads nothing and detects nothing.
            let secondReads = ReadCounter(turns: 1)
            let secondAnalyzer = RecordingAnalyzer(results: [])
            var second = fixture.service()
            second.cameraTurnsReader = secondReads.read
            let again = try second.scan(
                stacks: [vertical, upright, jpeg, marked].map { OrganizeStack(items: [$0]) },
                analyzer: secondAnalyzer
            )
            XCTAssertEqual(again.photosRescannedUpright, 0)
            XCTAssertEqual(secondReads.count, 0)
            XCTAssertEqual(secondAnalyzer.sizes.count, 0)
        }
    }

    /// A photo found to have no dog sideways is still re-read; that is
    /// where a miss would hide.
    func testASidewaysPhotoWithNoDogGetsADogWhenUprightFindsOne() throws {
        try withFixture { fixture in
            let photo = try fixture.scanned("DSC00020.ARW", orientation: 6, faces: [])
            let dog = NormalizedFaceBox(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
            _ = try fixture.service(reader: { _ in 1 }).scan(
                stacks: [OrganizeStack(items: [photo])],
                analyzer: RecordingAnalyzer(results: [[Self.detection(dog, seed: 2)]])
            )
            let faces = try fixture.store.faces(photoID: photo.primary.pathKey)
            XCTAssertEqual(faces.count, 1)
            XCTAssertEqual(try fixture.store.photos(pathKeys: [photo.primary.pathKey])[photo.primary.pathKey]?.faceCount, 1)
        }
    }

    func testAFailedDetectionLeavesTheRowsAndMarkerAloneAndIsRetried() throws {
        try withFixture { fixture in
            let owner = try fixture.store.createPerson(name: "Rex", isRoster: true)
            let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
            let old = FaceRecord(photoID: "", personID: owner.id, box: box, detScore: 0.7, embedding: Self.vector(1), model: PetFaceEngine.identifier, state: .confirmed, scanGrade: .high)
            let photo = try fixture.scanned("DSC00021.ARW", orientation: 6, faces: [old])
            let before = try fixture.store.faces(photoID: photo.primary.pathKey)

            let failing = RecordingAnalyzer(results: [], fails: true)
            let report = try fixture.service(reader: { _ in 1 }).scan(stacks: [OrganizeStack(items: [photo])], analyzer: failing)
            XCTAssertEqual(report.photosFailed, 1)
            XCTAssertEqual(report.photosRescannedUpright, 0)
            XCTAssertEqual(try fixture.store.faces(photoID: photo.primary.pathKey), before)
            XCTAssertNil(try fixture.markerTurns(photo.primary.pathKey))

            // Next scan: it is still unmarked, so it is tried again.
            let retry = try fixture.service(reader: { _ in 1 }).scan(
                stacks: [OrganizeStack(items: [photo])],
                analyzer: RecordingAnalyzer(results: [[Self.detection(box, seed: 1)]])
            )
            XCTAssertEqual(retry.photosRescannedUpright, 1)
            XCTAssertEqual(try fixture.markerTurns(photo.primary.pathKey), 1)
        }
    }

    func testAnUnreadableHeaderLeavesThePhotoUnmarkedAndUncounted() throws {
        try withFixture { fixture in
            let photo = try fixture.scanned("DSC00022.ARW", orientation: 6, faces: [])
            let analyzer = RecordingAnalyzer(results: [])
            let report = try fixture.service(reader: { _ in nil }).scan(stacks: [OrganizeStack(items: [photo])], analyzer: analyzer)
            XCTAssertEqual(report.photosSkipped, 1, "a NAS that is gone looks like an ordinary skip")
            XCTAssertEqual(analyzer.sizes.count, 0)
            XCTAssertNil(try fixture.markerTurns(photo.primary.pathKey))
        }
    }

    func testAMissingFileDuringRescanFailsWithoutTouchingRows() throws {
        try withFixture { fixture in
            let owner = try fixture.store.createPerson(name: "Rex", isRoster: true)
            let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
            let old = FaceRecord(photoID: "", personID: owner.id, box: box, detScore: 0.7, embedding: Self.vector(1), model: PetFaceEngine.identifier, state: .confirmed, scanGrade: .high)
            let photo = try fixture.scanned("DSC00023.ARW", orientation: 6, faces: [old])
            let before = try fixture.store.faces(photoID: photo.primary.pathKey)
            try FileManager.default.removeItem(at: photo.primary.url)
            let report = try fixture.service(reader: { _ in 1 }).scan(
                stacks: [OrganizeStack(items: [photo])],
                analyzer: RecordingAnalyzer(results: [[Self.detection(box, seed: 1)]])
            )
            XCTAssertEqual(report.photosFailed, 1)
            XCTAssertEqual(report.photosRescannedUpright, 0)
            XCTAssertEqual(try fixture.store.faces(photoID: photo.primary.pathKey), before)
            XCTAssertNil(try fixture.markerTurns(photo.primary.pathKey))
        }
    }

    /// One photo's trouble leaves the others done, so a quit or crash
    /// mid-pass resumes where it stopped.
    func testTheRescanResumesPhotoByPhoto() throws {
        try withFixture { fixture in
            let first = try fixture.scanned("DSC00030.ARW", orientation: 6, faces: [], imageWidth: 620)
            let second = try fixture.scanned("DSC00031.ARW", orientation: 6, faces: [], imageWidth: 640)
            let bad = RecordingAnalyzer(results: [], failsForWidth: 640, passthroughFaces: [])
            let report = try fixture.service(reader: { _ in 1 }).scan(
                stacks: [first, second].map { OrganizeStack(items: [$0]) },
                analyzer: bad
            )
            XCTAssertEqual(report.photosRescannedUpright, 1)
            XCTAssertEqual(report.photosFailed, 1)
            XCTAssertEqual(try fixture.markerTurns(first.primary.pathKey), 1)
            XCTAssertNil(try fixture.markerTurns(second.primary.pathKey))

            let good = RecordingAnalyzer(results: [])
            let again = try fixture.service(reader: { _ in 1 }).scan(
                stacks: [first, second].map { OrganizeStack(items: [$0]) },
                analyzer: good
            )
            XCTAssertEqual(again.photosRescannedUpright, 1, "only the one not marked yet")
            XCTAssertEqual(good.sizes.count, 1)
        }
    }

    func testARescanNeverLowersThePhotosGrade() throws {
        try withFixture { fixture in
            let photo = try fixture.scanned("DSC00032.ARW", orientation: 6, faces: [], grade: .high)
            let analyzer = RecordingAnalyzer(results: [[]])
            let report = try fixture.service(reader: { _ in 1 }, mode: .low).scan(
                stacks: [OrganizeStack(items: [photo])],
                analyzer: analyzer
            )
            XCTAssertEqual(report.photosRescannedUpright, 1)
            XCTAssertEqual(try fixture.store.photos(pathKeys: [photo.primary.pathKey])[photo.primary.pathKey]?.scanGrade, .high)
            XCTAssertEqual(analyzer.options.first?.minimumFacePixels, FaceScanOptions.pets(mode: .high).minimumFacePixels)
        }
    }

    // MARK: - Matching

    func testOneToOneInheritsEverythingByKeepingTheRow() throws {
        try withFixture { fixture in
            let pet = try fixture.store.createPerson(name: "Rex", isRoster: true)
            let box = NormalizedFaceBox(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
            let old = fixture.face(pet.id, box: box, seed: 1, state: .confirmed)
            let photo = try fixture.scanned("DSC00040.ARW", orientation: 6, faces: [old])
            try fixture.store.addTemplate(personID: pet.id, faceID: old.id)
            try fixture.store.recordRejection(personID: pet.id, faceID: old.id)
            _ = try fixture.store.setCoverFace(personID: pet.id, faceID: old.id)

            let newBox = NormalizedFaceBox(x: 0.21, y: 0.2, width: 0.4, height: 0.4)
            let upright = Self.boxTurned(newBox, by: 1)
            let report = try fixture.service(reader: { _ in 1 }).scan(
                stacks: [OrganizeStack(items: [photo])],
                analyzer: RecordingAnalyzer(results: [[Self.detection(upright, seed: 9)]])
            )
            XCTAssertEqual(report.photosRescannedUpright, 1)
            let row = try XCTUnwrap(try fixture.store.face(id: old.id))
            assertClose(row.box, newBox)
            XCTAssertEqual(row.state, .confirmed)
            XCTAssertEqual(row.personID, pet.id)
            XCTAssertEqual(row.embedding, Self.vector(9), "the upright vector replaces the sideways one")
            XCTAssertEqual(try fixture.store.person(pet.id)?.coverFaceID, old.id)
            XCTAssertEqual(try fixture.count("SELECT COUNT(*) FROM face_templates WHERE face_id = '\(old.id.uuidString)'"), 1)
            XCTAssertEqual(try fixture.count("SELECT COUNT(*) FROM face_rejections WHERE face_id = '\(old.id.uuidString)'"), 1)
            XCTAssertEqual(try fixture.store.person(pet.id)?.faceCount, 1)
            XCTAssertEqual(try fixture.count("SELECT COUNT(*) FROM faces"), 1)
        }
    }

    func testAMergedBoxOnAnAutoGroupOnlyJoinsWhereGroupingWould() throws {
        try withFixture { fixture in
            let group = try fixture.store.createPerson(name: "Dog 1", isRoster: false)
            let wide = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.8, height: 0.5)
            let merged = fixture.face(group.id, box: wide, seed: 50, state: .other)
            let photo = try fixture.scanned("DSC00041.ARW", orientation: 6, faces: [merged])
            // Two other members so the group survives and the mean is real.
            try fixture.seedGroupMembers(group.id, seed: 1, count: 2)

            let left = NormalizedFaceBox(x: 0.12, y: 0.12, width: 0.36, height: 0.45)
            let right = NormalizedFaceBox(x: 0.52, y: 0.12, width: 0.36, height: 0.45)
            let report = try fixture.service(reader: { _ in 1 }).scan(
                stacks: [OrganizeStack(items: [photo])],
                analyzer: RecordingAnalyzer(results: [[
                    Self.detection(Self.boxTurned(left, by: 1), seed: 1),
                    Self.detection(Self.boxTurned(right, by: 1), seed: 200),
                ]])
            )
            XCTAssertEqual(report.photosRescannedUpright, 1)
            XCTAssertNil(try fixture.store.face(id: merged.id), "the two-dog box is replaced by the two dogs")
            let faces = try fixture.store.faces(photoID: photo.primary.pathKey).sorted { $0.box.x < $1.box.x }
            XCTAssertEqual(faces.count, 2)
            XCTAssertEqual(faces[0].personID, group.id, "the dog resembling the group joins it")
            XCTAssertEqual(faces[0].state, .other)
            XCTAssertNil(faces[1].personID, "the unlike dog is left for review")
            XCTAssertEqual(faces[1].state, .cached)
            XCTAssertEqual(try fixture.store.person(group.id)?.faceCount, 3)
        }
    }

    /// A template row is never deleted, and a dog only becomes a "looks
    /// like" suggestion of the pet, never the pet itself.
    func testAMergedTemplateIsKeptAndTheDogsAreOnlySuggested() throws {
        try withFixture { fixture in
            let pet = try fixture.store.createPerson(name: "Rex", isRoster: true)
            let wide = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.8, height: 0.5)
            let merged = fixture.face(pet.id, box: wide, seed: 50, state: .confirmed)
            let photo = try fixture.scanned("DSC00042.ARW", orientation: 6, faces: [merged])
            try fixture.store.addTemplate(personID: pet.id, faceID: merged.id)
            let other = fixture.face(pet.id, box: wide, seed: 1, state: .confirmed)
            _ = try fixture.scanned("DSC00043.ARW", orientation: 1, faces: [other])
            try fixture.store.addTemplate(personID: pet.id, faceID: other.id)

            let left = NormalizedFaceBox(x: 0.12, y: 0.12, width: 0.36, height: 0.45)
            let right = NormalizedFaceBox(x: 0.52, y: 0.12, width: 0.36, height: 0.45)
            _ = try fixture.service(reader: { $0.lastPathComponent.hasPrefix("DSC00042") ? 1 : 0 }).scan(
                stacks: [OrganizeStack(items: [photo])],
                analyzer: RecordingAnalyzer(results: [[
                    Self.detection(Self.boxTurned(left, by: 1), seed: 1),
                    Self.detection(Self.boxTurned(right, by: 1), seed: 200),
                ]])
            )
            let kept = try XCTUnwrap(try fixture.store.face(id: merged.id), "a confirmed template row stays")
            XCTAssertEqual(kept.personID, pet.id)
            XCTAssertEqual(kept.state, .confirmed)
            let faces = try fixture.store.faces(photoID: photo.primary.pathKey).filter { $0.id != merged.id }.sorted { $0.box.x < $1.box.x }
            XCTAssertEqual(faces.count, 2)
            XCTAssertEqual(faces[0].state, .proposed)
            let row = try XCTUnwrap(faces[0].personID.flatMap { try fixture.store.person($0) })
            XCTAssertEqual(row.suggestedPersonID, pet.id, "filed on the looks-like row")
            XCTAssertFalse(row.isRoster)
            XCTAssertEqual(faces[1].state, .cached)
            XCTAssertNil(faces[1].personID)
            XCTAssertEqual(try fixture.count("SELECT COUNT(*) FROM face_templates WHERE person_id = '\(pet.id.uuidString)'"), 2)
            XCTAssertEqual(try fixture.store.person(pet.id)?.faceCount, 2)
        }
    }

    func testAnOldBoxWithNoNewBoxIsKeptWhenAssignedOrGuardedAndDroppedWhenOnlyCached() throws {
        try withFixture { fixture in
            let pet = try fixture.store.createPerson(name: "Rex", isRoster: true)
            let group = try fixture.store.createPerson(name: "Dog 2", isRoster: false)
            let confirmed = fixture.face(pet.id, box: Self.square(0.1), seed: 1, state: .confirmed)
            let grouped = fixture.face(group.id, box: Self.square(0.3), seed: 2, state: .other)
            let cached = fixture.face(nil, box: Self.square(0.5), seed: 3, state: .cached)
            let rejected = fixture.face(nil, box: Self.square(0.7), seed: 4, state: .cached)
            let photo = try fixture.scanned("DSC00044.ARW", orientation: 6, faces: [confirmed, grouped, cached, rejected])
            try fixture.store.recordRejection(personID: pet.id, faceID: rejected.id)

            _ = try fixture.service(reader: { _ in 1 }).scan(
                stacks: [OrganizeStack(items: [photo])],
                analyzer: RecordingAnalyzer(results: [[]])
            )
            XCTAssertNotNil(try fixture.store.face(id: confirmed.id))
            XCTAssertNotNil(try fixture.store.face(id: grouped.id), "a grouped box is never quietly dropped")
            XCTAssertNil(try fixture.store.face(id: cached.id), "an unassigned detection may be replaced")
            XCTAssertNotNil(try fixture.store.face(id: rejected.id), "a verdict is not lost")
            XCTAssertEqual(try fixture.store.photos(pathKeys: [photo.primary.pathKey])[photo.primary.pathKey]?.faceCount, 3)
        }
    }

    /// A merged row that is the group's only member stays: the group must
    /// never vanish because of a rescan.
    func testAGroupNeverLosesItsLastFace() throws {
        try withFixture { fixture in
            let group = try fixture.store.createPerson(name: "Dog 3", isRoster: false)
            let wide = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.8, height: 0.5)
            let merged = fixture.face(group.id, box: wide, seed: 50, state: .other)
            let photo = try fixture.scanned("DSC00045.ARW", orientation: 6, faces: [merged])
            let left = NormalizedFaceBox(x: 0.12, y: 0.12, width: 0.36, height: 0.45)
            let right = NormalizedFaceBox(x: 0.52, y: 0.12, width: 0.36, height: 0.45)
            _ = try fixture.service(reader: { _ in 1 }).scan(
                stacks: [OrganizeStack(items: [photo])],
                analyzer: RecordingAnalyzer(results: [[
                    Self.detection(Self.boxTurned(left, by: 1), seed: 7),
                    Self.detection(Self.boxTurned(right, by: 1), seed: 8),
                ]])
            )
            XCTAssertNotNil(try fixture.store.face(id: merged.id))
            XCTAssertNotNil(try fixture.store.person(group.id))
            XCTAssertEqual(try fixture.store.person(group.id)?.faceCount, 1)
        }
    }

    func testANewBoxWithNoOldBoxGoesToTheNormalPass() throws {
        try withFixture { fixture in
            let old = fixture.face(nil, box: Self.square(0.1), seed: 1, state: .cached)
            let photo = try fixture.scanned("DSC00046.ARW", orientation: 6, faces: [old])
            let newBox = Self.square(0.5)
            _ = try fixture.service(reader: { _ in 1 }).scan(
                stacks: [OrganizeStack(items: [photo])],
                analyzer: RecordingAnalyzer(results: [[Self.detection(Self.boxTurned(newBox, by: 1), seed: 3)]])
            )
            let faces = try fixture.store.faces(photoID: photo.primary.pathKey)
            let face = try XCTUnwrap(faces.first, "\(faces.count) rows")
            XCTAssertEqual(faces.count, 1)
            assertClose(face.box, newBox)
            XCTAssertNil(face.personID, "too few dogs to form a group; waits for the normal pass")
        }
    }

    /// The occluded-dog case: one dog with front, back and whole boxes.
    /// Nothing here may be read as a merge, and no box is dropped.
    func testADogWithPartBoxesIsNotAMerge() {
        let whole = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let plan = PetBoxRemap.plan(
            old: [(UUID(), whole)],
            new: [
                NormalizedFaceBox(x: 0.11, y: 0.1, width: 0.5, height: 0.5),
                NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.5),
                NormalizedFaceBox(x: 0.35, y: 0.1, width: 0.25, height: 0.5),
            ]
        )
        XCTAssertEqual(plan.matched.count, 1)
        XCTAssertEqual(plan.matched[0].new, 0)
        XCTAssertTrue(plan.merges.isEmpty)
        XCTAssertEqual(plan.unmatchedNew, [1, 2])
    }

    func testOverlappingBoxesOnOneDogAreNotAMerge() {
        // Two near-duplicate new boxes under an old box, neither close
        // enough to claim it outright, must not read as two dogs.
        let old = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        let plan = PetBoxRemap.plan(
            old: [(UUID(), old)],
            new: [
                NormalizedFaceBox(x: 0.12, y: 0.12, width: 0.4, height: 0.4),
                NormalizedFaceBox(x: 0.14, y: 0.14, width: 0.4, height: 0.4),
            ]
        )
        XCTAssertTrue(plan.merges.isEmpty)
    }

    func testAConfirmedOldBoxWinsItsOverlapAgainstASecondOldBox() {
        // Two old boxes on the same dog: the closer one takes it, the other
        // is reported unmatched instead of both claiming one new box.
        let near = NormalizedFaceBox(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let far = NormalizedFaceBox(x: 0.28, y: 0.2, width: 0.4, height: 0.4)
        let new = NormalizedFaceBox(x: 0.2, y: 0.2, width: 0.41, height: 0.4)
        let nearID = UUID()
        let farID = UUID()
        let plan = PetBoxRemap.plan(old: [(farID, far), (nearID, near)], new: [new])
        XCTAssertEqual(plan.matched.map(\.old), [nearID])
        XCTAssertEqual(plan.unmatchedOld, [farID])
    }

    func testANewBoxBelongsToAtMostOneMerge() {
        // Two overlapping old boxes both covering the same two dogs: the
        // larger takes them, so no new box can be inserted twice.
        let larger = NormalizedFaceBox(x: 0.05, y: 0.05, width: 0.9, height: 0.6)
        let smaller = NormalizedFaceBox(x: 0.08, y: 0.08, width: 0.86, height: 0.55)
        let largerID = UUID()
        let smallerID = UUID()
        let plan = PetBoxRemap.plan(
            old: [(smallerID, smaller), (largerID, larger)],
            new: [
                NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.35, height: 0.5),
                NormalizedFaceBox(x: 0.55, y: 0.1, width: 0.35, height: 0.5),
            ]
        )
        XCTAssertEqual(plan.merges, [PetBoxRemap.Merge(old: largerID, covered: [0, 1])])
        XCTAssertEqual(plan.unmatchedOld, [smallerID])
    }

    /// The other dog already has its own old box, but this one still spans
    /// both: the leftover dog is matched, not handed the old box's person.
    func testAMergeBoxWhoseOtherDogIsClaimedStillGoesThroughTheMatcher() {
        let span = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.8, height: 0.5)
        let own = NormalizedFaceBox(x: 0.55, y: 0.12, width: 0.34, height: 0.45)
        let spanID = UUID()
        let ownID = UUID()
        let plan = PetBoxRemap.plan(
            old: [(spanID, span), (ownID, own)],
            new: [
                NormalizedFaceBox(x: 0.12, y: 0.12, width: 0.36, height: 0.45),
                NormalizedFaceBox(x: 0.56, y: 0.12, width: 0.34, height: 0.45),
            ]
        )
        XCTAssertEqual(plan.merges, [PetBoxRemap.Merge(old: spanID, covered: [0])])
        XCTAssertEqual(plan.matched.map(\.old), [ownID])
        XCTAssertEqual(plan.matched.map(\.new), [1])
    }

    func testTwoDogsUnderOneBoxIsAMerge() {
        let wide = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.8, height: 0.5)
        let id = UUID()
        let plan = PetBoxRemap.plan(
            old: [(id, wide)],
            new: [
                NormalizedFaceBox(x: 0.12, y: 0.12, width: 0.36, height: 0.45),
                NormalizedFaceBox(x: 0.52, y: 0.12, width: 0.36, height: 0.45),
            ]
        )
        XCTAssertEqual(plan.merges, [PetBoxRemap.Merge(old: id, covered: [0, 1])])
        XCTAssertTrue(plan.matched.isEmpty)
        XCTAssertTrue(plan.unmatchedNew.isEmpty)
    }

    // MARK: - Migration and backup

    func testTheMigrationIsAdditive() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent(PetIndexDatabase.fileName)
            XCTAssertEqual(PetIndexDatabase.migrationIdentifiers.last, "v2-upright-detection")
            try PetIndexDatabase.migrator.migrate(try CatalogDatabase.writer(for: url), upTo: "v1-face-index-tables")

            let store = FaceIndexStore(url: url, engine: PetFaceEngine.identifier)
            let pet = try store.createPerson(name: "Rex", isRoster: true)
            let writer = try CatalogDatabase.writer(for: url)
            let before = try schemaColumns(writer)
            XCTAssertNil(before["pet_photo_orientation"])

            let backup = try XCTUnwrap(try PetIndexDatabase.migrate(url: url))
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

            let after = try schemaColumns(writer)
            for (table, columns) in before where table != "grdb_migrations" {
                XCTAssertEqual(after[table], columns, "\(table) changed")
            }
            XCTAssertNotNil(after["pet_photo_orientation"])
            XCTAssertNotNil(after["pet_index_state"])
            XCTAssertEqual(try store.person(pet.id)?.name, "Rex")
        }
    }

    func testTheRescanBacksTheIndexUpOnceBeforeItsFirstWrite() throws {
        try withFixture { fixture in
            let pet = try fixture.store.createPerson(name: "Rex", isRoster: true)
            let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
            let first = try fixture.scanned("DSC00050.ARW", orientation: 6, faces: [fixture.face(pet.id, box: box, seed: 1, state: .confirmed)])
            let second = try fixture.scanned("DSC00051.ARW", orientation: 6, faces: [], imageWidth: 640)
            let folder = fixture.root.appendingPathComponent("Backups-Test", isDirectory: true)

            var service = fixture.service(reader: { _ in 1 })
            service.uprightBackupFolder = folder
            _ = try service.scan(stacks: [OrganizeStack(items: [first])], analyzer: RecordingAnalyzer(results: [[Self.detection(box, seed: 2)]]))
            var copies = try backups(in: folder)
            XCTAssertEqual(copies.count, 1)
            XCTAssertEqual(try scalar("SELECT COUNT(*) FROM faces", url: folder.appendingPathComponent(copies[0])), "1")
            let copied = try scalar("SELECT COUNT(*) FROM pet_photo_orientation", url: folder.appendingPathComponent(copies[0]))
            XCTAssertEqual(copied, "0", "the copy is the index before the rescan's first write")
            XCTAssertEqual(try scalar("PRAGMA integrity_check", url: folder.appendingPathComponent(copies[0])), "ok")

            var later = fixture.service(reader: { _ in 1 })
            later.uprightBackupFolder = folder
            _ = try later.scan(stacks: [OrganizeStack(items: [second])], analyzer: RecordingAnalyzer(results: [[]]))
            copies = try backups(in: folder)
            XCTAssertEqual(copies.count, 1, "backed up once, not per pass")
        }
    }

    func testABackupThatFailsStopsTheRescanBeforeAnyWrite() throws {
        try withFixture { fixture in
            let photo = try fixture.scanned("DSC00052.ARW", orientation: 6, faces: [])
            let occupied = fixture.root.appendingPathComponent("not-a-folder")
            try Data("x".utf8).write(to: occupied)
            var service = fixture.service(reader: { _ in 1 })
            service.uprightBackupFolder = occupied
            XCTAssertThrowsError(try service.scan(stacks: [OrganizeStack(items: [photo])], analyzer: RecordingAnalyzer(results: [])))
            XCTAssertNil(try fixture.markerTurns(photo.primary.pathKey))
        }
    }

    // MARK: - Fixture

    private final class Fixture {
        let root: URL
        let store: FaceIndexStore
        init(root: URL, store: FaceIndexStore) {
            self.root = root
            self.store = store
        }

        func service(reader: (@Sendable (URL) -> Int?)? = nil, mode: FaceScanGrade = .high) -> FaceIndexService {
            var service = FaceIndexService(store: store, options: .pets(mode: mode))
            if let reader { service.cameraTurnsReader = reader }
            service.uprightBackupFolder = root.appendingPathComponent("Backups", isDirectory: true)
            return service
        }

        func face(_ personID: UUID?, box: NormalizedFaceBox, seed: Int, state: FaceState) -> FaceRecord {
            FaceRecord(
                photoID: "",
                personID: personID,
                box: box,
                detScore: 0.9,
                embedding: PetUprightDetectionTests.vector(seed),
                model: PetFaceEngine.identifier,
                state: state,
                scanGrade: .high
            )
        }

        /// A RAW on disk with a `face_photos` row and rows for `faces`, as a
        /// pre-fix scan would have left it — no marker.
        func scanned(
            _ name: String,
            orientation: Int?,
            faces: [FaceRecord],
            kind: OrganizeMediaKind = .raw,
            grade: FaceScanGrade = .high,
            imageWidth: Int = 600
        ) throws -> OrganizeItem {
            let url = root.appendingPathComponent(name)
            if let orientation {
                try writeOrientedRAW(url, orientation: orientation, width: imageWidth)
            } else {
                try writeLandscapeJPEG(url, width: imageWidth, height: 400)
            }
            let scannedItem = try item(url, kind: kind)
            let photo = FacePhotoRecord(
                pathKey: scannedItem.primary.pathKey,
                path: scannedItem.primary.path,
                fileName: scannedItem.primary.name,
                byteCount: scannedItem.primary.size,
                modifiedAt: scannedItem.primary.modifiedAt,
                scanGrade: grade,
                faceCount: faces.count,
                engine: PetFaceEngine.identifier
            )
            let rows = faces.map { face -> FaceRecord in
                var row = face
                row.photoID = photo.pathKey
                row.photoPath = photo.path
                return row
            }
            let writer = try CatalogDatabase.writer(for: store.url)
            try store.replaceFaces(photo: photo, faces: rows.filter { $0.state != .confirmed && $0.personID == nil })
            try writer.write { database in
                for row in rows where row.state == .confirmed || row.personID != nil {
                    try database.execute(
                        sql: """
                        INSERT INTO faces(id, photo_id, person_id, box_x, box_y, box_w, box_h, det_score, match_score, quality, face_px, embedding, model, state, scan_grade, crop, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                        """,
                        arguments: [
                            row.id.uuidString, row.photoID, row.personID?.uuidString,
                            row.box.x, row.box.y, row.box.width, row.box.height,
                            row.detScore, row.matchScore, row.quality, row.facePixels, row.embeddingData,
                            row.model, row.state.rawValue, row.scanGrade.rawValue, row.crop,
                        ]
                    )
                }
                try database.execute(
                    sql: "UPDATE face_photos SET face_count = (SELECT COUNT(*) FROM faces WHERE photo_id = ?) WHERE path_key = ?",
                    arguments: [photo.pathKey, photo.pathKey]
                )
            }
            try store.refreshFaceCounts()
            return scannedItem
        }

        /// Extra confirmed-free members of a group, each on its own photo.
        func seedGroupMembers(_ groupID: UUID, seed: Int, count: Int) throws {
            for index in 0..<count {
                _ = try scanned(
                    "MEMBER\(seed)-\(index).ARW",
                    orientation: 1,
                    faces: [face(groupID, box: PetUprightDetectionTests.square(0.05), seed: seed, state: .other)]
                )
            }
        }

        func markerTurns(_ key: String) throws -> Int? {
            try CatalogDatabase.writer(for: store.url).read { database in
                try Int.fetchOne(database, sql: "SELECT camera_turns FROM pet_photo_orientation WHERE path_key = ?", arguments: [key])
            }
        }

        func mark(_ key: String, turns: Int) throws {
            try CatalogDatabase.writer(for: store.url).write { database in
                try FaceIndexStore.writeUprightMarker(pathKey: key, cameraTurns: turns, database: database)
            }
        }

        func count(_ sql: String) throws -> Int {
            try CatalogDatabase.writer(for: store.url).read { database in
                try Int.fetchOne(database, sql: sql) ?? -1
            }
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent(PetIndexDatabase.fileName)
            let store = try PetIndexDatabase.open(url: url)
            try body(Fixture(root: root, store: store))
        }
    }

    /// Distinct unit vectors: same seed, same dog.
    static func vector(_ seed: Int) -> [Float] {
        var values = [Float](repeating: 0, count: 1024)
        for index in 0..<8 {
            values[(seed &* 17 &+ index * 7) % 1024] = Float(index + 1)
        }
        return FaceEmbeddingMath.l2Normalized(values)
    }

    static func detection(_ box: NormalizedFaceBox, seed: Int) -> AnalyzedFace {
        AnalyzedFace(box: box, detScore: 0.95, embedding: vector(seed), quality: 20, facePixels: 200, crop: Data([0xff, 0xd8]))
    }

    /// What the detector would report on the camera-turned picture for a
    /// dog at `stored`.
    static func boxTurned(_ stored: NormalizedFaceBox, by turns: Int) -> NormalizedFaceBox {
        FaceBoxProjection.box(ofTopLeftRect: FaceBoxProjection.rotatedTopLeftRect(
            FaceBoxProjection.topLeftRect(of: stored),
            quarterTurnsCW: turns
        ))
    }

    static func square(_ origin: Double) -> NormalizedFaceBox {
        NormalizedFaceBox(x: origin, y: origin, width: 0.2, height: 0.2)
    }

    private func assertClose(_ lhs: NormalizedFaceBox, _ rhs: NormalizedFaceBox, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: 1e-9, message, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: 1e-9, message, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: 1e-9, message, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: 1e-9, message, file: file, line: line)
    }

    private func backups(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".sqlite") }
    }

    private func hasMarkerTable(_ catalog: URL) throws -> Bool {
        try CatalogDatabase.writer(for: catalog).read { database in
            try String.fetchOne(database, sql: "SELECT name FROM sqlite_master WHERE name = 'pet_photo_orientation'") != nil
        }
    }

    private func schemaColumns(_ writer: any DatabaseWriter) throws -> [String: [String]] {
        try writer.read { database in
            let tables = try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            var result: [String: [String]] = [:]
            for table in tables {
                result[table] = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))").map { row in
                    let name: String = row["name"]
                    let type: String = row["type"]
                    return "\(name) \(type)"
                }
            }
            return result
        }
    }

    private func scalar(_ sql: String, url: URL) throws -> String? {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read { try String.fetchOne($0, sql: sql) }
    }
}

// MARK: - Test doubles and files

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    let turns: Int?
    let realFirst: Bool

    init(turns: Int?, realFirst: Bool = false) {
        self.turns = turns
        self.realFirst = realFirst
    }

    var count: Int { lock.withLock { paths.count } }
    var urls: [String] { lock.withLock { paths } }

    var read: @Sendable (URL) -> Int? {
        { [self] url in
            lock.withLock { paths.append(url.path) }
            return realFirst ? FaceImageDecoder.cameraQuarterTurns(for: url) : turns
        }
    }
}

/// Canned detections in call order, and a record of the pictures it saw.
private final class RecordingAnalyzer: FaceAnalyzing, @unchecked Sendable {
    let displayName = "RecordingAnalyzer"
    private let lock = NSLock()
    private var results: [[AnalyzedFace]]
    private let fails: Bool
    private let failsForWidth: Int?
    private let passthroughFaces: [AnalyzedFace]?
    private(set) var sizes: [(width: Int, height: Int)] = []
    private(set) var options: [FaceScanOptions] = []

    init(results: [[AnalyzedFace]], fails: Bool = false, failsForWidth: Int? = nil, passthroughFaces: [AnalyzedFace]? = nil) {
        self.results = results
        self.fails = fails
        self.failsForWidth = failsForWidth
        self.passthroughFaces = passthroughFaces
    }

    func analyze(_ image: CGImage, options: FaceScanOptions) throws -> [AnalyzedFace] {
        try lock.withLock {
            sizes.append((image.width, image.height))
            self.options.append(options)
            if fails || failsForWidth == image.height { // a turned 640-wide preview is 640 tall
                throw FaceIndexError.engineFailed("stub failure")
            }
            if let passthroughFaces { return passthroughFaces }
            return results.isEmpty ? [] : results.removeFirst()
        }
    }
}

private func item(_ url: URL, kind: OrganizeMediaKind = .raw) throws -> OrganizeItem {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let modified = attributes[.modificationDate] as? Date ?? Date()
    return OrganizeItem(
        primary: OrganizeFile(path: url.path, size: attributes[.size] as? Int64 ?? 0, modifiedAt: modified),
        kind: kind,
        captureDate: modified,
        hasCameraDate: false
    )
}

/// A TIFF-shaped RAW: IFD0 with an orientation tag and one embedded JPEG.
private func writeOrientedRAW(_ url: URL, orientation: Int?, width: Int = 600) throws {
    let jpeg = try landscapeJPEG(width: width, height: 400)
    var entries: [(tag: UInt16, type: UInt16, value: UInt32)] = []
    if let orientation { entries.append((0x0112, 3, UInt32(orientation))) }
    entries.append((0x0201, 4, UInt32(512)))
    entries.append((0x0202, 4, UInt32(jpeg.count)))
    var data = Data(count: 512 + jpeg.count)
    data[0] = 0x49
    data[1] = 0x49
    putUInt16(&data, 2, 42)
    putUInt32(&data, 4, 8)
    putUInt16(&data, 8, UInt16(entries.count))
    for (index, entry) in entries.enumerated() {
        let base = 10 + index * 12
        putUInt16(&data, base, entry.tag)
        putUInt16(&data, base + 2, entry.type)
        putUInt32(&data, base + 4, 1)
        putUInt32(&data, base + 8, entry.value)
    }
    data.replaceSubrange(512..<(512 + jpeg.count), with: jpeg)
    try data.write(to: url)
}

private func writeLandscapeJPEG(_ url: URL, width: Int, height: Int) throws {
    try landscapeJPEG(width: width, height: height).write(to: url)
}

private func landscapeJPEG(width: Int, height: Int) throws -> Data {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw XCTSkip("no bitmap") }
    context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    return try XCTUnwrap(FaceImageEncoding.jpegData(image))
}

private func putUInt16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
    data[offset] = UInt8(value & 0xff)
    data[offset + 1] = UInt8(value >> 8)
}

private func putUInt32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
    for shift in 0..<4 {
        data[offset + shift] = UInt8((value >> (shift * 8)) & 0xff)
    }
}
