import AVFoundation
@testable import CameraToolkitCore
import Foundation
import GRDB
import XCTest

/// The stabilizer drives an installed Gyroflow headless. These tests use a
/// fake process runner that plays back Gyroflow 1.6.3's output and writes
/// (or doesn't write) the output file, so no Gyroflow is needed.
final class StabilizerTests: XCTestCase {
    // MARK: Fakes

    /// Plays back `lines`, optionally writes `bytes` to the preset's
    /// output path, then waits for the stabilizer to end it when `waits`.
    final class FakeRunner: StabilizerProcessRunning, @unchecked Sendable {
        let lock = NSLock()
        var lines: [String]
        var writesOutput: Data?
        var waitsToBeEnded: Bool
        var exitCode: Int32 = 0
        /// Called after each line (the test flips a stop flag here).
        var afterLine: (Int) -> Void = { _ in }
        /// Where the bytes go: Gyroflow renders into `<output>.tmp`.
        var writesTo: (String) -> String = { $0 }
        private(set) var calls: [(URL, [String])] = []
        private(set) var presets: [[String: Any]] = []
        private(set) var ended = false

        init(lines: [String], writesOutput: Data? = Data("movie".utf8), waitsToBeEnded: Bool = false) {
            self.lines = lines
            self.writesOutput = writesOutput
            self.waitsToBeEnded = waitsToBeEnded
        }

        var presetOutputPath: String? {
            ((presets.last?["output"] as? [String: Any])?["output_path"]) as? String
        }

