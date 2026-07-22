import CameraToolkitCore
import Foundation
import XCTest

final class FileTrashServiceTests: XCTestCase {
    func testMovesFilesAndNonEmptyFolders() throws {
        try withTemporaryDirectory { root in
            let file = try writeFile(root.appendingPathComponent("ONE.ARW"), "raw")
            let folder = root.appendingPathComponent("Event", isDirectory: true)
            try writeFile(folder.appendingPathComponent("TWO.ARW"), "raw")
            var moved: [URL] = []

            let report = try FileTrashService.moveToTrash([file, folder]) { url in
                moved.append(url)
            }

            XCTAssertEqual(Set(report.movedURLs), Set([file, folder].map(\.standardizedFileURL)))
            XCTAssertEqual(Set(moved), Set([file, folder].map(\.standardizedFileURL)))
        }
    }

    func testSelectingFolderAndDescendantMovesOnlyFolder() throws {
        try withTemporaryDirectory { root in
            let folder = root.appendingPathComponent("Event", isDirectory: true)
            let file = try writeFile(folder.appendingPathComponent("PHOTO.ARW"), "raw")
            var moved: [URL] = []

            let report = try FileTrashService.moveToTrash([file, folder, file]) { url in
                moved.append(url)
            }

            XCTAssertEqual(report.movedURLs, [folder.standardizedFileURL])
            XCTAssertEqual(moved, [folder.standardizedFileURL])
        }
    }

    func testRefusesConfiguredLocationAndItsAncestorButAllowsAChild() throws {
        try withTemporaryDirectory { root in
            let configured = root.appendingPathComponent("Camera Card", isDirectory: true)
            let child = try writeFile(configured.appendingPathComponent("DCIM/PHOTO.ARW"), "raw")
            var moved: [URL] = []

            XCTAssertThrowsError(
                try FileTrashService.moveToTrash([configured], protectedURLs: [configured]) { _ in }
            ) { error in
                XCTAssertEqual(error as? FileTrashError, .protectedItem("Camera Card"))
            }
            XCTAssertThrowsError(
                try FileTrashService.moveToTrash([root], protectedURLs: [configured]) { _ in }
            ) { error in
                XCTAssertEqual(error as? FileTrashError, .protectedItem(root.lastPathComponent))
            }

            let report = try FileTrashService.moveToTrash([child], protectedURLs: [configured]) { url in
                moved.append(url)
            }
            XCTAssertEqual(report.movedURLs, [child.standardizedFileURL])
            XCTAssertEqual(moved, [child.standardizedFileURL])
        }
    }

    func testPreflightsEveryTargetBeforeMovingAnything() throws {
        try withTemporaryDirectory { root in
            let existing = try writeFile(root.appendingPathComponent("EXISTS.ARW"), "raw")
            let missing = root.appendingPathComponent("MISSING.ARW")
            var moved: [URL] = []

            XCTAssertThrowsError(
                try FileTrashService.moveToTrash([existing, missing]) { url in
                    moved.append(url)
                }
            ) { error in
                XCTAssertEqual(error as? FileTrashError, .missing("MISSING.ARW"))
            }
            XCTAssertTrue(moved.isEmpty)
        }
    }

    func testReportsPartialFailureHonestly() throws {
        try withTemporaryDirectory { root in
            let first = try writeFile(root.appendingPathComponent("A.ARW"), "raw")
            let second = try writeFile(root.appendingPathComponent("B.ARW"), "raw")

            XCTAssertThrowsError(
                try FileTrashService.moveToTrash([first, second]) { url in
                    if url.lastPathComponent == "B.ARW" {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                }
            ) { error in
                guard case .partialFailure(let movedCount, let totalCount, let failedName, _) = error as? FileTrashError else {
                    return XCTFail("Expected a partial failure, got \(error)")
                }
                XCTAssertEqual(movedCount, 1)
                XCTAssertEqual(totalCount, 2)
                XCTAssertEqual(failedName, "B.ARW")
            }
        }
    }

    func testRefusesNonFileURLsAndVolumeRootsBeforeMovingAnything() throws {
        var moved: [URL] = []
        let webURL = try XCTUnwrap(URL(string: "https://example.com/photo.arw"))

        XCTAssertThrowsError(
            try FileTrashService.moveToTrash([webURL]) { url in
                moved.append(url)
            }
        ) { error in
            XCTAssertEqual(error as? FileTrashError, .invalidItem("photo.arw"))
        }
        XCTAssertThrowsError(
            try FileTrashService.moveToTrash([URL(fileURLWithPath: "/Volumes/Camera Card")]) { url in
                moved.append(url)
            }
        ) { error in
            XCTAssertEqual(error as? FileTrashError, .protectedItem("Camera Card"))
        }
        XCTAssertTrue(moved.isEmpty)
    }
}
