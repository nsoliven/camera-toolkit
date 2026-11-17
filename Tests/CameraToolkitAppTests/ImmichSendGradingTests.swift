@testable import CameraToolkitApp
import AppKit
import CameraToolkitCore
import SwiftUI
import XCTest

/// Send to Immich asks about grading: never when there is nothing to grade,
/// every time when log clips would reach Immich flat, and "Send as they
/// are" sends exactly what it always did.
@MainActor
final class ImmichSendGradingTests: XCTestCase {
    private let sidecar = """
    <NonRealTimeMeta><Group name="CameraUnitMetadataSet">
    <Item name="CaptureGammaEquation" value="s-log3-cine"/>
    <Item name="CaptureColorPrimaries" value="s-gamut3-cine"/>
    </Group></NonRealTimeMeta>
    """
    private let event = SavedCameraEvent(name: "Beach Day", eventDate: Date(timeIntervalSince1970: 1_780_000_000))

    private func withSandbox(_ body: (URL, DashboardModel, EventsWorkspace) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitSendGrading-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Safety Test").path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: root.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: root.appendingPathComponent("Library").path,
            catalogDatabasePath: root.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path,
            selectedDeviceID: "sony-a7v"
        )
        let model = DashboardModel(jobs: [], configuration: configuration, configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json")))
        let workspace = EventsWorkspace(model: model, supportFolder: root.appendingPathComponent("Support", isDirectory: true))
        workspace.grading = ClipGrading(workspace: workspace, library: LUTLibrary(folder: root.appendingPathComponent("LUTs")))
        try await body(root, model, workspace)
    }

