@testable import CameraToolkitApp
import XCTest

final class PreviewZoomMathTests: XCTestCase {
    private let canvas = CGSize(width: 1_020, height: 820) // usable 1000×800

    func testClampedZoomBounds() {
        XCTAssertEqual(PreviewZoomMath.clampedZoom(0.5), 1)
        XCTAssertEqual(PreviewZoomMath.clampedZoom(3), 3)
        XCTAssertEqual(PreviewZoomMath.clampedZoom(20), PreviewZoomMath.maximumZoom)
    }

    func testAnchoredOffsetKeepsPointUnderPointer() {
        // The image-space point under the anchor must be identical before and
        // after the zoom: (anchor - center - offset) / zoom is invariant.
        let anchor = CGPoint(x: 700, y: 300)
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let offset = CGSize(width: 40, height: -20)
        let fromZoom: CGFloat = 1.5
        let toZoom: CGFloat = 4

        let newOffset = PreviewZoomMath.anchoredOffset(
            anchor: anchor,
            canvasSize: canvas,
            offset: offset,
            fromZoom: fromZoom,
            toZoom: toZoom
        )

        let beforeX = (anchor.x - center.x - offset.width) / fromZoom
        let beforeY = (anchor.y - center.y - offset.height) / fromZoom
        let afterX = (anchor.x - center.x - newOffset.width) / toZoom
        let afterY = (anchor.y - center.y - newOffset.height) / toZoom
        XCTAssertEqual(afterX, beforeX, accuracy: 0.001)
        XCTAssertEqual(afterY, beforeY, accuracy: 0.001)
    }

    func testClampedOffsetIsZeroWhenImageFits() {
        let imageSize = CGSize(width: 800, height: 600)
        let clamped = PreviewZoomMath.clampedOffset(
            CGSize(width: 500, height: 500),
            imageSize: imageSize,
            canvasSize: canvas,
            zoom: 1
        )
        XCTAssertEqual(clamped, .zero)
    }

    func testClampedOffsetCapsAtDisplayedOverflow() {
        // 800×600 pt image in a 1000×800 usable canvas: fit = 1.25 (it upscales
        // to fill), so at 2× the display is 2000×1500 → ±500/±350 pt of pan.
        let imageSize = CGSize(width: 800, height: 600)
        let clamped = PreviewZoomMath.clampedOffset(
            CGSize(width: 10_000, height: -10_000),
            imageSize: imageSize,
            canvasSize: canvas,
            zoom: 2
        )
        XCTAssertEqual(clamped.width, 500, accuracy: 0.001)
        XCTAssertEqual(clamped.height, -350, accuracy: 0.001)
    }

    func testActualSizeZoomAccountsForImageScale() {
        // A 4000 px decode presented at 2000 pt (scale 2) in a 1000×800
        // usable canvas: fit = 0.5, so true 1:1 pixels = 2/0.5 = 4×.
        let imageSize = CGSize(width: 2_000, height: 1_600)
        let zoom = PreviewZoomMath.actualSizeZoom(
            imageSize: imageSize,
            imageScale: 2,
            canvasSize: canvas
        )
        XCTAssertEqual(zoom, 4, accuracy: 0.001)

        // The same image at scale 1 shows its own pixels 1:1 at 1/0.5 = 2×.
        let unscaled = PreviewZoomMath.actualSizeZoom(
            imageSize: imageSize,
            imageScale: 1,
            canvasSize: canvas
        )
        XCTAssertEqual(unscaled, 2, accuracy: 0.001)
    }
}
