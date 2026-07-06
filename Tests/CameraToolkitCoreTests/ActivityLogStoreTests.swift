import CameraToolkitCore
import Foundation
import XCTest

final class ActivityLogStoreTests: XCTestCase {
    func testAppendAndLoadKeepsPermanentHistoryNewestFirst() throws {
        try withTemporaryDirectory { root in
            let store = ActivityLogStore(url: root.appendingPathComponent("activity-log.jsonl"))
            let older = ActivityLogEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                createdAt: Date(timeIntervalSince1970: 100),
                action: .ingestCard,
                state: .done,
                title: "Previewed copy plan",
                summary: "3 new files, 0 conflicts.",
                detail: "No files were copied."
            )
            let newer = ActivityLogEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                createdAt: Date(timeIntervalSince1970: 200),
                action: .verifyManifest,
                state: .done,
                title: "Completed safe demo",
                summary: "4 copied, 1 quarantined, 1 left alone.",
                detail: "The demo archive manifest verified."
            )

            try store.append(older)
            try store.append(newer)

            let loaded = try store.load()
            XCTAssertEqual(loaded.map(\.id), [newer.id, older.id])
            XCTAssertEqual(loaded.first?.summary, "4 copied, 1 quarantined, 1 left alone.")
        }
    }

    func testMissingLogLoadsEmptyHistory() throws {
        try withTemporaryDirectory { root in
            let store = ActivityLogStore(url: root.appendingPathComponent("missing.jsonl"))

            XCTAssertEqual(try store.load(), [])
        }
    }
}
