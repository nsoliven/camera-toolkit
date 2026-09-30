import AppKit
import CameraToolkitCore
import Darwin
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os
import XCTest
@testable import CameraToolkitApp

// Scroll-smoothness measurement for the open board, in the real main window
// on a real display. Opt-in: it skips unless `CT_SCROLL_PERF_OUT` names a
// scratch folder for its results, and it needs an awake display.
//
// Build once, then run it in a sandbox that cannot write the real
// Application Support folder or any volume, with a scratch home:
//
//     swift build --build-tests -c release -Xswiftc -enable-testing
//     CFFIXED_USER_HOME=$SCRATCH/home CT_SCROLL_PERF_OUT=$SCRATCH/run1 CT_DRIVER=link \
//       CT_SCENARIOS=tiles1500,list1500,job10 \
//       sandbox-exec -f perf.sb xcrun xctest -XCTest BoardScrollPerfTests/testScrollPerf \
//       .build/arm64-apple-macosx/release/CameraToolkitPackageTests.xctest
//
// where perf.sb is `(version 1) (allow default)` plus `(deny file-write*
// (subpath "<real Application Support>/CameraToolkit"))` and denials of
// reads and writes under `/Volumes`.
//
// Environment:
// - `CT_DRIVER=link`: a display link drives the scroll and its vsync stamps
//   are the frame record (needs an awake display). Without it a 120 Hz timer
//   drives the scroll and forces a frame each step.
// - `CT_SCENARIOS`: comma list of tiles1500, tiles4000, deepwarm1500,
//   deep1500, cold1500, cold4000, list1500, listdeepwarm1500, job10, job60,
//   jobonly10, jobonly60. Default: the whole set the pass criteria cover.
// - `CT_SCROLL_NAS=1`: the library lives on the NAS stand-in with the Buffer
//   empty (the usual case: the Buffer is unplugged), main-thread stats are
//   counted and every stat on it costs `CT_STAT_MS` (default 5), every read
//   `CT_READ_MS` (default 60), like an SMB round trip.
// - `CT_SECONDS` (6), `CT_LIB_DIR` (keep the generated JPEGs between runs),
//   `CT_LIB_SCALE`, `CT_TILE_WIDTH`, `CT_PROFILE` (scenarios to sample).
// - `CT_PERF_BUDGETS=1`: enforce the pass criteria as assertions (quiet
//   machine, release build). The body and stat counters are asserted always.
//
// Fixture names are neutral on purpose: this repository is public.

final class PerfWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

final class PerfLog: @unchecked Sendable {
    let handle: FileHandle
    init(_ url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try! FileHandle(forWritingTo: url)
    }
    func callAsFunction(_ s: String) {
        let stamp = String(format: "%.3f", CACurrentMediaTime())
        let data = Data(("[" + stamp + "] " + s + "\n").utf8)
        FileHandle.standardError.write(data)
        handle.write(data)
    }
}

/// Counts what the loader's injected hooks see: stats issued on the main
/// thread (the thing that must never happen while scrolling) and the delay
/// standing in for a network round trip.
final class ScrollLoaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _mainStats = 0
    private var _backgroundStats = 0
    let statDelayMicroseconds: UInt32
    let readDelayMicroseconds: UInt32
    let marker: String

    init(marker: String, statMs: Double, readMs: Double) {
        self.marker = marker
        statDelayMicroseconds = UInt32(statMs * 1_000)
        readDelayMicroseconds = UInt32(readMs * 1_000)
    }

    var mainStats: Int { lock.withLock { _mainStats } }
    var backgroundStats: Int { lock.withLock { _backgroundStats } }
    func reset() { lock.withLock { _mainStats = 0; _backgroundStats = 0 } }

    func stat(_ path: String) -> Bool {
        let onMain = Thread.isMainThread
        lock.withLock { if onMain { _mainStats += 1 } else { _backgroundStats += 1 } }
        if path.hasPrefix(marker), statDelayMicroseconds > 0 { usleep(statDelayMicroseconds) }
        return FileManager.default.fileExists(atPath: path)
    }

    func read(_ url: URL) {
        if url.path.hasPrefix(marker), readDelayMicroseconds > 0 { usleep(readDelayMicroseconds) }
    }
}

