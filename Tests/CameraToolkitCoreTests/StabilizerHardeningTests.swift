@testable import CameraToolkitCore
import Foundation
import XCTest

/// Review fixes: runs never outlive the app, crafted movie headers never
/// crash the probe, strays beside the source are cleaned, sizes are
/// estimated, and an intermediate without a range reads as video range.
final class StabilizerHardeningTests: XCTestCase {
    // MARK: Processes

    /// A stand-in for Gyroflow: prints a progress line, then sleeps.
    private func fakeTool(in root: URL) throws -> URL {
        let tool = root.appendingPathComponent("fake-gyroflow")
        try Data("#!/bin/sh\necho '[1] Rendering progress: 1/100 frames (1.0%) ETA 9.0s'\nsleep 30\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    func testStoppingARunEndsTheGuardAndTheToolAndUnregistersThem() throws {
        try withTemporaryDirectory { root in
            let tool = try fakeTool(in: root)
            final class Seen: @unchecked Sendable { let lock = NSLock(); var lines: [String] = []; var stopAt: Date? }
            let seen = Seen()
            let started = Date()
            let outcome = try FoundationProcessRunner().run(
                executable: tool, arguments: ["x", "-t", GyroflowCommand.scratchSuffix],
                onLine: { line in seen.lock.withLock { seen.lines.append(line) } },
                keepRunning: { Date().timeIntervalSince(started) < 1.5 }
            )
            XCTAssertTrue(outcome.terminated)
            XCTAssertLessThan(Date().timeIntervalSince(started), 8)
            let lines = seen.lock.withLock { seen.lines }
            XCTAssertEqual(lines.first, "[1] Rendering progress: 1/100 frames (1.0%) ETA 9.0s")
            XCTAssertFalse(lines.contains { $0.hasPrefix(FoundationProcessRunner.childPIDPrefix) }, "the guard's pid line is not passed on")
            XCTAssertTrue(StabilizerProcesses.running.isEmpty, "nothing left registered")
            let listing = try psListing()
            XCTAssertFalse(listing.split(separator: "\n").contains { $0.contains(tool.path) && $0.contains("ctk-guard") == false && $0.contains("fake-gyroflow x") }, "no tool left running")
        }
    }

    func testTheGuardEndsTheToolWhenItsParentIsGone() throws {
        try withTemporaryDirectory { root in
            let tool = try fakeTool(in: root)
            let pids = root.appendingPathComponent("guard.out")
            // A stand-in app the test can kill, as a crash would: it starts
            // the guard (its child, with its own pid as the parent) and waits.
            let app = Process()
            app.executableURL = URL(fileURLWithPath: "/bin/sh")
            app.arguments = ["-c", "/bin/sh -c \"$1\" ctk-guard $$ \"$2\" -t \(GyroflowCommand.scratchSuffix) > \"$3\" & wait", "app", FoundationProcessRunner.guardScript, tool.path, pids.path]
            try app.run()
            var childPID: pid_t?
            let deadline = Date().addingTimeInterval(5)
            while childPID == nil, Date() < deadline {
                let text = (try? String(contentsOf: pids, encoding: .utf8)) ?? ""
                if let line = text.split(separator: "\n").first(where: { $0.hasPrefix(FoundationProcessRunner.childPIDPrefix) }) {
                    childPID = pid_t(line.dropFirst(FoundationProcessRunner.childPIDPrefix.count))
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            let child = try XCTUnwrap(childPID)
            Thread.sleep(forTimeInterval: 2.5)
            XCTAssertTrue(isAlive(child), "the tool runs while its app is there")
            kill(app.processIdentifier, SIGKILL)
            app.waitUntilExit()
            let gone = Date().addingTimeInterval(6)
            while isAlive(child), Date() < gone { Thread.sleep(forTimeInterval: 0.1) }
            XCTAssertFalse(isAlive(child), "the tool ended with its app")
        }
    }

    /// A `ps` that fails (empty answer) is not "the app is gone": the
    /// render keeps going until it is really stopped.
    func testAFailingPsNeverStopsAHealthyRun() throws {
        try withTemporaryDirectory { root in
            let tool = try fakeTool(in: root)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for (name, target) in [("sleep", "/bin/sleep"), ("tr", "/usr/bin/tr")] {
                try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent(name).path, withDestinationPath: target)
            }
            let ps = bin.appendingPathComponent("ps")
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: ps)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path)
            let guardProcess = Process()
            guardProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
            guardProcess.arguments = ["-c", FoundationProcessRunner.guardScript, "ctk-guard", String(getpid()), tool.path, "-t", GyroflowCommand.scratchSuffix]
            guardProcess.environment = ["PATH": bin.path]
            let pipe = Pipe()
            guardProcess.standardOutput = pipe
            try guardProcess.run()
            var childPID: pid_t?
            var buffer = ""
            let deadline = Date().addingTimeInterval(5)
            while childPID == nil, Date() < deadline {
                buffer += String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
                if let line = buffer.split(separator: "\n").first(where: { $0.hasPrefix(FoundationProcessRunner.childPIDPrefix) }) {
                    childPID = pid_t(line.dropFirst(FoundationProcessRunner.childPIDPrefix.count))
                }
            }
            let child = try XCTUnwrap(childPID)
            Thread.sleep(forTimeInterval: 3)
            XCTAssertTrue(isAlive(child), "a failed parent check did not stop the run")
            XCTAssertTrue(guardProcess.isRunning)
            guardProcess.terminate()
            guardProcess.waitUntilExit()
            let gone = Date().addingTimeInterval(5)
            while isAlive(child), Date() < gone { Thread.sleep(forTimeInterval: 0.1) }
            XCTAssertFalse(isAlive(child), "Stop still ends it")
        }
    }

