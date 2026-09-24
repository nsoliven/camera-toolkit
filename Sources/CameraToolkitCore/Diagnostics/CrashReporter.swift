import Darwin
import Foundation

// Crash capture and the next-launch "quit unexpectedly" check.
//
// Everything lives in one folder, `~/Library/Application Support/
// CameraToolkit/Logs/`, and nothing here writes anywhere else:
//
// - `running.marker` — written at launch, removed on a normal quit. Its
//   presence at the next launch means the last run did not quit normally
//   (a crash, but also a force-quit, a kill during an install, or power
//   loss — so on its own it never raises the alert).
// - `crash-<timestamp>.log` — one per crash: the uncaught exception's
//   name, reason and call stack (or the fatal signal and a raw
//   backtrace), the app version, and the tail of the debug log.
// - `.signal-pending.log` — opened, empty, at launch so the signal
//   handler has a file descriptor to `write()` to without allocating. A
//   non-empty one at the next launch is renamed to a `crash-*.log`.
// - `system-CameraToolkit-*.ips` — copies of the system crash reports
//   from `~/Library/Logs/DiagnosticReports` (read only there).
// - `crash-check.json` — which crashes the alert has already covered.

/// Names, paths and pruning for the crash-log folder.
public struct CrashLogFolder: Sendable {
    public let url: URL

