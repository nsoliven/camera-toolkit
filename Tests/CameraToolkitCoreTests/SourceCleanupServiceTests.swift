import CameraToolkitCore
import Foundation
import XCTest

final class SourceCleanupServiceTests: XCTestCase {
    func testMatchingFilesAreRemovedFromSourceOnlyAfterRecheck() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeFixture(root)
            let phases = LockedPhases()

            let report = try SourceCleanupService().removeVerifiedFiles(
                sourceRoot: fixture.source,
                bufferRoot: fixture.buffer,
                files: fixture.files,
                confirmation: SourceCleanupService.confirmationToken,
                progress: { phases.insert($0.phase) }
            )

            XCTAssertEqual(report.removed, fixture.files.map(\.path).sorted())
            XCTAssertEqual(report.removedBytes, fixture.files.reduce(Int64(0)) { $0 + $1.size })
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("DCIM/one.OSV").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("DCIM/two.LRF").path))
            XCTAssertEqual(try Data(contentsOf: fixture.buffer.appendingPathComponent("DCIM/one.OSV")), Data("video-one".utf8))
            XCTAssertEqual(try Data(contentsOf: fixture.buffer.appendingPathComponent("DCIM/two.LRF")), Data("preview-two".utf8))
            XCTAssertTrue(phases.contains("Rechecking camera file"))
            XCTAssertTrue(phases.contains("Rechecking Buffer copy"))
        }
    }

    func testWrongConfirmationNeverRemovesSourceFiles() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeFixture(root)

            XCTAssertThrowsError(try SourceCleanupService().removeVerifiedFiles(
                sourceRoot: fixture.source,
                bufferRoot: fixture.buffer,
                files: fixture.files,
                confirmation: "DELETE"
            ))

            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("DCIM/one.OSV").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("DCIM/two.LRF").path))
        }
    }

    func testOneMismatchPreventsRemovingTheEntireSet() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeFixture(root)
            try Data("changed!!".utf8).write(to: fixture.buffer.appendingPathComponent("DCIM/two.LRF"))

            let report = try SourceCleanupService().removeVerifiedFiles(
                sourceRoot: fixture.source,
                bufferRoot: fixture.buffer,
                files: fixture.files,
                confirmation: SourceCleanupService.confirmationToken
            )

            XCTAssertEqual(report.differ, ["DCIM/two.LRF"])
            XCTAssertTrue(report.removed.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("DCIM/one.OSV").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("DCIM/two.LRF").path))
        }
    }

    func testMissingBufferCopyPreventsRemovingTheEntireSet() throws {
        try withTemporaryDirectory { root in
            let fixture = try makeFixture(root)
            try FileManager.default.removeItem(at: fixture.buffer.appendingPathComponent("DCIM/two.LRF"))

            let report = try SourceCleanupService().removeVerifiedFiles(
                sourceRoot: fixture.source,
                bufferRoot: fixture.buffer,
                files: fixture.files,
                confirmation: SourceCleanupService.confirmationToken
            )

            XCTAssertEqual(report.missingBuffer, ["DCIM/two.LRF"])
            XCTAssertTrue(report.removed.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("DCIM/one.OSV").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("DCIM/two.LRF").path))
        }
    }

    private func makeFixture(_ root: URL) throws -> (source: URL, buffer: URL, files: [FileRecord]) {
        let source = root.appendingPathComponent("Camera", isDirectory: true)
        let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
        let data: [(String, Data)] = [
            ("DCIM/one.OSV", Data("video-one".utf8)),
            ("DCIM/two.LRF", Data("preview-two".utf8))
        ]
        for (relativePath, content) in data {
            try writeFile(source.appendingPathComponent(relativePath), content)
            try writeFile(buffer.appendingPathComponent(relativePath), content)
        }
        let files = data.map { relativePath, content in
            FileRecord(path: relativePath, size: Int64(content.count), modifiedAt: .distantPast)
        }
        return (source, buffer, files)
    }
}

private final class LockedPhases: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: Set<String> = []

    func insert(_ phase: String) {
        _ = lock.withLock { phases.insert(phase) }
    }

    func contains(_ phase: String) -> Bool {
        lock.withLock { phases.contains(phase) }
    }
}
