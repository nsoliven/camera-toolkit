import CameraToolkitCore
import Foundation
import XCTest

final class EmptyFolderDeletionServiceTests: XCTestCase {
    func testDeletesEmptyFolder() throws {
        try withTemporaryDirectory { root in
            let folder = root.appendingPathComponent("Empty", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

            try EmptyFolderDeletionService.delete(folder)

            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        }
    }

    func testRefusesFolderContainingAFile() throws {
        try withTemporaryDirectory { root in
            let folder = root.appendingPathComponent("Not Empty", isDirectory: true)
            try writeFile(folder.appendingPathComponent("photo.ARW"), "camera data")

            XCTAssertThrowsError(try EmptyFolderDeletionService.delete(folder)) { error in
                XCTAssertEqual(error as? EmptyFolderDeletionError, .notEmpty)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("photo.ARW").path))
        }
    }

    func testHiddenFileStillMakesFolderNonEmpty() throws {
        try withTemporaryDirectory { root in
            let folder = root.appendingPathComponent("Looks Empty", isDirectory: true)
            try writeFile(folder.appendingPathComponent(".hidden"), "keep me")

            XCTAssertThrowsError(try EmptyFolderDeletionService.delete(folder)) { error in
                XCTAssertEqual(error as? EmptyFolderDeletionError, .notEmpty)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".hidden").path))
        }
    }

    func testRefusesConfiguredFolderAndItsAncestor() throws {
        try withTemporaryDirectory { root in
            let configured = root.appendingPathComponent("Configured", isDirectory: true)
            try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: false)

            XCTAssertThrowsError(
                try EmptyFolderDeletionService.delete(configured, protectedURLs: [configured])
            ) { error in
                XCTAssertEqual(error as? EmptyFolderDeletionError, .protectedFolder)
            }
            XCTAssertThrowsError(
                try EmptyFolderDeletionService.delete(root, protectedURLs: [configured])
            ) { error in
                XCTAssertEqual(error as? EmptyFolderDeletionError, .protectedFolder)
            }
        }
    }

    func testRefusesSymbolicLink() throws {
        try withTemporaryDirectory { root in
            let destination = root.appendingPathComponent("Destination", isDirectory: true)
            let link = root.appendingPathComponent("Folder Link", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)

            XCTAssertThrowsError(try EmptyFolderDeletionService.delete(link)) { error in
                XCTAssertEqual(error as? EmptyFolderDeletionError, .symbolicLink)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        }
    }
}