        func run(executable: URL, arguments: [String], onLine: @escaping @Sendable (String) -> Void, keepRunning: @escaping @Sendable () -> Bool) throws -> StabilizerProcessOutcome {
            let presetPath = arguments[arguments.firstIndex(of: "--preset")! + 1]
            let preset = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: presetPath))) as! [String: Any]
            lock.withLock {
                calls.append((executable, arguments))
                presets.append(preset)
            }
            let output = ((preset["output"] as? [String: Any])?["output_path"]) as! String
            for (index, line) in lines.enumerated() {
                if index == 1, let bytes = writesOutput { try bytes.write(to: URL(fileURLWithPath: writesTo(output))) }
                onLine(line)
                afterLine(index)
                if !keepRunning() {
                    ended = true
                    return StabilizerProcessOutcome(exitCode: 15, terminated: true)
                }
            }
            if lines.count <= 1, let bytes = writesOutput { try bytes.write(to: URL(fileURLWithPath: output)) }
            if waitsToBeEnded {
                let deadline = Date().addingTimeInterval(10)
                while keepRunning(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                ended = true
                return StabilizerProcessOutcome(exitCode: 15, terminated: true)
            }
            return StabilizerProcessOutcome(exitCode: exitCode, terminated: false)
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Stabilizer.Progress] = []
        var all: [Stabilizer.Progress] { lock.withLock { stored } }
        func add(_ step: Stabilizer.Progress) { lock.withLock { stored.append(step) } }
    }

    static let installation = GyroflowInstallation(
        appURL: URL(fileURLWithPath: "/Applications/Gyroflow.app"),
        executableURL: URL(fileURLWithPath: "/Applications/Gyroflow.app/Contents/MacOS/gyroflow"),
        version: "1.6.3",
        isAppStoreBuild: false
    )

    /// Gyroflow 1.6.3's `--stdout-progress` output for a 4-frame render.
    static let gyroflowOutput = [
        "03:31:31 [INFO] Videos: [\"/x/C0001.MP4\"]",
        "[0c412d19] Synchronization progress: 50.0%",
        "[0c412d19] Synchronization completed",
        "[0c412d19] Rendering progress: 1/4 frames (25.0%) ETA 1.0s",
        "[0c412d19] Rendering progress: 2/4 frames (50.0%) ETA 0.6s",
        "[0c412d19] Rendering progress: 4/4 frames (100.0%) ETA 0.0s",
        "[0c412d19] Rendering completed: C0001_ctk-stabilizing.mov",
    ]

    private func stabilizer(_ runner: FakeRunner, root: URL, probe: MotionDataAvailability = .present(.sony)) -> Stabilizer {
        var stabilizer = Stabilizer(
            installation: Self.installation,
            runner: runner,
            errorGrace: 0.1,
            verifier: { _, _ in },
            probe: { _ in probe },
            scratchFolder: root.appendingPathComponent("Scratch", isDirectory: true)
        )
        stabilizer.finishGrace = 0.1
        return stabilizer
    }

    private func makeSource(_ root: URL) throws -> URL {
        let folder = root.appendingPathComponent("Buffer/2026/2026-06-01 Trip/Originals/A7V", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("C0001.MP4")
        try Data("original".utf8).write(to: source)
        return source
    }

    private func request(_ source: URL, root: URL, smoothing: StabilizationSmoothing = .medium) -> StabilizeRequest {
        StabilizeRequest(
            source: source,
            settings: StabilizationSettings(smoothing: smoothing),
            sourceKey: "C0001.MP4|8|1",
            sourceModifiedAt: Date(timeIntervalSince1970: 1_780_000_000),
            outputFolder: StabilizedRenderNaming.outputFolder(editedRoot: root.appendingPathComponent("Buffer/2026/2026-06-01 Trip/Edited", isDirectory: true))
        )
    }

    private func files(under url: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    // MARK: Command line

    func testCommandLineAndPresetSayWhatTheRenderIs() throws {
        let job = GyroflowJob(
            input: URL(fileURLWithPath: "/Volumes/Buffer/Trip 2026/C0001.MP4"),
            output: URL(fileURLWithPath: "/Volumes/Buffer/Trip 2026/Edited/Stabilized/.TemporaryItems/x.ctsync-stab.partial.mov"),
            settings: StabilizationSettings(smoothing: .high),
            codec: .proResHQ,
            comment: "org.cameratoolkit.stab source=k stab=s"
        )
        let preset = URL(fileURLWithPath: "/tmp/p.gyroflow")
        XCTAssertEqual(
            GyroflowCommand.arguments(input: job.input, presetFile: preset),
            ["/Volumes/Buffer/Trip 2026/C0001.MP4", "-t", "_ctk-stabilizing", "--stdout-progress", "--preset", "/tmp/p.gyroflow"]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: GyroflowCommand.presetData(for: job)) as? [String: Any])
        let stabilization = try XCTUnwrap(object["stabilization"] as? [String: Any])
        XCTAssertEqual(stabilization["method"] as? String, "Default")
        let params = try XCTUnwrap(stabilization["smoothing_params"] as? [[String: Any]])
        XCTAssertEqual(params.first { $0["name"] as? String == "smoothness" }?["value"] as? Double, 0.8)
        XCTAssertEqual(stabilization["horizon_lock_amount"] as? Double, 0, "horizon lock off by default")
        XCTAssertEqual(stabilization["adaptive_zoom_window"] as? Double, 4, "dynamic crop on")
        let output = try XCTUnwrap(object["output"] as? [String: Any])
        XCTAssertEqual(output["codec"] as? String, "ProRes")
        XCTAssertEqual(output["codec_options"] as? String, "HQ", "10-bit 4:2:2, the log signal kept")
        XCTAssertEqual(output["output_path"] as? String, job.output.path)
        XCTAssertNil(output["output_width"], "the clip's own size")
        XCTAssertEqual(output["audio"] as? Bool, true)
        XCTAssertEqual((output["metadata"] as? [String: Any])?["comment"] as? String, job.comment)
        XCTAssertNil(object["trim_ranges_ms"])

        var trimmed = job
        trimmed.trim = 2.5...5.5
        trimmed.codec = .proResProxy
        let short = try XCTUnwrap(JSONSerialization.jsonObject(with: GyroflowCommand.presetData(for: trimmed)) as? [String: Any])
        XCTAssertEqual(short["trim_ranges_ms"] as? [[Double]], [[2500, 5500]])
        XCTAssertEqual((short["output"] as? [String: Any])?["codec_options"] as? String, "Proxy")

        // A path with an apostrophe survives: it is in a file, not inline JSON.
        var quoted = job
        quoted.output = URL(fileURLWithPath: "/Volumes/Buffer/Sam's Trip/x.mov")
        let reread = try XCTUnwrap(JSONSerialization.jsonObject(with: GyroflowCommand.presetData(for: quoted)) as? [String: Any])
        XCTAssertEqual((reread["output"] as? [String: Any])?["output_path"] as? String, "/Volumes/Buffer/Sam's Trip/x.mov")
    }

    func testProgressLinesParse() {
        XCTAssertEqual(GyroflowOutputLine.parse("[0c412d19] Rendering progress: 123/750 frames (16.4%) ETA 12.3s"), .rendering(frame: 123, total: 750))
        XCTAssertEqual(GyroflowOutputLine.parse("[0c412d19] Synchronization progress: 42.5%"), .synchronizing(0.425))
        XCTAssertEqual(GyroflowOutputLine.parse("[0c412d19] Rendering completed: C0001.mov"), .completed)
        XCTAssertEqual(GyroflowOutputLine.parse("[0c412d19] Rendering failed: C0001.mov"), .failed)
        XCTAssertEqual(
            GyroflowOutputLine.parse("03:31:31 [ERROR] [0c412d19] Error: An error occured: Unable to read the video file."),
            .error("Unable to read the video file.")
        )
        XCTAssertEqual(GyroflowOutputLine.parse("03:31:31 [INFO] Loaded 12409 lens profiles in 120ms"), .other)
        XCTAssertTrue(GyroflowOutputLine.explain("Unable to read the video file.").contains("App Store"))
    }

    func testLineSplitterJoinsPartialReadsAndSplitsCarriageReturns() {
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let splitter = LineSplitter { lines.all.append($0) }
        splitter.feed(Data("[a] Rendering progress: 1/4 fr".utf8))
        splitter.feed(Data("ames\r[a] Rendering progress: 2/4 frames\n\nlast".utf8))
        splitter.flush()
        XCTAssertEqual(lines.all, ["[a] Rendering progress: 1/4 frames", "[a] Rendering progress: 2/4 frames", "last"])
    }

    // MARK: Runs

    func testRenderWritesAPartialThenRenamesItInAndReportsProgress() throws {
        try withTemporaryDirectory { root in
            let source = try makeSource(root)
            let runner = FakeRunner(lines: Self.gyroflowOutput)
            let steps = Steps()
            let result = try stabilizer(runner, root: root).render(request(source, root: root), progress: { steps.add($0) })
            guard case .rendered(let url, let beside) = result else { return XCTFail("expected a render, got \(result)") }
            XCTAssertEqual(url.lastPathComponent, "C0001_stab.mov")
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Stabilized")
            XCTAssertTrue(beside.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), Data("movie".utf8))
            XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8), "the original is only read")
            // Gyroflow wrote into a partial in the temporary folder, never the final name.
            let partial = try XCTUnwrap(runner.presetOutputPath)
            XCTAssertTrue(StabilizedRenderNaming.isPartialName((partial as NSString).lastPathComponent))
            XCTAssertTrue(partial.contains("/Stabilized/\(GradedRenderNaming.temporaryFolderName)/"))
            XCTAssertEqual(files(under: url.deletingLastPathComponent()), ["C0001_stab.mov"], "no partial or temporary folder left")
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, Date(timeIntervalSince1970: 1_780_000_000))
            XCTAssertEqual(runner.calls.first?.0.path, Self.installation.executableURL.path)
            XCTAssertEqual(runner.calls.first?.1.first, source.path)
            // Progress only goes up, ends at the last frame.
            let fractions = steps.all.map(\.fraction)
            XCTAssertEqual(fractions, fractions.sorted())
            XCTAssertEqual(steps.all.last?.frame, 4)
            XCTAssertEqual(fractions.last ?? 0, 1, accuracy: 1e-9)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Scratch").path) && !files(under: root.appendingPathComponent("Scratch")).isEmpty, "preset file removed")
        }
    }

    func testATakenNameIsNeverReplaced() throws {
        try withTemporaryDirectory { root in
            let source = try makeSource(root)
            let request = request(source, root: root)
            try FileManager.default.createDirectory(at: request.outputFolder, withIntermediateDirectories: true)
            let other = request.outputFolder.appendingPathComponent("C0001_stab.mov")
            try Data("someone else's file".utf8).write(to: other)
            let result = try stabilizer(FakeRunner(lines: Self.gyroflowOutput), root: root).render(request)
            XCTAssertEqual(result.url.lastPathComponent, "C0001_stab (2).mov")
            XCTAssertEqual(try Data(contentsOf: other), Data("someone else's file".utf8))
        }
    }

    func testStopEndsGyroflowAndDeletesThePartial() throws {
        try withTemporaryDirectory { root in
            let source = try makeSource(root)
            let runner = FakeRunner(lines: Self.gyroflowOutput)
            runner.writesTo = { $0 + ".tmp" } // mid-render, as Gyroflow names it
            let stop = Flag()
            runner.afterLine = { index in if index == 3 { stop.set() } }
            let request = request(source, root: root)
            XCTAssertThrowsError(try stabilizer(runner, root: root).render(request, isCancelled: { stop.isSet })) { error in
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            XCTAssertTrue(runner.ended, "the run was ended from here")
            let partial = try XCTUnwrap(runner.presetOutputPath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial), "partial deleted")
            XCTAssertEqual(files(under: request.outputFolder), [], "no copy, no temporary folder")
        }
    }

    func testAStuckErrorIsEndedAndReportedWithNothingLeft() throws {
        try withTemporaryDirectory { root in
            let source = try makeSource(root)
            let runner = FakeRunner(lines: [
                "03:27:33 [WARN] [add_file]: Unable to read the video file.",
                "03:27:33 [ERROR] [46c2a80c] Error: An error occured: Unable to read the video file.",
            ], writesOutput: nil, waitsToBeEnded: true)
            let request = request(source, root: root)
            XCTAssertThrowsError(try stabilizer(runner, root: root).render(request)) { error in
                guard case Stabilizer.Failure.noOutput(let message) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(message, "Unable to read the video file.")
                XCTAssertTrue(error.localizedDescription.contains("gyroflow.xyz"))
            }
            XCTAssertTrue(runner.ended, "Gyroflow's CLI does not quit after an error; it is ended")
            XCTAssertEqual(files(under: request.outputFolder), [])
        }
    }

    func testAFailedCheckKeepsNothing() throws {
        try withTemporaryDirectory { root in
            let source = try makeSource(root)
            var stabilizer = stabilizer(FakeRunner(lines: Self.gyroflowOutput), root: root)
            stabilizer.verifier = { _, _ in throw Stabilizer.Failure.verification("too short") }
            let request = request(source, root: root)
            XCTAssertThrowsError(try stabilizer.render(request))
            XCTAssertEqual(files(under: request.outputFolder), [])
        }
    }

    func testNoMotionDataNeverRunsGyroflow() throws {
        try withTemporaryDirectory { root in
            let source = try makeSource(root)
            let runner = FakeRunner(lines: Self.gyroflowOutput)
            XCTAssertThrowsError(try stabilizer(runner, root: root, probe: .absent).render(request(source, root: root))) { error in
                XCTAssertEqual(error as? Stabilizer.Failure, .noMotionData)
            }
            XCTAssertTrue(runner.calls.isEmpty)
        }
    }

    func testAppStoreGyroflowIsRefusedBeforeRunning() throws {
        try withTemporaryDirectory { root in
            let source = try makeSource(root)
            var store = Self.installation
            store.isAppStoreBuild = true
            let runner = FakeRunner(lines: Self.gyroflowOutput)
            let stabilizer = Stabilizer(installation: store, runner: runner, verifier: { _, _ in }, probe: { _ in .present(.sony) })
            XCTAssertThrowsError(try stabilizer.render(request(source, root: root))) { error in
                XCTAssertTrue(error.localizedDescription.contains("App Store"))
            }
            XCTAssertTrue(runner.calls.isEmpty)
        }
    }

    func testFindsGyroflowAndTellsTheAppStoreBuildApart() throws {
        try withTemporaryDirectory { root in
            func makeApp(_ folder: String, appStore: Bool, version: String = "1.6.3", bundleID: String = "xyz.gyroflow") throws -> URL {
                let app = root.appendingPathComponent("\(folder)/Gyroflow.app", isDirectory: true)
                let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
                try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
                let binary = macOS.appendingPathComponent("gyroflow")
                try Data("#!/bin/sh\n".utf8).write(to: binary)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                try (["CFBundleShortVersionString": version, "CFBundleIdentifier": bundleID] as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
                if appStore {
                    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
                }
                return app
            }
            XCTAssertNil(GyroflowInstallation.locate(roots: [root], registered: [], isTrusted: { _ in true }))
            XCTAssertEqual(StabilizerAvailability(nil), .notInstalled)
            _ = try makeApp("A", appStore: true)
            let store = try XCTUnwrap(GyroflowInstallation.locate(roots: [root.appendingPathComponent("A")], registered: [], isTrusted: { _ in true }))
            XCTAssertTrue(store.isAppStoreBuild)
            XCTAssertEqual(store.version, "1.6.3")
            XCTAssertEqual(StabilizerAvailability(store), .appStoreBuild(store))
            XCTAssertNotNil(StabilizerAvailability(store).problem)
            _ = try makeApp("B", appStore: false)
            let both = try XCTUnwrap(GyroflowInstallation.locate(roots: [root.appendingPathComponent("A"), root.appendingPathComponent("B")], registered: [], isTrusted: { _ in true }))
            XCTAssertFalse(both.isAppStoreBuild, "the download is preferred when both are installed")
            // Found through LaunchServices only (installed somewhere else),
            // still preferred over the App Store copy in the folders.
            let elsewhere = try makeApp("Elsewhere", appStore: false)
            let viaRegistry = try XCTUnwrap(GyroflowInstallation.locate(roots: [root.appendingPathComponent("A")], registered: [root.appendingPathComponent("A/Gyroflow.app"), elsewhere], isTrusted: { _ in true }))
            XCTAssertEqual(viaRegistry.appURL.standardizedFileURL, elsewhere.standardizedFileURL)
            XCTAssertFalse(viaRegistry.isAppStoreBuild)

            // Never run: an untrusted signature, an old version, a look-alike
            // bundle id, or a copy in the Trash, on a volume, in Downloads.
            XCTAssertTrue(try XCTUnwrap(GyroflowInstallation.locate(roots: [root.appendingPathComponent("A"), root.appendingPathComponent("B")], registered: [], isTrusted: { _ in false })).isAppStoreBuild, "an unsigned download is passed over")
            let old = try makeApp("Old", appStore: false, version: "1.5.4")
            XCTAssertNil(GyroflowInstallation.locate(roots: [], registered: [old], isTrusted: { _ in true }))
            let fake = try makeApp("Fake", appStore: false, bundleID: "com.example.gyroflow")
            XCTAssertNil(GyroflowInstallation.locate(roots: [], registered: [fake], isTrusted: { _ in true }))
            XCTAssertNil(GyroflowInstallation.inspect(appURL: fake))
            let home = FileManager.default.homeDirectoryForCurrentUser
            for excluded in [home.appendingPathComponent(".Trash/Gyroflow.app").path, "/Volumes/Gyroflow/Gyroflow.app", home.appendingPathComponent("Downloads/Gyroflow.app").path,
                             "/private/var/folders/ab/T/AppTranslocation/1234/d/Gyroflow.app", home.appendingPathComponent("Library/Developer/Xcode/DerivedData/G/Gyroflow.app").path] {
                XCTAssertTrue(GyroflowInstallation.isExcludedLocation(URL(fileURLWithPath: excluded)), excluded)
            }
            XCTAssertFalse(GyroflowInstallation.isExcludedLocation(URL(fileURLWithPath: "/Applications/Gyroflow.app")))
            XCTAssertTrue(GyroflowInstallation.isSupportedVersion("1.6.3"))
            XCTAssertTrue(GyroflowInstallation.isSupportedVersion("2.0"))
            XCTAssertFalse(GyroflowInstallation.isSupportedVersion("1.5.4"))
            XCTAssertFalse(GyroflowInstallation.isSupportedVersion(nil))
            XCTAssertTrue(StabilizerAvailability(both).isReady)
        }
    }

    // MARK: Naming

    func testNamingAndTags() {
        let source = URL(fileURLWithPath: "/Volumes/Buffer/C0001.MP4")
        XCTAssertEqual(StabilizedRenderNaming.candidateName(forSource: source, attempt: 1), "C0001_stab.mov")
        XCTAssertEqual(StabilizedRenderNaming.candidateName(forSource: source, attempt: 3), "C0001_stab (3).mov")
        XCTAssertTrue(StabilizedRenderNaming.isStabilizedCopy(URL(fileURLWithPath: "/x/C0001_stab.mov")))
        XCTAssertTrue(StabilizedRenderNaming.isStabilizedCopy(URL(fileURLWithPath: "/x/C0001_stab (2).mov")))
        XCTAssertFalse(StabilizedRenderNaming.isStabilizedCopy(source))
        XCTAssertEqual(StabilizedRenderNaming.outputFolder(editedRoot: URL(fileURLWithPath: "/e/Edited")).path, "/e/Edited/Stabilized")
        let partial = StabilizedRenderNaming.partialName()
        XCTAssertTrue(StabilizedRenderNaming.isPartialName(partial))
        XCTAssertFalse(StabilizedRenderNaming.isPartialName("C0001.mov"))
        XCTAssertTrue(StabilizedRenderNaming.isPartialName(partial + ".tmp"), "Gyroflow's in-progress name")
        XCTAssertFalse(StabilizedRenderNaming.isPartialName("C0001.mov.tmp"))
        XCTAssertFalse(GradedRenderNaming.isPartialName(partial), "the graded exporter never deletes a stabilizer partial")
        XCTAssertTrue(NASSyncPlanner.isJunk(partial), "Sync skips it")
        let settings = StabilizationSettings(smoothing: .low)
        let tag = StabilizedRenderNaming.tag(sourceKey: "C0001.MP4|8|1", settings: settings)
        let parsed = StabilizedRenderNaming.parseTag("Original filename: C0001.MP4\n" + tag)
        XCTAssertEqual(parsed?.source, "C0001.MP4|8|1")
        XCTAssertEqual(parsed?.stabilization, settings.fingerprint)
        XCTAssertNil(StabilizedRenderNaming.parseTag("Original filename: C0001.MP4"))
        XCTAssertNotEqual(StabilizationSettings(smoothing: .low).fingerprint, StabilizationSettings(smoothing: .high).fingerprint)
        XCTAssertEqual(StabilizationSettings.fromCatalogJSON(settings.catalogJSON()), settings)
        XCTAssertEqual(StabilizationSettings.fromCatalogJSON("{}"), StabilizationSettings(), "missing fields read as defaults")
    }

    // MARK: Stabilize, then grade

    func testStabilizedThenGradedReadsTheIntermediateAndCleansItUp() async throws {
        try await withTemporaryDirectoryAsync { root in
            let originals = root.appendingPathComponent("Buffer/2026/2026-06-01 Trip/Originals/A7V", isDirectory: true)
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            let source = originals.appendingPathComponent("C0001.MOV")
            try GradedVideoExporterTests.makeClip(at: source)
            let movie = try Data(contentsOf: source)
            let edited = root.appendingPathComponent("Buffer/2026/2026-06-01 Trip/Edited", isDirectory: true)
            let plain = GradedRenderRequest(
                source: source,
                recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine, range: .full),
                sourceKey: "C0001.MOV|1|1",
                sourceModifiedAt: Date(timeIntervalSince1970: 1_780_000_000),
                outputFolder: GradedRenderNaming.outputFolder(editedRoot: edited)
            )
            var request = plain
            request.stabilization = RenderStabilization(settings: StabilizationSettings(smoothing: .medium))
            let stabilizedTag = try XCTUnwrap(GradedVideoExporter.renderFingerprint(of: request))
            let plainTag = try XCTUnwrap(GradedVideoExporter.renderFingerprint(of: plain))
            XCTAssertNotEqual(stabilizedTag, plainTag, "a stabilized copy has its own name tag")
            XCTAssertEqual(stabilizedTag, plainTag + "|" + StabilizationSettings(smoothing: .medium).fingerprint)
            XCTAssertEqual(plain.stabilizationTag, "", "unstabilized renders are tagged as before")

            // The fake Gyroflow "stabilizes" by writing the clip itself.
            let runner = FakeRunner(lines: Self.gyroflowOutput, writesOutput: movie)
            let stabilizer = stabilizer(runner, root: root)
            let prepared = try StabilizedGradeChain.prepare(request, stabilizer: stabilizer, rangeOf: { _ in .video })
            XCTAssertEqual(prepared.request.decodeSource, prepared.intermediate)
            XCTAssertEqual(prepared.request.decodeRange, .video)
            XCTAssertEqual(prepared.request.source, source, "the original stays the identity")
            XCTAssertTrue(prepared.intermediate.path.contains("/Rec709/\(GradedRenderNaming.temporaryFolderName)/"), "intermediate beside the graded copy, hidden from Sync")

            let exporter = GradedVideoExporter()
            exporter.requireHardwareEncoder = false
            let result = try exporter.render(prepared.request)
            StabilizedGradeChain.cleanUp(prepared)
            guard case .rendered(let url, _) = result else { return XCTFail("expected a render, got \(result)") }
            XCTAssertEqual(url.lastPathComponent, "C0001_709.mov")
            XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.intermediate.path), "intermediate deleted")
            XCTAssertEqual(files(under: url.deletingLastPathComponent()), ["C0001_709.mov"], "one final file")
            XCTAssertEqual(GradedVideoExporter.readTags(url)?.grade, stabilizedTag)
            XCTAssertEqual(GradedVideoExporter.existingRender(of: request), url, "the stabilized render is found again")
            XCTAssertNil(GradedVideoExporter.existingRender(of: plain), "and never taken for an unstabilized one")
            XCTAssertEqual(try Data(contentsOf: source), movie, "the original is only read")
        }
    }

    func testAChainWithoutGyroflowSaysSo() throws {
        var request = GradedRenderRequest(
            source: URL(fileURLWithPath: "/Volumes/Buffer/C0001.MP4"),
            recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine),
            sourceKey: "k", sourceModifiedAt: Date(), outputFolder: URL(fileURLWithPath: "/Volumes/Buffer/Edited/Rec709")
        )
        request.stabilization = RenderStabilization()
        XCTAssertThrowsError(try StabilizedGradeChain.prepare(request, stabilizer: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Gyroflow"))
        }
    }

    // MARK: Motion data probe

    private func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        var size = UInt32(8 + payload.count).bigEndian
        data.append(Data(bytes: &size, count: 4))
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    private func movie(sampleEntries: [String]) -> Data {
        func trak(_ entry: String) -> Data {
            var stsdPayload = Data([0, 0, 0, 0, 0, 0, 0, 1])
            stsdPayload.append(box(entry, Data(repeating: 0, count: 16)))
            let stbl = box("stbl", box("stsd", stsdPayload))
            return box("trak", box("mdia", box("hdlr", Data(repeating: 0, count: 24)) + box("minf", stbl)))
        }
        let moov = box("moov", box("mvhd", Data(repeating: 0, count: 100)) + sampleEntries.map(trak).reduce(Data(), +))
        // The media first, as Sony writes it: the probe seeks over it.
        return box("ftyp", Data("XAVCmp42".utf8)) + box("mdat", Data(repeating: 7, count: 4096)) + moov
    }

    func testProbeFindsSonyAndDJIMotionTracksAndNothingElse() throws {
        try withTemporaryDirectory { root in
            func probe(_ entries: [String]) throws -> MotionDataAvailability {
                let url = root.appendingPathComponent(UUID().uuidString + ".MP4")
                try movie(sampleEntries: entries).write(to: url)
                return MotionDataProbe.probe(url)
            }
            XCTAssertEqual(try probe(["hvc1", "twos", "rtmd"]), .present(.sony))
            XCTAssertEqual(try probe(["avc1", "mp4a", "djmd"]), .present(.dji))
            XCTAssertEqual(try probe(["avc1", "mp4a"]), .absent)
            let junk = root.appendingPathComponent("junk.MP4")
            try Data("not a movie at all".utf8).write(to: junk)
            if case .unknown = MotionDataProbe.probe(junk) {} else { XCTFail("junk is unknown, not absent") }
            if case .unknown = MotionDataProbe.probe(root.appendingPathComponent("missing.MP4")) {} else { XCTFail("missing is unknown") }
        }
    }

    // MARK: Catalog

    func testStabilizationIsSavedPerClipAndAnOlderCatalogGainsTheTable() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            // An older catalog: grades, no stabilization table.
            let queue = try DatabaseQueue(path: catalog.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE color_grades (file_key TEXT PRIMARY KEY, grade TEXT NOT NULL, updated_at TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO color_grades VALUES ('a|1|1', '{}', 'then')")
            }
            try queue.close()
            let store = StabilizationStore(catalogURL: catalog)
            XCTAssertEqual(try store.load(), [:])
            try store.save(["a|1|1": StabilizationSettings(smoothing: .high), "b|2|2": StabilizationSettings()])
            XCTAssertEqual(try store.load(), ["a|1|1": StabilizationSettings(smoothing: .high), "b|2|2": StabilizationSettings()])
            try store.save(["b|2|2": nil, "a|1|1": StabilizationSettings(smoothing: .low, horizonLock: true)])
            XCTAssertEqual(try StabilizationStore(catalogURL: catalog).load(), ["a|1|1": StabilizationSettings(smoothing: .low, horizonLock: true)])
            let grades = try CatalogDatabase.writer(for: catalog).read { db in
                try Row.fetchAll(db, sql: "SELECT file_key, grade, updated_at FROM color_grades").map { "\($0["file_key"] as String)=\($0["grade"] as String)@\($0["updated_at"] as String)" }
            }
            XCTAssertEqual(grades, ["a|1|1={}@then"], "the grades are untouched")
            // An unreadable row is skipped, not fatal.
            try CatalogDatabase.writer(for: catalog).write { db in
                try db.execute(sql: "INSERT INTO clip_stabilization VALUES ('c|3|3', 'garbage', 'now')")
            }
            XCTAssertEqual(try store.load().keys.sorted(), ["a|1|1"])
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testCatalogSchemaIncludesTheStabilizationTable() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            try CatalogStore(url: catalog).prepareSchema()
            let tables = try CatalogDatabase.writer(for: catalog).read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            }
            XCTAssertTrue(tables.contains(StabilizationStore.tableName))
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }
}
