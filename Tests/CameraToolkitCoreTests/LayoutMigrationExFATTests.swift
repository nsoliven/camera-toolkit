import CameraToolkitCore
import Darwin
import Foundation
import XCTest

/// The layout migration on a real exFAT volume, where the filesystem —
/// not the executor — renames a file's `._` AppleDouble twin with it and
/// drops a removed folder's twin. Skipped unless
/// `CAMERA_TOOLKIT_EXFAT_TEST_ROOT` names a folder on a mounted exFAT
/// volume that may be written to (a scratch disk image, never a real drive):
///
///     hdiutil create -size 64m -fs ExFAT -volname LMTEST -layout MBRSPUD img.dmg
///     hdiutil attach -nobrowse -mountpoint <scratch>/mnt img.dmg
///     CAMERA_TOOLKIT_EXFAT_TEST_ROOT=<scratch>/mnt swift test --filter LayoutMigrationExFATTests
final class LayoutMigrationExFATTests: XCTestCase {
    func testMigrationAndUndoOnExFAT() throws {
        guard let path = ProcessInfo.processInfo.environment["CAMERA_TOOLKIT_EXFAT_TEST_ROOT"], !path.isEmpty else {
            throw XCTSkip("Set CAMERA_TOOLKIT_EXFAT_TEST_ROOT to a scratch exFAT mount to run this test.")
        }
        var info = statfs()
        guard statfs(path, &info) == 0 else { throw XCTSkip("\(path) is not reachable.") }
        let type = withUnsafeBytes(of: info.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard type == "exfat" else { throw XCTSkip("\(path) is \(type), not exfat.") }
        XCTAssertFalse(path.hasPrefix("/Volumes/"), "use a scratch mount point, never a /Volumes drive")

        let root = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("run-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try withTemporaryDirectory { local in
            let fixture = try LayoutMigrationFixture.make(in: root, support: local.appendingPathComponent("Support", isDirectory: true))
            // A real extended attribute: exFAT stores it in a `._` twin the
            // filesystem itself creates and renames.
            let tagged = fixture.osmoCardCopy.appendingPathComponent("CAM_0001.OSV").path
            XCTAssertEqual(setxattr(tagged, "org.cameratoolkit.test", "tag", 3, 0, 0), 0)
            let treeBefore = try fixture.driveTree()

            let plan = try fixture.plan()
            XCTAssertTrue(plan.isExecutable, plan.blockers.joined(separator: "\n"))
            let twin = try XCTUnwrap(plan.allMoves.first { $0.source.hasSuffix("DJI Osmo 360/Card Copy/._CAM_0001.OSV") })
            XCTAssertEqual(twin.kind, .appleDouble)

            let executor = LayoutMigrationExecutor(
                supportFolder: fixture.support,
                configurationURL: fixture.configurationURL,
                catalogURL: fixture.catalogURL,
                isAppRunning: { false }
            )
            let report = try executor.execute(plan)
            XCTAssertTrue(report.succeeded, report.text)
            let moved = fixture.parentFolder.appendingPathComponent("Originals/Osmo 360/CAM_0001.OSV").path
            var buffer = [UInt8](repeating: 0, count: 8)
            XCTAssertEqual(getxattr(moved, "org.cameratoolkit.test", &buffer, buffer.count, 0, 0), 3, "the xattr traveled with its file")

            let undo = try executor.undo(journalURL: try XCTUnwrap(report.journalURL))
            XCTAssertTrue(undo.succeeded, undo.text)
            let treeAfter = try fixture.driveTree()
            let differing = Set(treeBefore.keys).union(treeAfter.keys).filter { treeBefore[$0] != treeAfter[$0] }.sorted()
            // The filesystem drops a removed folder's `._` twin and may not
            // recreate it; nothing else may differ.
            XCTAssertTrue(differing.allSatisfy { ($0 as NSString).lastPathComponent.hasPrefix("._") && treeAfter[$0] == nil }, "\(differing)")
            XCTAssertEqual(getxattr(tagged, "org.cameratoolkit.test", &buffer, buffer.count, 0, 0), 3)
        }
        try? FileManager.default.removeItem(at: root)
    }
}
