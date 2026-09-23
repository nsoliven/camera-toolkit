@testable import CameraToolkitCore
import Foundation
import GRDB
import XCTest

final class FaceLabelExportTests: XCTestCase {
    private let modified = Date(timeIntervalSince1970: 1_750_000_000)

    private func photo(_ name: String, folder: String = "/cards/a/DCIM") -> FacePhotoRecord {
        FacePhotoRecord(
            pathKey: "\(folder)/\(name)".lowercased(),
            path: "\(folder)/\(name)",
            fileName: name,
            byteCount: 1_000 + Int64(name.count),
            modifiedAt: modified,
            scanGrade: .med
        )
    }

    private func face(
        _ photo: FacePhotoRecord,
        _ box: NormalizedFaceBox,
        person: UUID? = nil,
        state: FaceState = .cached
    ) -> FaceRecord {
        FaceRecord(photoID: photo.pathKey, personID: person, box: box, detScore: 0.9, state: state, photoPath: photo.path)
    }

    private func bootstrap(_ root: URL, name: String) throws -> (URL, FaceIndexStore) {
        let catalog = root.appendingPathComponent(name)
        _ = try CatalogStore(url: catalog).bootstrap(
            configuration: .testConfiguration(root: root, catalog: catalog),
            createLibraryFolders: false
        )
        return (catalog, FaceIndexStore(url: catalog))
    }

    private let leftBox = NormalizedFaceBox(x: 0.10, y: 0.10, width: 0.20, height: 0.20)
    private let rightBox = NormalizedFaceBox(x: 0.60, y: 0.20, width: 0.20, height: 0.20)

    /// A reviewed catalog: Ada (roster) confirmed on two photos with a
    /// template and a cover, Grace confirmed once, one rejection, and an
    /// unconfirmed cached face that must not be exported as a label.
    private func seedReviewedCatalog(_ store: FaceIndexStore) throws -> (ada: FacePerson, grace: FacePerson) {
        let ada = try store.createPerson(name: "Ada", isRoster: true)
        let grace = try store.createPerson(name: "Grace", isRoster: true)
        let one = photo("DSC00001.ARW")
        let two = photo("DSC00002.ARW")
        let adaOne = face(one, leftBox, person: ada.id, state: .confirmed)
        let graceOne = face(one, rightBox, person: grace.id, state: .confirmed)
        let adaTwo = face(two, leftBox, person: ada.id, state: .confirmed)
        let strangerTwo = face(two, rightBox)
        try store.replaceFaces(photo: one, faces: [adaOne, graceOne])
        try store.replaceFaces(photo: two, faces: [adaTwo, strangerTwo])
        try store.addTemplate(personID: ada.id, faceID: adaOne.id)
        _ = try store.setCoverFace(personID: ada.id, faceID: adaTwo.id)
        try store.recordRejection(personID: ada.id, faceID: strangerTwo.id)
        try store.refreshFaceCounts()
        return (ada, grace)
    }

