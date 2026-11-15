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

    func testAFileGoneFromTheCardIsNotWaitingAndTheNASIsNotBlamed() async throws {
        try await withSandbox(createNAS: true) { root, model, workspace in
            let (card, events) = try sortCard(root: root, model: model, workspace: workspace)
            try FileManager.default.removeItem(at: card.appendingPathComponent("DSC00001.ARW"))
            var plan = EventsWorkspace.buildApplyPlan(
                events: events, configuration: model.configuration, locations: workspace.locations,
                onlyUnder: card.path, title: "Apply", unsortedRoots: [card]
            )
            XCTAssertEqual(plan.nasCopyCount, 2)
            XCTAssertEqual(plan.notPlannableCount, 1)
            XCTAssertEqual(plan.waitingForDriveCount, 0)
            for name in ["DSC00002.ARW", "DSC00003.ARW"] {
                try FileManager.default.removeItem(at: card.appendingPathComponent(name))
            }
            plan = EventsWorkspace.buildApplyPlan(
                events: events, configuration: model.configuration, locations: workspace.locations,
                onlyUnder: nil, title: "Apply", unsortedRoots: [card]
            )
            XCTAssertTrue(plan.isEmpty)
            let message = ApplyPlanOverview.emptyPlanMessage(plan)
            XCTAssertFalse(message.contains("NAS isn"), message)
            XCTAssertFalse(message.contains("neither is the NAS"), message)
            XCTAssertTrue(message.contains("gone from the source"), message)
        }
    }

    func testASourceInsideTheNASIsNotCopiedOntoTheNAS() async throws {
        try await withSandbox(createNAS: true) { root, model, workspace in
            let inside = workspace.locations.nasRoot.appendingPathComponent("Unsorted Phone", isDirectory: true)
            let (card, events) = try sortCard(root: root, model: model, workspace: workspace, card: inside)
            let plan = EventsWorkspace.buildApplyPlan(
                events: events, configuration: model.configuration, locations: workspace.locations,
                onlyUnder: card.path, title: "Apply", unsortedRoots: [card]
            )
            XCTAssertEqual(plan.nasCopyCount, 0)
            XCTAssertEqual(plan.notPlannableCount, 3)
        }
    }

    // MARK: - Clear from Card: NAS-only files need the owner's choice

    func testNASOnlyFilesAreLeftOutOfClearFromCardUnlessChosen() {
        let request = CardClearRequest(
            locationID: UUID(), locationName: "Card", itemIDs: ["drive"], fileCount: 2, byteCount: 200,
            events: [], waitingForNASFiles: 0, driveName: "Buffer", nasReachable: true,
            nasOnlyItemIDs: ["nas-a", "nas-b"], nasOnlyFiles: 3, nasOnlyBytes: 300
        )
        let off = EventsWorkspace.cardClearChoice(request, includeNASOnly: false)
        XCTAssertEqual(off.itemIDs, ["drive"])
        XCTAssertEqual(off.nasOnlyItemIDs, [])
        XCTAssertEqual(off.fileCount, 2)
        let on = EventsWorkspace.cardClearChoice(request, includeNASOnly: true)
        XCTAssertEqual(on.itemIDs, ["drive"])
        XCTAssertEqual(on.nasOnlyItemIDs, ["nas-a", "nas-b"])
        XCTAssertEqual(on.fileCount, 5)
        XCTAssertEqual(on.byteCount, 500)
        func item(_ id: String, nasOnly: Bool) -> CardClearItem {
            CardClearItem(id: id, eventID: UUID(), sourceRoot: "/c", driveRoot: "/d", files: [CardClearFile(
                sourcePath: "/c/\(id)", relativePath: id, byteCount: 1, modifiedAt: Date(),
                drivePath: "/d/\(id)", nasPath: "/n/\(id)", verifiedSHA256: "00", nasOnly: nasOnly
            )])
        }
        let items = [item("drive", nasOnly: false), item("nas-a", nasOnly: true), item("nas-b", nasOnly: true)]
        XCTAssertEqual(CardClearRequest.jobItems(items, request: off).items.map(\.id), ["drive"])
        XCTAssertEqual(CardClearRequest.jobItems(items, request: on).items.map(\.id), ["drive", "nas-a", "nas-b"])
        XCTAssertTrue(CardClearWording.nasOnlyToggle(request).hasPrefix("Also clear 3 files"))
        XCTAssertTrue(CardClearWording.nasOnlyToggle(request).contains("whose only other copy is on the NAS"))
    }

    /// Confirmed with a drive copy and the checkbox off; by the time the job
    /// plans again the drive copy is gone (deleted, or the drive unplugged)
    /// and the same item is NAS-only. The job leaves it on the card. Only
    /// an item opted in as NAS-only in the sheet is cleared on the NAS copy.
    func testAnItemThatLostItsDriveCopySinceTheSheetStaysOnTheCard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitDriveGone-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let card = root.appendingPathComponent("Card/DCIM/100MSDCF", isDirectory: true)
        let nas = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        var configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Safety Test").path,
            importSourcePath: card.path,
            archivePath: nas.appendingPathComponent("Originals").path,
            bufferPath: root.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: nas.path,
            catalogDatabasePath: root.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path,
            selectedDeviceID: "sony-a7v"
        )
        let beach = SavedCameraEvent(name: "Beach Day", eventDate: day("2026-08-26"))
        configuration.savedEvents = [beach]
        var locations = EventStorageLocations(configuration: configuration)
        var inputs: [CardClearInput] = []
        var driveCopies: [URL] = []
        for name in ["DSC00001.ARW", "DSC00002.ARW"] {
            let source = card.appendingPathComponent(name)
            try write(source, String(repeating: name, count: 100))
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let row = PhotoEventAssignment(
                sourceRootPath: card.path, relativePath: name,
                fileSize: (attributes[.size] as! NSNumber).int64Value,
                modifiedAt: attributes[.modificationDate] as! Date,
                eventID: beach.id, deviceID: "sony-a7v"
            )
            configuration.photoEventAssignments.append(row)
            // Apply copied it to the drive (time kept), Sync verified it.
            let copy = try XCTUnwrap(locations.driveURL(for: row, event: beach, policy: .buffer))
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: copy)
            driveCopies.append(copy)
            inputs.append(CardClearInput(id: EventStorageLocations.pathKey(source.path), entries: [.init(path: source.path, assignment: row)]))
        }
        let catalog = URL(fileURLWithPath: configuration.catalogDatabasePath)
        let synced = try NASSyncService(store: try NASSyncStore(catalogURL: catalog), isCancelled: { false })
            .sync(NASSyncPlanner.plan(events: [beach], locations: locations), nasRoot: nas)
        XCTAssertEqual(synced.copied.count, 2)
        func plan() -> CardClearPlan {
            CardClearPlanner.plan(
                inputs: inputs, sourceRoot: card.path, events: [beach.id: beach], locations: locations,
                catalogURL: catalog, sameVolume: { _, _, _ in false }
            )
        }

        // The sheet: both items have a drive copy; the checkbox stays off.
        let sheet = plan()
        XCTAssertEqual(sheet.clearableFiles, 2)
        XCTAssertEqual(sheet.nasOnlyFiles, 0)
        let request = EventsWorkspace.cardClearChoice(CardClearRequest(
            locationID: UUID(), locationName: "Card", itemIDs: Set(sheet.clearable.map(\.id)), fileCount: 2, byteCount: 0,
            events: [], waitingForNASFiles: 0, driveName: "Buffer", nasReachable: true
        ), includeNASOnly: false)

        // The drive copies are removed before the job runs.
        let parked = root.appendingPathComponent("Parked", isDirectory: true)
        try FileManager.default.createDirectory(at: parked, withIntermediateDirectories: true)
        for copy in driveCopies {
            try FileManager.default.moveItem(at: copy, to: parked.appendingPathComponent(copy.lastPathComponent))
        }
        var later = plan()
        XCTAssertEqual(later.nasOnlyFiles, 2, "the same items are NAS-only now")
        var chosen = CardClearRequest.jobItems(later.clearable, request: request)
        XCTAssertTrue(chosen.items.isEmpty)
        XCTAssertEqual(chosen.driveCopyGone.count, 2)
        let outcome = CardClearOutcome(report: CardClearReport(), noLongerEligible: 0, driveCopyGoneFiles: 2)
        XCTAssertTrue(CardClearWording.summary(outcome, locationName: "Card").contains("drive copy is gone since you confirmed"))
        for copy in driveCopies {
            try FileManager.default.moveItem(at: parked.appendingPathComponent(copy.lastPathComponent), to: copy)
        }

        // The drive unplugged before the job runs: the same.
        configuration.bufferPath = "/Volumes/CT-Offline-\(UUID().uuidString)/Camera Buffer"
        locations = EventStorageLocations(configuration: configuration)
        later = plan()
        XCTAssertEqual(later.nasOnlyFiles, 2)
        chosen = CardClearRequest.jobItems(later.clearable, request: request)
        XCTAssertTrue(chosen.items.isEmpty)
        for input in inputs { XCTAssertTrue(FileManager.default.fileExists(atPath: input.entries[0].path)) }

        // Opted in as NAS-only in the sheet, and still NAS-only: cleared.
        var optedIn = request
        optedIn.nasOnlyItemIDs = Set(later.clearable.map(\.id))
        chosen = CardClearRequest.jobItems(later.clearable, request: optedIn)
        XCTAssertEqual(chosen.items.count, 2)
        let nasBefore = try tree(nas)
        let report = try CardClearService().clear(items: chosen.items, nasReachable: true, confirmation: FreeUpService.confirmationToken)
        XCTAssertEqual(report.cleared.count, 2, "\(report.skipped)")
        XCTAssertEqual(try tree(nas), nasBefore)
    }

    func testCopiesTheNASCannotCheckAreNeverCalledSafe() {
        var plan = CardClearPlan()
        plan.nasUnchecked = ["a": UUID(), "b": UUID(), "c": UUID()]
        plan.nasUncheckedBecauseNASIsAway = true
        var summary = CardClearSummary(plan)
        var line = CardClearWording.bannerLine(summary)
        XCTAssertEqual(line, "3 were copied to the NAS earlier, not checked now (NAS not connected)")
        XCTAssertFalse(line.contains("safe"))
        XCTAssertFalse(summary.offersClear)
        // The NAS connected but not listed by the background refresh: the
        // click checks it, nothing is called safe before that.
        plan.nasUncheckedBecauseNASIsAway = false
        summary = CardClearSummary(plan)
        line = CardClearWording.bannerLine(summary)
        XCTAssertTrue(line.hasPrefix("3 were copied to the NAS earlier — not checked yet"), line)
        XCTAssertFalse(line.contains("safe"))
        XCTAssertTrue(summary.offersClear)
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
    private func sortCard(root: URL, model: DashboardModel, workspace: EventsWorkspace, card cardFolder: URL? = nil) throws -> (URL, [SavedCameraEvent]) {
        let card = cardFolder ?? root.appendingPathComponent("Card/DCIM/100MSDCF", isDirectory: true)
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
