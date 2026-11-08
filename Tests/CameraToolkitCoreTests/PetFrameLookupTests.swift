import Foundation
import GRDB
@testable import CameraToolkitCore
import XCTest

/// The organizer preview's dog boxes: read from the pet index by file
/// identity, never creating, migrating, or writing it, and never reading
/// the catalog.
final class PetFrameLookupTests: XCTestCase {
    private let modified = Date(timeIntervalSince1970: 1_752_000_000)

    private func file(_ folder: URL, _ name: String = "DSC00001.ARW", size: Int64 = 2_048) -> OrganizeFile {
        OrganizeFile(path: folder.appendingPathComponent(name).path, size: size, modifiedAt: modified)
    }

    private func photo(for file: OrganizeFile) -> FacePhotoRecord {
        FacePhotoRecord(
            pathKey: file.pathKey,
            path: file.path,
            fileName: file.name,
            byteCount: file.size,
            modifiedAt: file.modifiedAt,
            scanGrade: .high,
            engine: PetFaceEngine.identifier
        )
    }

    private func dog(
        on photo: FacePhotoRecord,
        x: Double,
        state: FaceState = .cached,
        petID: UUID? = nil,
        score: Double? = nil
    ) -> FaceRecord {
        FaceRecord(
            photoID: photo.pathKey,
            personID: petID,
            box: NormalizedFaceBox(x: x, y: 0.2, width: 0.2, height: 0.2),
            detScore: 0.9,
            matchScore: score,
            model: PetFaceEngine.identifier,
            state: state,
            photoPath: photo.path
        )
    }

    func testAMissingPetIndexDrawsNothingAndIsNotCreated() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent(PetIndexDatabase.fileName)
            XCTAssertEqual(PetFrameLookup.boxes(petIndexURL: url, file: file(root)), .empty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testAnEmptyPetIndexDrawsNothing() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent(PetIndexDatabase.fileName)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
            defer { CatalogDatabase.checkpointAndCloseAll() }
            XCTAssertEqual(PetFrameLookup.boxes(petIndexURL: url, file: file(root)), .empty)
            XCTAssertEqual(try Data(contentsOf: url), Data(), "an empty file is never opened")

            // A migrated index with no rows draws nothing either.
            let fresh = root.appendingPathComponent("fresh").appendingPathComponent(PetIndexDatabase.fileName)
            try PetIndexDatabase.migrate(url: fresh)
            XCTAssertEqual(PetFrameLookup.boxes(petIndexURL: fresh, file: file(root)), .empty)
        }
    }

    /// Named, suggested, and unnamed dogs on the frame come back with the
    /// names their chips wear and the approved pets the picker lists;
    /// another photo's dogs do not.
    func testLoadsTheDogsOnThePhotoWithNamesAndApprovedPets() throws {
        try withTemporaryDirectory { root in
            defer { CatalogDatabase.checkpointAndCloseAll() }
            let url = root.appendingPathComponent(PetIndexDatabase.fileName)
            let store = try PetIndexDatabase.open(url: url)
            let rex = try store.createPerson(name: "Rex", isRoster: true)
            let lookalike = try store.createPerson(name: "Dog 1", isRoster: false, suggestedPersonID: rex.id)

            let shown = file(root)
            let shownPhoto = photo(for: shown)
            try store.replaceFaces(photo: shownPhoto, faces: [
                dog(on: shownPhoto, x: 0.05, state: .confirmed, petID: rex.id),
                dog(on: shownPhoto, x: 0.40, state: .proposed, petID: lookalike.id, score: 0.81),
                dog(on: shownPhoto, x: 0.70),
            ])
            let other = file(root, "DSC00002.ARW")
            let otherPhoto = photo(for: other)
            try store.replaceFaces(photo: otherPhoto, faces: [dog(on: otherPhoto, x: 0.1)])

            let boxes = PetFrameLookup.boxes(petIndexURL: url, file: shown)
            XCTAssertEqual(boxes.faces.count, 3)
            XCTAssertEqual(Set(boxes.faces.map(\.state)), [.confirmed, .proposed, .cached])
            XCTAssertEqual(boxes.names[rex.id], "Rex")
            XCTAssertEqual(boxes.names[lookalike.id], "Rex", "a lookalike group wears its target's name")
            XCTAssertEqual(boxes.approvedPets.map(\.name), ["Rex"])

            XCTAssertEqual(PetFrameLookup.boxes(petIndexURL: url, file: other).faces.count, 1)
            XCTAssertEqual(PetFrameLookup.boxes(petIndexURL: url, file: file(root, "DSC00003.ARW")), .empty)
        }
    }

    /// A file that moved into an event folder keeps its dogs: the lookup is
    /// by name + size + modified second, not by path.
    func testBoxesFollowTheFileIdentityAcrossFolders() throws {
        try withTemporaryDirectory { root in
            defer { CatalogDatabase.checkpointAndCloseAll() }
            let url = root.appendingPathComponent(PetIndexDatabase.fileName)
            let store = try PetIndexDatabase.open(url: url)
            let scanned = file(root.appendingPathComponent("Unsorted"))
            let scannedPhoto = photo(for: scanned)
            try store.replaceFaces(photo: scannedPhoto, faces: [dog(on: scannedPhoto, x: 0.3)])

            let moved = file(root.appendingPathComponent("Beach Day"))
            XCTAssertEqual(PetFrameLookup.boxes(petIndexURL: url, file: moved).faces.count, 1)
            let resized = file(root.appendingPathComponent("Beach Day"), size: 4_096)
            XCTAssertTrue(PetFrameLookup.boxes(petIndexURL: url, file: resized).faces.isEmpty)
        }
    }

    /// Reading the boxes is not a write: every row in the pet index and
    /// the catalog beside it comes out exactly as it went in, and no pet
    /// row ever reaches the catalog. (Rows, not raw bytes: opening the
    /// shared WAL connection bumps the SQLite header on any read path.)
    func testLookupWritesNeitherThePetIndexNorTheCatalog() throws {
        try withTemporaryDirectory { root in
            defer { CatalogDatabase.checkpointAndCloseAll() }
            let catalog = root.appendingPathComponent("catalog.sqlite")
            try CatalogStore(url: catalog).prepareSchema()
            let people = FaceIndexStore(url: catalog)
            _ = try people.createPerson(name: "Person A", isRoster: true)
            let url = PetIndexDatabase.url(besideCatalog: catalog)
            let store = try PetIndexDatabase.open(url: url)
            let shown = file(root)
            let shownPhoto = photo(for: shown)
            try store.replaceFaces(photo: shownPhoto, faces: [dog(on: shownPhoto, x: 0.3)])
            let before = try rows(url, catalog)

            XCTAssertEqual(PetFrameLookup.boxes(petIndexURL: url, file: shown).faces.count, 1)
            XCTAssertEqual(try rows(url, catalog), before)
            XCTAssertEqual(try people.faceIndexCounts().faces, 0, "no dog reached the catalog")
            XCTAssertEqual(try people.rosterPeople().map(\.name), ["Person A"])
        }
    }

    /// Every face-table row in both files, as text.
    private func rows(_ urls: URL...) throws -> [String] {
        try urls.flatMap { url in
            try ["face_photos", "people", "faces", "face_templates", "face_rejections"].flatMap { table in
                try CatalogDatabase.writer(for: url).read { database in
                    try Row.fetchAll(database, sql: "SELECT * FROM \(table) ORDER BY rowid")
                        .map { "\(url.lastPathComponent)/\(table): \($0.description)" }
                }
            }
        }
    }
}
