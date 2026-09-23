import AppKit
@testable import CameraToolkitApp
import XCTest

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testPanesAreTheFiveToolbarTabsInOrder() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title), ["Locations", "Library", "Organizing", "Services", "Advanced"])
        for pane in SettingsPane.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil), "\(pane.symbol) must exist")
            XCTAssertGreaterThanOrEqual(pane.contentSize.width, 620)
            XCTAssertGreaterThan(pane.contentSize.height, 200)
        }
        XCTAssertEqual(Set(SettingsPane.allCases.map(\.toolbarIdentifier)).count, SettingsPane.allCases.count)
    }

    func testFitKeepsTheTitleBarInPlace() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 680, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        let top = window.frame.maxY
        SettingsTabViewController.fit(window, to: SettingsPane.advanced.contentSize, animate: false)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, SettingsPane.advanced.contentSize)
    }
}
