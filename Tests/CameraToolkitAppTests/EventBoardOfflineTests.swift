import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

/// The event board when its drives are unplugged. Every `/Volumes/<name>`
/// here is a random name that is never mounted — no real volume is read or
/// written; a "mount" is simulated through the workspace's mount-table seam.
@MainActor
final class EventBoardOfflineTests: XCTestCase {
    /// The reported hang: the Buffer and the NAS are both unplugged. Before
    /// the fix pass one and the build skipped the offline drive, the empty
    /// sweep equalled the empty build, and `eventStacks` was never assigned
    /// — the board spun on "Loading…" forever. Now the refresh reaches a
    /// terminal offline state well under a second, naming both drives, and
    /// never stats a place root on an unmounted volume.
    func testAllRootsOfflineReachesTerminalOfflineStateQuickly() async throws {
        let buffer = "/Volumes/CTOfflineBuffer-\(UUID().uuidString.prefix(8))"
        let nas = "/Volumes/CTOfflineNAS-\(UUID().uuidString.prefix(8))"
        try await withSandbox(bufferVolume: buffer, nasVolume: nas) { _, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Big Trip", date: day("2026-08-26"), policy: .buffer))
            model.updateConfiguration { configuration in
                configuration.photoEventAssignments += (0..<5_000).map { index in
                    assignment(index, eventID: eventID, source: "/Volumes/CTOfflineCard-\(index % 3)/DCIM")
                }
            }
            let probed = PathLog()
            workspace.placeResponseProbe = { url in probed.note(url.path); return true }

            let started = Date()
            await workspace.refreshEvent(eventID)
            let elapsed = Date().timeIntervalSince(started)

            XCTAssertLessThan(elapsed, 1.0, "an unplugged event must fail fast, took \(elapsed)s")
            XCTAssertEqual(workspace.eventStacks[eventID], [])
            let report = try XCTUnwrap(workspace.eventReachability[eventID])
            XCTAssertTrue(report.isOffline)
            XCTAssertFalse(report.anyReachable)
            let names = report.offlinePlaces.map(\.displayName)
            XCTAssertTrue(names.contains { $0.hasPrefix("CTOfflineBuffer-") && $0.hasSuffix("(Buffer)") }, "\(names)")
            XCTAssertTrue(names.contains { $0.hasPrefix("CTOfflineNAS-") && $0.hasSuffix("(NAS)") }, "\(names)")
            XCTAssertTrue(report.remedySentence.contains("Plug in the Buffer"), report.remedySentence)
            XCTAssertTrue(report.remedySentence.contains("connect to the NAS"), report.remedySentence)
            // Nothing on an unmounted volume was touched to find that out.
            XCTAssertTrue(probed.paths.allSatisfy { !$0.hasPrefix("/Volumes/") }, "\(probed.paths)")
            // No spinner state left behind.
            XCTAssertNil(workspace.eventBuildRemainders[eventID])
            XCTAssertNil(workspace.eventDateReadRemainders[eventID])
            XCTAssertFalse(workspace.isCheckingFiles(for: eventID))
            // The storage strip still gets its truthful (offline) answer.
            let summary = try XCTUnwrap(workspace.presence[eventID])
            XCTAssertEqual(summary.total, 5_000)
            XCTAssertTrue(summary.driveOffline)
            XCTAssertTrue(summary.archiveOffline)
        }
    }

    /// The offline state lands before the four-place sweep finishes: even
    /// with the sweep's per-file probe parked, the board is already
    /// terminal.
    func testOfflineStatePublishesBeforeTheSweepAnswers() async throws {
        let buffer = "/Volumes/CTOfflineBuffer-\(UUID().uuidString.prefix(8))"
        let nas = "/Volumes/CTOfflineNAS-\(UUID().uuidString.prefix(8))"
        try await withSandbox(bufferVolume: buffer, nasVolume: nas) { _, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Trip", date: day("2026-08-26"), policy: .buffer))
            model.updateConfiguration { configuration in
                configuration.photoEventAssignments += (0..<10).map { assignment($0, eventID: eventID, source: "/Volumes/CTOfflineCard/DCIM") }
            }
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            workspace.presenceProbe = { url, size, mounted in
                _ = gate.wait(timeout: .now() + 30)
                return EventPresenceScanner.state(url, size: size, mounted: mounted)
            }
            let refresh = Task { await workspace.refreshEvent(eventID) }
            try await waitUntil(timeout: 1) { workspace.eventReachability[eventID]?.isOffline == true }
            XCTAssertEqual(workspace.eventStacks[eventID], [])
            for _ in 0..<50 { gate.signal() }
            await refresh.value
            XCTAssertEqual(workspace.eventStacks[eventID], [])
        }
    }

