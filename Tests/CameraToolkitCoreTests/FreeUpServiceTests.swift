import CameraToolkitCore
import Foundation
import XCTest

final class FreeUpServiceTests: XCTestCase {
    func testFreeUpDryRunReportsButMovesNothing() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeBufferAndArchive(root)
            let before = try treeBytes(fixture.buffer)

            let report = try service().freeUp(bufferRoot: fixture.buffer, archiveRoot: fixture.archive, trashRoot: fixture.trash, apply: false)

            XCTAssertEqual(report.safe.sorted(), fixture.files.keys.sorted())
            XCTAssertTrue(report.moved.isEmpty)
            XCTAssertEqual(try treeBytes(fixture.buffer), before)
        }
    }

    func testFreeUpRefusesFileMissingOnArchive() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeBufferAndArchive(root)
            try FileManager.default.removeItem(at: fixture.archive.appendingPathComponent(fixture.rel).appendingPathComponent("DCIM/DSC2.ARW"))

            let report = try service().freeUp(bufferRoot: fixture.buffer, archiveRoot: fixture.archive, trashRoot: fixture.trash, apply: true)

            XCTAssertTrue(report.notOnArchive.contains("\(fixture.rel)/DCIM/DSC2.ARW"))
            XCTAssertFalse(report.moved.contains("\(fixture.rel)/DCIM/DSC2.ARW"))
            XCTAssertEqual(try Data(contentsOf: fixture.buffer.appendingPathComponent(fixture.rel).appendingPathComponent("DCIM/DSC2.ARW")), fixture.files["\(fixture.rel)/DCIM/DSC2.ARW"])
            XCTAssertEqual(report.moved.count, 2)
        }
    }

    func testFreeUpRefusesCorruptedArchiveCopySameSize() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeBufferAndArchive(root)
            let victim = fixture.archive.appendingPathComponent(fixture.rel).appendingPathComponent("DCIM/DSC1.ARW")
            var data = try Data(contentsOf: victim)
            data[100] = data[100] ^ 0xFF
            try data.write(to: victim)

            let report = try service().freeUp(bufferRoot: fixture.buffer, archiveRoot: fixture.archive, trashRoot: fixture.trash, apply: true)

            XCTAssertTrue(report.differ.contains("\(fixture.rel)/DCIM/DSC1.ARW"))
            XCTAssertFalse(report.moved.contains("\(fixture.rel)/DCIM/DSC1.ARW"))
            XCTAssertEqual(try Data(contentsOf: fixture.buffer.appendingPathComponent(fixture.rel).appendingPathComponent("DCIM/DSC1.ARW")), fixture.files["\(fixture.rel)/DCIM/DSC1.ARW"])
        }
    }

    func testFreeUpRefusesTruncatedArchiveCopy() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeBufferAndArchive(root)
            let victim = fixture.archive.appendingPathComponent(fixture.rel).appendingPathComponent("DCIM/DSC3.ARW")
            try Data(repeating: 0x54, count: 100).write(to: victim)

            let report = try service().freeUp(bufferRoot: fixture.buffer, archiveRoot: fixture.archive, trashRoot: fixture.trash, apply: true)

            XCTAssertTrue(report.differ.contains("\(fixture.rel)/DCIM/DSC3.ARW"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.buffer.appendingPathComponent(fixture.rel).appendingPathComponent("DCIM/DSC3.ARW").path))
        }
    }

    func testFreeUpQuarantinePreservesBytesAndLayout() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeBufferAndArchive(root)

            let report = try service().freeUp(bufferRoot: fixture.buffer, archiveRoot: fixture.archive, trashRoot: fixture.trash, apply: true)

            XCTAssertEqual(report.moved.sorted(), fixture.files.keys.sorted())
            XCTAssertEqual(report.freedBytes, fixture.files.values.reduce(Int64(0)) { $0 + Int64($1.count) })
            let batch = try XCTUnwrap(report.trashBatch)
            for (relativePath, content) in fixture.files {
                XCTAssertEqual(try Data(contentsOf: fixture.trash.appendingPathComponent(batch).appendingPathComponent(relativePath)), content)
            }
        }
    }

    func testJunkSweepDoesNotTouchRealUnsyncedFile() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeBufferAndArchive(root)
            try writeFile(fixture.buffer.appendingPathComponent(fixture.rel).appendingPathComponent("DCIM/.DS_Store"), "junk")
            try writeFile(fixture.buffer.appendingPathComponent(fixture.rel).appendingPathComponent("DCIM/._DSC1.ARW"), "appledouble")
            try writeFile(fixture.buffer.appendingPathComponent(fixture.rel).appendingPathComponent("DCIM/DSC9.ARW"), "unsynced-precious")

            let report = try service().freeUp(bufferRoot: fixture.buffer, archiveRoot: fixture.archive, trashRoot: fixture.trash, apply: true)

            XCTAssertEqual(report.junkRemoved, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.buffer.appendingPathComponent(fixture.rel).appendingPathComponent("DCIM/.DS_Store").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.buffer.appendingPathComponent(fixture.rel).appendingPathComponent("DCIM/._DSC1.ARW").path))
            XCTAssertEqual(try Data(contentsOf: fixture.buffer.appendingPathComponent(fixture.rel).appendingPathComponent("DCIM/DSC9.ARW")), Data("unsynced-precious".utf8))
        }
    }

    func testEmptyTrashRequiresTypedToken() throws {
        try withTemporaryDirectory { root in
            let trash = root.appendingPathComponent("_Trash", isDirectory: true)
            try writeFile(trash.appendingPathComponent("2026-01-01_000000/a.ARW"), "x")

            for bad in ["", "delete", "yes", "DELETE ", "Delete"] {
                XCTAssertThrowsError(try service().emptyTrash(trashRoot: trash, confirm: bad))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("2026-01-01_000000/a.ARW").path))

            let result = try service().emptyTrash(trashRoot: trash, confirm: "DELETE")
            XCTAssertEqual(result.deletedBatches, ["2026-01-01_000000"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: trash.appendingPathComponent("2026-01-01_000000").path))
        }
    }

    func testEmptyTrashRefusesNonTrashPath() throws {
        try withTemporaryDirectory { root in
            let realFolder = root.appendingPathComponent("Camera Buffer", isDirectory: true)
            try writeFile(realFolder.appendingPathComponent("a.ARW"), "precious")

            XCTAssertThrowsError(try service().emptyTrash(trashRoot: realFolder, confirm: "DELETE"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: realFolder.appendingPathComponent("a.ARW").path))
        }
    }

    func testRestoreTrashBatchDoesNotOverwriteExistingFile() throws {
        try withTemporaryDirectory { root in
            let buffer = root.appendingPathComponent("Camera Buffer", isDirectory: true)
            let trash = buffer.appendingPathComponent("_Trash", isDirectory: true)
            try writeFile(trash.appendingPathComponent("2026-01-01_000000/DCIM/DSC1.ARW"), "bytes-1")
            try writeFile(buffer.appendingPathComponent("DCIM/DSC2.ARW"), "already-here")
            try writeFile(trash.appendingPathComponent("2026-01-01_000000/DCIM/DSC2.ARW"), "older-version")

            let result = try service().restoreTrashBatch(trashRoot: trash, batch: "2026-01-01_000000", bufferRoot: buffer)

            XCTAssertEqual(result.restored, 1)
            XCTAssertEqual(try Data(contentsOf: buffer.appendingPathComponent("DCIM/DSC1.ARW")), Data("bytes-1".utf8))
            XCTAssertEqual(try Data(contentsOf: buffer.appendingPathComponent("DCIM/DSC2.ARW")), Data("already-here".utf8))
            XCTAssertEqual(result.skipped, ["DCIM/DSC2.ARW"])
        }
    }

    private func service() -> FreeUpService {
        FreeUpService(now: { Date(timeIntervalSince1970: 1_767_225_600) })
    }

    private func makeBufferAndArchive(_ root: URL) throws -> (buffer: URL, archive: URL, trash: URL, rel: String, files: [String: Data]) {
        let buffer = root.appendingPathComponent("drive/Camera Buffer", isDirectory: true)
        let archive = root.appendingPathComponent("Library/Originals", isDirectory: true)
        let trash = buffer.appendingPathComponent("_Trash", isDirectory: true)
        let rel = "Sony-A7V/2026/2026-06_Test/batch-1"
        let files = [
            "\(rel)/DCIM/DSC1.ARW": Data.repeated("photo-one", count: 500),
            "\(rel)/DCIM/DSC2.ARW": Data.repeated("photo-two", count: 500),
            "\(rel)/DCIM/DSC3.ARW": Data.repeated("photo-three", count: 500)
        ]

        for (relativePath, content) in files {
            try writeFile(buffer.appendingPathComponent(relativePath), content)
            try writeFile(archive.appendingPathComponent(relativePath), content)
        }

        return (buffer, archive, trash, rel, files)
    }
}
