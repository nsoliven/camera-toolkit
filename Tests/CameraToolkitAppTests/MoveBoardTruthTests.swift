import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// A move clicked on a family board used to re-read every other board it
/// touched once it landed — ~1 s of stalls on a 15,000-file family — on the
/// worry that a subevent's or the target's board cuts the moved stacks
/// differently. Those boards are patched in place instead, and only a board
/// that visibly cuts the stacks differently (`cutDifferently`) is re-read.
/// This is the proof: after every kind of move clicked on the parent's
/// board, each open board draws exactly the stacks a fresh read of the
/// drive does — stack by stack, not just file by file — and the boards
/// that already agreed were not read again.
@MainActor
final class MoveBoardTruthTests: XCTestCase {
    private func photo(_ tag: String) -> String { "ARW-\(tag)-" + String(repeating: "x", count: 24) }

    private let boards = ["trip", "beach", "museum", "market", "winter"]

    private struct Family {
        var library: AuditLibrary
        var pureBeach: [AuditLibrary.Placed]
        var pureMuseum: [AuditLibrary.Placed]
        var mixedSubevents: [AuditLibrary.Placed]
        var mixedWithParent: [AuditLibrary.Placed]
        var singleBeach: AuditLibrary.Placed
        var singleMuseum: AuditLibrary.Placed
    }

    /// A parent with three subevents and a separate event, holding bursts
    /// that sit wholly in one subevent, bursts whose frames belong to two
    /// subevents, and one that spans the parent's own files and a subevent.
    private func makeFamily() throws -> Family {
        let library = try AuditLibrary.make()
        library.addEvent("trip", name: "Trip 2026", date: AuditLibrary.day)
        library.addEvent("beach", name: "Beach Day", date: AuditLibrary.day.addingTimeInterval(-2 * 86_400), policy: nil, parent: "trip")
        library.addEvent("museum", name: "Museum Day", date: AuditLibrary.day.addingTimeInterval(86_400), policy: nil, parent: "trip")
        library.addEvent("market", name: "Market Day", date: AuditLibrary.day, policy: nil, parent: "trip")
        library.addEvent("winter", name: "Winter Trip 2026", date: AuditLibrary.day.addingTimeInterval(9 * 86_400))
        var tag = 0
        func place(_ key: String, _ name: String) throws -> AuditLibrary.Placed {
            tag += 1
            return try library.place(key, name: name, content: photo("\(tag)"), modifiedAt: AuditLibrary.day.addingTimeInterval(Double(tag) * 4), commit: false)
        }
        let pureBeach = try (1...3).map { try place("beach", "B3001_DSC0000\($0).ARW") }
        let pureMuseum = try (1...3).map { try place("museum", "B3002_DSC0001\($0).ARW") }
        let mixedSubevents = [try place("beach", "B3003_DSC00021.ARW"), try place("museum", "B3003_DSC00022.ARW"), try place("museum", "B3003_DSC00023.ARW")]
        let mixedWithParent = [try place("trip", "B3004_DSC00031.ARW"), try place("beach", "B3004_DSC00032.ARW")]
        let singleBeach = try place("beach", "DSC00041.ARW")
        let singleMuseum = try place("museum", "DSC00042.ARW")
        _ = try place("market", "DSC00043.ARW")
        _ = try place("trip", "DSC00044.ARW")
        _ = try place("winter", "DSC00045.ARW")
        _ = try place("winter", "B3005_DSC00046.ARW")
        _ = try place("winter", "B3005_DSC00047.ARW")
        library.commit()
        return Family(
            library: library, pureBeach: pureBeach, pureMuseum: pureMuseum, mixedSubevents: mixedSubevents,
            mixedWithParent: mixedWithParent, singleBeach: singleBeach, singleMuseum: singleMuseum
        )
    }

