import CoreGraphics
import Foundation
import ImageIO
import Vision

/// One detected face on a decoded preview image.
public struct DetectedFace: Sendable {
    /// Normalized face box, bottom-left origin (Vision convention).
    public var boundingBox: CGRect
    /// Vision detection confidence, 0–1.
    public var confidence: Float
    /// Image-left eye, image-right eye, nose tip, and mouth corners in the
    /// decoded image's top-left pixel space. Nil when the landmarks pass
    /// could not form the five points; callers fall back to a box crop.
    public var landmarks: FaceLandmarkSet?

    public init(boundingBox: CGRect, confidence: Float, landmarks: FaceLandmarkSet?) {
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.landmarks = landmarks
    }

    /// The face's pixel size on an image of `pixelSize` — the smaller box
    /// side, so oddly shaped detections do not inflate past the floor.
    public func minimumPixels(onImageOfSize pixelSize: CGSize) -> Double {
        min(boundingBox.width * pixelSize.width, boundingBox.height * pixelSize.height)
    }
}

/// Apple Vision face detection for LOW mode: one rectangles+landmarks pass
/// per photo on a bounded decode. Runs on the Neural Engine and never does
/// identity — that is the CoreML embedder's job.
public enum VisionFaceDetector {
    /// Detects faces in `image` (a bounded decode of `pixelSize`'s native
    /// image), dropping any face whose smaller box side is under
    /// `minimumFacePixels` measured on the *full* image.
    public static func detect(
        in image: CGImage,
        imagePixelSize: CGSize,
        minimumFacePixels: Double
    ) -> [DetectedFace] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard let _ = try? handler.perform([request]),
              let observations = request.results else {
            return []
        }
        return observations.compactMap { observation in
            let box = observation.boundingBox
            let facePixels = min(box.width * imagePixelSize.width, box.height * imagePixelSize.height)
            guard facePixels >= minimumFacePixels else { return nil }
            return DetectedFace(
                boundingBox: box,
                confidence: observation.confidence,
                landmarks: landmarkSet(
                    from: observation,
                    imageSize: CGSize(width: image.width, height: image.height)
                )
            )
        }
    }

    /// Maps Vision's landmark regions onto the five-point ArcFace order.
    /// Vision's `left`/`right` are anatomical; ordering by image x puts the
    /// image-left eye and mouth corner first, matching the template.
    static func landmarkSet(from observation: VNFaceObservation, imageSize: CGSize) -> FaceLandmarkSet? {
        guard let landmarks = observation.landmarks else { return nil }

        func point(_ region: VNFaceLandmarkRegion2D?, at index: Int = 0) -> CGPoint? {
            guard let region, region.pointCount > index else { return nil }
            return region.normalizedPoints[index]
        }

        func centroid(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let region, region.pointCount > 0 else { return nil }
            var x = 0.0
            var y = 0.0
            for point in region.normalizedPoints {
                x += Double(point.x)
                y += Double(point.y)
            }
            return CGPoint(x: x / Double(region.pointCount), y: y / Double(region.pointCount))
        }

        // Pupils are tighter than eye-region centroids when present.
        guard let leftEye = point(landmarks.leftPupil) ?? centroid(landmarks.leftEye),
              let rightEye = point(landmarks.rightPupil) ?? centroid(landmarks.rightEye) else {
            return nil
        }
        // The nose tip is the lowest point of the nose-crest ridge; the nose
        // region centroid is the fallback.
        let noseTip = landmarks.noseCrest?.normalizedPoints.min(by: { $0.y < $1.y })
            .map { CGPoint(x: Double($0.x), y: Double($0.y)) }
            ?? centroid(landmarks.nose)
        guard let noseTip else { return nil }
        // Mouth corners are the outer-lips extremes in face-box space.
        guard let lips = landmarks.outerLips, lips.pointCount >= 2 else { return nil }
        let lipPoints = lips.normalizedPoints
        let mouthA = lipPoints.min(by: { $0.x < $1.x })!
        let mouthB = lipPoints.max(by: { $0.x < $1.x })!

        func toImage(_ point: CGPoint) -> CGPoint {
            // Region points are normalized inside the bounding box with a
            // bottom-left origin; image pixels are top-left origin.
            let normalized = CGPoint(
                x: observation.boundingBox.origin.x + point.x * observation.boundingBox.width,
                y: observation.boundingBox.origin.y + point.y * observation.boundingBox.height
            )
            return CGPoint(
                x: normalized.x * imageSize.width,
                y: (1 - normalized.y) * imageSize.height
            )
        }

        return FaceLandmarkSet(
            eyeA: toImage(leftEye),
            eyeB: toImage(rightEye),
            nose: toImage(noseTip),
            mouthA: toImage(mouthA),
            mouthB: toImage(mouthB)
        )
    }
}

/// Bounded decodes and pixel-size reads shared by the face pipeline. RAW
/// files read their embedded JPEG — the same preview path the burst linker
/// uses — so detection never decodes sensor data.
public enum FaceImageDecoder {
    /// A bounded, orientation-applied decode for detection. Delegates to the
    /// burst linker's preview path: embedded JPEG for RAW, ImageIO otherwise.
    public static func detectionImage(for url: URL, maximumPixelSize: Int) -> CGImage? {
        BurstVisualLinker.previewImage(for: url, maximumPixelSize: maximumPixelSize)
    }

    /// The native pixel size of the image detection actually ran on — for a
    /// RAW that is its embedded JPEG, not the sensor resolution. Read from
    /// image-source properties without decoding pixels.
    public static func pixelSize(of url: URL) -> CGSize? {
        if OrganizeFileClassifier.rawExtensions.contains(url.pathExtension.lowercased()),
           let data = try? EmbeddedJPEGPreviewExtractor().jpegData(from: url, preference: .fullSize),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let size = sourceSize(source) {
            return size
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return sourceSize(source)
    }

    private static func sourceSize(_ source: CGImageSource) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}