    func testExportIsStableAndHoldsOnlyHandMadeLabels() throws {
        try withTemporaryDirectory { root in
            let (catalog, store) = try bootstrap(root, name: "catalog.sqlite")
            _ = try seedReviewedCatalog(store)

            let first = try store.exportFaceLabels(now: modified)
            let second = try store.exportFaceLabels(now: modified)
            XCTAssertEqual(try first.encoded(), try second.encoded(), "same labels → same bytes")
            XCTAssertEqual(first.people.map(\.name), ["Ada", "Grace"])
            XCTAssertEqual(first.confirmedFaces.count, 3)
            XCTAssertEqual(first.confirmedFaces.filter(\.isTemplate).count, 1)
            XCTAssertEqual(first.rejections.count, 1)
            XCTAssertNotNil(first.people.first { $0.name == "Ada" }?.cover)
            XCTAssertEqual(try FaceLabelExport.decode(first.encoded()), first)
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testTotalCatalogLossThenRescanRestoresWhoIsWho() throws {
        try withTemporaryDirectory { root in
            let (original, store) = try bootstrap(root, name: "catalog.sqlite")
            let (ada, grace) = try seedReviewedCatalog(store)
            let labels = try FaceLabelExport.decode(try store.exportFaceLabels().encoded())
            CatalogDatabase.checkpointAndClose(url: original)

            // Total loss: a brand-new catalog, re-scanned. Detections come
            // back with new ids, slightly shifted boxes, in unnamed groups.
            let (fresh, rescanned) = try bootstrap(root, name: "fresh.sqlite")
            let group = try rescanned.createPerson(name: "Group 1", isRoster: false)
            let shift = { (box: NormalizedFaceBox) in
                NormalizedFaceBox(x: box.x + 0.01, y: box.y - 0.01, width: box.width, height: box.height + 0.01)
            }
            let one = photo("DSC00001.ARW")
            // The second photo moved folders since the export: found by
            // file identity, not path.
            let two = photo("DSC00002.ARW", folder: "/Volumes/Buffer/2025/Trip")
            try rescanned.replaceFaces(photo: one, faces: [
                face(one, shift(leftBox), person: group.id, state: .other),
                face(one, shift(rightBox))
            ])
            try rescanned.replaceFaces(photo: two, faces: [face(two, shift(leftBox)), face(two, shift(rightBox))])
            // A third, never-exported photo stays untouched.
            let three = photo("DSC00003.ARW")
            try rescanned.replaceFaces(photo: three, faces: [face(three, leftBox)])

            let report = try rescanned.restoreFaceLabels(labels)

            XCTAssertEqual(report.peopleCreated, 2)
            XCTAssertEqual(report.facesRestored, 3)
            XCTAssertEqual(report.facesUnmatched, 0)
            XCTAssertEqual(report.rejectionsRestored, 1)
            XCTAssertEqual(report.coversRestored, 1)
            let restoredAda = try XCTUnwrap(rescanned.person(ada.id))
            XCTAssertTrue(restoredAda.isRoster)
            XCTAssertEqual(restoredAda.faceCount, 2)
            XCTAssertEqual(try rescanned.person(grace.id)?.faceCount, 1)
            XCTAssertTrue(try rescanned.faces(personID: ada.id).allSatisfy { $0.state == .confirmed })
            XCTAssertFalse(try rescanned.faceRejections().personIDsByFaceID.isEmpty)
            // Exporting the restored catalog gives back the same labels
            // (template pin included), apart from the moved photo's path.
            let roundTrip = try rescanned.exportFaceLabels()
            XCTAssertEqual(roundTrip.people.map(\.id), labels.people.map(\.id))
            XCTAssertEqual(roundTrip.confirmedFaces.count, 3)
            XCTAssertEqual(roundTrip.confirmedFaces.filter(\.isTemplate).count, 1)
            XCTAssertNil(try rescanned.person(group.id), "the group the restore emptied is removed")
            XCTAssertEqual(try rescanned.faces(photoID: three.pathKey).first?.state, .cached)

            // Idempotent: a second run changes nothing.
            let again = try rescanned.restoreFaceLabels(labels)
            XCTAssertEqual(again.facesRestored, 0)
            XCTAssertEqual(again.facesAlreadyLabeled, 3)
            XCTAssertEqual(again.peopleCreated, 0)
            XCTAssertEqual(again.rejectionsRestored, 0)
            XCTAssertEqual(again.coversRestored, 0)
            CatalogDatabase.checkpointAndClose(url: fresh)
        }
    }

    func testRestoreNeverOverridesAFaceConfirmedAsSomeoneElse() throws {
        try withTemporaryDirectory { root in
            let (original, store) = try bootstrap(root, name: "catalog.sqlite")
            _ = try seedReviewedCatalog(store)
            let labels = try store.exportFaceLabels()
            CatalogDatabase.checkpointAndClose(url: original)

            let (fresh, rescanned) = try bootstrap(root, name: "fresh.sqlite")
            let other = try rescanned.createPerson(name: "Someone", isRoster: true)
            let one = photo("DSC00001.ARW")
            let kept = face(one, leftBox, person: other.id, state: .confirmed)
            try rescanned.replaceFaces(photo: one, faces: [kept, face(one, rightBox)])

            let report = try rescanned.restoreFaceLabels(labels)

            XCTAssertEqual(report.facesConflicting, 1)
            XCTAssertEqual(report.facesUnmatched, 1, "DSC00002 was not re-scanned yet")
            XCTAssertEqual(try rescanned.face(id: kept.id)?.personID, other.id)
            CatalogDatabase.checkpointAndClose(url: fresh)
        }
    }

    func testEveryBackupSetCarriesTheFaceLabels() throws {
        try withTemporaryDirectory { root in
            let (catalog, store) = try bootstrap(root, name: "catalog.sqlite")
            _ = try seedReviewedCatalog(store)
            let result = try CatalogBackupService(
                catalogURL: catalog,
                configurationURL: nil,
                localFolder: root.appendingPathComponent("Backups"),
                remoteFolder: nil
            ).backupNow(reason: .manual)

            let file = try XCTUnwrap(result.manifest.file(.faceLabels))
            let labels = try FaceLabelExport.decode(Data(contentsOf: result.localFolder.appendingPathComponent(file.name)))
            XCTAssertEqual(labels.confirmedFaces.count, 3)
            XCTAssertEqual(labels.people.count, 2)
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }
}
