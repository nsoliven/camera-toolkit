import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

/// The organizer preview's box actions: a dog's confirm, tag, and "New
/// Pet" only ever reach the pet index, and a face's only ever reach the
/// catalog.
@MainActor
final class FaceBoxRoutingTests: XCTestCase {
    /// Records every call so a test can prove the other side heard nothing.
    private final class RecordingTarget: FaceBoxTagTarget {
        var calls: [String] = []

        func confirmFace(_ faceID: UUID) { calls.append("confirm \(faceID)") }
        func tagFace(_ faceID: UUID, as personID: UUID) { calls.append("tag \(faceID) \(personID)") }
        func createTaggable(named name: String) -> FacePerson? {
            calls.append("create \(name)")
            return FacePerson(name: name, isRoster: true)
        }
    }

    func testPetActionsNeverReachThePeopleSide() {
        let people = RecordingTarget()
        let pets = RecordingTarget()
        let router = FaceBoxActionRouter(people: people, pets: pets)
        let dog = UUID()
        let rex = UUID()

        router.confirm(dog, subject: .pets)
        router.tag(dog, as: rex, subject: .pets)
        XCTAssertEqual(router.create(named: "Rex", subject: .pets)?.name, "Rex")

        XCTAssertEqual(pets.calls, ["confirm \(dog)", "tag \(dog) \(rex)", "create Rex"])
        XCTAssertTrue(people.calls.isEmpty)
    }

    func testFaceActionsNeverReachThePetSide() {
        let people = RecordingTarget()
        let pets = RecordingTarget()
        let router = FaceBoxActionRouter(people: people, pets: pets)
        let face = UUID()
        let alex = UUID()

        router.confirm(face, subject: .people)
        router.tag(face, as: alex, subject: .people)
        _ = router.create(named: "Person A", subject: .people)

        XCTAssertEqual(people.calls, ["confirm \(face)", "tag \(face) \(alex)", "create Person A"])
        XCTAssertTrue(pets.calls.isEmpty)
    }

    /// Faces and dogs share one hover set, so their boxes are keyed by
    /// subject too — a dog can never be mistaken for a face with the same
    /// id from the other index.
    func testOverlayKeysBoxesBySubject() {
        let id = UUID()
        let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let face = FaceRecord(id: id, photoID: "p", box: box, detScore: 0.9)
        let dog = FaceRecord(id: id, photoID: "p", box: box, detScore: 0.9, model: PetFaceEngine.identifier)
        let entries = FaceBoxesOverlay.entries(faces: [face], pets: [dog])
        XCTAssertEqual(entries.map(\.subject), [.people, .pets])
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
    }

    /// The real pet gallery behind the router: tagging a dog and adding a
    /// pet write the pet index, and the catalog's people and faces stay
    /// exactly as they were.
    func testTaggingADogWritesThePetIndexOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ct-face-box-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            CatalogDatabase.checkpointAndCloseAll()
            try? FileManager.default.removeItem(at: root)
        }
        var configuration = AppConfiguration.defaults(applicationSupport: root)
        let catalog = root.appendingPathComponent("catalog.sqlite")
        configuration.catalogDatabasePath = catalog.path
        let model = DashboardModel(
            jobs: [],
            configuration: configuration,
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )
        let gallery = PetGallery(model: model)
        gallery.applicationSupport = root

        try CatalogStore(url: catalog).prepareSchema()
        let people = FaceIndexStore(url: catalog)
        let personA = try people.createPerson(name: "Person A", isRoster: true)

        let store = try PetIndexDatabase.open(url: gallery.databaseURL)
        let file = OrganizeFile(path: root.appendingPathComponent("DSC00001.ARW").path, size: 2_048, modifiedAt: Date(timeIntervalSince1970: 1_752_000_000))
        let photo = FacePhotoRecord(
            pathKey: file.pathKey,
            path: file.path,
            fileName: file.name,
            byteCount: file.size,
            modifiedAt: file.modifiedAt,
            scanGrade: .high,
            engine: PetFaceEngine.identifier
        )
        let dog = FaceRecord(
            photoID: photo.pathKey,
            box: NormalizedFaceBox(x: 0.3, y: 0.3, width: 0.2, height: 0.2),
            detScore: 0.9,
            model: PetFaceEngine.identifier,
            photoPath: photo.path
        )
        try store.replaceFaces(photo: photo, faces: [dog])
        gallery.noteScanFinished()

        let router = FaceBoxActionRouter(people: RecordingTarget(), pets: gallery)
        let revision = gallery.facesRevision
        let rex = try XCTUnwrap(router.create(named: "Rex", subject: .pets))
        router.tag(dog.id, as: rex.id, subject: .pets)
        XCTAssertGreaterThan(gallery.facesRevision, revision, "the preview reloads its boxes")

        let boxes = PetFrameLookup.boxes(petIndexURL: gallery.databaseURL, file: file)
        XCTAssertEqual(boxes.faces.map(\.state), [.confirmed])
        XCTAssertEqual(boxes.faces.first?.personID, rex.id)
        XCTAssertEqual(boxes.names[rex.id], "Rex")
        XCTAssertEqual(boxes.approvedPets.map(\.name), ["Rex"])

        XCTAssertEqual(try people.rosterPeople().map(\.id), [personA.id])
        XCTAssertEqual(try people.faceIndexCounts().faces, 0)
    }
}
