import AppKit
import CameraToolkitCore
import CoreGraphics
import Foundation
import SwiftUI
@testable import CameraToolkitApp
import XCTest

@MainActor
final class EventsWorkspaceTests: XCTestCase {
    func testSortingRecordsAssignmentsOnlyAndUndoRestores() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00002.ARW"), "2026:08:26 10:00:00", "400")
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/DSC00003.ARW"), "2026:08:26 10:05:00", "000")
            let location = addUnsorted(unsorted, to: model)

            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            XCTAssertEqual(result.stacks.map(\.items.count).sorted(), [1, 2])

            let eventID = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            let burst = try XCTUnwrap(result.stacks.first { $0.isBurst })
            workspace.assign(stackIDs: [burst.id], from: location.id, to: eventID)

            let assignments = model.configuration.photoEventAssignments.filter { $0.eventID == eventID }
            XCTAssertEqual(assignments.map(\.relativePath).sorted(), ["B0001_DSC00001.ARW", "B0001_DSC00002.ARW"])
            XCTAssertEqual(assignments.first?.deviceID, "sony-a7v")
            XCTAssertTrue(burst.items.allSatisfy { FileManager.default.fileExists(atPath: $0.primary.path) })
            XCTAssertEqual(workspace.assignedEvent(for: burst).event?.id, eventID)
            XCTAssertTrue(workspace.isSorted(burst))

