import CameraToolkitCore
import Foundation
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
