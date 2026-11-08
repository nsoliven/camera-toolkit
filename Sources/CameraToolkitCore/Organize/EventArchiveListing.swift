import Foundation

/// One listing of an event's NAS folder for the presence sweep, so the
/// board's NAS chip costs one bulk read instead of a stat per file.
///
/// The listing is only ever an answer about names and sizes: a file with a
/// matching name and size is present, nothing more. "Verified" still comes
/// from Sync to NAS's records alone. A listing that fails or runs out of
/// time is `failed`, which the sweep reports as *unknown* — never as missing
/// or present.
public enum EventArchiveListing {
    public enum Answer: Sendable {
        case listed(NASTreeListing)
        case failed(reason: String)
        case cancelled
    }

    /// Reads `folders` under `root`. Injectable so a test can fail, stall,
    /// or count the listing without a NAS.
    public typealias Lister = @Sendable (_ root: URL, _ folders: [String], _ isCancelled: @escaping @Sendable () -> Bool) throws -> NASTreeListing

    /// A one-folder listing takes about 80 ms and a family of many thousand
    /// files a few seconds; past this the share is treated as not answering.
    public static let defaultTimeout: TimeInterval = 30

    public static let smbLister: Lister = { root, folders, isCancelled in
        try NASSMBLister.list(root: root, folders: folders, isCancelled: isCancelled)
    }

    /// True when `listing` already covers every folder, so the sweep can
    /// answer from it without touching the NAS.
    public static func covers(_ listing: NASTreeListing?, folders: [String]) -> Bool {
        guard let listing, !folders.isEmpty else { return false }
        return folders.allSatisfy { listing.covers(NASTreeListing.trimmed($0) + "/_") }
    }

    /// Runs `lister` on a thread of its own and stops waiting after
    /// `timeout`: a read stuck on a hung share occupies that one thread
    /// until the share answers, and the sweep moves on without it.
    public static func list(
        nasRoot: URL,
        folders: [String],
        timeout: TimeInterval = defaultTimeout,
        lister: @escaping Lister = smbLister,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> Answer {
        let run = Run()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try lister(nasRoot, folders, { run.stopped }) }
            run.finish(result)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let result = run.wait(atMost: min(0.05, max(deadline.timeIntervalSinceNow, 0))) {
                switch result {
                case .success(let listing): return .listed(listing)
                case .failure(is CancellationError): return .cancelled
                case .failure(let error): return .failed(reason: DebugLog.describe(error))
                }
            }
            if isCancelled() {
                run.stop()
                return .cancelled
            }
            if Date() >= deadline {
                run.stop()
                return .failed(reason: "timed out after \(Int(timeout)) s")
            }
        }
    }

    private final class Run: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: Result<NASTreeListing, Error>?
        private var wasStopped = false

        var stopped: Bool { condition.withLock { wasStopped } }

        func stop() {
            condition.withLock { wasStopped = true }
        }

        func finish(_ result: Result<NASTreeListing, Error>) {
            condition.withLock {
                self.result = result
                condition.broadcast()
            }
        }

        func wait(atMost seconds: TimeInterval) -> Result<NASTreeListing, Error>? {
            condition.withLock {
                if result == nil { _ = condition.wait(until: Date().addingTimeInterval(seconds)) }
                return result
            }
        }
    }
}