    /// One clip in the event, on the drive or only on the NAS, with or
    /// without its S-Log3 sidecar.
    @discardableResult
    private func addClip(_ root: URL, _ model: DashboardModel, _ workspace: EventsWorkspace, onNAS: Bool = false, log: Bool = true) throws -> URL {
        let assignment = PhotoEventAssignment(
            sourceRootPath: root.appendingPathComponent("Card").path, relativePath: "C0001.MP4",
            fileSize: 64, modifiedAt: Date(timeIntervalSince1970: 1_780_000_100), eventID: event.id, deviceID: "sony-a7v"
        )
        model.updateConfiguration { configuration in
            configuration.savedEvents = [event]
            configuration.photoEventAssignments = [assignment]
        }
        let clip = try XCTUnwrap(onNAS
            ? workspace.locations.archiveURL(for: assignment, event: event)
            : workspace.locations.driveURL(for: assignment, event: event, policy: .buffer))
        try FileManager.default.createDirectory(at: clip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: clip)
        if log { try Data(sidecar.utf8).write(to: clip.deletingLastPathComponent().appendingPathComponent("C0001M01.XML")) }
        return clip
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    func testNoLogClipsMeansNoQuestion() async throws {
        try await withSandbox { root, model, workspace in
            try addClip(root, model, workspace, log: false)
            let grading = workspace.grading
            var sent: [Set<UUID>] = []
            grading.startImmichSend = { sent.append($0) }

            grading.beginImmichSend([event.id])
            try await waitUntil { !sent.isEmpty }

            XCTAssertEqual(sent, [[event.id]], "sent straight away")
            XCTAssertNil(grading.immichSendAsk, "nothing asked")
            XCTAssertTrue(model.queuedFileJobs.isEmpty)
        }
    }

    func testLogClipsAskEveryTimeAndSendAsTheyAreSendsUnchanged() async throws {
        try await withSandbox { root, model, workspace in
            try addClip(root, model, workspace)
            let grading = workspace.grading
            var sent: [Set<UUID>] = []
            grading.startImmichSend = { sent.append($0) }

            for round in 1...2 {
                grading.beginImmichSend([event.id])
                try await waitUntil { grading.immichSendAsk?.stage == .asking }
                let ask = try XCTUnwrap(grading.immichSendAsk, "round \(round) asks")
                XCTAssertEqual(ask.count, 1)
                XCTAssertEqual(ask.headline, "1 log clip in Beach Day has no Rec.709 copy. Immich will show it flat.")
                XCTAssertEqual(ask.options.map(\.id), [.grade], "Grade is the first render option")
                XCTAssertEqual(ask.onDriveCount, 1)
                XCTAssertTrue(sent.count == round - 1, "nothing is sent before the answer")

                grading.answerImmichSendAsk(.sendAsTheyAre)
                XCTAssertNil(grading.immichSendAsk)
                XCTAssertEqual(sent.count, round)
                XCTAssertTrue(model.queuedFileJobs.isEmpty, "nothing rendered")
                XCTAssertFalse(model.jobs.contains { $0.action == .gradeRender })
            }
            XCTAssertEqual(sent, [[event.id], [event.id]])
        }
    }

    func testRenderAndSendQueuesTheRenderOnTheNASAndStopsWithTheSend() async throws {
        try await withSandbox { root, model, workspace in
            let clip = try addClip(root, model, workspace, onNAS: true)
            XCTAssertTrue(NASDirectApply.isNASUsable(workspace.locations))
            let grading = workspace.grading
            var sent: [Set<UUID>] = []
            grading.startImmichSend = { sent.append($0) }

            grading.beginImmichSend([event.id])
            try await waitUntil { grading.immichSendAsk?.stage == .asking }
            let ask = try XCTUnwrap(grading.immichSendAsk)
            XCTAssertEqual(ask.onNASCount, 1, "the clip is only on the NAS")
            let request = try XCTUnwrap(ask.pending.first?.request)
            XCTAssertEqual(request.source, clip)
            XCTAssertEqual(request.outputFolder, GradedRenderNaming.outputFolder(editedRoot: workspace.locations.nasEditedRoot(for: event)))
            XCTAssertNil(request.stabilization)

            // Another job holds the gate, so the render waits in the queue.
            model.isBusy = true
            grading.answerImmichSendAsk(.renderAndSend)
            XCTAssertEqual(model.queuedFileJobs.map(\.action), [.gradeRender])
            XCTAssertEqual(workspace.immichSend?.phase, .rendering(count: 1, detail: nil))
            XCTAssertTrue(workspace.immichSend?.line.hasPrefix("Rendering 1 graded copy…") == true)
            try await waitUntil { workspace.immichSend?.phase == .rendering(count: 1, detail: "Waiting for the running job to finish…") }

            // Stopping the send takes the render off the queue.
            workspace.cancelImmichSend()
            try await waitUntil { model.queuedFileJobs.isEmpty }
            XCTAssertTrue(model.queuedFileJobs.isEmpty)
            XCTAssertEqual(model.jobs.first { $0.action == .gradeRender }?.state, .cancelled)
            XCTAssertTrue(sent.isEmpty, "nothing was sent")
            let edited = workspace.locations.nasEditedRoot(for: event).path
            XCTAssertFalse(FileManager.default.fileExists(atPath: edited), "nothing was written to the NAS")
            model.isBusy = false
        }
    }

    func testWithEveryRenderOptionOffItSendsAsItIs() async throws {
        try await withSandbox { root, model, workspace in
            try addClip(root, model, workspace)
            let grading = workspace.grading
            var sent: [Set<UUID>] = []
            grading.startImmichSend = { sent.append($0) }
            grading.beginImmichSend([event.id])
            try await waitUntil { grading.immichSendAsk?.stage == .asking }
            grading.immichSendAsk?.setOption(.grade, on: false)
            XCTAssertEqual(grading.immichSendAsk?.rendersAnything, false)

            grading.answerImmichSendAsk(.renderAndSend)

            XCTAssertEqual(sent, [[event.id]])
            XCTAssertTrue(model.queuedFileJobs.isEmpty)
        }
    }

    func testANASRenderChecksTheDriveFolderAndSaysWhenTheDriveIsAway() async throws {
        try await withSandbox { root, model, workspace in
            try addClip(root, model, workspace, onNAS: true)
            let inputs = workspace.grading.sendPlanInputs([event.id])
            let away = ClipGrading.planImmichSend(inputs, readsNAS: true, renderer: GradeRenderer(), check: { _, _ in .none }, driveIsAvailable: { _ in false })
            XCTAssertEqual(away.pending.first?.request.mirrorFolder, GradedRenderNaming.outputFolder(editedRoot: workspace.locations.editedRoot(for: event, policy: .buffer)))
            XCTAssertEqual(away.driveAwayCount, 1)
            let here = ClipGrading.planImmichSend(inputs, readsNAS: true, renderer: GradeRenderer(), check: { _, _ in .none }, driveIsAvailable: { _ in true })
            XCTAssertEqual(here.driveAwayCount, 0)
        }
    }

    func testACopyAlreadyMadeIsWrittenDownAndNotAskedFor() async throws {
        try await withSandbox { root, model, workspace in
            try addClip(root, model, workspace, onNAS: true)
            let grading = workspace.grading
            let inputs = grading.sendPlanInputs([event.id])
            let existing = GradedRenderNaming.outputFolder(editedRoot: workspace.locations.nasEditedRoot(for: event)).appendingPathComponent("C0001_709.mov")
            var recorded: [String: URL] = [:]
            let plan = ClipGrading.planImmichSend(
                inputs, readsNAS: true, renderer: GradeRenderer(),
                check: { _, _ in .found(existing) },
                record: { _, copies in recorded = copies }
            )
            XCTAssertTrue(plan.pending.isEmpty, "already rendered: nothing to ask about")
            XCTAssertEqual(Array(recorded.values), [existing])

            // Written down, so Immich checks swap it in.
            try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 3, count: 128).write(to: existing)
            let placed = GradedSyncPlanner.placedRequests(inputs, readsNAS: true, detect: { _ in .sLog3SGamut3Cine }, range: { _ in .full })
            let catalog = model.catalogURLForImmich
            let problems = ClipGrading.recordGradedCopies(placed, copies: recorded, newlyRendered: [], locations: workspace.locations, catalogURL: catalog)
            XCTAssertEqual(problems, [])
            let records = try GradedCopyStore(catalogURL: catalog).records(eventIDs: [event.id])
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.gradedRelativePath, workspace.locations.nasRelativePath(existing.path))
            XCTAssertEqual(records.first?.isOnNAS, true, "a NAS copy with no Sync record is read and recorded as verified")
        }
    }

    /// A manual render of a clip that is only on the NAS: the copy is
    /// written down for Immich and recorded as verified on the NAS, Immich
    /// is asked to scan (the same follow-up Sync uses), and the finished job
    /// says where the copy went, with a Show in Finder target.
    func testAFinishedNASRenderIsWrittenDownAndAsksImmichToScan() async throws {
        try await withSandbox { root, model, workspace in
            let clip = try addClip(root, model, workspace, onNAS: true)
            let output = GradedRenderNaming.outputFolder(editedRoot: workspace.locations.nasEditedRoot(for: event))
            let copy = output.appendingPathComponent("C0001_709.mov")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data(repeating: 3, count: 128).write(to: copy)
            let key = "C0001.MP4|64|1780000100"
            let request = GradedRenderRequest(
                source: clip, recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine, range: .full),
                sourceKey: key, sourceModifiedAt: Date(timeIntervalSince1970: 1_780_000_100), outputFolder: output
            )
            let placed = ClipGrading.placedForRecording([request], events: [key: event.id], locations: workspace.locations)
            XCTAssertEqual(placed.count, 1)
            XCTAssertEqual(placed.first?.placement, .nas)
            XCTAssertEqual(placed.first?.originalRelativePath, workspace.locations.nasRelativePath(clip.path))
            var outcome = ClipGrading.RenderOutcome()
            outcome.rendered = [copy]
            outcome.copies = [0: copy]

            let problems = ClipGrading.recordRenderedCopies(placed, outcome: outcome, requests: [request], locations: workspace.locations, catalogURL: model.catalogURLForImmich)
            XCTAssertEqual(problems, [])
            let records = try GradedCopyStore(catalogURL: model.catalogURLForImmich).records(eventIDs: [event.id])
            XCTAssertEqual(records.map(\.gradedRelativePath), [workspace.locations.nasRelativePath(copy.path)].compactMap { $0 })
            XCTAssertEqual(records.first?.isOnNAS, true, "recorded as verified on the NAS, so checks wait for its scan")

            var followUps = 0
            workspace.nasChangeFollowObserver = { _ in followUps += 1 }
            let jobID = UUID()
            workspace.grading.finishedRender(jobID: jobID, outcome: outcome, placed: placed, requests: [request])
            XCTAssertEqual(followUps, 1, "a copy on the NAS asks Immich to scan")
            let copies = try XCTUnwrap(model.renderedCopiesByJob[jobID])
            XCTAssertEqual(copies.map(\.path), [copy.standardizedFileURL.path])
            XCTAssertEqual(copies.first?.libraryRelativePath, workspace.locations.nasRelativePath(copy.path))
            XCTAssertTrue(copies.first?.libraryRelativePath.hasSuffix("/Edited/Rec709/C0001_709.mov") == true)
            XCTAssertEqual(copies.first?.eventID, event.id)

            // The Jobs window's rows: where it is, and its Immich state.
            let waiting = JobDetailFacts.gradedCopyRows(copies, states: [:], immichConfigured: true, stacksOn: { _ in false })
            XCTAssertEqual(waiting.first?.place, "On the NAS")
            XCTAssertEqual(waiting.first?.immich, "Waiting for Immich scan: added on the next check")
            XCTAssertEqual(waiting.first?.path, copy.standardizedFileURL.path, "Show in Finder selects the copy itself")
            let pathKey = NASSyncStore.pathKey(copies[0].libraryRelativePath)
            let stacked = JobDetailFacts.gradedCopyRows(copies, states: [pathKey: .stacked], immichConfigured: true, stacksOn: { _ in true })
            XCTAssertEqual(stacked.first?.immich, "In Immich, stacked on its original")
            XCTAssertEqual(stacked.first?.isStacked, true)
            let listed = JobDetailFacts.gradedCopyRows(copies, states: [pathKey: .inImmich], immichConfigured: true, stacksOn: { $0 == self.event.id })
            XCTAssertEqual(listed.first?.immich, "In Immich; stacked on its original on the next check")

            // A drive copy waits for Sync: no scan is asked for.
            followUps = 0
            var onDrive = copies[0]
            onDrive.isOnNAS = false
            XCTAssertEqual(JobDetailFacts.gradedCopyRows([onDrive], states: [:], immichConfigured: true, stacksOn: { _ in false }).first?.immich, "Sync to NAS carries it, then Immich adds it")
            // Show in Finder checks on the click; a missing copy is said.
            XCTAssertNil(JobDetailFacts.revealMessage(found: 2, of: 2))
            XCTAssertEqual(JobDetailFacts.revealMessage(found: 0, of: 1), "The copy is not there now: it was moved, or its drive or NAS is not connected.")
            XCTAssertEqual(JobDetailFacts.revealMessage(found: 1, of: 3), "2 of 3 copies are not there now; Finder shows the others.")
        }
    }
}