    /// Partly mounted: the Buffer is here, the NAS is not. The board loads
    /// every Buffer file, the NAS is named as offline, and nothing waits on
    /// it.
    func testMixedOnlineAndOfflineLoadsReachableFilesAndNamesTheRest() async throws {
        let nas = "/Volumes/CTOfflineNAS-\(UUID().uuidString.prefix(8))"
        try await withSandbox(bufferVolume: nil, nasVolume: nas) { _, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Beach", date: day("2026-08-26"), policy: .buffer))
            let event = try XCTUnwrap(workspace.event(eventID))
            let cardCopy = workspace.locations.cardCopyRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            var assignments: [PhotoEventAssignment] = []
            for index in 0..<20 {
                let name = String(format: "DSC%05d.ARW", index)
                try write(cardCopy.appendingPathComponent(name), bytes: 64)
                assignments.append(assignment(index, eventID: eventID, source: "/Volumes/CTOfflineCard/DCIM", size: 64))
            }
            model.updateConfiguration { $0.photoEventAssignments += assignments }

            let started = Date()
            await workspace.refreshEvent(eventID)
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)

            XCTAssertEqual(workspace.eventStacks[eventID]?.flatMap(\.files).count, 20)
            let report = try XCTUnwrap(workspace.eventReachability[eventID])
            XCTAssertFalse(report.isOffline)
            XCTAssertTrue(report.anyReachable)
            XCTAssertTrue(report.offlinePlaces.contains { $0.role == .nas }, "\(report.offlinePlaces)")
            XCTAssertFalse(report.offlinePlaces.contains { $0.role == .buffer })
            let summary = try XCTUnwrap(workspace.presence[eventID])
            XCTAssertEqual(summary.onDrive, 20)
            XCTAssertTrue(summary.archiveOffline)
            XCTAssertNil(workspace.eventBuildRemainders[eventID])
        }
    }

    /// A NAS that is mounted but hung: its root stat never returns. The
    /// bounded check gives up after the timeout, the NAS is reported as not
    /// responding, and the sweep treats it as unmounted — no per-file stat
    /// queues behind the dead share, and the Buffer board still loads.
    func testHungNASIsBoundedByTimeoutAndNeverStatted() async throws {
        let nas = "/Volumes/CTHungNAS-\(UUID().uuidString.prefix(8))"
        try await withSandbox(bufferVolume: nil, nasVolume: nas) { _, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Beach", date: day("2026-08-26"), policy: .buffer))
            let event = try XCTUnwrap(workspace.event(eventID))
            let cardCopy = workspace.locations.cardCopyRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            var assignments: [PhotoEventAssignment] = []
            for index in 0..<5 {
                try write(cardCopy.appendingPathComponent(String(format: "DSC%05d.ARW", index)), bytes: 64)
                assignments.append(assignment(index, eventID: eventID, source: cardCopy.path, size: 64))
            }
            model.updateConfiguration { $0.photoEventAssignments += assignments }

            let real = VolumeInfo.mountedVolumePaths()
            workspace.mountedVolumesProvider = { real.union([nas]) }
            workspace.placeResponseTimeout = 0.2
            let hang = DispatchSemaphore(value: 0)
            defer { for _ in 0..<4 { hang.signal() } }
            workspace.placeResponseProbe = { url in
                if url.path.hasPrefix(nas) { _ = hang.wait(timeout: .now() + 30) }
                return FileManager.default.fileExists(atPath: url.path)
            }
            let archiveStats = PathLog()
            workspace.presenceProbe = { url, size, mounted in
                if let url, url.path.hasPrefix(nas) { archiveStats.note(url.path) }
                return EventPresenceScanner.state(url, size: size, mounted: mounted)
            }

            let started = Date()
            await workspace.refreshEvent(eventID)
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertLessThan(elapsed, 3, "a hung share must be bounded by the timeout, took \(elapsed)s")

            let report = try XCTUnwrap(workspace.eventReachability[eventID])
            XCTAssertEqual(report.unresponsiveVolumes, [nas])
            XCTAssertTrue(report.offlinePlaces.contains { $0.role == .nas })
            XCTAssertEqual(workspace.eventStacks[eventID]?.flatMap(\.files).count, 5)
            let summary = try XCTUnwrap(workspace.presence[eventID])
            XCTAssertEqual(summary.onDrive, 5)
            XCTAssertTrue(summary.assets.allSatisfy { $0.archive == .unavailable })
            // The sweep's probe was asked, but the mount set it received
            // excluded the hung volume, so `state` answered from the table.
            XCTAssertEqual(archiveStats.paths.count, 5)
        }
    }

    /// The direct regression: the Buffer is unplugged but the NAS answers
    /// and holds nothing. The report is not "all offline" (the NAS is
    /// reachable), so it is the sweep that must leave the board a terminal
    /// empty grid — it used to leave `eventStacks` nil forever.
    func testUnpluggedBufferWithEmptyReachableNASStillEndsLoading() async throws {
        let buffer = "/Volumes/CTOfflineBuffer-\(UUID().uuidString.prefix(8))"
        try await withSandbox(bufferVolume: buffer, nasVolume: nil) { _, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Trip", date: day("2026-08-26"), policy: .buffer))
            model.updateConfiguration { configuration in
                configuration.photoEventAssignments += (0..<50).map { assignment($0, eventID: eventID, source: "/Volumes/CTOfflineCard/DCIM") }
            }
            await workspace.refreshEvent(eventID)
            XCTAssertEqual(workspace.eventStacks[eventID], [])
            let report = try XCTUnwrap(workspace.eventReachability[eventID])
            XCTAssertTrue(report.anyReachable)
            XCTAssertTrue(report.offlinePlaces.contains { $0.role == .buffer })
            XCTAssertNil(workspace.eventBuildRemainders[eventID])
            XCTAssertNil(workspace.eventDateReadRemainders[eventID])
            XCTAssertFalse(workspace.isCheckingFiles(for: eventID))
        }
    }

    /// Plugging the Buffer back in reloads the board on its own: the mount
    /// notification's connectivity refresh re-runs the offline event, which
    /// now paints its files and clears the offline report.
    func testVolumeAppearingReloadsOfflineBoard() async throws {
        let volume = "/Volumes/CTAppearingBuffer-\(UUID().uuidString.prefix(8))"
        try await withSandbox(bufferVolume: volume, nasVolume: nil) { _, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Trip", date: day("2026-08-26"), policy: .buffer))
            model.updateConfiguration { configuration in
                configuration.photoEventAssignments += (0..<12).map { assignment($0, eventID: eventID, source: "/Volumes/CTOfflineCard/DCIM") }
            }
            let mount = MountTable(VolumeInfo.mountedVolumePaths())
            workspace.mountedVolumesProvider = { mount.paths }
            workspace.placeResponseProbe = { url in
                url.path.hasPrefix(volume) || FileManager.default.fileExists(atPath: url.path)
            }
            // Stand-in for the drive's files: present once the volume is
            // "mounted" — no real path under /Volumes is ever read.
            workspace.presenceProbe = { url, size, mounted in
                if let url, url.path.hasPrefix(volume) {
                    return mounted.contains(volume) ? .present : .unavailable
                }
                return EventPresenceScanner.state(url, size: size, mounted: mounted)
            }
            workspace.captureDateReadProbe = { _ in nil }

            await workspace.refreshEvent(eventID)
            XCTAssertEqual(workspace.eventStacks[eventID], [])
            XCTAssertEqual(workspace.eventReachability[eventID]?.offlinePlaces.first?.role, .buffer)

            mount.insert(volume)
            workspace.refreshConnectivity(mountedVolumes: [URL(fileURLWithPath: volume, isDirectory: true)])
            try await waitUntil(timeout: 10) {
                workspace.eventStacks[eventID]?.flatMap(\.files).count == 12
                    && !workspace.isCheckingFiles(for: eventID)
            }
            XCTAssertFalse(workspace.eventReachability[eventID]?.isOffline ?? false)
            XCTAssertFalse(workspace.eventReachability[eventID]?.offlinePlaces.contains { $0.role == .buffer } ?? false)
            XCTAssertEqual(workspace.presence[eventID]?.onDrive, 12)
        }
    }

    /// Cancelling the board's task, or superseding a refresh with a second
    /// one, still leaves a terminal state — no path keeps the spinner up.
    func testLoadingIsClearedOnCancelAndSupersededRefresh() async throws {
        let buffer = "/Volumes/CTOfflineBuffer-\(UUID().uuidString.prefix(8))"
        try await withSandbox(bufferVolume: buffer, nasVolume: nil) { _, model, workspace in
            let eventID = try XCTUnwrap(workspace.createEvent(name: "Trip", date: day("2026-08-26"), policy: .buffer))
            model.updateConfiguration { configuration in
                configuration.photoEventAssignments += (0..<200).map { assignment($0, eventID: eventID, source: "/Volumes/CTOfflineCard/DCIM") }
            }

            let cancelled = Task { await workspace.refreshEvent(eventID) }
            cancelled.cancel()
            await cancelled.value
            try await waitUntil(timeout: 5) { !workspace.isCheckingFiles(for: eventID) }
            XCTAssertEqual(workspace.eventStacks[eventID], [])

            workspace.eventStacks[eventID] = nil
            let first = Task { await workspace.refreshEvent(eventID) }
            let second = Task { await workspace.refreshEvent(eventID) }
            await first.value
            await second.value
            XCTAssertEqual(workspace.eventStacks[eventID], [])
            XCTAssertNil(workspace.eventBuildRemainders[eventID])
            XCTAssertNil(workspace.eventDateReadRemainders[eventID])
            XCTAssertFalse(workspace.isCheckingFiles(for: eventID))
        }
    }

    // MARK: - Harness

    /// A sandbox whose Buffer and/or NAS sit on a named `/Volumes/<name>`
    /// that is never mounted; nil keeps that place in the temp folder.
    private func withSandbox(
        bufferVolume: String?,
        nasVolume: String?,
        _ body: (URL, DashboardModel, EventsWorkspace) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitOffline-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resolvedRoot = root.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: resolvedRoot) }
        let library = nasVolume.map { "\($0)/Library" } ?? resolvedRoot.appendingPathComponent("Library").path
        if nasVolume == nil {
            try FileManager.default.createDirectory(atPath: library, withIntermediateDirectories: true)
        }
        let configuration = AppConfiguration(
            demoRootPath: resolvedRoot.appendingPathComponent("Safety Test").path,
            importSourcePath: resolvedRoot.appendingPathComponent("Card").path,
            archivePath: "\(library)/Originals",
            bufferPath: bufferVolume.map { "\($0)/Camera Buffer" } ?? resolvedRoot.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: library,
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
            supportFolder: resolvedRoot.appendingPathComponent("Support", isDirectory: true)
        )
        try await body(resolvedRoot, model, workspace)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the board")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func day(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }

    private func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }
}

private func assignment(_ index: Int, eventID: UUID, source: String, size: Int64 = 4_096) -> PhotoEventAssignment {
    PhotoEventAssignment(
        sourceRootPath: source,
        relativePath: String(format: "DSC%05d.ARW", index),
        fileSize: size,
        modifiedAt: Date(timeIntervalSince1970: 1_752_000_000 + Double(index)),
        eventID: eventID,
        deviceID: "sony-a7v"
    )
}

private final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    var paths: [String] { lock.withLock { _paths } }
    func note(_ path: String) { lock.withLock { _paths.append(path) } }
}

private final class MountTable: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: Set<String>
    init(_ paths: Set<String>) { _paths = paths }
    var paths: Set<String> { lock.withLock { _paths } }
    func insert(_ path: String) { lock.withLock { _ = _paths.insert(path) } }
}
