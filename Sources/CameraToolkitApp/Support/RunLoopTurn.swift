import CoreFoundation
import Foundation

/// Lets a long main-actor job be cut into slices that each get their own
/// frame.
///
/// SwiftUI and Core Animation draw what the main actor changed at the end of
/// the run-loop turn that changed it. Work that changes a lot in one turn —
/// a Move to Event landing that swaps assignments, repoints tiles and
/// patches the storage strip — is drawn in one piece, and the window cannot
/// answer input until that piece is done. Awaiting `afterCommit()` between
/// slices lets each slice's changes be drawn, and the main queue answer input
/// in between, before the next slice starts.
@MainActor
enum RunLoopTurn {
    /// Run-loop observers of Core Animation's commit run at order 2,000,000;
    /// this one runs after them.
    private static let observerOrder = 2_100_000

    /// A run loop that never reaches the point where it is about to sleep —
    /// something keeps it busy — would hold a slice back for as long as that
    /// lasts; the next slice starts after this long regardless.
    private static let longestWait: DispatchTimeInterval = .milliseconds(300)

    /// Resumes a continuation once, whichever of two triggers gets there first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

        func resume() {
            let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume()
        }
    }

    /// Suspends until the run loop has finished the turn it is in — the
    /// SwiftUI update, layout and Core Animation commit for every write made
    /// so far — and resumes on the next turn.
    static func afterCommit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault,
                CFRunLoopActivity.beforeWaiting.rawValue,
                false,
                observerOrder
            ) { _, _ in
                // Resume from a queued block, not from inside the observer,
                // so the continuation runs on a turn of its own.
                DispatchQueue.main.async { once.resume() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
            DispatchQueue.main.asyncAfter(deadline: .now() + longestWait) {
                CFRunLoopObserverInvalidate(observer)
                once.resume()
            }
        }
    }
}