    func testLeftoversAreOnlyOrphanedRunsOfThisApp() {
        let listing = """
          101     1 /Applications/Gyroflow.app/Contents/MacOS/gyroflow /Volumes/Buffer/C0001.MP4 -t _ctk-stabilizing --stdout-progress --preset /tmp/x.gyroflow
          201     1 /bin/sh -c parent=$1; shift; ctk-guard 77 /Applications/Gyroflow.app/Contents/MacOS/gyroflow /Volumes/Buffer/C0002.MP4 -t _ctk-stabilizing
          202   201 /Applications/Gyroflow.app/Contents/MacOS/gyroflow /Volumes/Buffer/C0002.MP4 -t _ctk-stabilizing --stdout-progress
          300   900 /bin/sh -c parent=$1; shift; ctk-guard 900 /Applications/Gyroflow.app/Contents/MacOS/gyroflow /Volumes/Buffer/C0003.MP4 -t _ctk-stabilizing
          301   300 /Applications/Gyroflow.app/Contents/MacOS/gyroflow /Volumes/Buffer/C0003.MP4 -t _ctk-stabilizing --stdout-progress
          102   700 /bin/zsh -c grep -E 'MacOS/gyroflow .* -t _ctk-stabilizing' log
          103     1 /Applications/Gyroflow.app/Contents/MacOS/gyroflow /Volumes/Buffer/C0004.MP4 -f
          104   700 /usr/bin/vim notes_ctk.txt
          555     1 /Applications/Gyroflow.app/Contents/MacOS/gyroflow x -t _ctk-stabilizing
        """
        XCTAssertEqual(
            StabilizerProcesses.leftoverPIDs(inListing: listing, own: 555), [101, 201, 202],
            "orphans only: a run another live instance drives (300/301), the person's own Gyroflow, shells, and this process are left alone"
        )
    }

    private func psListing() throws -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Strays beside the source

