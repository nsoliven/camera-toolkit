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

            for table in ["face_photos", "people", "faces", "face_templates"] {
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

            // Re-running bootstrap is a no-op.
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            XCTAssertEqual(scalarString("PRAGMA integrity_check", database: catalog), "ok")
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
            // plus a disjoint new one. The confirmed face must survive
            // untouched and the overlapping re-detection must not duplicate it.
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

            var report = try service.scan(stacks: [OrganizeStack(items: [item])], embedder: StubEmbedder())
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(report.photosSkipped, 0)
            XCTAssertEqual(report.facesDetected, 0)

            // Same file identity + grade covers the mode → skipped.
            report = try service.scan(stacks: [OrganizeStack(items: [try organizeItem(forFileAt: jpegURL)])], embedder: StubEmbedder())
            XCTAssertEqual(report.photosProcessed, 0)
            XCTAssertEqual(report.photosSkipped, 1)

            // A changed file (new bytes, new mtime) is not "already scanned".
            try writeJPEG(jpegURL, seed: 2)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(3_600)],
                ofItemAtPath: jpegURL.path
            )
            report = try service.scan(stacks: [OrganizeStack(items: [try organizeItem(forFileAt: jpegURL)])], embedder: StubEmbedder())
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(report.photosSkipped, 0)

            // Missing embedder → the scan refuses rather than guessing.
            XCTAssertThrowsError(try service.scan(stacks: [OrganizeStack(items: [item])], embedder: nil)) { error in
                XCTAssertEqual(error as? FaceIndexError, .modelNotInstalled(FaceModelCatalog.modelFileName))
            }
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
                embedder: StubEmbedder()
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

            try FaceIndexService(catalogURL: catalog).rematchRoster()

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

            try FaceIndexService(catalogURL: catalog).rematchRoster()

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

    func testPromoteGroupConfirmsFacesAndBuildsTemplates() throws {
        try withFaceStore { store, catalog in
            // Two faces of the same cluster on different photos.
            let p1 = photoRecord("P1.JPG")
            let p2 = photoRecord("P2.JPG")
            let f1 = faceRecord(p1, embedding: testEmbedding(seed: 31))
            let f2 = faceRecord(p2, detScore: 0.8, embedding: testEmbedding(seed: 31, noise: 0.1))
            try store.replaceFaces(photo: p1, faces: [f1])
            try store.replaceFaces(photo: p2, faces: [f2])
            try FaceIndexService(catalogURL: catalog).rematchRoster()

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
            try FaceIndexService(catalogURL: catalog).rematchRoster()
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

    func testRejectFaceRegroupsToOthers() throws {
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

            // "Not this person" sends the face back to the Other groups.
            try service.regroup([wrongMatch.id])
            let regrouped = try store.face(id: wrongMatch.id)
            XCTAssertEqual(regrouped?.state, .other)
            let group = try XCTUnwrap(regrouped?.personID.flatMap { try? store.person($0) })
            XCTAssertFalse(group.isRoster)
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
        XCTAssertEqual(low.detectorKind, .vision)
        XCTAssertEqual(low.minimumFacePixels, 64)
        XCTAssertEqual(low.detectorScales, [640])
        XCTAssertNil(low.videoFrameStride)
        XCTAssertFalse(low.scansVideo)

        let med = FaceScanOptions(mode: .med)
        XCTAssertEqual(med.detectorKind, .scrfd)
        XCTAssertEqual(med.minimumFacePixels, 40)
        XCTAssertEqual(med.detectorScales, [640])
        XCTAssertEqual(med.videoFrameStride, 30)
        XCTAssertTrue(med.scansVideo)

        let high = FaceScanOptions(mode: .high)
        XCTAssertEqual(high.detectorKind, .scrfd)
        XCTAssertEqual(high.minimumFacePixels, 30)
        XCTAssertEqual(high.detectorScales, [640, 960])
        XCTAssertEqual(high.videoFrameStride, 1)
        XCTAssertTrue(high.scansVideo)

        // FAST pins the Mac; off is the quiet two-wide pass.
        XCTAssertGreaterThan(FaceScanOptions(mode: .med, fast: true).concurrency, 2)
        XCTAssertEqual(FaceScanOptions(mode: .med, fast: false).concurrency, 2)

        // XHIGH runs the HIGH pipeline and stamps high — not itself.
        XCTAssertEqual(FaceScanOptions.implementedGrade, .high)
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
            let detector = StubDetector(detections: [])

            // LOW stamps low; a repeat LOW pass skips.
            var service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .low))
            var report = try service.scan(items: [item], embedder: StubEmbedder(), detector: detector)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade, .low)

            report = try service.scan(items: [item], embedder: StubEmbedder(), detector: detector)
            XCTAssertEqual(report.photosSkipped, 1)
            XCTAssertEqual(report.photosProcessed, 0)

            // MED re-runs (low does not cover med), then stamps med.
            service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .med))
            report = try service.scan(items: [item], embedder: StubEmbedder(), detector: detector)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade, .med)

            report = try service.scan(items: [item], embedder: StubEmbedder(), detector: detector)
            XCTAssertEqual(report.photosSkipped, 1)

            // HIGH re-runs; afterwards a MED request is covered and skipped.
            service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .high))
            report = try service.scan(items: [item], embedder: StubEmbedder(), detector: detector)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade, .high)

            service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .med))
            report = try service.scan(items: [item], embedder: StubEmbedder(), detector: detector)
            XCTAssertEqual(report.photosSkipped, 1)

            // An XHIGH request runs the HIGH pipeline and stamps .high — so
            // it is not skipped on the next XHIGH request, and never marks
            // the photo as scanned at a grade nothing implemented.
            service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .xhigh))
            report = try service.scan(items: [item], embedder: StubEmbedder(), detector: detector)
            XCTAssertEqual(report.photosSkipped, 0)
            XCTAssertEqual(try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade, .high)
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
            let report = try service.scan(items: [photoItem, videoItem], embedder: StubEmbedder())
            XCTAssertEqual(report.photosConsidered, 1)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(report.videoFramesRead, 0)
            XCTAssertNil(try FaceIndexStore(url: catalog).photos(pathKeys: [videoItem.primary.pathKey])[videoItem.primary.pathKey])
        }
    }

    func testMedModeRequiresDetectorAndFreezesConfirmed() throws {
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

            // MED without a detector refuses — it must not silently fall
            // back to the LOW Vision path.
            let medService = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .med))
            XCTAssertThrowsError(try medService.scan(items: [item], embedder: StubEmbedder())) { error in
                XCTAssertEqual(error as? FaceIndexError, .detectorNotInstalled(FaceModelCatalog.detectorFileName))
            }

            // First pass finds one face; the owner confirms it as Dad.
            let box = CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.2)
            var detector = StubDetector(detections: [
                DetectedFace(boundingBox: box, confidence: 0.95, landmarks: nil),
            ])
            var report = try medService.scan(items: [item], embedder: StubEmbedder(), detector: detector)
            XCTAssertEqual(report.facesDetected, 1)

            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let detected = try XCTUnwrap(store.faces(photoID: item.primary.pathKey).first)
            try store.assignFace(detected.id, to: dad.id, state: .proposed, score: 0.9)
            try store.confirmFace(detected.id)

            // HIGH re-detects the same spot (overlapping box) plus a new
            // face elsewhere. The confirmed face is untouched, the overlap
            // is deduplicated, and the photo is now stamped high.
            detector = StubDetector(detections: [
                DetectedFace(boundingBox: box.offsetBy(dx: 0.01, dy: 0.01), confidence: 0.9, landmarks: nil),
                DetectedFace(boundingBox: CGRect(x: 0.6, y: 0.6, width: 0.15, height: 0.15), confidence: 0.8, landmarks: nil),
            ])
            let highService = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .high))
            report = try highService.scan(items: [item], embedder: StubEmbedder(), detector: detector)
            XCTAssertEqual(report.photosProcessed, 1)

            let faces = try store.faces(photoID: item.primary.pathKey)
            XCTAssertEqual(faces.count, 2)
            let confirmed = try XCTUnwrap(store.face(id: detected.id))
            XCTAssertEqual(confirmed.state, .confirmed)
            XCTAssertEqual(confirmed.personID, dad.id)
            XCTAssertEqual(faces.filter { $0.state != .confirmed }.count, 1)
            XCTAssertEqual(
                try store.photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade,
                .high
            )
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
            let detector = StubDetector(detections: [
                DetectedFace(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2), confidence: 0.9, landmarks: nil),
            ])
            let service = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .med))

            var report = try service.scan(
                items: items, embedder: StubEmbedder(), detector: detector, stacks: stacks
            )
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
            report = try service.scan(
                items: items, embedder: StubEmbedder(), detector: detector, stacks: stacks
            )
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
            let detector = StubDetector(detections: [
                DetectedFace(boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2), confidence: 0.9, landmarks: nil),
            ])

            // Without a scan result's stacks every still is scanned — the
            // Phase 1 behavior bare item lists keep.
            let lowService = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .low))
            var report = try lowService.scan(items: items, embedder: StubEmbedder(), detector: detector)
            XCTAssertEqual(report.photosProcessed, 4)
            XCTAssertEqual(report.photosBurstCovered, 0)
            for item in items {
                XCTAssertEqual(try store.faces(photoID: item.primary.pathKey).count, 1)
            }

            // MED with burst grouping: 4 frames sample to {0, 2, 3}; index 1
            // is covered and keeps the face LOW found on it.
            let stacks = [OrganizeStack(items: items)]
            let medService = FaceIndexService(catalogURL: catalog, options: FaceScanOptions(mode: .med))
            report = try medService.scan(items: items, embedder: StubEmbedder(), detector: detector, stacks: stacks)
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

    // MARK: - SCRFD decode math

    func testSCRFDDecodeAnchorsAndNMS() throws {
        // A 640 tensor: stride 8 → 80²·2 anchors, 16 → 3200, 32 → 800.
        let anchors8 = 80 * 80 * 2
        let anchors16 = 40 * 40 * 2
        let anchors32 = 20 * 20 * 2

        var scores8 = [Float](repeating: 0.01, count: anchors8)
        var boxes8 = [Float](repeating: 0, count: anchors8 * 4)
        var kpss8 = [Float](repeating: 0, count: anchors8 * 10)
        // One hot anchor at cell (row 10, col 20), k = 0.
        let anchor = (10 * 80 + 20) * 2
        scores8[anchor] = 0.9
        // Distances l=t=r=b=5 → box centered on (20.5·8, 10.5·8) = (164,84).
        for offset in 0..<4 { boxes8[anchor * 4 + offset] = 5 }

        let candidates = SCRFDDetector.decodeArrays(
            scores: [scores8, [Float](repeating: 0.01, count: anchors16), [Float](repeating: 0.01, count: anchors32)],
            boxes: [boxes8, [Float](repeating: 0, count: anchors16 * 4), [Float](repeating: 0, count: anchors32 * 4)],
            kpss: [kpss8, [Float](repeating: 0, count: anchors16 * 10), [Float](repeating: 0, count: anchors32 * 10)],
            tensorSide: 640,
            scoreThreshold: 0.5
        )
        XCTAssertEqual(candidates.count, 1)
        let hit = try XCTUnwrap(candidates.first)
        XCTAssertEqual(Double(hit.box.midX), 164, accuracy: 0.01)
        XCTAssertEqual(Double(hit.box.midY), 84, accuracy: 0.01)
        XCTAssertEqual(Double(hit.box.width), 80, accuracy: 0.01)
        // Zero kps offsets land the five landmarks on the anchor center.
        XCTAssertEqual(hit.landmarks.count, 5)
        XCTAssertEqual(Double(hit.landmarks[0].x), 164, accuracy: 0.01)

        // Wrong anchor counts → the outputs are ignored, not misdecoded.
        XCTAssertEqual(
            SCRFDDetector.decodeArrays(
                scores: [[Float](repeating: 0.9, count: 7)],
                boxes: [[Float](repeating: 0, count: 28)],
                kpss: [],
                tensorSide: 640,
                scoreThreshold: 0.5
            ).count,
            0
        )

        // NMS keeps the higher score of two overlapping candidates and all
        // disjoint ones.
        let overlapping = SCRFDDetector.Candidate(
            score: 0.9,
            box: CGRect(x: 100, y: 100, width: 80, height: 80),
            landmarks: []
        )
        let weaker = SCRFDDetector.Candidate(
            score: 0.7,
            box: CGRect(x: 105, y: 105, width: 80, height: 80),
            landmarks: []
        )
        let apart = SCRFDDetector.Candidate(
            score: 0.6,
            box: CGRect(x: 400, y: 400, width: 60, height: 60),
            landmarks: []
        )
        let kept = SCRFDDetector.nonMaxSuppressed([weaker, apart, overlapping], iouThreshold: 0.4)
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(kept.contains { $0.score == 0.9 })
        XCTAssertTrue(kept.contains { $0.score == 0.6 })
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
        // A clip shorter than the stride still contributes one mid frame.
        XCTAssertEqual(
            FaceVideoSampler.sampleTimes(duration: 10, stride: 30, maxFrames: 12),
            [5]
        )
        // The cap is respected on long clips.
        XCTAssertEqual(FaceVideoSampler.sampleTimes(duration: 600, stride: 30, maxFrames: 12).count, 12)
        XCTAssertTrue(FaceVideoSampler.sampleTimes(duration: 0, stride: 30, maxFrames: 12).isEmpty)
    }

    // MARK: - CoreML round-trip (skipped when the model is not installed)

    func testArcFaceEmbedderRoundTrip() async throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        guard FaceModelCatalog.isModelInstalled(applicationSupport: support) else {
            throw XCTSkip("Face model not installed — run scripts/convert-arcface.sh once")
        }

        let embedder = try await FaceModelCatalog.loadEmbedder(applicationSupport: support)
        let embedder2 = try XCTUnwrap(embedder)
        let imageA = try makeFaceTestImage(seed: 1)
        let imageB = try makeFaceTestImage(seed: 2)

        let first = try embedder2.embed(imageA)
        let repeatA = try embedder2.embed(imageA)
        let other = try embedder2.embed(imageB)

        XCTAssertEqual(first.count, 512)
        var norm: Float = 0
        for value in first { norm += value * value }
        XCTAssertEqual(norm, 1, accuracy: 0.01)
        XCTAssertGreaterThan(FaceEmbeddingMath.cosine(first, repeatA), 0.999)
        XCTAssertLessThan(FaceEmbeddingMath.cosine(first, other), 0.999)
    }

    /// The MED/HIGH detector, exercised end to end when the package is
    /// installed: loads, accepts the letterbox input, and decodes a real
    /// prediction. A synthetic gradient likely yields zero faces — a valid
    /// run — so the assertions are about the plumbing, not recall.
    func testSCRFDDetectorLoadsAndRuns() async throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        guard FaceModelCatalog.isDetectorInstalled(applicationSupport: support) else {
            throw XCTSkip("Face detector not installed — run scripts/convert-scrfd.sh once")
        }

        let loaded = try await FaceModelCatalog.loadDetector(applicationSupport: support)
        let detector = try XCTUnwrap(loaded)
        XCTAssertTrue(detector.nativeInputSizes.contains(640))

        let image = try makeFaceTestImage(seed: 9)
        let detections = detector.detect(
            in: image,
            imagePixelSize: CGSize(width: image.width, height: image.height),
            options: FaceScanOptions(mode: .med)
        )
        for detection in detections {
            XCTAssertGreaterThanOrEqual(detection.confidence, 0.5)
            XCTAssertEqual(detection.landmarks?.points.count ?? 5, 5)
        }

        // The full service path with the real detector on a face-free image.
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: faceTestConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            let jpegURL = root.appendingPathComponent("card/DSC00099.JPG")
            try writeJPEG(jpegURL, seed: 8)
            let item = try organizeItem(forFileAt: jpegURL)
            let report = try FaceIndexService(
                catalogURL: catalog,
                options: FaceScanOptions(mode: .med)
            ).scan(items: [item], embedder: StubEmbedder(), detector: detector)
            XCTAssertEqual(report.photosProcessed, 1)
            XCTAssertEqual(
                try FaceIndexStore(url: catalog).photos(pathKeys: [item.primary.pathKey])[item.primary.pathKey]?.scanGrade,
                .med
            )
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
        personID: UUID? = nil
    ) -> FaceRecord {
        FaceRecord(
            photoID: photo.pathKey,
            personID: personID,
            box: box,
            detScore: detScore,
            embedding: embedding,
            state: state,
            photoPath: photo.path
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

    /// A deterministic 112×112 bitmap for the CoreML round-trip test.
    private func makeFaceTestImage(seed: UInt8) throws -> CGImage {
        let size = FaceAligner.outputSize
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
        for index in 0..<16 {
            let shade = CGFloat((Int(seed) * 17 + index * 13) % 255) / 255
            context.setFillColor(CGColor(red: shade, green: 1 - shade, blue: shade / 2, alpha: 1))
            context.fill(CGRect(x: (index % 4) * size / 4, y: (index / 4) * size / 4, width: size / 4, height: size / 4))
        }
        return try XCTUnwrap(context.makeImage())
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

/// Never actually called — scans in these tests run on face-free images.
private struct StubEmbedder: FaceEmbeddingProviding {
    func embed(_ image: CGImage) throws -> [Float] {
        FaceEmbeddingMath.l2Normalized([Float](repeating: 1, count: 512))
    }
}

/// Canned detections so service tests exercise the real scan path without
/// a detector model on disk.
private struct StubDetector: FaceDetecting {
    var detections: [DetectedFace]

    func detect(in image: CGImage, imagePixelSize: CGSize, options: FaceScanOptions) -> [DetectedFace] {
        detections
    }
}
