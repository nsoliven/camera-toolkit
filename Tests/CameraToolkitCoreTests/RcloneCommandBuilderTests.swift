import CameraToolkitCore
import Foundation
import XCTest

final class RcloneCommandBuilderTests: XCTestCase {
    func testDestructiveSubcommandsRejected() throws {
        let builder = RcloneCommandBuilder()

        for subcommand in ["sync", "move", "delete", "purge", "deletefile"] {
            XCTAssertThrowsError(try builder.baseCommand(subcommand)) { error in
                XCTAssertEqual(error as? ToolkitError, .rcloneSubcommandNotAllowed(subcommand))
            }
        }
    }

    func testCopyCommandIncludesChecksumAndImmutableFlags() throws {
        let builder = RcloneCommandBuilder(excludes: ["._*", ".DS_Store"], transfers: 4)
        let command = try builder.copyCommand(source: URL(fileURLWithPath: "/tmp/src"), destination: URL(fileURLWithPath: "/tmp/dst"))

        XCTAssertEqual(Array(command.prefix(2)), ["rclone", "copy"])
        XCTAssertTrue(command.contains("--checksum"))
        XCTAssertTrue(command.contains("--immutable"))
        XCTAssertTrue(command.contains("--exclude"))
        XCTAssertTrue(command.contains(".DS_Store"))
        XCTAssertFalse(command.contains("sync"))
    }

    func testCheckCommandUsesCombinedChecksumOutput() throws {
        let builder = RcloneCommandBuilder()
        let command = try builder.checkCommand(source: URL(fileURLWithPath: "/tmp/src"), destination: URL(fileURLWithPath: "/tmp/dst"))

        XCTAssertEqual(Array(command.prefix(2)), ["rclone", "check"])
        XCTAssertTrue(command.contains("--checksum"))
        XCTAssertTrue(command.contains("--combined"))
        XCTAssertTrue(command.contains("-"))
    }
}
