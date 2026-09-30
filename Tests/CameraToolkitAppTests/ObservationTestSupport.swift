import Foundation
import Observation
import XCTest

/// Set from an `onChange` closure, read afterwards.
final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false
    var fired: Bool { lock.withLock { _fired } }
    func set() { lock.withLock { _fired = true } }
}

/// Runs `read` once under observation tracking and reports whether `change`
/// — run right after — notified it.
@MainActor
func observationFires<Result>(reading read: () -> Result, after change: () -> Void) -> Bool {
    let flag = ObservationFlag()
    _ = withObservationTracking {
        read()
    } onChange: {
        flag.set()
    }
    change()
    return flag.fired
}
