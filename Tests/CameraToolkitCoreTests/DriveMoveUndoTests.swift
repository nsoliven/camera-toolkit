@testable import CameraToolkitCore
import Foundation
import XCTest

/// Undo after a partial failure, and the names a Keep Both gives Sony clip
/// sidecars: what goes back is decided per file, and the journal says which
/// catalog entry belongs to which rename.
final class DriveMoveUndoTests: XCTestCase {
    private let source = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let target = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private func pair(_ name: String) -> (old: PhotoEventAssignment, new: PhotoEventAssignment) {
        let old = PhotoEventAssignment(
            sourceRootPath: "/Card", relativePath: name, fileSize: 1,
            modifiedAt: Date(timeIntervalSince1970: 1_000), eventID: source, deviceID: "sony-a7v"
        )
        var new = old
        new.eventID = target
        return (old, new)
    }

    // MARK: - Names

    func testSonyClipSidecarsTakeTheirClipsNumberBeforeTheMarker() {
        XCTAssertEqual(KeepBothNaming.suffixed("C0167.MP4", 2), "C0167 (2).MP4")
        XCTAssertEqual(KeepBothNaming.suffixed("C0167M01.XML", 2), "C0167 (2)M01.XML")
        XCTAssertEqual(KeepBothNaming.suffixed("c0167m02.xml", 3), "c0167 (3)m02.xml")
        // Not sidecars: an ordinary XML and a photo that happens to end in M01.
        XCTAssertEqual(KeepBothNaming.suffixed("notes.XML", 2), "notes (2).XML")
        XCTAssertEqual(KeepBothNaming.suffixed("TRIPM01.ARW", 2), "TRIPM01 (2).ARW")
        XCTAssertEqual(
            ApplyCollisionCheck.groupKey("/Card/C0167M01.XML"),
            ApplyCollisionCheck.groupKey("/Card/C0167.MP4")
        )
    }

    func testAClipAndItsSidecarTakeOneNumberTogether() throws {
        try withTemporaryDirectory { root in
            let event = root.appendingPathComponent("Event", isDirectory: true)
            try writeFile(event.appendingPathComponent("C0167 (2)M01.XML"), "someone else's sidecar")
            let moves = ["C0167.MP4", "C0167M01.XML"].map {
                DriveMove(sourcePath: root.appendingPathComponent("Unsorted/\($0)").path, destinationPath: event.appendingPathComponent($0).path, byteCount: 1)
            }
            let renamed = try XCTUnwrap(KeepBothNaming.renamedMoves(for: moves))
            XCTAssertEqual(renamed.map { ($0.destinationPath as NSString).lastPathComponent }, ["C0167 (3).MP4", "C0167 (3)M01.XML"])
        }
    }

    // MARK: - The journal

    func testTheJournalRecordsWhichRenameCarriesEachCatalogEntry() throws {
        try withTemporaryDirectory { root in
            let journals = root.appendingPathComponent("Journals", isDirectory: true)
            let a = try writeFile(root.appendingPathComponent("Old/A.ARW"), "a")
            let b = try writeFile(root.appendingPathComponent("Old/B.ARW"), "b")
            let entries = [pair("A.ARW"), pair("Catalog only.ARW"), pair("B.ARW"), pair("Missing.ARW")]
            let report = try DriveMoveService().apply(
                [
                    DriveMove(sourcePath: a.path, destinationPath: root.appendingPathComponent("New/A.ARW").path, byteCount: 1),
                    DriveMove(sourcePath: b.path, destinationPath: root.appendingPathComponent("New/B.ARW").path, byteCount: 1),
                    DriveMove(sourcePath: root.appendingPathComponent("Old/Missing.ARW").path, destinationPath: root.appendingPathComponent("New/Missing.ARW").path, byteCount: 1),
                ],
                title: "Move",
                journalFolder: journals,
                removedAssignments: entries.map(\.old),
                addedAssignments: entries.map(\.new),
                assignmentMoveSources: [a.path, nil, b.path, root.appendingPathComponent("Old/Missing.ARW").path]
            )
            XCTAssertEqual(report.moved.count, 2)
            let journal = try XCTUnwrap(DriveMoveService.latestUndoableJournal(in: journals)).journal
            XCTAssertEqual(journal.assignmentMoveIndices, [0, nil, 1, -1])
        }
    }

