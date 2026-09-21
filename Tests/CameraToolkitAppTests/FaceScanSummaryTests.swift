import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

/// The People window footer must report the scan grades actually stored
/// in the catalog — never the old hardcoded "LOW quality".
final class FaceScanSummaryTests: XCTestCase {
    func testEmptyIndexSaysNoFaceScanStored() throws {
        try withTempCatalog { store in
            XCTAssertEqual(try store.storedScanGrades(), [])
            XCTAssertEqual(
                FaceScanSummaryText.quality(try store.storedScanGrades()),
                "No face scan stored"
            )
        }
    }

    func testMediumOnlyIndexSaysMediumQuality() throws {
        try withTempCatalog { store in
            var photo = photoRecord("DSC00001.ARW")
            photo.scanGrade = .med
            try store.replaceFaces(photo: photo, faces: [])

            XCTAssertEqual(try store.storedScanGrades(), [.med])
            XCTAssertEqual(
                FaceScanSummaryText.quality(try store.storedScanGrades()),
                "Medium quality"
            )
        }
    }

    /// A library scanned at different passes lists every stored grade —
    /// in the scan sheet's words, not the raw `low`/`xhigh` values.
    func testMixedIndexListsEveryStoredGrade() throws {
        try withTempCatalog { store in
            var low = photoRecord("DSC00002.ARW")
            low.scanGrade = .low
            var medium = photoRecord("DSC00003.ARW")
            medium.scanGrade = .med
            var extraHigh = photoRecord("DSC00004.ARW")
            extraHigh.scanGrade = .xhigh
            try store.replaceFaces(photo: medium, faces: [])
            try store.replaceFaces(photo: low, faces: [])
            try store.replaceFaces(photo: extraHigh, faces: [])

            XCTAssertEqual(
                FaceScanSummaryText.quality(try store.storedScanGrades()),
                "Low, Medium, Extra High quality"
            )
        }
    }

    // MARK: - Helpers

    /// A bootstrapped catalog in a throwaway folder — tests never touch a
    /// real library.
    private func withTempCatalog(_ body: (FaceIndexStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("catalog.sqlite")
        let configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Safety Test").path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: root.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: root.appendingPathComponent("Library").path,
            catalogDatabasePath: catalog.path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path
        )
        _ = try CatalogStore(url: catalog).bootstrap(
            configuration: configuration,
            createBackup: false,
            createLibraryFolders: false
        )
        try body(FaceIndexStore(url: catalog))
    }

    private func photoRecord(_ name: String) -> FacePhotoRecord {
        let path = "/tmp/faces/\(name)"
        return FacePhotoRecord(
            pathKey: EventStorageLocations.pathKey(path),
            path: path,
            fileName: name,
            byteCount: 1_024,
            modifiedAt: Date(timeIntervalSince1970: 1_752_000_000)
        )
    }
}
