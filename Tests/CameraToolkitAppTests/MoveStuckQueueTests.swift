import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// "Alex + Sam Outing": four assignments whose files sit in the Buffer,
/// and the same four names in a private sibling holding identical bytes. The
/// running app showed the Outing board empty and its count 0 while the
/// storage strip still said "4 of 4" — a Move to Event that had been clicked,
/// moved the tiles off the board, and then waited for a job gate that a speed
/// test held and never announced it had let go of.
@MainActor
final class MoveStuckQueueTests: XCTestCase {
    private let names = ["C0167.MP4", "C0167M01.XML", "C0180.MP4", "C0180M01.XML"]

    private struct Outing {
        var library: AuditLibrary
        var outing: [AuditLibrary.Placed]
        var hangout: [AuditLibrary.Placed]
    }

    private func makeOuting() throws -> Outing {
        let library = try AuditLibrary.make()
        let date = AuditLibrary.day
        library.addEvent("trip", name: "Trip 2026", date: date)
        library.addEvent("outing", name: "Alex + Sam Outing", date: date.addingTimeInterval(-4 * 86_400))
        library.addEvent("hangout", name: "Alex&Sam Private Hangout", date: date.addingTimeInterval(86_400), policy: .archiveOnly, parent: "trip")
        var outing: [AuditLibrary.Placed] = []
        var hangout: [AuditLibrary.Placed] = []
        for (index, name) in names.enumerated() {
            let modified = date.addingTimeInterval(Double(index) * 30)
            let content = "SONY-\(name)-" + String(repeating: "v", count: 16)
            outing.append(try library.place("outing", name: name, content: content, modifiedAt: modified))
            hangout.append(try library.place(
                "hangout", name: name, content: content,
                sourceRoot: library.drive.appendingPathComponent("Alex + Sam Outing").path, modifiedAt: modified
            ))
        }
        return Outing(library: library, outing: outing, hangout: hangout)
    }

    /// The board shows every assignment the catalog has for it, with the
    /// same names owned by a sibling.
    func testTheBoardShowsEveryAssignmentTheCatalogHasWhenASiblingOwnsTheSameNames() async throws {
        let state = try makeOuting()
        defer { state.library.tearDown() }
        let library = state.library
        let workspace = library.workspace
        await library.open("outing", "hangout", "trip")

        for (key, placed) in [("outing", state.outing), ("hangout", state.hangout)] {
            let shown = library.boardFiles(library.id(key))
            XCTAssertEqual(shown, placed.map { $0.url.path.lowercased() }.sorted(), key)
            XCTAssertEqual(workspace.assignmentCount(for: library.id(key)), 4, key)
        }
        XCTAssertEqual(workspace.assignmentCount(for: library.id("trip")), 4, "the family board counts its subevent's four, not the sibling top-level event's")
        XCTAssertEqual(workspace.presence[library.id("outing")]?.total, 4)
        XCTAssertEqual(workspace.presence[library.id("outing")]?.onDrive, 4)
    }

    /// The reported state, reproduced: the move waits behind a speed test.
    func testAMoveQueuedBehindASpeedTestRunsWhenTheTestEnds() async throws {
        let state = try makeOuting()
        defer { state.library.tearDown() }
        let library = state.library
        let workspace = library.workspace
        let model = library.model
        await library.open("outing", "hangout")
        let census = library.contentCensus()
        let stacks = try XCTUnwrap(workspace.eventStacks[library.id("outing")])
        XCTAssertFalse(stacks.isEmpty)

        model.isStorageBenchmarkRunning = true
        workspace.moveStacks(Set(stacks.map(\.id)), fromEvent: library.id("outing"), toEvent: library.id("hangout"))
        XCTAssertTrue(model.statusMessage.contains("queued behind"), model.statusMessage)
        // What the user saw: the tiles are gone and the count reads 0 — so the
        // board says why, and the catalog still has all four.
        XCTAssertEqual(workspace.eventStacks[library.id("outing")]?.count, 0)
        XCTAssertEqual(workspace.assignmentCount(for: library.id("outing")), 0)
        XCTAssertEqual(library.assignments("outing").count, 4)
        XCTAssertNotNil(workspace.queuedMoveNote(for: library.id("outing")))
        XCTAssertNotNil(workspace.queuedMoveNote(for: library.id("hangout")))
        XCTAssertNotNil(workspace.queuedMoveNote(for: library.id("trip")), "the family board holds the target")
        // Deleting the "empty" board's event must not go by what the board shows.
        workspace.deleteEmptyEvent(library.id("outing"))
        XCTAssertNotNil(workspace.event(library.id("outing")))
        XCTAssertTrue(model.statusMessage.contains("4 files in the catalog"), model.statusMessage)

        // The speed test ends: the queued move starts by itself.
        model.isStorageBenchmarkRunning = false
        try await library.waitUntil("the queued move never started") { model.isBusy || workspace.isQuiet && model.statusMessage.hasPrefix("Moved") }
        try await library.settle()
        XCTAssertEqual(library.assignments("outing").count, 0)
        XCTAssertEqual(library.assignments("hangout").count, 4)
        XCTAssertNil(workspace.queuedMoveNote(for: library.id("outing")))
        XCTAssertEqual(workspace.assignmentCount(for: library.id("outing")), 0)
        XCTAssertEqual(workspace.assignmentCount(for: library.id("hangout")), 4)
        for placed in state.outing { XCTAssertFalse(library.exists(placed.url.path), "the Buffer spare is in Trash") }
        for placed in state.hangout { XCTAssertTrue(library.exists(placed.url.path)) }
        XCTAssertEqual(library.trashedNames(), names.sorted())
        XCTAssertEqual(library.contentCensus(), census)
    }

    /// The catalog and the drive decide whether an event is empty.
    func testDeleteEmptyEventChecksTheCatalogAndTheDriveNotTheBoard() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        library.addEvent("empty", name: "Empty Day")
        library.addEvent("stray", name: "Stray Day")
        library.addEvent("held", name: "Held Day")

        // A photo nobody catalogued sits in the event's folder.
        let strayFolder = library.folder("stray")
        try FileManager.default.createDirectory(at: strayFolder, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: strayFolder.appendingPathComponent("DSC00099.ARW"))
        try Data("meta".utf8).write(to: strayFolder.appendingPathComponent(".DS_Store"))
        workspace.deleteEmptyEvent(library.id("stray"))
        XCTAssertNotNil(workspace.event(library.id("stray")))
        XCTAssertTrue(model.statusMessage.contains("1 file on the drive"), model.statusMessage)
        XCTAssertTrue(model.statusMessage.contains(library.locations.eventFolder(for: library.event("stray"), policy: .buffer).path), model.statusMessage)
        let logged = try XCTUnwrap(model.activityLog.first)
        XCTAssertEqual(logged.detail, "DSC00099.ARW")

        // The private folder counts too.
        let held = library.locations.eventFolder(for: library.event("held"), policy: .archiveOnly)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: held.appendingPathComponent("DSC00100.ARW"))
        workspace.deleteEmptyEvent(library.id("held"))
        XCTAssertNotNil(workspace.event(library.id("held")))

        // An event with only Finder metadata, and no catalog rows, deletes.
        let emptyFolder = library.folder("empty")
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        try Data("meta".utf8).write(to: emptyFolder.appendingPathComponent(".DS_Store"))
        workspace.deleteEmptyEvent(library.id("empty"))
        XCTAssertNil(workspace.event(library.id("empty")))
    }
}
