import XCTest
@testable import CameraToolkitApp

/// `RunLoopTurn.afterCommit()` is what lets a Move to Event landing be drawn
/// a slice at a time: it must resume on a later turn than the one that
/// awaited it, after everything queued on the main queue before it.
@MainActor
final class RunLoopTurnTests: XCTestCase {
    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var _steps: [String] = []
        var steps: [String] { lock.withLock { _steps } }
        func note(_ step: String) { lock.withLock { _steps.append(step) } }
    }

    func testResumesAfterWhatWasAlreadyQueuedOnTheMainQueue() async {
        let order = Order()
        DispatchQueue.main.async { order.note("queued first") }
        await RunLoopTurn.afterCommit()
        order.note("resumed")
        XCTAssertEqual(order.steps, ["queued first", "resumed"])
    }

    func testEachAwaitIsATurnOfItsOwn() async {
        let order = Order()
        for step in 1...3 {
            DispatchQueue.main.async { order.note("main queue \(step)") }
            await RunLoopTurn.afterCommit()
            order.note("slice \(step)")
        }
        XCTAssertEqual(order.steps, ["main queue 1", "slice 1", "main queue 2", "slice 2", "main queue 3", "slice 3"])
    }
}
