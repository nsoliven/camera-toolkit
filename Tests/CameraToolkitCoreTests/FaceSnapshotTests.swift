@testable import CameraToolkitCore
import Foundation
import XCTest

/// Face review actions are undoable through row snapshots: what an action
/// could change is captured first, and swapping the snapshot back writes it in
/// one transaction — and hands back the rows it replaced, so Redo is the
/// same call. Confirmed faces come back confirmed, junked rows come back
/// with their embeddings and crops byte for byte, a merge un-merges.
final class FaceSnapshotTests: XCTestCase {
    private struct World {
        var store: FaceIndexStore
        var catalog: URL
        var roster: FacePerson
        var group: FacePerson
        var other: FacePerson
        var faces: [FaceRecord]
        /// The group's faces: two unconfirmed, one confirmed.
        var groupFaces: [FaceRecord]

        var everyPerson: Set<UUID> { [roster.id, group.id, other.id] }
        var everyFace: Set<UUID> { Set(faces.map(\.id)) }

        /// Every row that can change, in one comparable value.
        func dump() throws -> FaceSnapshot {
            var snapshot = try store.captureSnapshot(expandingPeople: Set(try store.rosterPeople().map(\.id) + store.otherGroups().map(\.id)), faces: everyFace)
            snapshot.personIDs.sort { $0.uuidString < $1.uuidString }
            return snapshot
        }
    }

    private func withWorld(_ body: (World) throws -> Void) throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            var configuration = testConfiguration(root: root)
            configuration.catalogDatabasePath = catalog.path
            _ = try CatalogStore(url: catalog).bootstrap(configuration: configuration, createBackup: false, createLibraryFolders: false)
            let store = FaceIndexStore(url: catalog)
            let roster = try store.createPerson(name: "Dad", isRoster: true)
            let group = try store.createPerson(name: "Person 1", isRoster: false)
            let other = try store.createPerson(name: "Person 2", isRoster: false)

