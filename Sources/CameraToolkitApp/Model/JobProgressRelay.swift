import Foundation

/// Carries a running job's progress from its worker thread to the main
/// actor at a bounded rate. Workers report as often as they like — a face
/// scan or a copy can report hundreds of times a second — and every report
/// used to become a main-actor hop that rewrote the job's row, redrew the
/// bottom bar, and re-laid-out the board around it. The relay keeps only the
/// newest report and delivers it at most every `minimumInterval`; the first
/// report of a job is delivered at once.
final class JobProgressRelay: @unchecked Sendable {
    /// Four deliveries a second: a progress bar cannot show more.
    static let defaultInterval: TimeInterval = 0.25

    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private let deliver: @MainActor (BackgroundJobUpdate) -> Void
    private var latest: BackgroundJobUpdate?
    private var scheduled = false
    private var closed = false
    private var lastDelivery: DispatchTime?

    init(
        minimumInterval: TimeInterval = JobProgressRelay.defaultInterval,
        deliver: @escaping @MainActor (BackgroundJobUpdate) -> Void
    ) {
        self.minimumInterval = minimumInterval
        self.deliver = deliver
    }

    /// Called from any thread.
    func submit(_ update: BackgroundJobUpdate) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        latest = update
        guard !scheduled else {
            lock.unlock()
            return
        }
        scheduled = true
        let delay: TimeInterval
        if let lastDelivery {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastDelivery.uptimeNanoseconds) / 1_000_000_000
            delay = max(0, minimumInterval - elapsed)
        } else {
            delay = 0
        }
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            flush()
        }
    }

    /// Stops delivering: whatever is waiting is dropped. Called when the job
    /// finishes, so a late report cannot rewrite a finished job's row.
    func close() {
        lock.lock()
        closed = true
        latest = nil
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        scheduled = false
        let update = closed ? nil : latest
        latest = nil
        if update != nil { lastDelivery = .now() }
        lock.unlock()
        guard let update else { return }
        MainActor.assumeIsolated { deliver(update) }
    }
}
