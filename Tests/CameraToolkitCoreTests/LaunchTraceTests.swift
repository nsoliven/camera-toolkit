import Foundation
import XCTest
@testable import CameraToolkitCore

/// The launch and event-open timing lines: written only while the app has
/// turned the trace on, and never naming a file or an event.
final class LaunchTraceTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchTraceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LaunchTrace.end()
        try? FileManager.default.removeItem(at: folder)
    }

    private func lines(_ log: DebugLog) throws -> [DebugLogEvent] {
        log.flush()
        guard let data = FileManager.default.contents(atPath: log.url.path) else { return [] }
        return try String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(DebugLogEvent.self, from: Data($0.utf8)) }
    }

    func testNothingIsLoggedUntilTheAppBeginsTheTrace() throws {
        LaunchTrace.mark("launch.should_not_appear")
        XCTAssertFalse(LaunchTrace.isActive)
        XCTAssertNil(BoardOpenTrace.appLog, "boards opened by tests stay out of the owner's log")
    }

    func testMilestonesCarryTimeSinceLaunchAndOnceMeansOnce() throws {
        let log = DebugLog(url: folder.appendingPathComponent("debug.jsonl"))
        LaunchTrace.begin(log: log)
        LaunchTrace.markOnce("launch.first_board_paint")
        LaunchTrace.markOnce("launch.first_board_paint")
        LaunchTrace.mark("discovery.drive", detail: "events=3")
        let events = try lines(log)
        XCTAssertEqual(events.map(\.event), ["launch.begin", "launch.first_board_paint", "discovery.drive"])
        XCTAssertTrue(events.allSatisfy { $0.subsystem == .launch && $0.durationMs != nil })
        XCTAssertEqual(events.last?.detail, "events=3")
    }

    func testABoardOpenIsTimedFromTheClickAndNamesTheEventOnlyByItsIDPrefix() throws {
        let log = DebugLog(url: folder.appendingPathComponent("debug.jsonl"))
        let eventID = UUID()
        let clicked = ContinuousClock.now.advanced(by: .seconds(-2))
        let trace = BoardOpenTrace(eventID: eventID, selectedAt: clicked, log: log)
        trace.mark("chips_resolved", detail: "on_nas=4 of=9")
        let event = try XCTUnwrap(lines(log).first)
        XCTAssertEqual(event.event, "board.open.chips_resolved")
        XCTAssertEqual(event.subsystem, .board)
        XCTAssertGreaterThanOrEqual(event.durationMs ?? 0, 2_000, "measured from the click, not from this line")
        let prefix = eventID.uuidString.prefix(8).lowercased()
        XCTAssertEqual(event.detail, "event=\(prefix) from=selection on_nas=4 of=9")
        XCTAssertNil(event.file)
    }

    func testARefreshNobodyClickedIsTimedFromItsOwnStart() throws {
        let log = DebugLog(url: folder.appendingPathComponent("debug.jsonl"))
        BoardOpenTrace(eventID: UUID(), log: log).mark("refresh_start")
        XCTAssertTrue(try XCTUnwrap(lines(log).first?.detail).contains("from=refresh"))
    }
}
