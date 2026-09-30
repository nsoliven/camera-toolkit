import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// Parks the first presence stat of a sweep until released — the stand-in for
/// a storage strip that still says "Checking…".
final class ParkedSweep: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var _parked = false
    private var _armed = true

    var isParked: Bool { lock.withLock { _parked } }

    var probe: EventPresenceScanner.PresenceProbe {
        { [self] url, size, mounted in
            let park = lock.withLock { () -> Bool in
                guard _armed else { return false }
                _armed = false
                _parked = true
                return true
            }
            if park { _ = gate.wait(timeout: .now() + 60) }
            return EventPresenceScanner.state(url, size: size, mounted: mounted)
        }
    }

    func release() { gate.signal() }
}

/// The move that would not run: a photo sitting in a subevent of the open
/// family board, moved to another subevent that already holds an identical
/// copy — clicked while the board was still "Checking…".
@MainActor
final class MoveFamilyBoardTests: XCTestCase {
    private struct Birthday {
        var library: AuditLibrary
        var birthday: AuditLibrary.Placed
        var hangout: AuditLibrary.Placed
        var burst: AuditLibrary.Placed
        var card: PhotoEventAssignment
        var census: [Data: Int]
    }

    /// 21 bytes of "photo": same length, different picture when the tag differs.
    private func photo(_ tag: String) -> String { "ARW-\(tag)-" + String(repeating: "x", count: 24) }

    /// The reported catalog: one photo in a subevent of the family and, as an
    /// identical copy, in a private sibling whose `source_root_path` is a
    /// folder that no longer exists; unrelated photos share its number.
    private func makeBirthday() throws -> Birthday {
        let library = try AuditLibrary.make()
        library.addEvent("trip", name: "Trip 2026", date: AuditLibrary.day)
        library.addEvent("birthday", name: "Jordan's 90th Birthday", date: AuditLibrary.day.addingTimeInterval(-2 * 86_400), policy: nil, parent: "trip")
        library.addEvent("hangout", name: "Alex&Sam Private Hangout", date: AuditLibrary.day.addingTimeInterval(86_400), policy: .archiveOnly, parent: "trip")
        library.addEvent("nano", name: "Nano", date: AuditLibrary.day, policy: nil, parent: "trip")
        library.addEvent("other", name: "Beach Trip 2026", date: AuditLibrary.day.addingTimeInterval(9 * 86_400))
        let modified = AuditLibrary.day.addingTimeInterval(500)
        let birthday = try library.place("birthday", name: "DSC08729.ARW", content: photo("A"), modifiedAt: modified)
        let hangout = try library.place(
            "hangout", name: "DSC08729.ARW", content: photo("A"),
            sourceRoot: library.drive.appendingPathComponent("Jordan's 90th Birthday").path, modifiedAt: modified
        )
        let burst = try library.place("trip", name: "B1037_DSC08729.ARW", content: photo("B"), modifiedAt: modified.addingTimeInterval(60))
        let card = library.assignWithoutFile("other", name: "DSC08729.ARW", size: Int64(photo("C").utf8.count), sourceRoot: library.card.path)
        return Birthday(library: library, birthday: birthday, hangout: hangout, burst: burst, card: card, census: library.contentCensus())
    }

    private func assertMerged(_ state: Birthday, file: StaticString = #filePath, line: UInt = #line) throws {
        let library = state.library
        // The private copy is the one that stays; the spare from the Buffer is in Trash.
        XCTAssertEqual(library.data(state.hangout.url), Data(photo("A").utf8), file: file, line: line)
        XCTAssertFalse(library.exists(state.birthday.url.path), "the Buffer spare left its folder", file: file, line: line)
        XCTAssertEqual(library.trashedNames(), ["DSC08729.ARW"], file: file, line: line)
        XCTAssertEqual(library.assignments("birthday").count, 0, "the birthday assignment is gone", file: file, line: line)
        XCTAssertEqual(library.assignments("hangout"), [state.hangout.assignment], "the private assignment is untouched", file: file, line: line)
        // The photos that only share the number never move.
        XCTAssertTrue(library.exists(state.burst.url.path), file: file, line: line)
        XCTAssertEqual(library.assignments("trip"), [state.burst.assignment], file: file, line: line)
        XCTAssertEqual(library.assignments("other"), [state.card], file: file, line: line)
        XCTAssertEqual(library.contentCensus(), state.census, "no photo was lost or overwritten", file: file, line: line)
    }

