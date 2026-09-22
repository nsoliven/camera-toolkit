import CoreGraphics
import Foundation
@testable import CameraToolkitCore
import XCTest

final class FaceBoxProjectionTests: XCTestCase {

    func testTopLeftConversionFlipsY() {
        // A box hugging the bottom-left of the photo (y=0 in Vision space)
        // sits near the bottom in top-left space.
        let box = NormalizedFaceBox(x: 0.1, y: 0.0, width: 0.2, height: 0.3)
        let topLeft = FaceBoxProjection.topLeftRect(of: box)
        XCTAssertEqual(topLeft.minX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(topLeft.minY, 0.7, accuracy: 0.0001)
        XCTAssertEqual(topLeft.width, 0.2, accuracy: 0.0001)
        XCTAssertEqual(topLeft.height, 0.3, accuracy: 0.0001)

        // And the inverse restores the stored box (within float noise).
        let restored = FaceBoxProjection.box(ofTopLeftRect: topLeft)
        XCTAssertEqual(restored.x, box.x, accuracy: 0.0001)
        XCTAssertEqual(restored.y, box.y, accuracy: 0.0001)
        XCTAssertEqual(restored.width, box.width, accuracy: 0.0001)
        XCTAssertEqual(restored.height, box.height, accuracy: 0.0001)
    }

    func testQuarterTurnRotationsMatchDisplayRotation() {
        // A face in the top-left quadrant of the displayed photo.
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2)

        // One quarter-turn CW: top-left lands at top-right; w/h swap.
        let cw = FaceBoxProjection.rotatedTopLeftRect(rect, quarterTurnsCW: 1)
        XCTAssertEqual(cw.minX, 0.6, accuracy: 0.0001)   // 1 - 0.2 - 0.2
        XCTAssertEqual(cw.minY, 0.1, accuracy: 0.0001)
        XCTAssertEqual(cw.width, 0.2, accuracy: 0.0001)
        XCTAssertEqual(cw.height, 0.3, accuracy: 0.0001)

        // 180°: flips both axes, w/h preserved.
        let half = FaceBoxProjection.rotatedTopLeftRect(rect, quarterTurnsCW: 2)
        XCTAssertEqual(half.minX, 0.6, accuracy: 0.0001) // 1 - 0.1 - 0.3
        XCTAssertEqual(half.minY, 0.6, accuracy: 0.0001) // 1 - 0.2 - 0.2
        XCTAssertEqual(half.width, 0.3, accuracy: 0.0001)

        // Three quarter-turns: top-left lands at bottom-left.
        let ccw = FaceBoxProjection.rotatedTopLeftRect(rect, quarterTurnsCW: 3)
        XCTAssertEqual(ccw.minX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(ccw.minY, 0.6, accuracy: 0.0001)  // 1 - 0.1 - 0.3
        XCTAssertEqual(ccw.width, 0.2, accuracy: 0.0001)
    }

    func testRotationAndUnrotationAreInverses() {
        let rect = CGRect(x: 0.05, y: 0.3, width: 0.25, height: 0.4)
        for turns in 0...3 {
            let rotated = FaceBoxProjection.rotatedTopLeftRect(rect, quarterTurnsCW: turns)
            let restored = FaceBoxProjection.unrotatedTopLeftRect(rotated, quarterTurnsCW: turns)
            XCTAssertEqual(restored.minX, rect.minX, accuracy: 0.0001, "turns=\(turns)")
            XCTAssertEqual(restored.minY, rect.minY, accuracy: 0.0001, "turns=\(turns)")
            XCTAssertEqual(restored.width, rect.width, accuracy: 0.0001, "turns=\(turns)")
            XCTAssertEqual(restored.height, rect.height, accuracy: 0.0001, "turns=\(turns)")
        }
        // Negative turns (e.g. stored rotation undone) normalize correctly.
        let rotated = FaceBoxProjection.rotatedTopLeftRect(rect, quarterTurnsCW: 1)
        let restored = FaceBoxProjection.rotatedTopLeftRect(rotated, quarterTurnsCW: -1)
        XCTAssertEqual(restored.minX, rect.minX, accuracy: 0.0001)
        XCTAssertEqual(restored.minY, rect.minY, accuracy: 0.0001)
    }
}
