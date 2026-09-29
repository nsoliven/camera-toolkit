@testable import CameraToolkitCore
import Foundation
import XCTest

/// Event folder names with accents written as a letter plus a combining mark,
/// emoji flags and other multi-scalar characters: SQLite's `substr` counts
/// code points, and the prefix match behind a folder rename and a presence
/// read must agree with that, not with Swift's grapheme count.
final class NASSyncStorePrefixTests: XCTestCase {
    private func record(_ root: String, _ path: String) -> NASSyncRecord {
        NASSyncRecord(nasRoot: root, relativePath: path, byteCount: 3, state: .verified, checkedAt: Date(timeIntervalSince1970: 1_000), verifiedAt: Date(timeIntervalSince1970: 1_000))
    }

    func testAFolderRenameMovesTheRecordsOfNamesWithCombiningMarksAndFlags() throws {
        try withTemporaryDirectory { root in
            let store = try NASSyncStore(catalogURL: root.appendingPathComponent("catalog.sqlite"))
            let nas = root.appendingPathComponent("NAS").path
            let decomposed = "2026/2026-08-21 Cafe\u{0301} du Monde"
            let flags = "2026/2026-08-22 Paris \u{1F1EB}\u{1F1F7}"
            for folder in [decomposed, flags] {
                try store.upsert([record(nas, "\(folder)/Originals/Sony A7V/DSC00001.ARW"), record(nas, "\(folder)/Originals/Sony A7V/DSC00002.ARW")])
            }
            try store.upsert([record(nas, "2026/2026-08-23 Other/Originals/Sony A7V/DSC00009.ARW")])

            // A read by prefix finds exactly the folder's records.
            XCTAssertEqual(try store.records(nasRoot: nas, prefixes: [decomposed]).count, 2)
            XCTAssertEqual(try store.records(nasRoot: nas, prefixes: [flags]).count, 2)

            // A folder rename moves every record under it and nothing else.
            XCTAssertEqual(try store.relocateFolder(nasRoot: nas, from: decomposed, to: "2026/2026-08-21 Cafe du Monde"), 2)
            XCTAssertEqual(try store.relocateFolder(nasRoot: nas, from: flags, to: "2026/2026-08-22 Paris"), 2)
            let all = try store.records(nasRoot: nas)
            XCTAssertEqual(Set(all.values.map(\.relativePath)), [
                "2026/2026-08-21 Cafe du Monde/Originals/Sony A7V/DSC00001.ARW",
                "2026/2026-08-21 Cafe du Monde/Originals/Sony A7V/DSC00002.ARW",
                "2026/2026-08-22 Paris/Originals/Sony A7V/DSC00001.ARW",
                "2026/2026-08-22 Paris/Originals/Sony A7V/DSC00002.ARW",
                "2026/2026-08-23 Other/Originals/Sony A7V/DSC00009.ARW",
            ])
        }
    }
}
