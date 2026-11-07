import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

/// The Pets side of the People window: it reads and writes the pet index
/// beside the catalog — never the catalog — and browsing never creates it.
@MainActor
final class PetGalleryTests: XCTestCase {
    private func makeGallery(root: URL) -> (PetGallery, URL) {
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
        return (gallery, catalog)
    }

    func testBrowsingPetsBeforeAnyPetScanCreatesNothing() throws {
        try withScratchFolder { root in
            let (gallery, catalog) = makeGallery(root: root)
            XCTAssertEqual(gallery.databaseURL, PetIndexDatabase.url(besideCatalog: catalog))
            XCTAssertTrue(gallery.faceSnapshot().approved.isEmpty)
            XCTAssertTrue(gallery.faceSnapshot().inbox.isEmpty)
            XCTAssertEqual(gallery.faceIndexCounts(), FaceIndexCounts())
            XCTAssertFalse(gallery.faceEngineInstalled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: gallery.databaseURL.path))
        }
    }

    /// Approve, rename, and clear a dog group: every write lands in the
    /// pet index, and the catalog's people stay exactly as they were.
    func testReviewActionsWriteThePetIndexOnly() throws {
        try withScratchFolder { root in
            let (gallery, catalog) = makeGallery(root: root)
            try CatalogStore(url: catalog).prepareSchema()
            let people = FaceIndexStore(url: catalog)
            let alex = try people.createPerson(name: "Alex", isRoster: true)

            let store = try PetIndexDatabase.open(url: gallery.databaseURL)
            let group = try store.createPerson(name: try store.nextGroupName(), isRoster: false)
            gallery.noteScanFinished()
            XCTAssertEqual(gallery.faceSnapshot().inbox.map(\.name), ["Dog 1"])

            let revision = gallery.facesRevision
            gallery.nameGroup(group.id, name: "Rex")
            XCTAssertGreaterThan(gallery.facesRevision, revision)
            XCTAssertEqual(gallery.faceSnapshot().approved.map(\.name), ["Rex"])
            gallery.renamePerson(group.id, name: "Rexie")
            XCTAssertEqual(gallery.person(group.id)?.name, "Rexie")

            gallery.clearFaceIndex()
            XCTAssertTrue(gallery.faceSnapshot().approved.isEmpty)

            XCTAssertEqual(try people.rosterPeople().map(\.id), [alex.id])
            XCTAssertEqual(try people.rosterPeople().map(\.name), ["Alex"])
        }
    }

    func testScanReportSummariesNameDogsOnlyWhenScanned() {
        var faces = FaceScanReport()
        faces.facesDetected = 4
        XCTAssertEqual(FaceAndPetScanReport(faces: faces).petSummary, "")

        var pets = FaceScanReport()
        pets.facesDetected = 1
        pets.photosProcessed = 3
        pets.facesGrouped = 1
        let summary = FaceAndPetScanReport(faces: faces, pets: pets).petSummary
        XCTAssertTrue(summary.contains("Dogs: 1 dog on 3 photo(s)"), summary)

        let failed = FaceAndPetScanReport(faces: faces, petError: "The pet sidecar exited.").petSummary
        XCTAssertTrue(failed.contains("did not finish"))
        XCTAssertTrue(failed.contains("Faces above are stored"))
    }

    func testGallerySubjectsKeepPeopleWordsAndNamePets() {
        XCTAssertEqual(FaceScanSummaryText.quality([]), "No face scan stored")
        XCTAssertEqual(FaceScanSummaryText.quality([], subject: .pets), "No pet scan stored")
        XCTAssertEqual(FaceGallerySubject.people.setupCommand, FaceSidecarInstallation.setupCommand)
        XCTAssertEqual(FaceGallerySubject.pets.setupCommand, PetSidecarInstallation.setupCommand)
        XCTAssertEqual(FaceGallerySubject.pets.clearTitle, "Clear Pet Scan")
    }

    func testPetsAreOnByDefaultOnceTheEngineIsThere() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pet-gallery-tests-\(UUID().uuidString)"))
        XCTAssertTrue(PetGallery.scanEnabled(defaults))
        defaults.set(false, forKey: PetGallery.scanEnabledDefaultsKey)
        XCTAssertFalse(PetGallery.scanEnabled(defaults))
    }

    private func withScratchFolder(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ct-pet-gallery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            CatalogDatabase.checkpointAndCloseAll()
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }
}
