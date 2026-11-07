import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

/// "Found on the NAS → Add to Events" through the workspace: a subevent
/// whose files only the NAS holds joins the catalog as NAS-only files, with
/// a photo-list backup first and nothing on disk changed.
@MainActor
final class NASAdoptWorkspaceTests: XCTestCase {
    func testAddToEventsPutsNASOnlyFilesOnTheirSubeventAfterABackup() async throws {
        try await withSandbox { root, model, workspace in
            let trip = try XCTUnwrap(workspace.createEvent(name: "Trip", date: day("2026-08-21"), policy: nil))
            let fullCard = try XCTUnwrap(workspace.createEvent(name: "Full Card", date: day("2026-08-22"), policy: nil, parentEventID: trip))
            let nas = workspace.locations.nasRoot
            let tripCamera = nas.appendingPathComponent("2026/2026-08-21 Trip/Originals/Sony A7V")
            try write(tripCamera.appendingPathComponent("Photos/DSC00001.ARW"), "trip frame")
            model.updateConfiguration {
                $0.photoEventAssignments.append(PhotoEventAssignment(
                    sourceRootPath: workspace.locations.originalsRoot(
                        for: $0.savedEvents.first { $0.id == trip }!, deviceID: "sony-a7v", policy: .buffer
                    ).path,
                    relativePath: "Photos/DSC00001.ARW",
                    fileSize: 10,
                    modifiedAt: Date(timeIntervalSince1970: 1_780_000_000),
                    eventID: trip,
                    deviceID: "sony-a7v"
                ))
            }
            let card = nas.appendingPathComponent("2026/2026-08-21 Trip/2026-08-22 Full Card/Originals/Sony A7V")
            try write(card.appendingPathComponent("DSC00001.ARW"), "card frame 1")
            try write(card.appendingPathComponent("DSC00002.ARW"), "card frame 2")
            try write(card.appendingPathComponent("._DSC00002.ARW"), "apple double")
            let tripBefore = model.configuration.photoEventAssignments
            let diskBefore = try tree(root.appendingPathComponent("Library"))
            let backups = root.appendingPathComponent("Backups", isDirectory: true)

            workspace.discoverNASEvents()
            try await waitUntil { !workspace.discoveredNASEvents.isEmpty }
            XCTAssertEqual(workspace.discoveredNASEvents.map(\.displayName), ["Trip / Full Card"])
            XCTAssertEqual(workspace.discoveredNASEvents.first?.fileCount, 2)
            XCTAssertEqual(workspace.discoveredNASEvents.first?.matchingEventID, fullCard)

            // The live app always has its photo list; this sandbox writes it shortly.
            try await waitUntil { FileManager.default.fileExists(atPath: model.configuration.catalogDatabasePath) }
            workspace.adoptDiscoveredNASEvents()
            try await waitUntil { !model.isBusy && model.configuration.photoEventAssignments.count > tripBefore.count }
            try await waitUntil { !model.isBusy }

            let added = model.configuration.photoEventAssignments.filter { $0.eventID == fullCard }
            XCTAssertEqual(added.map(\.relativePath).sorted(), ["DSC00001.ARW", "DSC00002.ARW"])
            XCTAssertEqual(model.configuration.photoEventAssignments.filter { $0.eventID == trip }, tripBefore)
            XCTAssertEqual(model.configuration.savedEvents.count, 2)
            let manifests = CatalogBackupService(
                catalogURL: URL(fileURLWithPath: model.configuration.catalogDatabasePath),
                configurationURL: nil,
                localFolder: backups,
                remoteFolder: nil
            ).manifests(in: backups)
            XCTAssertEqual(manifests.count, 1, "a photo-list backup is taken before the write")
            XCTAssertEqual(try tree(root.appendingPathComponent("Library")), diskBefore)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.locations.bufferRoot.path))

            await workspace.refreshEvent(fullCard)
            let stacks = try XCTUnwrap(workspace.eventStacks[fullCard])
            XCTAssertEqual(stacks.flatMap(\.files).map(\.path).sorted(), [
                card.appendingPathComponent("DSC00001.ARW").path,
                card.appendingPathComponent("DSC00002.ARW").path,
            ])
            XCTAssertEqual(workspace.presence[fullCard]?.onArchive, 2)
            XCTAssertEqual(workspace.presence[fullCard]?.removableFromDrive, 0)
            for stack in stacks {
                XCTAssertEqual(workspace.badge(for: stack, in: fullCard), .nasOnly)
            }
            // The list is read again after the write and finds nothing left.
            await workspace.nasDiscoveryTask?.value
            XCTAssertTrue(workspace.discoveredNASEvents.isEmpty)
        }
    }

    // MARK: - Sandbox

    private func withSandbox(_ body: (URL, DashboardModel, EventsWorkspace) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitNASAdopt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resolved = root.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: resolved) }
        let configuration = AppConfiguration(
            demoRootPath: resolved.appendingPathComponent("Safety Test").path,
            importSourcePath: resolved.appendingPathComponent("Card").path,
            archivePath: resolved.appendingPathComponent("Library/Originals").path,
            bufferPath: resolved.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: resolved.appendingPathComponent("Library").path,
            catalogDatabasePath: resolved.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: resolved.appendingPathComponent("activity.jsonl").path,
            selectedDeviceID: "sony-a7v"
        )
        let model = DashboardModel(
            jobs: [],
            configuration: configuration,
            configurationStore: ConfigurationStore(url: resolved.appendingPathComponent("config.json"))
        )
        let workspace = EventsWorkspace(model: model, supportFolder: resolved.appendingPathComponent("Support", isDirectory: true))
        try await body(resolved, model, workspace)
    }

    private func day(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }

    private func write(_ url: URL, _ string: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(string.utf8).write(to: url)
    }

    private func tree(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            result[url.path] = try Data(contentsOf: url)
        }
        return result
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the workspace")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
