import AppKit
import SwiftUI
@testable import CameraToolkitApp
import XCTest

@MainActor
final class WindowFactoryTests: XCTestCase {
    func testFactoryBuildsANativeToolbarWindow() throws {
        let identifier = "CameraToolkitWindowFactoryTests-\(UUID().uuidString)"
        let window = CameraToolkitWindowFactory.make(
            .trash,
            identifier: identifier,
            title: "Factory Test",
            initialContentSize: NSSize(width: 900, height: 600),
            rootView: Text("Hello")
        )
        defer {
            window.close()
            NSWindow.removeFrame(usingName: identifier)
        }

        XCTAssertEqual(window.identifier?.rawValue, identifier)
        XCTAssertEqual(window.frameAutosaveName, identifier)
        XCTAssertEqual(window.title, "Factory Test")
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertNotNil(window.toolbar)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertFalse(window.isRestorable)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        // With a full-size content view the title bar counts toward the
        // content area, so the minimum can only grow past the table value.
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, CameraToolkitPopOutWindow.trash.minimumContentSize.width)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, CameraToolkitPopOutWindow.trash.minimumContentSize.height)

        let host = try XCTUnwrap(window.contentViewController as? NSHostingController<Text>)
        XCTAssertTrue(host.sceneBridgingOptions.contains(.title))
        XCTAssertTrue(host.sceneBridgingOptions.contains(.toolbars))
    }

    func testFactoryHonoursACompactToolbarStyle() {
        let identifier = "CameraToolkitWindowFactoryTests-\(UUID().uuidString)"
        let window = CameraToolkitWindowFactory.make(
            .keyboardShortcuts,
            identifier: identifier,
            title: "Compact",
            initialContentSize: NSSize(width: 720, height: 650),
            toolbarStyle: .unifiedCompact,
            rootView: EmptyView()
        )
        defer {
            window.close()
            NSWindow.removeFrame(usingName: identifier)
        }
        XCTAssertEqual(window.toolbarStyle, .unifiedCompact)
    }

    func testPeopleHasItsOwnMinimumSize() {
        XCTAssertEqual(CameraToolkitPopOutWindow.people.minimumContentSize, NSSize(width: 640, height: 440))
    }
}
