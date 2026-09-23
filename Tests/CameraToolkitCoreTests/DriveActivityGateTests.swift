import CameraToolkitCore
import Foundation
import XCTest

final class DriveActivityGateTests: XCTestCase {
    func testPausedRootCoversDescendantsButNotSiblings() throws {
        try withTemporaryDirectory { root in
            let drive = root.appendingPathComponent("Drive", isDirectory: true)
            let sibling = root.appendingPathComponent("Drive Two", isDirectory: true)
            let gate = DriveActivityGate()

            gate.pause(drive)
            XCTAssertTrue(gate.isPaused(for: drive))
            XCTAssertTrue(gate.isPaused(for: drive.appendingPathComponent("Camera Buffer/2026/DSC.ARW")))
            // "Drive Two" shares the "Drive" text prefix but not a path
            // boundary — matching is per component, never per string.
            XCTAssertFalse(gate.isPaused(for: sibling.appendingPathComponent("file.bin")))
            XCTAssertFalse(gate.isPaused(for: drive.deletingLastPathComponent()))

            gate.resume(drive)
            XCTAssertFalse(gate.isPaused(for: drive.appendingPathComponent("Camera Buffer")))
        }
    }

    /// A waiter parked on a paused volume stays parked until resume —
    /// that is what keeps scans, sweeps, and decodes off the tested drive.
    func testWaitIfPausedBlocksUntilResumed() throws {
        try withTemporaryDirectory { root in
            let drive = root.appendingPathComponent("Drive", isDirectory: true)
            let gate = DriveActivityGate()
            gate.pause(drive)

            let box = LockedBox<Bool>()
            DispatchQueue.global().async {
                box.store(gate.waitIfPaused(for: drive.appendingPathComponent("Card Copy/DSC.ARW")))
            }
            Thread.sleep(forTimeInterval: 0.3)
            XCTAssertFalse(box.isDelivered)

            gate.resume(drive)
            let deadline = Date().addingTimeInterval(5)
            while !box.isDelivered, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTAssertTrue(box.isDelivered)
            XCTAssertEqual(box.value, true)
        }
    }

    /// Cancellation still wins: a waiter told to stop leaves even while the
    /// volume stays paused, so cancelled work never pins a thread.
    func testWaitIfPausedReturnsFalseWhenAskedToStop() throws {
        try withTemporaryDirectory { root in
            let gate = DriveActivityGate()
            gate.pause(root)
            XCTAssertFalse(gate.waitIfPaused(
                for: root.appendingPathComponent("deep/file.bin"),
                pollInterval: 0.02,
                shouldStop: { true }
            ))
        }
    }

    func testResumeAllReleasesEveryPausedRoot() throws {
        try withTemporaryDirectory { root in
            let gate = DriveActivityGate()
            gate.pause(root.appendingPathComponent("A", isDirectory: true))
            gate.pause(root.appendingPathComponent("B", isDirectory: true))
            gate.resumeAll()
            XCTAssertFalse(gate.isPaused(for: root.appendingPathComponent("A/x")))
            XCTAssertFalse(gate.isPaused(for: root.appendingPathComponent("B/x")))
        }
    }

    /// The presence sweep must wait at the gate instead of stat-ing a paused
    /// volume — then proceed untouched once the test lets the drive go.
    func testPresenceSweepWaitsAtTheGateForAPausedVolume() throws {
        try withTemporaryDirectory { root in
            let configuration = testConfiguration(root: root)
            let locations = EventStorageLocations(configuration: configuration)
            let event = SavedCameraEvent(
                name: "City Walk",
                eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-08-29"))
            )
            let source = try writeFile(root.appendingPathComponent("Unsorted/DSC00001.ARW"), Data(count: 100))
            let assignment = PhotoEventAssignment(
                sourceRootPath: source.deletingLastPathComponent().path,
                relativePath: "DSC00001.ARW",
                fileSize: 100,
                modifiedAt: Date(),
                eventID: event.id,
                deviceID: "sony-a7v"
            )

            let gate = DriveActivityGate()
            gate.pause(root)   // every candidate path lives under root
            let probed = LockedPaths()
            let box = LockedBox<EventPresenceSummary>()
            DispatchQueue.global().async {
                box.store(EventPresenceScanner.scan(
                    event: event,
                    assignments: [assignment],
                    locations: locations,
                    mountedVolumes: [],
                    probe: { url, _, _ in
                        probed.append(url?.path ?? "nil")
                        return .missing
                    },
                    pauseGate: gate
                ))
            }
            Thread.sleep(forTimeInterval: 0.3)
            XCTAssertTrue(probed.values.isEmpty)

            gate.resume(root)
            let deadline = Date().addingTimeInterval(5)
            while !box.isDelivered, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            let summary = try XCTUnwrap(box.value ?? nil)
            XCTAssertEqual(summary.assets.count, 1)
            // Source, policy drive, other drive, archive — probed only
            // after the volume resumed.
            XCTAssertEqual(probed.values.count, 4)
        }
    }
}

/// A value handed back from a parked background thread; `isDelivered`
/// distinguishes "still parked" from "returned nil".
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    private var delivered = false

    var value: Value? { lock.withLock { stored } }
    var isDelivered: Bool { lock.withLock { delivered } }

    func store(_ newValue: Value?) {
        lock.withLock {
            stored = newValue
            delivered = true
        }
    }
}

/// Paths the injected presence probe touched, in call order.
private final class LockedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
