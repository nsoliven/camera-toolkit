import AppKit
@testable import CameraToolkitApp
import XCTest

/// `FaceBoxesOverlay`'s proximity targets reveal a face's chrome while
/// staying transparent to clicks. The regression that hid every box was
/// a target that could not hit-test — SwiftUI's `onHover` goes dead under
/// `allowsHitTesting(false)` — so the AppKit helper pins both halves:
/// a tracking area that can receive hover, and a hit test that never
/// catches a click.
@MainActor
final class HoverTrackingViewTests: XCTestCase {
    private let frame = NSRect(x: 0, y: 0, width: 120, height: 80)

    /// Hover arrives through the tracking area — without one the pointer
    /// can never reach the target and no face ever reveals.
    func testTargetInstallsATrackingArea() {
        let view = HoverTrackingNSView(frame: frame)
        XCTAssertTrue(
            view.trackingAreas.contains { $0.options.contains(.mouseEnteredAndExited) },
            "no enter/exit tracking area — hover can never fire"
        )
    }

    /// Clicks must land on the canvas below: the target is never the
    /// result of a hit test anywhere in its rect.
    func testTargetIsTransparentToHitTesting() {
        let view = HoverTrackingNSView(frame: frame)
        XCTAssertNil(view.hitTest(NSPoint(x: 0, y: 0)))
        XCTAssertNil(view.hitTest(NSPoint(x: frame.midX, y: frame.midY)))
        XCTAssertNil(view.hitTest(NSPoint(x: frame.maxX - 1, y: frame.maxY - 1)))
    }

    /// The crossings the tracking area generates drive the inside state
    /// the overlay uses to show and hide the chrome — and a repeated
    /// edge doesn't double-report.
    func testEnterAndExitReportInside() throws {
        let view = HoverTrackingNSView(frame: frame)
        var reports: [Bool] = []
        view.onChange = { reports.append($0) }

        view.mouseEntered(with: try XCTUnwrap(Self.hoverEvent(.mouseEntered)))
        XCTAssertEqual(reports, [true])
        XCTAssertTrue(view.inside)

        view.mouseExited(with: try XCTUnwrap(Self.hoverEvent(.mouseExited)))
        XCTAssertEqual(reports, [true, false])
        XCTAssertFalse(view.inside)

        view.mouseExited(with: try XCTUnwrap(Self.hoverEvent(.mouseExited)))
        XCTAssertEqual(reports, [true, false])
    }

    private static func hoverEvent(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.enterExitEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )
    }
}