    func testAStrayDefaultOutputBesideTheSourceIsRemovedButNotAnOlderOne() throws {
        try withTemporaryDirectory { root in
            let folder = root.appendingPathComponent("Originals", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("C0001.MP4")
            try Data("original".utf8).write(to: source)
            let olderStray = folder.appendingPathComponent("C0001_ctk-stabilizing.mov")
            try Data("was already here".utf8).write(to: olderStray)

            final class StrayRunner: StabilizerProcessRunning, @unchecked Sendable {
                let stray: URL
                init(stray: URL) { self.stray = stray }
                func run(executable: URL, arguments: [String], onLine: @escaping @Sendable (String) -> Void, keepRunning: @escaping @Sendable () -> Bool) throws -> StabilizerProcessOutcome {
                    try Data("misplaced".utf8).write(to: stray)
                    onLine("03:00:00 [ERROR] [1] Error: An error occured: something")
                    return StabilizerProcessOutcome(exitCode: 0, terminated: false)
                }
            }
            let newStray = folder.appendingPathComponent("C0001_ctk-stabilizing.mp4")
            let stabilizer = Stabilizer(
                installation: StabilizerTests.installation, runner: StrayRunner(stray: newStray), errorGrace: 0.1,
                verifier: { _, _ in }, probe: { _ in .present(.sony) }, scratchFolder: root.appendingPathComponent("Scratch")
            )
            XCTAssertThrowsError(try stabilizer.stabilize(source: source, settings: StabilizationSettings(), into: root.appendingPathComponent("Edited/Stabilized")))
            XCTAssertFalse(FileManager.default.fileExists(atPath: newStray.path), "the stray this run made is gone")
            XCTAssertEqual(try Data(contentsOf: olderStray), Data("was already here".utf8), "a file that was already there is never touched")
            XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        }
    }

    // MARK: Sizes

    func testProResSizeEstimateMatchesWhatGyroflowWrote() throws {
        // Measured: a 12.5 s 3840×2160 59.94 fps clip became a 2.61 GB ProRes HQ file.
        let estimate = try XCTUnwrap(Stabilizer.estimatedBytes(width: 3840, height: 2160, fps: 59.94, seconds: 12.5, codec: .proResHQ))
        XCTAssertEqual(Double(estimate), 2.61e9, accuracy: 0.4e9)
        let minuteOfUHD = try XCTUnwrap(Stabilizer.estimatedBytes(width: 3840, height: 2160, fps: 59.94, seconds: 60, codec: .proResHQ))
        XCTAssertGreaterThan(minuteOfUHD, 10_000_000_000, "about 13 GB a minute at UHD 60p")
        XCTAssertLessThan(try XCTUnwrap(Stabilizer.estimatedBytes(width: 3840, height: 2160, fps: 59.94, seconds: 3, codec: .proResProxy)), 200_000_000)
        XCTAssertNil(Stabilizer.estimatedBytes(width: 0, height: 0, fps: 30, seconds: 1, codec: .proResHQ))
        XCTAssertNil(Stabilizer.estimatedBytes(width: 1920, height: 1080, fps: 30, seconds: .nan, codec: .proResHQ))
    }

    // MARK: Ranges

    func testAnIntermediateWithoutARangeIsReadAsVideoRange() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("C0001.MP4")
            try Data("x".utf8).write(to: source)
            var request = GradedRenderRequest(
                source: source,
                recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine, range: .full),
                sourceKey: "k", sourceModifiedAt: Date(), outputFolder: root.appendingPathComponent("Edited/Rec709")
            )
            request.stabilization = RenderStabilization()
            let runner = StabilizerTests.FakeRunner(lines: StabilizerTests.gyroflowOutput)
            let stabilizer = Stabilizer(installation: StabilizerTests.installation, runner: runner, verifier: { _, _ in }, probe: { _ in .present(.sony) }, scratchFolder: root.appendingPathComponent("Scratch"))
            stabilizer.finishGrace = 0.1
            let prepared = try StabilizedGradeChain.prepare(request, stabilizer: stabilizer, rangeOf: { _ in nil })
            defer { StabilizedGradeChain.cleanUp(prepared) }
            XCTAssertEqual(prepared.request.decodeRange, .video, "what Gyroflow writes, not the original's full range")
            XCTAssertEqual(prepared.request.recipe.range, .full, "the tags keep the original's recipe")
        }
    }

    // MARK: Crafted headers

    private func box(_ type: String, _ payload: Data, size: UInt32? = nil) -> Data {
        var out = Data()
        var value = (size ?? UInt32(8 + payload.count)).bigEndian
        out.append(Data(bytes: &value, count: 4))
        out.append(Data(type.utf8))
        out.append(payload)
        return out
    }

    private func largeBox(_ type: String, size: UInt64, payload: Data) -> Data {
        var out = Data()
        var one = UInt32(1).bigEndian
        out.append(Data(bytes: &one, count: 4))
        out.append(Data(type.utf8))
        var large = size.bigEndian
        out.append(Data(bytes: &large, count: 8))
        out.append(payload)
        return out
    }

    private func probe(_ data: Data, in root: URL) throws -> MotionDataAvailability {
        let url = root.appendingPathComponent(UUID().uuidString + ".MP4")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return MotionDataProbe.probe(url)
    }

    func testCraftedBoxSizesNeverCrashAndReadAsUnknown() throws {
        try withTemporaryDirectory { root in
            let ftyp = box("ftyp", Data("XAVCmp42".utf8))
            // Top level: a 64-bit size near the maximum, then one past the file.
            for size in [UInt64.max, UInt64.max - 7, UInt64(Int.max), 1 << 62] {
                if case .present = try probe(ftyp + largeBox("mdat", size: size, payload: Data(count: 32)), in: root) { XCTFail("size \(size)") }
                if case .present = try probe(ftyp + largeBox("moov", size: size, payload: Data(count: 32)), in: root) { XCTFail("size \(size)") }
            }
            // Inside moov: children bigger than their parent, huge 64-bit sizes, a short stsd.
            let stsdHuge = box("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + box("rtmd", Data(count: 4), size: UInt32.max))
            let nestedHuge = box("trak", largeBox("mdia", size: UInt64.max, payload: Data(count: 8)))
            for inner in [box("trak", box("mdia", Data(count: 4), size: 4096)), nestedHuge, box("trak", box("mdia", box("minf", box("stbl", stsdHuge)))), box("trak", box("stsd", Data(count: 3)))] {
                let answer = try probe(ftyp + box("moov", inner), in: root)
                if case .unknown = answer {} else { XCTFail("damaged header should be unknown, got \(answer)") }
            }
            // Fuzz: random bytes flipped in a good header never crash.
            var stsd = Data([0, 0, 0, 0, 0, 0, 0, 1])
            stsd.append(box("rtmd", Data(count: 16)))
            let good = ftyp + box("mdat", Data(count: 256)) + box("moov", box("trak", box("mdia", box("minf", box("stbl", box("stsd", stsd))))))
            XCTAssertEqual(try probe(good, in: root), .present(.sony))
            var generator = SystemRandomNumberGenerator()
            let url = root.appendingPathComponent("fuzz.MP4")
            for _ in 0..<1500 {
                var mutated = good
                for _ in 0..<Int.random(in: 1...6, using: &generator) {
                    mutated[Int.random(in: 0..<mutated.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
                try mutated.write(to: url)
                _ = MotionDataProbe.probe(url)
            }
        }
    }
}
