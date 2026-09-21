import Foundation
import GRDB
import SQLite3

/// The shared retry policy for catalog writes on volumes that answer a
/// `BEGIN IMMEDIATE` with a transient failure instead of honoring the
/// busy timeout — NAS shares surface lock stutters as `SQLITE_IOERR`
/// (10), not a clean `SQLITE_BUSY`. A refused attempt is retried a
/// handful of times with a doubling backoff; an error that outlasts the
/// retries, or any non-transient error, is rethrown untouched so the job
/// still fails with the real SQLite message.
enum CatalogTransactionRetry {
    /// Total tries a write gets, first attempt included.
    static let maxAttempts = 6
    /// Wait before the second attempt; doubles for each later retry —
    /// 50, 100, 200, 400, 800 ms.
    static let firstRetryDelay: TimeInterval = 0.05

    /// The backoff before attempt `attempt` (1-based). Attempt 1 does not
    /// sleep; attempt 2 waits `firstRetryDelay`.
    static func delay(beforeAttempt attempt: Int) -> TimeInterval {
        firstRetryDelay * Double(1 << max(0, attempt - 2))
    }

    /// Transient by raw result code — extended codes mask to their
    /// primary, so `SQLITE_IOERR_LOCK` still counts as `SQLITE_IOERR`.
    static func isTransient(_ code: Int32) -> Bool {
        let primary = code & 0xFF
        return primary == SQLITE_BUSY || primary == SQLITE_IOERR
    }

    /// Transient for a GRDB error — `resultCode` is already the primary
    /// code, so every `SQLITE_IOERR_*` variant qualifies.
    static func isTransient(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_IOERR
    }

    /// Runs `operation` until it succeeds or the error is final: a
    /// transient `DatabaseError` retries with backoff, anything else —
    /// and a transient failure that outlasts the attempts — propagates
    /// as thrown. The operation must be safe to re-run: each call is a
    /// complete write transaction, so a retried attempt starts clean.
    static func run<T>(attempts: Int = maxAttempts, _ operation: () throws -> T) throws -> T {
        try run(attempts: attempts, isTransient: { error in
            (error as? DatabaseError).map(Self.isTransient) ?? false
        }, operation)
    }

    /// `run` with a caller-supplied transient classifier — the raw-sqlite
    /// catalog bootstrap carries result codes on its own error type
    /// rather than GRDB's `DatabaseError`.
    static func run<T>(
        attempts: Int = maxAttempts,
        isTransient: (Error) -> Bool,
        _ operation: () throws -> T
    ) throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            if attempt > 1 {
                Thread.sleep(forTimeInterval: delay(beforeAttempt: attempt))
            }
            do {
                return try operation()
            } catch {
                guard attempt < attempts, isTransient(error) else { throw error }
            }
        }
    }
}
