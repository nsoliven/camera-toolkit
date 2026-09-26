import CameraToolkitCore
import Foundation
import XCTest

final class EventReachabilityTests: XCTestCase {
    private let buffer = EventStoragePlace(role: .buffer, root: URL(fileURLWithPath: "/Volumes/CTTestBuffer/Camera Buffer"), isPrimary: true)
    private let staging = EventStoragePlace(role: .privateStaging, root: URL(fileURLWithPath: "/Volumes/CTTestBuffer/.Camera Toolkit/Private"), isPrimary: false)
    private let nas = EventStoragePlace(role: .nas, root: URL(fileURLWithPath: "/Volumes/CTTestNAS/Library"), isPrimary: true)

    func testUnmountedVolumesAnswerFromTheMountTableWithoutProbing() async {
        let calls = Counter()
        let report = await EventReachability.check(
            places: [buffer, staging, nas],
            mountedVolumes: ["/"],
            probe: { _ in calls.increment(); return true }
        )
        XCTAssertEqual(calls.value, 0)
        XCTAssertTrue(report.isOffline)
        XCTAssertEqual(report.offlinePlaces.map(\.displayName), ["CTTestBuffer (Buffer)", "CTTestNAS (NAS)"])
        XCTAssertEqual(report.offlineList, "CTTestBuffer (Buffer) and CTTestNAS (NAS)")
        XCTAssertEqual(report.remedySentence, "Plug in the Buffer or connect to the NAS to see the photos.")
    }

    func testMountedButHungVolumeIsBoundedByTheTimeout() async {
        let hang = DispatchSemaphore(value: 0)
        defer { hang.signal() }
        let started = Date()
        let report = await EventReachability.check(
            places: [buffer, nas],
            mountedVolumes: ["/Volumes/CTTestBuffer", "/Volumes/CTTestNAS"],
            timeout: 0.2,
            probe: { url in
                if url.path.hasPrefix("/Volumes/CTTestNAS") { _ = hang.wait(timeout: .now() + 30) }
                return true
            }
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(report.states[buffer], .reachable)
        XCTAssertEqual(report.states[nas], .notResponding)
        XCTAssertEqual(report.unresponsiveVolumes, ["/Volumes/CTTestNAS"])
        XCTAssertFalse(report.isOffline)
        XCTAssertEqual(report.offlinePlaces.map(\.role), [.nas])
    }

    func testMissingLocalRootIsNotOffline() async {
        let local = EventStoragePlace(role: .buffer, root: FileManager.default.temporaryDirectory.appendingPathComponent("ct-missing-\(UUID())"), isPrimary: true)
        let report = await EventReachability.check(places: [local], mountedVolumes: [])
        XCTAssertEqual(report.states[local], .missing)
        XCTAssertFalse(report.isOffline)
        XCTAssertTrue(report.offlinePlaces.isEmpty)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