    func testAJournalWithoutEntryIndicesStillReadsAndSwapsOnlyAfterAFullUndo() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("old.json")
            try writeFile(url, """
            {"completedIndices":[0],"createdAt":"2026-08-20T06:00:04Z","id":"00000000-0000-0000-0000-0000000000AA","moves":[],"removedAssignments":[],"addedAssignments":[],"title":"Apply"}
            """)
            var journal = try DriveMoveService.read(url)
            XCTAssertNil(journal.assignmentMoveIndices)
            let entry = pair("A.ARW")
            journal.removedAssignments = [entry.old]
            journal.addedAssignments = [entry.new]
            XCTAssertEqual(journal.assignmentsToRestore(reversed: [0], fullyUndone: true).removed, [entry.old])
            XCTAssertTrue(journal.assignmentsToRestore(reversed: [0], fullyUndone: false).removed.isEmpty)
        }
    }

    // MARK: - Undo

    private func move(_ root: URL, names: [String]) throws -> (report: DriveMoveReport, journals: URL) {
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        var moves: [DriveMove] = []
        for name in names {
            let file = try writeFile(root.appendingPathComponent("Old/\(name)"), name)
            moves.append(DriveMove(sourcePath: file.path, destinationPath: root.appendingPathComponent("New/\(name)").path, byteCount: Int64(name.utf8.count)))
        }
        let entries = names.map(pair)
        let report = try DriveMoveService().apply(
            moves, title: "Move", journalFolder: journals,
            removedAssignments: entries.map(\.old), addedAssignments: entries.map(\.new),
            assignmentMoveSources: moves.map(\.sourcePath)
        )
        return (report, journals)
    }

    func testAPartialUndoSwapsBackOnlyTheEntriesWhoseFileWentBackAndKeepsTheJournalOpen() throws {
        try withTemporaryDirectory { root in
            let (_, journals) = try move(root, names: ["A.ARW", "B.ARW", "C.ARW"])
            // A new file takes B's old name.
            try writeFile(root.appendingPathComponent("Old/B.ARW"), "someone else's")
            let latest = try XCTUnwrap(DriveMoveService.latestUndoableJournal(in: journals))

            let first = try DriveMoveService().undo(journalURL: latest.url)
            XCTAssertEqual(Set(first.report.moved.map { ($0.destinationPath as NSString).lastPathComponent }), ["A.ARW", "C.ARW"])
            XCTAssertEqual(first.report.skipped.count, 1)
            XCTAssertEqual(first.report.reversedIndices.sorted(), [0, 2])
            XCTAssertNil(first.journal.undoneAt, "the file left behind can be tried again")
            XCTAssertEqual(first.journal.completedIndices, [1])
            let restore = first.journal.assignmentsToRestore(reversed: first.report.reversedIndices, fullyUndone: false)
            XCTAssertEqual(restore.removed.map(\.relativePath), ["A.ARW", "C.ARW"])
            XCTAssertEqual(restore.added.map(\.relativePath), ["A.ARW", "C.ARW"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("New/B.ARW").path))
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Old/B.ARW"), encoding: .utf8), "someone else's", "nothing was replaced")

            // The name frees up; Undo again moves only B.
            try FileManager.default.removeItem(at: root.appendingPathComponent("Old/B.ARW"))
            let again = try XCTUnwrap(DriveMoveService.latestUndoableJournal(in: journals))
            let second = try DriveMoveService().undo(journalURL: again.url)
            XCTAssertEqual(second.report.reversedIndices, [1])
            XCTAssertNotNil(second.journal.undoneAt)
            XCTAssertEqual(second.journal.assignmentsToRestore(reversed: [1], fullyUndone: true).removed.map(\.relativePath), ["B.ARW"])
            XCTAssertNil(DriveMoveService.latestUndoableJournal(in: journals))
        }
    }

    func testAnUndoThatGetsNowhereClosesTheJournalSoOlderChangesCanBeUndone() throws {
        try withTemporaryDirectory { root in
            let (_, journals) = try move(root, names: ["A.ARW"])
            try writeFile(root.appendingPathComponent("Old/A.ARW"), "taken")
            let latest = try XCTUnwrap(DriveMoveService.latestUndoableJournal(in: journals))
            let result = try DriveMoveService().undo(journalURL: latest.url)
            XCTAssertTrue(result.report.moved.isEmpty)
            XCTAssertEqual(result.report.skipped.count, 1)
            XCTAssertNotNil(result.journal.undoneAt)
            XCTAssertTrue(result.journal.assignmentsToRestore(reversed: [], fullyUndone: false).removed.isEmpty)
        }
    }

    func testUndoReversesRenamesTheJournalNeverRecorded() throws {
        try withTemporaryDirectory { root in
            let (_, journals) = try move(root, names: ["A.ARW", "B.ARW", "C.ARW"])
            // A crash before the journal was written past the first rename.
            let url = try XCTUnwrap(DriveMoveService.journals(in: journals).first)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json["completedIndices"] = [0]
            try JSONSerialization.data(withJSONObject: json).write(to: url)

            let latest = try XCTUnwrap(DriveMoveService.latestUndoableJournal(in: journals))
            let result = try DriveMoveService().undo(journalURL: latest.url)
            XCTAssertEqual(result.report.reversedIndices.sorted(), [0, 1, 2])
            for name in ["A.ARW", "B.ARW", "C.ARW"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Old/\(name)").path), name)
            }
        }
    }

    /// A file that was renamed by hand since is not "unrecorded progress":
    /// undo never moves a file whose source is still there.
    func testUndoNeverTouchesAFileWhoseSourceIsStillInPlace() throws {
        try withTemporaryDirectory { root in
            let (_, journals) = try move(root, names: ["A.ARW", "B.ARW"])
            let url = try XCTUnwrap(DriveMoveService.journals(in: journals).first)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json["completedIndices"] = [0]
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            // B's source name is occupied again, so B is not evidently "done".
            try writeFile(root.appendingPathComponent("Old/B.ARW"), "new photo")

            let result = try DriveMoveService().undo(journalURL: url)
            XCTAssertEqual(result.report.reversedIndices, [0])
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Old/B.ARW"), encoding: .utf8), "new photo")
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("New/B.ARW").path))
        }
    }
}