            let photo = photoRecord("ONE.ARW")
            let rosterFace = face(photo, x: 0.0, seed: 1, state: .confirmed, person: roster.id, crop: Data([1, 2, 3, 4]))
            let confirmed = face(photo, x: 0.2, seed: 2, state: .confirmed, person: group.id, crop: Data(repeating: 7, count: 512))
            let unconfirmed1 = face(photo, x: 0.4, seed: 3, state: .other, person: group.id, crop: Data(repeating: 8, count: 512))
            let unconfirmed2 = face(photo, x: 0.6, seed: 3, state: .other, person: group.id, crop: nil)
            let stray = face(photo, x: 0.8, seed: 40, state: .other, person: other.id, crop: Data([9]))
            let all = [rosterFace, confirmed, unconfirmed1, unconfirmed2, stray]
            try store.replaceFaces(photo: photo, faces: all)
            try store.addTemplate(personID: roster.id, faceID: rosterFace.id)
            try store.addTemplate(personID: group.id, faceID: confirmed.id)
            try store.recordRejection(personID: roster.id, faceID: stray.id)
            try store.refreshFaceCounts()
            try body(World(
                store: store, catalog: catalog, roster: roster, group: group, other: other,
                faces: all, groupFaces: [confirmed, unconfirmed1, unconfirmed2]
            ))
        }
    }

    /// Runs `action`, swaps the snapshot back (Undo) and again (Redo), and
    /// proves the rows are exactly what they were, and then exactly what the
    /// action left.
    private func assertUndoRedo(
        _ world: World,
        expandingPeople: Set<UUID> = [],
        people: Set<UUID> = [],
        faces: Set<UUID> = [],
        _ action: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let before = try world.dump()
        let snapshot = try world.store.captureSnapshot(expandingPeople: expandingPeople, people: people, faces: faces)
        try action()
        let after = try world.dump()
        XCTAssertNotEqual(before, after, "the action changed something", file: file, line: line)

        let redo = try world.store.swapSnapshot(snapshot)
        XCTAssertEqual(try world.dump(), before, "Undo puts every row back exactly", file: file, line: line)
        _ = try world.store.swapSnapshot(redo)
        XCTAssertEqual(try world.dump(), after, "Redo makes the action's rows again", file: file, line: line)
        _ = try world.store.swapSnapshot(snapshot)
        XCTAssertEqual(try world.dump(), before, "and Undo again", file: file, line: line)
    }

    // MARK: - The actions

    func testJunkingAGroupIsUndoneWithItsConfirmedFaceAndItsCropsAndRedone() throws {
        try withWorld { world in
            try assertUndoRedo(world, expandingPeople: [world.group.id]) {
                try world.store.deletePersonAndFaces(world.group.id)
                try world.store.refreshFaceCounts()
            }
            // The unconfirmed faces are gone after the junk, and back after Undo.
            try world.store.deletePersonAndFaces(world.group.id)
            XCTAssertNil(try world.store.person(world.group.id))
        }
    }

    func testJunkedGroupComesBackWithConfirmedStateAndBlobsByteForByte() throws {
        try withWorld { world in
            let snapshot = try world.store.captureSnapshot(expandingPeople: [world.group.id])
            let before = try world.store.faces(personID: world.group.id)
            try world.store.deletePersonAndFaces(world.group.id)
            XCTAssertNil(try world.store.person(world.group.id))
            XCTAssertNil(try world.store.face(id: world.groupFaces[1].id), "the unconfirmed face row is gone")
            XCTAssertNotNil(try world.store.face(id: world.groupFaces[0].id), "a confirmed face is never deleted by a junk")

            try world.store.swapSnapshot(snapshot)
            let back = try world.store.faces(personID: world.group.id)
            XCTAssertEqual(Set(back.map(\.id)), Set(before.map(\.id)))
            XCTAssertEqual(back.first { $0.id == world.groupFaces[0].id }?.state, .confirmed)
            XCTAssertEqual(back.first { $0.id == world.groupFaces[1].id }?.embedding, world.groupFaces[1].embedding)
            XCTAssertEqual(back.first { $0.id == world.groupFaces[1].id }?.crop, Data(repeating: 8, count: 512))
            XCTAssertEqual(try world.store.person(world.group.id)?.faceCount, 3)
        }
    }

    func testJunkingOneFaceIsUndone() throws {
        try withWorld { world in
            try assertUndoRedo(world, faces: [world.groupFaces[1].id]) {
                try world.store.deleteFaces([world.groupFaces[1].id])
                try world.store.refreshFaceCounts()
            }
        }
    }

    func testMergingAPersonIsUndoneAndTheSourceRowComesBackWithItsTemplates() throws {
        try withWorld { world in
            try assertUndoRedo(world, expandingPeople: [world.group.id], people: [world.roster.id]) {
                try world.store.mergePerson(world.group.id, into: world.roster.id)
                try world.store.refreshFaceCounts()
            }
            let merged = try world.store.captureSnapshot(expandingPeople: [world.group.id], people: [world.roster.id])
            try world.store.mergePerson(world.group.id, into: world.roster.id)
            XCTAssertNil(try world.store.person(world.group.id))
            try world.store.swapSnapshot(merged)
            XCTAssertNotNil(try world.store.person(world.group.id), "the merged person is a person again")
            XCTAssertEqual(try world.store.faces(personID: world.group.id).count, 3)
            XCTAssertEqual(try world.store.faces(personID: world.roster.id).count, 1, "Dad has his own face again and nothing else")
        }
    }

    func testRejectingAFaceIsUndoneAndItsVetoGoes() throws {
        try withWorld { world in
            let target = world.groupFaces[1]
            try assertUndoRedo(world, faces: [target.id]) {
                try FaceIndexService(catalogURL: world.catalog).reject([target.id])
            }
        }
    }

    func testConfirmingATaggingAndApprovingAreUndone() throws {
        try withWorld { world in
            let unconfirmed = world.groupFaces[1]
            try assertUndoRedo(world, faces: [unconfirmed.id]) {
                try world.store.assignFace(unconfirmed.id, to: world.group.id, state: .other, score: 0.9)
                try world.store.confirmFace(unconfirmed.id)
                try world.store.refreshFaceCounts()
            }
            try assertUndoRedo(world, people: [world.roster.id], faces: [world.faces[4].id]) {
                try world.store.assignFace(world.faces[4].id, to: world.roster.id, state: .confirmed, score: nil)
                try world.store.addTemplate(personID: world.roster.id, faceID: world.faces[4].id)
                try world.store.refreshFaceCounts()
            }
            try assertUndoRedo(world, expandingPeople: [world.other.id]) {
                try world.store.promoteGroup(world.other.id, name: "Mum", templateCap: 5)
            }
        }
    }

    func testRenamingDemotingPinningAndCoversAreUndone() throws {
        try withWorld { world in
            try assertUndoRedo(world, people: [world.roster.id]) {
                try world.store.renamePerson(world.roster.id, name: "Father")
            }
            try assertUndoRedo(world, expandingPeople: [world.roster.id]) {
                try world.store.demoteFromRoster(world.roster.id)
            }
            try assertUndoRedo(world, people: [world.group.id]) {
                try world.store.addTemplate(personID: world.group.id, faceID: world.groupFaces[1].id)
            }
            try assertUndoRedo(world, people: [world.group.id]) {
                XCTAssertTrue(try world.store.setCoverFace(personID: world.group.id, faceID: world.groupFaces[1].id))
            }
        }
    }

    func testANewPersonIsRemovedByUndoAndReturnsOnRedo() throws {
        try withWorld { world in
            let before = try world.dump()
            let person = try world.store.createPerson(name: "Nan", isRoster: true)
            // The row did not exist when the action started: a snapshot that
            // names the person and holds no row for it says "absent".
            let absent = FaceSnapshot(personIDs: [person.id])
            let redo = try world.store.swapSnapshot(absent)
            XCTAssertNil(try world.store.person(person.id))
            XCTAssertEqual(try world.dump(), before)
            _ = try world.store.swapSnapshot(redo)
            XCTAssertEqual(try world.store.person(person.id)?.name, "Nan")
        }
    }

    func testASnapshotNeverTouchesFacesOrPeopleItDoesNotName() throws {
        try withWorld { world in
            let untouched = try world.store.captureSnapshot(expandingPeople: [world.roster.id])
            let snapshot = try world.store.captureSnapshot(faces: [world.groupFaces[1].id])
            try world.store.deleteFaces([world.groupFaces[1].id])
            try world.store.swapSnapshot(snapshot)
            // Dad and his face were not part of it.
            XCTAssertEqual(try world.store.captureSnapshot(expandingPeople: [world.roster.id]), untouched)
        }
    }

    func testASnapshotThatMentionsMoreRowsThanASQLiteStatementHoldsStillSwaps() throws {
        try withWorld { world in
            let photo = photoRecord("MANY.ARW")
            let crowd = (0..<1_100).map { index in
                face(photo, x: Double(index % 20) * 0.04, seed: UInt64(index), state: .other, person: world.group.id, crop: nil, y: Double(index / 20) * 0.01)
            }
            try world.store.replaceFaces(photo: photo, faces: crowd)
            try world.store.refreshFaceCounts()
            let snapshot = try world.store.captureSnapshot(expandingPeople: [world.group.id])
            XCTAssertGreaterThan(snapshot.faces.count, 1_000)
            try world.store.deletePersonAndFaces(world.group.id)
            try world.store.swapSnapshot(snapshot)
            XCTAssertEqual(try world.store.person(world.group.id)?.faceCount, 1_103)
        }
    }

    func testASnapshotSurvivesJSONSoItCanBeKept() throws {
        try withWorld { world in
            let snapshot = try world.store.captureSnapshot(expandingPeople: [world.group.id])
            let decoded = try JSONDecoder().decode(FaceSnapshot.self, from: JSONEncoder().encode(snapshot))
            XCTAssertEqual(decoded, snapshot, "embeddings and crops included")
            XCTAssertGreaterThan(snapshot.byteCount, 1_000)
        }
    }

    // MARK: - Fixtures

    private func photoRecord(_ name: String) -> FacePhotoRecord {
        let path = "/tmp/face-snapshots/\(name)"
        return FacePhotoRecord(
            pathKey: EventStorageLocations.pathKey(path), path: path, fileName: name,
            byteCount: 1_024, modifiedAt: Date(timeIntervalSince1970: 1_752_000_000)
        )
    }

    private func face(
        _ photo: FacePhotoRecord,
        x: Double,
        seed: UInt64,
        state: FaceState,
        person: UUID?,
        crop: Data?,
        y: Double = 0.1
    ) -> FaceRecord {
        var record = FaceRecord(
            photoID: photo.pathKey,
            personID: person,
            box: NormalizedFaceBox(x: x, y: y, width: 0.05, height: 0.06),
            detScore: 0.9,
            embedding: embedding(seed: seed),
            state: state,
            photoPath: photo.path
        )
        record.crop = crop
        return record
    }

    /// A deterministic unit vector: the same seed makes the same face.
    private func embedding(seed: UInt64) -> [Float] {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1
        let vector = (0..<512).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) * 2 - 1
        }
        return FaceEmbeddingMath.l2Normalized(vector)
    }
}
