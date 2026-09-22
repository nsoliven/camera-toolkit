import CameraToolkitCore
import CoreGraphics
import Foundation
import XCTest

/// "Rotate Burst" turns a whole stack at once and never writes a byte to the
/// media files: the turn is recorded as a display orientation keyed by file
/// identity, then applied at decode time.
final class DisplayRotationTests: XCTestCase {
    private let fileSize: Int64 = 1_234_567
    private let mtime = Date(timeIntervalSince1970: 1_757_760_000)

    private func file(_ name: String, in folder: String = "/Volumes/card/DCIM") -> OrganizeFile {
        OrganizeFile(path: "\(folder)/\(name)", size: fileSize, modifiedAt: mtime)
    }

    private func item(_ file: OrganizeFile, companions: [OrganizeFile] = []) -> OrganizeItem {
        OrganizeItem(
            primary: file,
            companions: companions,
            kind: OrganizeFileClassifier.kind(forExtension: file.fileExtension),
            captureDate: mtime,
            hasCameraDate: true
        )
    }

    // MARK: Rotatability

    func testStillsAndVideoPostersRotate_sidecarsAndOtherFilesDoNot() {
        let stack = OrganizeStack(items: [
            item(file("A0001.DSC0001.ARW")),
            item(file("A0001.DSC0002.JPG")),
            item(file("A0001.DSC0003.MP4")),
            item(file("A0001.DSC0004.XMP")),
            item(file("A0001.DSC0005.SRT")),
        ])

        let names = Set(DisplayRotation.rotatableFiles(in: stack).map(\.name))

        XCTAssertEqual(names, ["A0001.DSC0001.ARW", "A0001.DSC0002.JPG", "A0001.DSC0003.MP4"])
    }

    func testBurstWithCompanions_rotatesCompanionsButNotXMP() {
        let raw = file("B0001_DSC00001.ARW")
        let keep = file("B0001_DSC00001.JPG")
        let xmp = file("B0001_DSC00001.xmp")
        let second = file("B0001_DSC00002.ARW")
        let stack = OrganizeStack(items: [
            item(raw, companions: [keep, xmp]),
            item(second),
        ])

        let map = DisplayRotation.rotatedMap([:], applying: 1, to: stack)

        XCTAssertEqual(map[DisplayRotation.fileKey(for: raw)], 1)
        XCTAssertEqual(map[DisplayRotation.fileKey(for: keep)], 1)
        XCTAssertEqual(map[DisplayRotation.fileKey(for: second)], 1)
        XCTAssertNil(map[DisplayRotation.fileKey(for: xmp)])
        XCTAssertEqual(map.count, 3)
    }

    // MARK: Same delta for every frame

    func testEveryRotatableFileReceivesTheSameDelta() {
        let stack = OrganizeStack(items: [
            item(file("B0001_DSC00001.ARW"), companions: [file("B0001_DSC00001.JPG")]),
            item(file("B0001_DSC00002.ARW"), companions: [file("B0001_DSC00002.JPG")]),
        ])

        let ccw = DisplayRotation.rotatedMap([:], applying: -1, to: stack)
        for rotatable in DisplayRotation.rotatableFiles(in: stack) {
            XCTAssertEqual(ccw[DisplayRotation.fileKey(for: rotatable)], 3)
        }

        let oneEighty = DisplayRotation.rotatedMap([:], applying: 2, to: stack)
        for rotatable in DisplayRotation.rotatableFiles(in: stack) {
            XCTAssertEqual(oneEighty[DisplayRotation.fileKey(for: rotatable)], 2)
        }
    }

    // MARK: Wrapping and cleanup

    func testTurnsWrapModuloFour_andDropOutAtZero() {
        let a = file("B0001_DSC00001.ARW")
        let stack = OrganizeStack(items: [item(a), item(file("B0001_DSC00002.ARW"))])

        var map = DisplayRotation.rotatedMap([:], applying: 3, to: stack)
        XCTAssertEqual(map[DisplayRotation.fileKey(for: a)], 3)

        // One more CW turn wraps 3 → 0 and removes the key entirely.
        map = DisplayRotation.rotatedMap(map, applying: 1, to: stack)
        XCTAssertTrue(map.isEmpty)
    }

    func testOtherStacksKeepTheirRotation() {
        let rotated = file("B0001_DSC00001.ARW")
        let untouched = file("B0001_DSC00002.ARW")

        var map = DisplayRotation.rotatedMap([:], applying: 1, to: OrganizeStack(items: [item(untouched)]))
        map = DisplayRotation.rotatedMap(map, applying: 2, to: OrganizeStack(items: [item(rotated)]))

        XCTAssertEqual(map[DisplayRotation.fileKey(for: rotated)], 2)
        XCTAssertEqual(map[DisplayRotation.fileKey(for: untouched)], 1)
    }

    // MARK: File identity survives moves