    public static let markerName = "running.marker"
    public static let pendingSignalName = ".signal-pending.log"
    public static let stateName = "crash-check.json"
    public static let crashLogPrefix = "crash-"
    public static let crashLogSuffix = ".log"
    public static let systemReportPrefix = "system-"
    /// Crash logs and copied system reports kept, each.
    public static let keepCount = 20

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/CameraToolkit/Logs/`.
    public static func `default`(fileManager: FileManager = .default) -> CrashLogFolder {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return CrashLogFolder(url: support
            .appendingPathComponent("CameraToolkit", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true))
    }

    public var markerURL: URL { url.appendingPathComponent(Self.markerName) }
    public var pendingSignalURL: URL { url.appendingPathComponent(Self.pendingSignalName) }
    public var stateURL: URL { url.appendingPathComponent(Self.stateName) }

    public func create(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// `crash-20260924-002008.log`; a second crash in the same second gets
    /// `-2`, `-3`… so no log is ever overwritten.
    public func newCrashLogURL(at date: Date, fileManager: FileManager = .default) -> URL {
        let stamp = Self.stamp(date)
        var candidate = url.appendingPathComponent("\(Self.crashLogPrefix)\(stamp)\(Self.crashLogSuffix)")
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = url.appendingPathComponent("\(Self.crashLogPrefix)\(stamp)-\(index)\(Self.crashLogSuffix)")
            index += 1
        }
        return candidate
    }

    /// Whether a file name is one this feature wrote as a crash log.
    public static func isCrashLog(_ name: String) -> Bool {
        name.hasPrefix(crashLogPrefix) && name.hasSuffix(crashLogSuffix)
    }

    /// Whether a file name is a system report this feature copied in.
    public static func isCopiedSystemReport(_ name: String) -> Bool {
        name.hasPrefix(systemReportPrefix + SystemCrashReports.namePrefix) && name.hasSuffix(".ips")
    }

    /// The feature's crash logs, oldest first.
    public func crashLogs(fileManager: FileManager = .default) -> [URL] {
        files(matching: Self.isCrashLog, fileManager: fileManager)
    }

    /// Keeps the newest `keep` crash logs and the newest `keep` copied
    /// system reports. Anything else in the folder — the owner's files,
    /// the marker, the state file — is never touched.
    @discardableResult
    public func prune(keep: Int = CrashLogFolder.keepCount, fileManager: FileManager = .default) -> [URL] {
        var removed: [URL] = []
        for matches in [Self.isCrashLog, Self.isCopiedSystemReport] as [(String) -> Bool] {
            let owned = files(matching: matches, fileManager: fileManager)
            for old in owned.dropLast(max(keep, 0)) where (try? fileManager.removeItem(at: old)) != nil {
                removed.append(old)
            }
        }
        return removed
    }

    /// Matching regular files, oldest first by modification date, then name.
    private func files(matching predicate: (String) -> Bool, fileManager: FileManager) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let contents = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        let owned: [URL] = contents.filter { file in
            guard predicate(file.lastPathComponent) else { return false }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
        let dated: [(url: URL, date: Date)] = owned.map { ($0, Self.modificationDate($0)) }
        let sorted = dated.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        return sorted.map(\.url)
    }

    static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

// MARK: - Report text

/// What an app build says about itself in a crash log.
public struct CrashAppInfo: Sendable, Equatable {
    public var version: String
    public var build: String
    public var commit: String?

    public init(version: String, build: String, commit: String? = nil) {
        self.version = version
        self.build = build
        self.commit = commit
    }

    /// Info.plist's `CFBundleShortVersionString`, `CFBundleVersion`, and
    /// `CameraToolkitBuildCommit` when the packager recorded one.
    public static func from(bundle: Bundle) -> CrashAppInfo {
        let info = bundle.infoDictionary ?? [:]
        let commit = (info["CameraToolkitBuildCommit"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CrashAppInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            commit: commit?.isEmpty == false ? commit : nil
        )
    }

    /// "0.1.0 (1, abc1234)".
    public var summary: String {
        "\(version) (\(build)\(commit.map { ", \($0)" } ?? ""))"
    }
}

/// Builds the text of a `crash-*.log`. Pure, so the format is testable.
public enum CrashLogFormatter {
    public static let title = "Camera Toolkit crash log"
    public static let reasonPrefix = "Reason: "

    public static func exceptionReport(
        name: String,
        reason: String?,
        callStack: [String],
        app: CrashAppInfo,
        date: Date,
        debugLogTail: [String]
    ) -> String {
        var lines = header(app: app, date: date)
        lines.append("Kind: Uncaught exception")
        lines.append("Exception: \(name)")
        lines.append(reasonPrefix + oneLine(reason ?? "(no reason given)"))
        lines.append("")
        lines.append("Call stack:")
        lines.append(contentsOf: callStack.isEmpty ? ["(none)"] : callStack)
        lines.append(contentsOf: tailSection(debugLogTail))
        return lines.joined(separator: "\n") + "\n"
    }

    /// The fixed preamble the signal handler writes before the signal
    /// name — built at launch, since the handler cannot format text.
    public static func signalPreamble(app: CrashAppInfo, launchedAt: Date) -> String {
        var lines = header(app: app, date: nil)
        lines.append("Launched: \(iso(launchedAt))")
        lines.append("Kind: Fatal signal")
        return lines.joined(separator: "\n") + "\n" + reasonPrefix
    }

    /// The debug-log tail appended when a signal log is picked up at the
    /// next launch (the handler itself could not read files).
    public static func harvestedSignalSuffix(debugLogTail: [String], crashedAt: Date) -> String {
        (["", "Crashed: \(iso(crashedAt)) (file time)"] + tailSection(debugLogTail))
            .joined(separator: "\n") + "\n"
    }

    /// The `Reason:` line of a crash log, for the alert's one-line reason.
    public static func reason(inLog text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix(reasonPrefix) }
            .map { String($0.dropFirst(reasonPrefix.count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func header(app: CrashAppInfo, date: Date?) -> [String] {
        var lines = [title, "App: Camera Toolkit \(app.summary)"]
        if let date { lines.append("Date: \(iso(date))") }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        lines.append("macOS: \(os)")
        return lines
    }

    private static func tailSection(_ tail: [String]) -> [String] {
        guard !tail.isEmpty else { return [] }
        return ["", "Last \(tail.count) debug log line\(tail.count == 1 ? "" : "s"):"] + tail
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

/// The last lines of the app's `debug.jsonl`, read from its end so a
/// large log costs one bounded read.
public enum DebugLogTail {
    public static let defaultLineCount = 40

    public static func lines(of url: URL, count: Int = defaultLineCount, maxBytes: Int = 64 * 1_024) -> [String] {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return [] }
        var text = String(decoding: data, as: UTF8.self)
        // A read that starts mid-file starts mid-line; drop the fragment.
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(count))
    }
}

// MARK: - Launch marker

/// The "this run has not quit normally yet" marker.
public struct CrashRunMarker: Codable, Sendable, Equatable {
    public var launchedAt: Date
    public var pid: Int32
    public var version: String

    public init(launchedAt: Date, pid: Int32, version: String) {
        self.launchedAt = launchedAt
        self.pid = pid
        self.version = version
    }

    /// Reads a leftover marker — the previous run's — or nil after a
    /// normal quit. An unreadable marker still counts as an unclean exit.
    public static func read(in folder: CrashLogFolder, fileManager: FileManager = .default) -> CrashRunMarker? {
        guard fileManager.fileExists(atPath: folder.markerURL.path) else { return nil }
        if let data = try? Data(contentsOf: folder.markerURL),
           let marker = try? JSONDecoder.crashLog.decode(CrashRunMarker.self, from: data) {
            return marker
        }
        return CrashRunMarker(
            launchedAt: CrashLogFolder.modificationDate(folder.markerURL),
            pid: 0,
            version: "unknown"
        )
    }

    public func write(in folder: CrashLogFolder) throws {
        try folder.create()
        try JSONEncoder.crashLog.encode(self).write(to: folder.markerURL, options: .atomic)
    }

    /// A normal quit: the next launch should not suspect a crash.
    public static func clear(in folder: CrashLogFolder, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: folder.markerURL)
    }
}

// MARK: - System reports

/// Read-only access to the system's `CameraToolkit-*.ips` crash reports.
public enum SystemCrashReports {
    public static let namePrefix = "CameraToolkit-"

    /// `~/Library/Logs/DiagnosticReports`.
    public static func defaultFolder(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// The newest crash report (bug type 309) written after `since`. Hang
    /// and other report kinds, and reports for other apps, are skipped.
    public static func newest(in folder: URL, since: Date, fileManager: FileManager = .default) -> URL? {
        let contents = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let reports: [URL] = contents.filter { $0.lastPathComponent.hasPrefix(namePrefix) && $0.pathExtension == "ips" }
        let dated: [(url: URL, date: Date)] = reports.map { ($0, CrashLogFolder.modificationDate($0)) }
        let newestFirst = dated.filter { $0.date > since }.sorted { $0.date > $1.date }
        return newestFirst.map(\.url).first { isCrashReport($0) }
    }

    /// The `.ips` JSON header line names the report kind; 309 is a crash.
    static func isCrashReport(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4_096)) ?? Data()
        let firstLine = head.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first ?? head
        guard let header = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any] else {
            return false
        }
        return "\(header["bug_type"] ?? "")" == "309"
    }

    /// "EXC_BREAKPOINT (SIGTRAP)" from the report body, when readable.
    public static func reason(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any],
              let exception = body["exception"] as? [String: Any],
              let type = exception["type"] as? String else { return nil }
        if let signal = exception["signal"] as? String { return "\(type) (\(signal))" }
        return type
    }

    /// Copies a system report into the crash-log folder as
    /// `system-<its name>`; an existing copy is kept, never replaced.
    public static func copy(_ report: URL, into folder: CrashLogFolder, fileManager: FileManager = .default) throws -> URL {
        try folder.create(fileManager: fileManager)
        let destination = folder.url.appendingPathComponent(CrashLogFolder.systemReportPrefix + report.lastPathComponent)
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.copyItem(at: report, to: destination)
        }
        return destination
    }
}

// MARK: - Next-launch decision

/// What the alert has already covered, so each crash is shown once.
public struct CrashCheckState: Codable, Sendable, Equatable {
    public var lastCheck: Date
    public var shownLogs: [String]
    public var shownSystemReports: [String]

    public init(lastCheck: Date = .distantPast, shownLogs: [String] = [], shownSystemReports: [String] = []) {
        self.lastCheck = lastCheck
        self.shownLogs = shownLogs
        self.shownSystemReports = shownSystemReports
    }

    public static func read(in folder: CrashLogFolder) -> CrashCheckState {
        guard let data = try? Data(contentsOf: folder.stateURL),
              let state = try? JSONDecoder.crashLog.decode(CrashCheckState.self, from: data) else {
            return CrashCheckState()
        }
        return state
    }

    public func write(in folder: CrashLogFolder) throws {
        try folder.create()
        var trimmed = self
        trimmed.shownLogs = Array(shownLogs.suffix(CrashLogFolder.keepCount * 2))
        trimmed.shownSystemReports = Array(shownSystemReports.suffix(CrashLogFolder.keepCount * 2))
        try JSONEncoder.crashLog.encode(trimmed).write(to: folder.stateURL, options: .atomic)
    }
}

/// Everything the next-launch check found, in plain values.
public struct CrashLaunchEvidence: Sendable, Equatable {
    /// The previous run's marker — nil when it quit normally.
    public var previousRun: CrashRunMarker?
    /// Crash logs in the folder the alert has not covered yet, newest last.
    public var unseenCrashLogs: [String]
    /// A system crash report newer than the previous launch and the last
    /// check, not yet covered.
    public var systemReport: String?

    public init(previousRun: CrashRunMarker?, unseenCrashLogs: [String], systemReport: String?) {
        self.previousRun = previousRun
        self.unseenCrashLogs = unseenCrashLogs
        self.systemReport = systemReport
    }
}

public enum CrashAlertDecision: Sendable, Equatable {
    case none
    /// Show the alert for this crash log and/or system report.
    case show(crashLog: String?, systemReport: String?)

    /// Pure: whether to say "quit unexpectedly".
    ///
    /// - A normal quit (no marker) never alerts — even if an old crash log
    ///   is lying around, it was from a run the owner has already seen end.
    /// - A leftover marker with no crash log and no new system report is a
    ///   force-quit, an install replacing the binary, or power loss: no
    ///   alert, since nothing says the app crashed.
    /// - Otherwise alert once, for the newest evidence.
    public static func decide(_ evidence: CrashLaunchEvidence) -> CrashAlertDecision {
        guard evidence.previousRun != nil else { return .none }
        let log = evidence.unseenCrashLogs.last
        guard log != nil || evidence.systemReport != nil else { return .none }
        return .show(crashLog: log, systemReport: evidence.systemReport)
    }
}

/// The alert's contents, ready for the app to show.
public struct CrashNotice: Sendable, Equatable {
    public var reason: String
    /// Files to select in Finder: the crash log and the copied system report.
    public var files: [URL]
    /// Plain text for Copy Details.
    public var details: String

    public init(reason: String, files: [URL], details: String) {
        self.reason = reason
        self.files = files
        self.details = details
    }
}

// MARK: - The reporter

/// Installs crash capture at launch and runs the next-launch check.
///
/// The app calls `start(at:)` first thing, `checkPreviousRun()` off the
/// main thread shortly after launch, and `markCleanExit()` on a normal
/// quit. Handlers are process-wide; `start` installs them once.
public final class CrashReporter: @unchecked Sendable {
    public let folder: CrashLogFolder
    public let app: CrashAppInfo
    public let debugLogURL: URL
    public let systemReportsFolder: URL
    private let fileManager: FileManager
    /// The previous run's marker, read before this launch replaced it.
    public private(set) var previousRun: CrashRunMarker?
    public private(set) var launchedAt = Date()

    public init(
        folder: CrashLogFolder = .default(),
        app: CrashAppInfo,
        debugLogURL: URL = DebugLog.defaultURL(),
        systemReportsFolder: URL = SystemCrashReports.defaultFolder(),
        fileManager: FileManager = .default
    ) {
        self.folder = folder
        self.app = app
        self.debugLogURL = debugLogURL
        self.systemReportsFolder = systemReportsFolder
        self.fileManager = fileManager
    }

    /// Launch step: remember the previous run's marker, turn a pending
    /// signal log into a crash log, write this run's marker, and open the
    /// signal log for this run. Does not install handlers (see
    /// `installHandlers()`), so tests can drive it.
    public func prepareLaunch(at date: Date = Date()) {
        launchedAt = date
        previousRun = CrashRunMarker.read(in: folder, fileManager: fileManager)
        try? folder.create(fileManager: fileManager)
        harvestPendingSignalLog()
        try? CrashRunMarker(
            launchedAt: date,
            pid: ProcessInfo.processInfo.processIdentifier,
            version: app.summary
        ).write(in: folder)
        CrashSignalCapture.prepare(
            fileURL: folder.pendingSignalURL,
            preamble: CrashLogFormatter.signalPreamble(app: app, launchedAt: date)
        )
    }

    /// `prepareLaunch`, then the exception and signal handlers.
    public func start(at date: Date = Date()) {
        prepareLaunch(at: date)
        installHandlers()
    }

    public func installHandlers() {
        CrashReporter.exceptionReporter = self
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.exceptionReporter?.recordUncaughtException(exception)
        }
        CrashSignalCapture.install()
    }

    /// A normal quit.
    public func markCleanExit() {
        CrashSignalCapture.finish(fileURL: folder.pendingSignalURL)
        CrashRunMarker.clear(in: folder, fileManager: fileManager)
    }

    nonisolated(unsafe) static var exceptionReporter: CrashReporter?

    /// Writes the full crash log for an uncaught exception. Runs on the
    /// crashing thread just before the process aborts, so it allocates
    /// freely but does as little as it can.
    @discardableResult
    public func recordUncaughtException(_ exception: NSException, at date: Date = Date()) -> URL? {
        recordException(
            name: exception.name.rawValue,
            reason: exception.reason,
            callStack: exception.callStackSymbols,
            at: date
        )
    }

    @discardableResult
    public func recordException(name: String, reason: String?, callStack: [String], at date: Date = Date()) -> URL? {
        // The abort that follows raises SIGABRT/SIGTRAP; this log already
        // says everything, so the signal handler stays quiet.
        CrashSignalCapture.markHandled()
        let text = CrashLogFormatter.exceptionReport(
            name: name,
            reason: reason,
            callStack: callStack,
            app: app,
            date: date,
            debugLogTail: DebugLogTail.lines(of: debugLogURL)
        )
        try? folder.create(fileManager: fileManager)
        let url = folder.newCrashLogURL(at: date, fileManager: fileManager)
        guard (try? Data(text.utf8).write(to: url)) != nil else { return nil }
        return url
    }

    /// A non-empty signal log from the previous run becomes a crash log,
    /// with the debug-log tail the handler could not read; an empty one is
    /// just this feature's placeholder and goes away.
    @discardableResult
    func harvestPendingSignalLog() -> URL? {
        let pending = folder.pendingSignalURL
        guard let data = try? Data(contentsOf: pending) else { return nil }
        guard !data.isEmpty else {
            try? fileManager.removeItem(at: pending)
            return nil
        }
        let crashedAt = CrashLogFolder.modificationDate(pending)
        let text = String(decoding: data, as: UTF8.self)
            + CrashLogFormatter.harvestedSignalSuffix(
                debugLogTail: DebugLogTail.lines(of: debugLogURL),
                crashedAt: crashedAt
            )
        let destination = folder.newCrashLogURL(at: crashedAt, fileManager: fileManager)
        guard (try? Data(text.utf8).write(to: destination)) != nil else { return nil }
        try? fileManager.removeItem(at: pending)
        return destination
    }

    /// The next-launch check: gathers evidence, decides, copies a new
    /// system report in, records what was covered, and prunes. Returns
    /// the notice to show, or nil. File work only — call it off the main
    /// thread.
    public func checkPreviousRun(now: Date = Date()) -> CrashNotice? {
        var state = CrashCheckState.read(in: folder)
        let unseen = folder.crashLogs(fileManager: fileManager)
            .map(\.lastPathComponent)
            .filter { !state.shownLogs.contains($0) }
        let since = max(state.lastCheck, previousRun?.launchedAt ?? .distantPast)
        let report = SystemCrashReports.newest(in: systemReportsFolder, since: since, fileManager: fileManager)
            .flatMap { state.shownSystemReports.contains($0.lastPathComponent) ? nil : $0 }
        let evidence = CrashLaunchEvidence(
            previousRun: previousRun,
            unseenCrashLogs: unseen,
            systemReport: report?.lastPathComponent
        )
        let decision = CrashAlertDecision.decide(evidence)

        var notice: CrashNotice?
        if case let .show(logName, _) = decision {
            let logURL = logName.map { folder.url.appendingPathComponent($0) }
            let copied = report.flatMap { try? SystemCrashReports.copy($0, into: folder, fileManager: fileManager) }
            let logText = logURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let reason = logText.flatMap(CrashLogFormatter.reason(inLog:))
                ?? report.flatMap(SystemCrashReports.reason(of:))
                ?? "The reason was not recorded."
            let files = [logURL, copied].compactMap { $0 }
            notice = CrashNotice(
                reason: reason,
                files: files,
                details: Self.details(reason: reason, files: files, logText: logText)
            )
        }
        // Every log present now is covered, alert or not: a stale log
        // from before a normal quit must not surface after a later crash
        // that left no log of its own.
        state.shownLogs.append(contentsOf: unseen)
        if let report { state.shownSystemReports.append(report.lastPathComponent) }
        state.lastCheck = now
        try? state.write(in: folder)
        folder.prune(fileManager: fileManager)
        return notice
    }

    static func details(reason: String, files: [URL], logText: String?) -> String {
        var lines = ["Camera Toolkit quit unexpectedly last time.", "Reason: \(reason)"]
        lines += files.map { "Saved: \($0.path)" }
        if let logText {
            let limit = 16_000
            lines += ["", logText.count > limit ? String(logText.prefix(limit)) + "\n…" : logText]
        }
        return lines.joined(separator: "\n")
    }
}

extension JSONEncoder {
    static var crashLog: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var crashLog: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
