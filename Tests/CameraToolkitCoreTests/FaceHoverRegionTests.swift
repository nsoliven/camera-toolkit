import CoreGraphics
import Foundation
@testable import CameraToolkitCore
import XCTest

final class FaceHoverRegionTests: XCTestCase {
    /// A narrow displayed box — small enough that the 140-pt chip strip
    /// the overlay centers under it pokes out past the expanded sides.
    private let box = CGRect(x: 100, y: 100, width: 40, height: 60)
    private let margin = FaceHoverRegion.margin

    /// The strip geometry `FaceBoxesOverlay` lays out below the box.
    private var strip: CGRect {
        CGRect(x: box.midX - 70, y: box.maxY, width: 140, height: 28)
    }

    private func contains(_ point: CGPoint) -> Bool {
        FaceHoverRegion.contains(point, boxRect: box, chipStrip: strip)
    }

    func testRectExpandsBoxByMarginAndKeepsStrip() {
        let regions = FaceHoverRegion.rects(boxRect: box, chipStrip: strip)
        XCTAssertEqual(regions.box.minX, box.minX - margin, accuracy: 0.0001)
        XCTAssertEqual(regions.box.minY, box.minY - margin, accuracy: 0.0001)
        XCTAssertEqual(regions.box.maxX, box.maxX + margin, accuracy: 0.0001)
        XCTAssertEqual(regions.box.maxY, box.maxY + margin, accuracy: 0.0001)
        XCTAssertEqual(regions.strip, strip)
    }

    func testPointsInsideAndAroundTheBoxAreNear() {
        XCTAssertTrue(contains(CGPoint(x: box.midX, y: box.midY)))
        // Inside the margin but outside the tight box on every side.
        XCTAssertTrue(contains(CGPoint(x: box.minX - margin / 2, y: box.midY)))
        XCTAssertTrue(contains(CGPoint(x: box.maxX + margin / 2, y: box.midY)))
        XCTAssertTrue(contains(CGPoint(x: box.midX, y: box.minY - margin / 2)))
        XCTAssertTrue(contains(CGPoint(x: box.midX, y: box.maxY + margin / 2)))
        // The expanded edge itself still counts.
        XCTAssertTrue(contains(CGPoint(x: box.minX - margin, y: box.midY)))
    }

    func testPointsBeyondTheMarginAreFar() {
        XCTAssertFalse(contains(CGPoint(x: box.minX - margin - 1, y: box.midY)))
        XCTAssertFalse(contains(CGPoint(x: box.maxX + margin + 1, y: box.midY)))
        XCTAssertFalse(contains(CGPoint(x: box.midX, y: box.minY - margin - 1)))
        // Past the strip below: outside the expanded box and off the strip.
        XCTAssertFalse(contains(CGPoint(x: box.midX, y: strip.maxY + 20)))
        // Way off the photo neighborhood entirely.
        XCTAssertFalse(contains(CGPoint(x: box.minX - 500, y: box.midY)))
    }

    func testChipStripCountsAsNearWhereItPokesPastTheExpandedBox() {
        // The strip is 140 wide around midX; the 40-wide box only expands
        // to 112, so its corners sit outside the expanded box — yet a
        // pointer parked on the chip must keep the face revealed.
        let regions = FaceHoverRegion.rects(boxRect: box, chipStrip: strip)
        XCTAssertGreaterThan(strip.width, regions.box.width)
        XCTAssertTrue(contains(CGPoint(x: strip.minX + 2, y: strip.midY)))
        XCTAssertTrue(contains(CGPoint(x: strip.maxX - 2, y: strip.midY)))
        // Sanity: those x positions really are outside the expanded box.
        XCTAssertFalse(regions.box.contains(CGPoint(x: strip.minX + 2, y: strip.midY)))
    }

    func testTravelFromBoxToChipNeverLeavesTheNeighborhood() {
        // March straight down from the box's bottom edge across the strip:
        // every point on the path is near, so the chrome can't flicker.
        var y = box.maxY - 1
        while y <= strip.maxY {
            XCTAssertTrue(contains(CGPoint(x: box.midX, y: y)), "dropped at y=\(y)")
            y += 1
        }
    }
}
