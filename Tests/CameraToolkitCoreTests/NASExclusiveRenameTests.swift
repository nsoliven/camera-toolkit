@testable import CameraToolkitCore
import Darwin
import Foundation
import XCTest

/// `renameExclusive` on a filesystem that answers `ENOTSUP` for a free name
/// and whose plain `rename` replaces (smbfs, measured on the NAS share).
final class NASExclusiveRenameTests: XCTestCase {
    override func tearDown() {
        NASFileIO.renameExclusivePrimitive = nil
        super.tearDown()
    }

    /// The SMB answer: `EEXIST` when the name is taken, `ENOTSUP` when free.
    private func behaveLikeSMB() {
        NASFileIO.renameExclusivePrimitive = { _, destination in
            var info = stat()
            errno = lstat(destination, &info) == 0 ? EEXIST : ENOTSUP
            return -1
        }
    }

    func testAFileMovesOntoAFreeNameThroughTheClaim() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("a.ARW"), Data("photo".utf8))
            let destination = root.appendingPathComponent("b.ARW")
            behaveLikeSMB()
            try NASFileIO.renameExclusive(from: source.path, to: destination.path)
            XCTAssertEqual(try Data(contentsOf: destination), Data("photo".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testAFolderMovesOntoAFreeNameThroughTheClaim() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("Event A")
            _ = try writeFile(source.appendingPathComponent("Originals/IMG_1.ARW"), Data("1".utf8))
            let destination = root.appendingPathComponent("Event B")
            behaveLikeSMB()
            try NASFileIO.renameExclusive(from: source.path, to: destination.path)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Originals/IMG_1.ARW")), Data("1".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }

    /// Another writer takes the name after the primitive said it was free:
    /// the exclusive claim fails and their file is untouched.
    func testAFileThatAppearsAfterTheCheckIsNeverReplaced() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("a.ARW"), Data("mine".utf8))
            let destination = root.appendingPathComponent("b.ARW")
            NASFileIO.renameExclusivePrimitive = { _, destination in
                _ = try? writeFile(URL(fileURLWithPath: destination), Data("someone else's".utf8))
                errno = ENOTSUP
                return -1
            }
            XCTAssertThrowsError(try NASFileIO.renameExclusive(from: source.path, to: destination.path))
            XCTAssertEqual(try Data(contentsOf: destination), Data("someone else's".utf8))
            XCTAssertEqual(try Data(contentsOf: source), Data("mine".utf8))
        }
    }

    func testAFolderThatAppearsAfterTheCheckIsNeverReplaced() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("Event A")
            _ = try writeFile(source.appendingPathComponent("IMG_1.ARW"), Data("1".utf8))
            let destination = root.appendingPathComponent("Event B")
            NASFileIO.renameExclusivePrimitive = { _, destination in
                try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
                errno = ENOTSUP
                return -1
            }
            XCTAssertThrowsError(try NASFileIO.renameExclusive(from: source.path, to: destination.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("IMG_1.ARW").path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        }
    }

    /// A rename that fails after the claim leaves no placeholder behind.
    func testAFailedRenameRemovesItsPlaceholder() throws {
        try withTemporaryDirectory { root in
            let missing = root.appendingPathComponent("gone.ARW")
            let destination = root.appendingPathComponent("b.ARW")
            _ = try writeFile(missing, Data("x".utf8))
            NASFileIO.renameExclusivePrimitive = { source, _ in
                unlink(source)  // The source vanishes before the rename.
                errno = ENOTSUP
                return -1
            }
            XCTAssertThrowsError(try NASFileIO.renameExclusive(from: missing.path, to: destination.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }
}
