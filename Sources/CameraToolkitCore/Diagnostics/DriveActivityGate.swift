import Foundation

/// Pauses the app's own background disk work on a volume while a storage
/// speed test measures it. Drive-event discovery, presence sweeps,
/// capture-date reads, and thumbnail decodes wait at this gate instead of
/// contending with the measurement — or piling onto a drive that may be
/// about to stall.
///
/// Pausing is per root path: a paused `/Volumes/Buffer` suspends work for
/// every URL under it while other volumes keep running. Waiters block their
/// background thread until the root resumes or `shouldStop` wins, so work
/// picks up again by itself when the test finishes.
public final class DriveActivityGate: @unchecked Sendable {
    /// Shared instance used by the app shell and the speed-test window.
    public static let shared = DriveActivityGate()

    private let condition = NSCondition()
    private var pausedRoots: Set<String> = []

    public init() {}

    /// Lowercased path so case-insensitive volumes match. Purely lexical:
    /// `standardizedFileURL` stats the path, and scans call this per file.
    private static func key(for url: URL) -> String {
        url.path.lowercased()
    }

    /// True when `url` is the paused root or lives inside it.
    private func isPausedLocked(key: String) -> Bool {
        pausedRoots.contains { key == $0 || key.hasPrefix($0 + "/") }
    }

    /// Suspend background work under `root` until `resume(_:)` or
    /// `resumeAll()`. Re-pausing an already paused root is a no-op.
    public func pause(_ root: URL) {
        condition.lock()
        pausedRoots.insert(Self.key(for: root))
        condition.unlock()
    }

    public func resume(_ root: URL) {
        condition.lock()
        pausedRoots.remove(Self.key(for: root))
        condition.broadcast()
        condition.unlock()
    }

    /// Release every paused root — safety net so nothing waits forever.
    public func resumeAll() {
        condition.lock()
        pausedRoots.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    /// True when `url` lives under a currently paused root.
    public func isPaused(for url: URL) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !pausedRoots.isEmpty else { return false }
        return isPausedLocked(key: Self.key(for: url))
    }

    /// Blocks a background thread until `url`'s root is unpaused or
    /// `shouldStop` wins. Returns false when stopped instead of resumed.
    /// Polls on a short timer so cancellation keeps working even when no
    /// resume broadcast is coming.
    @discardableResult
    public func waitIfPaused(
        for url: URL,
        pollInterval: TimeInterval = 0.1,
        shouldStop: @Sendable () -> Bool = { false }
    ) -> Bool {
        while true {
            condition.lock()
            if pausedRoots.isEmpty || !isPausedLocked(key: Self.key(for: url)) {
                condition.unlock()
                return true
            }
            if shouldStop() {
                condition.unlock()
                return false
            }
            condition.wait(until: Date().addingTimeInterval(pollInterval))
            condition.unlock()
        }
    }
}
