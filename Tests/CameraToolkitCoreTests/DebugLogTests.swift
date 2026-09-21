@testable import CameraToolkitCore
import XCTest

final class DebugLogTests: XCTestCase {
    private func makeLog(
        name: String = "debug.jsonl",
        maxBytes: UInt64 = 4 * 1_024 * 1_024
    ) -> (log: DebugLog, root: URL, url: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugLogTests-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent(name)
        return (DebugLog(url: url, maxBytes: maxBytes), root, url)
    }

    private func readEvents(_ url: URL) throws -> [DebugLogEvent] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { try decoder.decode(DebugLogEvent.self, from: Data($0.utf8)) }
    }

    func testWritesOneJSONLinePerEvent() throws {
        let (log, root, url) = makeLog()
        defer { try? FileManager.default.removeItem(at: root) }

        log.log(
            "decode.finish",
            subsystem: .tile,
            level: .info,
            outcome: .ok,
            duration: .milliseconds(42),
            url: URL(fileURLWithPath: "/private/card/DSC_0001.ARW"),
            size: 24_117_248
        )
        log.log(
            "decode.timeout",
            subsystem: .preview,
            level: .warning,
            outcome: .timeout,
            error: "wait released"
        )
        log.flush()

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(raw.split(separator: "\n").count, 2)
        // The wire format is `duration_ms`, not camelCase.
        XCTAssertTrue(raw.contains("\"duration_ms\":42"))
        // Basename only — the folder path must never reach the log.
        XCTAssertFalse(raw.contains("/private/card"))
        XCTAssertFalse(raw.contains("private"))

        let events = try readEvents(url)
        XCTAssertEqual(events[0].subsystem, .tile)
        XCTAssertEqual(events[0].event, "decode.finish")
        XCTAssertEqual(events[0].outcome, .ok)
        XCTAssertEqual(events[0].durationMs, 42)
        XCTAssertEqual(events[0].file, "DSC_0001.ARW")
        XCTAssertEqual(events[0].ext, "arw")
        XCTAssertEqual(events[0].size, 24_117_248)
        XCTAssertEqual(events[1].subsystem, .preview)
        XCTAssertEqual(events[1].outcome, .timeout)
        XCTAssertEqual(events[1].error, "wait released")
        // ISO-8601 timestamp with fractional seconds.
        XCTAssertTrue(events[0].ts.hasSuffix("Z"))
        XCTAssertTrue(events[0].ts.contains("."))
    }

    func testCreatesMissingLogDirectories() throws {
        let (log, root, url) = makeLog(name: "nested/deeper/debug.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        log.log("job.finish", subsystem: .apply, level: .info, outcome: .ok)
        log.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let events = try readEvents(url)
        XCTAssertEqual(events.first?.subsystem, .apply)
    }

    func testTrimsToCapAndKeepsWholeLines() throws {
        let (log, root, url) = makeLog(maxBytes: 1_024)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<200 {
            log.log(
                "tick.\(index)",
                subsystem: .tile,
                detail: String(repeating: "x", count: 40)
            )
        }
        log.flush()

        let data = try Data(contentsOf: url)
        // Trim runs before the write, so the cap is only ever exceeded by
        // the length of the newest line.
        XCTAssertLessThanOrEqual(data.count, 1_024 + 256)
        let events = try readEvents(url)
        XCTAssertFalse(events.isEmpty)
        XCTAssertEqual(events.last?.event, "tick.199")
        // The partial first line of the kept tail must have been dropped —
        // every remaining line parsed above.
    }

    func testUnwritableDestinationIsSwallowed() throws {
        // A path inside an existing *file* — directory creation fails and the
        // write must drop the line without crashing or throwing.
        let (_, root, url) = makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
        let blocked = DebugLog(url: url.appendingPathComponent("debug.jsonl"))

        blocked.log("decode.start", subsystem: .tile)
        blocked.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.url.path))
    }

    func testDefaultURLIsUserLogsFolder() {
        let url = DebugLog.defaultURL()
        XCTAssertTrue(url.path.hasSuffix("Library/Logs/CameraToolkit/debug.jsonl"))
    }

    func testDescribeNeverEmbedsPaths() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: 260,
            userInfo: [NSFilePathErrorKey: "/private/card/DSC_0001.ARW"]
        )
        XCTAssertEqual(DebugLog.describe(error), "NSCocoaErrorDomain 260")
    }
}
