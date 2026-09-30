import Foundation
import XCTest
@testable import CameraToolkitCore

/// `OrganizeFile.name` cuts a path at its last slash instead of asking
/// `NSString`; the answer must be the same for every spelling of a path.
final class OrganizeFileNameTests: XCTestCase {
    private func name(_ path: String) -> String {
        OrganizeFile(literalPath: path, size: 1, modifiedAt: Date(timeIntervalSince1970: 0)).name
    }

    func testPlainPathsGiveTheirLastComponent() {
        XCTAssertEqual(name("/Volumes/Buffer/Trip 2026/Originals/Sony A7V/DSC00001.ARW"), "DSC00001.ARW")
        XCTAssertEqual(name("/DSC00001.ARW"), "DSC00001.ARW")
        XCTAssertEqual(name("/a/b c/d e.JPG"), "d e.JPG")
    }

    func testUnusualSpellingsAgreeWithNSString() {
        let paths = [
            "", "/", "//", "a", "a/", "/a/", "/a/b/", "a//b", "//a", "/a//b//", "/a/b.c.d", "/a/.hidden", "/a/é/ñ.ARW",
            "/a/😀.MOV", "relative/path/file.txt", "/trailing space /file ", "/a/b\\c", "/a/../b", "/a/./b"
        ]
        for path in paths {
            XCTAssertEqual(name(path), (path as NSString).lastPathComponent, "path: \(path)")
        }
    }
}