    func testFileKeyIsStableAcrossFolders() {
        let onCard = file("B0001_DSC00001.ARW", in: "/Volumes/card/DCIM")
        let onNas = file("B0001_DSC00001.ARW", in: "/nas/photos/2026")

        XCTAssertEqual(DisplayRotation.fileKey(for: onCard), DisplayRotation.fileKey(for: onNas))
    }

    func testTurnsLookupNormalizesStoredValues() {
        let f = file("B0001_DSC00001.ARW")
        XCTAssertEqual(DisplayRotation.turns(for: f, in: [DisplayRotation.fileKey(for: f): 5]), 1)
    }

    // MARK: Pixel correctness — the burst actually turns

    /// 2×1 image: red left, green right.
    private func twoPixelImage() -> CGImage? {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255]
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: 2,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Reads back the RGBA pixels of a small CGImage (buffer row 0 = the row
    /// displayed at the top).
    private func pixels(of image: CGImage) -> [UInt8]? {
        let bytesPerRow = image.width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        guard let context = CGContext(
            data: &buffer,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    /// Is the pixel at (x, y) red (1), green (2), or other (0)?
    private func color(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> Int {
        let offset = (y * width + x) * 4
        if pixels[offset] > 200 && pixels[offset + 1] < 50 { return 1 }
        if pixels[offset + 1] > 200 && pixels[offset] < 50 { return 2 }
        return 0
    }

    func testQuarterTurnCWMovesLeftPixelToTop() throws {
        let source = try XCTUnwrap(twoPixelImage())
        let rotated = try XCTUnwrap(DisplayRotation.rotate(source, quarterTurnsCW: 1))
        XCTAssertEqual(rotated.width, 1)
        XCTAssertEqual(rotated.height, 2)
        let px = try XCTUnwrap(pixels(of: rotated))
        // A CW turn lifts the source's left edge to the top.
        XCTAssertEqual(color(px, width: 1, x: 0, y: 0), 1)
        XCTAssertEqual(color(px, width: 1, x: 0, y: 1), 2)
    }

    func testQuarterTurnCCWMovesLeftPixelToBottom() throws {
        let source = try XCTUnwrap(twoPixelImage())
        let rotated = try XCTUnwrap(DisplayRotation.rotate(source, quarterTurnsCW: -1))
        XCTAssertEqual(rotated.width, 1)
        XCTAssertEqual(rotated.height, 2)
        let px = try XCTUnwrap(pixels(of: rotated))
        XCTAssertEqual(color(px, width: 1, x: 0, y: 1), 1)
        XCTAssertEqual(color(px, width: 1, x: 0, y: 0), 2)
    }

    func testHalfTurnSwapsPixels() throws {
        let source = try XCTUnwrap(twoPixelImage())
        let rotated = try XCTUnwrap(DisplayRotation.rotate(source, quarterTurnsCW: 2))
        XCTAssertEqual(rotated.width, 2)
        XCTAssertEqual(rotated.height, 1)
        let px = try XCTUnwrap(pixels(of: rotated))
        XCTAssertEqual(color(px, width: 2, x: 0, y: 0), 2)
        XCTAssertEqual(color(px, width: 2, x: 1, y: 0), 1)
    }

    func testZeroAndFullTurnsReturnTheSource() throws {
        let source = try XCTUnwrap(twoPixelImage())
        XCTAssertTrue(DisplayRotation.rotate(source, quarterTurnsCW: 0) === source)
        XCTAssertTrue(DisplayRotation.rotate(source, quarterTurnsCW: 4) === source)
        XCTAssertTrue(DisplayRotation.rotate(source, quarterTurnsCW: -4) === source)
    }

    // MARK: Rotation never writes to the files

    /// Rotating a scanned burst flips the map only — every byte under the
    /// folder, including the RAWs, is identical afterwards.
    func testRotatingAScannedBurstLeavesEveryByteOnDisk() throws {
        try withTemporaryDirectory { root in
            let raw1 = try writeFakeARW(
                root.appendingPathComponent("B0001_DSC00001.ARW"),
                captureTime: "2026:08:26 10:00:00"
            )
            let raw2 = try writeFakeARW(
                root.appendingPathComponent("B0001_DSC00002.ARW"),
                captureTime: "2026:08:26 10:00:00"
            )
            let jpg = root.appendingPathComponent("B0001_DSC00002.JPG")
            try Data("<jpeg companion>".utf8).write(to: jpg)

            let beforeBytes = try [raw1, raw2, jpg].map { try Data(contentsOf: $0) }
            let beforeListing = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()

            let result = try OrganizeScanner().scan(root: root)
            let burst = try XCTUnwrap(result.days.flatMap(\.stacks).first { $0.isBurst })

            _ = DisplayRotation.rotatedMap([:], applying: 1, to: burst)

            XCTAssertEqual(try [raw1, raw2, jpg].map { try Data(contentsOf: $0) }, beforeBytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), beforeListing)
        }
    }
}