    func testMoveFromTheFamilyBoardWhileCheckingMergesTheSubeventsCopy() async throws {
        let state = try makeBirthday()
        defer { state.library.tearDown() }
        let library = state.library
        let workspace = library.workspace
        let sweep = ParkedSweep()
        defer { sweep.release() }
        workspace.presenceProbe = sweep.probe

        let refresh = Task { await workspace.refreshEvent(library.id("trip")) }
        try await library.waitUntil("board never reached Checking") {
            sweep.isParked && (workspace.eventStacks[library.id("trip")]?.flatMap(\.files).count ?? 0) >= 3
        }
        XCTAssertNil(workspace.presence[library.id("trip")], "still Checking")
        let tile = try XCTUnwrap(library.stack(at: state.birthday.url.path, on: "trip"))

        workspace.moveStacks([tile.id], fromEvent: library.id("trip"), toEvent: library.id("hangout"))
        XCTAssertFalse(model(library).statusMessage.hasPrefix("Nothing to move"), model(library).statusMessage)
        XCTAssertTrue(model(library).isBusy, "the move is a running job")
        // The tile leaves the birthday board's count at once, on the click.
        XCTAssertEqual(workspace.assignmentCount(for: library.id("birthday")), 0)

        sweep.release()
        await refresh.value
        try await library.settle()
        try assertMerged(state)
        XCTAssertTrue(model(library).statusMessage.contains("already in"), model(library).statusMessage)
        XCTAssertEqual(workspace.assignmentCount(for: library.id("trip")), 2)
    }

    func testMoveFromTheFamilyBoardAfterCheckingMergesTheSubeventsCopy() async throws {
        let state = try makeBirthday()
        defer { state.library.tearDown() }
        let library = state.library
        await library.open("trip")
        XCTAssertNotNil(library.workspace.presence[library.id("trip")])
        let tile = try XCTUnwrap(library.stack(at: state.birthday.url.path, on: "trip"))

        library.workspace.moveStacks([tile.id], fromEvent: library.id("trip"), toEvent: library.id("hangout"))
        try await library.settle()
        try assertMerged(state)
        XCTAssertTrue(model(library).statusMessage.contains("already in"), model(library).statusMessage)
        // The family board no longer draws the spare's tile; the private copy's stays.
        let files = library.boardFiles(library.id("trip"))
        XCTAssertFalse(files.contains(state.birthday.url.path.lowercased()))
        XCTAssertTrue(files.contains(state.hangout.url.path.lowercased()))
        XCTAssertEqual(library.workspace.assignmentCount(for: library.id("trip")), 2)
        XCTAssertEqual(library.workspace.assignmentCount(for: library.id("birthday")), 0)
    }

    /// A refused click leaves its reason and the file names in the activity log.
    func testARefusedClickIsLoggedWithTheReasonAndTheFileNames() async throws {
        let state = try makeBirthday()
        defer { state.library.tearDown() }
        let library = state.library
        await library.open("trip", "hangout")
        let tile = try XCTUnwrap(library.stack(at: state.hangout.url.path, on: "hangout"))

        // The private copy already lives in the target.
        library.workspace.moveStacks([tile.id], fromEvent: library.id("hangout"), toEvent: library.id("hangout"))
        XCTAssertTrue(model(library).statusMessage.contains("already in"), model(library).statusMessage)
        let entry = try XCTUnwrap(model(library).activityLog.first)
        XCTAssertEqual(entry.state, .failed)
        XCTAssertTrue(entry.title.contains("nothing moved"), entry.title)
        XCTAssertEqual(entry.summary, model(library).statusMessage)
        XCTAssertEqual(entry.detail, "DSC08729.ARW")
        // …and it is on disk, in the permanent log.
        let saved = try ActivityLogStore(url: URL(fileURLWithPath: model(library).configuration.activityLogPath)).load()
        XCTAssertEqual(saved.first?.detail, "DSC08729.ARW")
    }