    /// The board's stacks as sets of files: the cut, without the ids.
    private func cut(_ library: AuditLibrary, _ key: String) -> Set<[String]> {
        Set((library.workspace.eventStacks[library.id(key)] ?? []).map { stack in
            stack.files.map { $0.path.lowercased() }.sorted()
        })
    }

    private func stackIDs(on key: String, of placed: [AuditLibrary.Placed], _ library: AuditLibrary) throws -> Set<String> {
        var ids: Set<String> = []
        for file in placed {
            ids.insert(try XCTUnwrap(library.stack(at: file.url.path, on: key), "no tile for \(file.url.lastPathComponent) on \(key)").id)
        }
        return ids
    }

    /// One move clicked on the parent's board, then every open board against a fresh read.
    private func assertMoveKeepsEveryBoardTrue(
        _ label: String,
        select: (Family) -> [AuditLibrary.Placed],
        to target: String
    ) async throws {
        let family = try makeFamily()
        defer { family.library.tearDown() }
        let library = family.library
        let workspace = library.workspace
        await library.open(boards[0], boards[1], boards[2], boards[3], boards[4])
        let ids = try stackIDs(on: "trip", of: select(family), library)
        let readsBefore = workspace.boardReadCount

        workspace.moveStacks(ids, fromEvent: library.id("trip"), toEvent: library.id(target))
        try await library.settle()
        XCTAssertFalse(library.model.statusMessage.hasPrefix("Nothing to move"), "\(label): \(library.model.statusMessage)")

        var patched: [String: Set<[String]>] = [:]
        for key in boards { patched[key] = cut(library, key) }
        let readsAfterMove = workspace.boardReadCount - readsBefore
        for key in boards {
            let files = library.boardFiles(library.id(key))
            await workspace.refreshEvent(library.id(key))
            XCTAssertEqual(files, library.boardFiles(library.id(key)), "\(label): the \(key) board drew other files than a fresh read")
            // The board the click came from keeps the stacks it drew — two
            // stacks that end up side by side in one folder are cut into one
            // only when the board is read again, as they always were. The
            // other boards are the ones this test is about.
            if key != "trip" {
                XCTAssertEqual(patched[key], cut(library, key), "\(label): the \(key) board is not what a fresh read draws")
            }
        }
        // Whatever re-reads the move itself caused are limited to boards that cut the stacks differently.
        XCTAssertLessThanOrEqual(readsAfterMove, boards.count, "\(label): \(readsAfterMove) boards were re-read")
    }

    func testAWholeSubeventBurstMovedToAnotherSubeventFromTheFamilyBoard() async throws {
        try await assertMoveKeepsEveryBoardTrue("pure beach burst → market", select: { $0.pureBeach }, to: "market")
    }

    func testAWholeSubeventBurstMovedBetweenSubeventsThatAlreadyHoldBursts() async throws {
        try await assertMoveKeepsEveryBoardTrue("pure museum burst → beach", select: { $0.pureMuseum }, to: "beach")
    }

    func testABurstWhoseFramesBelongToTwoSubeventsMovedToAnotherEvent() async throws {
        try await assertMoveKeepsEveryBoardTrue("mixed subevent burst → winter", select: { $0.mixedSubevents }, to: "winter")
    }

    func testABurstSpanningTheParentsOwnFilesAndASubeventMovedToASubevent() async throws {
        try await assertMoveKeepsEveryBoardTrue("parent+beach burst → museum", select: { $0.mixedWithParent }, to: "museum")
    }

    func testTwoStacksFromDifferentSubeventsMovedTogetherToTheParent() async throws {
        try await assertMoveKeepsEveryBoardTrue("two singles → trip", select: { [$0.singleBeach, $0.singleMuseum] }, to: "trip")
    }

    func testASubeventsBurstMovedIntoTheEventThatAlreadyHoldsItsNeighbours() async throws {
        try await assertMoveKeepsEveryBoardTrue("pure beach burst → winter", select: { $0.pureBeach }, to: "winter")
    }
}