            workspace.undoLastSort()
            XCTAssertTrue(model.configuration.photoEventAssignments.isEmpty)
            XCTAssertFalse(workspace.isSorted(burst))
        }
    }

    func testApplyMovesIntoBufferAndPrivateStagingThenUndoPutsFilesBack() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            let shared = try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            let sidecar = try organizerWrite(unsorted.appendingPathComponent("Transfer 1/DSC00001.xmp"), "<xmp/>")
            let secret = try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/DSC00020.ARW"), "2026:08:26 22:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)

            let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            let hotel = try XCTUnwrap(workspace.createEvent(name: "Hotel Night", date: organizerDay("2026-08-26"), policy: .archiveOnly))
            let sharedStack = try XCTUnwrap(result.stacks.first { $0.coverItem.primary.name == "DSC00001.ARW" })
            let secretStack = try XCTUnwrap(result.stacks.first { $0.coverItem.primary.name == "DSC00020.ARW" })
            workspace.assign(stackIDs: [sharedStack.id], from: location.id, to: beach)
            workspace.assign(stackIDs: [secretStack.id], from: location.id, to: hotel)

            let plan = EventsWorkspace.buildApplyPlan(
                events: [try XCTUnwrap(workspace.event(beach)), try XCTUnwrap(workspace.event(hotel))],
                configuration: model.configuration,
                locations: workspace.locations,
                onlyUnder: unsorted.path,
                title: "Apply",
                unsortedRoots: [unsorted]
            )
            XCTAssertEqual(plan.moveCount, 3)
            XCTAssertEqual(plan.copyCount, 0)

            workspace.performApply(plan)
            try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }

            let bufferEvent = root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-26 Beach Day/Originals/Sony A7V", isDirectory: true)
            let privateEvent = root.appendingPathComponent("Drive/.Camera Toolkit/Private/2026/2026-08-26 Hotel Night/Originals/Sony A7V", isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: bufferEvent.appendingPathComponent("DSC00001.ARW").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: bufferEvent.appendingPathComponent("DSC00001.xmp").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: privateEvent.appendingPathComponent("DSC00020.ARW").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-26 Hotel Night").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: unsorted.appendingPathComponent("Transfer 1").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unsorted.path))
            XCTAssertEqual(workspace.sources[location.id]?.result?.items.count, 0)

            await workspace.refreshEvent(beach)
            XCTAssertEqual(workspace.presence[beach]?.onDrive, 2)
            XCTAssertEqual(workspace.presence[beach]?.onSource, 0)

            workspace.undoLastMove()
            try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle == nil }
            XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Drive/.Camera Toolkit/Private/2026/2026-08-26 Hotel Night").path))
            XCTAssertEqual(model.configuration.photoEventAssignments.count, 3)
        }
    }

    func testMovingAppliedBurstToPrivateEventRenamesItOutOfTheBuffer() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("B0007_DSC00001.ARW"), "2026:08:27 09:00:00", "000")
            try writeOrganizerARW(unsorted.appendingPathComponent("B0007_DSC00002.ARW"), "2026:08:27 09:00:00", "300")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let burst = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks.first)

            let shared = try XCTUnwrap(workspace.createEvent(name: "City Walk", date: organizerDay("2026-08-27"), policy: .buffer))
            let hidden = try XCTUnwrap(workspace.createEvent(name: "Just Us", date: organizerDay("2026-08-27"), policy: .archiveOnly))
            workspace.assign(stackIDs: [burst.id], from: location.id, to: shared)
            workspace.performApply(EventsWorkspace.buildApplyPlan(
                events: [try XCTUnwrap(workspace.event(shared))],
                configuration: model.configuration,
                locations: workspace.locations,
                onlyUnder: nil,
                title: "Apply",
                unsortedRoots: [unsorted]
            ))
            try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }

            await workspace.refreshEvent(shared)
            let appliedStack = try XCTUnwrap(workspace.eventStacks[shared]?.first)
            XCTAssertEqual(appliedStack.items.count, 2)
            workspace.moveStacks([appliedStack.id], fromEvent: shared, toEvent: hidden)
            try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle == "Move to Just Us" }

            let privateCopy = root.appendingPathComponent("Drive/.Camera Toolkit/Private/2026/2026-08-27 Just Us/Originals/Sony A7V/B0007_DSC00002.ARW")
            XCTAssertTrue(FileManager.default.fileExists(atPath: privateCopy.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-27 City Walk").path))
            XCTAssertEqual(model.configuration.photoEventAssignments.filter { $0.eventID == hidden }.count, 2)
            XCTAssertTrue(model.configuration.photoEventAssignments.filter { $0.eventID == shared }.isEmpty)
        }
    }

    /// Regression: an Apply rename used to leave every open preview and tile
    /// pointing at the vacated path, which decoded as a "could not decode"
    /// failure until a full event restat replaced the stacks. The move
    /// report must retarget the preview's path to the destination in the
    /// same update that records the move.
    func testApplyMoveRetargetsOpenPreviewPathsToTheDestination() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            let source = try writeOrganizerJPEG(unsorted.appendingPathComponent("101MSDCF/DSC05012.JPG"))
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let stack = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks.first)

            let eventID = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            workspace.assign(stackIDs: [stack.id], from: location.id, to: eventID)

            // The state an open preview is bound to: the event board already
            // lists the file at its unsorted path ("On source" badge).
            await workspace.refreshEvent(eventID)
            let boardStack = try XCTUnwrap(workspace.eventStacks[eventID]?.first)
            XCTAssertEqual(boardStack.items.first?.primary.path, source.path)

            let plan = EventsWorkspace.buildApplyPlan(
                events: [try XCTUnwrap(workspace.event(eventID))],
                configuration: model.configuration,
                locations: workspace.locations,
                onlyUnder: unsorted.path,
                title: "Apply",
                unsortedRoots: [unsorted]
            )
            XCTAssertEqual(plan.moveCount, 1)
            workspace.performApply(plan)
            try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }

            let destination = root.appendingPathComponent(
                "Drive/Camera Buffer/2026/2026-08-26 Beach Day/Originals/Sony A7V/DSC05012.JPG"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

            // The preview's decode target moved with the file in the same
            // update — before any refreshEvent restat could rebuild stacks.
            let retargeted = try XCTUnwrap(workspace.eventStacks[eventID]?.first)
            XCTAssertEqual(retargeted.items.first?.primary.path, destination.path)
            XCTAssertEqual(retargeted.id, boardStack.id)

            // A path the move just vacated is not a decode failure: the
            // loader follows the move to the destination. A missing path
            // with no move behind it still reports failure.
            TileImageLoader.shared.invalidate(url: destination)
            let decoded = await TileImageLoader.shared.image(for: source, maximumPixelSize: 384)
            XCTAssertNotNil(decoded)
            let untouched = unsorted.appendingPathComponent("101MSDCF/NEVER_THERE.JPG")
            let missingDecode = await TileImageLoader.shared.image(for: untouched, maximumPixelSize: 384)
            XCTAssertNil(missingDecode)

            // The unsorted board dropped the file; the event refresh that
            // lands afterwards agrees — and keeps the stack identity the
            // preview is bound to.
            XCTAssertEqual(workspace.sources[location.id]?.result?.items.count, 0)
            await workspace.refreshEvent(eventID)
            XCTAssertEqual(workspace.eventStacks[eventID]?.first?.items.first?.primary.path, destination.path)
            XCTAssertEqual(workspace.eventStacks[eventID]?.first?.id, boardStack.id)
        }
    }

    func testSetupGuideAddsChosenFoldersHidesTestSourcesAndOpensThem() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unparsed A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            let testSource = ConfiguredLocation(
                role: .importSource,
                name: "Old Test Card",
                path: root.appendingPathComponent("Library/Application Support/CameraToolkit/Simulation/Source Card").path
            )
            model.updateConfiguration { $0.configuredLocations.append(testSource) }
            XCTAssertTrue(SetupGuide.isTestSource(testSource))

            workspace.startGuide()
            let guide = try XCTUnwrap(workspace.guide)
            guide.go(to: SetupGuideStep.unsorted.rawValue)
            XCTAssertTrue(guide.removableLocationIDs.contains(testSource.id))
            guide.candidates = [UnsortedFolderCandidate(
                path: unsorted.path,
                name: "Unparsed A7V",
                volumeName: "Drive",
                cameraFileCount: 1,
                byteCount: 100,
                isCameraCard: false,
                isSuggested: true
            )]
            guide.chosenCandidatePaths = [unsorted.path]
            guide.applyUnsortedChoices()

            let added = try XCTUnwrap(workspace.unsortedLocations.first { $0.path == unsorted.path })
            XCTAssertEqual(added.deviceID, "sony-a7v")
            XCTAssertFalse(workspace.unsortedLocations.contains { $0.id == testSource.id })

            guide.go(to: SetupGuideStep.browse.rawValue)
            XCTAssertEqual(guide.browseLocationID, added.id)
            guide.openBrowse()
            XCTAssertEqual(workspace.selection, .unsorted(added.id))
            workspace.scan(added)
            try await waitUntil { workspace.sources[added.id]?.result != nil }
            guide.pickFirstBurstAndCreateEvent()
            XCTAssertNotNil(workspace.newEventRequest)
            XCTAssertEqual(workspace.newEventRequest?.stackIDs.count, 1)

            guide.finish()
            XCTAssertNil(workspace.guide)
            UserDefaults.standard.removeObject(forKey: SetupGuide.completedKey)
        }
    }

    func testConnectivityRefreshRescansSourcesThatFailedWhileOffline() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let missing = root.appendingPathComponent("Late Card", isDirectory: true)
            let location = addUnsorted(missing, to: model)

            workspace.scan(location)
            XCTAssertNotNil(workspace.sources[location.id]?.error)
            XCTAssertNil(workspace.sources[location.id]?.result)

            // Still unreachable: a refresh re-checks but does not clear the error.
            workspace.refreshConnectivity()
            XCTAssertNotNil(workspace.sources[location.id]?.error)
            XCTAssertNil(workspace.sources[location.id]?.result)

            try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
            try writeOrganizerARW(missing.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")

            let revision = workspace.connectivityRevision
            workspace.refreshConnectivity()
            XCTAssertEqual(workspace.connectivityRevision, revision + 1)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            XCTAssertNil(workspace.sources[location.id]?.error)
            XCTAssertEqual(workspace.sources[location.id]?.result?.items.count, 1)
        }
    }

    func testConnectivityRefreshLeavesHealthyCachedScansAlone() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let folder = root.appendingPathComponent("Card", isDirectory: true)
            try writeOrganizerARW(folder.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            let location = addUnsorted(folder, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }

            // A file landing after the first scan is not picked up by a
            // connectivity refresh — it re-checks reachability, not contents.
            try writeOrganizerARW(folder.appendingPathComponent("DSC00002.ARW"), "2026:08:26 10:01:00", "000")
            workspace.refreshConnectivity()
            try await Task.sleep(for: .milliseconds(300))

            XCTAssertEqual(workspace.sources[location.id]?.isScanning, false)
            XCTAssertEqual(workspace.sources[location.id]?.result?.items.count, 1)
        }
    }

    func testTrashStackMovesFilesIntoDriveTrashAndDropsAssignments() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            let frame1 = try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            let frame2 = try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00002.ARW"), "2026:08:26 10:00:00", "400")
            let sidecar = try organizerWrite(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00001.xmp"), "<xmp/>")
            let kept = try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/DSC00010.ARW"), "2026:08:26 11:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)

            let eventID = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            let burst = try XCTUnwrap(result.stacks.first { $0.isBurst })
            workspace.assign(stackIDs: [burst.id], from: location.id, to: eventID)
            XCTAssertEqual(model.configuration.photoEventAssignments.count, 3)
            workspace.selectStacks([burst.id])

            let trashPosts = NotificationPostBox()
            let observer = NotificationCenter.default.addObserver(
                forName: .cameraToolkitMediaTrashChanged, object: nil, queue: nil
            ) { _ in trashPosts.note() }
            defer { NotificationCenter.default.removeObserver(observer) }

            workspace.trash(stackIDs: [burst.id], from: location.id)
            // Trash now confirms first — the test stands in for the owner
            // pressing "Move to Trash" on the sheet.
            workspace.confirmTrash(try XCTUnwrap(workspace.pendingTrash))
            try await waitUntil { !model.isBusy && workspace.sources[location.id]?.result?.items.count == 1 }

            // Companions travel together: both RAWs and the XMP moved into the
            // drive-local _Trash, preserving their folder structure.
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            let batchFolders = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: [.isDirectoryKey])
            let batchFolder = try XCTUnwrap(batchFolders.first { $0.lastPathComponent != ".DS_Store" })
            for url in [frame1, frame2, sidecar] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: batchFolder.appendingPathComponent("Transfer 1/\(url.lastPathComponent)").path))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))

            // The manifest records where each file lived and what it was sorted into.
            let manifestData = try Data(contentsOf: batchFolder.appendingPathComponent("manifest.json"))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(MediaTrashManifest.self, from: manifestData)
            XCTAssertEqual(manifest.entries.count, 3)
            let entry = try XCTUnwrap(manifest.entries.first { $0.trashedRelativePath == "Transfer 1/B0001_DSC00001.ARW" })
            XCTAssertEqual(entry.originalAbsolutePath, frame1.standardizedFileURL.path)
            XCTAssertEqual(entry.eventID, eventID)
            XCTAssertEqual(entry.deviceID, "sony-a7v")
            XCTAssertEqual(entry.originalLocationName, location.name)

            // Scan result and assignments dropped the trashed files; the
            // untrashed single stays. Selection of the trashed stack cleared.
            XCTAssertEqual(workspace.sources[location.id]?.result?.items.count, 1)
            XCTAssertEqual(workspace.sources[location.id]?.result?.items.first?.primary.name, "DSC00010.ARW")
            XCTAssertTrue(model.configuration.photoEventAssignments.isEmpty)
            XCTAssertTrue(workspace.selectedStackIDs.isEmpty)
            XCTAssertTrue(model.statusMessage.contains("Moved 3 files to Trash"))
            // An open Trash window reloads on this notification — the move
            // must post it once so the new batch shows without a manual Reload.
            XCTAssertEqual(trashPosts.count, 1)

            // The batch lists under the removed-files root and restores cleanly.
            let svc = MediaTrashService(removedFilesRoot: workspace.locations.removedFilesRoot)
            let batches = svc.listBatches(under: [workspace.locations.removedFilesRoot])
            XCTAssertEqual(batches.count, 1)
            let report = svc.restore(batch: try XCTUnwrap(batches.first))
            XCTAssertEqual(report.restored.count, 3)
            XCTAssertTrue(report.conflicts.isEmpty)
            XCTAssertEqual(try Data(contentsOf: sidecar), Data("<xmp/>".utf8))
        }
    }

    /// What the filmstrip's Delete key and context menu hand over: a range of
    /// selected frames — every item's primary and companions move together.
    func testTrashItemsMovesEverySelectedFrameToTrash() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            let frame1 = try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            let frame2 = try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00002.ARW"), "2026:08:26 10:00:00", "400")
            let frame3 = try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00003.ARW"), "2026:08:26 10:00:00", "700")
            let sidecar = try organizerWrite(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00002.xmp"), "<xmp/>")
            let kept = try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/DSC00010.ARW"), "2026:08:26 11:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let burst = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks.first { $0.items.count == 3 })

            workspace.trashItems(Array(burst.items.prefix(2)), from: location.id)
            try await waitUntil { !model.isBusy && workspace.sources[location.id]?.result?.items.count == 2 }

            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            let batches = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: [.isDirectoryKey])
            let batch = try XCTUnwrap(batches.first { $0.lastPathComponent != ".DS_Store" })
            for url in [frame1, frame2, sidecar] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: batch.appendingPathComponent("Transfer 1/\(url.lastPathComponent)").path))
            }
            // The unselected frame and the unrelated single stay on the board.
            XCTAssertTrue(FileManager.default.fileExists(atPath: frame3.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
            XCTAssertEqual(
                Set(workspace.sources[location.id]?.result?.items.map(\.primary.name) ?? []),
                ["B0001_DSC00003.ARW", "DSC00010.ARW"]
            )
        }
    }

    func testRequestTrashDoesNotMoveUntilConfirmed() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            let photo = try writeOrganizerARW(unsorted.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let stack = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks.first)

            workspace.requestTrash(stack.items, from: location.id)
            XCTAssertNotNil(workspace.pendingTrash)
            XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
            XCTAssertEqual(workspace.pendingTrash?.fileCount, 1)
            XCTAssertTrue(workspace.pendingTrash?.destinations.contains { $0.trashFolderPath.contains("_Trash") } == true)

            workspace.pendingTrash = nil
            XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
        }
    }

    /// Regression: the event-board trash completion used to kick off a full
    /// `refreshEvent` on top of its own board update — on a large event that
    /// repaint replaced the "Moved N files to Trash" line with loading bars
    /// and re-read every file. The completion already drops the moved files
    /// from the boards it owns; the event grid must lose the trashed stacks
    /// with no refresh at all.
    func testEventTrashDropsStacksWithoutRefreshingTheBoard() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00002.ARW"), "2026:08:26 10:00:00", "400")
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/DSC00010.ARW"), "2026:08:26 11:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)

            let eventID = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            let burst = try XCTUnwrap(result.stacks.first { $0.isBurst })
            let single = try XCTUnwrap(result.stacks.first { !$0.isBurst })
            workspace.assign(stackIDs: [burst.id, single.id], from: location.id, to: eventID)

            // Paint the board once — its stacks point at the real files.
            await workspace.refreshEvent(eventID)
            let painted = try XCTUnwrap(workspace.eventStacks[eventID])
            XCTAssertEqual(painted.flatMap(\.files).count, 3)
            let boardBurst = try XCTUnwrap(painted.first { $0.isBurst })

            // Every board-path resolve runs inside refreshEvent, so this seam
            // records any refresh the trash completion might still spawn.
            let locations = workspace.locations
            let event = try XCTUnwrap(workspace.event(eventID))
            let box = EventPathProbeBox()
            workspace.eventPathResolver = { assignment in
                box.noteResolved(assignment.relativePath)
                return locations.impliedDrivePath(for: assignment, event: event, policy: .buffer)
            }

            let trashPosts = NotificationPostBox()
            let observer = NotificationCenter.default.addObserver(
                forName: .cameraToolkitMediaTrashChanged, object: nil, queue: nil
            ) { _ in trashPosts.note() }
            defer { NotificationCenter.default.removeObserver(observer) }

            workspace.requestTrash(stackIDs: [boardBurst.id], fromEvent: eventID)
            workspace.confirmTrash(try XCTUnwrap(workspace.pendingTrash))
            try await waitUntil { !model.isBusy && workspace.eventStacks[eventID]?.flatMap(\.files).count == 1 }

            // The grid kept the untrashed single; the burst's files are gone
            // from the event board, the unsorted board, and the assignments.
            let remaining = try XCTUnwrap(workspace.eventStacks[eventID])
            XCTAssertEqual(remaining.flatMap(\.files).map(\.name), ["DSC00010.ARW"])
            XCTAssertEqual(workspace.sources[location.id]?.result?.items.count, 1)
            XCTAssertEqual(model.configuration.photoEventAssignments.map(\.relativePath), ["DSC00010.ARW"])
            XCTAssertTrue(model.statusMessage.contains("Moved 2 files to Trash"))
            XCTAssertEqual(trashPosts.count, 1)

            // Give a wrongly-spawned refresh every chance to run its first
            // resolve — none may come.
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(box.resolved.isEmpty)
        }
    }

    /// The Trash window's reload gate: only the newest listing may publish.
    /// A read that lands late — before or after the current one — is dropped,
    /// and `reading` stays owned by the read still in flight.
    func testTrashReloadGateDropsStaleListings() {
        var gate = TrashReloadGate()
        let first = gate.begin()
        let second = gate.begin()
        XCTAssertTrue(gate.reading)

        // The newer read lands first and publishes.
        XCTAssertTrue(gate.finish(second))
        XCTAssertFalse(gate.reading)
        // The older listing finishes late — dropped, and it must not clear a
        // reading flag it never owned.
        XCTAssertFalse(gate.finish(first))
        XCTAssertFalse(gate.reading)

        // Same rule when the stale read lands while the newer one is still
        // in flight: the board keeps saying it is re-reading.
        let third = gate.begin()
        let fourth = gate.begin()
        XCTAssertFalse(gate.finish(third))
        XCTAssertTrue(gate.reading)
        XCTAssertTrue(gate.finish(fourth))
        XCTAssertFalse(gate.reading)
    }

    /// "Move to New Burst" records a BurstSplit in the configuration and
    /// restacks the board; a forced rescan must not glue the frames back
    /// together.
    func testSplittingFramesOffABurstPersistsAcrossRescan() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            for index in 1...4 {
                try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC0000\(index).ARW"), "2026:08:26 10:00:00", "\(index)00")
            }
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/DSC00010.ARW"), "2026:08:26 11:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let burst = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks.first { $0.items.count == 4 })

            workspace.splitItems(Array(burst.items.suffix(2)))

            XCTAssertEqual(model.configuration.burstSplits.count, 1)
            XCTAssertEqual(
                model.configuration.burstSplits[0].memberPathKeys,
                ["B0001_DSC00003.ARW", "B0001_DSC00004.ARW"].map {
                    EventStorageLocations.pathKey(unsorted.appendingPathComponent("Transfer 1/\($0)").path)
                }
            )
            var stacks = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks)
            XCTAssertEqual(stacks.map(\.items.count).sorted(), [1, 2, 2])
            let split = try XCTUnwrap(stacks.first { $0.items.map(\.primary.name) == ["B0001_DSC00003.ARW", "B0001_DSC00004.ARW"] })
            XCTAssertTrue(split.isBurst)
            // The files themselves never moved.
            XCTAssertTrue(burst.items.allSatisfy { FileManager.default.fileExists(atPath: $0.primary.path) })

            workspace.scan(location, force: true)
            try await waitUntil { workspace.sources[location.id]?.isScanning == false }
            stacks = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks)
            XCTAssertEqual(stacks.map(\.items.count).sorted(), [1, 2, 2])
            XCTAssertNotNil(stacks.first { $0.items.map(\.primary.name) == ["B0001_DSC00003.ARW", "B0001_DSC00004.ARW"] })
        }
    }

    func testSubeventCreationDedupAndSidebarNesting() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            _ = root
            let parentA = try XCTUnwrap(workspace.createEvent(name: "TRIP2026", date: organizerDay("2026-08-21"), policy: .buffer))
            let parentB = try XCTUnwrap(workspace.createEvent(name: "Other Trip", date: organizerDay("2026-08-21"), policy: .buffer))
            let child = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parentA))

            // Same name and date under a different parent is a different
            // folder, so it creates a new event rather than matching.
            let childB = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parentB))
            XCTAssertNotEqual(child, childB)
            // Same name, date, and parent matches the existing event.
            XCTAssertEqual(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parentA), child)

            let events = model.configuration.savedEvents
            XCTAssertEqual(events.first { $0.id == child }?.parentEventID, parentA)
            XCTAssertEqual(events.first { $0.id == childB }?.parentEventID, parentB)

            // The sidebar nests children under their parent.
            let rows = workspace.sidebarEvents
            guard let parentIndex = rows.firstIndex(where: { $0.event.id == parentA }),
                  let childIndex = rows.firstIndex(where: { $0.event.id == child }) else {
                return XCTFail("Sidebar is missing the parent or subevent")
            }
            XCTAssertEqual(rows[parentIndex].depth, 0)
            XCTAssertEqual(rows[childIndex].depth, 1)
            XCTAssertEqual(childIndex, parentIndex + 1)

            // A descendant can never be picked as a parent.
            XCTAssertNil(workspace.validParentEventID(child, for: parentA))
            XCTAssertEqual(workspace.validParentEventID(parentB, for: parentA), parentB)

            XCTAssertEqual(workspace.eventTitle(try XCTUnwrap(workspace.event(child))), "TRIP2026 / Matcha")
        }
    }

    func testRenamingParentMovesSubeventFolderAndRewritesAssignments() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let parent = try XCTUnwrap(workspace.createEvent(name: "TRIP2026", date: organizerDay("2026-08-21"), policy: .buffer))
            let child = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parent))
            let cardCopy = root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-21 TRIP2026/2026-08-23 Matcha/Originals/Sony A7V", isDirectory: true)
            try writeOrganizerARW(cardCopy.appendingPathComponent("DSC00001.ARW"), "2026:08:23 10:00:00", "000")
            model.updateConfiguration { configuration in
                configuration.photoEventAssignments.append(PhotoEventAssignment(
                    sourceRootPath: cardCopy.path,
                    relativePath: "DSC00001.ARW",
                    fileSize: 1,
                    modifiedAt: Date(),
                    eventID: child,
                    deviceID: "sony-a7v"
                ))
            }

            workspace.renameEvent(parent, name: "TRIP2026 Renamed", date: organizerDay("2026-08-21"), policy: .buffer, parentEventID: nil)

            let movedFolder = root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-21 TRIP2026 Renamed", isDirectory: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-21 TRIP2026").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: movedFolder.appendingPathComponent("2026-08-23 Matcha/Originals/Sony A7V/DSC00001.ARW").path))
            XCTAssertEqual(
                model.configuration.photoEventAssignments.first?.sourceRootPath,
                movedFolder.appendingPathComponent("2026-08-23 Matcha/Originals/Sony A7V").path
            )
        }
    }

    func testReparentingMovesTheEventFolder() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let parent = try XCTUnwrap(workspace.createEvent(name: "TRIP2026", date: organizerDay("2026-08-21"), policy: .buffer))
            let child = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parent))
            let nestedFolder = root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-21 TRIP2026/2026-08-23 Matcha/Originals/Sony A7V", isDirectory: true)
            try writeOrganizerARW(nestedFolder.appendingPathComponent("DSC00001.ARW"), "2026:08:23 10:00:00", "000")

            workspace.renameEvent(child, name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: nil)

            XCTAssertNil(workspace.event(child)?.parentEventID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: nestedFolder.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-23 Matcha/Originals/Sony A7V/DSC00001.ARW").path))
        }
    }

    func testDeleteEmptyEventRefusesAParentWithSubevents() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            _ = root
            let parent = try XCTUnwrap(workspace.createEvent(name: "TRIP2026", date: organizerDay("2026-08-21"), policy: .buffer))
            _ = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parent))

            workspace.deleteEmptyEvent(parent)
            XCTAssertNotNil(workspace.event(parent))
            XCTAssertTrue(model.statusMessage.contains("subevents"))
        }
    }

    func testSubeventDepthCapRefusesAFourthLevel() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            _ = root
            let parent = try XCTUnwrap(workspace.createEvent(name: "TRIP2026", date: organizerDay("2026-08-21"), policy: .buffer))
            let child = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parent))
            let grandchild = try XCTUnwrap(workspace.createEvent(name: "Latte Art", date: organizerDay("2026-08-24"), policy: nil, parentEventID: child))

            // Depth 2 is the deepest: a fourth level refuses and says why.
            XCTAssertNil(workspace.createEvent(name: "Too Deep", date: organizerDay("2026-08-25"), policy: nil, parentEventID: grandchild))
            XCTAssertTrue(model.statusMessage.contains("two levels"), model.statusMessage)
            XCTAssertNil(model.configuration.savedEvents.first { $0.name == "Too Deep" })

            // The "New Subevent" shortcut on a depth-2 event refuses the
            // same way instead of opening the sheet.
            workspace.requestNewEvent(from: nil, parentEventID: grandchild)
            XCTAssertNil(workspace.newEventRequest)
            XCTAssertTrue(model.statusMessage.contains("two levels"), model.statusMessage)

            // The Inside-event picker never offers a depth-2 parent; the
            // grandchild still lists and its own link survives a rename.
            XCTAssertFalse(workspace.parentCandidates(excluding: nil).contains { $0.event.id == grandchild })
            XCTAssertEqual(workspace.sidebarEvents.map(\.event.id), [parent, child, grandchild])
            XCTAssertNil(workspace.validParentEventID(grandchild, for: nil))
            XCTAssertEqual(workspace.validParentEventID(child, for: grandchild), child)
        }
    }

    func testFamilyScopeCountsFiltersAndBoardSections() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            // Separate folders keep the frames from burst-grouping — each
            // lands as its own stack.
            try writeOrganizerARW(unsorted.appendingPathComponent("Roll A/DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            try writeOrganizerARW(unsorted.appendingPathComponent("Roll B/DSC00002.ARW"), "2026:08:26 10:01:00", "000")
            try writeOrganizerARW(unsorted.appendingPathComponent("Roll C/DSC00003.ARW"), "2026:08:26 10:02:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            let byName = Dictionary(uniqueKeysWithValues: result.stacks.map { ($0.coverItem.primary.name, $0) })
            let ownStack = try XCTUnwrap(byName["DSC00001.ARW"])
            let childStack = try XCTUnwrap(byName["DSC00002.ARW"])
            let grandchildStack = try XCTUnwrap(byName["DSC00003.ARW"])

            let parent = try XCTUnwrap(workspace.createEvent(name: "TRIP2026", date: organizerDay("2026-08-21"), policy: .buffer))
            let child = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parent))
            let grandchild = try XCTUnwrap(workspace.createEvent(name: "Latte Art", date: organizerDay("2026-08-24"), policy: nil, parentEventID: child))

            workspace.assign(stackIDs: [ownStack.id], from: location.id, to: parent)
            workspace.assign(stackIDs: [childStack.id], from: location.id, to: child)
            workspace.assign(stackIDs: [grandchildStack.id], from: location.id, to: grandchild)

            // Counts cover the family: the parent includes both
            // descendants; a child never counts the parent's files.
            XCTAssertEqual(workspace.assignmentCount(for: parent), 3)
            XCTAssertEqual(workspace.assignmentCount(for: child), 2)
            XCTAssertEqual(workspace.assignmentCount(for: grandchild), 1)

            // An Event row for the parent keeps the stack sorted into the
            // grandchild; the child's row does not keep the parent's stack.
            @MainActor func board(_ rows: [OrganizeFilterRow]) -> Set<String> {
                var search = OrganizeSearchFilter()
                search.groups = [OrganizeFilterGroup(rows: rows)]
                return Set(workspace.visibleStacks(result, hideSorted: false, search: search).map(\.id))
            }
            XCTAssertEqual(board([.events([parent])]), [ownStack.id, childStack.id, grandchildStack.id])
            XCTAssertEqual(board([.events([child])]), [childStack.id, grandchildStack.id])
            XCTAssertEqual(board([.events([grandchild])]), [grandchildStack.id])
            // The sidebar rows scope the same way: a parent filter keeps
            // the whole subtree, a child filter drops the parent's row.
            @MainActor func rows(_ filterRows: [OrganizeFilterRow]) -> Set<UUID> {
                var search = OrganizeSearchFilter()
                search.groups = [OrganizeFilterGroup(rows: filterRows)]
                return Set(workspace.sidebarRows(matching: "", applying: search).map(\.event.id))
            }
            XCTAssertEqual(rows([.events([parent])]), [parent, child, grandchild])
            XCTAssertEqual(rows([.events([child])]), [child, grandchild])
            XCTAssertEqual(rows([.events([grandchild])]), [grandchild])

            // Subevent photos stay in the day sections with everything
            // else. The dot says which tag they belong to.
            await workspace.refreshEvent(parent)
            let parentStacks = try XCTUnwrap(workspace.eventStacks[parent])
            XCTAssertEqual(Set(parentStacks.map(\.id)), [ownStack.id, childStack.id, grandchildStack.id])
            let parentGroups = workspace.eventBoardGroups(parent, stacks: parentStacks, grouping: .day, sort: .oldestFirst)
            XCTAssertFalse(parentGroups.contains { $0.id.hasPrefix("subevent|") })
            XCTAssertEqual(Set(parentGroups.flatMap(\.stacks).map(\.id)), [ownStack.id, childStack.id, grandchildStack.id])

            await workspace.refreshEvent(child)
            let childStacks = try XCTUnwrap(workspace.eventStacks[child])
            XCTAssertEqual(Set(childStacks.map(\.id)), [childStack.id, grandchildStack.id])
            let childGroups = workspace.eventBoardGroups(child, stacks: childStacks, grouping: .day, sort: .oldestFirst)
            XCTAssertFalse(childGroups.contains { $0.id.hasPrefix("subevent|") })
            XCTAssertEqual(Set(childGroups.flatMap(\.stacks).map(\.id)), [childStack.id, grandchildStack.id])
            XCTAssertFalse(childStacks.contains { $0.id == ownStack.id })

            await workspace.refreshEvent(grandchild)
            XCTAssertEqual(workspace.eventStacks[grandchild]?.map(\.id), [grandchildStack.id])
        }
    }

    /// The parent board's Event rows scope to its family: an "is none of"
    /// pick on a subevent hides that whole branch, "is any of" keeps only
    /// it, and a pick outside the family — carried over from an unsorted
    /// board's panel — is ignored instead of emptying the board.
    func testEventBoardFiltersSubeventsAndTagsTheirStacks() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            // Separate folders keep the files from burst-grouping — each
            // lands as its own stack.
            try writeOrganizerARW(unsorted.appendingPathComponent("Roll A/DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            try writeOrganizerARW(unsorted.appendingPathComponent("Roll B/DSC00002.ARW"), "2026:08:26 10:01:00", "000")
            try writeOrganizerARW(unsorted.appendingPathComponent("Roll C/DSC00003.ARW"), "2026:08:26 10:02:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            let byName = Dictionary(uniqueKeysWithValues: result.stacks.map { ($0.coverItem.primary.name, $0) })
            let ownStack = try XCTUnwrap(byName["DSC00001.ARW"])
            let childStack = try XCTUnwrap(byName["DSC00002.ARW"])
            let grandchildStack = try XCTUnwrap(byName["DSC00003.ARW"])

            let parent = try XCTUnwrap(workspace.createEvent(name: "TRIP2026", date: organizerDay("2026-08-21"), policy: .buffer))
            let child = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parent))
            let grandchild = try XCTUnwrap(workspace.createEvent(name: "Latte Art", date: organizerDay("2026-08-24"), policy: nil, parentEventID: child))
            let other = try XCTUnwrap(workspace.createEvent(name: "Japan 2026", date: organizerDay("2026-08-27"), policy: .buffer))

            workspace.assign(stackIDs: [ownStack.id], from: location.id, to: parent)
            workspace.assign(stackIDs: [childStack.id], from: location.id, to: child)
            workspace.assign(stackIDs: [grandchildStack.id], from: location.id, to: grandchild)
            await workspace.refreshEvent(parent)

            @MainActor func board(_ rows: [OrganizeFilterRow]) -> Set<String> {
                var search = OrganizeSearchFilter()
                search.groups = [OrganizeFilterGroup(rows: rows)]
                return Set(workspace.visibleEventStacks(parent, search: search).map(\.id))
            }

            // "is none of" the child hides its whole branch — the
            // grandchild goes with it — while the parent's own stack stays.
            XCTAssertEqual(board([.events([child], exclude: true)]), [ownStack.id])
            // "is any of" keeps only that branch.
            XCTAssertEqual(board([.events([child])]), [childStack.id, grandchildStack.id])
            // Excluding just the grandchild leaves the child's own stack.
            XCTAssertEqual(board([.events([grandchild], exclude: true)]), [ownStack.id, childStack.id])

            // A pick outside the family never filters this board — an
            // Unsorted filter for another event cannot blank TRIP2026, and
            // "Not Sorted Yet" is not a family member either.
            let all: Set<String> = [ownStack.id, childStack.id, grandchildStack.id]
            XCTAssertEqual(board([.events([other])]), all)
            XCTAssertEqual(board([.events([other], exclude: true)]), all)
            XCTAssertEqual(board([.events([], unsorted: true)]), all)
            // Mixing a family pick with a foreign one still applies the
            // family half.
            XCTAssertEqual(board([.events([child, other], unsorted: true)]), [childStack.id, grandchildStack.id])

            // The header chips write the same "is none of" rows: tapping
            // the child's chip hides the branch, tapping again restores it.
            workspace.search = OrganizeSearchFilter()
            workspace.search.toggleEventExclusion(child)
            XCTAssertEqual(workspace.search.excludedEventIDs, [child])
            XCTAssertEqual(Set(workspace.visibleEventStacks(parent, search: workspace.search).map(\.id)), [ownStack.id])
            workspace.search.toggleEventExclusion(child)
            XCTAssertEqual(Set(workspace.visibleEventStacks(parent, search: workspace.search).map(\.id)), all)

            // The header chips are the direct subevents only.
            XCTAssertEqual(workspace.subevents(of: parent).map(\.id), [child])
            XCTAssertEqual(workspace.subevents(of: child).map(\.id), [grandchild])

            // The dot is the owning subevent — a grandchild's photos wear
            // the grandchild's color, not the direct child's. A top-level
            // event's own photos wear none. A subevent's photos keep the
            // dot on that subevent's own board.
            let boardByName = Dictionary(uniqueKeysWithValues: try XCTUnwrap(workspace.eventStacks[parent]).map {
                ($0.coverItem.primary.name, $0)
            })
            XCTAssertEqual(workspace.subeventTag(for: try XCTUnwrap(boardByName["DSC00002.ARW"]), in: parent)?.id, child)
            let grandchildTag = try XCTUnwrap(workspace.subeventTag(for: try XCTUnwrap(boardByName["DSC00003.ARW"]), in: parent))
            XCTAssertEqual(grandchildTag.id, grandchild)
            XCTAssertEqual(EventPalette.color(for: grandchildTag.id), EventPalette.color(for: grandchild))
            XCTAssertNil(workspace.subeventTag(for: try XCTUnwrap(boardByName["DSC00001.ARW"]), in: parent))
            // On the child's board the same stack is still a descendant;
            // on the grandchild's own board it wears no tag.
            XCTAssertEqual(workspace.subeventTag(for: try XCTUnwrap(boardByName["DSC00003.ARW"]), in: child)?.id, grandchild)
            XCTAssertEqual(workspace.subeventTag(for: try XCTUnwrap(boardByName["DSC00003.ARW"]), in: grandchild)?.id, grandchild)
            XCTAssertEqual(workspace.subeventTag(for: try XCTUnwrap(boardByName["DSC00002.ARW"]), in: child)?.id, child)

            // Applied photos sit in Originals, not the folder they were
            // imported from. The filter still has to see which subevent
            // owns them, or "is none of" leaves the count unchanged.
            let childEvent = try XCTUnwrap(workspace.event(child))
            let childAssignment = try XCTUnwrap(model.configuration.photoEventAssignments.first { $0.eventID == child })
            let implied = try XCTUnwrap(workspace.locations.impliedDrivePath(
                for: childAssignment,
                event: childEvent,
                policy: workspace.locations.resolvedPolicy(for: childEvent)
            ))
            let atCardCopy = OrganizeFile(
                literalPath: implied,
                size: childAssignment.fileSize,
                modifiedAt: childAssignment.modifiedAt
            )
            XCTAssertEqual(workspace.assignment(for: atCardCopy)?.eventID, child)
            var standardized = atCardCopy
            standardized.path = implied
            XCTAssertEqual(workspace.assignment(for: standardized)?.eventID, child)
            var hidden = workspace.search
            hidden.groups = [OrganizeFilterGroup(rows: [.events([child], exclude: true)])]
            var cardCopyStack = try XCTUnwrap(boardByName["DSC00002.ARW"])
            cardCopyStack.items[0].primary = atCardCopy
            workspace.eventStacks[parent] = [cardCopyStack]
            XCTAssertTrue(workspace.visibleEventStacks(parent, search: hidden).isEmpty)
        }
    }

    /// The shipping layout: a Buffer parent with a private (NAS-only)
    /// subevent, burst-prefixed frames, and boards that draw files from
    /// whichever place holds them — the import source, the private or
    /// Buffer `Originals/<Camera>`, the NAS archive, or a differently cased
    /// spelling of any of those. Every Event operator must resolve the
    /// subevent the same way at each of those paths, and a burst's
    /// membership is the union of its frames: "is none of" a tag drops a
    /// stack when any frame carries the tag, "is any of" keeps it.
    func testSubeventOperatorsResolveBurstsAtEveryStoragePath() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            let roll = unsorted.appendingPathComponent("Transfer 1", isDirectory: true)
            // Two prefix-trusted bursts seconds apart in one folder, plus a
            // single — the tag's burst sits right next to the parent's.
            for (index, name) in ["B0001_DSC00001", "B0001_DSC00002", "B0001_DSC00003"].enumerated() {
                try writeOrganizerARW(roll.appendingPathComponent("\(name).ARW"), "2026:08:24 03:04:25", "\(index)00")
            }
            for (index, name) in ["B0002_DSC00004", "B0002_DSC00005"].enumerated() {
                try writeOrganizerARW(roll.appendingPathComponent("\(name).ARW"), "2026:08:24 03:04:32", "\(index)00")
            }
            try writeOrganizerARW(roll.appendingPathComponent("DSC00006.ARW"), "2026:08:24 03:05:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            let tagBurst = try XCTUnwrap(result.stacks.first { $0.burstLabel == "B0001" })
            let parentBurst = try XCTUnwrap(result.stacks.first { $0.burstLabel == "B0002" })
            let single = try XCTUnwrap(result.stacks.first { $0.coverItem.primary.name == "DSC00006.ARW" })
            XCTAssertEqual(tagBurst.items.count, 3)
            XCTAssertEqual(parentBurst.items.count, 2)

            let parent = try XCTUnwrap(workspace.createEvent(name: "Trip", date: organizerDay("2026-08-23"), policy: .buffer))
            let tag = try XCTUnwrap(workspace.createEvent(name: "Tag A", date: organizerDay("2026-08-24"), policy: .archiveOnly, parentEventID: parent))
            workspace.assign(stackIDs: [tagBurst.id], from: location.id, to: tag)
            workspace.assign(stackIDs: [parentBurst.id, single.id], from: location.id, to: parent)

            let tagEvent = try XCTUnwrap(workspace.event(tag))
            let locations = workspace.locations
            XCTAssertEqual(locations.resolvedPolicy(for: tagEvent), .archiveOnly)

            /// Every spelling a board may draw one assigned file at.
            @MainActor func variants(of file: OrganizeFile) throws -> [String: OrganizeFile] {
                let assignment = try XCTUnwrap(model.configuration.photoEventAssignments.first {
                    EventsWorkspace.sourceKey($0) == file.pathKey
                })
                let owner = try XCTUnwrap(workspace.event(assignment.eventID))
                let policy = locations.resolvedPolicy(for: owner)
                let other: EventStoragePolicy = policy == .buffer ? .archiveOnly : .buffer
                func literal(_ path: String?) throws -> OrganizeFile {
                    OrganizeFile(literalPath: try XCTUnwrap(path), size: assignment.fileSize, modifiedAt: assignment.modifiedAt)
                }
                func standardized(_ url: URL?) throws -> OrganizeFile {
                    OrganizeFile(path: try XCTUnwrap(url).path, size: assignment.fileSize, modifiedAt: assignment.modifiedAt)
                }
                let cardCopy = try literal(locations.impliedDrivePath(for: assignment, event: owner, policy: policy))
                return [
                    "source": file,
                    "card copy": cardCopy,
                    "other drive": try standardized(locations.driveURL(for: assignment, event: owner, policy: other)),
                    "nas": try standardized(locations.archiveURL(for: assignment, event: owner)),
                    "card copy, upper case": try literal(cardCopy.path.uppercased()),
                ]
            }

            /// The three stacks as a board would draw them at one place.
            @MainActor func stacks(at place: String) throws -> [OrganizeStack] {
                try [tagBurst, parentBurst, single].map { stack in
                    var moved = stack
                    for index in moved.items.indices {
                        moved.items[index].primary = try XCTUnwrap(variants(of: stack.items[index].primary)[place])
                    }
                    return moved
                }
            }

            @MainActor func board(_ stacks: [OrganizeStack], _ row: OrganizeFilterRow) -> Set<String> {
                workspace.eventStacks[parent] = stacks
                var search = OrganizeSearchFilter()
                search.groups = [OrganizeFilterGroup(rows: [row])]
                return Set(workspace.visibleEventStacks(parent, search: search).map(\.id))
            }

            let all: Set<String> = [tagBurst.id, parentBurst.id, single.id]
            for place in ["source", "card copy", "other drive", "nas", "card copy, upper case"] {
                let drawn = try stacks(at: place)
                // Every frame resolves to its own event — the lookup, the
                // tile's tag dot, and the filter all agree.
                for frame in drawn[0].items {
                    XCTAssertEqual(workspace.assignment(for: frame.primary)?.eventID, tag, "\(place): \(frame.primary.name)")
                }
                for frame in drawn[1].items + drawn[2].items {
                    XCTAssertEqual(workspace.assignment(for: frame.primary)?.eventID, parent, "\(place): \(frame.primary.name)")
                }
                XCTAssertEqual(workspace.subeventTag(for: drawn[0], in: parent)?.id, tag, place)
                XCTAssertNil(workspace.subeventTag(for: drawn[1], in: parent), place)

                XCTAssertEqual(board(drawn, .events([tag], operator: .noneOf)), [parentBurst.id, single.id], place)
                XCTAssertEqual(board(drawn, .events([tag], operator: .anyOf)), [tagBurst.id], place)
                XCTAssertEqual(board(drawn, .events([tag], operator: .allOf)), [tagBurst.id], place)
                XCTAssertEqual(board(drawn, .events([tag], operator: .notAllOf)), [parentBurst.id, single.id], place)
                // The parent pick covers its subevent's stacks too.
                XCTAssertEqual(board(drawn, .events([parent], operator: .anyOf)), all, place)
                XCTAssertTrue(board(drawn, .events([parent], operator: .noneOf)).isEmpty, place)
                // The header chip writes the same exclusion.
                var chip = OrganizeSearchFilter()
                chip.toggleEventExclusion(tag)
                workspace.eventStacks[parent] = drawn
                XCTAssertEqual(Set(workspace.visibleEventStacks(parent, search: chip).map(\.id)), [parentBurst.id, single.id], place)
            }

            // A burst with mixed membership is one subject: whether its
            // cover frame or another frame carries the tag, "is none of"
            // drops the whole stack and "is any of" keeps it. The preview
            // badge reads such a stack as mixed, not as the parent's.
            let cardCopy = try stacks(at: "card copy")
            for coverTagged in [true, false] {
                var mixed = cardCopy[1]
                let tagFrame = cardCopy[0].items[0]
                if coverTagged {
                    mixed.items.insert(tagFrame, at: mixed.items.count / 2)
                    XCTAssertEqual(workspace.assignment(for: mixed.coverItem.primary)?.eventID, tag)
                } else {
                    mixed.items.append(tagFrame)
                    XCTAssertEqual(workspace.assignment(for: mixed.coverItem.primary)?.eventID, parent)
                }
                XCTAssertTrue(workspace.assignedEvent(for: mixed).mixed)
                XCTAssertNil(workspace.assignedEvent(for: mixed).event)
                let drawn = [mixed, cardCopy[2]]
                XCTAssertEqual(board(drawn, .events([tag], operator: .noneOf)), [single.id], "cover tagged: \(coverTagged)")
                XCTAssertEqual(board(drawn, .events([tag], operator: .anyOf)), [parentBurst.id], "cover tagged: \(coverTagged)")
                XCTAssertEqual(board(drawn, .events([tag], operator: .allOf)), [parentBurst.id], "cover tagged: \(coverTagged)")
                XCTAssertEqual(board(drawn, .events([tag], operator: .notAllOf)), [single.id], "cover tagged: \(coverTagged)")
            }

            // Unsorted board: a burst with one frame in the tag and the rest
            // still unsorted is not "Not Sorted Yet", and "is none of" the
            // tag drops it there as well.
            workspace.unassign(stackIDs: [parentBurst.id], from: location.id)
            var search = OrganizeSearchFilter()
            var partial = result
            var mixedSource = parentBurst
            mixedSource.items.append(tagBurst.items[0])
            partial.stacks = [mixedSource, single]
            search.groups = [OrganizeFilterGroup(rows: [.events([tag], operator: .noneOf)])]
            XCTAssertEqual(workspace.visibleStacks(partial, hideSorted: false, search: search).map(\.id), [single.id])
            search.groups = [OrganizeFilterGroup(rows: [.events([], unsorted: true)])]
            XCTAssertTrue(workspace.visibleStacks(partial, hideSorted: false, search: search).isEmpty)
        }
    }

    func testApplySortsSubeventFilesIntoTheNestedFolder() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/DSC00001.ARW"), "2026:08:23 10:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let stack = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks.first)

            let parent = try XCTUnwrap(workspace.createEvent(name: "TRIP2026", date: organizerDay("2026-08-21"), policy: .archiveOnly))
            let child = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parent))
            workspace.assign(stackIDs: [stack.id], from: location.id, to: child)

            let plan = EventsWorkspace.buildApplyPlan(
                events: [try XCTUnwrap(workspace.event(child))],
                configuration: model.configuration,
                locations: workspace.locations,
                onlyUnder: unsorted.path,
                title: "Apply",
                unsortedRoots: [unsorted]
            )
            // The subevent inherits its parent's private policy.
            XCTAssertEqual(plan.groups.first?.isPrivate, true)
            XCTAssertEqual(plan.moveCount, 1)

            workspace.performApply(plan)
            try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }

            let nested = root.appendingPathComponent("Drive/.Camera Toolkit/Private/2026/2026-08-21 TRIP2026/2026-08-23 Matcha/Originals/Sony A7V/DSC00001.ARW")
            XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-23 Matcha").path))
        }
    }

    func testSearchFiltersSidebarRowsLocationsAndVisibleDays() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00002.ARW"), "2026:08:26 10:00:00", "400")
            try writeOrganizerARW(unsorted.appendingPathComponent("Extra/DSC00009.ARW"), "2026:08:26 11:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            let burst = try XCTUnwrap(result.stacks.first { $0.isBurst })
            let single = try XCTUnwrap(result.stacks.first { $0.coverItem.primary.name == "DSC00009.ARW" })

            let parent = try XCTUnwrap(workspace.createEvent(name: "TRIP2026", date: organizerDay("2026-08-21"), policy: .buffer))
            let child = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parent))
            let other = try XCTUnwrap(workspace.createEvent(name: "Other Trip", date: organizerDay("2026-08-21"), policy: .buffer))

            // Sidebar events: a parent-name hit reveals the subevent row too;
            // a child-name hit keeps only the matching child.
            XCTAssertEqual(Set(workspace.sidebarRows(matching: "trip").map(\.event.id)), [parent, child])
            XCTAssertEqual(workspace.sidebarRows(matching: "matcha").map(\.event.id), [child])
            XCTAssertEqual(Set(workspace.sidebarRows(matching: "").map(\.event.id)), [parent, child, other])

            // Unsorted locations match on name or path.
            XCTAssertEqual(workspace.unsortedLocations(matching: "unsorted a7v").map(\.id), [location.id])
            XCTAssertEqual(workspace.unsortedLocations(matching: unsorted.path).map(\.id), [location.id])
            XCTAssertTrue(workspace.unsortedLocations(matching: "nowhere").isEmpty)

            // Board days match file name, burst label, and origin subfolder.
            XCTAssertEqual(workspace.visibleDays(result, hideSorted: false, matching: "dsc00009").flatMap(\.stacks).map(\.id), [single.id])
            XCTAssertEqual(workspace.visibleDays(result, hideSorted: false, matching: "b0001").flatMap(\.stacks).map(\.id), [burst.id])
            XCTAssertEqual(workspace.visibleDays(result, hideSorted: false, matching: "extra").flatMap(\.stacks).map(\.id), [single.id])
            XCTAssertEqual(workspace.visibleDays(result, hideSorted: false, matching: "zzz").flatMap(\.stacks).count, 0)

            // The assigned event's breadcrumb title matches — the parent's
            // name still finds a stack sorted into the subevent.
            workspace.assign(stackIDs: [burst.id], from: location.id, to: child)
            XCTAssertEqual(workspace.visibleDays(result, hideSorted: false, matching: "matcha").flatMap(\.stacks).map(\.id), [burst.id])
            XCTAssertEqual(workspace.visibleDays(result, hideSorted: false, matching: "trip").flatMap(\.stacks).map(\.id), [burst.id])

            // hideSorted composes with the query: a sorted stack matching the
            // query is still hidden, an unsorted match stays.
            XCTAssertTrue(workspace.visibleDays(result, hideSorted: true, matching: "b0001").isEmpty)
            XCTAssertEqual(workspace.visibleDays(result, hideSorted: true, matching: "dsc00009").flatMap(\.stacks).map(\.id), [single.id])

            // Discovered drive events filter by name for the banner.
            let cardCopy = root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-26 Found Day/Originals/Sony A7V", isDirectory: true)
            try writeOrganizerARW(cardCopy.appendingPathComponent("DSC00050.ARW"), "2026:08:26 12:00:00", "000")
            workspace.discoverDriveEvents()
            try await waitUntil { !workspace.discoveredDriveEvents.isEmpty }
            XCTAssertEqual(workspace.discoveredDriveEvents(matching: "found day").count, 1)
            XCTAssertEqual(workspace.discoveredDriveEvents(matching: "").count, workspace.discoveredDriveEvents.count)
            XCTAssertTrue(workspace.discoveredDriveEvents(matching: "zzz").isEmpty)
        }
    }

    /// An edit in the event's `Edited/<Tag>/` links to its original by
    /// file-name stem: the original's tile gets the tag, and the board's
    /// Edit tag row keeps (any of) or drops (none of) it.
    func testEditedFolderTagsItsOriginalAndTheBoardFiltersOnIt() async throws {
        try await withOrganizerSandbox { root, _, workspace in
            let event = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            let folder = root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-26 Beach Day", isDirectory: true)
            try writeOrganizerARW(folder.appendingPathComponent("Originals/Sony A7V/DSC00001.ARW"), "2026:08:26 12:00:00", "000")
            try writeOrganizerARW(folder.appendingPathComponent("Originals/Sony A7V/DSC00002.ARW"), "2026:08:26 12:05:00", "000")
            let edit = folder.appendingPathComponent("Edited/Photomator/DSC00001-edit.jpg")
            try FileManager.default.createDirectory(at: edit.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("jpeg".utf8).write(to: edit)

            workspace.discoverDriveEvents()
            try await waitUntil { !workspace.discoveredDriveEvents.isEmpty }
            XCTAssertFalse(workspace.discoveredDriveEvents.contains { $0.filesRootPath.contains("/Edited") })
            workspace.adoptDiscoveredDriveEvents()
            await workspace.refreshEvent(event)
            try await waitUntil { workspace.eventEditTags[event]?.tagsByItemID.isEmpty == false }

            let stacks = workspace.eventStacks[event] ?? []
            XCTAssertEqual(stacks.count, 2)
            let tagged = stacks.filter { !workspace.editTagList(for: $0, in: event).isEmpty }
            XCTAssertEqual(tagged.map(\.coverItem.primary.name), ["DSC00001.ARW"])
            XCTAssertEqual(workspace.boardEditTags(for: stacks, scope: workspace.scopeIDs(event)).map(\.tag), ["Photomator"])

            var search = OrganizeSearchFilter()
            search.addCondition(.editTags(["Photomator"]))
            XCTAssertEqual(workspace.visibleEventStacks(event, search: search).map(\.coverItem.primary.name), ["DSC00001.ARW"])
            search = OrganizeSearchFilter()
            search.addCondition(.editTags(["Photomator"], exclude: true))
            XCTAssertEqual(workspace.visibleEventStacks(event, search: search).map(\.coverItem.primary.name), ["DSC00002.ARW"])
        }
    }

    func testEventPeopleDriveChipsAndSidebarPersonFilter() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            let hike = try XCTUnwrap(workspace.createEvent(name: "Hike", date: organizerDay("2026-08-27"), policy: .buffer))
            let modified = Date(timeIntervalSince1970: 1_752_000_000)
            model.updateConfiguration { configuration in
                configuration.photoEventAssignments.append(PhotoEventAssignment(
                    sourceRootPath: "/Card/DCIM",
                    relativePath: "DSC00001.ARW",
                    fileSize: 4_096,
                    modifiedAt: modified,
                    eventID: beach,
                    deviceID: "sony-a7v"
                ))
                configuration.photoEventAssignments.append(PhotoEventAssignment(
                    sourceRootPath: "/Card/DCIM",
                    relativePath: "DSC00002.ARW",
                    fileSize: 4_096,
                    modifiedAt: modified,
                    eventID: hike,
                    deviceID: "sony-a7v"
                ))
            }

            // Seed the face index as if a scan ran: Dad confirmed on the
            // Beach Day photo, an unnamed group on the Hike photo.
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let stranger = try store.createPerson(name: "Person 1", isRoster: false)
            let beachPhoto = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey("/Card/DCIM/DSC00001.ARW"),
                path: "/Card/DCIM/DSC00001.ARW",
                fileName: "DSC00001.ARW",
                byteCount: 4_096,
                modifiedAt: modified,
                scanGrade: .low
            )
            let hikePhoto = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey("/Card/DCIM/DSC00002.ARW"),
                path: "/Card/DCIM/DSC00002.ARW",
                fileName: "DSC00002.ARW",
                byteCount: 4_096,
                modifiedAt: modified,
                scanGrade: .low
            )
            let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
            try store.replaceFaces(photo: beachPhoto, faces: [
                FaceRecord(photoID: beachPhoto.pathKey, personID: dad.id, box: box, detScore: 0.9, embedding: [0.5, 0.5], state: .confirmed),
            ])
            try store.replaceFaces(photo: hikePhoto, faces: [
                FaceRecord(photoID: hikePhoto.pathKey, personID: stranger.id, box: box, detScore: 0.9, embedding: [0.5, 0.5], state: .other),
            ])

            // event.people: roster people only, per event.
            XCTAssertEqual(workspace.eventPeople(beach).map(\.name), ["Dad"])
            XCTAssertEqual(workspace.eventPeople(hike), [])

            // Sidebar search filters events by roster person name; unnamed
            // group labels never leak into event filtering.
            XCTAssertEqual(workspace.sidebarRows(matching: "dad").map(\.event.id), [beach])
            XCTAssertTrue(workspace.sidebarRows(matching: "person").isEmpty)

            // The popover's People rows hide sidebar events too — an event
            // stays when a picked roster person is in its event.people.
            let peopleFilter = { (ids: Set<UUID>) -> OrganizeSearchFilter in
                var search = OrganizeSearchFilter()
                search.groups = [OrganizeFilterGroup(rows: [.people(ids)])]
                return search
            }
            XCTAssertEqual(workspace.sidebarRows(matching: "", applying: peopleFilter([dad.id])).map(\.event.id), [beach])
            // The unnamed group is a valid board pick, but sidebar events
            // only know roster people — a group-only pick hides them all.
            XCTAssertTrue(workspace.sidebarRows(matching: "", applying: peopleFilter([stranger.id])).isEmpty)
            // People rows AND with the text needle.
            XCTAssertEqual(workspace.sidebarRows(matching: "beach", applying: peopleFilter([dad.id])).map(\.event.id), [beach])
            XCTAssertTrue(workspace.sidebarRows(matching: "hike", applying: peopleFilter([dad.id])).isEmpty)
        }
    }

    /// The filter builder's full loop on a real scan: media, day range,
    /// event (incl. Not Sorted Yet), and face-catalog people — condition
    /// rows ANDed inside a group, groups ORed, and the text needle on top.
    /// End to end through the face catalog: "is exactly A, B" keeps only
    /// stacks whose confirmed approved people are A and B and whose frames
    /// hold no other face — another approved person, an unnamed group, a
    /// "looks like" suggestion, or a detection never grouped all count as
    /// someone else. A burst uses the union of its frames.
    func testPeopleIsExactlyReadsEveryFaceOnTheBoard() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            let names = [
                "DSC00001.ARW", "DSC00002.ARW", "DSC00003.ARW", "DSC00004.ARW",
                "DSC00005.ARW", "DSC00006.ARW", "DSC00007.ARW", "DSC00008.ARW",
            ]
            for (index, name) in names.enumerated() {
                try writeOrganizerARW(
                    unsorted.appendingPathComponent("Transfer/\(name)"),
                    "2026:08:26 1\(index):00:00",
                    "000"
                )
            }
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer/B0001_DSC00011.ARW"), "2026:08:27 10:00:00", "100")
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer/B0001_DSC00012.ARW"), "2026:08:27 10:00:00", "400")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            func stack(_ name: String) throws -> OrganizeStack {
                try XCTUnwrap(result.stacks.first { $0.coverItem.primary.name == name }, name)
            }
            let bothOnly = try stack("DSC00001.ARW")
            let onlyA = try stack("DSC00002.ARW")
            let onlyB = try stack("DSC00003.ARW")
            let withC = try stack("DSC00004.ARW")
            let withGroup = try stack("DSC00005.ARW")
            let withUngrouped = try stack("DSC00006.ARW")
            let withSuggestion = try stack("DSC00007.ARW")
            let faceless = try stack("DSC00008.ARW")
            let burst = try XCTUnwrap(result.stacks.first { $0.isBurst })
            XCTAssertEqual(burst.items.count, 2)
            XCTAssertEqual(result.stacks.count, 9)

            _ = try CatalogStore(url: root.appendingPathComponent("catalog.sqlite")).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let personA = try store.createPerson(name: "Person A", isRoster: true)
            let personB = try store.createPerson(name: "Person B", isRoster: true)
            let personC = try store.createPerson(name: "Person C", isRoster: true)
            let group = try store.createPerson(name: "Person 1", isRoster: false)
            let suggestion = try store.createPerson(name: "Looks like C", isRoster: false)
            // (person, state); nil person is a detection never grouped.
            func seed(_ file: OrganizeFile, _ faces: [(FacePerson?, FaceState)]) throws {
                try store.replaceFaces(
                    photo: FacePhotoRecord(
                        pathKey: file.pathKey,
                        path: file.path,
                        fileName: file.name,
                        byteCount: file.size,
                        modifiedAt: file.modifiedAt,
                        scanGrade: .low
                    ),
                    faces: faces.enumerated().map { index, face in
                        FaceRecord(
                            photoID: file.pathKey,
                            personID: face.0?.id,
                            box: NormalizedFaceBox(x: 0.25 * Double(index), y: 0.1, width: 0.2, height: 0.2),
                            detScore: 0.9,
                            embedding: [0.5, 0.5],
                            state: face.1
                        )
                    }
                )
            }
            try seed(bothOnly.coverItem.primary, [(personA, .confirmed), (personB, .confirmed)])
            try seed(onlyA.coverItem.primary, [(personA, .confirmed)])
            try seed(onlyB.coverItem.primary, [(personB, .confirmed)])
            try seed(withC.coverItem.primary, [(personA, .confirmed), (personB, .confirmed), (personC, .confirmed)])
            try seed(withGroup.coverItem.primary, [(personA, .confirmed), (personB, .confirmed), (group, .other)])
            try seed(withUngrouped.coverItem.primary, [(personA, .confirmed), (personB, .confirmed), (nil, .cached)])
            try seed(withSuggestion.coverItem.primary, [(personA, .confirmed), (personB, .confirmed), (suggestion, .proposed)])
            try seed(burst.items[0].primary, [(personA, .confirmed)])
            try seed(burst.items[1].primary, [(personB, .confirmed)])

            // The index: approved people per stack, and which stacks hold
            // anyone else.
            let people = workspace.boardPeople(for: result.stacks)
            XCTAssertEqual(people.byStackID[burst.id], [personA.id, personB.id])
            XCTAssertEqual(people.byStackID[withGroup.id], [personA.id, personB.id])
            XCTAssertEqual(people.othersStackIDs, [withGroup.id, withUngrouped.id, withSuggestion.id])

            @MainActor func board(_ rows: [OrganizeFilterRow]) -> Set<String> {
                var search = OrganizeSearchFilter()
                search.groups = [OrganizeFilterGroup(rows: rows)]
                return Set(workspace.visibleStacks(result, hideSorted: false, search: search).map(\.id))
            }
            XCTAssertEqual(board([.people([personA.id, personB.id], operator: .exactly)]), [bothOnly.id, burst.id])
            XCTAssertEqual(
                board([.people([personA.id, personB.id], operator: .notExactly)]),
                [onlyA.id, onlyB.id, withC.id, withGroup.id, withUngrouped.id, withSuggestion.id, faceless.id]
            )
            // "is all of" keeps its superset meaning.
            XCTAssertEqual(
                board([.people([personA.id, personB.id], operator: .allOf)]),
                [bothOnly.id, withC.id, withGroup.id, withUngrouped.id, withSuggestion.id, burst.id]
            )
            // ANDed with a Date row: only the single on the first day.
            let firstDay = Calendar.current.startOfDay(for: bothOnly.captureDate)
            XCTAssertEqual(
                board([.people([personA.id, personB.id], operator: .exactly), .days(from: firstDay, to: firstDay)]),
                [bothOnly.id]
            )
        }
    }

    func testStructuredBoardSearchFiltersByMediaDateEventAndPeople() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00002.ARW"), "2026:08:26 10:00:00", "400")
            try writeOrganizerARW(unsorted.appendingPathComponent("Extra/DSC00009.ARW"), "2026:08:27 11:00:00", "000")
            try organizerWrite(unsorted.appendingPathComponent("Extra/C0001.MP4"), "video")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            let burst = try XCTUnwrap(result.stacks.first { $0.isBurst })
            let single = try XCTUnwrap(result.stacks.first { $0.coverItem.primary.name == "DSC00009.ARW" })
            let clip = try XCTUnwrap(result.stacks.first { $0.coverItem.primary.name == "C0001.MP4" })
            @MainActor func board(_ search: OrganizeSearchFilter, hideSorted: Bool = false) -> Set<String> {
                Set(workspace.visibleStacks(result, hideSorted: hideSorted, search: search).map(\.id))
            }
            func filter(_ rows: [OrganizeFilterRow], text: String = "") -> OrganizeSearchFilter {
                var search = OrganizeSearchFilter()
                search.text = text
                search.groups = [OrganizeFilterGroup(rows: rows)]
                return search
            }

            // Empty search shows everything.
            XCTAssertEqual(board(OrganizeSearchFilter()), [burst.id, single.id, clip.id])

            // Media rows — include and exclude.
            XCTAssertEqual(board(filter([.media([.video])])), [clip.id])
            XCTAssertEqual(board(filter([.media([.raw])])), [burst.id, single.id])
            XCTAssertEqual(board(filter([.media([.video], exclude: true)])), [burst.id, single.id])

            // Date row — inclusive bounds on each stack's capture day.
            // The clip has no camera date; the scan's clock-offset
            // correction still lands it on a day near the RAWs', so
            // compare against the days the scanner actually assigned.
            let calendar = Calendar.current
            let burstDay = calendar.startOfDay(for: burst.captureDate)
            let singleDay = calendar.startOfDay(for: single.captureDate)
            let clipDay = calendar.startOfDay(for: clip.captureDate)
            XCTAssertNotEqual(burstDay, singleDay)

            var search = filter([.days(from: burstDay, to: burstDay)])
            XCTAssertTrue(board(search).contains(burst.id))
            XCTAssertFalse(board(search).contains(single.id))
            XCTAssertEqual(board(search).contains(clip.id), clipDay == burstDay)

            search = filter([.days(from: singleDay, to: singleDay)])
            XCTAssertTrue(board(search).contains(single.id))
            XCTAssertFalse(board(search).contains(burst.id))

            search = filter([.days(from: burstDay, to: singleDay)])
            XCTAssertTrue(board(search).isSuperset(of: [burst.id, single.id]))

            // A range starting after the last capture day matches nothing.
            search = filter([.days(from: calendar.date(byAdding: .day, value: 1, to: singleDay), to: nil)])
            XCTAssertTrue(board(search).isEmpty)

            // Event rows, including "Not Sorted Yet" and "is none of".
            let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: burstDay, policy: .buffer))
            workspace.assign(stackIDs: [burst.id], from: location.id, to: beach)
            XCTAssertEqual(board(filter([.events([beach])])), [burst.id])
            XCTAssertEqual(board(filter([.events([beach], unsorted: true)])), [burst.id, single.id, clip.id])
            XCTAssertEqual(board(filter([.events([], unsorted: true)])), [single.id, clip.id])
            XCTAssertEqual(board(filter([.events([beach], exclude: true)])), [single.id, clip.id])
            // hideSorted composes: the assigned burst drops out.
            XCTAssertEqual(board(OrganizeSearchFilter(), hideSorted: true), [single.id, clip.id])

            // People rows — seed the face index as if a scan ran: Dad
            // confirmed on the single, an unnamed group on the burst's cover.
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let group = try store.createPerson(name: "Person 1", isRoster: false)
            let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
            for (file, person, state) in [
                (single.coverItem.primary, dad, FaceState.confirmed),
                (burst.coverItem.primary, group, FaceState.other),
            ] as [(OrganizeFile, FacePerson, FaceState)] {
                try store.replaceFaces(
                    photo: FacePhotoRecord(
                        pathKey: file.pathKey,
                        path: file.path,
                        fileName: file.name,
                        byteCount: file.size,
                        modifiedAt: file.modifiedAt,
                        scanGrade: .low
                    ),
                    faces: [FaceRecord(photoID: file.pathKey, personID: person.id, box: box, detScore: 0.9, embedding: [0.5, 0.5], state: state)]
                )
            }

            // Picker options: approved people only — an Inbox face never
            // satisfies a People filter, so the unnamed group is not an
            // option and no stack "carries" it.
            let people = workspace.boardPeople(for: result.stacks)
            XCTAssertEqual(people.options.map(\.name), ["Dad"])
            XCTAssertEqual(people.byStackID[single.id], [dad.id])
            XCTAssertEqual(people.byStackID[burst.id], [])
            XCTAssertEqual(people.byStackID[clip.id], [])

            XCTAssertEqual(board(filter([.people([dad.id])])), [single.id])
            XCTAssertEqual(board(filter([.people([dad.id, group.id])])), [single.id])
            // "is none of": nothing carries the Inbox group, so every
            // stack passes.
            XCTAssertEqual(board(filter([.people([group.id], exclude: true)])), [burst.id, single.id, clip.id])

            // Rows in a group AND together — and with the text needle.
            search = filter([.people([dad.id, group.id]), .media([.raw]), .days(from: singleDay, to: singleDay)])
            XCTAssertEqual(board(search), [single.id])
            search = filter([.people([dad.id, group.id]), .media([.raw]), .days(from: singleDay, to: singleDay)], text: "dsc00009")
            XCTAssertEqual(board(search), [single.id])
            search = filter([.people([dad.id, group.id]), .media([.raw]), .days(from: singleDay, to: singleDay), .events([beach])])
            XCTAssertTrue(board(search).isEmpty)

            // Groups OR: "Dad's day" or "the clip".
            search = OrganizeSearchFilter()
            search.groups = [
                OrganizeFilterGroup(rows: [.people([dad.id]), .days(from: singleDay, to: singleDay)]),
                OrganizeFilterGroup(rows: [.media([.video])]),
            ]
            XCTAssertEqual(board(search), [single.id, clip.id])

            // The event board runs the same rows minus Event.
            workspace.eventStacks[beach] = [burst, single, clip]
            var eventSearch = OrganizeSearchFilter()
            eventSearch.groups = [OrganizeFilterGroup(rows: [.media([.video])])]
            XCTAssertEqual(workspace.visibleEventStacks(beach, search: eventSearch).map(\.id), [clip.id])
            eventSearch = OrganizeSearchFilter()
            eventSearch.groups = [OrganizeFilterGroup(rows: [.people([group.id])])]
            XCTAssertEqual(workspace.visibleEventStacks(beach, search: eventSearch).map(\.id), [])
            eventSearch = OrganizeSearchFilter()
            eventSearch.groups = [OrganizeFilterGroup(rows: [.people([dad.id])])]
            XCTAssertEqual(workspace.visibleEventStacks(beach, search: eventSearch).map(\.id), [single.id])
            XCTAssertEqual(workspace.visibleEventStacks(beach, search: OrganizeSearchFilter()).count, 3)

            // Event rows carried over from an unsorted board's panel are
            // dropped here — the board is one event already.
            eventSearch = OrganizeSearchFilter()
            eventSearch.groups = [OrganizeFilterGroup(rows: [.events([UUID()], unsorted: true)])]
            XCTAssertEqual(workspace.visibleEventStacks(beach, search: eventSearch).count, 3)
        }
    }

    func testBoardSearchMatchesStacksByPersonName() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("Batch 1/DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            try writeOrganizerARW(unsorted.appendingPathComponent("Batch 2/DSC00002.ARW"), "2026:08:26 11:00:00", "400")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            let samStack = try XCTUnwrap(result.stacks.first { $0.coverItem.primary.name == "DSC00001.ARW" })
            let groupStack = try XCTUnwrap(result.stacks.first { $0.coverItem.primary.name == "DSC00002.ARW" })

            // Seed the face index as if a scan ran: Sam confirmed on the
            // first photo, an Inbox cluster on the second.
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let sam = try store.createPerson(name: "Sam", isRoster: true)
            let group = try store.createPerson(name: "Person 1", isRoster: false)
            let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
            for (stack, person, state) in [
                (samStack, sam, FaceState.confirmed),
                (groupStack, group, FaceState.other),
            ] {
                let file = stack.coverItem.primary
                let photo = FacePhotoRecord(
                    pathKey: file.pathKey,
                    path: file.path,
                    fileName: file.name,
                    byteCount: file.size,
                    modifiedAt: file.modifiedAt,
                    scanGrade: .low
                )
                try store.replaceFaces(photo: photo, faces: [
                    FaceRecord(photoID: photo.pathKey, personID: person.id, box: box, detScore: 0.9, state: state),
                ])
            }

            // Typing an approved name keeps exactly the stacks whose files
            // carry that person's confirmed face — the catalog join needs
            // no filesystem reads. An Inbox face names no stack: a needle
            // matching its row's name still doesn't surface it.
            XCTAssertEqual(workspace.visibleDays(result, hideSorted: false, matching: "sam").flatMap(\.stacks).map(\.id), [samStack.id])
            XCTAssertEqual(workspace.visibleDays(result, hideSorted: false, matching: "person 1").flatMap(\.stacks).map(\.id), [])
            XCTAssertEqual(Set(workspace.visibleDays(result, hideSorted: false, matching: "").flatMap(\.stacks).map(\.id)), [samStack.id, groupStack.id])
            XCTAssertTrue(workspace.visibleDays(result, hideSorted: false, matching: "zzz").isEmpty)

            // File-name matching still works alongside person names.
            XCTAssertEqual(workspace.visibleDays(result, hideSorted: false, matching: "dsc00001").flatMap(\.stacks).map(\.id), [samStack.id])
        }
    }

    func testFaceScanRefusesUntilBurstGroupingFinishes() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Card", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            let location = addUnsorted(unsorted, to: model)

            // No scan result yet: face scan is gated on grouping existing.
            let noResultBlocker = try XCTUnwrap(workspace.faceScanBlocker(for: location))
            XCTAssertTrue(noResultBlocker.contains("grouping") || noResultBlocker.contains("scan"))
            workspace.faceScan(location)
            XCTAssertFalse(model.jobs.contains { $0.action == .faceScan })

            // While grouping runs, the blocker says so and no job starts.
            workspace.scan(location)
            XCTAssertEqual(workspace.sources[location.id]?.isScanning, true)
            let groupingBlocker = try XCTUnwrap(workspace.faceScanBlocker(for: location))
            XCTAssertTrue(groupingBlocker.contains("grouping"))
            workspace.faceScan(location)
            XCTAssertTrue(model.statusMessage.contains("grouping"))
            XCTAssertFalse(model.jobs.contains { $0.action == .faceScan })

            // Once grouping finishes the gate lifts.
            try await waitUntil {
                workspace.sources[location.id]?.result != nil
                    && workspace.sources[location.id]?.isScanning == false
            }
            XCTAssertNil(workspace.faceScanBlocker(for: location))
        }
    }

    func testFaceScanRunsAsTrackedJobAfterGrouping() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Card", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("B0001_DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            try writeOrganizerARW(unsorted.appendingPathComponent("B0001_DSC00002.ARW"), "2026:08:26 10:00:00", "400")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil {
                workspace.sources[location.id]?.result != nil
                    && workspace.sources[location.id]?.isScanning == false
            }

            workspace.faceAnalyzerProvider = { StubFaceAnalyzer() }
            workspace.faceScan(location)
            try await waitUntil { !model.isBusy }

            // The Jobs window lists model.jobs — the face scan appears there.
            let job = try XCTUnwrap(model.jobs.first { $0.action == .faceScan })
            XCTAssertEqual(job.state, .done)
            XCTAssertEqual(job.action.displayName, "Face Scan")
            XCTAssertTrue(model.statusMessage.contains("Face scan done"))
        }
    }

    func testEventFaceScanBlockerRequiresAssignedReachableFiles() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            // An event with nothing sorted into it has nothing to scan.
            let empty = try XCTUnwrap(workspace.createEvent(name: "Empty", date: organizerDay("2026-08-26"), policy: .buffer))
            let emptyEvent = try XCTUnwrap(workspace.event(empty))
            let noFiles = try XCTUnwrap(workspace.faceScanBlocker(for: emptyEvent))
            XCTAssertTrue(noFiles.contains("Sort photos"))
            workspace.faceScan(emptyEvent)
            XCTAssertFalse(model.jobs.contains { $0.action == .faceScan })

            // Assigned files that exist nowhere right now still block the
            // scan — presence resolves to zero reachable stacks.
            let ghost = try XCTUnwrap(workspace.createEvent(name: "Ghost", date: organizerDay("2026-08-26"), policy: .buffer))
            model.updateConfiguration { configuration in
                configuration.photoEventAssignments.append(PhotoEventAssignment(
                    sourceRootPath: "/Volumes/MissingCard/DCIM",
                    relativePath: "DSC00009.ARW",
                    fileSize: 4_096,
                    modifiedAt: Date(timeIntervalSince1970: 1_752_000_000),
                    eventID: ghost,
                    deviceID: "sony-a7v"
                ))
            }
            let ghostEvent = try XCTUnwrap(workspace.event(ghost))
            await workspace.refreshEvent(ghost)
            XCTAssertEqual(workspace.eventStacks[ghost], [])
            let offline = try XCTUnwrap(workspace.faceScanBlocker(for: ghostEvent))
            XCTAssertTrue(offline.contains("No reachable copies"))
            workspace.faceScan(ghostEvent)
            XCTAssertFalse(model.jobs.contains { $0.action == .faceScan })

            // Once presence finds reachable copies the gate lifts.
            let unsorted = root.appendingPathComponent("Card", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil {
                workspace.sources[location.id]?.result != nil
                    && workspace.sources[location.id]?.isScanning == false
            }
            let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            for stack in workspace.sources[location.id]?.result?.stacks ?? [] {
                workspace.assign(stackIDs: [stack.id], from: location.id, to: beach)
            }
            let beachEvent = try XCTUnwrap(workspace.event(beach))
            // The blocker only reports now — the menu's explicit kick
            // starts the check, and once that pass lands the gate lifts.
            let warming = try XCTUnwrap(workspace.faceScanBlocker(for: beachEvent))
            XCTAssertTrue(warming.contains("checking"))
            workspace.prepareFaceScanStatus(for: beachEvent)
            try await waitUntil { workspace.eventStacks[beach] != nil }
            XCTAssertEqual(workspace.eventStacks[beach]?.count, 1)
            XCTAssertNil(workspace.faceScanBlocker(for: beachEvent))
        }
    }

    /// First paint is local: the board's stacks come from the catalog-implied
    /// `Originals/<Camera>` path before the four-place sweep answers — even while an
    /// archive stat is parked the way a NAS share stalls. 2,000 assignments
    /// stand in for the real 2,251/10,987-file events: the parked stat is
    /// what proves the ordering, the count keeps it honest. While parked,
    /// the stacks already published stay published, and the finished sweep
    /// still reports drive/source/archive truthfully.
    func testRefreshEventPublishesLocalStacksWhileArchiveSweepIsParked() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Big Trip", date: organizerDay("2026-08-26"), policy: .buffer))
            let event = try XCTUnwrap(workspace.event(eventID))
            let locations = workspace.locations
            let cardCopy = locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            let fileCount = 2_000
            var assignments: [PhotoEventAssignment] = []
            for index in 0..<fileCount {
                let name = String(format: "DSC%05d.ARW", index)
                let url = try writeOrganizerARW(cardCopy.appendingPathComponent(name), "2026:08:26 10:00:00", "000")
                let size = Int64(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
                assignments.append(PhotoEventAssignment(
                    sourceRootPath: "/Volumes/MissingCard/DCIM",
                    relativePath: name,
                    fileSize: size,
                    modifiedAt: Date(),
                    eventID: eventID,
                    deviceID: "sony-a7v"
                ))
            }
            model.updateConfiguration { $0.photoEventAssignments.append(contentsOf: assignments) }

            // The first archive stat parks until released — the stand-in
            // for a NAS share that takes seconds per lookup.
            let box = PresenceProbeBox()
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let libraryPrefix = locations.libraryRoot.path
            workspace.presenceProbe = { url, size, mounted in
                box.noteCall()
                if let url, url.path.hasPrefix(libraryPrefix), box.archiveCalls == 0 {
                    box.noteArchiveCall()
                    _ = gate.wait(timeout: .now() + 30)
                }
                return EventPresenceScanner.state(url, size: size, mounted: mounted)
            }

            let refresh = Task { await workspace.refreshEvent(eventID) }
            // Parked inside the first archive stat: the sweep has begun,
            // and the local stacks must already be on the board.
            try await waitUntil { box.archiveCalls > 0 }
            XCTAssertEqual(workspace.eventStacks[eventID]?.flatMap(\.files).count, fileCount)
            XCTAssertNil(workspace.presence[eventID])
            XCTAssertFalse(box.onMainThread)
            XCTAssertEqual(box.priority, .utility)

            gate.signal()
            await refresh.value
            let summary = try XCTUnwrap(workspace.presence[eventID])
            XCTAssertEqual(summary.total, fileCount)
            XCTAssertEqual(summary.onDrive, fileCount)
            XCTAssertEqual(summary.onSource, 0)
            XCTAssertEqual(summary.sourceOffline, fileCount)
            XCTAssertEqual(summary.onArchive, 0)
            // The sweep agreed with pass one's paths, so the grid the board
            // drew first is the grid that stays.
            XCTAssertEqual(workspace.eventStacks[eventID]?.flatMap(\.files).count, fileCount)
            XCTAssertTrue(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        }
    }

    /// A second open cancels the parked sweep instead of letting it
    /// publish over the newer generation: the stale pass is dropped and
    /// the fresh one still lands truthfully.
    func testRefreshEventReopenCancelsParkedSweep() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Trip", date: organizerDay("2026-08-26"), policy: .buffer))
            let event = try XCTUnwrap(workspace.event(eventID))
            let locations = workspace.locations
            let cardCopy = locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            var assignments: [PhotoEventAssignment] = []
            for index in 0..<3 {
                let name = String(format: "DSC%05d.ARW", index)
                let url = try writeOrganizerARW(cardCopy.appendingPathComponent(name), "2026:08:26 10:00:00", "000")
                assignments.append(PhotoEventAssignment(
                    sourceRootPath: "/Volumes/MissingCard/DCIM",
                    relativePath: name,
                    fileSize: Int64(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)),
                    modifiedAt: Date(),
                    eventID: eventID,
                    deviceID: "sony-a7v"
                ))
            }
            model.updateConfiguration { $0.photoEventAssignments.append(contentsOf: assignments) }

            let box = PresenceProbeBox()
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let libraryPrefix = locations.libraryRoot.path
            workspace.presenceProbe = { url, size, mounted in
                box.noteCall()
                if let url, url.path.hasPrefix(libraryPrefix), box.archiveCalls == 0 {
                    box.noteArchiveCall()
                    _ = gate.wait(timeout: .now() + 30)
                }
                return EventPresenceScanner.state(url, size: size, mounted: mounted)
            }

            // The parked first sweep is abandoned by the second open;
            // releasing the gate lets its next cancellation check exit.
            let first = Task { await workspace.refreshEvent(eventID) }
            try await waitUntil { box.archiveCalls > 0 }
            let second = Task { await workspace.refreshEvent(eventID) }
            gate.signal()
            await first.value
            await second.value

            let summary = try XCTUnwrap(workspace.presence[eventID])
            XCTAssertEqual(summary.onDrive, 3)
            XCTAssertEqual(workspace.eventStacks[eventID]?.flatMap(\.files).count, 3)
        }
    }

    /// First paint is a first screen, not the whole build: while the
    /// deferred pass is parked on its first beyond-the-screen resolve,
    /// the board already shows the earliest `firstScreenFileLimit`
    /// files — and none of the parked files went through any path
    /// resolution at all, let alone a `standardizedFileURL`. When the
    /// rest lands, the stacks that were on screen keep the ids an open
    /// preview would be bound to. 2,000 files stand in for the real
    /// 10,987-file events.
    func testRefreshEventPaintsFirstScreenBeforeRestResolves() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Big Trip", date: organizerDay("2026-08-26"), policy: .buffer))
            let event = try XCTUnwrap(workspace.event(eventID))
            let locations = workspace.locations
            let cardCopy = locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            let fileCount = 2_000
            // Frame numbers step by 10 — never consecutive — and
            // modifiedAt climbs one second per file, so every file stays
            // a single and "the earliest" is exactly the first
            // firstScreenFileLimit assignments.
            var assignments: [PhotoEventAssignment] = []
            for index in 0..<fileCount {
                let name = String(format: "DSC%05d.ARW", index * 10)
                let url = try writeOrganizerARW(cardCopy.appendingPathComponent(name), "2026:08:26 10:00:00", "000")
                assignments.append(PhotoEventAssignment(
                    sourceRootPath: "/Volumes/MissingCard/DCIM",
                    relativePath: name,
                    fileSize: Int64(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)),
                    modifiedAt: Date(timeIntervalSince1970: 1_752_000_000 + TimeInterval(index)),
                    eventID: eventID,
                    deviceID: "sony-a7v"
                ))
            }
            model.updateConfiguration { $0.photoEventAssignments.append(contentsOf: assignments) }

            let firstScreen = Set(assignments.prefix(EventsWorkspace.firstScreenFileLimit).map(\.relativePath))
            let box = EventPathProbeBox()
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            workspace.eventPathResolver = { assignment in
                if firstScreen.contains(assignment.relativePath) {
                    box.noteResolved(assignment.relativePath)
                } else if box.noteParkedCall() {
                    // The deferred build parks on its first
                    // beyond-the-screen resolve — the stand-in for a
                    // drive that answers one file at a time, slowly.
                    // Later parked-file resolves just record and return.
                    _ = gate.wait(timeout: .now() + 30)
                }
                return locations.impliedDrivePath(for: assignment, event: event, policy: .buffer)
            }

            let refresh = Task { await workspace.refreshEvent(eventID) }
            // Parked inside the deferred build's first beyond-the-screen
            // resolve: the first screen must already be on the board, and
            // nothing parked was resolved — no `standardizedFileURL`, no
            // stat — to get it there.
            try await waitUntil { box.parkedCalls > 0 }
            let firstStacks = try XCTUnwrap(workspace.eventStacks[eventID])
            XCTAssertFalse(firstStacks.isEmpty)
            XCTAssertEqual(firstStacks.flatMap(\.files).count, EventsWorkspace.firstScreenFileLimit)
            XCTAssertTrue(box.resolved.isSubset(of: firstScreen))
            XCTAssertFalse(box.onMainThread)

            gate.signal()
            await refresh.value
            let finalStacks = try XCTUnwrap(workspace.eventStacks[eventID])
            XCTAssertEqual(finalStacks.flatMap(\.files).count, fileCount)
            XCTAssertEqual(workspace.presence[eventID]?.onDrive, fileCount)
            // Every stack the first screen drew still owns its id — an
            // open preview bound to one never lost it to the append.
            XCTAssertTrue(Set(firstStacks.map(\.id)).isSubset(of: Set(finalStacks.map(\.id))))
        }
    }

    /// The deferred build's provisional grid puts every implied file on
    /// the board before the dated pass spends a single header read: with
    /// the first cache-miss read parked on the seam, the board already
    /// holds the whole event, the "still loading" count is gone, and only
    /// the outstanding capture-date reads remain. 2,000 files stand in
    /// for the real 10,987-file events.
    func testRefreshEventPublishesFullGridBeforeMissingCaptureDateReads() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Big Trip", date: organizerDay("2026-08-26"), policy: .buffer))
            let event = try XCTUnwrap(workspace.event(eventID))
            let locations = workspace.locations
            let cardCopy = locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            let fileCount = 2_000
            var assignments: [PhotoEventAssignment] = []
            for index in 0..<fileCount {
                let name = String(format: "DSC%05d.ARW", index * 10)
                let url = try writeOrganizerARW(cardCopy.appendingPathComponent(name), "2026:08:26 10:00:00", "000")
                assignments.append(PhotoEventAssignment(
                    sourceRootPath: "/Volumes/MissingCard/DCIM",
                    relativePath: name,
                    fileSize: Int64(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)),
                    modifiedAt: Date(timeIntervalSince1970: 1_752_000_000 + TimeInterval(index)),
                    eventID: eventID,
                    deviceID: "sony-a7v"
                ))
            }
            model.updateConfiguration { $0.photoEventAssignments.append(contentsOf: assignments) }

            // The dated pass's first cache-miss read parks until released —
            // the stand-in for a slow header read on a cold cache.
            let box = CaptureDateReadProbeBox()
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            workspace.captureDateReadProbe = { url in
                if box.noteReadCall() {
                    _ = gate.wait(timeout: .now() + 30)
                }
                return CaptureDateReader.timestamp(of: url)
            }

            let refresh = Task { await workspace.refreshEvent(eventID) }
            // Parked inside the dated pass's first cache-miss read: the
            // provisional grid already put every implied file on the board.
            try await waitUntil { box.readCalls > 0 }
            XCTAssertEqual(workspace.eventStacks[eventID]?.flatMap(\.files).count, fileCount)
            XCTAssertNil(workspace.eventBuildRemainders[eventID])
            XCTAssertEqual(workspace.eventDateReadRemainders[eventID], fileCount - EventsWorkspace.firstScreenFileLimit)
            XCTAssertFalse(box.onMainThread)

            gate.signal()
            await refresh.value
            XCTAssertEqual(workspace.eventStacks[eventID]?.flatMap(\.files).count, fileCount)
            XCTAssertNil(workspace.eventDateReadRemainders[eventID])
            XCTAssertEqual(workspace.presence[eventID]?.onDrive, fileCount)
        }
    }

    func testEventFaceScanRunsAsTrackedJobOnReachableFiles() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Card", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("B0001_DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            try writeOrganizerARW(unsorted.appendingPathComponent("B0001_DSC00002.ARW"), "2026:08:26 10:00:00", "400")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil {
                workspace.sources[location.id]?.result != nil
                    && workspace.sources[location.id]?.isScanning == false
            }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)

            let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            for stack in result.stacks {
                workspace.assign(stackIDs: [stack.id], from: location.id, to: beach)
            }
            let event = try XCTUnwrap(workspace.event(beach))
            await workspace.refreshEvent(beach)
            XCTAssertEqual(workspace.eventStacks[beach]?.count, 1)

            workspace.faceAnalyzerProvider = { StubFaceAnalyzer() }
            workspace.faceScan(event)
            try await waitUntil { !model.isBusy }

            // The Jobs window lists model.jobs — the event's scan appears
            // there, and finishing bumps facesRevision so the board's
            // people chips re-read the catalog.
            let job = try XCTUnwrap(model.jobs.first { $0.action == .faceScan })
            XCTAssertEqual(job.state, .done)
            XCTAssertTrue(model.statusMessage.contains("Face scan done"))
            XCTAssertEqual(workspace.facesRevision, 1)
        }
    }

    /// Clear Face Scan drops every face row and bumps `facesRevision` so
    /// the People window and chips re-read — the event in the same
    /// database is untouched.
    func testClearFaceIndexEmptiesIndexAndBumpsFacesRevision() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let photo = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey("/Card/DCIM/DSC00001.ARW"),
                path: "/Card/DCIM/DSC00001.ARW",
                fileName: "DSC00001.ARW",
                byteCount: 4_096,
                modifiedAt: Date(timeIntervalSince1970: 1_752_000_000),
                scanGrade: .med
            )
            try store.replaceFaces(photo: photo, faces: [
                FaceRecord(photoID: photo.pathKey, personID: dad.id, box: NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2), detScore: 0.9, embedding: [0.5, 0.5], state: .confirmed),
            ])
            // An event row lives in the same database.
            let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )

            XCTAssertEqual(workspace.faceIndexCounts().scannedPhotos, 1)
            XCTAssertEqual(workspace.storedFaceScanGrades(), [.med])
            XCTAssertEqual(workspace.facesRevision, 0)

            workspace.clearFaceIndex()

            XCTAssertEqual(workspace.faceIndexCounts(), FaceIndexCounts())
            XCTAssertEqual(workspace.storedFaceScanGrades(), [])
            XCTAssertEqual(workspace.facesRevision, 1)
            XCTAssertTrue(model.statusMessage.contains("Face index cleared"))
            // Events are untouched (the row-level proof lives in the core
            // tests — here the workspace simply still resolves it).
            XCTAssertNotNil(workspace.event(beach))
        }
    }

    /// "Not this person" is a real move: the face leaves the person
    /// immediately and `facesRevision` bumps so the open People grid and
    /// Inbox re-read. Alone it is under the group-size floor, so it
    /// returns to the unassigned pool rather than minting a "Person N".
    /// The persisted verdict keeps it off the person through a later
    /// Re-match.
    func testRejectFaceMovesItOutImmediatelyAndStaysOut() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let photo = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey("/Card/DCIM/RJ1.JPG"),
                path: "/Card/DCIM/RJ1.JPG",
                fileName: "RJ1.JPG",
                byteCount: 4_096,
                modifiedAt: Date(timeIntervalSince1970: 1_752_000_000),
                scanGrade: .med
            )
            let face = FaceRecord(
                photoID: photo.pathKey,
                personID: dad.id,
                box: NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                detScore: 0.9,
                embedding: [0.5, 0.5],
                state: .proposed
            )
            try store.replaceFaces(photo: photo, faces: [face])

            workspace.rejectFace(face.id)

            XCTAssertEqual(workspace.facesRevision, 1)
            let moved = try XCTUnwrap(store.face(id: face.id))
            XCTAssertEqual(moved.state, .cached)
            XCTAssertNil(moved.personID)
            XCTAssertTrue(try store.otherGroups().isEmpty)
            XCTAssertTrue(model.statusMessage.contains("Dad"))
            XCTAssertTrue(try store.faceRejections().blocks(faceID: face.id, personID: dad.id))

            // Re-match can never put the face back on Dad.
            workspace.rematchFaces()
            try await waitUntil { !model.isBusy }
            let after = try XCTUnwrap(store.face(id: face.id))
            XCTAssertNotEqual(after.personID, dad.id)
            XCTAssertNotEqual(after.state, .proposed)
        }
    }

    /// Re-match runs with unnamed groups and no roster at all: a drifted
    /// drawer of two identities splits into real groups, the job is
    /// tracked, and the status line reports the moves.
    func testRematchFacesRebundlesUnnamedGroupsWithoutRoster() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let drawer = try store.createPerson(name: "Person 27", isRoster: false)
            let photo = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey("/Card/DCIM/RB1.JPG"),
                path: "/Card/DCIM/RB1.JPG",
                fileName: "RB1.JPG",
                byteCount: 4_096,
                modifiedAt: Date(timeIntervalSince1970: 1_752_000_000),
                scanGrade: .med
            )
            // Two orthogonal identities, three sightings each — enough for
            // both to clear the group-size floor — shoved into one group.
            let alex = (0..<3).map { index in
                FaceRecord(
                    photoID: photo.pathKey,
                    box: NormalizedFaceBox(x: 0.1 + Double(index) * 0.3, y: 0.1, width: 0.2, height: 0.2),
                    detScore: 0.9,
                    embedding: [1, 0],
                    state: .cached
                )
            }
            let sam = (0..<3).map { index in
                FaceRecord(
                    photoID: photo.pathKey,
                    box: NormalizedFaceBox(x: 0.1 + Double(index) * 0.3, y: 0.5, width: 0.2, height: 0.2),
                    detScore: 0.8,
                    embedding: [0, 1],
                    state: .cached
                )
            }
            try store.replaceFaces(photo: photo, faces: alex + sam)
            for face in alex + sam {
                try store.assignFace(face.id, to: drawer.id, state: .other, score: 0.9)
            }

            workspace.rematchFaces()
            try await waitUntil { !model.isBusy }

            let job = try XCTUnwrap(model.jobs.first { $0.action == .faceScan })
            XCTAssertEqual(job.state, .done)
            XCTAssertEqual(workspace.facesRevision, 1)
            let alexGroup = try XCTUnwrap(store.face(id: alex[0].id)?.personID)
            let samGroup = try XCTUnwrap(store.face(id: sam[0].id)?.personID)
            XCTAssertNotEqual(alexGroup, samGroup)
            for face in alex {
                XCTAssertEqual(try store.face(id: face.id)?.personID, alexGroup)
            }
            for face in sam {
                XCTAssertEqual(try store.face(id: face.id)?.personID, samGroup)
            }
            XCTAssertTrue(model.statusMessage.contains("Re-match done"))
            XCTAssertTrue(model.statusMessage.contains("moved"))
        }
    }

    /// Junk removes only the Inbox row the user confirmed — the
    /// neighboring row and its faces stay, photos keep their scan grade,
    /// and approved people refuse the junk path entirely.
    func testJunkGroupRemovesOnlyTheConfirmedGroup() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let junk = try store.createPerson(name: "Person 3", isRoster: false)
            let keep = try store.createPerson(name: "Person 4", isRoster: false)
            let photoA = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey("/Card/DCIM/JK1.JPG"),
                path: "/Card/DCIM/JK1.JPG",
                fileName: "JK1.JPG",
                byteCount: 4_096,
                modifiedAt: Date(timeIntervalSince1970: 1_752_000_000),
                scanGrade: .med
            )
            let photoB = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey("/Card/DCIM/JK2.JPG"),
                path: "/Card/DCIM/JK2.JPG",
                fileName: "JK2.JPG",
                byteCount: 4_096,
                modifiedAt: Date(timeIntervalSince1970: 1_752_000_000),
                scanGrade: .med
            )
            let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
            let junkFace = FaceRecord(photoID: photoA.pathKey, personID: junk.id, box: box, detScore: 0.9, embedding: [0.5, 0.5], state: .other)
            let keepFace = FaceRecord(photoID: photoB.pathKey, personID: keep.id, box: box, detScore: 0.9, embedding: [0.5, 0.5], state: .other)
            try store.replaceFaces(photo: photoA, faces: [junkFace])
            try store.replaceFaces(photo: photoB, faces: [keepFace])

            workspace.junkGroup(junk.id)

            XCTAssertEqual(workspace.facesRevision, 1)
            XCTAssertNil(try store.person(junk.id))
            XCTAssertNil(try store.face(id: junkFace.id))
            XCTAssertNotNil(try store.person(keep.id))
            XCTAssertEqual(try store.face(id: keepFace.id)?.personID, keep.id)
            XCTAssertTrue(model.statusMessage.contains("Person 3"))
            XCTAssertEqual(
                try store.photos(pathKeys: [photoB.pathKey])[photoB.pathKey]?.scanGrade,
                .med
            )

            // An approved person refuses the junk path — no row is removed
            // and nothing else moves.
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            workspace.junkGroup(dad.id)
            XCTAssertNotNil(try store.person(dad.id))
            XCTAssertEqual(workspace.facesRevision, 1)
            XCTAssertTrue(model.statusMessage.contains("approved person"))
        }
    }

    /// The People window's data: approved people on one side, every
    /// unapproved cluster on the other — automatic "Person N" groups and
    /// "looks like" suggestion rows alike, suggestions first.
    func testFaceSnapshotSplitsApprovedAndInbox() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let pile = try store.createPerson(name: "Dad", isRoster: false, suggestedPersonID: dad.id)
            let group = try store.createPerson(name: "Person 1", isRoster: false)
            let photo = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey("/Card/DCIM/SN1.JPG"),
                path: "/Card/DCIM/SN1.JPG",
                fileName: "SN1.JPG",
                byteCount: 4_096,
                modifiedAt: Date(timeIntervalSince1970: 1_752_000_000),
                scanGrade: .med
            )
            let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
            try store.replaceFaces(photo: photo, faces: [
                FaceRecord(photoID: photo.pathKey, personID: dad.id, box: box, detScore: 0.9, embedding: [0.5, 0.5], state: .confirmed),
                FaceRecord(photoID: photo.pathKey, personID: pile.id, box: box, detScore: 0.8, matchScore: 0.5, embedding: [0.5, 0.4], state: .proposed),
                FaceRecord(photoID: photo.pathKey, personID: group.id, box: box, detScore: 0.7, embedding: [0.1, 0.9], state: .other),
            ])
            try store.refreshFaceCounts()

            let snapshot = workspace.faceSnapshot()
            XCTAssertEqual(snapshot.approved.map(\.id), [dad.id])
            // The lookalike row leads the Inbox; its display name is the
            // live target name.
            XCTAssertEqual(snapshot.inbox.map(\.id), [pile.id, group.id])
            XCTAssertEqual(snapshot.inbox.first?.suggestedPersonName, "Dad")
            // Nothing Inbox leaks into approved.
            XCTAssertFalse(snapshot.approved.contains { !$0.isRoster })
        }
    }

    /// Reading the snapshot when a catalog still has a legacy proposed
    /// face sitting on an approved person kicks off the sweep: a stored-
    /// vectors re-match files it into the "looks like" Inbox row and
    /// leaves the approved person's membership untouched.
    func testFaceSnapshotSweepsLegacyRosterProposalsIntoInbox() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let photo = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey("/Card/DCIM/LG1.JPG"),
                path: "/Card/DCIM/LG1.JPG",
                fileName: "LG1.JPG",
                byteCount: 4_096,
                modifiedAt: Date(timeIntervalSince1970: 1_752_000_000),
                scanGrade: .med
            )
            let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
            let confirmed = FaceRecord(photoID: photo.pathKey, personID: dad.id, box: box, detScore: 0.9, embedding: [1, 0], state: .confirmed)
            let legacy = FaceRecord(photoID: photo.pathKey, personID: dad.id, box: box, detScore: 0.85, embedding: [1, 0], state: .proposed)
            try store.replaceFaces(photo: photo, faces: [confirmed, legacy])
            try store.addTemplate(personID: dad.id, faceID: confirmed.id)
            XCTAssertTrue(try store.hasUnapprovedRosterFaces())

            _ = workspace.faceSnapshot()
            try await waitUntil { !model.isBusy }

            let moved = try XCTUnwrap(store.face(id: legacy.id))
            let rowID = try XCTUnwrap(moved.personID)
            XCTAssertNotEqual(rowID, dad.id)
            let row = try XCTUnwrap(store.person(rowID))
            XCTAssertFalse(row.isRoster)
            XCTAssertEqual(row.suggestedPersonID, dad.id)
            // Dad keeps only his confirmed face; the probe is quiet again.
            XCTAssertEqual(try store.faces(personID: dad.id).map(\.id), [confirmed.id])
            XCTAssertFalse(try store.hasUnapprovedRosterFaces())
        }
    }

    /// An Inbox person's faces read in review order: stored match score,
    /// strongest first; a face with no score was a cluster seed and rides
    /// with the strongest.
    func testInboxFacesOrdersByMatchScore() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let group = try store.createPerson(name: "Person 1", isRoster: false)
            let photo = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey("/Card/DCIM/SC1.JPG"),
                path: "/Card/DCIM/SC1.JPG",
                fileName: "SC1.JPG",
                byteCount: 4_096,
                modifiedAt: Date(timeIntervalSince1970: 1_752_000_000),
                scanGrade: .med
            )
            let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
            let weak = FaceRecord(photoID: photo.pathKey, personID: group.id, box: box, detScore: 0.9, matchScore: 0.41, embedding: [0.5, 0.5], state: .other)
            let seed = FaceRecord(photoID: photo.pathKey, personID: group.id, box: box, detScore: 0.6, matchScore: nil, embedding: [0.5, 0.5], state: .other)
            let strong = FaceRecord(photoID: photo.pathKey, personID: group.id, box: box, detScore: 0.7, matchScore: 0.9, embedding: [0.5, 0.5], state: .other)
            let mid = FaceRecord(photoID: photo.pathKey, personID: group.id, box: box, detScore: 0.8, matchScore: 0.6, embedding: [0.5, 0.5], state: .other)
            try store.replaceFaces(photo: photo, faces: [weak, seed, strong, mid])

            let ordered = workspace.inboxFaces(for: group.id)
            XCTAssertEqual(ordered.map(\.id), [seed.id, strong.id, mid.id, weak.id])
        }
    }

    /// Confirming a face out of a "looks like Dad" row lands it on Dad —
    /// the user saying so is the approval — while the rest of the pile
    /// stays unapproved.
    func testConfirmFaceFromSuggestionRowConfirmsOntoTarget() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let pile = try store.createPerson(name: "Dad", isRoster: false, suggestedPersonID: dad.id)
            let photo = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey("/Card/DCIM/CF1.JPG"),
                path: "/Card/DCIM/CF1.JPG",
                fileName: "CF1.JPG",
                byteCount: 4_096,
                modifiedAt: Date(timeIntervalSince1970: 1_752_000_000),
                scanGrade: .med
            )
            let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
            let yes = FaceRecord(photoID: photo.pathKey, personID: pile.id, box: box, detScore: 0.9, matchScore: 0.5, embedding: [0.5, 0.5], state: .proposed)
            let still = FaceRecord(photoID: photo.pathKey, personID: pile.id, box: box, detScore: 0.8, matchScore: 0.45, embedding: [0.5, 0.4], state: .proposed)
            try store.replaceFaces(photo: photo, faces: [yes, still])

            workspace.confirmFace(yes.id)

            XCTAssertEqual(workspace.facesRevision, 1)
            let confirmed = try XCTUnwrap(store.face(id: yes.id))
            XCTAssertEqual(confirmed.state, .confirmed)
            XCTAssertEqual(confirmed.personID, dad.id)
            XCTAssertEqual(try store.rosterTemplates().map(\.personID), [dad.id])
            // The pilemate stays unapproved on the row.
            let leftover = try XCTUnwrap(store.face(id: still.id))
            XCTAssertEqual(leftover.state, .proposed)
            XCTAssertEqual(leftover.personID, pile.id)
        }
    }

    /// Approving an Inbox group confirms only its own faces — no
    /// catalog-wide re-match runs behind it, so a similar cached face
    /// waits in the Inbox rather than jumping onto the new person.
    func testNameGroupApprovesClusterWithoutSweepingCatalog() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let group = try store.createPerson(name: "Person 1", isRoster: false)
            let photo = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey("/Card/DCIM/NG1.JPG"),
                path: "/Card/DCIM/NG1.JPG",
                fileName: "NG1.JPG",
                byteCount: 4_096,
                modifiedAt: Date(timeIntervalSince1970: 1_752_000_000),
                scanGrade: .med
            )
            let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
            let member = FaceRecord(photoID: photo.pathKey, personID: group.id, box: box, detScore: 0.9, embedding: [1, 0], state: .other)
            let lookalike = FaceRecord(photoID: photo.pathKey, box: box, detScore: 0.8, embedding: [1, 0], state: .cached)
            try store.replaceFaces(photo: photo, faces: [member, lookalike])

            workspace.nameGroup(group.id, name: "Alex")

            XCTAssertEqual(workspace.facesRevision, 1)
            let alex = try XCTUnwrap(store.person(group.id))
            XCTAssertTrue(alex.isRoster)
            XCTAssertEqual(alex.name, "Alex")
            XCTAssertEqual(try store.face(id: member.id)?.state, .confirmed)
            // The lookalike was not swept onto Alex — no re-match ran.
            let waiting = try XCTUnwrap(store.face(id: lookalike.id))
            XCTAssertNil(waiting.personID)
            XCTAssertEqual(waiting.state, .cached)
            XCTAssertTrue(model.statusMessage.contains("Approved Alex"))
            XCTAssertFalse(model.jobs.contains { $0.action == .faceScan })
        }
    }

    /// Junking one face deletes just that catalog row — the rest of the
    /// Inbox row and the photo's scan grade stay put.
    func testJunkFaceDeletesOnlyThatFace() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let group = try store.createPerson(name: "Person 1", isRoster: false)
            let photo = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey("/Card/DCIM/JF1.JPG"),
                path: "/Card/DCIM/JF1.JPG",
                fileName: "JF1.JPG",
                byteCount: 4_096,
                modifiedAt: Date(timeIntervalSince1970: 1_752_000_000),
                scanGrade: .med
            )
            let box = NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
            let junk = FaceRecord(photoID: photo.pathKey, personID: group.id, box: box, detScore: 0.9, embedding: [0.5, 0.5], state: .other)
            let keep = FaceRecord(photoID: photo.pathKey, personID: group.id, box: box, detScore: 0.8, embedding: [0.5, 0.4], state: .other)
            try store.replaceFaces(photo: photo, faces: [junk, keep])

            workspace.junkFace(junk.id)

            XCTAssertEqual(workspace.facesRevision, 1)
            XCTAssertNil(try store.face(id: junk.id))
            XCTAssertEqual(try store.face(id: keep.id)?.personID, group.id)
            XCTAssertEqual(try store.photos(pathKeys: [photo.pathKey])[photo.pathKey]?.scanGrade, .med)
        }
    }

    /// The sidebar's Face Scan item used to start `refreshEvent` as a
    /// side effect of `faceScanBlocker` — every unopened event's row
    /// swept its files at launch just by drawing the menu. The blocker
    /// is pure now; the explicit kick the menu calls on open is the only
    /// thing that starts the check.
    func testFaceScanBlockerReportsWithoutStartingTheSweep() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Card", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil {
                workspace.sources[location.id]?.result != nil
                    && workspace.sources[location.id]?.isScanning == false
            }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            workspace.assign(stackIDs: [try XCTUnwrap(result.stacks.first).id], from: location.id, to: beach)
            let event = try XCTUnwrap(workspace.event(beach))

            XCTAssertNil(workspace.eventStacks[beach])
            XCTAssertNotNil(workspace.faceScanBlocker(for: event))
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertFalse(workspace.isCheckingFiles(for: beach))
            XCTAssertNil(workspace.eventStacks[beach])

            workspace.prepareFaceScanStatus(for: event)
            try await waitUntil { workspace.eventStacks[beach] != nil }
            XCTAssertNil(workspace.faceScanBlocker(for: event))
        }
    }

    /// Reopening an event whose board is already current must not shrink
    /// the grid to the first screen: the revisit keeps every stack and
    /// only the sweep re-verifies. 260 files stand in for the events that
    /// used to drop to the 240-file first paint on every revisit.
    func testRevisitingAnEventKeepsTheFullGrid() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Big Trip", date: organizerDay("2026-08-26"), policy: .buffer))
            let event = try XCTUnwrap(workspace.event(eventID))
            let cardCopy = workspace.locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            let fileCount = 260
            var assignments: [PhotoEventAssignment] = []
            for index in 0..<fileCount {
                let name = String(format: "DSC%05d.ARW", index)
                let url = try writeOrganizerARW(cardCopy.appendingPathComponent(name), "2026:08:26 10:00:00", "000")
                let size = Int64(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
                assignments.append(PhotoEventAssignment(
                    sourceRootPath: "/Volumes/MissingCard/DCIM",
                    relativePath: name,
                    fileSize: size,
                    modifiedAt: Date(),
                    eventID: eventID,
                    deviceID: "sony-a7v"
                ))
            }
            model.updateConfiguration { $0.photoEventAssignments.append(contentsOf: assignments) }
            await workspace.refreshEvent(eventID)
            try await waitUntil { workspace.presence[eventID] != nil }
            XCTAssertEqual(workspace.eventStacks[eventID]?.flatMap(\.files).count, fileCount)
            XCTAssertGreaterThan(fileCount, 240)
            let checkedAt = try XCTUnwrap(workspace.presence[eventID]?.checkedAt)

            // The revisit: no first paint, no shrink — the grid stays
            // whole while the sweep re-verifies it.
            await workspace.refreshEvent(eventID)
            XCTAssertEqual(workspace.eventStacks[eventID]?.flatMap(\.files).count, fileCount)
            try await waitUntil { (workspace.presence[eventID]?.checkedAt ?? .distantPast) > checkedAt }
            XCTAssertEqual(workspace.eventStacks[eventID]?.flatMap(\.files).count, fileCount)
        }
    }

    /// An assign into an event whose board is open gains the new stacks
    /// in place — the items land on the board in the same call that
    /// records the assignments, no refresh or rebuild in between.
    func testAssignPatchesTheOpenEventBoardInPlace() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Card", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            try writeOrganizerARW(unsorted.appendingPathComponent("IMG00002.ARW"), "2026:08:26 12:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil {
                workspace.sources[location.id]?.result != nil
                    && workspace.sources[location.id]?.isScanning == false
            }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            let stacks = result.stacks
            XCTAssertEqual(stacks.count, 2)

            workspace.assign(stackIDs: [stacks[0].id], from: location.id, to: beach)
            await workspace.refreshEvent(beach)
            try await waitUntil { (workspace.eventStacks[beach]?.flatMap(\.files).count ?? 0) == 1 }

            workspace.assign(stackIDs: [stacks[1].id], from: location.id, to: beach)
            XCTAssertEqual(workspace.eventStacks[beach]?.flatMap(\.files).count, 2)
        }
    }

    /// An activation check where nothing mounted or unmounted does no
    /// work: the connectivity revision holds and no event re-verifies.
    func testActivationWithUnchangedMountsDoesNothing() async throws {
        try await withOrganizerSandbox { _, _, workspace in
            workspace.refreshConnectivity()
            let revision = workspace.connectivityRevision
            workspace.refreshConnectivityIfStale(maxAge: 0)
            XCTAssertEqual(workspace.connectivityRevision, revision)
        }
    }

    /// A mount-scoped connectivity refresh re-verifies the board on
    /// screen and the events whose roots live on the changed volume —
    /// not every board it happens to remember.
    func testScopedConnectivityRefreshSkipsUntouchedEvents() async throws {
        try await withOrganizerSandbox { _, model, workspace in
            let alpha = try XCTUnwrap(workspace.createEvent(name: "Alpha", date: organizerDay("2026-08-26"), policy: .buffer))
            let beta = try XCTUnwrap(workspace.createEvent(name: "Beta", date: organizerDay("2026-08-26"), policy: .buffer))
            // Both boards known — the scoped pass only re-verifies the
            // visible one; the other keeps its cached presence.
            await workspace.refreshEvent(alpha)
            await workspace.refreshEvent(beta)
            try await waitUntil { workspace.presence[alpha] != nil && workspace.presence[beta] != nil }
            let alphaCheckedAt = try XCTUnwrap(workspace.presence[alpha]?.checkedAt)
            let betaCheckedAt = try XCTUnwrap(workspace.presence[beta]?.checkedAt)

            workspace.selection = .event(alpha)
            let changed: Set<URL> = [URL(fileURLWithPath: "/Volumes/External", isDirectory: true)]
            workspace.refreshConnectivity(mountedVolumes: changed)
            try await waitUntil {
                (workspace.presence[alpha]?.checkedAt ?? .distantPast) > alphaCheckedAt
            }
            XCTAssertEqual(workspace.presence[beta]?.checkedAt, betaCheckedAt)
        }
    }

    func testBoardSearchMatchesRosterPersonNames() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Card", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            try writeOrganizerARW(unsorted.appendingPathComponent("DSC00002.ARW"), "2026:08:26 12:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil {
                workspace.sources[location.id]?.result != nil
                    && workspace.sources[location.id]?.isScanning == false
            }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)

            let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            for stack in result.stacks {
                workspace.assign(stackIDs: [stack.id], from: location.id, to: beach)
            }
            await workspace.refreshEvent(beach)
            let eventStacks = try XCTUnwrap(workspace.eventStacks[beach])
            XCTAssertEqual(eventStacks.count, 2)

            // Seed the face index as if a scan ran: Dad confirmed on
            // DSC00001's file identity (name + size + mtime).
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: model.configuration,
                createBackup: false,
                createLibraryFolders: false
            )
            let store = workspace.faceStore
            let dad = try store.createPerson(name: "Dad", isRoster: true)
            let dadFile = try XCTUnwrap(eventStacks.flatMap(\.files).first { $0.name == "DSC00001.ARW" })
            let photo = FacePhotoRecord(
                pathKey: EventStorageLocations.pathKey(dadFile.path),
                path: dadFile.path,
                fileName: dadFile.name,
                byteCount: dadFile.size,
                modifiedAt: dadFile.modifiedAt,
                scanGrade: .low
            )
            try store.replaceFaces(photo: photo, faces: [
                FaceRecord(photoID: photo.pathKey, personID: dad.id, box: NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2), detScore: 0.9, embedding: [0.5, 0.5], state: .confirmed),
            ])
            XCTAssertEqual(workspace.eventPeople(beach).map(\.name), ["Dad"])

            // A roster name keeps the stack holding that person's photo on
            // both the event board and the unsorted board.
            let dadStacks = workspace.visibleEventStacks(beach, matching: "dad")
            XCTAssertEqual(dadStacks.count, 1)
            XCTAssertTrue(dadStacks.flatMap(\.files).contains { $0.name == "DSC00001.ARW" })
            XCTAssertTrue(workspace.visibleEventStacks(beach, matching: "stranger").isEmpty)
            let unsortedMatches = workspace.visibleStacks(result, hideSorted: false, matching: "dad")
            XCTAssertEqual(unsortedMatches.count, 1)
            XCTAssertTrue(unsortedMatches.flatMap(\.files).contains { $0.name == "DSC00001.ARW" })
            XCTAssertTrue(workspace.visibleStacks(result, hideSorted: false, matching: "stranger").isEmpty)

            // File-name search still matches the other stack.
            let byName = workspace.visibleEventStacks(beach, matching: "dsc00002")
            XCTAssertTrue(byName.flatMap(\.files).contains { $0.name == "DSC00002.ARW" })
        }
    }

    func testRegroupBurstsRerunsGroupingAsAnOrganizeJob() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Card", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("B0001_DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            try writeOrganizerARW(unsorted.appendingPathComponent("B0001_DSC00002.ARW"), "2026:08:26 10:00:00", "400")
            try writeOrganizerARW(unsorted.appendingPathComponent("DSC00010.ARW"), "2026:08:26 11:00:00", "000")
            let location = addUnsorted(unsorted, to: model)

            // Nothing to regroup before the first scan — refused with a
            // message, no job.
            workspace.regroupBursts(location)
            XCTAssertTrue(model.statusMessage.contains("nothing to regroup"))
            XCTAssertFalse(model.jobs.contains { $0.action == .organize })

            workspace.scan(location)
            try await waitUntil {
                workspace.sources[location.id]?.result != nil
                    && workspace.sources[location.id]?.isScanning == false
            }

            workspace.regroupBursts(location)
            XCTAssertTrue(model.jobs.contains { $0.action == .organize })
            try await waitUntil {
                !model.isBusy && workspace.sources[location.id]?.isScanning == false
            }

            // The board's stacks were rebuilt from the same items: the
            // B0001_ pair stays one burst, the lone file stays single.
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            XCTAssertEqual(result.stacks.map(\.items.count).sorted(), [1, 2])
            let job = try XCTUnwrap(model.jobs.first { $0.action == .organize })
            XCTAssertEqual(job.state, .done)
            XCTAssertTrue(job.note.contains("Regrouped"))
        }
    }

    func testRecentEventsCapAtThreeAndKeepPositionsStable() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let stack = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks.first)

            let alpha = try XCTUnwrap(workspace.createEvent(name: "Alpha", date: organizerDay("2026-08-26"), policy: .buffer))
            let bravo = try XCTUnwrap(workspace.createEvent(name: "Bravo", date: organizerDay("2026-08-26"), policy: .buffer))
            let charlie = try XCTUnwrap(workspace.createEvent(name: "Charlie", date: organizerDay("2026-08-26"), policy: .buffer))
            XCTAssertEqual(workspace.recentEvents.map(\.id), [alpha, bravo, charlie])
            XCTAssertLessThanOrEqual(workspace.recentEvents.count, EventsWorkspace.recentLimit)

            // Reusing a listed event must not move it: the digit keys keep
            // meaning the same event for the rest of the sort session.
            workspace.assign(stackIDs: [stack.id], from: location.id, to: bravo)
            XCTAssertEqual(workspace.recentEvents.map(\.id), [alpha, bravo, charlie])

            // A target that isn't listed enters at the front; the tail drops.
            let delta = try XCTUnwrap(workspace.createEvent(name: "Delta", date: organizerDay("2026-08-26"), policy: .buffer))
            XCTAssertEqual(workspace.recentEvents.map(\.id), [delta, alpha, bravo])
            XCTAssertLessThanOrEqual(workspace.recentEvents.count, EventsWorkspace.recentLimit)

            // An excluded event (the board being viewed) is not a target.
            XCTAssertEqual(workspace.assignableRecents(excluding: alpha).map(\.id), [delta, bravo])
            XCTAssertEqual(workspace.assignableRecents().map(\.id), [delta, alpha, bravo])
        }
    }

    func testEventPickerSectionsPinMatchingRecentsAndFilterByBreadcrumb() async throws {
        try await withOrganizerSandbox { _, model, workspace in
            let trip = try XCTUnwrap(workspace.createEvent(name: "TRIP2026", date: organizerDay("2026-08-26"), policy: .buffer))
            let matcha = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-26"), policy: .buffer, parentEventID: trip))
            let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            let hotel = try XCTUnwrap(workspace.createEvent(name: "Hotel Night", date: organizerDay("2026-08-26"), policy: .buffer))
            let matchaEvent = try XCTUnwrap(workspace.event(matcha))
            XCTAssertEqual(workspace.eventTitle(matchaEvent), "TRIP2026 / Matcha")

            // Hotel entering evicted Beach, so the unfiltered picker shows
            // the three recents up top and only Beach below.
            let all = workspace.eventPickerSections(matching: "")
            XCTAssertEqual(all.recent.map(\.id), [hotel, trip, matcha])
            XCTAssertEqual(all.other.map(\.event.id), [beach])

            // A matching recent pins to the Recent section, not the list.
            let matchaHit = workspace.eventPickerSections(matching: "matcha")
            XCTAssertEqual(matchaHit.recent.map(\.id), [matcha])
            XCTAssertTrue(matchaHit.other.isEmpty)

            // A non-recent match still appears, under its breadcrumb title.
            let beachHit = workspace.eventPickerSections(matching: "beach")
            XCTAssertTrue(beachHit.recent.isEmpty)
            XCTAssertEqual(beachHit.other.map(\.event.id), [beach])

            // Parent names match subevents through the breadcrumb title.
            let tripHit = workspace.eventPickerSections(matching: "trip")
            XCTAssertEqual(tripHit.recent.map(\.id), [trip, matcha])
            XCTAssertTrue(tripHit.other.isEmpty)

            let none = workspace.eventPickerSections(matching: "zzz")
            XCTAssertTrue(none.recent.isEmpty && none.other.isEmpty)

            // The board's own event is dropped from both sections.
            let moving = workspace.eventPickerSections(matching: "", excluding: hotel)
            XCTAssertEqual(moving.recent.map(\.id), [trip, matcha])
            XCTAssertEqual(moving.other.map(\.event.id), [beach])
        }
    }

    func testNewEventRequestDoesNotAssignOnCreate() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("B0009_DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            try writeOrganizerARW(unsorted.appendingPathComponent("B0009_DSC00002.ARW"), "2026:08:26 10:00:00", "200")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let burst = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks.first)

            // The overlay's "New Event…" requests the previewed stack
            // explicitly, independent of the board's selection.
            workspace.requestNewEvent(stackIDs: [burst.id], from: location.id, suggestedDate: burst.captureDate)
            let request = try XCTUnwrap(workspace.newEventRequest)
            XCTAssertEqual(request.sourceLocationID, location.id)
            XCTAssertEqual(request.stackIDs, [burst.id])
            XCTAssertNil(request.moveFromEventID)

            workspace.completeNewEvent(request, name: "New Gig", date: organizerDay("2026-08-26"), policy: .buffer, parentEventID: nil)
            XCTAssertNil(workspace.newEventRequest)

            let created = try XCTUnwrap(model.configuration.savedEvents.first { $0.name == "New Gig" })
            XCTAssertNil(workspace.assignedEvent(for: burst).event)
            XCTAssertFalse(workspace.isSorted(burst))
            XCTAssertTrue(workspace.recentEvents.contains { $0.id == created.id })
        }
    }

    func testNewEventRequestDoesNotMoveEventBoardStackOnCreate() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("B0007_DSC00001.ARW"), "2026:08:27 09:00:00", "000")
            try writeOrganizerARW(unsorted.appendingPathComponent("B0007_DSC00002.ARW"), "2026:08:27 09:00:00", "300")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let burst = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks.first)

            let shared = try XCTUnwrap(workspace.createEvent(name: "City Walk", date: organizerDay("2026-08-27"), policy: .buffer))
            workspace.assign(stackIDs: [burst.id], from: location.id, to: shared)
            workspace.performApply(EventsWorkspace.buildApplyPlan(
                events: [try XCTUnwrap(workspace.event(shared))],
                configuration: model.configuration,
                locations: workspace.locations,
                onlyUnder: nil,
                title: "Apply",
                unsortedRoots: [unsorted]
            ))
            try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }
            await workspace.refreshEvent(shared)
            let appliedStack = try XCTUnwrap(workspace.eventStacks[shared]?.first)

            // "New Event…" on an event board records the event the stack is
            // leaving, so completion moves rather than assigns.
            workspace.requestNewEvent(stackIDs: [appliedStack.id], movingFromEvent: shared, suggestedDate: appliedStack.captureDate)
            let request = try XCTUnwrap(workspace.newEventRequest)
            XCTAssertEqual(request.moveFromEventID, shared)
            XCTAssertEqual(request.stackIDs, [appliedStack.id])
            XCTAssertNil(request.sourceLocationID)

            workspace.completeNewEvent(request, name: "After Party", date: organizerDay("2026-08-27"), policy: .buffer, parentEventID: nil)
            XCTAssertNil(workspace.newEventRequest)

            let created = try XCTUnwrap(model.configuration.savedEvents.first { $0.name == "After Party" })
            XCTAssertEqual(model.configuration.photoEventAssignments.filter { $0.eventID == shared }.count, 2)
            XCTAssertTrue(model.configuration.photoEventAssignments.filter { $0.eventID == created.id }.isEmpty)
            XCTAssertTrue(workspace.recentEvents.contains { $0.id == created.id })
        }
    }

    /// Rotate Burst applies the same quarter-turn to every still in the stack
    /// — RAW primaries and the keep-JPEG companion alike — while the XMP
    /// sidecar stays out of the map and no byte on disk changes.
    func testRotateBurstTurnsEveryStillTogetherWithoutTouchingFiles() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00002.ARW"), "2026:08:26 10:00:00", "400")
            try organizerWrite(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00002.JPG"), "<jpeg companion>")
            try organizerWrite(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00001.xmp"), "<xmp/>")
            let location = addUnsorted(unsorted, to: model)

            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let burst = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks.first { $0.isBurst })
            XCTAssertEqual(burst.items.count, 2)

            let folder = unsorted.appendingPathComponent("Transfer 1")
            let beforeListing = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            let beforeBytes = try beforeListing.map { try Data(contentsOf: folder.appendingPathComponent($0)) }

            workspace.rotateStack(burst, quarterTurnsCW: 1)

            for file in burst.files {
                let expected = DisplayRotation.isRotatable(file) ? 1 : 0
                XCTAssertEqual(workspace.displayTurns(for: file), expected, file.name)
            }
            // The JPEG companion shares the turn; the XMP never enters the map.
            XCTAssertEqual(burst.items.flatMap(\.companions).map(\.name).sorted(), ["B0001_DSC00001.xmp", "B0001_DSC00002.JPG"])
            XCTAssertEqual(workspace.displayTurns(for: try XCTUnwrap(burst.files.first { $0.name == "B0001_DSC00002.JPG" })), 1)
            XCTAssertNil(model.configuration.displayOrientations[DisplayRotation.fileKey(for: try XCTUnwrap(burst.files.first { $0.name == "B0001_DSC00001.xmp" }))])

            // Nothing was written, created, or deleted on disk.
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), beforeListing)
            XCTAssertEqual(try beforeListing.map { try Data(contentsOf: folder.appendingPathComponent($0)) }, beforeBytes)

            // A second CW turn stacks to 2, and a half-turn back drops the keys.
            workspace.rotateStack(burst, quarterTurnsCW: 1)
            XCTAssertEqual(workspace.displayTurns(for: burst.coverItem.primary), 2)
            workspace.rotateStack(burst, quarterTurnsCW: -2)
            for file in burst.files {
                XCTAssertEqual(workspace.displayTurns(for: file), 0, file.name)
                XCTAssertNil(model.configuration.displayOrientations[DisplayRotation.fileKey(for: file)])
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), beforeListing)
        }
    }

    /// Rotate Selection on the board turns every targeted burst the same
    /// direction in one pass — the multi-select version of Rotate Burst —
    /// and still writes nothing to disk.
    func testRotateSelectionTurnsEverySelectedBurstTogether() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0001_DSC00002.ARW"), "2026:08:26 10:00:00", "400")
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0002_DSC00001.ARW"), "2026:08:26 10:00:05", "100")
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/B0002_DSC00002.ARW"), "2026:08:26 10:00:05", "400")
            try organizerWrite(unsorted.appendingPathComponent("Transfer 1/B0002_DSC00001.xmp"), "<xmp/>")
            let location = addUnsorted(unsorted, to: model)

            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let bursts = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks.filter { $0.isBurst })
            XCTAssertEqual(bursts.count, 2)

            let folder = unsorted.appendingPathComponent("Transfer 1")
            let beforeListing = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            let beforeBytes = try beforeListing.map { try Data(contentsOf: folder.appendingPathComponent($0)) }

            workspace.rotateStacks(bursts, quarterTurnsCW: -1)

            for burst in bursts {
                for file in burst.files {
                    let expected = DisplayRotation.isRotatable(file) ? 3 : 0
                    XCTAssertEqual(workspace.displayTurns(for: file), expected, file.name)
                }
            }
            XCTAssertNil(model.configuration.displayOrientations[DisplayRotation.fileKey(for: try XCTUnwrap(bursts.flatMap(\.files).first { $0.name == "B0002_DSC00001.xmp" }))])

            // One more turn applies to every burst again; nothing lands on disk.
            workspace.rotateStacks(bursts, quarterTurnsCW: -1)
            for burst in bursts {
                XCTAssertEqual(workspace.displayTurns(for: burst.coverItem.primary), 2)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), beforeListing)
            XCTAssertEqual(try beforeListing.map { try Data(contentsOf: folder.appendingPathComponent($0)) }, beforeBytes)
        }
    }

    /// The bug: Move to Event clicked while the storage row still says
    /// "Checking" used to vanish — `eventStacks` is painted but the presence
    /// index behind it is empty until the sweep lands. The catalog already
    /// knows each file's event and the Originals path the grid implied, so
    /// the click must plan the rename from that and open a tracked job in
    /// the same moment — never return silently.
    func testMoveStacksWhilePresenceIndexIsEmptyRunsFromTheCatalog() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Sample Trip 2026", date: organizerDay("2026-08-26"), policy: .buffer))
            let targetID = try XCTUnwrap(workspace.createEvent(name: "Japan 2026", date: organizerDay("2026-08-27"), policy: .buffer))
            let event = try XCTUnwrap(workspace.event(eventID))
            let locations = workspace.locations
            let cardCopy = locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)

            // Post-Apply state: the originals already sit in the event's
            // Originals folder and the catalog says where they came from.
            var assignments: [PhotoEventAssignment] = []
            for (name, sub) in [("B0001_DSC00001.ARW", "100"), ("B0001_DSC00002.ARW", "400")] {
                let url = try writeOrganizerARW(cardCopy.appendingPathComponent(name), "2026:08:26 10:00:00", sub)
                assignments.append(PhotoEventAssignment(
                    sourceRootPath: unsorted.path,
                    relativePath: name,
                    fileSize: Int64(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)),
                    modifiedAt: Date(),
                    eventID: eventID,
                    deviceID: "sony-a7v"
                ))
            }
            model.updateConfiguration { $0.photoEventAssignments.append(contentsOf: assignments) }

            // Park the first archive stat — the stand-in for a NAS share
            // mid-sweep. The board paints; the presence index stays empty.
            let box = PresenceProbeBox()
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let libraryPrefix = locations.libraryRoot.path
            workspace.presenceProbe = { url, size, mounted in
                box.noteCall()
                if let url, url.path.hasPrefix(libraryPrefix), box.archiveCalls == 0 {
                    box.noteArchiveCall()
                    _ = gate.wait(timeout: .now() + 30)
                }
                return EventPresenceScanner.state(url, size: size, mounted: mounted)
            }

            let refresh = Task { await workspace.refreshEvent(eventID) }
            try await waitUntil { box.archiveCalls > 0 }
            let stack = try XCTUnwrap(workspace.eventStacks[eventID]?.first)
            XCTAssertNil(workspace.presence[eventID])

            workspace.moveStacks([stack.id], fromEvent: eventID, toEvent: targetID)

            // Same-moment observability: a running organize job and a status
            // line, while the sweep is still parked.
            XCTAssertTrue(model.isBusy)
            XCTAssertTrue(model.jobs.contains { $0.action == .organize && $0.state == .running })
            XCTAssertTrue(model.statusMessage.contains("Moving"))
            XCTAssertNil(workspace.presence[eventID])

            gate.signal()
            try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle == "Move to Japan 2026" }
            await refresh.value

            let target = try XCTUnwrap(workspace.event(targetID))
            let targetCopy = locations.originalsRoot(for: target, deviceID: "sony-a7v", policy: .buffer)
            for name in ["B0001_DSC00001.ARW", "B0001_DSC00002.ARW"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: targetCopy.appendingPathComponent(name).path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: cardCopy.appendingPathComponent(name).path))
            }
            XCTAssertEqual(model.configuration.photoEventAssignments.filter { $0.eventID == targetID }.count, 2)
            XCTAssertTrue(model.configuration.photoEventAssignments.filter { $0.eventID == eventID }.isEmpty)
        }
    }

    /// Move to Event before the board has painted at all: no stacks exist
    /// to open into files, so the click is queued with a readable message
    /// and runs as soon as the refresh publishes the grid.
    func testMoveStacksBeforeBoardPaintsQueuesThenRuns() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Sample Trip 2026", date: organizerDay("2026-08-26"), policy: .buffer))
            let targetID = try XCTUnwrap(workspace.createEvent(name: "Japan 2026", date: organizerDay("2026-08-27"), policy: .buffer))
            let event = try XCTUnwrap(workspace.event(eventID))
            let locations = workspace.locations
            let cardCopy = locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            let url = try writeOrganizerARW(cardCopy.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            let assignment = PhotoEventAssignment(
                sourceRootPath: unsorted.path,
                relativePath: "DSC00001.ARW",
                fileSize: Int64(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)),
                modifiedAt: Date(),
                eventID: eventID,
                deviceID: "sony-a7v"
            )
            model.updateConfiguration { $0.photoEventAssignments.append(assignment) }
            XCTAssertNil(workspace.eventStacks[eventID])

            // The board never painted, so the stack id is the cover path the
            // first paint will draw — the implied Originals path.
            let stackID = try XCTUnwrap(locations.driveURL(for: assignment, event: event, policy: .buffer)).path
            workspace.moveStacks([stackID], fromEvent: eventID, toEvent: targetID)

            XCTAssertTrue(model.statusMessage.contains("queued"))
            XCTAssertFalse(model.isBusy)

            let target = try XCTUnwrap(workspace.event(targetID))
            let destination = locations.originalsRoot(for: target, deviceID: "sony-a7v", policy: .buffer)
                .appendingPathComponent("DSC00001.ARW")
            try await waitUntil {
                FileManager.default.fileExists(atPath: destination.path)
                    && workspace.latestMoveJournalTitle == "Move to Japan 2026"
                    && !model.isBusy
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(model.configuration.photoEventAssignments.first?.eventID, targetID)
        }
    }

    /// A click that cannot move anything still answers: a destination name
    /// collision and a move onto the same event each leave a sentence.
    func testMoveStacksExplainsWhenNothingCanMove() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Sample Trip 2026", date: organizerDay("2026-08-26"), policy: .buffer))
            let targetID = try XCTUnwrap(workspace.createEvent(name: "Japan 2026", date: organizerDay("2026-08-27"), policy: .buffer))
            let event = try XCTUnwrap(workspace.event(eventID))
            let locations = workspace.locations
            let cardCopy = locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            let url = try writeOrganizerARW(cardCopy.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            let fileSize = Int64(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
            model.updateConfiguration {
                $0.photoEventAssignments.append(PhotoEventAssignment(
                    sourceRootPath: unsorted.path,
                    relativePath: "DSC00001.ARW",
                    fileSize: fileSize,
                    modifiedAt: Date(),
                    eventID: eventID,
                    deviceID: "sony-a7v"
                ))
                // The destination catalog already owns that file name.
                $0.photoEventAssignments.append(PhotoEventAssignment(
                    sourceRootPath: unsorted.path,
                    relativePath: "DSC00001.ARW",
                    fileSize: 1,
                    modifiedAt: Date(),
                    eventID: targetID,
                    deviceID: "sony-a7v"
                ))
            }
            await workspace.refreshEvent(eventID)
            let stack = try XCTUnwrap(workspace.eventStacks[eventID]?.first)

            workspace.moveStacks([stack.id], fromEvent: eventID, toEvent: eventID)
            XCTAssertTrue(model.statusMessage.contains("already in"))

            workspace.moveStacks([stack.id], fromEvent: eventID, toEvent: targetID)
            XCTAssertTrue(model.statusMessage.contains("already has files with those names"))
            XCTAssertTrue(model.statusMessage.contains("Nothing moved"))
            XCTAssertNil(workspace.latestMoveJournalTitle)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// Return to Unsorted obeys the same rule: while "Checking" hides the
    /// presence index, the catalog fallback still plans the rename back to
    /// the file's unsorted folder, and a tracked job runs it.
    func testReturnToUnsortedWhilePresenceIndexIsEmptyRenamesBack() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Sample Trip 2026", date: organizerDay("2026-08-26"), policy: .buffer))
            let event = try XCTUnwrap(workspace.event(eventID))
            let locations = workspace.locations
            let cardCopy = locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            let url = try writeOrganizerARW(cardCopy.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            let fileSize = Int64(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
            model.updateConfiguration {
                $0.photoEventAssignments.append(PhotoEventAssignment(
                    sourceRootPath: unsorted.path,
                    relativePath: "DSC00001.ARW",
                    fileSize: fileSize,
                    modifiedAt: Date(),
                    eventID: eventID,
                    deviceID: "sony-a7v"
                ))
            }

            let box = PresenceProbeBox()
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let libraryPrefix = locations.libraryRoot.path
            workspace.presenceProbe = { url, size, mounted in
                box.noteCall()
                if let url, url.path.hasPrefix(libraryPrefix), box.archiveCalls == 0 {
                    box.noteArchiveCall()
                    _ = gate.wait(timeout: .now() + 30)
                }
                return EventPresenceScanner.state(url, size: size, mounted: mounted)
            }

            let refresh = Task { await workspace.refreshEvent(eventID) }
            try await waitUntil { box.archiveCalls > 0 }
            let stack = try XCTUnwrap(workspace.eventStacks[eventID]?.first)
            XCTAssertNil(workspace.presence[eventID])

            workspace.returnToUnsorted([stack.id], eventID: eventID)

            XCTAssertTrue(model.isBusy)
            XCTAssertTrue(model.jobs.contains { $0.action == .organize && $0.state == .running })
            XCTAssertTrue(model.statusMessage.contains("Returning"))

            gate.signal()
            try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }
            await refresh.value

            // The original was renamed back to its unsorted folder — never
            // copied, never rewritten.
            XCTAssertTrue(FileManager.default.fileExists(atPath: unsorted.appendingPathComponent("DSC00001.ARW").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(model.configuration.photoEventAssignments.isEmpty)
        }
    }

    /// A file adopted from an Originals folder has no unsorted home: its
    /// catalog source is the Originals path itself. Return to Unsorted must
    /// say that instead of doing nothing — the note exists for the swept
    /// path and now also for the mid-"Checking" catalog path.
    func testReturnToUnsortedAdoptedFileExplainsItselfWhileChecking() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Sample Trip 2026", date: organizerDay("2026-08-26"), policy: .buffer))
            let event = try XCTUnwrap(workspace.event(eventID))
            let locations = workspace.locations
            let cardCopy = locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            let url = try writeOrganizerARW(cardCopy.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            let fileSize = Int64(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
            model.updateConfiguration {
                $0.photoEventAssignments.append(PhotoEventAssignment(
                    sourceRootPath: cardCopy.path,
                    relativePath: "DSC00001.ARW",
                    fileSize: fileSize,
                    modifiedAt: Date(),
                    eventID: eventID,
                    deviceID: "sony-a7v"
                ))
            }

            let box = PresenceProbeBox()
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let libraryPrefix = locations.libraryRoot.path
            workspace.presenceProbe = { url, size, mounted in
                box.noteCall()
                if let url, url.path.hasPrefix(libraryPrefix), box.archiveCalls == 0 {
                    box.noteArchiveCall()
                    _ = gate.wait(timeout: .now() + 30)
                }
                return EventPresenceScanner.state(url, size: size, mounted: mounted)
            }

            let refresh = Task { await workspace.refreshEvent(eventID) }
            try await waitUntil { box.archiveCalls > 0 }
            let stack = try XCTUnwrap(workspace.eventStacks[eventID]?.first)

            workspace.returnToUnsorted([stack.id], eventID: eventID)

            XCTAssertTrue(model.statusMessage.contains("already organized on the drive"))
            XCTAssertFalse(model.isBusy)
            XCTAssertNil(workspace.latestMoveJournalTitle)

            gate.signal()
            await refresh.value
            // Nothing moved and nothing was unassigned.
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(model.configuration.photoEventAssignments.count, 1)
        }
    }

    /// The context-menu state type answers from the stack values it is
    /// handed — the fixture paths point at files that do not exist, so any
    /// `standardizedFileURL`/`resourceValues` work inside it could not even
    /// produce an answer.
    func testStackMenuStateAnswersWithoutFilesystem() {
        let photo = OrganizeItem(
            primary: OrganizeFile(path: "/definitely/not/here/B0001_DSC00001.ARW", size: 1, modifiedAt: Date()),
            kind: .raw,
            captureDate: Date(),
            hasCameraDate: true
        )
        let sidecar = OrganizeItem(
            primary: OrganizeFile(path: "/definitely/not/here/B0001_DSC00001.xmp", size: 1, modifiedAt: Date()),
            kind: .other,
            captureDate: Date(),
            hasCameraDate: false
        )
        let photoStack = OrganizeStack(items: [photo])
        let sidecarStack = OrganizeStack(items: [sidecar])
        let targets = [EventMenuTarget(id: UUID(), title: "Trip")]

        let rotatable = OrganizeStackMenuState(targetIDs: [photoStack.id], stacks: [photoStack], eventTargets: targets)
        XCTAssertTrue(rotatable.canRotate)
        XCTAssertNil(rotatable.rotateHelp)
        XCTAssertEqual(rotatable.rotateTitle, "Rotate Burst")
        XCTAssertEqual(rotatable.eventTargets, targets)

        let sidecarsOnly = OrganizeStackMenuState(targetIDs: [sidecarStack.id], stacks: [sidecarStack], eventTargets: targets)
        XCTAssertFalse(sidecarsOnly.canRotate)
        XCTAssertNotNil(sidecarsOnly.rotateHelp)

        let multi = OrganizeStackMenuState(targetIDs: [photoStack.id, sidecarStack.id], stacks: [photoStack, sidecarStack], eventTargets: targets)
        XCTAssertTrue(multi.canRotate)
        XCTAssertEqual(multi.rotateTitle, "Rotate Selection")

        let gone = OrganizeStackMenuState(targetIDs: ["ghost"], stacks: [], eventTargets: targets)
        XCTAssertFalse(gone.canRotate)
        XCTAssertNotNil(gone.rotateHelp)
    }

    /// The workspace's menu state resolves clicked/selected stacks through
    /// the id indexes — a right-click on a painted event board or a scanned
    /// unsorted board answers without walking the board's stacks.
    func testStackMenuStateResolvesTargetsAndEvents() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("B0001_DSC00001.ARW"), "2026:08:26 10:00:00", "100")
            try writeOrganizerARW(unsorted.appendingPathComponent("B0001_DSC00002.ARW"), "2026:08:26 10:00:00", "400")
            try organizerWrite(unsorted.appendingPathComponent("DSC00010.xmp"), "<xmp/>")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let stacks = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks)
            let burst = try XCTUnwrap(stacks.first { $0.isBurst })
            let sidecar = try XCTUnwrap(stacks.first { !$0.isBurst })

            let eventID = try XCTUnwrap(workspace.createEvent(name: "Sample Trip 2026", date: organizerDay("2026-08-26"), policy: .buffer))
            let otherID = try XCTUnwrap(workspace.createEvent(name: "Japan 2026", date: organizerDay("2026-08-27"), policy: .buffer))

            // Unsorted board: every event is a Sort Into target.
            let unsortedMenu = workspace.stackMenuState(forStackID: burst.id, inLocation: location.id)
            XCTAssertEqual(unsortedMenu.targetIDs, [burst.id])
            XCTAssertEqual(Set(unsortedMenu.eventTargets.map(\.id)), [eventID, otherID])
            XCTAssertTrue(unsortedMenu.canRotate)

            let sidecarMenu = workspace.stackMenuState(forStackID: sidecar.id, inLocation: location.id)
            XCTAssertFalse(sidecarMenu.canRotate)
            XCTAssertNotNil(sidecarMenu.rotateHelp)

            // A clicked stack inside the selection targets the selection.
            workspace.selectStacks([burst.id, sidecar.id])
            let selectedMenu = workspace.stackMenuState(forStackID: burst.id, inLocation: location.id)
            XCTAssertEqual(selectedMenu.targetIDs, [burst.id, sidecar.id])
            XCTAssertEqual(selectedMenu.rotateTitle, "Rotate Selection")

            // Event board: the board's own event is not a Move target.
            workspace.assign(stackIDs: [burst.id], from: location.id, to: eventID)
            await workspace.refreshEvent(eventID)
            let boardStack = try XCTUnwrap(workspace.eventStacks[eventID]?.first)
            let eventMenu = workspace.stackMenuState(forStackID: boardStack.id, inEvent: eventID)
            XCTAssertEqual(eventMenu.targetIDs, [boardStack.id])
            XCTAssertEqual(eventMenu.eventTargets.map(\.id), [otherID])
            XCTAssertTrue(eventMenu.canRotate)

            // A stack id that is not on the board still answers, disabled.
            let staleMenu = workspace.stackMenuState(forStackID: "ghost", inEvent: eventID)
            XCTAssertFalse(staleMenu.canRotate)
            XCTAssertNotNil(staleMenu.rotateHelp)
        }
    }

    /// While a speed test owns the volume, the workspace's background work
    /// — drive-event discovery, the refresh pipeline's capture-date reads,
    /// and the presence sweep — waits at the gate instead of touching the
    /// drive, then proceeds once the gate resumes.
    func testBackgroundDriveWorkWaitsWhileTheVolumeIsUnderTest() async throws {
        let gate = DriveActivityGate()
        try await withOrganizerSandbox(driveActivityGate: gate) { root, model, workspace in
            let drive = root.appendingPathComponent("Drive", isDirectory: true)
            // A hand-organized event folder for discovery to find, and an
            // assignable drop so the presence sweep has work too.
            try writeOrganizerARW(
                drive.appendingPathComponent("Camera Buffer/2026/2026-08-26 Harbor/Originals/Sony A7V/DSC00001.ARW"),
                "2026:08:26 10:00:00",
                "000"
            )
            let unsorted = drive.appendingPathComponent("Unsorted A7V", isDirectory: true)
            try writeOrganizerARW(unsorted.appendingPathComponent("Transfer 1/DSC00002.ARW"), "2026:08:26 11:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            let stack = try XCTUnwrap(workspace.sources[location.id]?.result?.stacks.first)
            workspace.assign(stackIDs: [stack.id], from: location.id, to: eventID)

            let probed = ProbePathBox()
            workspace.presenceProbe = { url, size, mounted in
                if let url { probed.note(url.path) }
                return EventPresenceScanner.state(url, size: size, mounted: mounted)
            }

            gate.pause(drive)
            defer { gate.resume(drive) }

            workspace.discoverDriveEvents()
            let refresh = Task { await workspace.refreshEvent(eventID) }
            try await Task.sleep(for: .milliseconds(400))
            // Parked: no discovery results and not a single sweep probe —
            // nothing touched the gated volume while the test owned it.
            XCTAssertTrue(workspace.discoveredDriveEvents.isEmpty)
            XCTAssertTrue(probed.paths.isEmpty)

            gate.resume(drive)
            await refresh.value
            try await waitUntil { !workspace.discoveredDriveEvents.isEmpty }
            try await waitUntil { workspace.presence[eventID] != nil }
            XCTAssertFalse(probed.paths.isEmpty)
        }
    }

    // MARK: - Helpers

    private func withOrganizerSandbox(
        driveActivityGate: DriveActivityGate = DriveActivityGate(),
        _ body: (URL, DashboardModel, EventsWorkspace) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitOrganizer-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resolvedRoot = root.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: resolvedRoot) }
        let configuration = AppConfiguration(
            demoRootPath: resolvedRoot.appendingPathComponent("Safety Test").path,
            importSourcePath: resolvedRoot.appendingPathComponent("Card").path,
            archivePath: resolvedRoot.appendingPathComponent("Library/Originals").path,
            bufferPath: resolvedRoot.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: resolvedRoot.appendingPathComponent("Library").path,
            catalogDatabasePath: resolvedRoot.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: resolvedRoot.appendingPathComponent("activity.jsonl").path,
            selectedDeviceID: "sony-a7v"
        )
        let model = DashboardModel(
            jobs: [],
            configuration: configuration,
            configurationStore: ConfigurationStore(url: resolvedRoot.appendingPathComponent("config.json"))
        )
        let workspace = EventsWorkspace(
            model: model,
            supportFolder: resolvedRoot.appendingPathComponent("Support", isDirectory: true),
            driveActivityGate: driveActivityGate
        )
        try await body(resolvedRoot, model, workspace)
    }

    private func addUnsorted(_ url: URL, to model: DashboardModel) -> ConfiguredLocation {
        let location = ConfiguredLocation(role: .importSource, name: url.lastPathComponent, path: url.path, deviceID: "sony-a7v")
        model.updateConfiguration { $0.configuredLocations.append(location) }
        return location
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the organizer")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func organizerDay(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }

    @discardableResult
    private func organizerWrite(_ url: URL, _ string: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(string.utf8).write(to: url)
        return url
    }

    /// A real JPEG the tile loader can actually decode — unlike the fake
    /// ARW stub, which is only a header.
    @discardableResult
    private func writeOrganizerJPEG(_ url: URL, width: Int = 320, height: Int = 240) throws -> URL {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ))
        let data = try XCTUnwrap(representation.representation(using: .jpeg, properties: [:]))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// A little-endian TIFF header with an EXIF capture time, padded like a tiny RAW.
    @discardableResult
    private func writeOrganizerARW(_ url: URL, _ original: String, _ subseconds: String) throws -> URL {
        var bytes: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0]
        func append16(_ value: Int) { bytes += [UInt8(value & 0xff), UInt8(value >> 8 & 0xff)] }
        func append32(_ value: Int) { (0..<4).forEach { bytes.append(UInt8(value >> ($0 * 8) & 0xff)) } }
        append16(1)
        append16(0x8769); append16(4); append32(1); append32(26)
        append32(0)
        append16(2)
        append16(0x9003); append16(2); append32(20); append32(56)
        append16(0x9291); append16(2); append32(4); bytes += Array((String((subseconds + "000").prefix(3)) + "\0").utf8)
        append32(0)
        bytes += Array((original + "\0").utf8)
        bytes += [UInt8](repeating: 0xAB, count: 256)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }
}

