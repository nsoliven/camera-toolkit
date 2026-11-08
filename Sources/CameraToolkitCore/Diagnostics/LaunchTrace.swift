import Foundation

/// Launch milestones in `debug.jsonl`, each with the time since launch began,
/// so a slow start can be read back as what ran when and how long it took.
///
/// Off until the app turns it on (`begin`): tests and previews write nothing
/// to the owner's log. A line carries a step name and counts, never a path
/// or an event's name.
public enum LaunchTrace {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var log: DebugLog?
        var started: ContinuousClock.Instant?
        var once: Set<String> = []
    }

    private static let state = State()

    /// Starts the trace; the app calls this first thing in `main`.
    public static func begin(log: DebugLog = .shared) {
        state.lock.withLock {
            state.log = log
            state.started = .now
            state.once = []
        }
        mark("launch.begin", detail: processAge().map { "since_exec_ms=\($0)" })
    }

    /// Stops the trace; a test that began one calls this.
    public static func end() {
        state.lock.withLock {
            state.log = nil
            state.started = nil
            state.once = []
        }
    }

    public static var isActive: Bool { state.lock.withLock { state.log != nil } }

    /// Logs `event` with the time since launch began.
    public static func mark(_ event: String, outcome: DebugOutcome? = nil, detail: String? = nil) {
        let (log, started) = state.lock.withLock { (state.log, state.started) }
        guard let log, let started else { return }
        log.log(event, subsystem: .launch, level: .info, outcome: outcome, duration: started.duration(to: .now), detail: detail)
    }

    /// `mark`, the first time `event` happens in this launch only.
    public static func markOnce(_ event: String, outcome: DebugOutcome? = nil, detail: String? = nil) {
        let first = state.lock.withLock { state.log != nil && state.once.insert(event).inserted }
        if first { mark(event, outcome: outcome, detail: detail) }
    }

    /// How long ago this process was started, in ms — what the app's own
    /// clock cannot see: dyld, static initializers and the wait before `main`.
    private static func processAge() -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
        return Int(Date().timeIntervalSince(started) * 1_000)
    }
}

/// One board's open, as a line per step in `debug.jsonl`: selected, first
/// paint, each pass the refresh waited on, chips resolved, finished. Every
/// line carries the time since the board was selected (or, for a refresh
/// nobody clicked, since that refresh began), so a long spinner shows which
/// step it was waiting on.
///
/// The event is named by the first eight characters of its id only. A value,
/// so the passes that run off the main actor can carry it.
public struct BoardOpenTrace: Sendable {
    public let eventID: UUID
    private let started: ContinuousClock.Instant
    private let origin: String
    private let log: DebugLog?

    /// `selectedAt` is when the board was clicked; nil for a background
    /// refresh. `log` is nil outside the app, where the trace writes nothing.
    public init(eventID: UUID, selectedAt: ContinuousClock.Instant? = nil, log: DebugLog? = BoardOpenTrace.appLog) {
        self.eventID = eventID
        self.started = selectedAt ?? .now
        self.origin = selectedAt == nil ? "refresh" : "selection"
        self.log = log
    }

    /// The log while `LaunchTrace` is on.
    public static var appLog: DebugLog? { LaunchTrace.isActive ? .shared : nil }

    public func mark(_ step: String, outcome: DebugOutcome? = nil, detail: String? = nil) {
        guard let log else { return }
        var line = "event=\(eventID.uuidString.prefix(8).lowercased()) from=\(origin)"
        if let detail { line += " \(detail)" }
        log.log("board.open.\(step)", subsystem: .board, level: .info, outcome: outcome, duration: started.duration(to: .now), detail: line)
    }
}