/// Main-runloop busy segments (afterWaiting to beforeWaiting) and the
/// synchronous cost of each scroll step.
@MainActor
final class FrameRecorder: NSObject {
    var steps: [(start: CFTimeInterval, cost: CFTimeInterval)] = []
    var segments: [(CFTimeInterval, CFTimeInterval)] = []
    private var segStart: CFTimeInterval = 0
    private var observer: CFRunLoopObserver?
    var recording = false

    func install() {
        let mask = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let obs = CFRunLoopObserverCreateWithHandler(nil, mask, true, CFIndex(Int.max)) { [weak self] _, activity in
            let t = CACurrentMediaTime()
            MainActor.assumeIsolated {
                guard let self else { return }
                if activity == .afterWaiting { self.segStart = t }
                else if self.recording, self.segStart > 0 { self.segments.append((self.segStart, t)) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        observer = obs
    }

    var linkStamps: [CFTimeInterval] = []
    var onTick: ((CADisplayLink) -> Void)?

    @objc func tick(_ link: CADisplayLink) {
        if recording { linkStamps.append(link.timestamp) }
        onTick?(link)
    }

    func reset() { steps = []; segments = []; linkStamps = [] }
}

struct ScenarioResult: Codable {
    var name: String
    var seconds: Double
    var steps: Int
    var stepsPerSecond: Double
    var costP50: Double, costP95: Double, costP99: Double, costMax: Double
    var over8: Int, over16: Int
    var intervalP50: Double, intervalP99: Double, intervalMax: Double
    var missedFrames: Int; var hitch1: Int; var hitch2: Int
    var windowBusyP50: Double, windowBusyP99: Double, windowBusyMax: Double
    var windowsOver: Int
    var longestSegments: [Double]
    var mainBusyFraction: Double
    var load: Double
    var mainStats: Int
    var bodies: [String: Int]
}

@MainActor
final class BoardScrollPerfTests: XCTestCase {
    var log: PerfLog!
    var window: NSWindow!

    func testScrollPerf() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outPath = env["CT_SCROLL_PERF_OUT"] else { throw XCTSkip("set CT_SCROLL_PERF_OUT to run the scroll measurement") }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        log = PerfLog(out.appendingPathComponent("log.txt"))
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled], reason: "board scroll measurement")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        log("pid \(getpid()) home \(NSHomeDirectory()) screen fps \(NSScreen.main?.maximumFramesPerSecond ?? -1) display asleep \(asleep) load \(loadAverage())")
        if env["CT_DRIVER"] == "link", asleep { throw XCTSkip("CT_DRIVER=link needs an awake display") }
        for key in ["CameraToolkit.organize.mode", "CameraToolkit.organize.tileWidth", "CameraToolkit.organize.showInspector",
                    "CameraToolkit.organize.sidebarWidth", "CameraToolkit.eventboard.grouping"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if let w = env["CT_TILE_WIDTH"], let v = Double(w) { UserDefaults.standard.set(v, forKey: "CameraToolkit.organize.tileWidth") }

        let onNAS = env["CT_SCROLL_NAS"] != nil
        let t0 = CACurrentMediaTime()
        let lib = try ScrollLibrary.make(log: log, onNAS: onNAS)
        log("library built in \(String(format: "%.1f", CACurrentMediaTime() - t0)) s, files \(lib.fileCount), on NAS \(onNAS)")
        defer { lib.tearDown() }

        // The loader every tile uses: it counts main-thread stats, and on the
        // NAS stand-in charges each stat and read like a network round trip.
        let probe = ScrollLoaderProbe(
            marker: lib.workspace.locations.nasRoot.path,
            statMs: onNAS ? (Double(env["CT_STAT_MS"] ?? "") ?? 5) : 0,
            readMs: onNAS ? (Double(env["CT_READ_MS"] ?? "") ?? 60) : 0
        )
        let originalLoader = TileImageLoader.shared
        TileImageLoader.shared = TileImageLoader(
            fileExists: { probe.stat($0) },
            willRead: { probe.read($0) }
        )
        defer { TileImageLoader.shared = originalLoader }

        window = MainWindowFactory.make(model: lib.model, workspace: lib.workspace, restoresFrame: false) { rect, style in
            PerfWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        }
        let screen = NSScreen.main!
        let size = NSSize(width: min(1500, screen.visibleFrame.width - 40), height: min(960, screen.visibleFrame.height - 60))
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        lib.workspace.selection = .event(lib.parentID)
        let loadStart = CACurrentMediaTime()
        try await waitUntil(timeout: 600) {
            (lib.workspace.eventStacks[lib.parentID]?.count ?? 0) > 100
                && lib.workspace.presence[lib.parentID] != nil
                && lib.workspace.eventBuildRemainders[lib.parentID] == nil
                && lib.workspace.eventDateReadRemainders[lib.parentID] == nil
        }
        log("board loaded in \(String(format: "%.1f", CACurrentMediaTime() - loadStart)) s: stacks \(lib.workspace.eventStacks[lib.parentID]?.count ?? -1) occlusion \(window.occlusionState.rawValue)")
        try await settle(2)

        let recorder = FrameRecorder()
        recorder.install()

        var scroll = try boardScrollView(window)
        log("board scroll view \(type(of: scroll)) doc height \(scroll.documentView?.frame.height ?? -1) flipped \(scroll.documentView?.isFlipped ?? false) clip \(scroll.contentView.bounds) insets \(scroll.contentInsets)")

        let warmRange = Double(env["CT_WARM_RANGE"] ?? "") ?? 5_000
        try await warm(scroll, range: warmRange)

        let defaultScenarios = onNAS ? "cold1500,cold4000,deep1500" : "tiles1500,tiles4000,deepwarm1500,deep1500,list1500,listdeepwarm1500,job10,jobonly60"
        let scenarios = (env["CT_SCENARIOS"] ?? defaultScenarios).split(separator: ",").map(String.init)
        let seconds = Double(env["CT_SECONDS"] ?? "") ?? 6
        var results: [ScenarioResult] = []
        for name in scenarios {
            if name.hasPrefix("list"), UserDefaults.standard.string(forKey: "CameraToolkit.organize.mode") != "list" {
                UserDefaults.standard.set("list", forKey: "CameraToolkit.organize.mode")
                try await settle(2)
                scroll = try boardScrollView(window)
                try await warm(scroll, range: warmRange)
            }
            var velocity = 1_500.0
            if name.hasSuffix("4000") { velocity = 4_000 }
            if name.hasPrefix("jobonly") { velocity = 0 }
            var range = warmRange
            var start = 0.0
            if name.contains("deepwarm") {
                start = 150_000; range = 5_000
                try await warm(scroll, range: 5_000, from: 150_000)
            } else if name.contains("deep") {
                start = 150_000; range = 1e9
            }
            if name.hasPrefix("cold") { start = warmRange + (velocity > 2_000 ? 40_000 : 2_000); range = 1e9 }
            let loadName = name.hasPrefix("jobonly") ? "job" + name.dropFirst(7) : name
            let stopLoad = startLoad(for: loadName, lib: lib)
            try await settle(0.5)
            let isProfile = (env["CT_PROFILE"] ?? "").split(separator: ",").contains(Substring(name))
            probe.reset()
            BoardRenderCounter.reset()
            if isProfile { log("PROFILE START \(name)") }
            var r = try await run(name: name, recorder: recorder, scroll: scroll, velocity: velocity, start: start, range: range,
                                  seconds: isProfile ? (Double(env["CT_PROFILE_SECONDS"] ?? "") ?? 20) : seconds)
            if isProfile { log("PROFILE END \(name)") }
            stopLoad()
            r.load = loadAverage()
            r.mainStats = probe.mainStats
            r.bodies = Dictionary(uniqueKeysWithValues: BoardRenderCounter.Kind.allCases.map { ($0.rawValue, BoardRenderCounter.count($0)) })
            results.append(r)
            log("\(name): load \(String(format: "%.1f", r.load)) main-thread stats \(r.mainStats) (background \(probe.backgroundStats)) bodies \(r.bodies.sorted { $0.key < $1.key }.map { $0.key + "=" + String($0.value) })")
            log(describe(r))
            try await settle(1)
        }
        let data = try JSONEncoder().encode(results)
        try data.write(to: out.appendingPathComponent("results.json"))

        // Deterministic criteria, always asserted.
        for r in results {
            XCTAssertEqual(r.mainStats, 0, "\(r.name): the tile path stat a file on the main thread")
            for kind in ["board", "grid", "storageStrip"] {
                XCTAssertEqual(r.bodies[kind, default: 0], 0, "\(r.name): \(kind) bodies ran while only scrolling or ticking progress")
            }
        }
        // Timing criteria, on a quiet machine in a release build.
        if env["CT_PERF_BUDGETS"] == "1" {
            for r in results {
                let scrolling = !r.name.hasPrefix("jobonly")
                XCTAssertGreaterThanOrEqual(r.stepsPerSecond, 119, "\(r.name): frames per second (load \(r.load))")
                if scrolling {
                    XCTAssertLessThanOrEqual(r.intervalP99, 8.4, "\(r.name): p99 frame interval")
                }
                XCTAssertEqual(r.hitch2, 0, "\(r.name): frames that missed two vsyncs")
                XCTAssertLessThanOrEqual(r.hitch1, 4, "\(r.name): frames that missed a vsync")
            }
        }
    }

    // MARK: - Load generators

    func startLoad(for name: String, lib: ScrollLibrary) -> () -> Void {
        let model = lib.model
        guard name.hasPrefix("job") else { return {} }
        let hz = Double(name.dropFirst(3)) ?? 10
        let jobID = UUID()
        model.jobs.insert(JobSnapshot(id: jobID, action: .faceScan, state: .running, progress: 0.02, note: "Scanning for faces"), at: 0)
        model.isBusy = true
        let stop = OSAllocatedUnfairLock(initialState: false)
        let progress = model.jobProgressHandler(jobID: jobID)
        let thread = Thread {
            var n = 0
            while !stop.withLock({ $0 }) {
                n += 1
                let update = BackgroundJobUpdate(
                    progress: Double(n % 4700) / 4700, note: "Face scan: \(n) of 4,700 photos", phase: "scanning",
                    detail: "", command: "", sourcePath: nil, destinationPath: nil, currentPath: "/x/Originals/DSC\(n).JPG",
                    processedFiles: n, totalFiles: 4_700, processedBytes: Int64(n) * 12_000_000, totalBytes: 56_000_000_000,
                    bytesPerSecond: 120_000_000, telemetry: nil)
                // The same hop the job runner's progress handler makes.
                progress(update)
                usleep(UInt32(1_000_000 / hz))
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
        return {
            stop.withLock { $0 = true }
            model.jobs.removeAll { $0.id == jobID }
            model.isBusy = false
        }
    }

    // MARK: - Scrolling

    func boardScrollView(_ window: NSWindow) throws -> NSScrollView {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let views = all(window.contentView!.superview!).compactMap { $0 as? NSScrollView }
        for v in views { log("scrollview \(type(of: v)) doc \(v.documentView.map { "\(type(of: $0)) \($0.frame.size)" } ?? "nil")") }
        return try XCTUnwrap(views.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
    }

    func setOffset(_ scroll: NSScrollView, _ y: Double) {
        let clip = scroll.contentView
        guard let doc = scroll.documentView else { return }
        let top = -scroll.contentInsets.top
        let maxY = max(top, doc.frame.height - clip.bounds.height + scroll.contentInsets.bottom)
        let target = min(max(top, top + y), maxY)
        let flippedY = doc.isFlipped ? target : doc.frame.height - clip.bounds.height - target
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: flippedY))
        scroll.reflectScrolledClipView(clip)
    }

    /// What the display cycle does once per frame on a visible window:
    /// layout (the SwiftUI graph update), display, and the CA commit.
    func forceFrame() {
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    func warm(_ scroll: NSScrollView, range: Double, from: Double = 0) async throws {
        let t = CACurrentMediaTime()
        var y = from
        while y <= from + range + 1_200 {
            setOffset(scroll, y)
            forceFrame()
            try await settle(0.25)
            y += 350
        }
        setOffset(scroll, from)
        forceFrame()
        try await settle(1.5)
        log("warmed \(Int(from))...\(Int(from + range)) in \(String(format: "%.1f", CACurrentMediaTime() - t)) s; doc height \(scroll.documentView?.frame.height ?? -1)")
    }

    func run(name: String, recorder: FrameRecorder, scroll: NSScrollView, velocity: Double, start: Double, range: Double, seconds: Double) async throws -> ScenarioResult {
        setOffset(scroll, start)
        forceFrame()
        try await settle(0.8)
        // The warm-up and settling above draw tiles too; the counters cover
        // the measured run only.
        BoardRenderCounter.reset()
        let signposter = OSSignposter(subsystem: "ct.scrollperf", category: .pointsOfInterest)
        let state = signposter.beginInterval("scenario", id: signposter.makeSignpostID(), "\(name)")
        recorder.reset()
        recorder.recording = true
        let begin = CACurrentMediaTime()
        let offset: (CFTimeInterval) -> Double = { t in
            let travel = velocity * (t - begin)
            if range > 1e8 { return start + travel }
            let phase = travel.truncatingRemainder(dividingBy: 2 * range)
            return start + (phase <= range ? phase : 2 * range - phase)
        }
        if ProcessInfo.processInfo.environment["CT_DRIVER"] == "link" {
            let link = window.contentView!.displayLink(target: recorder, selector: #selector(FrameRecorder.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            recorder.onTick = { [weak self] link in
                guard let self else { return }
                let t = CACurrentMediaTime()
                self.setOffset(scroll, offset(link.targetTimestamp))
                recorder.steps.append((t, CACurrentMediaTime() - t))
            }
            link.add(to: .main, forMode: .common)
            try await settle(seconds)
            link.invalidate()
            recorder.onTick = nil
        } else {
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .nanoseconds(0))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let t = CACurrentMediaTime()
                    self.setOffset(scroll, offset(t))
                    self.forceFrame()
                    recorder.steps.append((t, CACurrentMediaTime() - t))
                }
            }
            timer.resume()
            try await settle(seconds)
            timer.cancel()
        }
        recorder.recording = false
        signposter.endInterval("scenario", state)
        return summarize(name, recorder, seconds: seconds)
    }