/// Renders the question off-screen with made-up clips, light and dark. Runs
/// only when `CT_SNAPSHOT_OUT` names an output folder.
@MainActor
final class ImmichSendGradeAskSnapshotTests: XCTestCase {
    func testRenderTheQuestion() throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else {
            throw XCTSkip("Snapshot harness runs only with CT_SNAPSHOT_OUT set.")
        }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = AppConfiguration(
            demoRootPath: "/tmp/ct-demo", importSourcePath: "/tmp/ct-card", archivePath: "/tmp/ct-lib/Originals",
            bufferPath: "/Volumes/Buffer", cameraLibraryRootPath: "/Volumes/nas_share", catalogDatabasePath: "/tmp/ct-demo/catalog.sqlite",
            activityLogPath: "/tmp/ct-demo/activity.jsonl"
        )
        let model = DashboardModel(jobs: [], configuration: configuration, configurationStore: ConfigurationStore(url: URL(fileURLWithPath: "/tmp/ct-demo/config.json")))
        let workspace = EventsWorkspace(model: model, supportFolder: URL(fileURLWithPath: "/tmp/ct-demo/Support", isDirectory: true))
        let ask = ImmichSendGradeAsk(eventIDs: [UUID()], stage: .asking)
        ask.eventNames = ["Beach Day"]
        ask.estimatedBytes = 3_400_000_000
        let recipe = GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine)
        ask.pending = (1...8).map { index in
            GradedSyncPlanner.PlacedRequest(
                request: GradedRenderRequest(
                    source: URL(fileURLWithPath: "/Volumes/nas_share/2026/Beach Day/Originals/A7V/C000\(index).MP4"), recipe: recipe,
                    sourceKey: "k\(index)", sourceModifiedAt: Date(), outputFolder: URL(fileURLWithPath: "/Volumes/nas_share/2026/Beach Day/Edited/Rec709")
                ),
                placement: index <= 6 ? .nas : .drive, eventID: UUID(), eventAssetID: "e\(index)", originalRelativePath: nil
            )
        }
        ask.previews = (1...6).map { index in
            var row = BlanketGradeModel.Row(id: "k\(index)", name: "C000\(index).MP4", profile: .sLog3SGamut3Cine, conversion: .builtIn, range: .full, existing: nil)
            row.before = Self.frame(flat: true, seed: index)
            row.after = Self.frame(flat: false, seed: index)
            return row
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = ImmichSendGradeAskView(grading: workspace.grading, ask: ask).background(.background)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let name = appearance == .aqua ? "send-grade-ask-light.png" : "send-grade-ask-dark.png"
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name))
            window.orderOut(nil)
        }
    }

    /// A made-up frame: grey and low-contrast for log, warmer and punchier converted.
    private static func frame(flat: Bool, seed: Int) -> CGImage {
        let width = 320, height = 180
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let hue = Double(seed) / 7
        let top = flat ? CGColor(gray: 0.55, alpha: 1) : CGColor(red: 0.2 + hue * 0.3, green: 0.45, blue: 0.85, alpha: 1)
        let bottom = flat ? CGColor(gray: 0.42, alpha: 1) : CGColor(red: 0.95, green: 0.7 - hue * 0.2, blue: 0.35, alpha: 1)
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
        return context.makeImage()!
    }
}
