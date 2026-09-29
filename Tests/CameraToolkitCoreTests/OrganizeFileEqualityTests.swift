import Foundation
import XCTest
@testable import CameraToolkitCore

/// A board of 15,000 files is compared for changes every time it is
/// republished; `OrganizeFile` equality must not pay for `URL ==`.
final class OrganizeFileEqualityTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_780_000_000)

    func testAFileIsItsPathSizeAndModificationTime() {
        let file = OrganizeFile(path: "/Volumes/Buffer/2026/Trip/DSC0001.ARW", size: 10, modifiedAt: date)
        XCTAssertEqual(file, OrganizeFile(path: "/Volumes/Buffer/2026/Trip/DSC0001.ARW", size: 10, modifiedAt: date))
        XCTAssertNotEqual(file, OrganizeFile(path: "/Volumes/Buffer/2026/Trip/DSC0002.ARW", size: 10, modifiedAt: date))
        XCTAssertNotEqual(file, OrganizeFile(path: file.path, size: 11, modifiedAt: date))
        XCTAssertNotEqual(file, OrganizeFile(path: file.path, size: 10, modifiedAt: date.addingTimeInterval(1)))
    }

    func testDerivedFieldsFollowThePathSoTheyNeverDecideEquality() {
        let literal = OrganizeFile(literalPath: "/tmp/ct-equality/DSC0001.ARW", size: 1, modifiedAt: date)
        let standardized = OrganizeFile(path: "/tmp/ct-equality/DSC0001.ARW", size: 1, modifiedAt: date)
        XCTAssertEqual(literal, standardized)
        XCTAssertEqual(Set([literal, standardized]).count, 1)
        XCTAssertEqual(literal.hashValue, standardized.hashValue)

        var moved = literal
        moved.path = "/tmp/ct-equality/Other/DSC0001.ARW"
        XCTAssertNotEqual(moved, literal)
        XCTAssertEqual(moved.pathKey, EventStorageLocations.pathKey(moved.path), "a repointed file re-derives its key and URL")
        XCTAssertEqual(moved.url.path, moved.path)
    }

    func testStacksOfEqualFilesAreEqual() {
        func stack() -> OrganizeStack {
            OrganizeStack(items: [OrganizeItem(
                primary: OrganizeFile(path: "/tmp/ct-equality/B0001_DSC0001.ARW", size: 1, modifiedAt: date),
                companions: [OrganizeFile(path: "/tmp/ct-equality/B0001_DSC0001.xmp", size: 1, modifiedAt: date)],
                kind: .raw,
                captureDate: date,
                hasCameraDate: false
            )])
        }
        XCTAssertEqual([stack()], [stack()])
    }
}
