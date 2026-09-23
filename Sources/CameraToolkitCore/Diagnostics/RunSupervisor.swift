import Foundation

/// Shared state between a supervised caller and its I/O worker so a hung
/// syscall fails the run instead of pinning it: the worker reports each
/// completed unit of work and checks `shouldStop` between units, while the
/// caller polls for completion and idle time.
final class RunLivenessMonitor<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var lastChunkCompletedAt: TimeInterval
    private var stopRequested = false
    private var outcome: Result<Value, Error>?

    init(startedAt: TimeInterval) {
        lastChunkCompletedAt = startedAt
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    /// Liveness heartbeat — the worker completed one bounded unit of work.
    /// A step that returns at all proves the thread is not parked inside a
    /// dead mount's syscall.
    func markChunkCompleted(at uptime: TimeInterval) {
        lock.lock()
        lastChunkCompletedAt = uptime
        lock.unlock()
    }

    func idleSeconds(at uptime: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return uptime - lastChunkCompletedAt
    }

    func finish(_ outcome: Result<Value, Error>) {
        lock.lock()
        self.outcome = outcome
        lock.unlock()
        finished.signal()
    }

    func waitFinished(timeout: TimeInterval) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }

    func result() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}

/// Runs `work` on a private queue while the calling thread watches for stalls
/// and cancellation. POSIX `write`/`fsync`/`read` can block in ways Swift task
/// cancellation cannot interrupt, so on abort the caller stops waiting, asks
/// the worker to stand down between units, and reports the drive as
/// unresponsive. A worker parked inside a dead mount's syscall stays contained
/// on its queue — it owns its descriptor and closes it if the kernel ever
/// returns.
struct RunSupervisor: Sendable {
    var stallTimeout: TimeInterval
    var uptime: @Sendable () -> TimeInterval
    var queueLabel: String
    /// How often the supervisor wakes to check cancellation and idle time.
    var pollInterval: TimeInterval = 0.05
    /// The error thrown when no unit of work completes for `stallTimeout`.
    var stalledError: @Sendable () -> Error
    /// The error thrown when the worker ended without producing a result.
    var missingResultError: @Sendable () -> Error

    func run<Value>(
        _ work: @escaping @Sendable (RunLivenessMonitor<Value>) throws -> Value
    ) throws -> Value {
        let monitor = RunLivenessMonitor<Value>(startedAt: uptime())
        DispatchQueue(label: queueLabel, qos: .userInitiated).async {
            monitor.finish(Result(catching: { try work(monitor) }))
        }
        while !monitor.waitFinished(timeout: pollInterval) {
            if Task.isCancelled {
                monitor.requestStop()
                throw CancellationError()
            }
            if monitor.idleSeconds(at: uptime()) >= stallTimeout {
                monitor.requestStop()
                throw stalledError()
            }
        }
        guard let outcome = monitor.result() else {
            throw missingResultError()
        }
        return try outcome.get()
    }
}
