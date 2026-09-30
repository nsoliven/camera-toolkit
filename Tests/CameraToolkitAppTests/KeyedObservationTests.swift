import Observation
import XCTest
@testable import CameraToolkitApp

/// A scope that tracked one key hears about that key and `touchAll`, and
/// about no other key.
@MainActor
final class KeyedObservationTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.withLock { _value } }
        func set() { lock.withLock { _value = true } }
    }

    private func fires(_ keysRead: [String], after change: (KeyedObservation<String>) -> Void) -> Bool {
        let observation = KeyedObservation<String>()
        let fired = Flag()
        withObservationTracking {
            for key in keysRead { observation.track(key) }
        } onChange: {
            fired.set()
        }
        change(observation)
        return fired.value
    }

    func testATouchOfTheTrackedKeyIsHeard() {
        XCTAssertTrue(fires(["a"]) { $0.touch("a") })
    }

    func testATouchOfAnotherKeyIsNot() {
        XCTAssertFalse(fires(["a"]) { $0.touch("b") })
    }

    func testAnyOfSeveralTrackedKeysIsHeard() {
        XCTAssertTrue(fires(["a", "b", "c"]) { $0.touch("b") })
        XCTAssertFalse(fires(["a", "b", "c"]) { $0.touch("d") })
    }

    func testTouchAllIsHeardByEveryTrackedKey() {
        XCTAssertTrue(fires(["a"]) { $0.touchAll() })
        XCTAssertTrue(fires(["a", "b"]) { $0.touchAll() })
    }

    func testAScopeThatTrackedNothingHearsNothing() {
        XCTAssertFalse(fires([]) { $0.touchAll() })
    }
}
