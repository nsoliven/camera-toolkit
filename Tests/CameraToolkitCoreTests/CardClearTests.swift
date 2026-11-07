import CameraToolkitCore
import Foundation
import XCTest

/// The final pass of Clear from Card: per item, the drive copy must hash to
/// the Sync to NAS verified hash, the NAS copy (when reachable) must match it,
/// and the card file must match the drive copy — or nothing of that item is
/// deleted. Drive and NAS copies are never changed.
final class CardClearTests: XCTestCase {
    private struct Fixture {
        var card: URL
        var drive: URL
        var nas: URL

        func item(_ names: [String], verified: [String: String]? = nil) throws -> CardClearItem {
            let files = try names.map { name -> CardClearFile in
                let source = card.appendingPathComponent(name)
                let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber).int64Value
                let driveCopy = drive.appendingPathComponent(name)
                let sha = try verified?[name] ?? FileScanner.sha256(driveCopy)
                return CardClearFile(
                    sourcePath: source.path,
                    relativePath: name,
                    byteCount: size,
                    modifiedAt: Date(timeIntervalSince1970: 1_790_000_000),
                    drivePath: driveCopy.path,
                    nasPath: nas.appendingPathComponent(name).path,
                    verifiedSHA256: sha
                )
            }
            return CardClearItem(
                id: EventStorageLocations.pathKey(card.appendingPathComponent(names[0]).path),
                eventID: UUID(),
                sourceRoot: card.path,
                driveRoot: drive.path,
                files: files
            )
        }
    }

    /// Card, drive and NAS each hold the same bytes for every name.
    private func fixture(_ root: URL, _ names: [String]) throws -> Fixture {
        let fixture = Fixture(
            card: root.appendingPathComponent("Card/DCIM/100MSDCF", isDirectory: true),
            drive: root.appendingPathComponent("Drive/Camera Buffer/2026/2026-08-26 Beach Day/Originals/Sony A7V", isDirectory: true),
            nas: root.appendingPathComponent("NAS/2026/2026-08-26 Beach Day/Originals/Sony A7V", isDirectory: true)
        )
        for (index, name) in names.enumerated() {
            let data = Data((0..<2_048).map { UInt8(($0 &* 31 &+ index &* 7) & 0xff) })
            for folder in [fixture.card, fixture.drive, fixture.nas] {
                try writeFile(folder.appendingPathComponent(name), data)
            }
        }
        return fixture
    }

    private func snapshot(_ fixture: Fixture) throws -> [String: Data] {
        var all: [String: Data] = [:]
        for (prefix, folder) in [("drive", fixture.drive), ("nas", fixture.nas)] {
            for (path, data) in try treeBytes(folder) { all["\(prefix)/\(path)"] = data }
        }
        return all
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testClearsOnlyItemsWhoseDriveAndNASCopiesMatchAndNeverTouchesThem() throws {
        try withTemporaryDirectory { root in
            let names = ["DSC00001.ARW", "DSC00002.ARW", "C0001.MP4", "C0001M01.XML", "DSC00003.ARW", "DSC00004.ARW", "DSC00005.ARW"]
            let f = try fixture(root, names)
            // DSC00002: the drive copy changed after Sync to NAS verified it
            // (same size, so only the hash can tell).
            let good2 = try FileScanner.sha256(f.drive.appendingPathComponent("DSC00002.ARW"))
            try Data(repeating: 0x42, count: 2_048).write(to: f.drive.appendingPathComponent("DSC00002.ARW"))
            // The clip's XML differs on the drive: the clip stays with it.
            try Data(repeating: 0x43, count: 2_048).write(to: f.drive.appendingPathComponent("C0001M01.XML"))
            let goodXML = try FileScanner.sha256(f.card.appendingPathComponent("C0001M01.XML"))
            // DSC00003: the NAS copy differs. DSC00004: the NAS copy is gone.
            try Data(repeating: 0x44, count: 2_048).write(to: f.nas.appendingPathComponent("DSC00003.ARW"))
            try FileManager.default.removeItem(at: f.nas.appendingPathComponent("DSC00004.ARW"))
            // DSC00005: the record's hash is not this drive copy's.
            let items = try [
                f.item(["DSC00001.ARW"]),
                f.item(["DSC00002.ARW"], verified: ["DSC00002.ARW": good2]),
                f.item(["C0001.MP4", "C0001M01.XML"], verified: ["C0001M01.XML": goodXML]),
                f.item(["DSC00003.ARW"]),
                f.item(["DSC00004.ARW"]),
                f.item(["DSC00005.ARW"], verified: ["DSC00005.ARW": String(repeating: "0", count: 64)]),
            ]
            let before = try snapshot(f)

            let report = try CardClearService().clear(items: items, nasReachable: true, confirmation: FreeUpService.confirmationToken)

            XCTAssertEqual(report.cleared, [f.card.appendingPathComponent("DSC00001.ARW").path])
            XCTAssertFalse(report.usedRecordedNASHashes)
            XCTAssertFalse(exists(f.card.appendingPathComponent("DSC00001.ARW")))
            for name in names.dropFirst() {
                XCTAssertTrue(exists(f.card.appendingPathComponent(name)), name)
                XCTAssertNotNil(report.skipped[f.card.appendingPathComponent(name).path], name)
            }
            XCTAssertEqual(report.skipped.count, names.count - 1)
            XCTAssertTrue(report.skipped[f.card.appendingPathComponent("DSC00002.ARW").path]?.contains("Sync to NAS verified") == true)
            XCTAssertTrue(report.skipped[f.card.appendingPathComponent("C0001.MP4").path]?.contains("C0001M01.XML") == true)
            XCTAssertTrue(report.skipped[f.card.appendingPathComponent("DSC00003.ARW").path]?.contains("NAS copy differs") == true)
            XCTAssertTrue(report.skipped[f.card.appendingPathComponent("DSC00004.ARW").path]?.contains("NAS copy is missing") == true)
            // Drive and NAS copies are byte-for-byte as they were.
            XCTAssertEqual(try snapshot(f), before)
        }
    }

    func testReportsEachFileWithItsPhaseAndReason() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, ["DSC00001.ARW", "DSC00002.ARW"])
            try Data(repeating: 0x44, count: 2_048).write(to: f.nas.appendingPathComponent("DSC00002.ARW"))
            let settled = SettledFiles()
            let phaseLog = PhaseLog()
            let report = try CardClearService().clear(
                items: [try f.item(["DSC00001.ARW"]), try f.item(["DSC00002.ARW"])],
                nasReachable: true,
                confirmation: FreeUpService.confirmationToken,
                progress: { phaseLog.note($0.phase) },
                fileSettled: { settled.append($0) }
            )
            XCTAssertEqual(phaseLog.all, [CardClearService.verifyPhase, CardClearService.removePhase])
            XCTAssertEqual(report.phases.map(\.label), ["Verify", "Remove"])
            let results = settled.all
            XCTAssertEqual(results.count, 2)
            let kept = try XCTUnwrap(results.first { !$0.removed })
            XCTAssertEqual(kept.phase, "Verify")
            XCTAssertTrue(kept.reason?.contains("NAS copy differs") == true)
            let gone = try XCTUnwrap(results.first { $0.removed })
            XCTAssertEqual(gone.phase, "Remove")
            XCTAssertNil(gone.reason)
        }
    }

    func testAClipAndItsXMLLeaveTogether() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, ["C0002.MP4", "C0002M01.XML"])
            let report = try CardClearService().clear(items: [try f.item(["C0002.MP4", "C0002M01.XML"])], nasReachable: true, confirmation: "DELETE")
            XCTAssertEqual(report.cleared.count, 2)
            XCTAssertFalse(exists(f.card.appendingPathComponent("C0002.MP4")))
            XCTAssertFalse(exists(f.card.appendingPathComponent("C0002M01.XML")))
        }
    }

    func testUnreachableNASFallsBackToTheRecordedHashAndSaysSo() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, ["DSC00001.ARW", "DSC00002.ARW"])
            // The NAS cannot be read at all; only the record speaks for it.
            try FileManager.default.removeItem(at: f.nas)
            let wrong = String(repeating: "f", count: 64)
            let report = try CardClearService().clear(
                items: [try f.item(["DSC00001.ARW"]), try f.item(["DSC00002.ARW"], verified: ["DSC00002.ARW": wrong])],
                nasReachable: false,
                confirmation: FreeUpService.confirmationToken
            )
            XCTAssertTrue(report.usedRecordedNASHashes)
            XCTAssertEqual(report.cleared, [f.card.appendingPathComponent("DSC00001.ARW").path])
            XCTAssertTrue(exists(f.card.appendingPathComponent("DSC00002.ARW")))
            XCTAssertTrue(exists(f.drive.appendingPathComponent("DSC00001.ARW")))
        }
    }

    func testWrongTokenRemovesNothing() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, ["DSC00001.ARW"])
            let items = [try f.item(["DSC00001.ARW"])]
            for token in ["", "delete", "DELETE ", "REMOVE"] {
                XCTAssertThrowsError(try CardClearService().clear(items: items, nasReachable: true, confirmation: token))
            }
            XCTAssertTrue(exists(f.card.appendingPathComponent("DSC00001.ARW")))
        }
    }

    func testCameraSupportFilesAreNeverCleared() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, ["DSC00001.ARW"])
            let preview = root.appendingPathComponent("Card/M4ROOT/THMBNL/C0001T01.JPG")
            try writeFile(preview, Data(repeating: 1, count: 64))
            var item = try f.item(["DSC00001.ARW"])
            item.files[0].sourcePath = preview.path
            let report = try CardClearService().clear(items: [item], nasReachable: true, confirmation: FreeUpService.confirmationToken)
            XCTAssertTrue(report.cleared.isEmpty)
            XCTAssertTrue(exists(preview))
            XCTAssertTrue(exists(f.card.appendingPathComponent("DSC00001.ARW")))
        }
    }
}

private final class SettledFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [CardClearFileResult] = []
    var all: [CardClearFileResult] { lock.withLock { results } }
    func append(_ result: CardClearFileResult) { lock.withLock { results.append(result) } }
}

private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [String] = []
    var all: [String] { lock.withLock { phases } }
    func note(_ phase: String) { lock.withLock { if phases.last != phase { phases.append(phase) } } }
}