    // MARK: - Stats

    func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads[0]
    }

    func pct(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[min(s.count - 1, Int((p / 100) * Double(s.count - 1)))]
    }

    func summarize(_ name: String, _ r: FrameRecorder, seconds: Double) -> ScenarioResult {
        let period = 1.0 / 120
        let steps = r.steps
        let costs = steps.map { $0.cost }
        var intervals: [Double] = []
        var missed = 0; var hitch1 = 0; var hitch2 = 0
        // Vsync timestamps when a display link drove the run, otherwise the
        // timer step start times.
        let stamps = r.linkStamps.isEmpty ? steps.map { $0.start } : r.linkStamps
        if stamps.count > 1 {
            for i in 1..<stamps.count {
                let dt = stamps[i] - stamps[i - 1]
                intervals.append(dt)
                let skipped = max(0, Int((dt / period).rounded()) - 1); missed += skipped; if skipped >= 1 { hitch1 += 1 }; if skipped >= 2 { hitch2 += 1 }
            }
        }
        // Main-thread busy time in each 8.33 ms window of the run.
        let segs = r.segments
        let t0 = steps.first?.start ?? 0
        let t1 = steps.last?.start ?? 0
        var windows: [Double] = []
        var w = t0
        var j = 0
        while w < t1 {
            let e = w + period
            var sum = 0.0
            while j < segs.count, segs[j].1 < w { j += 1 }
            var k = j
            while k < segs.count, segs[k].0 < e {
                sum += max(0, min(segs[k].1, e) - max(segs[k].0, w))
                k += 1
            }
            windows.append(sum)
            w = e
        }
        let longest = segs.map { $0.1 - $0.0 }.sorted(by: >).prefix(8).map { ($0 * 10_000).rounded() / 10 }
        let totalBusy = segs.reduce(0) { $0 + ($1.1 - $1.0) }
        let span = max(t1 - t0, 1e-6)
        return ScenarioResult(
            name: name, seconds: seconds, steps: steps.count, stepsPerSecond: Double(max(steps.count - 1, 0)) / span,
            costP50: pct(costs, 50) * 1000, costP95: pct(costs, 95) * 1000, costP99: pct(costs, 99) * 1000, costMax: (costs.max() ?? 0) * 1000,
            over8: costs.filter { $0 > period }.count, over16: costs.filter { $0 > 2 * period }.count,
            intervalP50: pct(intervals, 50) * 1000, intervalP99: pct(intervals, 99) * 1000, intervalMax: (intervals.max() ?? 0) * 1000,
            missedFrames: missed, hitch1: hitch1, hitch2: hitch2,
            windowBusyP50: pct(windows, 50) * 1000, windowBusyP99: pct(windows, 99) * 1000, windowBusyMax: (windows.max() ?? 0) * 1000,
            windowsOver: windows.filter { $0 > period * 0.999 }.count,
            longestSegments: Array(longest), mainBusyFraction: totalBusy / span, load: 0, mainStats: 0, bodies: [:])
    }

    func describe(_ r: ScenarioResult) -> String {
        String(format: "%@: steps %d (%.1f/s) | step cost p50 %.2f p95 %.2f p99 %.2f max %.1f ms, >8.3ms %d, >16.7ms %d | step interval p50 %.2f p99 %.2f max %.1f ms, missed %d, hitches>=1 %d, hitches>=2 %d | main busy %.0f%% | longest %@",
               r.name, r.steps, r.stepsPerSecond, r.costP50, r.costP95, r.costP99, r.costMax, r.over8, r.over16,
               r.intervalP50, r.intervalP99, r.intervalMax, r.missedFrames, r.hitch1, r.hitch2, r.mainBusyFraction * 100,
               r.longestSegments.map { String($0) }.joined(separator: ","))
    }

    func settle(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("timeout"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// The MoveLibrary shape (a 15,610-file family, bursts of 8 every third
/// group), with real decodable JPEGs as APFS clones of a few masters, in the
/// Buffer's `Originals/<Camera>` or — with `onNAS` — only on the NAS
/// stand-in, the Buffer being unplugged. `CT_LIB_DIR` keeps the media
/// between runs so a run does not churn 17k files.
@MainActor
struct ScrollLibrary {
    let root: URL
    let model: DashboardModel
    let workspace: EventsWorkspace
    let parentID: UUID
    let fileCount: Int

    func tearDown() {
        CatalogDatabase.checkpointAndClose(url: root.appendingPathComponent("CameraToolkit/catalog.sqlite"))
        if ProcessInfo.processInfo.environment["CT_LIB_DIR"] == nil {
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func existingMasters(in folder: URL) throws -> [(URL, Int64)] {
        try (0..<48).map { m in
            let url = folder.appendingPathComponent(String(format: "master%02d.jpg", m))
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return (url, size)
        }
    }

    static func makeMasters(in folder: URL, count: Int) throws -> [(URL, Int64)] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var result: [(URL, Int64)] = []
        let width = 1800, height = 1200
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var rng = SystemRandomNumberGenerator()
        for m in 0..<count {
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let hue = Double(m) / Double(count)
            let top = NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor
            let bottom = NSColor(hue: (hue + 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.3, alpha: 1).cgColor
            let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            for _ in 0..<60 {
                ctx.setFillColor(NSColor(hue: Double.random(in: 0...1, using: &rng), saturation: 0.5, brightness: 0.8, alpha: 0.5).cgColor)
                let r = Double.random(in: 20...300, using: &rng)
                ctx.fillEllipse(in: CGRect(x: Double.random(in: 0...Double(width), using: &rng), y: Double.random(in: 0...Double(height), using: &rng), width: r, height: r * 0.7))
            }
            // Grain, so the JPEGs have realistic entropy.
            if let data = ctx.data {
                let p = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
                for i in 0..<(ctx.bytesPerRow * height) where i % 4 != 3 {
                    p[i] = p[i] &+ UInt8.random(in: 0...12, using: &rng)
                }
            }
            let image = ctx.makeImage()!
            let url = folder.appendingPathComponent(String(format: "master%02d.jpg", m))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(dest)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            result.append((url, size))
        }
        return result
    }

    static func make(log: PerfLog, onNAS: Bool) throws -> ScrollLibrary {
        let persistent = ProcessInfo.processInfo.environment["CT_LIB_DIR"]
        let base = persistent.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CTScrollPerf-\(UUID().uuidString)", isDirectory: true)
        let root = base.resolvingSymlinksInPath()
        let readyURL = root.appendingPathComponent(onNAS ? "ready-nas" : "ready")
        let ready = FileManager.default.fileExists(atPath: readyURL.path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let support = root.appendingPathComponent("CameraToolkit", isDirectory: true)
        try? FileManager.default.removeItem(at: support)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("Support"))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let masterFolder = root.appendingPathComponent("masters")
        let masters = FileManager.default.fileExists(atPath: masterFolder.appendingPathComponent("master47.jpg").path)
            ? try existingMasters(in: masterFolder) : try makeMasters(in: masterFolder, count: 48)
        log("masters: \(masters.count), sizes \(masters.prefix(3).map { $0.1 }), files reused \(ready)")
        var configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Safety Test").path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: root.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: root.appendingPathComponent("Library").path,
            catalogDatabasePath: support.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path,
            selectedDeviceID: "sony-a7v"
        )
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_772_000_000))
        let parent = SavedCameraEvent(name: "Trip 2026", eventDate: day, storagePolicy: .buffer)
        let partA = SavedCameraEvent(name: "Part A", eventDate: day, storagePolicy: .buffer, parentEventID: parent.id)
        let partB = SavedCameraEvent(name: "Part B", eventDate: day.addingTimeInterval(4 * 86_400), storagePolicy: .buffer, parentEventID: parent.id)
        let partC = SavedCameraEvent(name: "Part C", eventDate: day.addingTimeInterval(9 * 86_400), storagePolicy: .buffer, parentEventID: parent.id)
        let elsewhere = SavedCameraEvent(name: "Other Trip", eventDate: day.addingTimeInterval(30 * 86_400), storagePolicy: .buffer)
        configuration.savedEvents = [parent, partA, partB, partC, elsewhere]
        let locations = EventStorageLocations(configuration: configuration)
        let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
        var assignments: [PhotoEventAssignment] = []
        var frame = 0, burst = 0, total = 0
        let fm = FileManager.default
        let scale = Double(ProcessInfo.processInfo.environment["CT_LIB_SCALE"] ?? "") ?? 1
        for (event, baseCount) in [(parent, 9_846), (partA, 1_931), (partB, 3_673), (partC, 160), (elsewhere, 1_390)] {
            let count = Int(Double(baseCount) * scale)
            let folder = onNAS
                ? locations.nasOriginalsRoot(for: event, deviceID: "sony-a7v")
                : locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            if !ready { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            var made = 0, group = 0
            while made < count {
                let isBurst = group % 3 == 0
                let size = isBurst ? min(8, count - made) : 1
                burst += isBurst ? 1 : 0
                for index in 0..<size {
                    frame += 1
                    let name = isBurst ? String(format: "B%04d_DSC%05d.JPG", burst, frame) : String(format: "DSC%05d.JPG", frame)
                    let dayIndex = (made + index) * 6 / max(count, 1)
                    let modifiedAt = event.eventDate.addingTimeInterval(Double(dayIndex) * 86_400 + 8 * 3_600 + Double(made + index) * 2)
                    let master = masters[frame % masters.count]
                    let dest = folder.appendingPathComponent(name)
                    if !ready {
                        guard clonefile(master.0.path, dest.path, 0) == 0 else { throw NSError(domain: "clone", code: Int(errno)) }
                        try fm.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: dest.path)
                    }
                    assignments.append(PhotoEventAssignment(
                        sourceRootPath: unsorted.path, relativePath: name, fileSize: master.1,
                        modifiedAt: modifiedAt, eventID: event.id, deviceID: "sony-a7v"))
                    total += 1
                }
                made += size
                group += 1
            }
        }
        if !ready, persistent != nil { fm.createFile(atPath: readyURL.path, contents: Data()) }
        configuration.photoEventAssignments = assignments
        let configURL = support.appendingPathComponent("config.json")
        let store = ConfigurationStore(url: configURL)
        try store.save(configuration)
        let outcome = CatalogStateStartup.resolve(
            configurationURL: configURL, defaults: configuration,
            backups: { url in CatalogBackupService(catalogURL: url, configurationURL: configURL, localFolder: support.appendingPathComponent("Backups"), remoteFolder: nil) })
        let model = DashboardModel(jobs: [], configuration: outcome.configuration, configurationStore: store)
        model.adoptCatalogState(outcome)
        let workspace = EventsWorkspace(model: model, supportFolder: root.appendingPathComponent("Support", isDirectory: true), driveActivityGate: DriveActivityGate())
        workspace.captureDateReadProbe = { _ in nil }
        return ScrollLibrary(root: root, model: model, workspace: workspace, parentID: parent.id, fileCount: total)
    }
}
