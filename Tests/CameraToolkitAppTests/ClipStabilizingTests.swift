@testable import CameraToolkitApp
import CameraToolkitCore
import Foundation
import XCTest

/// The app side of stabilization: per-clip settings saved in the catalog
/// with Undo, the graded render picking them up, stabilized-only copies,
/// the quick sheet's choice, and the render asks' Stabilize box.
@MainActor
final class ClipStabilizingTests: XCTestCase {
    private let sidecar = """
    <NonRealTimeMeta><Group name="CameraUnitMetadataSet">
    <Item name="CaptureGammaEquation" value="s-log3-cine"/>
    <Item name="CaptureColorPrimaries" value="s-gamut3-cine"/>
    </Group></NonRealTimeMeta>
    """

    /// A fake Gyroflow that answers like 1.6.3 and writes `bytes`.
    final class FakeRunner: StabilizerProcessRunning, @unchecked Sendable {
        let bytes: Data
        init(bytes: Data = Data("movie".utf8)) { self.bytes = bytes }
        func run(executable: URL, arguments: [String], onLine: @escaping @Sendable (String) -> Void, keepRunning: @escaping @Sendable () -> Bool) throws -> StabilizerProcessOutcome {
            let presetPath = arguments[arguments.firstIndex(of: "--preset")! + 1]
            let preset = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: presetPath))) as! [String: Any]
            let output = (preset["output"] as! [String: Any])["output_path"] as! String
            try bytes.write(to: URL(fileURLWithPath: output))
            onLine("[1] Rendering progress: 2/2 frames (100.0%) ETA 0.0s")
            onLine("[1] Rendering completed: x.mov")
            return StabilizerProcessOutcome(exitCode: 0, terminated: false)
        }
    }

    static let gyroflow = GyroflowInstallation(
        appURL: URL(fileURLWithPath: "/Applications/Gyroflow.app"),
        executableURL: URL(fileURLWithPath: "/Applications/Gyroflow.app/Contents/MacOS/gyroflow"),
        version: "1.6.3", isAppStoreBuild: false
    )

    static func fakeStabilizer(scratch: URL) -> Stabilizer {
        let stabilizer = Stabilizer(installation: gyroflow, runner: FakeRunner(), verifier: { _, _ in }, probe: { _ in .present(.sony) }, scratchFolder: scratch)
        stabilizer.finishGrace = 0.1
        return stabilizer
    }

    private func withSandbox(_ body: (URL, DashboardModel, EventsWorkspace, ClipStabilizing) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitStabilize-\(UUID().uuidString)", isDirectory: true)
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
        let stabilizing = ClipStabilizing(grading: workspace.grading, installation: .some(Self.gyroflow))
        let scratch = root.appendingPathComponent("Scratch", isDirectory: true)
        stabilizing.makeStabilizer = { Self.fakeStabilizer(scratch: scratch) }
        workspace.grading.stabilizingStorage = stabilizing
        try await body(root, model, workspace, stabilizing)
        CatalogDatabase.checkpointAndClose(url: root.appendingPathComponent("catalog.sqlite"))
    }

    private func makeClips(in folder: URL, names: [String], log: Set<String>) throws -> [OrganizeItem] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        return try names.enumerated().map { index, name in
            let clip = folder.appendingPathComponent("\(name).MP4")
            try Data(repeating: UInt8(index), count: 64 + index).write(to: clip)
            var companions: [OrganizeFile] = []
            if log.contains(name) {
                let xml = folder.appendingPathComponent("\(name)M01.XML")
                try Data(sidecar.utf8).write(to: xml)
                companions.append(OrganizeFile(path: xml.path, size: Int64(sidecar.utf8.count), modifiedAt: date))
            }
            return OrganizeItem(primary: OrganizeFile(path: clip.path, size: Int64(64 + index), modifiedAt: date), companions: companions, kind: .video, captureDate: date, hasCameraDate: true)
        }
    }

    func testStabilizationIsSavedPerClipAndUndoesInOneStep() async throws {
        try await withSandbox { root, model, workspace, stabilizing in
            let items = try makeClips(in: root.appendingPathComponent("Card/M4ROOT/CLIP"), names: ["C0001", "C0002"], log: [])
            stabilizing.setStabilization(StabilizationSettings(smoothing: .high), for: items, undoTitle: "Stabilize 2 Clips")
            let keys = items.map(ClipStabilizing.fileKey)
            XCTAssertEqual(stabilizing.settings(for: items[0])?.smoothing, .high)
            let catalog = URL(fileURLWithPath: model.configuration.catalogDatabasePath)
            XCTAssertEqual(try StabilizationStore(catalogURL: catalog).load().keys.sorted(), keys.sorted(), "saved in the catalog")
            XCTAssertEqual(stabilizing.lastSmoothing, .high, "offered next time")
            XCTAssertEqual(workspace.undoMenuTitle?.contains("Stabilize 2 Clips"), true, workspace.undoMenuTitle ?? "nil")

            workspace.undo()
            XCTAssertNil(stabilizing.settings(for: items[0]))
            XCTAssertEqual(try StabilizationStore(catalogURL: catalog).load(), [:])
            workspace.redo()
            XCTAssertEqual(stabilizing.settings(for: items[1])?.smoothing, .high)
            // A fresh session reads it back.
            let reopened = ClipStabilizing(grading: workspace.grading, installation: .some(Self.gyroflow))
            XCTAssertEqual(reopened.settings(for: items[1]), StabilizationSettings(smoothing: .high))
            for item in items { XCTAssertTrue(FileManager.default.fileExists(atPath: item.primary.path), "no file touched") }
        }
    }

    func testGradedRendersCarryStabilizationAndUngradedClipsGetAStabilizedCopy() async throws {
        try await withSandbox { root, model, workspace, stabilizing in
            let grading = workspace.grading
            let event = SavedCameraEvent(name: "Beach Day", eventDate: Date(timeIntervalSince1970: 1_780_000_000))
            model.updateConfiguration { $0.savedEvents = [event] }
            let folder = workspace.locations.eventFolder(for: event, policy: .buffer).appendingPathComponent("Originals/A7V", isDirectory: true)
            let items = try makeClips(in: folder, names: ["C0001", "C0002", "C0003"], log: ["C0001", "C0002"])
            await grading.ensureDetected(items)
            grading.setGrade(ClipGrade(look: .builtIn(.softFilm)), for: [items[0], items[1]], undoTitle: "Apply Soft Film")
            stabilizing.setStabilization(StabilizationSettings(smoothing: .low), for: items)
            stabilizing.setMotion(.present(.sony), forKey: ClipStabilizing.fileKey(items[0]))
            stabilizing.setMotion(.absent, forKey: ClipStabilizing.fileKey(items[1]))
            stabilizing.setMotion(.present(.sony), forKey: ClipStabilizing.fileKey(items[2]))
            let stacks = items.map { OrganizeStack(items: [$0]) }

            let plan = grading.renderPlan(for: stacks, boardEventID: event.id)
            XCTAssertEqual(plan.requests.count, 2, "the two graded clips")
            XCTAssertEqual(plan.requests[0].stabilization, RenderStabilization(settings: StabilizationSettings(smoothing: .low)))
            XCTAssertNil(plan.requests[1].stabilization, "no motion data: graded only")
            XCTAssertTrue(plan.refusals.isEmpty, "a stabilized clip without a grade is not refused: \(plan.refusals)")
            XCTAssertTrue(plan.requests[0].outputFolder.path.hasSuffix("/Edited/Rec709"))

            let only = stabilizing.stabilizeOnlyItems(in: stacks)
            XCTAssertEqual(only.map(\.id), [items[2].id])
            let stabilizePlan = stabilizing.stabilizePlan(for: only, in: stacks, boardEventID: event.id)
            XCTAssertEqual(stabilizePlan.requests.count, 1)
            XCTAssertTrue(stabilizePlan.requests[0].outputFolder.path.hasSuffix("/Edited/Stabilized"), stabilizePlan.requests[0].outputFolder.path)
            XCTAssertEqual(stabilizePlan.requests[0].settings.smoothing, .low)

            XCTAssertEqual(Set(stabilizing.renderStabilizationMap().keys), [ClipStabilizing.fileKey(items[0]), ClipStabilizing.fileKey(items[2])], "planners get only clips that can be stabilized")

            // The stabilized-only job writes Edited/Stabilized/<name>_stab.mov.
            let outcome = try ClipStabilizing.runStabilize(stabilizePlan.requests, stabilizer: Self.fakeStabilizer(scratch: root.appendingPathComponent("Scratch")), progress: { _ in })
            XCTAssertEqual(outcome.rendered.map(\.lastPathComponent), ["C0003_stab.mov"])
            XCTAssertTrue(ClipStabilizing.summary(outcome, refusals: []).contains("Edited/Stabilized"))
            XCTAssertFalse(ClipGrading.isGradable(OrganizeItem(primary: OrganizeFile(path: outcome.rendered[0].path, size: 5, modifiedAt: Date()), kind: .video, captureDate: Date(), hasCameraDate: false)), "a stabilized copy is never graded as an original")
        }
    }

    func testAGradedRenderThatCannotStabilizeLeavesNothingBehind() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StabilizeChain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("C0001.MP4")
        try Data("not really a movie".utf8).write(to: source)
        var request = GradedRenderRequest(
            source: source,
            recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine),
            sourceKey: "C0001|1|1", sourceModifiedAt: Date(),
            outputFolder: folder.appendingPathComponent("Edited/Rec709", isDirectory: true)
        )
        request.stabilization = RenderStabilization()
        // Without Gyroflow: a clear failure, nothing written.
        XCTAssertThrowsError(try ClipGrading.runRender([request], availableBytes: { _ in nil }, estimatedBytes: { _ in nil }, progress: { _ in })) { error in
            XCTAssertTrue(error.localizedDescription.contains("Gyroflow"), error.localizedDescription)
        }
        // With a (fake) Gyroflow whose output the grade cannot read: the
        // intermediate is deleted with the failed render.
        let stabilizer = Self.fakeStabilizer(scratch: folder.appendingPathComponent("Scratch"))
        XCTAssertThrowsError(try ClipGrading.runRender([request], stabilizer: stabilizer, availableBytes: { _ in nil }, estimatedBytes: { _ in nil }, progress: { _ in }))
        let left = (try? FileManager.default.subpathsOfDirectory(atPath: request.outputFolder.path)) ?? []
        XCTAssertTrue(left.allSatisfy { !$0.hasSuffix(".mov") }, "no intermediate or partial left: \(left)")
        XCTAssertEqual(try Data(contentsOf: source), Data("not really a movie".utf8))
    }

    func testQuickSheetChoiceChangesOnlyWhatMoved() async throws {
        try await withSandbox { root, _, _, stabilizing in
            let items = try makeClips(in: root.appendingPathComponent("Card/M4ROOT/CLIP"), names: ["C0001", "C0002", "C0003"], log: [])
            let keys = items.map(ClipStabilizing.fileKey)
            stabilizing.setMotion(.present(.sony), forKey: keys[0])
            stabilizing.setMotion(.present(.sony), forKey: keys[1])
            stabilizing.setMotion(.absent, forKey: keys[2])
            let model = BlanketGradeModel(scopeTitle: "Beach Day", lookName: { _ in "" })
            await stabilizing.fillBlanketChoice(model, items: items)
            XCTAssertEqual(model.stabilize.withMotion, 2)
            XCTAssertEqual(model.stabilize.withoutMotion, 1)
            XCTAssertFalse(model.stabilize.isOn, "starts where the clips are: off")
            XCTAssertNil(stabilizing.applyBlanketChoice(model.stabilize, items: items), "untouched: nothing changes")
            XCTAssertTrue(stabilizing.settingsByKey.isEmpty)

            var choice = model.stabilize
            choice.isOn = true
            choice.smoothing = .high
            XCTAssertEqual(stabilizing.applyBlanketChoice(choice, items: items), 2, "the clip with no motion data is skipped")
            XCTAssertEqual(Set(stabilizing.settingsByKey.keys), [keys[0], keys[1]])

            await stabilizing.fillBlanketChoice(model, items: items)
            XCTAssertTrue(model.stabilize.isOn, "all that can be are on")
            XCTAssertEqual(model.stabilize.smoothing, .high)
            var off = model.stabilize
            off.isOn = false
            XCTAssertEqual(stabilizing.applyBlanketChoice(off, items: items), 0)
            XCTAssertTrue(stabilizing.settingsByKey.isEmpty)
        }
    }

    func testSendToImmichOffersStabilizeAndHonoursTheBox() async throws {
        try await withSandbox { _, _, workspace, stabilizing in
            let grading = workspace.grading
            var request = GradedRenderRequest(
                source: URL(fileURLWithPath: "/Volumes/Buffer/2026/Trip/Originals/A7V/C0001.MP4"),
                recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine),
                sourceKey: "C0001|1|1", sourceModifiedAt: Date(),
                outputFolder: URL(fileURLWithPath: "/Volumes/Buffer/2026/Trip/Edited/Rec709")
            )
            let plainItem = GradedSyncPlanner.PlacedRequest(request: request, placement: .drive, eventID: UUID(), eventAssetID: "a", originalRelativePath: nil)
            XCTAssertNil(stabilizing.stabilizeOption(for: [plainItem]), "no box when nothing is set to Stabilize")
            stabilizing.setStabilization(byKey: [("C0001|1|1", StabilizationSettings())], undoTitle: "Stabilize")
            let refreshed = stabilizing.refreshStabilization(of: [plainItem])
            XCTAssertNotNil(refreshed[0].request.stabilization)
            request.stabilization = RenderStabilization()
            let option = try XCTUnwrap(stabilizing.stabilizeOption(for: refreshed))
            XCTAssertTrue(option.isOn)
            XCTAssertTrue(option.isAvailable)

            let ask = ImmichSendGradeAsk(eventIDs: [], stage: .asking)
            ask.setStabilizeOption(option)
            XCTAssertEqual(ask.options.map(\.id), [.grade, .stabilize])
            XCTAssertNotNil(grading.applyRenderOptions(ask.options, to: refreshed).first?.request.stabilization, "ticked: stabilized, then graded")
            ask.setOption(.stabilize, on: false)
            XCTAssertNil(grading.applyRenderOptions(ask.options, to: refreshed).first?.request.stabilization, "unticked: graded only")
            ask.setOption(.grade, on: false)
            XCTAssertTrue(grading.applyRenderOptions(ask.options, to: refreshed).isEmpty)
        }
    }

    func testPreviewWindowStaysInsideTheClip() {
        XCTAssertEqual(ClipStabilizing.previewRange(around: 5, duration: 12), 3.5...6.5)
        XCTAssertEqual(ClipStabilizing.previewRange(around: 0.2, duration: 12), 0...3)
        XCTAssertEqual(ClipStabilizing.previewRange(around: 11.9, duration: 12), 9...12)
        XCTAssertEqual(ClipStabilizing.previewRange(around: 1, duration: 2), 0...2)
    }

    func testStabilizeStopsBeforeRunningOutOfSpace() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StabilizeSpace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let requests = (1...2).map { index in
            StabilizeRequest(
                source: folder.appendingPathComponent("C000\(index).MP4"), settings: StabilizationSettings(),
                sourceKey: "C000\(index)|1|1", sourceModifiedAt: Date(),
                outputFolder: folder.appendingPathComponent("Edited/Stabilized", isDirectory: true)
            )
        }
        final class Counting: StabilizerProcessRunning, @unchecked Sendable {
            var runs = 0
            func run(executable: URL, arguments: [String], onLine: @escaping @Sendable (String) -> Void, keepRunning: @escaping @Sendable () -> Bool) throws -> StabilizerProcessOutcome {
                runs += 1
                return StabilizerProcessOutcome(exitCode: 0, terminated: false)
            }
        }
        let runner = Counting()
        let stabilizer = Stabilizer(installation: Self.gyroflow, runner: runner, verifier: { _, _ in }, probe: { _ in .present(.sony) })
        let outcome = try ClipStabilizing.runStabilize(
            requests, stabilizer: stabilizer,
            availableBytes: { _ in 20 * 1_024 * 1_024 * 1_024 },
            estimatedBytes: { _ in 30 * 1_024 * 1_024 * 1_024 },
            progress: { _ in }
        )
        XCTAssertEqual(runner.runs, 0, "Gyroflow is never started without room for its ProRes copy")
        XCTAssertTrue(outcome.stoppedReason?.hasPrefix("Stopped before C0001.MP4") == true, outcome.stoppedReason ?? "nil")
        XCTAssertTrue(outcome.stoppedReason?.contains("ProRes") == true)

        // A graded render that stabilizes counts its intermediate too.
        var graded = GradedRenderRequest(
            source: folder.appendingPathComponent("C0001.MP4"), recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine),
            sourceKey: "C0001|1|1", sourceModifiedAt: Date(), outputFolder: folder.appendingPathComponent("Edited/Rec709", isDirectory: true)
        )
        graded.stabilization = RenderStabilization()
        let gb: Int64 = 1_024 * 1_024 * 1_024
        let full = try ClipGrading.runRender(
            [graded], stabilizer: stabilizer,
            availableBytes: { _ in 12 * gb }, estimatedBytes: { _ in 2 * gb }, stabilizedBytes: { _ in 8 * gb },
            progress: { _ in }
        )
        XCTAssertEqual(runner.runs, 0)
        XCTAssertTrue(full.stoppedReason?.contains("intermediate") == true, full.stoppedReason ?? "nil")
        // Without stabilization the same space is enough for the copy alone.
        graded.stabilization = nil
        let plain = try? ClipGrading.runRender([graded], availableBytes: { _ in 12 * gb }, estimatedBytes: { _ in 2 * gb }, stabilizedBytes: { _ in 8 * gb }, progress: { _ in })
        XCTAssertNil(plain?.stoppedReason, "the intermediate is only counted when there is one")
    }

    func testWithoutAUsableGyroflowClipsAreGradedAloneWithANote() async throws {
        try await withSandbox { root, model, workspace, _ in
            let grading = workspace.grading
            let missing = ClipStabilizing(grading: grading, installation: .some(nil))
            grading.stabilizingStorage = missing
            XCTAssertEqual(missing.availability, .notInstalled)
            let event = SavedCameraEvent(name: "Beach Day", eventDate: Date(timeIntervalSince1970: 1_780_000_000))
            model.updateConfiguration { $0.savedEvents = [event] }
            let folder = workspace.locations.eventFolder(for: event, policy: .buffer).appendingPathComponent("Originals/A7V", isDirectory: true)
            let items = try makeClips(in: folder, names: ["C0001"], log: ["C0001"])
            await grading.ensureDetected(items)
            grading.setGrade(ClipGrade(look: .builtIn(.softFilm)), for: items, undoTitle: "Apply Soft Film")
            missing.setStabilization(byKey: [(ClipStabilizing.fileKey(items[0]), StabilizationSettings())], undoTitle: "Stabilize")
            missing.setMotion(.present(.sony), forKey: ClipStabilizing.fileKey(items[0]))
            XCTAssertNil(missing.renderStabilization(forKey: ClipStabilizing.fileKey(items[0])))
            XCTAssertTrue(missing.renderStabilizationMap().isEmpty, "render before Sync shows no Stabilize box")
            let plan = grading.renderPlan(for: [OrganizeStack(items: items)], boardEventID: event.id)
            XCTAssertEqual(plan.requests.count, 1, "the graded copy is still made")
            XCTAssertNil(plan.requests[0].stabilization)
            XCTAssertTrue(plan.notes.first?.contains("graded only") == true, plan.notes.first ?? "nil")
        }
    }

    /// A BT.2020-tagged log clip that is also stabilized: its copy's tag
    /// names both (`|src2020v3` then the stabilization), it is found again
    /// as the same render, and a plain graded copy is never taken for it.
    func testBT2020AndStabilizationComposeInTheGradeTag() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Stabilize2020-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await SyntheticSLog3Clip.write(to: folder.appendingPathComponent("C0001.MP4"), primaries: .rec2020)
        let recipe = SyntheticSLog3Clip.recipe(range: .video)
        let plain = GradedRenderRequest(source: clip, recipe: recipe, sourceKey: "C0001|1|1", sourceModifiedAt: Date(), outputFolder: folder.appendingPathComponent("Edited/Rec709", isDirectory: true))
        var stabilized = plain
        stabilized.stabilization = RenderStabilization(settings: StabilizationSettings(smoothing: .high))
        let tag = try XCTUnwrap(GradedVideoExporter.renderFingerprint(of: stabilized))
        XCTAssertEqual(tag, recipe.fingerprint + "|src2020v3|" + StabilizationSettings(smoothing: .high).fingerprint)
        XCTAssertEqual(GradedVideoExporter.renderFingerprint(of: plain), recipe.fingerprint + "|src2020v3")

        // The fake Gyroflow "stabilizes" by writing the clip itself.
        let stabilizer = Stabilizer(installation: Self.gyroflow, runner: FakeRunner(bytes: try Data(contentsOf: clip)), verifier: { _, _ in }, probe: { _ in .present(.sony) }, scratchFolder: folder.appendingPathComponent("Scratch"))
        stabilizer.finishGrace = 0.1
        let outcome = try ClipGrading.runRender([stabilized], renderer: GradeRenderer(), stabilizer: stabilizer, availableBytes: { _ in nil }, estimatedBytes: { _ in nil }, progress: { _ in })
        let url = try XCTUnwrap(outcome.rendered.first, "\(outcome)")
        XCTAssertEqual(GradedVideoExporter.readTags(url)?.grade, tag)
        XCTAssertEqual(GradedVideoExporter.identity(at: url, of: stabilized), .same)
        XCTAssertEqual(GradedVideoExporter.identity(at: url, of: plain), .olderGrade, "never taken for an unstabilized copy")
        let left = (try? FileManager.default.subpathsOfDirectory(atPath: plain.outputFolder.path)) ?? []
        XCTAssertEqual(left, [url.lastPathComponent], "the intermediate is gone")
    }

    /// Right after launch the Gyroflow search may still run. Render before
    /// Sync and a manual render wait for it — never planning clips set to
    /// Stabilize as graded only (their stabilized copies would read as
    /// older grades and get plain "(2)" duplicates).
    func testPlannersWaitForTheGyroflowSearch() async throws {
        try await withSandbox { root, model, workspace, _ in
            let grading = workspace.grading
            let found = Self.gyroflow
            let slow = ClipStabilizing(grading: grading, installation: nil, locator: {
                Thread.sleep(forTimeInterval: 0.8)
                return found
            })
            grading.stabilizingStorage = slow
            XCTAssertEqual(slow.availability, .checking)

            let event = SavedCameraEvent(name: "Beach Day", eventDate: Date(timeIntervalSince1970: 1_780_000_000))
            let date = Date(timeIntervalSince1970: 1_780_000_100)
            model.updateConfiguration { configuration in
                configuration.savedEvents = [event]
                configuration.photoEventAssignments = [PhotoEventAssignment(
                    sourceRootPath: root.appendingPathComponent("Card").path, relativePath: "C0001.MP4",
                    fileSize: 64, modifiedAt: date, eventID: event.id, deviceID: "sony-a7v"
                )]
                configuration.gradeDefaults.setLook(.builtIn(.softFilm), for: .sLog3SGamut3Cine)
                configuration.renderGradedCopiesBeforeSync = true
            }
            let assignment = model.configuration.photoEventAssignments[0]
            let clip = try XCTUnwrap(workspace.locations.driveURL(for: assignment, event: event, policy: .buffer))
            try FileManager.default.createDirectory(at: clip.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(to: clip)
            try Data(sidecar.utf8).write(to: clip.deletingLastPathComponent().appendingPathComponent("C0001M01.XML"))
            let key = FaceIndexStore.fileKey(fileName: "C0001.MP4", byteCount: 64, modifiedAt: date)
            slow.setStabilization(byKey: [(key, StabilizationSettings())], undoTitle: "Stabilize")

            var asked: [ClipGrading.RenderBeforeSyncSummary] = []
            grading.confirmRenderBeforeSync = { summary in
                asked.append(summary)
                return .cancel
            }
            UserDefaults.standard.removeObject(forKey: ClipGrading.renderBeforeSyncConfirmedKey)
            defer { UserDefaults.standard.removeObject(forKey: ClipGrading.renderBeforeSyncConfirmedKey) }
            grading.renderBeforeSyncIfWanted(events: [event], syncTitle: "Beach Day", syncNow: {}, queueSync: { _ in })
            let deadline = ContinuousClock.now + .seconds(20)
            while asked.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(asked.first?.count, 1)
            XCTAssertEqual(asked.first?.stabilized, 1, "the plan waited for the search and stabilizes the clip")
            XCTAssertTrue(slow.availability.isReady)

            // A manual render asked while the search runs also waits.
            slow.refreshAvailability()
            XCTAssertEqual(slow.availability, .checking)
            model.isBusy = true
            let xml = clip.deletingLastPathComponent().appendingPathComponent("C0001M01.XML")
            let item = OrganizeItem(
                primary: OrganizeFile(path: clip.path, size: 64, modifiedAt: date),
                companions: [OrganizeFile(path: xml.path, size: Int64(sidecar.utf8.count), modifiedAt: date)],
                kind: .video, captureDate: date, hasCameraDate: true
            )
            await grading.ensureDetected([item])
            grading.renderGradedCopies(of: [OrganizeStack(items: [item])], boardEventID: event.id)
            while !model.queuedFileJobs.contains(where: { $0.action == .gradeRender }), ContinuousClock.now < deadline + .seconds(20) {
                try await Task.sleep(for: .milliseconds(20))
            }
            let job = try XCTUnwrap(model.jobs.first { $0.action == .gradeRender && $0.state == .queued }, "\(model.statusMessage) \(model.jobs.map { "\($0.action) \($0.state)" })")
            XCTAssertTrue(job.detail.contains("1 stabilized first"), job.detail)
            model.cancelQueuedFileJob(id: job.id)
            model.isBusy = false
        }
    }
}
