import CoreGraphics
import Foundation
import ImageIO

/// The five facial landmarks ArcFace alignment needs, in image pixel
/// coordinates with a top-left origin (row 0 is the top of the image).
///
/// Ordering follows the detector convention used by InsightFace/SCRFD:
/// the eye and mouth corner that appear on the *left of the image* come
/// first — for a frontal face those are the subject's right side. Ordering
/// by x coordinate keeps the mapping right for profile faces too.
public struct FaceLandmarkSet: Equatable, Sendable {
    public var leftEye: CGPoint
    public var rightEye: CGPoint
    public var nose: CGPoint
    public var leftMouth: CGPoint
    public var rightMouth: CGPoint

    public init(leftEye: CGPoint, rightEye: CGPoint, nose: CGPoint, leftMouth: CGPoint, rightMouth: CGPoint) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.nose = nose
        self.leftMouth = leftMouth
        self.rightMouth = rightMouth
    }

    /// Eye/mouth points re-ordered by x so index 0 is the image-left side,
    /// matching `FaceAligner.template`.
    public init(eyeA: CGPoint, eyeB: CGPoint, nose: CGPoint, mouthA: CGPoint, mouthB: CGPoint) {
        let eyes = [eyeA, eyeB].sorted { $0.x < $1.x }
        let mouths = [mouthA, mouthB].sorted { $0.x < $1.x }
        self.init(leftEye: eyes[0], rightEye: eyes[1], nose: nose, leftMouth: mouths[0], rightMouth: mouths[1])
    }

    public var points: [CGPoint] { [leftEye, rightEye, nose, leftMouth, rightMouth] }
}

/// Warps a detected face to the normalized 112×112 ArcFace input.
public enum FaceAligner {
    public static let outputSize = 112

    /// The canonical ArcFace 112×112 landmark positions (InsightFace
    /// `arcface_dst`), in output pixel coordinates with a top-left origin.
    public static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// Least-squares 2D similarity transform (scale + rotation + translation,
    /// no reflection) mapping `source` points onto `destination` points.
    ///
    /// For centered point sets the solution is `R = [[a, -b], [b, a]]` with
    /// `a = Σ(d.x·s.x + d.y·s.y) / Σ|s|²` and `b = Σ(d.y·s.x − d.x·s.y) / Σ|s|²`,
    /// then `t = μd − R·μs`.
    public static func similarityTransform(from source: [CGPoint], to destination: [CGPoint]) -> CGAffineTransform {
        precondition(source.count == destination.count && !source.isEmpty)
        let n = Double(source.count)
        let sourceMean = mean(source)
        let destinationMean = mean(destination)

        var numeratorA = 0.0
        var numeratorB = 0.0
        var denominator = 0.0
        for index in source.indices {
            let s = CGPoint(x: source[index].x - sourceMean.x, y: source[index].y - sourceMean.y)
            let d = CGPoint(x: destination[index].x - destinationMean.x, y: destination[index].y - destinationMean.y)
            numeratorA += d.x * s.x + d.y * s.y
            numeratorB += d.y * s.x - d.x * s.y
            denominator += s.x * s.x + s.y * s.y
        }
        guard denominator > 0 else { return .identity }
        let a = numeratorA / denominator
        let b = numeratorB / denominator
        let tx = destinationMean.x - (a * sourceMean.x - b * sourceMean.y)
        let ty = destinationMean.y - (b * sourceMean.x + a * sourceMean.y)
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    /// Renders the face aligned to the ArcFace template as a 112×112 RGB
    /// image. `landmarks` are in the image's pixel space (top-left origin).
    ///
    /// The similarity transform is computed in the CGContext's own
    /// bottom-left space so the draw lands upright without a flip pass.
    public static func alignedImage(_ image: CGImage, landmarks: FaceLandmarkSet) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let size = outputSize

        // Convert top-left-origin image points and template points into the
        // context's bottom-left coordinate space.
        let source = landmarks.points.map { CGPoint(x: $0.x, y: Double(height) - $0.y) }
        let destination = template.map { CGPoint(x: $0.x, y: Double(size) - $0.y) }
        let transform = similarityTransform(from: source, to: destination)

        guard let context = RGBContext(width: size, height: size) else { return nil }
        context.interpolationQuality = .high
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Fallback when landmarks are unavailable: scale the face box (slightly
    /// expanded, like the detector crops ArcFace was trained with) straight
    /// into 112×112. `box` is normalized with a bottom-left origin.
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

    /// JPEG bytes of an aligned crop for review surfaces.
    public static func jpegData(_ image: CGImage, quality: Double = 0.82) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
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

    private static func mean(_ points: [CGPoint]) -> CGPoint {
        var x = 0.0
        var y = 0.0
        for point in points {
            x += point.x
            y += point.y
        }
        let n = Double(points.count)
        return CGPoint(x: x / n, y: y / n)
    }
}
