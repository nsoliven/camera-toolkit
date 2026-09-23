import AppKit
@testable import CameraToolkitApp
import XCTest

@MainActor
final class WindowSizingTests: XCTestCase {
    func testEveryPopOutHasAUsableMinimumSize() {
        XCTAssertEqual(CameraToolkitPopOutWindow.allCases.count, 7)
        for kind in CameraToolkitPopOutWindow.allCases {
            XCTAssertGreaterThanOrEqual(kind.minimumContentSize.width, 620)
            XCTAssertGreaterThanOrEqual(kind.minimumContentSize.height, 440)
        }
    }

    func testSharedSizingPolicyMakesWindowResizableWithoutSmallMaximumCap() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.maxSize = NSSize(width: 800, height: 700)

        CameraToolkitWindowSizing.configure(window, as: .settings)

        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, CameraToolkitPopOutWindow.settings.minimumContentSize)
        XCTAssertGreaterThan(window.maxSize.width, 10_000)
        XCTAssertGreaterThan(window.maxSize.height, 10_000)
    }
}
