import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// Sidebar drag and drop on a temp library: a reorder changes only the
/// order (no file, no NAS rename, no sheet), a nest or un-nest asks first
/// and then moves the event's folder on the same drive with the NAS copy
/// following through its journaled rename, and every refusal changes
/// nothing. Nothing here touches Application Support, `/Volumes` or a NAS.
@MainActor
final class SidebarArrangeTests: XCTestCase {
    private func photo(_ tag: String) -> String { "ARW-\(tag)-" + String(repeating: "x", count: 24) }

    private let day = AuditLibrary.day
    private func days(_ count: Double) -> Date { AuditLibrary.day.addingTimeInterval(count * 86_400) }

    /// Every file on the drive, card and NAS, by path and content.
    private func disk(_ library: AuditLibrary) -> [String] {
        library.diskFiles().map { file in
            file.path.replacingOccurrences(of: library.root.path, with: "") + "#" + String(decoding: file.content, as: UTF8.self)
        }.sorted()
    }

    private func sidebar(_ library: AuditLibrary) -> [String] {
        library.workspace.sidebarEvents.map { String(repeating: "  ", count: $0.depth) + $0.event.name }
    }

    /// Every job, board read and queued NAS rename is done.
    private func settle(_ library: AuditLibrary) async throws {
        try await library.settle()
        if FileManager.default.fileExists(atPath: library.nasRoot.path) {
            try await library.waitUntil(timeout: 30, "the NAS renames never drained") {
                library.workspace.pendingNASRenameCount == 0 && library.workspace.isQuiet
            }
            try await library.settle()
        }
    }

    @discardableResult
    private func putOnNAS(_ library: AuditLibrary, _ assignment: PhotoEventAssignment, in key: String, content: String) throws -> URL {
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        let url = try XCTUnwrap(library.locations.archiveURL(for: assignment, event: library.event(key)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        library.workspace.refreshConnectivity()
        return url
    }

    // MARK: - Reorder

    func testAReorderChangesOnlyTheOrderAsksNothingAndIsUndoable() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026", date: day)
        library.addEvent("beach", name: "Beach Day", date: days(1))
        library.addEvent("hike", name: "Hike", date: days(2))
        _ = try library.place("trip", name: "DSC00001.ARW", content: photo("1"))
        _ = try library.place("beach", name: "DSC00002.ARW", content: photo("2"))
        let workspace = library.workspace
        try await settle(library)
        XCTAssertEqual(sidebar(library), ["Hike", "Beach Day", "Trip 2026"], "date order until a drag")
        let filesBefore = disk(library)
        let assignmentsBefore = library.model.configuration.photoEventAssignments
        let historyBefore = workspace.undoHistory.undoStack.count

        XCTAssertTrue(workspace.canDropSidebarEvent(library.id("trip"), at: .before(library.id("hike"))))
        workspace.dropSidebarEvent(library.id("trip"), at: .before(library.id("hike")))

        XCTAssertNil(workspace.pendingReparent, "a reorder never asks")
        XCTAssertEqual(sidebar(library), ["Trip 2026", "Hike", "Beach Day"])
        XCTAssertEqual(disk(library), filesBefore, "no file moved")
        XCTAssertEqual(library.model.configuration.photoEventAssignments, assignmentsBefore)
        XCTAssertEqual(workspace.pendingNASRenameCount, 0, "no NAS rename was queued")
        XCTAssertFalse(library.model.isBusy, "no job ran")
        XCTAssertTrue(library.model.configuration.savedEvents.allSatisfy { $0.parentEventID == nil })
        XCTAssertEqual(workspace.undoHistory.undoStack.count, historyBefore + 1)
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Reorder Trip 2026")

        // Dropped after a row: lands behind it.
        workspace.dropSidebarEvent(library.id("hike"), at: .after(library.id("beach")))
        XCTAssertEqual(sidebar(library), ["Trip 2026", "Beach Day", "Hike"])

        workspace.undo()
        workspace.undo()
        XCTAssertEqual(sidebar(library), ["Hike", "Beach Day", "Trip 2026"])
        XCTAssertTrue(library.model.configuration.savedEvents.allSatisfy { $0.sidebarOrder == nil }, "back to the unplaced date order")
        workspace.redo()
        XCTAssertEqual(sidebar(library), ["Trip 2026", "Hike", "Beach Day"])
        XCTAssertEqual(disk(library), filesBefore)
    }

    func testMoveUpAndDownStayAmongSiblings() throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026", date: day)
        library.addEvent("one", name: "Day One", date: day, policy: nil, parent: "trip")
        library.addEvent("two", name: "Day Two", date: days(1), policy: nil, parent: "trip")
        library.addEvent("hike", name: "Hike", date: days(3))
        let workspace = library.workspace
        XCTAssertEqual(sidebar(library), ["Hike", "Trip 2026", "  Day Two", "  Day One"])

        XCTAssertFalse(workspace.canMoveEvent(library.id("two"), by: -1), "first in its group")
        XCTAssertFalse(workspace.canMoveEvent(library.id("one"), by: 1), "last in its group")
        workspace.moveEvent(library.id("one"), by: -1)
        XCTAssertEqual(sidebar(library), ["Hike", "Trip 2026", "  Day One", "  Day Two"])
        XCTAssertEqual(library.event("one").parentEventID, library.id("trip"), "Move Up never leaves the parent")
        workspace.moveEvent(library.id("trip"), by: -1)
        XCTAssertEqual(sidebar(library), ["Trip 2026", "  Day One", "  Day Two", "Hike"], "subevents travel with their parent")
        XCTAssertNil(workspace.pendingReparent)
    }