    /// A subevent's photo moved to its own parent from the family board — the
    /// board is the parent, and so is the target, yet the file must move.
    func testASubeventsPhotoMovesToItsParentFromTheFamilyBoard() async throws {
        let state = try makeBirthday()
        defer { state.library.tearDown() }
        let library = state.library
        let single = try library.place("birthday", name: "DSC00001.ARW", content: photo("D"))
        await library.open("trip", "birthday")
        let tile = try XCTUnwrap(library.stack(at: single.url.path, on: "trip"))

        library.workspace.moveStacks([tile.id], fromEvent: library.id("trip"), toEvent: library.id("trip"))
        try await library.settle()
        let landed = library.folder("trip").appendingPathComponent("DSC00001.ARW")
        XCTAssertEqual(library.data(landed), Data(photo("D").utf8))
        XCTAssertFalse(library.exists(single.url.path))
        XCTAssertEqual(library.assignments("trip").map(\.relativePath).sorted(), ["B1037_DSC08729.ARW", "DSC00001.ARW"])
        XCTAssertEqual(library.assignments("birthday").map(\.relativePath), ["DSC08729.ARW"])
        // The parent's own photo, moved onto the parent, stays and says why.
        let own = try XCTUnwrap(library.stack(at: state.burst.url.path, on: "trip"))
        library.workspace.moveStacks([own.id], fromEvent: library.id("trip"), toEvent: library.id("trip"))
        XCTAssertTrue(model(library).statusMessage.contains("already in"), model(library).statusMessage)
        XCTAssertTrue(library.exists(state.burst.url.path))
    }

    /// Every board that shows the photo follows it, and counts add up per scope.
    func testAFamilyBoardMoveUpdatesTheSubeventBoardsAndCounts() async throws {
        let state = try makeBirthday()
        defer { state.library.tearDown() }
        let library = state.library
        let single = try library.place("birthday", name: "DSC00002.ARW", content: photo("E"))
        await library.open("trip", "birthday", "hangout", "nano")
        let workspace = library.workspace
        let tile = try XCTUnwrap(library.stack(at: single.url.path, on: "trip"))

        workspace.moveStacks([tile.id], fromEvent: library.id("trip"), toEvent: library.id("nano"))
        try await library.settle()
        let landed = library.folder("nano").appendingPathComponent("DSC00002.ARW")
        XCTAssertEqual(library.data(landed), Data(photo("E").utf8))
        XCTAssertNil(library.stack(at: single.url.path, on: "birthday"))
        XCTAssertNotNil(library.stack(at: landed.path, on: "nano"))
        XCTAssertNotNil(library.stack(at: landed.path, on: "trip"), "the family board still holds it, at its new path")
        XCTAssertEqual(workspace.assignmentCount(for: library.id("birthday")), 1)
        XCTAssertEqual(workspace.assignmentCount(for: library.id("nano")), 1)
        XCTAssertEqual(workspace.assignmentCount(for: library.id("trip")), 4)
        // What the boards hold is what a fresh read of the drive finds.
        for key in ["trip", "birthday", "hangout", "nano"] {
            let before = library.boardFiles(library.id(key))
            await workspace.refreshEvent(library.id(key))
            XCTAssertEqual(library.boardFiles(library.id(key)), before, key)
        }
    }

    /// A subevent chip switched off after tiles were selected: the hidden
    /// subevent's tiles stay put, the visible ones move, and dropping the
    /// selection on a sidebar row goes through the same rule.
    func testTilesHiddenByASubeventChipAreNotMovedWithTheVisibleSelection() async throws {
        let state = try makeBirthday()
        defer { state.library.tearDown() }
        let library = state.library
        let workspace = library.workspace
        let visible = try library.place("birthday", name: "DSC00050.ARW", content: photo("V"))
        let hidden = try library.place("nano", name: "DSC00051.ARW", content: photo("H"))
        await library.open("trip")
        let visibleTile = try XCTUnwrap(library.stack(at: visible.url.path, on: "trip"))
        let hiddenTile = try XCTUnwrap(library.stack(at: hidden.url.path, on: "trip"))
        workspace.selectStacks([visibleTile.id, hiddenTile.id])
        workspace.search.excludedEventIDs = [library.id("nano")]

        let payload = workspace.dragPayload(for: visibleTile.id, origin: .event, containerID: library.id("trip"))
        XCTAssertTrue(workspace.handleDrop([payload], onto: library.id("other")))
        try await library.settle()
        XCTAssertEqual(library.assignments("other").map(\.relativePath).sorted(), ["DSC00050.ARW", "DSC08729.ARW"])
        XCTAssertEqual(library.assignments("nano"), [hidden.assignment], "the hidden subevent's tile did not move")
        XCTAssertTrue(library.exists(hidden.url.path))
    }

    private func model(_ library: AuditLibrary) -> DashboardModel { library.model }
}