// MARK: - Apply collisions (a taken destination name)

extension EventsWorkspaceTests {
    private func cardCopy(_ root: URL, event: String) -> URL {
        root.appendingPathComponent("Drive/Camera Buffer/2026/\(event)/Originals/Sony A7V", isDirectory: true)
    }

    /// Regression: a sorted file whose event name was taken by a different
    /// photo was planned as "Move 1 File", then left in place by the rename
    /// job on every Apply. The plan now flags it, the sheet does not count
    /// it, the status line says why, and Keep Both moves it in under a free
    /// "(2)" name that Undo reverses.
    func testApplyFlagsANameConflictAndKeepBothMovesItInUndoably() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Found Folder", isDirectory: true)
            let clash = try writeOrganizerARW(unsorted.appendingPathComponent("DSC00001.ARW"), "2026:08:26 10:00:00", "000")
            let clashXMP = try organizerWrite(unsorted.appendingPathComponent("DSC00001.xmp"), "<new/>")
            let clean = try writeOrganizerARW(unsorted.appendingPathComponent("DSC00003.ARW"), "2026:08:26 10:10:00", "000")
            let location = addUnsorted(unsorted, to: model)
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            // A different photo with the same name (another camera, a counter reset).
            let existing = try organizerWrite(cardCopy(root, event: "2026-08-26 Beach Day").appendingPathComponent("DSC00001.ARW"), "an older, different photo")

            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            workspace.assign(stackIDs: Set(result.stacks.map(\.id)), from: location.id, to: eventID)
            XCTAssertEqual(model.configuration.photoEventAssignments.count, 3)

