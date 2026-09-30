import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// The move audit's edge cases, one deterministic scenario each: what the
/// user sees, the catalog, and the drive must agree after every one.
@MainActor
final class MoveAuditTests: XCTestCase {
    private func photo(_ tag: String) -> String { "ARW-\(tag)-" + String(repeating: "x", count: 24) }

    private func twoEvents(_ library: AuditLibrary) {
        library.addEvent("a", name: "Beach Day", date: AuditLibrary.day)
        library.addEvent("b", name: "Hotel Night", date: AuditLibrary.day.addingTimeInterval(86_400))
    }

    private func click(_ library: AuditLibrary, _ paths: [String], from: String, to: String) throws {
        let stacks = try paths.map { try XCTUnwrap(library.stack(at: $0, on: from), $0) }
        library.workspace.moveStacks(Set(stacks.map(\.id)), fromEvent: library.id(from), toEvent: library.id(to))
    }

    /// Takes the newest entry off the history, as if that change had been made
    /// by something that does not register one (an older build, a Finder
    /// rename) — the entries below it then meet a world they did not expect.
    private func forgetNewestUndo(_ library: AuditLibrary) {
        if let newest = library.workspace.undoHistory.nextUndo {
            library.workspace.undoHistory.remove(newest.id)
        }
    }

    // MARK: - Undo

    /// Two files move; one name is taken again before Undo. The file that
    /// could not go back keeps its new assignment (so it still has one that
    /// points at where it is), the other returns, the journal stays open, and
    /// a second Undo finishes the job once the name is free.
    func testUndoAfterAPartialFailureSwapsBackOnlyTheFilesThatWentBack() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let first = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let second = try library.place("a", name: "DSC00002.ARW", content: photo("2"))
        await library.open("a", "b")
        try click(library, [first.url.path, second.url.path], from: "a", to: "b")
        try await library.settle()
        XCTAssertEqual(library.assignments("b").count, 2)
        let census = library.contentCensus()

        // A new photo takes the first name in Beach Day's folder.
        try FileManager.default.createDirectory(at: first.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(photo("Z").utf8).write(to: first.url)
        library.workspace.undoLastMove()
        try await library.settle()
        XCTAssertEqual(library.assignments("a").map(\.relativePath), ["DSC00002.ARW"], "only the file that went back is in Beach Day again")
        XCTAssertEqual(library.assignments("b").map(\.relativePath), ["DSC00001.ARW"], "the file that could not go back keeps pointing at Hotel Night")
        XCTAssertTrue(library.exists(second.url.path))
        XCTAssertTrue(library.exists(library.folder("b").appendingPathComponent("DSC00001.ARW").path))
        XCTAssertEqual(library.data(first.url), Data(photo("Z").utf8), "nothing was replaced")
        XCTAssertTrue(library.model.statusMessage.contains("1 could not move back"), library.model.statusMessage)
        XCTAssertNotNil(library.workspace.latestMoveJournalTitle, "Undo can be tried again for the one left")
        XCTAssertTrue(library.model.activityLog.contains { $0.title.contains("stayed") && $0.detail.contains("DSC00001.ARW") })
        for assignment in library.model.configuration.photoEventAssignments {
            XCTAssertTrue(library.exists(library.impliedPath(assignment) ?? ""), "\(assignment.relativePath) is where its assignment says")
        }

        // The name is free again: Undo finishes.
        try FileManager.default.removeItem(at: first.url)
        library.workspace.undoLastMove()
        try await library.settle()
        XCTAssertEqual(Set(library.assignments("a").map(\.relativePath)), ["DSC00001.ARW", "DSC00002.ARW"])
        XCTAssertTrue(library.assignments("b").isEmpty)
        XCTAssertEqual(library.data(first.url), Data(photo("1").utf8))
        XCTAssertNil(library.workspace.latestMoveJournalTitle)
        XCTAssertEqual(library.contentCensus(), census)
    }

    /// A move whose journal never recorded a rename (a crash, a pulled cable)
    /// is still an Undo: the file is at its destination and gone from its source.
    func testUndoFindsRenamesTheJournalNeverRecorded() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a", "b")
        try click(library, [file.url.path], from: "a", to: "b")
        try await library.settle()
        let journalURL = try XCTUnwrap(DriveMoveService.journals(in: library.workspace.journalFolder).first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        json["completedIndices"] = [Int]()
        try JSONSerialization.data(withJSONObject: json).write(to: journalURL)
        XCTAssertNotNil(DriveMoveService.latestUndoableJournal(in: library.workspace.journalFolder))

        library.workspace.undoLastMove()
        try await library.settle()
        XCTAssertTrue(library.exists(file.url.path))
        XCTAssertEqual(library.assignments("a").count, 1)
        XCTAssertTrue(library.assignments("b").isEmpty)
    }

    /// Undo with a drive missing refuses and keeps the journal.
    func testUndoRefusesWhileADriveIsAwayAndKeepsTheJournal() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        let ghost = "/Volumes/AuditGhost-\(UUID().uuidString)"
        let journals = library.workspace.journalFolder
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        let journal: [String: Any] = [
            "id": UUID().uuidString, "title": "Move to Ghost", "createdAt": "2026-09-01T10:00:00Z",
            "moves": [["sourcePath": "\(ghost)/A/DSC1.ARW", "destinationPath": "\(ghost)/B/DSC1.ARW", "byteCount": 3]],
            "completedIndices": [0], "removedAssignments": [], "addedAssignments": [],
        ]
        let url = journals.appendingPathComponent("20260901-100000-000001-abcd1234.json")
        try JSONSerialization.data(withJSONObject: journal).write(to: url)
        library.workspace.refreshLatestJournal()
        XCTAssertEqual(library.workspace.latestMoveJournalTitle, "Move to Ghost")

