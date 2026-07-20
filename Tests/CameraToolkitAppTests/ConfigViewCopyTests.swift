import CameraToolkitCore
@testable import CameraToolkitApp
import XCTest

final class ConfigViewCopyTests: XCTestCase {
    func testLocationRolesExplainTheirActualSelectedMeaning() {
        XCTAssertEqual(ConfiguredLocationRole.importSource.settingsCurrentLabel, "Import Default")
        XCTAssertEqual(ConfiguredLocationRole.importSource.settingsSelectionButtonTitle, "Set as Default")
        XCTAssertTrue(ConfiguredLocationRole.importSource.settingsSelectionExplanation.contains("starts with"))

        XCTAssertEqual(ConfiguredLocationRole.archive.settingsCurrentLabel, "Originals Destination")
        XCTAssertEqual(ConfiguredLocationRole.archive.settingsSelectionButtonTitle, "Use for Originals")
        XCTAssertTrue(ConfiguredLocationRole.archive.settingsSelectionExplanation.contains("permanent"))

        XCTAssertEqual(ConfiguredLocationRole.buffer.settingsCurrentLabel, "Buffer Destination")
        XCTAssertEqual(ConfiguredLocationRole.buffer.settingsSelectionButtonTitle, "Use as Buffer")
        XCTAssertTrue(ConfiguredLocationRole.buffer.settingsSelectionExplanation.contains("temporary"))
    }
}