    // MARK: - Nest and un-nest

    func testDroppingOntoAnEventAsksFirstThenNestsItsFolderAndUndoBringsItBack() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026", date: day)
        library.addEvent("beach", name: "Beach Day", date: days(1))
        let first = try library.place("beach", name: "DSC00001.ARW", content: photo("1"))
        _ = try library.place("beach", name: "DSC00002.ARW", content: photo("2"))
        let workspace = library.workspace
        await library.open("trip", "beach")
        try await settle(library)
        let oldFolder = library.locations.eventFolder(for: library.event("beach"), policy: .buffer)
        let before = disk(library)

        XCTAssertTrue(workspace.canDropSidebarEvent(library.id("beach"), at: .into(library.id("trip"))))
        workspace.dropSidebarEvent(library.id("beach"), at: .into(library.id("trip")))
        let request = try XCTUnwrap(workspace.pendingReparent, "a nest asks first")
        XCTAssertEqual(request.eventName, "Beach Day")
        XCTAssertEqual(request.fromTitle, "Top level")
        XCTAssertEqual(request.toTitle, "Trip 2026")
        XCTAssertEqual(request.fileCount, 2)
        XCTAssertEqual(request.subeventCount, 0)
        XCTAssertEqual(request.folderMoves.count, 1)
        XCTAssertTrue(request.folderMoves[0].to.hasSuffix("/" + oldFolder.deletingLastPathComponent().lastPathComponent
            + "/" + library.locations.eventFolder(for: library.event("trip"), policy: .buffer).lastPathComponent
            + "/" + oldFolder.lastPathComponent), request.folderMoves[0].to)
        XCTAssertNil(request.storageNote)
        XCTAssertEqual(disk(library), before, "nothing moves before the confirmation")
        XCTAssertEqual(EventReparentConfirmSheet.title(request), "Move “Beach Day” into Trip 2026?")
        XCTAssertEqual(EventReparentConfirmSheet.holdings(request), "2 files")

        workspace.confirmReparent(request)
        try await settle(library)
        XCTAssertNil(workspace.pendingReparent)
        XCTAssertEqual(library.event("beach").parentEventID, library.id("trip"))
        let newFolder = library.locations.eventFolder(for: library.event("beach"), policy: .buffer)
        XCTAssertEqual(newFolder.deletingLastPathComponent().lastPathComponent,
                       library.locations.eventFolder(for: library.event("trip"), policy: .buffer).lastPathComponent)
        XCTAssertFalse(library.exists(oldFolder.path), "the folder moved, nothing was left behind")
        for assignment in library.assignments("beach") {
            let implied = try XCTUnwrap(library.impliedPath(assignment))
            XCTAssertTrue(library.exists(implied), "the catalog finds \(assignment.relativePath) in the new folder")
        }
        XCTAssertEqual(library.data(newFolder.appendingPathComponent("Originals/Sony A7V/DSC00001.ARW")), Data(photo("1").utf8))
        XCTAssertEqual(Set(disk(library).map { $0.components(separatedBy: "#")[1] }), Set(before.map { $0.components(separatedBy: "#")[1] }),
                       "the same files, none copied or lost")
        XCTAssertEqual(sidebar(library), ["Trip 2026", "  Beach Day"])
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Move Beach Day")
        XCTAssertTrue(library.model.statusMessage.hasPrefix("Moved Beach Day into Trip 2026."), library.model.statusMessage)
        _ = first

