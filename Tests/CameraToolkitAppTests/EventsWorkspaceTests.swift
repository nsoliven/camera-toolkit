import CameraToolkitCore
import CoreGraphics
import Foundation
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

            let bufferEvent = root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-26 Beach Day/Sony A7V/Card Copy", isDirectory: true)
            let privateEvent = root.appendingPathComponent("Drive/.Camera Toolkit/Private/2026/2026-08-26 Hotel Night/Sony A7V/Card Copy", isDirectory: true)
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

            let privateCopy = root.appendingPathComponent("Drive/.Camera Toolkit/Private/2026/2026-08-27 Just Us/Sony A7V/Card Copy/B0007_DSC00002.ARW")
            XCTAssertTrue(FileManager.default.fileExists(atPath: privateCopy.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-27 City Walk").path))
            XCTAssertEqual(model.configuration.photoEventAssignments.filter { $0.eventID == hidden }.count, 2)
            XCTAssertTrue(model.configuration.photoEventAssignments.filter { $0.eventID == shared }.isEmpty)
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

            workspace.trash(stackIDs: [burst.id], from: location.id)
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
            XCTAssertTrue(workspace.pendingTrash?.alertMessage.contains("_Trash") == true)

            workspace.pendingTrash = nil
            XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
        }
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
            let parentA = try XCTUnwrap(workspace.createEvent(name: "PHIL2026", date: organizerDay("2026-08-21"), policy: .buffer))
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

            XCTAssertEqual(workspace.eventTitle(try XCTUnwrap(workspace.event(child))), "PHIL2026 / Matcha")
        }
    }

    func testRenamingParentMovesSubeventFolderAndRewritesAssignments() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let parent = try XCTUnwrap(workspace.createEvent(name: "PHIL2026", date: organizerDay("2026-08-21"), policy: .buffer))
            let child = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parent))
            let cardCopy = root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-21 PHIL2026/2026-08-23 Matcha/Sony A7V/Card Copy", isDirectory: true)
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

            workspace.renameEvent(parent, name: "PHIL2026 Renamed", date: organizerDay("2026-08-21"), policy: .buffer, parentEventID: nil)

            let movedFolder = root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-21 PHIL2026 Renamed", isDirectory: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-21 PHIL2026").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: movedFolder.appendingPathComponent("2026-08-23 Matcha/Sony A7V/Card Copy/DSC00001.ARW").path))
            XCTAssertEqual(
                model.configuration.photoEventAssignments.first?.sourceRootPath,
                movedFolder.appendingPathComponent("2026-08-23 Matcha/Sony A7V/Card Copy").path
            )
        }
    }

    func testReparentingMovesTheEventFolder() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            let parent = try XCTUnwrap(workspace.createEvent(name: "PHIL2026", date: organizerDay("2026-08-21"), policy: .buffer))
            let child = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parent))
            let nestedFolder = root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-21 PHIL2026/2026-08-23 Matcha/Sony A7V/Card Copy", isDirectory: true)
            try writeOrganizerARW(nestedFolder.appendingPathComponent("DSC00001.ARW"), "2026:08:23 10:00:00", "000")

            workspace.renameEvent(child, name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: nil)

            XCTAssertNil(workspace.event(child)?.parentEventID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: nestedFolder.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-23 Matcha/Sony A7V/Card Copy/DSC00001.ARW").path))
        }
    }

    func testDeleteEmptyEventRefusesAParentWithSubevents() async throws {
        try await withOrganizerSandbox { root, model, workspace in
            _ = root
            let parent = try XCTUnwrap(workspace.createEvent(name: "PHIL2026", date: organizerDay("2026-08-21"), policy: .buffer))
            _ = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parent))

            workspace.deleteEmptyEvent(parent)
            XCTAssertNotNil(workspace.event(parent))
            XCTAssertTrue(model.statusMessage.contains("subevents"))
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

            let parent = try XCTUnwrap(workspace.createEvent(name: "PHIL2026", date: organizerDay("2026-08-21"), policy: .archiveOnly))
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

            let nested = root.appendingPathComponent("Drive/.Camera Toolkit/Private/2026/2026-08-21 PHIL2026/2026-08-23 Matcha/Sony A7V/Card Copy/DSC00001.ARW")
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

            let parent = try XCTUnwrap(workspace.createEvent(name: "PHIL2026", date: organizerDay("2026-08-21"), policy: .buffer))
            let child = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-23"), policy: nil, parentEventID: parent))
            let other = try XCTUnwrap(workspace.createEvent(name: "Other Trip", date: organizerDay("2026-08-21"), policy: .buffer))

            // Sidebar events: a parent-name hit reveals the subevent row too;
            // a child-name hit keeps only the matching child.
            XCTAssertEqual(Set(workspace.sidebarRows(matching: "phil").map(\.event.id)), [parent, child])
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
            XCTAssertEqual(workspace.visibleDays(result, hideSorted: false, matching: "phil").flatMap(\.stacks).map(\.id), [burst.id])

            // hideSorted composes with the query: a sorted stack matching the
            // query is still hidden, an unsorted match stays.
            XCTAssertTrue(workspace.visibleDays(result, hideSorted: true, matching: "b0001").isEmpty)
            XCTAssertEqual(workspace.visibleDays(result, hideSorted: true, matching: "dsc00009").flatMap(\.stacks).map(\.id), [single.id])

            // Discovered drive events filter by name for the banner.
            let cardCopy = root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-26 Found Day/Sony A7V/Card Copy", isDirectory: true)
            try writeOrganizerARW(cardCopy.appendingPathComponent("DSC00050.ARW"), "2026:08:26 12:00:00", "000")
            workspace.discoverDriveEvents()
            try await waitUntil { !workspace.discoveredDriveEvents.isEmpty }
            XCTAssertEqual(workspace.discoveredDriveEvents(matching: "found day").count, 1)
            XCTAssertEqual(workspace.discoveredDriveEvents(matching: "").count, workspace.discoveredDriveEvents.count)
            XCTAssertTrue(workspace.discoveredDriveEvents(matching: "zzz").isEmpty)
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
        }
    }

    /// The chip filter's full loop on a real scan: media, day range,
    /// event (incl. Not Sorted Yet), and face-catalog people all ANDed
    /// together with the text needle.
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

            // Empty search shows everything.
            XCTAssertEqual(board(OrganizeSearchFilter()), [burst.id, single.id, clip.id])

            // Media facet.
            var search = OrganizeSearchFilter()
            search.mediaKinds = [.video]
            XCTAssertEqual(board(search), [clip.id])
            search.mediaKinds = [.raw]
            XCTAssertEqual(board(search), [burst.id, single.id])

            // Date facet — inclusive bounds on each stack's capture day.
            // The clip has no camera date; the scan's clock-offset
            // correction still lands it on a day near the RAWs', so
            // compare against the days the scanner actually assigned.
            let calendar = Calendar.current
            let burstDay = calendar.startOfDay(for: burst.captureDate)
            let singleDay = calendar.startOfDay(for: single.captureDate)
            let clipDay = calendar.startOfDay(for: clip.captureDate)
            XCTAssertNotEqual(burstDay, singleDay)

            search = OrganizeSearchFilter()
            search.dayStart = burstDay
            search.dayEnd = burstDay
            XCTAssertTrue(board(search).contains(burst.id))
            XCTAssertFalse(board(search).contains(single.id))
            XCTAssertEqual(board(search).contains(clip.id), clipDay == burstDay)

            search.dayStart = singleDay
            search.dayEnd = singleDay
            XCTAssertTrue(board(search).contains(single.id))
            XCTAssertFalse(board(search).contains(burst.id))

            search.dayStart = burstDay
            search.dayEnd = singleDay
            XCTAssertTrue(board(search).isSuperset(of: [burst.id, single.id]))

            // A range starting after the last capture day matches nothing.
            search.dayStart = calendar.date(byAdding: .day, value: 1, to: singleDay)
            search.dayEnd = nil
            XCTAssertTrue(board(search).isEmpty)

            // Event facet, including "Not Sorted Yet".
            let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: burstDay, policy: .buffer))
            workspace.assign(stackIDs: [burst.id], from: location.id, to: beach)
            search = OrganizeSearchFilter()
            search.eventIDs = [beach]
            XCTAssertEqual(board(search), [burst.id])
            search.includeUnsorted = true
            XCTAssertEqual(board(search), [burst.id, single.id, clip.id])
            search.eventIDs = []
            XCTAssertEqual(board(search), [single.id, clip.id])
            // hideSorted composes: the assigned burst drops out.
            XCTAssertEqual(board(OrganizeSearchFilter(), hideSorted: true), [single.id, clip.id])

            // People facet — seed the face index as if a scan ran: Dad
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

            // Picker options: roster first, then groups — only people
            // actually seen on this board.
            let people = workspace.boardPeople(for: result.stacks)
            XCTAssertEqual(people.options.map(\.name), ["Dad", "Person 1"])
            XCTAssertEqual(people.options.map(\.isRoster), [true, false])
            XCTAssertEqual(people.byStackID[single.id], [dad.id])
            XCTAssertEqual(people.byStackID[burst.id], [group.id])
            XCTAssertEqual(people.byStackID[clip.id], [])

            search = OrganizeSearchFilter()
            search.peopleIDs = [dad.id]
            XCTAssertEqual(board(search), [single.id])
            search.peopleIDs = [dad.id, group.id]
            XCTAssertEqual(board(search), [burst.id, single.id])

            // Facets AND together — and with the text needle.
            search.mediaKinds = [.raw]
            search.dayStart = singleDay
            search.dayEnd = singleDay
            XCTAssertEqual(board(search), [single.id])
            search.text = "dsc00009"
            XCTAssertEqual(board(search), [single.id])
            search.eventIDs = [beach]
            XCTAssertTrue(board(search).isEmpty)

            // The event board runs the same facets minus Event.
            workspace.eventStacks[beach] = [burst, single, clip]
            var eventSearch = OrganizeSearchFilter()
            eventSearch.mediaKinds = [.video]
            XCTAssertEqual(workspace.visibleEventStacks(beach, search: eventSearch).map(\.id), [clip.id])
            eventSearch = OrganizeSearchFilter()
            eventSearch.peopleIDs = [group.id]
            XCTAssertEqual(workspace.visibleEventStacks(beach, search: eventSearch).map(\.id), [burst.id])
            XCTAssertEqual(workspace.visibleEventStacks(beach, search: OrganizeSearchFilter()).count, 3)
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

            workspace.faceEmbedderProvider = { StubFaceEmbedder() }
            workspace.faceScan(location)
            try await waitUntil { !model.isBusy }

            // The Jobs window lists model.jobs — the face scan appears there.
            let job = try XCTUnwrap(model.jobs.first { $0.action == .faceScan })
            XCTAssertEqual(job.state, .done)
            XCTAssertEqual(job.action.displayName, "Face Scan")
            XCTAssertTrue(model.statusMessage.contains("Face scan done"))
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
            let phil = try XCTUnwrap(workspace.createEvent(name: "PHIL2026", date: organizerDay("2026-08-26"), policy: .buffer))
            let matcha = try XCTUnwrap(workspace.createEvent(name: "Matcha", date: organizerDay("2026-08-26"), policy: .buffer, parentEventID: phil))
            let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: organizerDay("2026-08-26"), policy: .buffer))
            let hotel = try XCTUnwrap(workspace.createEvent(name: "Hotel Night", date: organizerDay("2026-08-26"), policy: .buffer))
            let matchaEvent = try XCTUnwrap(workspace.event(matcha))
            XCTAssertEqual(workspace.eventTitle(matchaEvent), "PHIL2026 / Matcha")

            // Hotel entering evicted Beach, so the unfiltered picker shows
            // the three recents up top and only Beach below.
            let all = workspace.eventPickerSections(matching: "")
            XCTAssertEqual(all.recent.map(\.id), [hotel, phil, matcha])
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
            let philHit = workspace.eventPickerSections(matching: "phil")
            XCTAssertEqual(philHit.recent.map(\.id), [phil, matcha])
            XCTAssertTrue(philHit.other.isEmpty)

            let none = workspace.eventPickerSections(matching: "zzz")
            XCTAssertTrue(none.recent.isEmpty && none.other.isEmpty)

            // The board's own event is dropped from both sections.
            let moving = workspace.eventPickerSections(matching: "", excluding: hotel)
            XCTAssertEqual(moving.recent.map(\.id), [phil, matcha])
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

    // MARK: - Helpers

    private func withOrganizerSandbox(
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
            activePlan: CopyPlan(),
            jobs: [],
            configuration: configuration,
            configurationStore: ConfigurationStore(url: resolvedRoot.appendingPathComponent("config.json"))
        )
        let workspace = EventsWorkspace(model: model, supportFolder: resolvedRoot.appendingPathComponent("Support", isDirectory: true))
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

/// Embeds nothing real — a fixed unit vector — so face scans can run in
/// tests without the CoreML package.
private struct StubFaceEmbedder: FaceEmbeddingProviding {
    func embed(_ image: CGImage) throws -> [Float] {
        FaceEmbeddingMath.l2Normalized([Float](repeating: 1, count: 512))
    }
}
