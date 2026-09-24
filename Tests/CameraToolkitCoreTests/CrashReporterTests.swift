import Darwin
@testable import CameraToolkitCore
import XCTest

/// Crash capture and the next-launch check, all against temp folders:
/// the Logs folder, the debug log, and a stand-in DiagnosticReports.
final class CrashReporterTests: XCTestCase {
    private var root: URL!
    private var folder: CrashLogFolder!
    private var reports: URL!
    private var debugLog: URL!
    private let app = CrashAppInfo(version: "0.1.0", build: "7", commit: "abc1234")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashReporterTests-\(UUID().uuidString)", isDirectory: true)
        folder = CrashLogFolder(url: root.appendingPathComponent("Support/CameraToolkit/Logs", isDirectory: true))
        reports = root.appendingPathComponent("DiagnosticReports", isDirectory: true)
        debugLog = root.appendingPathComponent("debug.jsonl")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CrashSignalCapture.finish(fileURL: folder.pendingSignalURL)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeReporter() -> CrashReporter {
        CrashReporter(folder: folder, app: app, debugLogURL: debugLog, systemReportsFolder: reports)
    }

    // MARK: - Writing and formatting

    func testExceptionReportCarriesNameReasonStackVersionAndDebugTail() {
        let text = CrashLogFormatter.exceptionReport(
            name: "NSGenericException",
            reason: "The window has been marked as needing another Update Constraints pass\nsecond line",
            callStack: ["0 CoreFoundation __exceptionPreprocess", "1 libobjc objc_exception_throw"],
            app: app,
            date: Date(timeIntervalSince1970: 1_790_000_000),
            debugLogTail: ["{\"event\":\"a\"}", "{\"event\":\"b\"}"]
        )
        XCTAssertTrue(text.hasPrefix(CrashLogFormatter.title))
        XCTAssertTrue(text.contains("App: Camera Toolkit 0.1.0 (7, abc1234)"))
        XCTAssertTrue(text.contains("Exception: NSGenericException"))
        XCTAssertTrue(text.contains("Reason: The window has been marked as needing another Update Constraints pass second line"),
                      "the reason stays on one line")
        XCTAssertTrue(text.contains("Call stack:\n0 CoreFoundation __exceptionPreprocess\n1 libobjc objc_exception_throw"))
        XCTAssertTrue(text.contains("Last 2 debug log lines:\n{\"event\":\"a\"}\n{\"event\":\"b\"}"))
        XCTAssertEqual(
            CrashLogFormatter.reason(inLog: text),
            "The window has been marked as needing another Update Constraints pass second line"
        )
    }

    func testAppInfoWithoutCommitOmitsIt() {
        XCTAssertEqual(CrashAppInfo(version: "1.2", build: "3").summary, "1.2 (3)")
    }

    func testRecordExceptionCreatesLogsFolderAndCrashLog() throws {
        try writeFile(debugLog, (1...50).map { "{\"n\":\($0)}" }.joined(separator: "\n") + "\n")
        let reporter = makeReporter()
        let date = Date(timeIntervalSince1970: 1_790_000_000)

        let url = try XCTUnwrap(reporter.recordException(name: "NSInternalInconsistencyException", reason: "boom", callStack: ["frame"], at: date))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, folder.url.standardizedFileURL)
        XCTAssertEqual(url.lastPathComponent, "crash-\(CrashLogFolder.stamp(date)).log")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Reason: boom"))
        XCTAssertTrue(text.contains("{\"n\":50}"))
        XCTAssertFalse(text.contains("{\"n\":10}\n"), "only the last \(DebugLogTail.defaultLineCount) lines")