        workspace.undo()
        try await settle(library)
        XCTAssertNil(library.event("beach").parentEventID)
        XCTAssertEqual(disk(library), before, "Undo put the folder back")
        XCTAssertEqual(sidebar(library), ["Beach Day", "Trip 2026"])
    }

    func testDroppingASubeventBetweenTopLevelRowsUnNestsAndPlacesIt() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026", date: day)
        library.addEvent("one", name: "Day One", date: day, policy: nil, parent: "trip")
        library.addEvent("hike", name: "Hike", date: days(3))
        _ = try library.place("one", name: "DSC00001.ARW", content: photo("1"))
        let workspace = library.workspace
        try await settle(library)
        let nested = library.locations.eventFolder(for: library.event("one"), policy: .buffer)
        XCTAssertEqual(sidebar(library), ["Hike", "Trip 2026", "  Day One"])

        workspace.dropSidebarEvent(library.id("one"), at: .after(library.id("hike")))
        let request = try XCTUnwrap(workspace.pendingReparent)
        XCTAssertNil(request.newParentID)
        XCTAssertTrue(request.placed)
        XCTAssertEqual(request.placeBefore, library.id("trip"))
        XCTAssertEqual(EventReparentConfirmSheet.title(request), "Move “Day One” to the top level?")

        workspace.confirmReparent(request)
        try await settle(library)
        XCTAssertNil(library.event("one").parentEventID)
        XCTAssertEqual(sidebar(library), ["Hike", "Day One", "Trip 2026"], "it landed where it was dropped")
        let topLevel = library.locations.eventFolder(for: library.event("one"), policy: .buffer)
        XCTAssertEqual(topLevel.deletingLastPathComponent(), library.locations.bufferRoot.appendingPathComponent(topLevel.deletingLastPathComponent().lastPathComponent, isDirectory: true),
                       "back in its normal spot under the year folder")
        XCTAssertFalse(library.exists(nested.path))
        XCTAssertTrue(library.exists(topLevel.appendingPathComponent("Originals/Sony A7V/DSC00001.ARW").path))

        // Nesting it back by a drop onto the row (or Move Into…) is unplaced.
        workspace.requestReparent(library.id("one"), to: library.id("trip"))
        workspace.confirmReparent(try XCTUnwrap(workspace.pendingReparent))
        try await settle(library)
        XCTAssertEqual(library.event("one").parentEventID, library.id("trip"))
        XCTAssertNil(library.event("one").sidebarOrder, "nested by a drop onto the row: it lists by date among its new siblings")
        XCTAssertTrue(library.exists(nested.appendingPathComponent("Originals/Sony A7V/DSC00001.ARW").path))
    }

    func testAFolderAlreadyAtTheNewPlaceRefusesTheMoveAndChangesNothing() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026", date: day)
        library.addEvent("beach", name: "Beach Day", date: days(1))
        _ = try library.place("beach", name: "DSC00001.ARW", content: photo("1"))
        let workspace = library.workspace
        try await settle(library)
        var nested = library.event("beach")
        nested.parentEventID = library.id("trip")
        let occupied = library.locations.eventFolder(for: nested, policy: .buffer)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: occupied.appendingPathComponent("notes.txt"))
        let before = disk(library)
        let history = workspace.undoHistory.undoStack.count

        workspace.requestReparent(library.id("beach"), to: library.id("trip"))
        workspace.confirmReparent(try XCTUnwrap(workspace.pendingReparent))
        try await settle(library)

        XCTAssertNil(library.event("beach").parentEventID, "the event stayed where it was")
        XCTAssertEqual(disk(library), before, "both folders untouched, nothing replaced")
        XCTAssertTrue(library.model.statusMessage.contains("is already there"), library.model.statusMessage)
        XCTAssertEqual(workspace.undoHistory.undoStack.count, history, "nothing to undo")
        XCTAssertEqual(workspace.pendingNASRenameCount, 0)
    }

    func testCyclesAndTooDeepNestingAreRefusedBeforeAnySheet() throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026", date: day)
        library.addEvent("one", name: "Day One", date: day, policy: nil, parent: "trip")
        library.addEvent("hour", name: "Golden Hour", date: day, policy: nil, parent: "one")
        library.addEvent("beach", name: "Beach Day", date: days(1))
        library.addEvent("swim", name: "Swim", date: days(1), policy: nil, parent: "beach")
        let workspace = library.workspace
        let before = library.model.configuration.savedEvents

        XCTAssertFalse(workspace.canDropSidebarEvent(library.id("trip"), at: .into(library.id("trip"))))
        XCTAssertFalse(workspace.canDropSidebarEvent(library.id("trip"), at: .into(library.id("hour"))))
        XCTAssertFalse(workspace.canDropSidebarEvent(library.id("trip"), at: .before(library.id("one"))), "between its own subevents is inside itself")
        XCTAssertFalse(workspace.canDropSidebarEvent(library.id("one"), at: .into(library.id("trip"))), "already there")
        XCTAssertFalse(workspace.canDropSidebarEvent(library.id("beach"), at: .into(library.id("one"))), "Swim would sit 4 levels deep")

        workspace.dropSidebarEvent(library.id("trip"), at: .into(library.id("hour")))
        XCTAssertNil(workspace.pendingReparent)
        XCTAssertTrue(library.model.statusMessage.contains("one of its own subevents"), library.model.statusMessage)

        workspace.requestReparent(library.id("beach"), to: library.id("one"))
        XCTAssertNil(workspace.pendingReparent)
        XCTAssertTrue(library.model.statusMessage.contains("levels deep"), library.model.statusMessage)
        XCTAssertEqual(library.model.configuration.savedEvents, before)

        XCTAssertFalse(workspace.moveIntoTargets(for: library.id("trip")).contains(library.id("hour")))
        XCTAssertFalse(workspace.moveIntoTargets(for: library.id("one")).contains(library.id("trip")), "its own parent is not offered")
        XCTAssertTrue(workspace.moveIntoTargets(for: library.id("beach")).contains(library.id("trip")))
    }

    func testAMoveWaitsForARunningJobEvenOnceTheSheetIsOpen() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026", date: day)
        library.addEvent("beach", name: "Beach Day", date: days(1))
        _ = try library.place("beach", name: "DSC00001.ARW", content: photo("1"))
        let workspace = library.workspace
        let before = disk(library)

        library.model.isStorageBenchmarkRunning = true
        workspace.requestReparent(library.id("beach"), to: library.id("trip"))
        XCTAssertNil(workspace.pendingReparent)
        XCTAssertTrue(library.model.statusMessage.contains("file job"), library.model.statusMessage)
        XCTAssertFalse(workspace.canDropSidebarEvent(library.id("beach"), at: .into(library.id("trip"))))

        library.model.isStorageBenchmarkRunning = false
        workspace.requestReparent(library.id("beach"), to: library.id("trip"))
        let request = try XCTUnwrap(workspace.pendingReparent)
        library.model.isStorageBenchmarkRunning = true
        workspace.confirmReparent(request)
        library.model.isStorageBenchmarkRunning = false
        XCTAssertNil(library.event("beach").parentEventID)
        XCTAssertEqual(disk(library), before)
    }

    // MARK: - NAS

    func testTheNASCopyFollowsANestThroughItsJournaledFolderRenameAndUndo() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026", date: day)
        library.addEvent("beach", name: "Beach Day", date: days(1))
        let file = try library.place("beach", name: "DSC00001.ARW", content: photo("1"))
        let oldNAS = try putOnNAS(library, file.assignment, in: "beach", content: photo("1"))
        let workspace = library.workspace
        await library.open("beach")
        try await settle(library)
        let before = disk(library)

        workspace.requestReparent(library.id("beach"), to: library.id("trip"))
        workspace.confirmReparent(try XCTUnwrap(workspace.pendingReparent))
        try await settle(library)

        let newNAS = try XCTUnwrap(library.locations.archiveURL(for: file.assignment, event: library.event("beach")))
        XCTAssertNotEqual(newNAS.path, oldNAS.path)
        XCTAssertTrue(newNAS.path.contains("/" + library.locations.nasEventFolder(for: library.event("trip")).lastPathComponent + "/"),
                      "the NAS copy now sits inside the parent's NAS folder: \(newNAS.path)")
        XCTAssertEqual(library.data(newNAS), Data(photo("1").utf8), "renamed, not copied")
        XCTAssertFalse(library.exists(oldNAS.path))
        XCTAssertEqual(library.diskFiles().count, before.count, "no copy was made anywhere")

        workspace.undo()
        try await settle(library)
        XCTAssertEqual(disk(library), before, "Undo put the drive folder and the NAS folder back")
    }

    // MARK: - Storage setting

    func testAPrivateSubeventStaysPrivateWhenItLeavesItsPrivateParent() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026", date: day, policy: .archiveOnly)
        library.addEvent("one", name: "Day One", date: day, policy: nil, parent: "trip")
        _ = try library.place("one", name: "DSC00001.ARW", content: photo("1"))
        let workspace = library.workspace
        try await settle(library)
        let nested = library.locations.eventFolder(for: library.event("one"), policy: .archiveOnly)
        XCTAssertTrue(library.exists(nested.path))

        workspace.requestReparent(library.id("one"), to: nil)
        let request = try XCTUnwrap(workspace.pendingReparent)
        XCTAssertEqual(request.storageNote, "Day One stays Private, so none of its files change drives.")
        workspace.confirmReparent(request)
        try await settle(library)

        XCTAssertNil(library.event("one").parentEventID)
        XCTAssertEqual(library.event("one").storagePolicy, .archiveOnly, "pinned to where its files already are")
        let moved = library.locations.eventFolder(for: library.event("one"), policy: .archiveOnly)
        XCTAssertTrue(moved.path.hasPrefix(library.locations.privateStagingRoot.path), "still in private staging")
        XCTAssertTrue(library.exists(moved.appendingPathComponent("Originals/Sony A7V/DSC00001.ARW").path))
        XCTAssertFalse(library.exists(library.locations.eventFolder(for: library.event("one"), policy: .buffer).path), "nothing went to the shared Buffer")
    }

    // MARK: - Tile drops

    func testEventRowPayloadsAndTilePayloadsNeverCross() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("a", name: "Beach Day", date: day)
        library.addEvent("b", name: "Hike", date: days(1))
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let workspace = library.workspace
        await library.open("a", "b")
        try await settle(library)

        let eventPayload = EventsWorkspace.sidebarEventDragPayload(library.id("a"))
        XCTAssertEqual(EventsWorkspace.sidebarEventID(fromDragPayload: eventPayload), library.id("a"))
        XCTAssertNil(OrganizeDragPayload.decode(eventPayload))
        XCTAssertFalse(workspace.handleDrop([eventPayload], onto: library.id("b")), "an event row is never sorted as photos")

        workspace.draggingSidebarEventID = library.id("a")
        let stack = try XCTUnwrap(library.stack(at: file.url.path, on: "a"))
        let tilePayload = workspace.dragPayload(for: stack.id, origin: .event, containerID: library.id("a"))
        XCTAssertNil(workspace.draggingSidebarEventID, "a tile drag is drawn as a tile drag")
        XCTAssertNil(EventsWorkspace.sidebarEventID(fromDragPayload: tilePayload))
        XCTAssertTrue(workspace.handleDrop([tilePayload], onto: library.id("b")))
        try await settle(library)
        XCTAssertEqual(library.assignments("b").count, 1, "photos dropped on an event still move there")
        XCTAssertNil(library.event("a").parentEventID)
    }

    func testDropZonesSplitARowIntoBeforeInsideAndAfter() {
        XCTAssertEqual(SidebarRowDropZone.zone(atY: 1, height: 24), .top)
        XCTAssertEqual(SidebarRowDropZone.zone(atY: 12, height: 24), .middle)
        XCTAssertEqual(SidebarRowDropZone.zone(atY: 23, height: 24), .bottom)
        XCTAssertEqual(SidebarRowDropZone.zone(atY: 5, height: 0), .middle)
        let id = UUID()
        XCTAssertEqual(SidebarRowDropZone.top.spot(on: id), .before(id))
        XCTAssertEqual(SidebarRowDropZone.middle.spot(on: id), .into(id))
        XCTAssertEqual(SidebarRowDropZone.bottom.spot(on: id), .after(id))
    }
}
