import CameraToolkitCore
import Foundation
import XCTest

final class WorkflowPlannerTests: XCTestCase {
    func testIngestPlanPointsAtBufferBatchAndCanRunSafely() throws {
        try withTemporaryDirectory { root in
            let configuration = configuration(root: root)

            let plan = try XCTUnwrap(WorkflowPlanner().plans(for: configuration).first { $0.kind == .ingestBuffer })

            XCTAssertEqual(plan.status, .ready)
            XCTAssertTrue(plan.steps.contains { $0.isExecutableNow })
            let copyCommand = try XCTUnwrap(plan.steps.first { $0.title == "Copy to Buffer" }?.command)
            XCTAssertEqual(Array(copyCommand.prefix(4)), [
                "/opt/homebrew/bin/rclone",
                "copy",
                root.appendingPathComponent("Card").path,
                root.appendingPathComponent("Buffer/Test Trip/sony-a7v/Card/Originals").path
            ])
            XCTAssertTrue(copyCommand.contains("--checksum"))
            XCTAssertTrue(copyCommand.contains("--immutable"))
            XCTAssertFalse(copyCommand.contains("sync"))
        }
    }

    func testArchivePlanPointsAtBufferAndLockedRcloneCommands() throws {
        try withTemporaryDirectory { root in
            let configuration = configuration(root: root)

            let plan = try XCTUnwrap(WorkflowPlanner().plans(for: configuration).first { $0.kind == .importArchive })

            XCTAssertEqual(plan.status, .locked)
            XCTAssertTrue(plan.steps.allSatisfy { !$0.isExecutableNow })
            let copyCommand = try XCTUnwrap(plan.steps.first { $0.title == "Copy Originals to Library" }?.command)
            XCTAssertEqual(Array(copyCommand.prefix(4)), [
                "/opt/homebrew/bin/rclone",
                "copy",
                root.appendingPathComponent("Buffer/Test Trip/sony-a7v/Card/Originals").path,
                root.appendingPathComponent("Camera Library/Originals/Test Trip/sony-a7v/Card").path
            ])
            XCTAssertTrue(copyCommand.contains("--checksum"))
            XCTAssertTrue(copyCommand.contains("--immutable"))
            XCTAssertFalse(copyCommand.contains("sync"))

            let checkCommand = try XCTUnwrap(plan.steps.first { $0.title == "Check Originals" }?.command)
            XCTAssertEqual(Array(checkCommand.prefix(2)), ["/opt/homebrew/bin/rclone", "check"])
            XCTAssertTrue(checkCommand.contains("--combined"))
        }
    }

    func testFreeUpPlanPointsAtTrashAndNeverPlansDestructiveRcloneSubcommands() throws {
        try withTemporaryDirectory { root in
            let configuration = configuration(root: root)

            let plan = try XCTUnwrap(WorkflowPlanner().plans(for: configuration).first { $0.kind == .freeUpBuffer })

            XCTAssertEqual(plan.status, .locked)
            XCTAssertTrue(plan.steps.contains { $0.detail.contains("_Trash") })
            for command in plan.steps.compactMap(\.command) {
                XCTAssertFalse(command.contains("delete"))
                XCTAssertFalse(command.contains("move"))
                XCTAssertFalse(command.contains("purge"))
                XCTAssertFalse(command.contains("sync"))
            }
        }
    }

    func testImmichPlanNormalizesEndpointAndRequiresKeyGate() throws {
        try withTemporaryDirectory { root in
            var configuration = configuration(root: root)
            configuration.immichServerURL = "photos.local:2283"

            let missingKeyPlan = try XCTUnwrap(WorkflowPlanner().plans(for: configuration, hasImmichAPIKey: false).first { $0.kind == .immichUpload })
            XCTAssertEqual(missingKeyPlan.status, .needsConfig)
            XCTAssertEqual(missingKeyPlan.gates.first { $0.title == "API key in Keychain" }?.isSatisfied, false)

            let readyPlan = try XCTUnwrap(WorkflowPlanner().plans(for: configuration, hasImmichAPIKey: true).first { $0.kind == .immichUpload })
            XCTAssertEqual(readyPlan.status, .locked)
            XCTAssertEqual(readyPlan.steps.first { $0.title == "Upload Photo" }?.endpoint, "http://photos.local:2283/api/assets")
            XCTAssertEqual(readyPlan.steps.first { $0.title == "Upload Photo" }?.detail, "photo bytes, created time, modified time")
        }
    }

    func testMetadataPlanUsesConfiguredExiftoolReadOnlyCommand() throws {
        try withTemporaryDirectory { root in
            let configuration = configuration(root: root)

            let plan = try XCTUnwrap(WorkflowPlanner().plans(for: configuration).first { $0.kind == .metadataRead })

            let command = try XCTUnwrap(plan.steps.first?.command)
            XCTAssertEqual(command, [
                "/opt/homebrew/bin/exiftool",
                "-json",
                "-r",
                root.appendingPathComponent("Card").path
            ])
        }
    }

    private func configuration(root: URL) -> AppConfiguration {
        AppConfiguration(
            demoRootPath: root.appendingPathComponent("Demo").path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Camera Library/Originals").path,
            bufferPath: root.appendingPathComponent("Buffer").path,
            cameraLibraryRootPath: root.appendingPathComponent("Camera Library").path,
            activityLogPath: root.appendingPathComponent("activity-log.jsonl").path,
            immichServerURL: "http://photos.local:2283",
            editorWorkingFolderPath: root.appendingPathComponent("Working Copies").path,
            externalEditor: .preview,
            rcloneBinaryPath: "/opt/homebrew/bin/rclone",
            exiftoolBinaryPath: "/opt/homebrew/bin/exiftool",
            selectedDeviceID: "sony-a7v",
            eventName: "Test Trip",
            importDestination: .nas
        )
    }
}
