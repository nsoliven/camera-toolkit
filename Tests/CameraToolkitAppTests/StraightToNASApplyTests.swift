import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

/// Apply with the event's drive unplugged: the plan routes sorted card files
/// straight to the NAS (or says plainly that the drive is missing), the job
/// runs through Jobs like a sync, and when the drive comes back nothing is
/// copied back or treated as missing. Also: Add to Events always ends in a
/// visible outcome.
@MainActor
final class StraightToNASApplyTests: XCTestCase {
    func testApplySendsCardFilesStraightToTheNASAndNeverCopiesThemBack() async throws {
        try await withSandbox(createNAS: true) { root, model, workspace in
            let (card, events) = try sortCard(root: root, model: model, workspace: workspace)
            let cardBefore = try tree(card)

            let plan = EventsWorkspace.buildApplyPlan(
                events: events, configuration: model.configuration, locations: workspace.locations,
                onlyUnder: card.path, title: "Apply sorting from Card", unsortedRoots: [card]
            )
            XCTAssertEqual(plan.nasCopyCount, 3)
            XCTAssertEqual(plan.moveCount + plan.copyCount, 0)
            XCTAssertEqual(plan.unavailableCount, 0)
            XCTAssertEqual(plan.waitingForDriveCount, 0)
            let nasRoot = workspace.locations.nasRoot.path
            for group in plan.groups {
                XCTAssertTrue(group.destinationFolder.hasPrefix(nasRoot + "/"), group.destinationFolder)
                XCTAssertTrue(group.driveIsOffline)
            }
            // The private event goes to the NAS too — as Sync sends it.
            XCTAssertTrue(plan.groups.contains { $0.isPrivate && $0.nasCopyCount == 1 })

            let overview = ApplyPlanOverview(plan: plan)
            XCTAssertEqual(overview.nasCount, 3)
            XCTAssertTrue(overview.sentence.contains("isn’t connected"), overview.sentence)
            XCTAssertTrue(overview.sentence.contains("straight to the NAS, checked file by file"), overview.sentence)
            XCTAssertEqual(overview.primaryActionTitle, "Copy 3 Files to the NAS")
            XCTAssertTrue(overview.routes.allSatisfy { $0.methods == [.nasCopy] })
            XCTAssertTrue(overview.safetyFacts.contains { $0.text.contains("SHA-256") })
            XCTAssertTrue(ApplyRouteDiagram.routes(for: plan.groups[0]).allSatisfy { $0.destinationLabel.hasPrefix("NAS") })

            var immichFollowUps: [[NASRename]] = []
            workspace.nasChangeFollowObserver = { immichFollowUps.append($0) }
            workspace.performApply(plan)
            try await waitUntil { model.jobs.contains { $0.action == .syncBuffer && $0.state == .done } }
            try await waitUntil { !model.isBusy }
            let job = try XCTUnwrap(model.jobs.first { $0.action == .syncBuffer })
            XCTAssertEqual(job.state, .done, job.note)
            XCTAssertTrue(job.note.contains("3 copied and verified"), job.note)
            // The same post-copy hook as Sync to NAS, once, with no renames.
            XCTAssertEqual(immichFollowUps.count, 1)
            XCTAssertEqual(immichFollowUps.first, [])

            // Each file is where Sync to NAS would have put its drive copy;
            // the card is untouched; the catalog rows still name the card.
            for row in model.configuration.photoEventAssignments {
                let event = try XCTUnwrap(workspace.event(row.eventID))
                let drive = try XCTUnwrap(workspace.locations.driveURL(for: row, event: event, policy: workspace.locations.resolvedPolicy(for: event)))
                let mirror = try XCTUnwrap(workspace.locations.nasMirrorURL(forDrivePath: drive.path))
                XCTAssertEqual(try Data(contentsOf: mirror), cardBefore[card.appendingPathComponent(row.relativePath).path].map { Data($0.prefix(Int(row.fileSize))) })
                XCTAssertEqual(row.sourceRootPath, card.path)
            }
            XCTAssertEqual(try tree(card), cardBefore)

            // Apply again: everything is already in its event on the NAS.
            let again = EventsWorkspace.buildApplyPlan(
                events: events, configuration: model.configuration, locations: workspace.locations,
                onlyUnder: card.path, title: "Apply", unsortedRoots: [card]
            )
            XCTAssertTrue(again.isEmpty)
            XCTAssertEqual(again.alreadyOnNASCount, 3)
            XCTAssertTrue(ApplyPlanOverview.emptyPlanMessage(again).contains("NAS folder"), ApplyPlanOverview.emptyPlanMessage(again))

            // The drive comes back: the files stay on the NAS, are not
            // copied back to it, and are not missing.
            let buffer = root.appendingPathComponent("Drive/Camera Buffer", isDirectory: true)
            try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
            model.updateConfiguration { $0.bufferPath = buffer.path }
            let back = EventsWorkspace.buildApplyPlan(
                events: events.compactMap { workspace.event($0.id) }, configuration: model.configuration, locations: workspace.locations,
                onlyUnder: card.path, title: "Apply", unsortedRoots: [card]
            )
            XCTAssertEqual(back.copyCount + back.moveCount + back.nasCopyCount, 0)
            XCTAssertEqual(back.alreadyOnNASCount, 3)
            XCTAssertEqual(back.waitingForDriveCount, 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: buffer.path), [])
            XCTAssertEqual(try tree(card), cardBefore)
        }
    }

    func testWithNeitherTheDriveNorTheNASTheMessageNamesTheMissingDrive() async throws {
        try await withSandbox(createNAS: false) { root, model, workspace in
            let (card, events) = try sortCard(root: root, model: model, workspace: workspace)
            let plan = EventsWorkspace.buildApplyPlan(
                events: events, configuration: model.configuration, locations: workspace.locations,
                onlyUnder: card.path, title: "Apply", unsortedRoots: [card], nasAvailable: false
            )
            XCTAssertTrue(plan.isEmpty)
            XCTAssertEqual(plan.waitingForDriveCount, 3)
            XCTAssertEqual(plan.unavailableCount, 0)
            let message = ApplyPlanOverview.emptyPlanMessage(plan)
            XCTAssertTrue(message.contains("isn’t connected, and neither is the NAS"), message)
            XCTAssertFalse(message.contains("disconnected drive"), message)
            XCTAssertTrue(ApplyRouteDiagram.eventSummaries(for: plan).allSatisfy { $0.footnote?.contains("wait for the") == true })

            // Through the button: the same words reach the status line.
            workspace.prepareApply(eventIDs: events.map(\.id), title: "Apply", onlyUnder: card.path)
            try await waitUntil { model.statusMessage.contains("neither is the NAS") }
            XCTAssertNil(workspace.pendingApplyPlan)
        }
    }

    func testAnOfflineSourceIsStillCalledThat() {
        var plan = OrganizeApplyPlan(title: "Apply", groups: [], pruneBoundaries: [])
        plan.groups = [OrganizeApplyPlan.EventGroup(
            event: SavedCameraEvent(name: "Beach Day", eventDate: Date()),
            moves: [], copies: [], alreadyThere: 0, unavailable: 2,
            destinationFolder: "/tmp/x", isPrivate: false, byteCount: 0
        )]
        XCTAssertTrue(ApplyPlanOverview.emptyPlanMessage(plan).contains("source drive that isn’t connected"))
    }

    // MARK: - Add to Events outcomes

    func testAddToEventsAlwaysEndsInAVisibleOutcome() async throws {
        try await withSandbox(createNAS: true) { root, model, workspace in
            // Nothing listed: a line, not silence.
            workspace.discoveredNASEvents = []
            workspace.adoptDiscoveredNASEvents()
            XCTAssertTrue(workspace.nasAdoptNote?.hasPrefix("Nothing was added") == true)
            XCTAssertTrue(model.statusMessage.hasPrefix("Nothing was added"))

            // A folder two saved events claim cannot be added: the job says
            // so, and the next listing reports it as left out instead of
            // offering it again.
            let first = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: day("2026-08-26"), policy: nil))
            model.updateConfiguration { configuration in
                var twin = configuration.savedEvents.first { $0.id == first }!
                twin.id = UUID()
                configuration.savedEvents.append(twin)
            }
            let camera = workspace.locations.nasRoot.appendingPathComponent("2026/2026-08-26 Beach Day/Originals/Sony A7V")
            try write(camera.appendingPathComponent("DSC00001.ARW"), "frame")
            workspace.discoverNASEvents()
            try await waitUntil { !workspace.discoveredNASEvents.isEmpty }
            try await waitUntil { FileManager.default.fileExists(atPath: model.configuration.catalogDatabasePath) }

            // Clicked while another job holds the gate: it waits in Jobs.
            let release = BlockerRelease()
            model.runBackgroundJob(
                action: .organize, runningNote: "Another job", logTitle: "Another job", logDetail: "",
                operation: { _ in
                    while !release.isSet { Thread.sleep(forTimeInterval: 0.01) }
                    return 0
                },
                completion: { _ in "Done." }
            )
            workspace.adoptDiscoveredNASEvents()
            let queued = try XCTUnwrap(model.jobs.first { $0.state == .queued })
            XCTAssertTrue(queued.note.contains("Add 1 NAS file"), queued.note)
            release.set()
            try await waitUntil { model.jobs.first(where: { $0.id == queued.id })?.state == .done }
            try await waitUntil { !model.isBusy }
            XCTAssertTrue(workspace.nasAdoptNote?.hasPrefix("Nothing was added") == true, workspace.nasAdoptNote ?? "")
            await workspace.nasDiscoveryTask?.value
            try await waitUntil { !workspace.nasDiscoveryProblems.isEmpty }
            XCTAssertTrue(workspace.discoveredNASEvents.isEmpty, "a folder that cannot be added is not offered again")
            let line = try XCTUnwrap(NASDiscoveryWording.leftOutLine(workspace.nasDiscoveryProblems))
            XCTAssertTrue(line.hasPrefix("Left out: Beach Day"), line)
            XCTAssertTrue(line.contains("2 events use this folder"), line)
        }
    }

    func testLeftOutWordingSaysWhatAndWhyPlainly() {
        let problem = NASDiscoveryProblem(
            path: "2026/2026-01-01 Beach Day/Originals/Osmo 360 (Alex)",
            reason: "the app names this camera’s folder “Osmo 360 -Alex”"
        )
        let line = NASDiscoveryWording.leftOutLine([problem]) ?? ""
        XCTAssertTrue(line.hasPrefix("Left out: Beach Day ▸ Osmo 360 (Alex) — the app would name this camera’s folder “Osmo 360 -Alex”"), line)
        XCTAssertNil(NASDiscoveryWording.leftOutLine([]))
        XCTAssertTrue(NASDiscoveryWording.leftOutLine([problem, problem])?.contains("2 folders or files were left out") == true)
        XCTAssertEqual(
            EventsWorkspace.driveAdoptionSummaryLine(createdEvents: 0, addedAssignments: 0),
            "Nothing was added: those drive folders are already events and their files are already listed. No files moved."
        )
    }

    // MARK: - Fixtures

    /// Three card files sorted into a shared and a private event.
    private func sortCard(root: URL, model: DashboardModel, workspace: EventsWorkspace) throws -> (URL, [SavedCameraEvent]) {
        let card = root.appendingPathComponent("Card/DCIM/100MSDCF", isDirectory: true)
        let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: day("2026-08-26"), policy: .buffer))
        let hotel = try XCTUnwrap(workspace.createEvent(name: "Hotel Night", date: day("2026-08-26"), policy: .archiveOnly))
        var rows: [PhotoEventAssignment] = []
        for (index, name) in ["DSC00001.ARW", "DSC00002.ARW", "DSC00003.ARW"].enumerated() {
            let url = card.appendingPathComponent(name)
            try write(url, String(repeating: "frame \(index) ", count: 200))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            rows.append(PhotoEventAssignment(
                sourceRootPath: card.path,
                relativePath: name,
                fileSize: (attributes[.size] as! NSNumber).int64Value,
                modifiedAt: attributes[.modificationDate] as! Date,
                eventID: index == 2 ? hotel : beach,
                deviceID: "sony-a7v"
            ))
        }
        model.updateConfiguration { $0.photoEventAssignments += rows }
        return (card, [try XCTUnwrap(workspace.event(beach)), try XCTUnwrap(workspace.event(hotel))])
    }

    /// The Buffer is a drive that is not mounted; the NAS is a folder.
    private func withSandbox(createNAS: Bool, _ body: (URL, DashboardModel, EventsWorkspace) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitStraightToNAS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resolved = root.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: resolved) }
        if createNAS {
            try FileManager.default.createDirectory(at: resolved.appendingPathComponent("Library"), withIntermediateDirectories: true)
        }
        let configuration = AppConfiguration(
            demoRootPath: resolved.appendingPathComponent("Safety Test").path,
            importSourcePath: resolved.appendingPathComponent("Card").path,
            archivePath: resolved.appendingPathComponent("Library/Originals").path,
            bufferPath: "/Volumes/CT-Offline-\(UUID().uuidString)/Camera Buffer",
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
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            var data = try Data(contentsOf: url)
            data.append(contentsOf: Array("\(modified?.timeIntervalSinceReferenceDate ?? 0)".utf8))
            result[url.standardizedFileURL.path] = data
        }
        return result
    }

    private func waitUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
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
