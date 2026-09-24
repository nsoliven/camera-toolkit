import AppKit
import CameraToolkitCore
@testable import CameraToolkitApp
import XCTest

@MainActor
final class CrashReportingTests: XCTestCase {
    func testAlertSaysWhatHappenedAndOffersTheLog() {
        let notice = CrashNotice(
            reason: "more Update Constraints in Window passes than there are views",
            files: [URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("crash-x.log")],
            details: "details"
        )
        let alert = CrashReporting.makeAlert(for: notice)
        XCTAssertEqual(alert.messageText, "Camera Toolkit quit unexpectedly last time")
        XCTAssertTrue(alert.informativeText.hasPrefix(notice.reason))
        XCTAssertEqual(alert.buttons.map(\.title), ["OK", "Show Log in Finder", "Copy Details"])
        XCTAssertTrue(alert.buttons[1].isEnabled)
    }

    func testShowLogIsDisabledWithoutFilesAndLongReasonsAreCut() {
        let notice = CrashNotice(reason: String(repeating: "r", count: 500), files: [], details: "")
        let alert = CrashReporting.makeAlert(for: notice)
        XCTAssertFalse(alert.buttons[1].isEnabled)
        XCTAssertLessThan(alert.informativeText.count, 400)
    }
}
