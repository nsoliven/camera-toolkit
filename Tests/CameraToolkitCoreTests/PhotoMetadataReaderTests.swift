import Foundation
import ImageIO
@testable import CameraToolkitCore
import XCTest

final class PhotoMetadataReaderTests: XCTestCase {

    func testReadsEXIFFromJPEG() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("shot.jpg")
            try writeJPEGWithEXIF(url)

            let metadata = PhotoMetadataReader.metadata(for: url)
            XCTAssertEqual(metadata.cameraMake, "SONY")
            XCTAssertEqual(metadata.cameraModel, "ILCE-7RM5")
            XCTAssertEqual(metadata.lens, "FE 85mm F1.4 GM")
            XCTAssertEqual(metadata.exposureSeconds ?? -1, 1.0 / 250.0, accuracy: 0.0001)
            XCTAssertEqual(metadata.fNumber ?? -1, 2.8, accuracy: 0.01)
            XCTAssertEqual(metadata.iso, 400)
            XCTAssertEqual(metadata.focalLengthMillimeters ?? -1, 85, accuracy: 0.01)
            XCTAssertEqual(metadata.pixelWidth, 64)
            XCTAssertEqual(metadata.pixelHeight, 48)
            XCTAssertNotNil(metadata.capturedAt)

            // Display strings render the way the inspector shows them.
            XCTAssertEqual(metadata.cameraDisplay, "SONY ILCE-7RM5")
            XCTAssertEqual(metadata.shutterDisplay, "1/250 s")
            XCTAssertEqual(metadata.apertureDisplay, "f/2.8")
            XCTAssertEqual(metadata.isoDisplay, "ISO 400")
            XCTAssertEqual(metadata.focalDisplay, "85 mm")
            XCTAssertEqual(metadata.dimensionsDisplay, "64 × 48")
        }
    }

    func testMissingEXIFYieldsEmptyCameraFields() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("plain.jpg")
            try writeJPEGWithEXIF(url, exif: false)

            let metadata = PhotoMetadataReader.metadata(for: url)
            XCTAssertFalse(metadata.hasCameraFields)
            XCTAssertNil(metadata.cameraDisplay)
            XCTAssertNil(metadata.shutterDisplay)
            // Pixel dimensions still come through — they need no EXIF.
            XCTAssertEqual(metadata.pixelWidth, 64)
        }
    }

    func testNonImageFileYieldsEmptyMetadata() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("clip.mp4")
            try writeFile(url, Data(repeating: 0, count: 256))
            let metadata = PhotoMetadataReader.metadata(for: url)
            XCTAssertFalse(metadata.hasCameraFields)
            XCTAssertNil(metadata.pixelWidth)
        }
    }

    // MARK: - Helpers

    /// A tiny JPEG carrying a full EXIF block when `exif` is set.
    private func writeJPEGWithEXIF(_ url: URL, exif: Bool = true) throws {
        let width = 64
        let height = 48
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw XCTSkip("Could not create a test bitmap")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil
        ) else {
            throw XCTSkip("Could not create a JPEG destination")
        }
        var properties: [CFString: Any] = [:]
        if exif {
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: "SONY",
                kCGImagePropertyTIFFModel: "ILCE-7RM5",
            ]
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: "2025:09:14 10:24:38",
                kCGImagePropertyExifExposureTime: 1.0 / 250.0,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifFocalLength: 85.0,
            ]
            properties[kCGImagePropertyExifAuxDictionary] = [
                kCGImagePropertyExifAuxLensModel: "FE 85mm F1.4 GM",
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("Could not finalize a JPEG")
        }
        try writeFile(url, data as Data)
    }
}