            let plan = EventsWorkspace.buildApplyPlan(
                events: [try XCTUnwrap(workspace.event(eventID))],
                configuration: model.configuration,
                locations: workspace.locations,
                onlyUnder: unsorted.path,
                title: "Apply",
                unsortedRoots: [unsorted]
            )
            XCTAssertEqual(plan.moveCount, 1, "only the free name moves")
            XCTAssertEqual(plan.conflictCount, 1)
            XCTAssertEqual(plan.duplicateCount, 0)
            let group = try XCTUnwrap(plan.groups.first)
            XCTAssertEqual(group.conflicts.map(\.fileName).sorted(), ["DSC00001.ARW", "DSC00001.xmp"])
            XCTAssertEqual(group.conflicts.first { $0.fileName == "DSC00001.xmp" }?.kind, .travelsWithConflict)

            let overview = ApplyPlanOverview(plan: plan)
            XCTAssertEqual(overview.primaryActionTitle, "Move 1 File")
            XCTAssertEqual(overview.conflictCount, 1)
            XCTAssertEqual(overview.collisions.first?.conflictLine, "1 file can’t move: a different DSC00001.ARW is already in Beach Day")

            workspace.performApply(plan)
            try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }
            XCTAssertTrue(FileManager.default.fileExists(atPath: cardCopy(root, event: "2026-08-26 Beach Day").appendingPathComponent("DSC00003.ARW").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: clean.path))
            let status = try XCTUnwrap(model.statusMessage)
            XCTAssertTrue(status.hasPrefix("Moved 1 file(s)"), status)
            XCTAssertTrue(status.contains("a different DSC00001.ARW is already in Beach Day — open Apply to resolve."), status)
            XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "an older, different photo")

            workspace.keepBoth(plan)
            try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle == "Keep both in Beach Day" }
            let keptRaw = cardCopy(root, event: "2026-08-26 Beach Day").appendingPathComponent("DSC00001 (2).ARW")
            let keptXMP = cardCopy(root, event: "2026-08-26 Beach Day").appendingPathComponent("DSC00001 (2).xmp")
            XCTAssertTrue(FileManager.default.fileExists(atPath: keptRaw.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: keptXMP.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: clash.path))
            XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "an older, different photo")
            XCTAssertEqual(
                Set(model.configuration.photoEventAssignments.map(\.relativePath)),
                ["DSC00001 (2).ARW", "DSC00001 (2).xmp", "DSC00003.ARW"]
            )
            await workspace.refreshEvent(eventID)
            XCTAssertEqual(workspace.presence[eventID]?.onDrive, 3)

            workspace.undoLastMove()
            try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle == "Apply" }
            XCTAssertTrue(FileManager.default.fileExists(atPath: clash.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: clashXMP.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: keptRaw.path))
            XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "an older, different photo")
            XCTAssertEqual(
                Set(model.configuration.photoEventAssignments.map(\.relativePath)),
                ["DSC00001.ARW", "DSC00001.xmp", "DSC00003.ARW"]
            )
        }
    }

    /// The sheet's primary button with its default choices: the free name
    /// moves and the taken one keeps both, in one job — one Undo reverses
    /// both, and the file that already had the name is never touched.
    func testApplyWithDefaultChoicesMovesAndKeepsBothInOneUndoableJob() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Found Folder", isDirectory: true)
            let clash = try writeOrganizerARW(unsorted.appendingPathComponent("DSC00001.ARW"), "2026:08:19 10:00:00", "000")
            let clean = try writeOrganizerARW(unsorted.appendingPathComponent("DSC00003.ARW"), "2026:08:19 10:10:00", "000")
            let location = addUnsorted(unsorted, to: model)
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-19"), policy: .buffer))
            let folder = cardCopy(root, event: "2026-08-19 Beach Day")
            let existing = try organizerWrite(folder.appendingPathComponent("DSC00001.ARW"), "a different photo")

            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            workspace.assign(stackIDs: Set(result.stacks.map(\.id)), from: location.id, to: eventID)
            let plan = EventsWorkspace.buildApplyPlan(
                events: [try XCTUnwrap(workspace.event(eventID))],
                configuration: model.configuration,
                locations: workspace.locations,
                onlyUnder: unsorted.path,
                title: "Apply",
                unsortedRoots: [unsorted]
            )
            let overview = ApplyPlanOverview(plan: plan)
            let decisions = ApplyCollisionResolution.decisions(
                for: overview.collisionItems,
                choices: ApplyCollisionResolution.defaultChoices(for: overview.collisionItems)
            )
            XCTAssertEqual(overview.primaryActionTitle(with: decisions), "Move 2 Files (Keep Both for 1)")

            workspace.performApply(plan, resolving: decisions)
            try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle == "Apply" }
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("DSC00003.ARW").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("DSC00001 (2).ARW").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: clash.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: clean.path))
            XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "a different photo")
            XCTAssertEqual(
                Set(model.configuration.photoEventAssignments.map(\.relativePath)),
                ["DSC00001 (2).ARW", "DSC00003.ARW"]
            )
            XCTAssertNil(workspace.pendingTrash)

            workspace.undoLastMove()
            try await waitUntil { !model.isBusy && FileManager.default.fileExists(atPath: clash.path) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: clean.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("DSC00001 (2).ARW").path))
            XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "a different photo")
            XCTAssertEqual(
                Set(model.configuration.photoEventAssignments.map(\.relativePath)),
                ["DSC00001.ARW", "DSC00003.ARW"]
            )
        }
    }

    /// An identical copy already in the event is not pending, the sheet
    /// shows it instead of "Move 1 File", and "Move Duplicate to Trash"
    /// goes through the organizer Trash confirmation into `_Trash` —
    /// never a delete — keeping the event's only assignment for the photo.
    func testIdenticalCopyIsNotPendingAndGoesToTrashOnlyThroughTheConfirmation() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let unsorted = root.appendingPathComponent("Drive/Found Folder", isDirectory: true)
            let spare = try writeOrganizerARW(unsorted.appendingPathComponent("DSC00002.ARW"), "2026:08:26 10:00:00", "000")
            let location = addUnsorted(unsorted, to: model)
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            let inEvent = cardCopy(root, event: "2026-08-26 Beach Day").appendingPathComponent("DSC00002.ARW")
            try FileManager.default.createDirectory(at: inEvent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: spare, to: inEvent)

            workspace.scan(location)
            try await waitUntil { workspace.sources[location.id]?.result != nil }
            let result = try XCTUnwrap(workspace.sources[location.id]?.result)
            workspace.assign(stackIDs: Set(result.stacks.map(\.id)), from: location.id, to: eventID)
            XCTAssertEqual(workspace.sortedFiles(in: result).files, 1)

            workspace.prepareApply(sourceLocationID: location.id)
            try await waitUntil { workspace.pendingApplyPlan != nil }
            let plan = try XCTUnwrap(workspace.pendingApplyPlan)
            XCTAssertTrue(plan.isEmpty)
            XCTAssertEqual(plan.duplicateCount, 1)
            XCTAssertEqual(plan.groups.first?.alreadyThere, 0)

            // Every file is blocked: the button does not pretend to move.
            let overview = ApplyPlanOverview(plan: plan)
            XCTAssertEqual(overview.primaryActionTitle, "Nothing to Move")
            XCTAssertEqual(overview.sentence, "DSC00002.ARW is already in Beach Day as an identical copy.")
            XCTAssertEqual(model.statusMessage, "1 photo is already in Beach Day (identical copy) — open Apply to resolve.")

            // Marked as already in the event: not "nothing moves until you Apply".
            XCTAssertEqual(workspace.sortedFiles(in: result).files, 0)
            XCTAssertEqual(workspace.applyCollisions(in: result).duplicates, 1)

            // Nothing is trashed until the owner confirms.
            workspace.requestTrashApplyDuplicates(plan)
            XCTAssertNil(workspace.pendingApplyPlan)
            let request = try XCTUnwrap(workspace.pendingTrash)
            XCTAssertEqual(request.fileCount, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: spare.path))
            XCTAssertEqual(request.preservedAssignmentKeys.count, 1)

            workspace.confirmTrash(request)
            try await waitUntil { !model.isBusy && workspace.sources[location.id]?.result?.items.isEmpty == true }
            XCTAssertFalse(FileManager.default.fileExists(atPath: spare.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: inEvent.path))
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            let trashed = FileManager.default.enumerator(atPath: trash.path)?.compactMap { $0 as? String } ?? []
            XCTAssertTrue(trashed.contains { $0.hasSuffix("DSC00002.ARW") }, "\(trashed)")
            // The event's only record of the photo stays and now finds the copy in the event.
            XCTAssertEqual(model.configuration.photoEventAssignments.count, 1)
            await workspace.refreshEvent(eventID)
            XCTAssertEqual(workspace.presence[eventID]?.onDrive, 1)
        }
    }
}

