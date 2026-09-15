import CameraToolkitCore
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
