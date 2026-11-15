import CameraToolkitCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class EmbeddedJPEGPreviewExtractorTests: XCTestCase {
    func testSelectsMediumJPEGForThumbnailAndLargestJPEGForFullSize() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("camera.arw")
            let thumbnail = jpegData(length: 70_000, marker: 0x31)
            let fullSize = jpegData(length: 120_000, marker: 0x72)
            let data = tiffData(candidates: [
                (offset: 512, data: thumbnail),
                (offset: 71_000, data: fullSize)
            ])
            try data.write(to: file)

            let extractor = EmbeddedJPEGPreviewExtractor()
            XCTAssertEqual(try extractor.jpegData(from: file, preference: .thumbnail), thumbnail)
            XCTAssertEqual(try extractor.jpegData(from: file, preference: .fullSize), fullSize)
        }
    }

    func testRejectsCandidateThatIsNotJPEGData() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("camera.arw")
            var invalid = Data(repeating: 0x44, count: 70_000)
            invalid[invalid.count - 1] = 0x55
            try tiffData(candidates: [(offset: 512, data: invalid)]).write(to: file)

            XCTAssertNil(try EmbeddedJPEGPreviewExtractor().jpegData(from: file))
        }
    }

    // MARK: The camera's rotation

    func testOrientationTagMapsToQuarterTurnsInBothByteOrders() throws {
        let expected: [(tag: UInt16?, turns: Int)] = [(1, 0), (3, 2), (6, 1), (8, 3), (nil, 0), (2, 0), (4, 0), (5, 0), (7, 0), (9, 0), (0, 0)]
        try withTemporaryDirectory { root in
            for bigEndian in [false, true] {
                for (tag, turns) in expected {
                    let file = root.appendingPathComponent("camera-\(bigEndian)-\(tag.map(String.init) ?? "none").arw")
                    try orientedTIFF(orientation: tag, bigEndian: bigEndian, jpeg: jpegData(length: 70_000, marker: 0x31)).write(to: file)
                    let preview = try XCTUnwrap(EmbeddedJPEGPreviewExtractor().preview(from: file))
                    XCTAssertEqual(preview.cameraQuarterTurns, turns, "tag \(String(describing: tag)) bigEndian \(bigEndian)")
                }
            }
        }
    }

    func testOnlyTheFirstIFDsOrientationCounts() throws {
        // The JPEG's own IFD (and any SubIFD) can carry a different value;
        // only the RAW's IFD0 tag is what the camera recorded.
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("camera.arw")
            try orientedTIFF(orientation: 1, secondIFDOrientation: 8, bigEndian: false, jpeg: jpegData(length: 70_000, marker: 0x31)).write(to: file)
            XCTAssertEqual(try XCTUnwrap(EmbeddedJPEGPreviewExtractor().preview(from: file)).cameraQuarterTurns, 0)
        }
    }

    func testJPEGBytesAreUnchangedForDetection() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("camera.arw")
            let jpeg = jpegData(length: 70_000, marker: 0x31)
            try orientedTIFF(orientation: 8, bigEndian: false, jpeg: jpeg).write(to: file)
            let extractor = EmbeddedJPEGPreviewExtractor()
            XCTAssertEqual(try extractor.jpegData(from: file), jpeg)
            XCTAssertEqual(try extractor.preview(from: file)?.data, jpeg)
        }
    }

    func testAJPEGWithItsOwnRotationNeedsNoCameraTurn() throws {
        try withTemporaryDirectory { root in
            let plain = root.appendingPathComponent("plain.arw")
            let tagged = root.appendingPathComponent("tagged.arw")
            try orientedTIFF(orientation: 8, bigEndian: false, jpeg: try encodedJPEG(orientation: nil)).write(to: plain)
            try orientedTIFF(orientation: 8, bigEndian: false, jpeg: try encodedJPEG(orientation: 6)).write(to: tagged)
            let extractor = EmbeddedJPEGPreviewExtractor()
            XCTAssertEqual(try XCTUnwrap(extractor.preview(from: plain)).cameraQuarterTurns, 3)
            XCTAssertEqual(try XCTUnwrap(extractor.preview(from: tagged)).cameraQuarterTurns, 0, "ImageIO applies the JPEG's own rotation")
        }
    }

    func testMountedRawFixtureWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["CAMERA_TOOLKIT_RAW_FIXTURE"] else { return }
        let data = try XCTUnwrap(
            EmbeddedJPEGPreviewExtractor().jpegData(
                from: URL(fileURLWithPath: path),
                preference: .fullSize
            )
        )
        XCTAssertEqual(Array(data.prefix(2)), [0xff, 0xd8])
        XCTAssertGreaterThan(data.count, 100_000)
    }

    private func encodedJPEG(orientation: Int?) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A one-JPEG TIFF with an orientation tag in IFD0 (SHORT, as cameras
    /// write it), and optionally a second IFD with a different tag.
    private func orientedTIFF(orientation: UInt16?, secondIFDOrientation: UInt16? = nil, bigEndian: Bool, jpeg: Data) -> Data {
        var bytes = Data(repeating: 0, count: 4_096 + jpeg.count)
        let put16: (UInt16, Int) -> Void = { value, offset in
            bytes[offset] = UInt8(bigEndian ? value >> 8 : value & 0xff)
            bytes[offset + 1] = UInt8(bigEndian ? value & 0xff : value >> 8)
        }
        let put32: (UInt32, Int) -> Void = { value, offset in
            let shifts: [UInt32] = bigEndian ? [24, 16, 8, 0] : [0, 8, 16, 24]
            for (index, shift) in shifts.enumerated() { bytes[offset + index] = UInt8((value >> shift) & 0xff) }
        }
        bytes[0] = bigEndian ? 0x4d : 0x49
        bytes[1] = bytes[0]
        put16(42, 2)
        put32(8, 4)
        let jpegOffset = 4_096
        func writeIFD(at start: Int, entries: [(tag: UInt16, type: UInt16, value: UInt32)], next: UInt32) {
            put16(UInt16(entries.count), start)
            for (index, entry) in entries.enumerated() {
                let base = start + 2 + index * 12
                put16(entry.tag, base)
                put16(entry.type, base + 2)
                put32(1, base + 4)
                if entry.type == 3 { put16(UInt16(entry.value), base + 8) } else { put32(entry.value, base + 8) }
            }
            put32(next, start + 2 + entries.count * 12)
        }
        var first: [(tag: UInt16, type: UInt16, value: UInt32)] = []
        if let orientation { first.append((0x0112, 3, UInt32(orientation))) }
        first.append((0x0201, 4, UInt32(jpegOffset)))
        first.append((0x0202, 4, UInt32(jpeg.count)))
        let secondIFD = 512
        writeIFD(at: 8, entries: first, next: secondIFDOrientation == nil ? 0 : UInt32(secondIFD))
        if let secondIFDOrientation {
            writeIFD(at: secondIFD, entries: [(0x0112, 3, UInt32(secondIFDOrientation))], next: 0)
        }
        bytes.replaceSubrange(jpegOffset..<(jpegOffset + jpeg.count), with: jpeg)
        return bytes
    }

    private func jpegData(length: Int, marker: UInt8) -> Data {
        var data = Data(repeating: marker, count: length)
        data[0] = 0xff
        data[1] = 0xd8
        data[length - 2] = 0xff
        data[length - 1] = 0xd9
        return data
    }

    private func tiffData(candidates: [(offset: Int, data: Data)]) -> Data {
        let ifdOffsets = candidates.indices.map { 8 + ($0 * 30) }
        let totalSize = candidates.map { $0.offset + $0.data.count }.max() ?? 8
        var data = Data(repeating: 0, count: totalSize)
        data[0] = 0x49
        data[1] = 0x49
        writeUInt16(42, to: &data, at: 2)
        writeUInt32(UInt32(ifdOffsets[0]), to: &data, at: 4)

        for (index, candidate) in candidates.enumerated() {
            let ifd = ifdOffsets[index]
            writeUInt16(2, to: &data, at: ifd)
            writeEntry(tag: 0x0201, value: UInt32(candidate.offset), to: &data, at: ifd + 2)
            writeEntry(tag: 0x0202, value: UInt32(candidate.data.count), to: &data, at: ifd + 14)
            let next = index + 1 < ifdOffsets.count ? UInt32(ifdOffsets[index + 1]) : 0
            writeUInt32(next, to: &data, at: ifd + 26)
            data.replaceSubrange(candidate.offset..<(candidate.offset + candidate.data.count), with: candidate.data)
        }
        return data
    }

    private func writeEntry(tag: UInt16, value: UInt32, to data: inout Data, at offset: Int) {
        writeUInt16(tag, to: &data, at: offset)
        writeUInt16(4, to: &data, at: offset + 2)
        writeUInt32(1, to: &data, at: offset + 4)
        writeUInt32(value, to: &data, at: offset + 8)
    }

    private func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }
}