/// Counts NotificationCenter posts — the observer block is `@Sendable`, so
/// the tally lives behind a lock.
private final class NotificationPostBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int { lock.withLock { _count } }

    func note() {
        lock.withLock { _count += 1 }
    }
}

/// What the injected presence probe observed inside the sweep: where the
/// stat ran, at what priority, and how far it got before parking.
private final class PresenceProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _onMainThread = true
    private var _priority: TaskPriority?
    private var _archiveCalls = 0

    var onMainThread: Bool { lock.withLock { _onMainThread } }
    var priority: TaskPriority? { lock.withLock { _priority } }
    var archiveCalls: Int { lock.withLock { _archiveCalls } }

    func noteCall() {
        lock.withLock {
            _onMainThread = Thread.isMainThread
            _priority = Task<Never, Never>.currentPriority
        }
    }

    func noteArchiveCall() {
        lock.withLock { _archiveCalls += 1 }
    }
}

/// Paths the injected presence probe touched — the pause test asserts the
/// sweep never stats the volume while it is gated.
private final class ProbePathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []

    var paths: [String] { lock.withLock { _paths } }

    func note(_ path: String) {
        lock.withLock { _paths.append(path) }
    }
}

/// What the injected path resolver observed inside an event refresh:
/// which assignments resolved before the deferred build parked, and
/// whether any of that ran on the main thread.
private final class EventPathProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _resolved: Set<String> = []
    private var _parkedCalls = 0
    private var _onMainThread = false

    var resolved: Set<String> { lock.withLock { _resolved } }
    var parkedCalls: Int { lock.withLock { _parkedCalls } }
    var onMainThread: Bool { lock.withLock { _onMainThread } }

    func noteResolved(_ relativePath: String) {
        lock.withLock {
            _resolved.insert(relativePath)
            _onMainThread = _onMainThread || Thread.isMainThread
        }
    }

    /// Returns true for the first parked call only — the one the test
    /// holds on its gate while it inspects the first-screen publish.
    func noteParkedCall() -> Bool {
        lock.withLock {
            _parkedCalls += 1
            _onMainThread = _onMainThread || Thread.isMainThread
            return _parkedCalls == 1
        }
    }
}

/// What the injected capture-date reader observed inside the deferred
/// build: how many header reads ran and whether any ran on the main
/// thread.
private final class CaptureDateReadProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _readCalls = 0
    private var _onMainThread = false

    var readCalls: Int { lock.withLock { _readCalls } }
    var onMainThread: Bool { lock.withLock { _onMainThread } }

    /// Returns true for the first read only — the one the test holds on
    /// its gate while it inspects the provisional grid.
    func noteReadCall() -> Bool {
        lock.withLock {
            _readCalls += 1
            _onMainThread = _onMainThread || Thread.isMainThread
            return _readCalls == 1
        }
    }
}

/// Finds nothing — so face scans can run in tests without the sidecar.
private struct StubFaceAnalyzer: FaceAnalyzing {
    var displayName: String { "StubFaceAnalyzer" }

    func analyze(_ image: CGImage, options: FaceScanOptions) throws -> [AnalyzedFace] {
        []
    }
}
