import AppKit
import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// The user's report: double-clicking a photo to see it bigger, then going
/// back, lost the multi-selection. Selection is per board, keyed by file
/// identity, and only an explicit choice changes it.
@MainActor
final class BoardSelectionTests: XCTestCase {
    private func open(_ library: MoveLibrary, _ id: UUID) async {
        await library.workspace.refreshEvent(id)
        library.workspace.selection = .event(id)
    }

    private func firstStacks(_ library: MoveLibrary, _ id: UUID, count: Int) throws -> [OrganizeStack] {
        let stacks = try XCTUnwrap(library.workspace.eventStacks[id])
        XCTAssertGreaterThanOrEqual(stacks.count, count)
        return Array(stacks.prefix(count))
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The same stacks with every file under another folder, restacked — what
    /// a NAS listing or presence rebuild does to path-derived stack ids.
    private func relocated(_ stacks: [OrganizeStack], into folder: String) -> [OrganizeStack] {
        func moved(_ file: OrganizeFile) -> OrganizeFile {
            OrganizeFile(path: folder + "/" + file.name, size: file.size, modifiedAt: file.modifiedAt)
        }
        let items = stacks.flatMap(\.items).map { item -> OrganizeItem in
            var copy = OrganizeItem(
                primary: moved(item.primary),
                companions: item.companions.map(moved),
                kind: item.kind,
                captureDate: item.captureDate,
                hasCameraDate: item.hasCameraDate,
                metadataCamera: item.metadataCamera
            )
            copy.burstPrefix = item.burstPrefix
            copy.frameNumber = item.frameNumber
            return copy
        }
        return OrganizeStacker.stacks(for: items, splits: [])
    }

    // MARK: - The reported bug

    func testOpeningTheViewerNeverChangesTheMultiSelection() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        await open(library, library.cityID)
        let chosen = try firstStacks(library, library.cityID, count: 5)
        let ids = Set(chosen.map(\.id))
        workspace.selectStacks(chosen.map(\.id))

        // Double-click and Space both go through the board's onOpen, which
        // now only moves focus.
        workspace.focus(stackID: chosen[2].id)
        XCTAssertEqual(workspace.selectedStackIDs, ids)
        XCTAssertEqual(workspace.focusedStackID, chosen[2].id)
        // Space on a stack that is not part of the selection: still 5.
        let outsider = try XCTUnwrap(workspace.eventStacks[library.cityID]?.last)
        XCTAssertFalse(ids.contains(outsider.id))
        workspace.focus(stackID: outsider.id)
        XCTAssertEqual(workspace.selectedStackIDs, ids)
        }
    }

    func testDoubleClickOnASelectedTileKeepsTheSelectionEvenAfterTheInterval() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        workspace.selectionCollapseDelay = 0.05
        await open(library, library.cityID)
        let chosen = try firstStacks(library, library.cityID, count: 5)
        let ids = Set(chosen.map(\.id))
        workspace.selectStacks(chosen.map(\.id))
        let ordered = chosen.map(\.id)

        // First click of the double-click: nothing collapses yet.
        workspace.click(stackID: chosen[1].id, orderedIDs: ordered, modifiers: [], clickCount: 1)
        XCTAssertEqual(workspace.selectedStackIDs, ids)
        // The second click and the open that follows it.
        workspace.click(stackID: chosen[1].id, orderedIDs: ordered, modifiers: [], clickCount: 2)
        workspace.focus(stackID: chosen[1].id)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(workspace.selectedStackIDs, ids)
        XCTAssertEqual(workspace.focusedStackID, chosen[1].id)
        }
    }

    func testDoubleClickWhoseSecondClickNeverArrivesAsAnEventStillOpensWithoutCollapsing() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        workspace.selectionCollapseDelay = 0.05
        await open(library, library.cityID)
        let chosen = try firstStacks(library, library.cityID, count: 5)
        let ids = Set(chosen.map(\.id))
        workspace.selectStacks(chosen.map(\.id))

        workspace.click(stackID: chosen[3].id, orderedIDs: chosen.map(\.id), modifiers: [], clickCount: 1)
        // The double-tap gesture's open cancels the waiting collapse.
        workspace.focus(stackID: chosen[3].id)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(workspace.selectedStackIDs, ids)
        }
    }

    func testSingleClickInsideAMultiSelectionCollapsesToThatTileAfterTheInterval() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        workspace.selectionCollapseDelay = 0.05
        await open(library, library.cityID)
        let chosen = try firstStacks(library, library.cityID, count: 5)
        workspace.selectStacks(chosen.map(\.id))

        workspace.click(stackID: chosen[3].id, orderedIDs: chosen.map(\.id), modifiers: [], clickCount: 1)
        XCTAssertEqual(workspace.selectedStackIDs.count, 5, "waits to see whether a second click follows")
        try await waitUntil { workspace.selectedStackIDs == [chosen[3].id] }
        XCTAssertEqual(workspace.focusedStackID, chosen[3].id)
        }
    }

    func testPlainClickOnAnUnselectedTileReplacesTheSelectionAtOnce() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        await open(library, library.cityID)
        let stacks = try firstStacks(library, library.cityID, count: 6)
        workspace.selectStacks(stacks.prefix(5).map(\.id))

        workspace.click(stackID: stacks[5].id, orderedIDs: stacks.map(\.id), modifiers: [], clickCount: 1)
        XCTAssertEqual(workspace.selectedStackIDs, [stacks[5].id])
        }
    }

    func testCommandAndShiftClicksStillExtendTheSelection() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        await open(library, library.cityID)
        let stacks = try firstStacks(library, library.cityID, count: 6)
        let ordered = stacks.map(\.id)
        workspace.click(stackID: stacks[0].id, orderedIDs: ordered, modifiers: [], clickCount: 1)
        workspace.click(stackID: stacks[2].id, orderedIDs: ordered, modifiers: .shift, clickCount: 1)
        XCTAssertEqual(workspace.selectedStackIDs, Set(ordered[0...2]))
        workspace.click(stackID: stacks[4].id, orderedIDs: ordered, modifiers: .command, clickCount: 1)
        XCTAssertEqual(workspace.selectedStackIDs, Set(ordered[0...2] + [ordered[4]]))
        workspace.click(stackID: stacks[1].id, orderedIDs: ordered, modifiers: .command, clickCount: 1)
        XCTAssertEqual(workspace.selectedStackIDs, Set([ordered[0], ordered[2], ordered[4]]))
        }
    }

    func testClickPolicyTable() {
        typealias Policy = BoardClickPolicy
        // Any click that is part of a double-click never changes selection.
        for selected in [true, false] {
            for count in [0, 1, 5] {
                for modifiers: NSEvent.ModifierFlags in [[], .shift, .command] {
                    XCTAssertEqual(
                        Policy.decide(isSelected: selected, selectionCount: count, modifiers: modifiers, clickCount: 2),
                        .keepSelection
                    )
                    XCTAssertEqual(
                        Policy.decide(isSelected: selected, selectionCount: count, modifiers: modifiers, clickCount: 3),
                        .keepSelection
                    )
                }
            }
        }
        // Plain single clicks.
        XCTAssertEqual(Policy.decide(isSelected: false, selectionCount: 0, modifiers: [], clickCount: 1), .replace)
        XCTAssertEqual(Policy.decide(isSelected: false, selectionCount: 5, modifiers: [], clickCount: 1), .replace)
        XCTAssertEqual(Policy.decide(isSelected: true, selectionCount: 1, modifiers: [], clickCount: 1), .replace)
        XCTAssertEqual(Policy.decide(isSelected: true, selectionCount: 5, modifiers: [], clickCount: 1), .replaceAfterDoubleClickInterval)
        // Modifiers.
        XCTAssertEqual(Policy.decide(isSelected: true, selectionCount: 5, modifiers: .command, clickCount: 1), .toggle)
        XCTAssertEqual(Policy.decide(isSelected: false, selectionCount: 5, modifiers: .command, clickCount: 1), .toggle)
        XCTAssertEqual(Policy.decide(isSelected: true, selectionCount: 5, modifiers: .shift, clickCount: 1), .extend)
        XCTAssertEqual(Policy.decide(isSelected: false, selectionCount: 0, modifiers: .shift, clickCount: 1), .extend)
    }

    // MARK: - Switching boards

    func testSelectionSurvivesSwitchingBoardsAndBack() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        await open(library, library.cityID)
        await open(library, library.beachID)
        workspace.selection = .event(library.cityID)
        let chosen = try firstStacks(library, library.cityID, count: 5)
        workspace.selectStacks(chosen.map(\.id))
        workspace.focus(stackID: chosen[3].id)

        workspace.selection = .event(library.beachID)
        XCTAssertTrue(workspace.selectedStackIDs.isEmpty, "the other board has its own selection")
        let beach = try firstStacks(library, library.beachID, count: 2)
        workspace.selectStacks(beach.map(\.id))

        workspace.selection = .event(library.cityID)
        XCTAssertEqual(workspace.selectedStackIDs, Set(chosen.map(\.id)))
        XCTAssertEqual(workspace.focusedStackID, chosen[3].id)
        workspace.selection = .event(library.beachID)
        XCTAssertEqual(workspace.selectedStackIDs, Set(beach.map(\.id)))
        // Through a board with no selection and no board at all.
        workspace.selection = nil
        workspace.selection = .event(library.cityID)
        XCTAssertEqual(workspace.selectedStackIDs.count, 5)
        }
    }

    func testSelectionOnAnUnsortedBoardSurvivesSwitchingAndARescan() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        let folder = library.root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<8 {
            let url = folder.appendingPathComponent(String(format: "DSC%05d.ARW", index))
            try Data(repeating: UInt8(index), count: 16 + index).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 600)], ofItemAtPath: url.path)
        }
        let location = ConfiguredLocation(role: .importSource, name: "Unsorted A7V", path: folder.path, deviceID: "sony-a7v")
        library.model.updateConfiguration { $0.configuredLocations.append(location) }
        workspace.scan(location)
        try await waitUntil { workspace.sources[location.id]?.result != nil }
        workspace.selection = .unsorted(location.id)
        let stacks = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks)
        workspace.selectStacks(stacks.prefix(4).map(\.id))

        await open(library, library.beachID)
        XCTAssertTrue(workspace.selectedStackIDs.isEmpty)
        workspace.selection = .unsorted(location.id)
        XCTAssertEqual(workspace.selectedStackIDs, Set(stacks.prefix(4).map(\.id)))

        // A rescan rebuilds the result; the same files are still selected.
        workspace.scan(location, force: true)
        try await waitUntil { workspace.sources[location.id]?.isScanning == false }
        XCTAssertEqual(workspace.selectedStackIDs.count, 4)
        }
    }

    // MARK: - Restacks that change ids

    /// The reported loss: a rebuild from another place gives every stack a
    /// new id (the id is the first file's path), and the old ids matched
    /// nothing. Selection follows the files instead.
    func testSelectionSurvivesARestackThatChangesEveryStackID() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        await open(library, library.cityID)
        let stacks = try XCTUnwrap(workspace.eventStacks[library.cityID])
        let chosen = Array(stacks.prefix(5))
        workspace.selectStacks(chosen.map(\.id))
        workspace.focus(stackID: chosen[2].id)
        let chosenNames = Set(chosen.flatMap(\.files).map(\.name))

        workspace.eventStacks[library.cityID] = relocated(stacks, into: library.root.appendingPathComponent("Library/Elsewhere").path)

        let rebuilt = try XCTUnwrap(workspace.eventStacks[library.cityID])
        XCTAssertTrue(Set(rebuilt.map(\.id)).isDisjoint(with: stacks.map(\.id)), "every id changed")
        XCTAssertEqual(workspace.selectedStackIDs.count, 5)
        let selectedNames = Set(rebuilt.filter { workspace.selectedStackIDs.contains($0.id) }.flatMap(\.files).map(\.name))
        XCTAssertEqual(selectedNames, chosenNames)
        let focused = try XCTUnwrap(rebuilt.first { $0.id == workspace.focusedStackID })
        XCTAssertEqual(focused.files.map(\.name), chosen[2].files.map(\.name))
        }
    }

    func testARestackWhileAnotherBoardIsOpenIsRememberedForWhenThisOneReturns() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        await open(library, library.cityID)
        await open(library, library.beachID)
        workspace.selection = .event(library.cityID)
        let stacks = try XCTUnwrap(workspace.eventStacks[library.cityID])
        workspace.selectStacks(stacks.prefix(5).map(\.id))
        workspace.selection = .event(library.beachID)

        // A background re-read of the board that is not on screen.
        workspace.eventStacks[library.cityID] = relocated(stacks, into: library.root.appendingPathComponent("Library/Elsewhere").path)
        XCTAssertTrue(workspace.selectedStackIDs.isEmpty)

        workspace.selection = .event(library.cityID)
        XCTAssertEqual(workspace.selectedStackIDs.count, 5)
        }
    }

    func testSelectionRidesThroughABoardThatEmptiesAndRefills() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        await open(library, library.cityID)
        let stacks = try XCTUnwrap(workspace.eventStacks[library.cityID])
        workspace.selectStacks(stacks.prefix(5).map(\.id))

        workspace.eventStacks[library.cityID] = []
        XCTAssertTrue(workspace.selectedStackIDs.isEmpty)
        workspace.eventStacks[library.cityID] = relocated(stacks, into: library.root.appendingPathComponent("Library/Back").path)
        XCTAssertEqual(workspace.selectedStackIDs.count, 5)
        }
    }

    func testRefreshingTheBoardKeepsTheSelection() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        await open(library, library.cityID)
        let chosen = try firstStacks(library, library.cityID, count: 5)
        workspace.selectStacks(chosen.map(\.id))
        let names = Set(chosen.flatMap(\.files).map(\.name))

        await workspace.refreshEvent(library.cityID)   // Cmd-R
        await workspace.refreshEvent(library.parentID)    // a family board over it
        workspace.refreshConnectivity()
        try await Task.sleep(for: .milliseconds(200))

        let stacks = try XCTUnwrap(workspace.eventStacks[library.cityID])
        let selectedNames = Set(stacks.filter { workspace.selectedStackIDs.contains($0.id) }.flatMap(\.files).map(\.name))
        XCTAssertEqual(selectedNames, names)
        }
    }

    // MARK: - Files leaving

    func testTrashingTwoOfFiveLeavesThree() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        await open(library, library.cityID)
        let chosen = try firstStacks(library, library.cityID, count: 5)
        workspace.selectStacks(chosen.map(\.id))
        let trashed = Set(chosen.prefix(2).map(\.id))
        let kept = Set(chosen.suffix(3).map(\.id))

        workspace.requestTrash(stackIDs: trashed, fromEvent: library.cityID)
        workspace.confirmTrash(try XCTUnwrap(workspace.pendingTrash))
        if mode != .bufferPlugged {
            // In the temp folder standing in for the NAS there is no volume of
            // its own to hold a Trash folder, and the Buffer's is away: the
            // trash says so, moves nothing, and the selection is untouched.
            let before = workspace.eventStacks[library.cityID]?.flatMap(\.files).count
            try await waitUntil { !library.model.isBusy && library.model.statusMessage.contains("Nothing moved to Trash") }
            XCTAssertEqual(workspace.selectedStackIDs, Set(chosen.map(\.id)))
            XCTAssertEqual(workspace.eventStacks[library.cityID]?.flatMap(\.files).count, before)
            return
        }
        try await waitUntil {
            !library.model.isBusy && (workspace.eventStacks[library.cityID]?.contains { trashed.contains($0.id) } == false)
        }

        XCTAssertEqual(workspace.selectedStackIDs, kept)
        // And they stay that way across a board switch.
        workspace.selection = .event(library.beachID)
        workspace.selection = .event(library.cityID)
        XCTAssertEqual(workspace.selectedStackIDs, kept)
        }
    }

    /// An Apply on the unsorted board, which moves files into events, must
    /// not clear the selection on any other board — and only the moved
    /// files leave the board it ran on.
    func testApplyOnOneBoardLeavesAnotherBoardsSelectionAlone() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        let model = library.model
        let folder = library.root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<4 {
            let url = folder.appendingPathComponent(String(format: "DSC9%04d.ARW", index))
            try Data(repeating: UInt8(index + 1), count: 32).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3600)], ofItemAtPath: url.path)
        }
        let location = ConfiguredLocation(role: .importSource, name: "Unsorted A7V", path: folder.path, deviceID: "sony-a7v")
        model.updateConfiguration { $0.configuredLocations.append(location) }
        workspace.scan(location)
        try await waitUntil { workspace.sources[location.id]?.result != nil }
        let unsortedStacks = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks)
        XCTAssertEqual(unsortedStacks.count, 4)

        await open(library, library.cityID)
        let city = try firstStacks(library, library.cityID, count: 5)
        workspace.selectStacks(city.map(\.id))
        workspace.selection = .unsorted(location.id)
        // Two of the four are sorted into Beach Day and stay selected on the
        // unsorted board; one unmoved file is selected too.
        workspace.assign(stackIDs: Set(unsortedStacks.prefix(2).map(\.id)), from: location.id, to: library.beachID)
        workspace.selectStacks(unsortedStacks.prefix(3).map(\.id))

        let plan = EventsWorkspace.buildApplyPlan(
            events: [try XCTUnwrap(workspace.event(library.beachID))],
            configuration: model.configuration,
            locations: workspace.locations,
            onlyUnder: folder.path,
            title: "Apply",
            unsortedRoots: [folder]
        )
        if mode != .bufferPlugged {
            // Apply puts files into the Buffer, so with the Buffer away it is
            // the one action that may say it needs it: nothing moves, and no
            // board's selection is touched by the refusal.
            XCTAssertEqual(plan.moveCount, 0)
            workspace.prepareApply(eventIDs: [library.beachID], title: "Apply", onlyUnder: folder.path)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(workspace.selectedStackIDs.count, 3)
            XCTAssertEqual(workspace.sources[location.id]?.result?.stacks.count, 4)
            workspace.selection = .event(library.cityID)
            XCTAssertEqual(workspace.selectedStackIDs.count, 5)
            return
        }
        XCTAssertEqual(plan.moveCount, 2)
        workspace.performApply(plan)
        try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }

        // The board Apply ran on lost exactly the two files that moved.
        let remaining = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(workspace.selectedStackIDs, Set(remaining.filter { stack in
            unsortedStacks[2].files.contains { $0.name == stack.files.first?.name }
        }.map(\.id)))
        // The other board is untouched.
        workspace.selection = .event(library.cityID)
        XCTAssertEqual(workspace.selectedStackIDs.count, 5)
        }
    }

    func testEscapeAndSelectAllStillWork() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        await open(library, library.cityID)
        let stacks = try XCTUnwrap(workspace.eventStacks[library.cityID])
        workspace.selectStacks(stacks.map(\.id))
        XCTAssertEqual(workspace.selectedStackIDs.count, stacks.count)
        workspace.selectedStackIDs.removeAll()
        workspace.selection = .event(library.beachID)
        workspace.selection = .event(library.cityID)
        XCTAssertTrue(workspace.selectedStackIDs.isEmpty, "Escape's clear is remembered too")
        }
    }
}