        library.workspace.undoLastMove()
        XCTAssertTrue(library.model.statusMessage.contains("isn't connected"), library.model.statusMessage)
        XCTAssertFalse(library.model.isBusy)
        XCTAssertNotNil(DriveMoveService.latestUndoableJournal(in: journals), "nothing was spent")
    }

    // MARK: - Renames

    func testRenameRefusesWhileAMoveIsQueuedBehindAJob() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a", "b")
        library.model.isStorageBenchmarkRunning = true
        try click(library, [file.url.path], from: "a", to: "b")
        XCTAssertTrue(library.model.statusMessage.contains("queued behind"), library.model.statusMessage)

        library.workspace.renameEvent(library.id("b"), name: "Hotel Nights", date: AuditLibrary.day, policy: .buffer, parentEventID: nil)
        XCTAssertEqual(library.event("b").name, "Hotel Night", "the destination folder is not moved from under a queued move")
        XCTAssertTrue(library.model.statusMessage.contains("Rename"), library.model.statusMessage)

        library.model.isStorageBenchmarkRunning = false
        try await library.settle()
        XCTAssertEqual(library.assignments("b").count, 1)
        library.workspace.renameEvent(library.id("b"), name: "Hotel Nights", date: AuditLibrary.day.addingTimeInterval(86_400), policy: .buffer, parentEventID: nil)
        XCTAssertEqual(library.event("b").name, "Hotel Nights")
        try await library.settle()
        for assignment in library.model.configuration.photoEventAssignments {
            XCTAssertTrue(library.exists(library.impliedPath(assignment) ?? ""))
        }
    }

    func testRenameRefusesWhileTheEventsDriveIsAway() async throws {
        let ghost = "/Volumes/AuditGhost-\(UUID().uuidString)/Camera Buffer"
        let library = try AuditLibrary.make(bufferPath: ghost)
        defer { library.tearDown() }
        library.addEvent("a", name: "Beach Day")
        library.workspace.renameEvent(library.id("a"), name: "Beach Days", date: AuditLibrary.day, policy: .buffer, parentEventID: nil)
        XCTAssertEqual(library.event("a").name, "Beach Day")
        XCTAssertTrue(library.model.statusMessage.contains("isn't connected"), library.model.statusMessage)
        XCTAssertEqual(library.model.activityLog.first?.state, .failed)
    }

    // MARK: - Names

    /// "Café" written two ways is one name to the volume; it must also be one
    /// name to the catalog, or a merge adopts a second row for one file.
    func testNamesMatchAcrossUnicodeCompositionAndCase() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let composed = "Caf\u{00E9}.ARW"
        let decomposed = "Cafe\u{0301}.ARW"
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8), "two spellings of one name")
        let incoming = try library.place("a", name: decomposed, content: photo("1"))
        let existing = try library.place("b", name: composed, content: photo("1"))
        let upper = try library.place("a", name: "DSC00007.ARW", content: photo("2"))
        let lower = try library.place("b", name: "dsc00007.arw", content: photo("3"))
        await library.open("a", "b")
        let census = library.contentCensus()

        try click(library, [incoming.url.path, upper.url.path], from: "a", to: "b")
        try await library.settle()
        // Identical bytes: merged, the target's row is the only one for that file.
        XCTAssertEqual(library.assignments("b").count, 3, "café once, dsc00007 twice")
        XCTAssertEqual(Set(library.assignments("b").map(\.relativePath)), [composed, "dsc00007.arw", "DSC00007 (2).ARW"])
        XCTAssertFalse(library.exists(incoming.url.path))
        XCTAssertTrue(library.exists(existing.url.path))
        // The different photo with a case-only different name is kept, not replaced.
        XCTAssertEqual(library.data(lower.url), Data(photo("3").utf8))
        XCTAssertEqual(library.data(library.folder("b").appendingPathComponent("DSC00007 (2).ARW")), Data(photo("2").utf8))
        XCTAssertTrue(library.assignments("a").isEmpty)
        XCTAssertEqual(library.contentCensus(), census)
        _ = upper
    }

    // MARK: - Sidecars

    /// Cataloged sidecars, a Sony clip's XML and the `._` twin travel with the
    /// photo; Finder metadata is left where it is.
    func testSidecarsAndAppleDoubleTravelWithThePhoto() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let raw = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let xmp = try library.place("a", name: "DSC00001.xmp", content: "<xmp/>")
        let clip = try library.place("a", name: "C0001.MP4", content: photo("v"))
        let xml = try library.place("a", name: "C0001M01.XML", content: "<xml/>")
        let lrf = try library.place("a", name: "C0001.LRF", content: "lrf")
        let appleDouble = raw.url.deletingLastPathComponent().appendingPathComponent("._DSC00001.ARW")
        try Data("appledouble".utf8).write(to: appleDouble)
        let finder = raw.url.deletingLastPathComponent().appendingPathComponent(".DS_Store")
        try Data("finder".utf8).write(to: finder)
        await library.open("a", "b")

        try click(library, [raw.url.path, clip.url.path], from: "a", to: "b")
        try await library.settle()
        let target = library.folder("b")
        for name in ["DSC00001.ARW", "DSC00001.xmp", "C0001.MP4", "C0001M01.XML", "C0001.LRF", "._DSC00001.ARW"] {
            XCTAssertTrue(library.exists(target.appendingPathComponent(name).path), name)
        }
        XCTAssertEqual(library.assignments("b").count, 5)
        XCTAssertTrue(library.assignments("a").isEmpty)
        // Only Finder metadata was left in the emptied folder, and it goes with it.
        XCTAssertFalse(library.exists(finder.deletingLastPathComponent().path))
        for placed in [raw, xmp, clip, xml, lrf] { XCTAssertFalse(library.exists(placed.url.path)) }
    }

    /// A different clip with the same number: the clip and its XML take the
    /// same "(2)" so the pair still pairs.
    func testAClipAndItsXMLKeepBothTogether() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let clip = try library.place("a", name: "C0167.MP4", content: photo("v"))
        let xml = try library.place("a", name: "C0167M01.XML", content: "<xml a/>")
        let theirClip = try library.place("b", name: "C0167.MP4", content: photo("w"))
        let theirXML = try library.place("b", name: "C0167M01.XML", content: "<xml b/>")
        await library.open("a", "b")
        let census = library.contentCensus()

        try click(library, [clip.url.path], from: "a", to: "b")
        try await library.settle()
        let target = library.folder("b")
        XCTAssertEqual(library.data(target.appendingPathComponent("C0167 (2).MP4")), Data(photo("v").utf8))
        XCTAssertEqual(library.data(target.appendingPathComponent("C0167 (2)M01.XML")), Data("<xml a/>".utf8))
        XCTAssertEqual(library.data(theirClip.url), Data(photo("w").utf8))
        XCTAssertEqual(library.data(theirXML.url), Data("<xml b/>".utf8))
        XCTAssertFalse(library.exists(xml.url.path))
        XCTAssertEqual(library.contentCensus(), census)
        XCTAssertEqual(library.assignments("b").count, 4)
        // The renamed pair is one stack on the board again.
        await library.workspace.refreshEvent(library.id("b"))
        let stack = try XCTUnwrap(library.stack(at: target.appendingPathComponent("C0167 (2).MP4").path, on: "b"))
        XCTAssertTrue(stack.files.contains { $0.name == "C0167 (2)M01.XML" })
    }

    // MARK: - Files that are not where the catalog says

    func testAFileMissingFromTheDriveButInTheCatalogStaysAndSaysWhy() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let gone = try library.place("a", name: "DSC00002.ARW", content: photo("2"))
        await library.open("a", "b")
        let stacks = try [file, gone].map { try XCTUnwrap(library.stack(at: $0.url.path, on: "a")) }
        try FileManager.default.removeItem(at: gone.url)

        library.workspace.moveStacks(Set(stacks.map(\.id)), fromEvent: library.id("a"), toEvent: library.id("b"))
        try await library.settle()
        XCTAssertEqual(library.assignments("b").map(\.relativePath), ["DSC00001.ARW"])
        XCTAssertEqual(library.assignments("a"), [gone.assignment], "the missing file's row stays where it was")
        let line = library.model.statusMessage
        XCTAssertTrue(line.contains("1 stayed in Beach Day"), line)
        XCTAssertTrue(line.contains("no longer"), line)
        let logged = try XCTUnwrap(library.model.activityLog.first { $0.title.contains("stayed") })
        XCTAssertTrue(logged.detail.contains("DSC00002.ARW"), logged.detail)
        // The board tells the truth: the missing file has no tile after a re-read.
        await library.workspace.refreshEvent(library.id("a"))
        XCTAssertNil(library.stack(at: gone.url.path, on: "a"))
    }

    func testAFileOnDiskButNotInTheCatalogIsNeverTouched() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let stray = file.url.deletingLastPathComponent().appendingPathComponent("DSC00099.ARW")
        try Data(photo("s").utf8).write(to: stray)
        await library.open("a", "b")
        XCTAssertNil(library.stack(at: stray.path, on: "a"), "the board only draws what the catalog owns")

        try click(library, [file.url.path], from: "a", to: "b")
        try await library.settle()
        XCTAssertEqual(library.data(stray), Data(photo("s").utf8))
        XCTAssertTrue(library.exists(library.folder("b").appendingPathComponent("DSC00001.ARW").path))
    }

    /// The destination cannot be written (a drive that went read-only): every
    /// file stays, the catalog does not change, the board is put right, and the
    /// reason is named — nothing is half-moved.
    func testAnUnwritableDestinationLeavesEverythingWhereItWas() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let target = library.folder("b")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
        await library.open("a", "b")
        let census = library.contentCensus()

        try click(library, [file.url.path], from: "a", to: "b")
        try await library.settle()
        XCTAssertTrue(library.exists(file.url.path))
        XCTAssertEqual(library.assignments("a"), [file.assignment])
        XCTAssertTrue(library.assignments("b").isEmpty)
        XCTAssertTrue(library.model.statusMessage.contains("stayed in Beach Day"), library.model.statusMessage)
        XCTAssertEqual(library.contentCensus(), census)
        XCTAssertNotNil(library.stack(at: file.url.path, on: "a"))
        XCTAssertEqual(library.workspace.assignmentCount(for: library.id("a")), 1)
        XCTAssertEqual(library.workspace.assignmentCount(for: library.id("b")), 0)
        XCTAssertNil(library.workspace.latestMoveJournalTitle)
    }

    // MARK: - Queued behind a job, quit before it runs

    func testAQueuedMoveChangesNothingOnDiskUntilItRuns() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a", "b")
        library.model.isStorageBenchmarkRunning = true
        try click(library, [file.url.path], from: "a", to: "b")
        XCTAssertEqual(library.workspace.assignmentCount(for: library.id("a")), 0, "the board already shows it gone")

        // The app quits here: what a relaunch reads is the catalog on disk.
        library.model.flushConfigurationSave()
        let onDisk = try ConfigurationStore(url: library.root.appendingPathComponent("CameraToolkit/config.json")).load(defaults: library.model.configuration)
        XCTAssertEqual(onDisk.photoEventAssignments, [file.assignment])
        XCTAssertTrue(library.exists(file.url.path))
        XCTAssertTrue(DriveMoveService.journals(in: library.workspace.journalFolder).isEmpty)
        library.model.isStorageBenchmarkRunning = false
        try await library.settle()
    }

    // MARK: - Bursts, families, and returns

    /// A burst and a frame of the same numbering that belong to two
    /// subevents, moved together from the family board: each leaves its own
    /// event, and every board agrees with a fresh read.
    func testABurstWhoseFramesBelongToDifferentEventsMovesFromTheFamilyBoard() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026")
        library.addEvent("beach", name: "Beach Day", date: AuditLibrary.day, policy: nil, parent: "trip")
        library.addEvent("city", name: "City Weekend", date: AuditLibrary.day.addingTimeInterval(86_400), policy: nil, parent: "trip")
        library.addEvent("nano", name: "Nano", date: AuditLibrary.day.addingTimeInterval(2 * 86_400), policy: nil, parent: "trip")
        let stamp = AuditLibrary.day.addingTimeInterval(100)
        let one = try library.place("beach", name: "B0007_DSC00001.ARW", content: photo("1"), modifiedAt: stamp)
        let two = try library.place("beach", name: "B0007_DSC00002.ARW", content: photo("2"), modifiedAt: stamp.addingTimeInterval(1))
        let three = try library.place("city", name: "B0007_DSC00003.ARW", content: photo("3"), modifiedAt: stamp.addingTimeInterval(2))
        await library.open("trip", "beach", "city", "nano")
        // Frames of one burst number, cut into stacks by the event folder they sit in.
        let beachBurst = try XCTUnwrap(library.stack(at: one.url.path, on: "trip"))
        let cityFrame = try XCTUnwrap(library.stack(at: three.url.path, on: "trip"))
        XCTAssertEqual(beachBurst.files.count + cityFrame.files.count, 3)
        let census = library.contentCensus()

        library.workspace.moveStacks([beachBurst.id, cityFrame.id], fromEvent: library.id("trip"), toEvent: library.id("nano"))
        try await library.settle()
        XCTAssertEqual(library.assignments("nano").count, 3)
        XCTAssertTrue(library.assignments("beach").isEmpty)
        XCTAssertTrue(library.assignments("city").isEmpty)
        for placed in [one, two, three] {
            XCTAssertFalse(library.exists(placed.url.path))
            XCTAssertTrue(library.exists(library.folder("nano").appendingPathComponent(placed.assignment.relativePath).path))
        }
        XCTAssertEqual(library.contentCensus(), census)
        for key in ["trip", "beach", "city", "nano"] {
            let before = library.boardFiles(library.id(key))
            await library.workspace.refreshEvent(library.id(key))
            XCTAssertEqual(library.boardFiles(library.id(key)), before, "\(key)'s board is what a fresh read finds")
        }
        // Undo puts every frame back in its own event.
        library.workspace.undoLastMove()
        try await library.settle()
        XCTAssertEqual(library.assignments("beach").count, 2)
        XCTAssertEqual(library.assignments("city").count, 1)
        XCTAssertTrue(library.exists(three.url.path))
    }

    /// Return to Unsorted from the family board: each file goes back to its
    /// own folder, whichever subevent held it.
    func testReturnToUnsortedFromTheFamilyBoardReturnsSubeventFiles() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026")
        library.addEvent("beach", name: "Beach Day", date: AuditLibrary.day, policy: nil, parent: "trip")
        let unsorted = library.drive.appendingPathComponent("Unsorted A7V")
        try FileManager.default.createDirectory(at: unsorted, withIntermediateDirectories: true)
        let file = try library.place("beach", name: "DSC00001.ARW", content: photo("1"), sourceRoot: unsorted.path)
        await library.open("trip", "beach")
        let tile = try XCTUnwrap(library.stack(at: file.url.path, on: "trip"))

        library.workspace.returnToUnsorted([tile.id], eventID: library.id("trip"))
        try await library.settle()
        XCTAssertEqual(library.data(unsorted.appendingPathComponent("DSC00001.ARW")), Data(photo("1").utf8))
        XCTAssertFalse(library.exists(file.url.path))
        XCTAssertTrue(library.assignments("beach").isEmpty)
        XCTAssertNil(library.stack(at: file.url.path, on: "beach"))

        library.workspace.undoLastMove()
        try await library.settle()
        XCTAssertTrue(library.exists(file.url.path))
        XCTAssertEqual(library.assignments("beach"), [file.assignment])
    }

    // MARK: - Size

    /// A thousand-plus files in one click, with names that collide in the
    /// target: one job, one journal, nothing lost.
    func testAThousandFilesMoveInOneClick() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        var paths: [String] = []
        for index in 0..<1_200 {
            let name = String(format: "DSC%05d.ARW", index)
            paths.append(try library.place("a", name: name, content: "ARW-\(index)-" + String(repeating: "y", count: 12), commit: false).url.path)
        }
        // Every 50th name is already in the target: half identical, half different.
        for index in stride(from: 0, to: 1_200, by: 50) {
            let name = String(format: "DSC%05d.ARW", index)
            let same = index % 100 == 0
            try library.place("b", name: name, content: same ? "ARW-\(index)-" + String(repeating: "y", count: 12) : "ARW-other-\(index)-" + String(repeating: "z", count: 8), commit: false)
        }
        library.commit()
        await library.open("a", "b")
        let census = library.contentCensus()
        let stacks = try paths.map { try XCTUnwrap(library.stack(at: $0, on: "a")) }

        library.workspace.moveStacks(Set(stacks.map(\.id)), fromEvent: library.id("a"), toEvent: library.id("b"))
        try await library.settle(timeout: 120)
        XCTAssertTrue(library.assignments("a").isEmpty)
        XCTAssertEqual(library.assignments("b").count, 1_200 + 12, "the 12 different photos with taken names are kept beside the originals")
        XCTAssertEqual(library.trashedNames().count, 12, "the 12 identical copies were merged; their spares are in Trash")
        XCTAssertEqual(library.contentCensus(), census)
        for assignment in library.model.configuration.photoEventAssignments {
            XCTAssertTrue(library.exists(library.impliedPath(assignment) ?? ""), assignment.relativePath)
        }
        XCTAssertEqual(library.workspace.assignmentCount(for: library.id("b")), 1_212)
    }

    // MARK: - Files only the NAS has

    /// A photo taken off the drive (Free Up) lives only on the NAS. Moving it
    /// between events must take its NAS copy along, or the board loses it.
    func testAPhotoOnlyTheNASHasMovesWithItsNASCopy() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let nas = library.nasRoot
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        let only = try library.placeOnNASOnly("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a", "b")
        XCTAssertNotNil(library.stack(at: only.url.path, on: "a"), "the board draws the NAS copy")

        try click(library, [only.url.path], from: "a", to: "b")
        try await library.settle()
        XCTAssertEqual(library.assignments("b").count, 1)
        let moved = try XCTUnwrap(library.locations.archiveURL(for: library.assignments("b")[0], event: library.event("b")))
        // Queued while the NAS was connected: a NAS Rename job may still be running.
        try await library.waitUntil(timeout: 20, "the NAS copy never followed") { library.exists(moved.path) && !library.exists(only.url.path) }
        try await library.settle()
        await library.open("b")
        XCTAssertNotNil(library.stack(at: moved.path, on: "b"), "the target board draws it at its new NAS path")
        XCTAssertEqual(library.data(moved), Data(photo("1").utf8))

        // Undo of a catalog-only move takes the NAS copy back too.
        library.workspace.undoLastSort()
        try await library.settle()
        try await library.waitUntil(timeout: 20, "the NAS copy never came back") { library.exists(only.url.path) && !library.exists(moved.path) }
        try await library.settle()
        XCTAssertEqual(library.assignments("a"), [only.assignment])
    }

    // MARK: - Return to Unsorted edge cases

    /// A photo whose card is not plugged in, and one only the NAS has, are
    /// left where they are with a sentence each — never a bare "nothing".
    func testReturnToUnsortedExplainsACardThatIsAwayAndAPhotoOnlyTheNASHas() async throws {
        let ghost = "/Volumes/AuditGhost-\(UUID().uuidString)/DCIM"
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        let fromCard = try library.place("a", name: "DSC00001.ARW", content: photo("1"), sourceRoot: ghost)
        let nasOnly = try library.placeOnNASOnly("a", name: "DSC00002.ARW", content: photo("2"))
        library.workspace.refreshConnectivity()
        await library.open("a")
        let stacks = [try XCTUnwrap(library.stack(at: fromCard.url.path, on: "a")), try XCTUnwrap(library.stack(at: nasOnly.url.path, on: "a"))]

        library.workspace.returnToUnsorted(Set(stacks.map(\.id)), eventID: library.id("a"))
        try await library.settle()
        XCTAssertEqual(Set(library.assignments("a").map(\.relativePath)), ["DSC00001.ARW", "DSC00002.ARW"], "neither was returned")
        XCTAssertTrue(library.exists(fromCard.url.path))
        XCTAssertTrue(library.exists(nasOnly.url.path))
        let line = library.model.statusMessage
        XCTAssertTrue(line.contains("isn't connected"), line)
        XCTAssertTrue(line.contains("only on the NAS"), line)
        XCTAssertEqual(library.model.activityLog.first?.state, .failed)
        XCTAssertEqual(Set(library.model.activityLog.first?.detail.split(separator: "\n").map(String.init) ?? []), ["DSC00001.ARW", "DSC00002.ARW"])
    }

    // MARK: - Undo after an event changed

    /// The event a move left was renamed since — by something the history
    /// does not know (an older build, Finder): undoing would recreate the old
    /// folder and drop the file into it while the event looks in the new one.
    /// The move stays in the history, and nothing is recreated.
    func testUndoAfterTheSourceEventWasRenamedRefusesAndRecreatesNothing() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a", "b")
        try click(library, [file.url.path], from: "a", to: "b")
        try await library.settle()
        let oldFolder = library.locations.eventFolder(for: library.event("a"), policy: .buffer)
        XCTAssertNotNil(library.workspace.latestMoveJournalTitle)

        library.workspace.renameEvent(library.id("a"), name: "Beach Days", date: AuditLibrary.day, policy: .buffer, parentEventID: nil)
        try await library.settle()
        forgetNewestUndo(library)
        library.workspace.undo()
        try await library.settle()
        XCTAssertTrue(library.model.statusMessage.contains("was renamed or moved since"), library.model.statusMessage)
        XCTAssertFalse(library.exists(oldFolder.path), "the old folder was not recreated")
        XCTAssertEqual(library.assignments("b").map(\.relativePath), ["DSC00001.ARW"])
        XCTAssertTrue(library.assignments("a").isEmpty)
        XCTAssertEqual(library.workspace.latestMoveJournalTitle, "Move to Hotel Night", "the move is still there to undo once the rename is undone — it is not abandoned")
        XCTAssertTrue(library.exists(library.folder("b").appendingPathComponent("DSC00001.ARW").path))
    }

    /// The same sequence with the rename made here: it is the newest entry,
    /// so it is the first thing ⌘Z takes back; the second ⌘Z takes back the
    /// move — nothing was abandoned on the way.
    func testUndoingARenameThenTheMoveBeforeItReturnsBothWithoutAbandoningTheMove() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a", "b")
        try click(library, [file.url.path], from: "a", to: "b")
        try await library.settle()

        library.workspace.renameEvent(library.id("a"), name: "Beach Days", date: AuditLibrary.day, policy: .buffer, parentEventID: nil)
        try await library.settle()
        XCTAssertEqual(library.workspace.undoMenuTitle, "Undo Rename Beach Day")

        library.workspace.undo()
        try await library.settle()
        XCTAssertEqual(library.event("a").name, "Beach Day")
        XCTAssertEqual(library.workspace.undoMenuTitle, "Undo Move to Hotel Night (1 file)")

        library.workspace.undo()
        try await library.settle()
        XCTAssertEqual(library.assignments("a").map(\.relativePath), ["DSC00001.ARW"])
        XCTAssertTrue(library.assignments("b").isEmpty)
        XCTAssertTrue(library.exists(file.url.path), "the file is back where it started")
        XCTAssertFalse(library.workspace.canUndo)
        XCTAssertEqual(library.workspace.redoMenuTitle, "Redo Move to Hotel Night (1 file)")
    }

    /// Undoing a move into an event that was deleted since would put entries
    /// into an event that no longer exists.
    func testUndoAfterAnEventWasDeletedRefusesInsteadOfOrphaningEntries() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a", "b")
        try click(library, [file.url.path], from: "a", to: "b")
        try await library.settle()
        library.workspace.deleteEmptyEvent(library.id("a"))
        XCTAssertNil(library.workspace.event(library.id("a")), "Beach Day is empty now, so it deletes")
        forgetNewestUndo(library)

        library.workspace.undo()
        try await library.settle()
        XCTAssertTrue(library.model.statusMessage.contains("was deleted since"), library.model.statusMessage)
        XCTAssertNil(library.workspace.latestMoveJournalTitle, "it can never run, so it stops standing in front of older changes")
        XCTAssertEqual(library.model.configuration.photoEventAssignments.count, 1)
        XCTAssertEqual(library.assignments("b").map(\.relativePath), ["DSC00001.ARW"])
        for assignment in library.model.configuration.photoEventAssignments {
            XCTAssertNotNil(library.workspace.event(assignment.eventID), "no orphaned entry")
        }
    }

    /// A photo only the NAS has moved between events; the target event is
    /// renamed (its NAS folder follows); undoing the move would rename the NAS
    /// copy back under the old folder name, away from where the event looks.
    func testUndoingAMoveOfAPhotoOnlyTheNASHasAfterARenameRefuses() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        let only = try library.placeOnNASOnly("a", name: "DSC00001.ARW", content: photo("1"))
        library.workspace.refreshConnectivity()
        await library.open("a", "b")
        try click(library, [only.url.path], from: "a", to: "b")
        try await library.settle()
        try await library.waitUntil(timeout: 20, "the NAS copy never followed") { library.workspace.isQuiet && library.workspace.pendingNASRenameCount == 0 }

        library.workspace.renameEvent(library.id("b"), name: "Hotel Nights", date: AuditLibrary.day.addingTimeInterval(86_400), policy: .buffer, parentEventID: nil)
        let renamedCopy = try nasCopy(library, of: library.assignments("b")[0], in: "b")
        try await library.waitUntil(timeout: 20, "the NAS folder never followed") { library.exists(renamedCopy.path) }
        try await library.settle()
        forgetNewestUndo(library)

        library.workspace.undo()
        try await library.settle()
        XCTAssertTrue(library.model.statusMessage.contains("was renamed or moved since"), library.model.statusMessage)
        XCTAssertEqual(library.assignments("b").count, 1)
        XCTAssertTrue(library.exists(renamedCopy.path))
        XCTAssertFalse(library.exists(only.url.path), "nothing was recreated under the old name")
    }

    /// Renaming a subevent moves its folder; the family board above it must
    /// draw the files at their new paths.
    func testRenamingASubeventUpdatesTheFamilyBoard() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026")
        library.addEvent("beach", name: "Beach Day", date: AuditLibrary.day.addingTimeInterval(86_400), policy: nil, parent: "trip")
        let file = try library.place("beach", name: "DSC00001.ARW", content: photo("1"))
        await library.open("trip", "beach")
        XCTAssertNotNil(library.stack(at: file.url.path, on: "trip"))

        library.workspace.renameEvent(library.id("beach"), name: "Beach Day Two", date: AuditLibrary.day.addingTimeInterval(86_400), policy: nil, parentEventID: library.id("trip"))
        try await library.settle()
        let landed = library.folder("beach").appendingPathComponent("DSC00001.ARW")
        XCTAssertTrue(library.exists(landed.path))
        XCTAssertNotNil(library.stack(at: landed.path, on: "trip"), "the parent's board follows the renamed folder")
        XCTAssertNil(library.stack(at: file.url.path, on: "trip"))
    }

    // MARK: - Event renames

    /// "Beach Day" → "BEACH DAY" is one folder to the volume: the folder must
    /// still be renamed, so the drive spells the name as the app does.
    func testACaseOnlyEventRenameRenamesTheFolder() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a")
        let oldFolder = library.locations.eventFolder(for: library.event("a"), policy: .buffer)

        library.workspace.renameEvent(library.id("a"), name: "BEACH DAY", date: AuditLibrary.day, policy: .buffer, parentEventID: nil)
        try await library.settle()
        XCTAssertEqual(library.event("a").name, "BEACH DAY")
        let names = try FileManager.default.contentsOfDirectory(atPath: oldFolder.deletingLastPathComponent().path)
        XCTAssertTrue(names.contains { $0.hasSuffix("BEACH DAY") }, "\(names)")
        XCTAssertFalse(names.contains { $0.hasSuffix("Beach Day") }, "\(names)")
        XCTAssertTrue(library.exists(library.impliedPath(file.assignment) ?? ""))
        XCTAssertNotNil(library.stack(at: library.folder("a").appendingPathComponent("DSC00001.ARW").path, on: "a"))
    }

    /// Moving an event under a parent and back: every file follows, the
    /// family boards agree, and nothing is orphaned.
    func testReparentingAnEventMovesItsFolderAndUpdatesTheFamilyBoard() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026")
        library.addEvent("beach", name: "Beach Day", date: AuditLibrary.day.addingTimeInterval(86_400))
        let file = try library.place("beach", name: "DSC00001.ARW", content: photo("1"))
        await library.open("trip", "beach")
        XCTAssertNil(library.stack(at: file.url.path, on: "trip"))

        library.workspace.renameEvent(library.id("beach"), name: "Beach Day", date: AuditLibrary.day.addingTimeInterval(86_400), policy: .buffer, parentEventID: library.id("trip"))
        try await library.settle()
        XCTAssertEqual(library.event("beach").parentEventID, library.id("trip"))
        let landed = library.folder("beach").appendingPathComponent("DSC00001.ARW")
        XCTAssertTrue(library.exists(landed.path))
        XCTAssertFalse(library.exists(file.url.path))
        XCTAssertNotNil(library.stack(at: landed.path, on: "trip"), "the new parent's board draws it")
        XCTAssertNotNil(library.stack(at: landed.path, on: "beach"))
        XCTAssertEqual(library.workspace.assignmentCount(for: library.id("trip")), 1)

        library.workspace.renameEvent(library.id("beach"), name: "Beach Day", date: AuditLibrary.day.addingTimeInterval(86_400), policy: .buffer, parentEventID: nil)
        try await library.settle()
        XCTAssertNil(library.stack(at: landed.path, on: "trip"))
        XCTAssertNotNil(library.stack(at: file.url.path, on: "beach"))
        XCTAssertEqual(library.workspace.assignmentCount(for: library.id("trip")), 0)
    }

    // MARK: - Sorting from a card, Apply, and their undo

    private func cardLibrary() async throws -> (AuditLibrary, ConfiguredLocation, URL) {
        let library = try AuditLibrary.make()
        twoEvents(library)
        try FileManager.default.createDirectory(at: library.card, withIntermediateDirectories: true)
        let photo = library.card.appendingPathComponent("DSC00001.ARW")
        try Data(self.photo("c").utf8).write(to: photo)
        try FileManager.default.setAttributes([.modificationDate: AuditLibrary.day.addingTimeInterval(60)], ofItemAtPath: photo.path)
        let location = ConfiguredLocation(role: .importSource, name: "Card", path: library.card.path, deviceID: "sony-a7v")
        library.model.updateConfiguration { $0.configuredLocations.append(location) }
        library.workspace.scan(location)
        try await library.waitUntil("the card never scanned") { library.workspace.sources[location.id]?.result != nil }
        return (library, location, photo)
    }

    /// Apply refused because another job holds the gate: nothing moved, the
    /// plan is still there to Apply again, and the click left a log line.
    func testApplyWhileAJobRunsKeepsThePlanAndMovesNothing() async throws {
        let (library, location, photo) = try await cardLibrary()
        defer { library.tearDown() }
        let workspace = library.workspace
        let result = try XCTUnwrap(workspace.sources[location.id]?.result)
        workspace.assign(stackIDs: Set(result.stacks.map(\.id)), from: location.id, to: library.id("a"))
        workspace.prepareApply(sourceLocationID: location.id)
        try await library.waitUntil("the plan never appeared") { workspace.pendingApplyPlan != nil }
        let plan = try XCTUnwrap(workspace.pendingApplyPlan)
        XCTAssertGreaterThan(plan.moveCount + plan.copyCount, 0)

        library.model.isStorageBenchmarkRunning = true
        workspace.performApply(plan)
        XCTAssertNotNil(workspace.pendingApplyPlan, "the plan stays open")
        XCTAssertTrue(library.exists(photo.path))
        XCTAssertTrue(library.model.statusMessage.contains("nothing was moved"), library.model.statusMessage)
        XCTAssertEqual(library.model.activityLog.first?.state, .failed)

        library.model.isStorageBenchmarkRunning = false
        workspace.performApply(plan)
        try await library.settle()
        XCTAssertFalse(library.exists(photo.path))
        XCTAssertTrue(library.exists(library.folder("a").appendingPathComponent("DSC00001.ARW").path))
    }

    /// Sort, Apply, then undo the sort: the file already sits in the event's
    /// folder, so its catalog entry stays — undoing would leave a photo in the
    /// folder that nothing records.
    func testUndoingASortAfterApplyKeepsTheEntryOfAFileNowInTheEventFolder() async throws {
        let (library, location, photo) = try await cardLibrary()
        defer { library.tearDown() }
        let workspace = library.workspace
        let result = try XCTUnwrap(workspace.sources[location.id]?.result)
        workspace.assign(stackIDs: Set(result.stacks.map(\.id)), from: location.id, to: library.id("a"))
        workspace.prepareApply(sourceLocationID: location.id)
        try await library.waitUntil("the plan never appeared") { workspace.pendingApplyPlan != nil }
        workspace.performApply(try XCTUnwrap(workspace.pendingApplyPlan))
        try await library.settle()
        let landed = library.folder("a").appendingPathComponent("DSC00001.ARW")
        XCTAssertTrue(library.exists(landed.path))
        XCTAssertFalse(library.exists(photo.path))

        // Something that does not register (an older build's Apply) sits on
        // top: the Apply's entry is not in the history, so the sort is next.
        forgetNewestUndo(library)
        workspace.undo()
        XCTAssertEqual(library.assignments("a").count, 1, "the entry stays")
        XCTAssertTrue(library.model.statusMessage.contains("Return to Unsorted"), library.model.statusMessage)
        XCTAssertTrue(library.exists(landed.path))
    }

    /// The same sequence in order: the first ⌘Z takes the Apply back (the
    /// file returns to the card), the second takes the sort back.
    func testUndoingAnApplyThenItsSortWorksInOrder() async throws {
        let (library, location, photo) = try await cardLibrary()
        defer { library.tearDown() }
        let workspace = library.workspace
        let result = try XCTUnwrap(workspace.sources[location.id]?.result)
        workspace.assign(stackIDs: Set(result.stacks.map(\.id)), from: location.id, to: library.id("a"))
        workspace.prepareApply(sourceLocationID: location.id)
        try await library.waitUntil("the plan never appeared") { workspace.pendingApplyPlan != nil }
        workspace.performApply(try XCTUnwrap(workspace.pendingApplyPlan))
        try await library.settle()
        let landed = library.folder("a").appendingPathComponent("DSC00001.ARW")
        XCTAssertTrue(library.exists(landed.path))

        workspace.undo()
        try await library.settle()
        XCTAssertTrue(library.exists(photo.path), "the Apply's rename went back")
        XCTAssertEqual(library.assignments("a").count, 1, "the sort is still there")
        workspace.undo()
        try await library.settle()
        XCTAssertTrue(library.assignments("a").isEmpty, "then the sort")
        XCTAssertTrue(library.exists(photo.path))
    }

    // MARK: - Trash from an event

    /// A file the Trash cannot take (its drive is read-only) keeps its event.
    func testTrashKeepsTheEntryOfAFileThatStayedInPlace() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let stays = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let goes = try library.place("a", name: "DSC00002.ARW", content: photo("2"))
        await library.open("a")
        let items = try XCTUnwrap(library.workspace.eventStacks[library.id("a")]).flatMap(\.items)
        // The Trash is refused for one of them: it is no longer where the board saw it.
        try FileManager.default.removeItem(at: stays.url)

        library.workspace.trashItems(items, fromEvent: library.id("a"))
        try await library.settle()
        XCTAssertEqual(library.assignments("a"), [stays.assignment], "only the file that reached Trash lost its entry")
        XCTAssertEqual(library.trashedNames(), ["DSC00002.ARW"])
        XCTAssertFalse(library.exists(goes.url.path))
    }

    // MARK: - NAS renames, queued and undone

    private func nasCopy(_ library: AuditLibrary, of assignment: PhotoEventAssignment, in key: String) throws -> URL {
        try XCTUnwrap(library.locations.archiveURL(for: assignment, event: library.event(key)))
    }

    /// Two moves while the NAS is away, then the NAS mounts with the copy still
    /// at the first path: the queue applies in order and the copy ends where
    /// the drive file ended.
    func testAChainOfMovesWhileTheNASIsAwayEndsWithTheCopyAtTheFinalPath() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        library.addEvent("c", name: "Sunset Walk", date: AuditLibrary.day.addingTimeInterval(2 * 86_400))
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a", "b", "c")
        XCTAssertFalse(library.exists(library.nasRoot.path))

        try click(library, [file.url.path], from: "a", to: "b")
        try await library.settle()
        let inB = library.folder("b").appendingPathComponent("DSC00001.ARW")
        try click(library, [inB.path], from: "b", to: "c")
        try await library.settle()
        let inC = library.folder("c").appendingPathComponent("DSC00001.ARW")
        XCTAssertTrue(library.exists(inC.path))
        XCTAssertEqual(library.workspace.pendingNASRenameCount, 2, "both renames wait for the NAS")

        // The NAS comes back with its copy where the file started.
        let atA = try nasCopy(library, of: file.assignment, in: "a")
        try FileManager.default.createDirectory(at: atA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(photo("1").utf8).write(to: atA)
        library.workspace.refreshConnectivity()
        try await library.waitUntil(timeout: 20, "the queue never drained") { library.workspace.pendingNASRenameCount == 0 && library.workspace.isQuiet }
        var moved = library.assignments("c")[0]
        moved.relativePath = "DSC00001.ARW"
        let atC = try nasCopy(library, of: moved, in: "c")
        XCTAssertEqual(library.data(atC), Data(photo("1").utf8))
        XCTAssertFalse(library.exists(atA.path), "no copy left at the first path")
        XCTAssertFalse(library.exists(try nasCopy(library, of: moved, in: "b").path), "none at the middle one")
    }

    /// One drive file cannot go back on Undo. The NAS copy of the file that
    /// did go back returns; the other stays with its drive file.
    func testUndoAfterAPartialFailureReversesOnlyTheNASCopiesOfFilesThatWentBack() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let one = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let two = try library.place("a", name: "DSC00002.ARW", content: photo("2"))
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        for placed in [one, two] {
            let copy = try nasCopy(library, of: placed.assignment, in: "a")
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: placed.url).write(to: copy)
        }
        library.workspace.refreshConnectivity()
        await library.open("a", "b")

        try click(library, [one.url.path, two.url.path], from: "a", to: "b")
        try await library.waitUntil(timeout: 20, "the NAS never followed") { library.workspace.isQuiet && library.workspace.pendingNASRenameCount == 0 }
        func nas(_ placed: AuditLibrary.Placed, _ key: String) throws -> URL {
            var assignment = placed.assignment
            assignment.eventID = library.id(key)
            return try nasCopy(library, of: assignment, in: key)
        }
        XCTAssertTrue(library.exists(try nas(one, "b").path))
        XCTAssertTrue(library.exists(try nas(two, "b").path))

        // A new photo takes the first name in Beach Day's folder.
        try FileManager.default.createDirectory(at: one.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(photo("Z").utf8).write(to: one.url)
        library.workspace.undoLastMove()
        try await library.waitUntil(timeout: 20, "the undo never finished") { library.workspace.isQuiet && library.workspace.pendingNASRenameCount == 0 }
        XCTAssertTrue(library.exists(try nas(two, "a").path), "the file that went back has its NAS copy back")
        XCTAssertFalse(library.exists(try nas(two, "b").path))
        XCTAssertTrue(library.exists(try nas(one, "b").path), "the file that stayed keeps its NAS copy beside it")
        XCTAssertFalse(library.exists(try nas(one, "a").path))

        try FileManager.default.removeItem(at: one.url)
        library.workspace.undoLastMove()
        try await library.waitUntil(timeout: 20, "the second undo never finished") { library.workspace.isQuiet && library.workspace.pendingNASRenameCount == 0 }
        XCTAssertTrue(library.exists(try nas(one, "a").path))
        XCTAssertFalse(library.exists(try nas(one, "b").path))
    }

    // MARK: - Boards after a catalog-only move and its undo

    /// A card's photo (not on the drive) moved between two events and back:
    /// the family board draws it throughout, at the card path.
    func testACardPhotoMovedAndUndoneStaysOnTheFamilyBoard() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026")
        library.addEvent("beach", name: "Beach Day", date: AuditLibrary.day, policy: nil, parent: "trip")
        let card = try library.place("trip", name: "CARD_1.ARW", content: photo("c"), onDrive: false)
        await library.open("trip", "beach")
        let tile = try XCTUnwrap(library.stack(at: card.url.path, on: "trip"))

        library.workspace.moveStacks([tile.id], fromEvent: library.id("trip"), toEvent: library.id("beach"))
        try await library.settle()
        XCTAssertEqual(library.assignments("beach").count, 1)
        XCTAssertNotNil(library.stack(at: card.url.path, on: "trip"))
        XCTAssertNotNil(library.stack(at: card.url.path, on: "beach"))
        XCTAssertTrue(library.exists(card.url.path), "the card file is not touched")

        library.workspace.undoLastSort()
        try await library.settle()
        XCTAssertEqual(library.assignments("trip"), [card.assignment])
        XCTAssertNotNil(library.stack(at: card.url.path, on: "trip"), "the family board still draws it")
        XCTAssertNil(library.stack(at: card.url.path, on: "beach"))
    }

    /// A card's photo moves from a top-level event down into a subevent three
    /// levels below it: every board in between draws it once it arrives.
    func testACardPhotoMovedDownAFamilyAppearsOnTheBoardsBetween() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("solo", name: "Solo Day")
        library.addEvent("trip", name: "Trip", date: AuditLibrary.day.addingTimeInterval(86_400), policy: nil, parent: "solo")
        library.addEvent("city", name: "City Weekend", date: AuditLibrary.day.addingTimeInterval(2 * 86_400), policy: nil, parent: "trip")
        library.addEvent("beach", name: "Beach Day", date: AuditLibrary.day.addingTimeInterval(3 * 86_400), policy: nil, parent: "city")
        let one = try library.place("solo", name: "CARD_0.ARW", content: photo("c0"), onDrive: false)
        let two = try library.place("solo", name: "CARD_2.ARW", content: photo("c2"), onDrive: false)
        await library.open("solo", "trip", "city", "beach")

        try click(library, [one.url.path, two.url.path], from: "solo", to: "beach")
        try await library.settle()
        XCTAssertEqual(library.assignments("beach").count, 2)
        for key in ["solo", "trip", "city", "beach"] {
            XCTAssertNotNil(library.stack(at: one.url.path, on: key), "\(key) draws CARD_0")
            XCTAssertNotNil(library.stack(at: two.url.path, on: key), "\(key) draws CARD_2")
            let before = library.boardFiles(library.id(key))
            await library.workspace.refreshEvent(library.id(key))
            XCTAssertEqual(library.boardFiles(library.id(key)), before, key)
        }
    }

    /// One click moves a photo owned by the top-level event and one owned by a
    /// subevent into another subevent: the middle board already drew the
    /// second and must gain the first — decided per file, not per board.
    func testAClickWithOwnersInsideAndOutsideABoardsFamilyUpdatesThatBoardPerFile() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("solo", name: "Solo Day")
        library.addEvent("trip", name: "Trip", date: AuditLibrary.day.addingTimeInterval(86_400), policy: nil, parent: "solo")
        library.addEvent("city", name: "City Weekend", date: AuditLibrary.day.addingTimeInterval(2 * 86_400), policy: nil, parent: "trip")
        library.addEvent("beach", name: "Beach Day", date: AuditLibrary.day.addingTimeInterval(3 * 86_400), policy: nil, parent: "trip")
        let outside = try library.place("solo", name: "DSC00001.ARW", content: photo("o"))
        let inside = try library.place("city", name: "DSC00002.ARW", content: photo("i"))
        await library.open("solo", "trip", "city", "beach")
        XCTAssertNil(library.stack(at: outside.url.path, on: "trip"))

        try click(library, [outside.url.path, inside.url.path], from: "solo", to: "beach")
        // At once, on the click: the middle board has both, city lost its own.
        XCTAssertNotNil(library.stack(at: outside.url.path, on: "trip"), "the family board gains the top-level event's photo")
        XCTAssertNotNil(library.stack(at: inside.url.path, on: "trip"), "and keeps the subevent's until it lands")
        XCTAssertNil(library.stack(at: inside.url.path, on: "city"))
        try await library.settle()
        XCTAssertEqual(library.assignments("beach").count, 2)
        for key in ["solo", "trip", "city", "beach"] {
            let before = library.boardFiles(library.id(key))
            await library.workspace.refreshEvent(library.id(key))
            XCTAssertEqual(library.boardFiles(library.id(key)), before, key)
        }
    }

    /// A board is re-read (a click on the sidebar, a mount) while a clicked
    /// move waits behind a job: the re-read draws the files where the catalog
    /// still has them, so the board is read again when the move lands.
    func testABoardReadWhileAMoveIsQueuedIsReadAgainWhenTheMoveLands() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a", "b")
        library.model.isStorageBenchmarkRunning = true
        try click(library, [file.url.path], from: "a", to: "b")
        XCTAssertNil(library.stack(at: file.url.path, on: "a"))
        await library.open("a")
        XCTAssertNotNil(library.stack(at: file.url.path, on: "a"), "the re-read drew it where the catalog still has it")

        library.model.isStorageBenchmarkRunning = false
        try await library.settle()
        let landed = library.folder("b").appendingPathComponent("DSC00001.ARW").path
        XCTAssertNil(library.stack(at: file.url.path, on: "a"))
        XCTAssertNil(library.stack(at: landed, on: "a"), "and not at its new path either: it is Hotel Night's now")
        XCTAssertNotNil(library.stack(at: landed, on: "b"))
    }

    /// Undoing an older move after a later one took the same file elsewhere
    /// must not put a second assignment back for it.
    func testUndoingAnOlderMoveDoesNotAssignAFileThatMovedAgainASecondTime() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        library.addEvent("c", name: "Sunset Walk", date: AuditLibrary.day.addingTimeInterval(2 * 86_400))
        let card = try library.place("a", name: "CARD_1.ARW", content: photo("c"), onDrive: false)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a", "b", "c")
        // One click, two kinds of move: a rename on the drive and a catalog-only move.
        try click(library, [card.url.path, file.url.path], from: "a", to: "b")
        try await library.settle()
        XCTAssertEqual(library.assignments("b").count, 2)
        // The card photo moves on to Sunset Walk (catalog-only, its own undo).
        try click(library, [card.url.path], from: "b", to: "c")
        try await library.settle()
        XCTAssertEqual(library.assignments("c").map(\.relativePath), ["CARD_1.ARW"])

        // Undo the first move with the second missing from the history: its
        // rename goes back, but its catalog-only entry for the card photo is
        // not put back — the photo moved on since and would be assigned twice.
        forgetNewestUndo(library)
        library.workspace.undo()
        try await library.settle()
        let owners = library.model.configuration.photoEventAssignments.filter { $0.relativePath == "CARD_1.ARW" }
        XCTAssertEqual(owners.count, 1, "the card photo is assigned once: \(owners.map { library.key(of: $0.eventID) })")
        XCTAssertEqual(owners.first?.eventID, library.id("c"))
        XCTAssertEqual(library.assignments("a").map(\.relativePath), ["DSC00001.ARW"])
        XCTAssertTrue(library.exists(file.url.path))
    }

    // MARK: - The catalog on disk

    /// What a relaunch reads from the SQLite catalog is what the app shows,
    /// after a merge, a rename move, an undo and a return.
    func testTheCatalogOnDiskAgreesAfterMovesUndoAndReturn() async throws {
        let library = try AuditLibrary.make(catalogBacked: true)
        defer { library.tearDown() }
        twoEvents(library)
        let same = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        _ = try library.place("b", name: "DSC00001.ARW", content: photo("1"))
        let other = try library.place("a", name: "DSC00002.ARW", content: photo("2"))
        await library.open("a", "b")
        func ids(_ assignments: [PhotoEventAssignment]) -> Set<String> { Set(assignments.map(CatalogStore.eventAssetID)) }
        func waitForDisk(_ message: String) async throws {
            try await library.waitUntil(timeout: 20, message) { ids(library.assignmentsOnDisk()) == ids(library.model.configuration.photoEventAssignments) }
        }

        try click(library, [same.url.path, other.url.path], from: "a", to: "b")
        try await library.settle()
        try await waitForDisk("the merge never reached the catalog")
        XCTAssertEqual(library.assignments("b").count, 2)

        library.workspace.undo()
        try await library.settle()
        try await waitForDisk("the undo never reached the catalog")
        XCTAssertEqual(
            library.assignments("a").map(\.relativePath).sorted(), ["DSC00001.ARW", "DSC00002.ARW"],
            "Undo brings the merged copy back too: its entry, and the spare copy out of Trash"
        )
        XCTAssertTrue(library.exists(same.url.path))

        await library.open("a")
        let tile = try XCTUnwrap(library.stack(at: other.url.path, on: "a"))
        library.workspace.returnToUnsorted([tile.id], eventID: library.id("a"))
        try await library.settle()
        try await waitForDisk("the return never reached the catalog")
        XCTAssertEqual(library.assignments("a").map(\.relativePath), ["DSC00001.ARW"])
    }

    /// Two clicks queued behind one job, each bringing a file of the same name
    /// into the target: the second finds the name taken by the first when it
    /// runs, decides by content, and never adds a second entry for one file.
    func testTwoQueuedMovesBringingOneNameIntoATargetMergeInsteadOfDuplicating() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        library.addEvent("c", name: "Sunset Walk", date: AuditLibrary.day.addingTimeInterval(2 * 86_400))
        let first = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let second = try library.place("c", name: "DSC00001.ARW", content: photo("1"))
        let different = try library.place("a", name: "DSC00002.ARW", content: photo("2"))
        let other = try library.place("c", name: "DSC00002.ARW", content: photo("3"))
        await library.open("a", "b", "c")
        let census = library.contentCensus()

        library.model.isStorageBenchmarkRunning = true
        try click(library, [first.url.path, different.url.path], from: "a", to: "b")
        try click(library, [second.url.path, other.url.path], from: "c", to: "b")
        library.model.isStorageBenchmarkRunning = false
        try await library.settle()

        let rows = library.assignments("b").map(\.relativePath).sorted()
        XCTAssertEqual(rows, ["DSC00001.ARW", "DSC00002 (2).ARW", "DSC00002.ARW"], "one photo once; the two different ones side by side")
        XCTAssertEqual(library.contentCensus(), census)
        for assignment in library.assignments("b") {
            XCTAssertTrue(library.exists(library.impliedPath(assignment) ?? ""), assignment.relativePath)
        }
    }

    // MARK: - Boards after a merge

    /// A merged copy's tile does not linger on the board it was moved onto.
    func testAMergedCopyLeavesNoStaleTileOnTheTargetBoard() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let incoming = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let existing = try library.place("b", name: "DSC00001.ARW", content: photo("1"))
        let other = try library.place("a", name: "DSC00002.ARW", content: photo("2"))
        await library.open("a", "b")
        try click(library, [incoming.url.path, other.url.path], from: "a", to: "b")
        try await library.settle()
        XCTAssertNil(library.stack(at: incoming.url.path, on: "b"), "the spare's tile is gone from the target board")
        XCTAssertNotNil(library.stack(at: existing.url.path, on: "b"))
        XCTAssertNil(library.stack(at: incoming.url.path, on: "a"))
        let landed = library.folder("b").appendingPathComponent("DSC00002.ARW").path
        XCTAssertNotNil(library.stack(at: landed, on: "b"))
        for key in ["a", "b"] {
            let before = library.boardFiles(library.id(key))
            await library.workspace.refreshEvent(library.id(key))
            XCTAssertEqual(library.boardFiles(library.id(key)), before, key)
        }
    }
}