        // A second crash in the same second never overwrites the first.
        let second = try XCTUnwrap(reporter.recordException(name: "X", reason: "again", callStack: [], at: date))
        XCTAssertNotEqual(second, url)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("-2.log"))
    }

    func testDebugTailDropsAPartialFirstLineWhenReadingFromTheMiddle() throws {
        try writeFile(debugLog, (1...200).map { "line-\($0)-" + String(repeating: "x", count: 40) }.joined(separator: "\n"))
        let tail = DebugLogTail.lines(of: debugLog, count: 500, maxBytes: 1_000)
        XCTAssertFalse(tail.isEmpty)
        XCTAssertTrue(tail.allSatisfy { $0.hasPrefix("line-") })
        XCTAssertEqual(tail.last?.hasPrefix("line-200-"), true)
        XCTAssertEqual(DebugLogTail.lines(of: root.appendingPathComponent("missing.jsonl")), [])
    }

    func testSignalWriterWritesPreambleSignalAndBacktraceToThePreparedFile() throws {
        try folder.create()
        CrashSignalCapture.prepare(
            fileURL: folder.pendingSignalURL,
            preamble: CrashLogFormatter.signalPreamble(app: app, launchedAt: Date())
        )
        XCTAssertEqual(try Data(contentsOf: folder.pendingSignalURL).count, 0, "empty until a signal arrives")

        CrashSignalCapture.writeReport(signal: SIGSEGV)
        let text = try String(contentsOf: folder.pendingSignalURL, encoding: .utf8)
        XCTAssertTrue(text.contains("Kind: Fatal signal"))
        XCTAssertTrue(text.contains("Reason: SIGSEGV"))
        XCTAssertTrue(text.contains("Backtrace:\n"))
        XCTAssertEqual(CrashLogFormatter.reason(inLog: text)?.hasPrefix("SIGSEGV"), true)
    }

    func testSignalWriterStaysQuietAfterTheExceptionLogWasWritten() throws {
        try folder.create()
        CrashSignalCapture.prepare(fileURL: folder.pendingSignalURL, preamble: "preamble ")
        CrashSignalCapture.markHandled()
        CrashSignalCapture.writeReport(signal: SIGABRT)
        XCTAssertEqual(try Data(contentsOf: folder.pendingSignalURL).count, 0)
    }

    // MARK: - Marker lifecycle

    func testMarkerLifecycle() throws {
        let first = makeReporter()
        first.prepareLaunch(at: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertNil(first.previousRun, "a first launch has no previous run")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.markerURL.path))

        // Crashed (no clean exit): the next launch sees the old marker.
        let second = makeReporter()
        second.prepareLaunch(at: Date(timeIntervalSince1970: 1_790_000_100))
        XCTAssertEqual(second.previousRun?.launchedAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(second.previousRun?.version, app.summary)

        // A normal quit removes it, and the empty signal file with it.
        second.markCleanExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.markerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.pendingSignalURL.path))
        let third = makeReporter()
        third.prepareLaunch()
        XCTAssertNil(third.previousRun)
    }

    func testPendingSignalLogBecomesACrashLogAtNextLaunch() throws {
        try writeFile(debugLog, "{\"last\":true}\n")
        try writeFile(folder.pendingSignalURL, "Camera Toolkit crash log\nKind: Fatal signal\nReason: SIGBUS (bus error)\n\nBacktrace:\n0 x\n")
        try CrashRunMarker(launchedAt: Date(timeIntervalSince1970: 1_790_000_000), pid: 1, version: "0.1.0").write(in: folder)

        let reporter = makeReporter()
        reporter.prepareLaunch()
        let logs = folder.crashLogs()
        XCTAssertEqual(logs.count, 1)
        let text = try String(contentsOf: logs[0], encoding: .utf8)
        XCTAssertTrue(text.contains("Reason: SIGBUS (bus error)"))
        XCTAssertTrue(text.contains("{\"last\":true}"), "the debug tail the handler could not read")
        XCTAssertEqual(try Data(contentsOf: folder.pendingSignalURL).count, 0, "reopened empty for this run")
    }

    // MARK: - System reports

    private func writeIPS(_ name: String, bugType: String = "309", modified: Date) throws -> URL {
        let header = "{\"app_name\":\"CameraToolkit\",\"bug_type\":\"\(bugType)\"}"
        let body = "{\"exception\":{\"type\":\"EXC_BREAKPOINT\",\"signal\":\"SIGTRAP\"}}"
        let url = try writeFile(reports.appendingPathComponent(name), header + "\n" + body)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testPicksTheNewestCrashReportSinceTheLastCheck() throws {
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try writeIPS("CameraToolkit-2026-09-20-100000.ips", modified: since.addingTimeInterval(-60))
        _ = try writeIPS("CameraToolkit-2026-09-24-001000.ips", modified: since.addingTimeInterval(10))
        _ = try writeIPS("CameraToolkit-2026-09-24-002008.ips", modified: since.addingTimeInterval(20))
        _ = try writeIPS("CameraToolkit-2026-09-24-003000.ips", bugType: "288", modified: since.addingTimeInterval(30))
        _ = try writeIPS("OtherApp-2026-09-24-004000.ips", modified: since.addingTimeInterval(40))

        let newest = SystemCrashReports.newest(in: reports, since: since)
        XCTAssertEqual(newest?.lastPathComponent, "CameraToolkit-2026-09-24-002008.ips",
                       "newest crash (309) for this app; hang reports and other apps skipped")
        XCTAssertNil(SystemCrashReports.newest(in: reports, since: since.addingTimeInterval(25)))
        XCTAssertEqual(newest.flatMap(SystemCrashReports.reason(of:)), "EXC_BREAKPOINT (SIGTRAP)")
    }

    func testCopyingASystemReportLeavesTheOriginalAndNeverReplacesACopy() throws {
        let report = try writeIPS("CameraToolkit-2026-09-24-002008.ips", modified: Date())
        let original = try Data(contentsOf: report)
        let copy = try SystemCrashReports.copy(report, into: folder)
        XCTAssertEqual(copy.lastPathComponent, "system-CameraToolkit-2026-09-24-002008.ips")
        XCTAssertEqual(try Data(contentsOf: copy), original)
        XCTAssertEqual(try Data(contentsOf: report), original)

        try writeFile(copy, "kept")
        _ = try SystemCrashReports.copy(report, into: folder)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "kept")
    }

    // MARK: - Pruning

    func testPruneKeepsTheNewestOwnedFilesAndNeverTouchesForeignOnes() throws {
        try folder.create()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        for index in 0..<25 {
            let log = try writeFile(folder.url.appendingPathComponent("crash-2026092\(index / 10)-\(String(format: "%06d", index)).log"), "log \(index)")
            try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(Double(index))], ofItemAtPath: log.path)
        }
        for index in 0..<22 {
            let ips = try writeFile(folder.url.appendingPathComponent("system-CameraToolkit-\(index).ips"), "ips")
            try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(Double(index))], ofItemAtPath: ips.path)
        }
        let foreign = ["notes.txt", "crash-notes.txt", "CameraToolkit-owner-copy.ips", "system-Other-1.ips", "debug.log"]
        for name in foreign {
            try writeFile(folder.url.appendingPathComponent(name), "owner's")
        }
        try CrashRunMarker(launchedAt: base, pid: 1, version: "x").write(in: folder)

        let removed = folder.prune()
        XCTAssertEqual(removed.count, 5 + 2)
        let logs = folder.crashLogs().map(\.lastPathComponent)
        XCTAssertEqual(logs.count, CrashLogFolder.keepCount)
        XCTAssertFalse(logs.contains { $0.hasSuffix("000004.log") }, "oldest go first")
        XCTAssertTrue(logs.contains { $0.hasSuffix("000024.log") })
        for name in foreign {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent(name).path), name)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.markerURL.path))
    }

    // MARK: - Alert decision

    private let marker = CrashRunMarker(launchedAt: Date(timeIntervalSince1970: 1_790_000_000), pid: 1, version: "0.1.0")

    func testDecisionNormalQuitNeverAlerts() {
        let evidence = CrashLaunchEvidence(previousRun: nil, unseenCrashLogs: ["crash-a.log"], systemReport: "CameraToolkit-x.ips")
        XCTAssertEqual(CrashAlertDecision.decide(evidence), .none)
    }

    func testDecisionMarkerAloneIsAForceQuitOrInstallNotACrash() {
        let evidence = CrashLaunchEvidence(previousRun: marker, unseenCrashLogs: [], systemReport: nil)
        XCTAssertEqual(CrashAlertDecision.decide(evidence), .none)
    }

    func testDecisionAlertsForTheNewestLogOrASystemReport() {
        XCTAssertEqual(
            CrashAlertDecision.decide(CrashLaunchEvidence(previousRun: marker, unseenCrashLogs: ["crash-a.log", "crash-b.log"], systemReport: nil)),
            .show(crashLog: "crash-b.log", systemReport: nil)
        )
        XCTAssertEqual(
            CrashAlertDecision.decide(CrashLaunchEvidence(previousRun: marker, unseenCrashLogs: [], systemReport: "CameraToolkit-x.ips")),
            .show(crashLog: nil, systemReport: "CameraToolkit-x.ips")
        )
    }

    // MARK: - End to end

    func testCheckShowsOncePerCrashAndCopiesTheSystemReport() throws {
        // Run 1 launches, throws, never quits cleanly.
        let crashed = makeReporter()
        crashed.prepareLaunch(at: Date(timeIntervalSince1970: 1_790_000_000))
        try XCTUnwrap(crashed.recordException(
            name: "NSGenericException",
            reason: "more Update Constraints in Window passes than there are views",
            callStack: ["frame"],
            at: Date(timeIntervalSince1970: 1_790_000_050)
        ))
        _ = try writeIPS("CameraToolkit-2026-09-24-002008.ips", modified: Date(timeIntervalSince1970: 1_790_000_051))

        // Run 2: one alert, with the exception's reason and both files.
        let next = makeReporter()
        next.prepareLaunch(at: Date(timeIntervalSince1970: 1_790_000_100))
        let notice = try XCTUnwrap(next.checkPreviousRun(now: Date(timeIntervalSince1970: 1_790_000_103)))
        XCTAssertEqual(notice.reason, "more Update Constraints in Window passes than there are views")
        XCTAssertEqual(notice.files.map(\.lastPathComponent).sorted(), [
            "crash-\(CrashLogFolder.stamp(Date(timeIntervalSince1970: 1_790_000_050))).log",
            "system-CameraToolkit-2026-09-24-002008.ips",
        ].sorted())
        XCTAssertTrue(notice.details.contains("Camera Toolkit quit unexpectedly last time."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reports.appendingPathComponent("CameraToolkit-2026-09-24-002008.ips").path),
                      "the system report stays where it was")

        // Run 2 crashes without leaving anything new (killed): run 3 stays quiet.
        let third = makeReporter()
        third.prepareLaunch(at: Date(timeIntervalSince1970: 1_790_000_200))
        XCTAssertNil(third.checkPreviousRun(now: Date(timeIntervalSince1970: 1_790_000_203)))
    }

    func testCheckAfterANormalQuitCoversOldLogsSoTheyNeverSurfaceLater() throws {
        let quit = makeReporter()
        quit.prepareLaunch(at: Date(timeIntervalSince1970: 1_790_000_000))
        try writeFile(folder.url.appendingPathComponent("crash-20260901-000000.log"), "Reason: old\n")
        quit.markCleanExit()

        let clean = makeReporter()
        clean.prepareLaunch(at: Date(timeIntervalSince1970: 1_790_000_100))
        XCTAssertNil(clean.checkPreviousRun(now: Date(timeIntervalSince1970: 1_790_000_101)))

        // Force-quit next (marker left, nothing new): still no alert for the old log.
        let forced = makeReporter()
        forced.prepareLaunch(at: Date(timeIntervalSince1970: 1_790_000_200))
        XCTAssertNil(forced.checkPreviousRun(now: Date(timeIntervalSince1970: 1_790_000_201)))
    }
}
