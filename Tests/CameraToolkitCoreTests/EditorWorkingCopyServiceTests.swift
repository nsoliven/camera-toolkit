import CameraToolkitCore
import Foundation
import XCTest

final class EditorWorkingCopyServiceTests: XCTestCase {
    func testCopiesSourceToWorkingFolderWithoutChangingOriginal() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("Card/DCIM/DSC0001.JPG"), "original-bytes")
            let workingRoot = root.appendingPathComponent("Working", isDirectory: true)

            let copy = try EditorWorkingCopyService().makeWorkingCopy(source: source, workingRoot: workingRoot)

            XCTAssertEqual(copy.lastPathComponent, "DSC0001.JPG")
            XCTAssertEqual(try String(contentsOf: copy), "original-bytes")
            try "edited-copy".write(to: copy, atomically: true, encoding: .utf8)
            XCTAssertEqual(try String(contentsOf: source), "original-bytes")
        }
    }

    func testWorkingCopyUsesUniqueNameWhenFileAlreadyExists() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("Card/DSC0001.ARW"), "raw")
            let workingRoot = root.appendingPathComponent("Working", isDirectory: true)
            try writeFile(workingRoot.appendingPathComponent("DSC0001.ARW"), "existing")

            let copy = try EditorWorkingCopyService().makeWorkingCopy(source: source, workingRoot: workingRoot)

            XCTAssertEqual(copy.lastPathComponent, "DSC0001-2.ARW")
            XCTAssertEqual(try String(contentsOf: copy), "raw")
        }
    }

    func testPhotoMatcherIncludesCommonRawAndPreviewFormats() {
        XCTAssertTrue(MediaFileMatcher.isSupportedPhotoPath("DCIM/DSC0001.ARW"))
        XCTAssertTrue(MediaFileMatcher.isSupportedPhotoPath("DCIM/DSC0002.HEIC"))
        XCTAssertTrue(MediaFileMatcher.isSupportedPhotoPath("DCIM/DSC0003.jpg"))
        XCTAssertFalse(MediaFileMatcher.isSupportedPhotoPath("M4ROOT/CLIP/C0001.MP4"))
    }
}
