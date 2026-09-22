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

    func testDisplayedImageRectCentersFitAndAppliesPan() {
        // 800×600 pt image in a 1000×800 usable canvas → fit 1.25 → the
        // displayed rect is 1000×750 centered in the 1020×820 canvas.
        let imageSize = CGSize(width: 800, height: 600)
        let rect = PreviewZoomMath.displayedImageRect(
            imageSize: imageSize,
            canvasSize: canvas,
            zoom: 1,
            offset: .zero
        )
        XCTAssertEqual(rect.width, 1_000, accuracy: 0.001)
        XCTAssertEqual(rect.height, 750, accuracy: 0.001)
        XCTAssertEqual(rect.midX, canvas.width / 2, accuracy: 0.001)
        XCTAssertEqual(rect.midY, canvas.height / 2, accuracy: 0.001)

        // At 2× with a pan the rect scales about the center and shifts.
        let zoomed = PreviewZoomMath.displayedImageRect(
            imageSize: imageSize,
            canvasSize: canvas,
            zoom: 2,
            offset: CGSize(width: 30, height: -40)
        )
        XCTAssertEqual(zoomed.width, 2_000, accuracy: 0.001)
        XCTAssertEqual(zoomed.midX, canvas.width / 2 + 30, accuracy: 0.001)
        XCTAssertEqual(zoomed.midY, canvas.height / 2 - 40, accuracy: 0.001)
    }

    func testNormalizedMarkupRectClampsToImageFrame() {
        let frame = CGRect(x: 110, y: 35, width: 800, height: 750)
        // A quarter-frame box in the middle → 0.25–0.75 normalized.
        let normalized = PreviewZoomMath.normalizedMarkupRect(
            canvasRect: CGRect(x: 310, y: 222.5, width: 400, height: 375),
            imageFrame: frame
        )
        XCTAssertEqual(normalized?.minX ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(normalized?.minY ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(normalized?.width ?? -1, 0.5, accuracy: 0.001)

        // A rect drawn partly off the photo clamps to the image edge:
        // 60...460 clamps to the frame's left edge 110 → 350/800 wide.
        let offEdge = PreviewZoomMath.normalizedMarkupRect(
            canvasRect: CGRect(x: 60, y: 35, width: 400, height: 300),
            imageFrame: frame
        )
        XCTAssertEqual(offEdge?.minX ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(offEdge?.width ?? -1, 0.4375, accuracy: 0.001)

        // Click-sized rects and rects fully off the photo are dropped.
        XCTAssertNil(PreviewZoomMath.normalizedMarkupRect(
            canvasRect: CGRect(x: 300, y: 300, width: 4, height: 4),
            imageFrame: frame
        ))
        XCTAssertNil(PreviewZoomMath.normalizedMarkupRect(
            canvasRect: CGRect(x: 0, y: 0, width: 40, height: 20),
            imageFrame: frame
        ))
        XCTAssertNil(PreviewZoomMath.normalizedMarkupRect(
            canvasRect: CGRect(x: 300, y: 300, width: 40, height: 40),
            imageFrame: .zero
        ))
    }
}
