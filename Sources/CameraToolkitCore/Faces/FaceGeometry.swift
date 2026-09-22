import CoreGraphics
import Foundation

/// Renders the plain box crop a manual tag stores as its thumbnail. The
/// engine's own aligned crops come from the sidecar; nothing here feeds
/// the embedder.
public enum FaceCropRenderer {
    public static let outputSize = 112

    /// Scales the face box (slightly expanded so chin and forehead survive)
    /// straight into 112×112. `box` is normalized with a bottom-left origin.
    public static func boxCrop(_ image: CGImage, box: CGRect) -> CGImage? {
        let width = Double(image.width)
        let height = Double(image.height)
        guard width > 0, height > 0 else { return nil }

        // `box` is normalized with a bottom-left origin (Vision); CGImage
        // pixel space is top-left origin, so flip y before scaling.
        var rect = CGRect(
            x: box.origin.x * width,
            y: (1 - box.origin.y - box.height) * height,
            width: box.width * width,
            height: box.height * height
        )
        // Grow ~25% so chin/forehead survive the crop, clipped to the image.
        let growX = rect.width * 0.125
        let growY = rect.height * 0.125
        rect = rect.insetBy(dx: -growX, dy: -growY)
        let pixelRect = CGRect(
            x: max(0, rect.origin.x),
            y: max(0, rect.origin.y),
            width: min(rect.width, width - max(0, rect.origin.x)),
            height: min(rect.height, height - max(0, rect.origin.y))
        ).integral
        guard pixelRect.width >= 8, pixelRect.height >= 8,
              let cropped = image.cropping(to: pixelRect) else { return nil }

        guard let context = RGBContext(width: outputSize, height: outputSize) else { return nil }
        context.interpolationQuality = .high
        // CGContext.draw renders the image upright inside the rect, so the
        // output bitmap reads top-down without any flip.
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
        return context.makeImage()
    }

    /// An sRGB 8-bit bitmap context sized `width`×`height`.
    static func RGBContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}

/// Projection between stored face boxes and the space a preview draws in.
///
/// `NormalizedFaceBox` is normalized with a bottom-left origin (Vision's
/// convention, matching what the detector produced). SwiftUI and CoreGraphics
/// drawing code work in top-left-origin space, and the burst preview may
/// rotate the decoded image by whole quarter-turns via `DisplayRotation` —
/// these helpers convert a stored box to the rotated display space and a
/// hand-drawn rect back to the stored space. Pure math, so it stays
/// testable away from the views.
public enum FaceBoxProjection {
    /// A stored box as a top-left-origin normalized rect.
    public static func topLeftRect(of box: NormalizedFaceBox) -> CGRect {
        CGRect(x: box.x, y: 1 - box.y - box.height, width: box.width, height: box.height)
    }

    /// A top-left-origin normalized rect as a stored box.
    public static func box(ofTopLeftRect rect: CGRect) -> NormalizedFaceBox {
        NormalizedFaceBox(
            x: rect.minX,
            y: 1 - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Rotates a top-left normalized rect `turns` quarter-turns clockwise —
    /// the same transform `DisplayRotation.rotate` applies to the pixels it
    /// is drawn over.
    public static func rotatedTopLeftRect(_ rect: CGRect, quarterTurnsCW turns: Int) -> CGRect {
        switch DisplayRotation.normalized(turns) {
        case 1:
            return CGRect(
                x: 1 - rect.minY - rect.height,
                y: rect.minX,
                width: rect.height,
                height: rect.width
            )
        case 2:
            return CGRect(
                x: 1 - rect.minX - rect.width,
                y: 1 - rect.minY - rect.height,
                width: rect.width,
                height: rect.height
            )
        case 3:
            return CGRect(
                x: rect.minY,
                y: 1 - rect.minX - rect.width,
                width: rect.height,
                height: rect.width
            )
        default:
            return rect
        }
    }

    /// Inverse of `rotatedTopLeftRect`: the stored-space rect behind a rect
    /// the owner drew on the rotated display.
    public static func unrotatedTopLeftRect(_ rect: CGRect, quarterTurnsCW turns: Int) -> CGRect {
        rotatedTopLeftRect(rect, quarterTurnsCW: -turns)
    }
}

/// The pointer-proximity regions that reveal a stored face's overlay
/// chrome: "near" is the displayed box grown by `margin`, plus the chip
/// strip riding beside the box. The strip stays a separate rect — a chip
/// can sit wider than a narrow face's expanded box, and a single bounding
/// union would add dead corners that reveal the face from too far away.
/// Pure geometry, so the preview's invisible hover targets and the reveal
/// predicate share one definition.
public enum FaceHoverRegion {
    /// Points of slack around a displayed face box that still count as
    /// near — wide enough that the pointer can travel from the box onto
    /// its chip without the chrome vanishing.
    public static let margin: CGFloat = 36

    /// The rects that count as near: the box expanded by `margin` and the
    /// chip strip, both in the overlay's coordinate space.
    public static func rects(
        boxRect: CGRect,
        chipStrip: CGRect,
        margin: CGFloat = Self.margin
    ) -> (box: CGRect, strip: CGRect) {
        (boxRect.insetBy(dx: -margin, dy: -margin), chipStrip)
    }

    /// The predicate the overlay's hover targets implement: inside the
    /// expanded box or on the chip strip.
    public static func contains(
        _ point: CGPoint,
        boxRect: CGRect,
        chipStrip: CGRect,
        margin: CGFloat = Self.margin
    ) -> Bool {
        let regions = rects(boxRect: boxRect, chipStrip: chipStrip, margin: margin)
        return regions.box.contains(point) || regions.strip.contains(point)
    }
}
