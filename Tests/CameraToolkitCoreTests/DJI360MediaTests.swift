import CameraToolkitCore
import CoreGraphics
import Foundation
import XCTest

final class DJI360MediaTests: XCTestCase {
    private func onDisk(_ url: URL) -> OrganizeFile {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return OrganizeFile(
            path: url.standardizedFileURL.path,
            size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: (attributes?[.modificationDate] as? Date) ?? Date()
        )
    }

    private func pairedItem(_ paths: [String]) -> OrganizeItem {
        let files = paths.map { OrganizeFile(path: $0, size: 10, modifiedAt: Date(timeIntervalSince1970: 0)) }
        let pairing = OrganizeFileClassifier.pair(files)
        XCTAssertEqual(pairing.count, 1)
        return OrganizeItem(
            primary: pairing[0].primary,
            companions: pairing[0].companions,
            kind: pairing[0].kind,
            captureDate: Date(timeIntervalSince1970: 0),
            hasCameraDate: false
        )
    }

    // MARK: - Proxy lookup

    func testProxyNameMatchesStemCaseInsensitivelyAndPrefersExactCase() {
        let names = ["CAM_0001_D.OSV", "cam_0001_d.lrf", "CAM_0002_D.LRF", "CAM_0001_D.JPG", "notes.txt"]
        XCTAssertEqual(DJI360Media.proxyName(forClipNamed: "CAM_0001_D.OSV", among: names), "cam_0001_d.lrf")
        XCTAssertEqual(
            DJI360Media.proxyName(forClipNamed: "CAM_0001_D.OSV", among: names + ["CAM_0001_D.LRF"]),
            "CAM_0001_D.LRF"
        )
        XCTAssertEqual(DJI360Media.proxyName(forClipNamed: "cam_0002_d.osv", among: names), "CAM_0002_D.LRF")
        XCTAssertNil(DJI360Media.proxyName(forClipNamed: "CAM_0003_D.OSV", among: names))
        // Only an OSV has a proxy.
        XCTAssertNil(DJI360Media.proxyName(forClipNamed: "CAM_0001_D.JPG", among: names))
    }

    func testProxyURLFindsTheSiblingInTheSameFolderOnly() throws {
        try withTemporaryDirectory { root in
            let card = root.appendingPathComponent("DCIM", isDirectory: true)
            let clip = try writeFile(card.appendingPathComponent("CAM_0001_D.OSV"), "osv")
            try writeFile(card.appendingPathComponent("cam_0001_d.lrf"), "lrf")
            let lonely = try writeFile(card.appendingPathComponent("CAM_0002_D.OSV"), "osv")
            // A same-stem proxy in another folder is not this clip's.
            try writeFile(root.appendingPathComponent("Elsewhere/CAM_0002_D.LRF"), "lrf")

            let proxy = try XCTUnwrap(DJI360Media.proxyURL(forClipAt: clip))
            XCTAssertEqual(proxy.deletingLastPathComponent().standardizedFileURL, card.standardizedFileURL)
            XCTAssertEqual(proxy.lastPathComponent.lowercased(), "cam_0001_d.lrf")
            XCTAssertTrue(FileManager.default.fileExists(atPath: proxy.path))
            XCTAssertNil(DJI360Media.proxyURL(forClipAt: lonely))
            XCTAssertNil(DJI360Media.proxyURL(forClipAt: card.appendingPathComponent("cam_0001_d.lrf")))
        }
    }

    func testPlaybackAndFaceScanUseTheProxyCompanionWithoutTouchingDisk() {
        let paired = pairedItem(["/Card/CAM_0001_D.OSV", "/Card/cam_0001_d.LRF"])
        XCTAssertEqual(DJI360Media.proxy(for: paired)?.name, "cam_0001_d.LRF")
        XCTAssertEqual(DJI360Media.playbackFile(for: paired).name, "cam_0001_d.LRF")
        XCTAssertEqual(DJI360Media.faceScanFile(for: paired).name, "cam_0001_d.LRF")

        let lonely = pairedItem(["/Card/CAM_0002_D.OSV"])
        XCTAssertNil(DJI360Media.proxy(for: lonely))
        XCTAssertEqual(DJI360Media.playbackFile(for: lonely).name, "CAM_0002_D.OSV")

        let ordinary = pairedItem(["/Card/C0001.MP4"])
        XCTAssertEqual(DJI360Media.playbackFile(for: ordinary).name, "C0001.MP4")
    }

    func testMP4ContainersAVFoundationDoesNotKnowByNameGetAMIMEOverride() {
        XCTAssertTrue(CameraVideoAsset.needsMIMEOverride(URL(fileURLWithPath: "/a/CAM_1_D.OSV")))
        XCTAssertTrue(CameraVideoAsset.needsMIMEOverride(URL(fileURLWithPath: "/a/CAM_1_D.lrf")))
        XCTAssertFalse(CameraVideoAsset.needsMIMEOverride(URL(fileURLWithPath: "/a/C0001.MP4")))
        XCTAssertFalse(CameraVideoAsset.needsMIMEOverride(URL(fileURLWithPath: "/a/IMG_1.MOV")))
    }

    // MARK: - Thumbnail precedence

    func testThumbnailSourceOrderPrefersCoverForTilesAndProxyForPosters() {
        XCTAssertEqual(DJI360Media.thumbnailSourceOrder(maximumPixelSize: 384), [.embeddedCover, .proxyFrame, .lensFrame])
        XCTAssertEqual(DJI360Media.thumbnailSourceOrder(maximumPixelSize: 768), [.embeddedCover, .proxyFrame, .lensFrame])
        XCTAssertEqual(DJI360Media.thumbnailSourceOrder(maximumPixelSize: 2_400), [.proxyFrame, .embeddedCover, .lensFrame])
    }

    func testThumbnailFallsBackThroughSourcesAndLooksUpTheProxyLazily() throws {
        let clip = URL(fileURLWithPath: "/Card/CAM_0001_D.OSV")
        let proxy = URL(fileURLWithPath: "/Card/CAM_0001_D.LRF")
        let image = try XCTUnwrap(makeImage(width: 4, height: 2))

        // Tile: the cover answers, so the folder is never consulted.
        var lookups = 0
        var tried: [DJI360Media.ThumbnailSource] = []
        XCTAssertNotNil(DJI360Media.thumbnail(forClipAt: clip, maximumPixelSize: 384, proxyLookup: { _ in
            lookups += 1
            return proxy
        }) { source in
            tried.append(source)
            return image
        })
        XCTAssertEqual(lookups, 0)
        XCTAssertEqual(tried, [.embeddedCover(clip)])

        // No cover: the proxy frame, then the lens as the last resort.
        tried = []
        _ = DJI360Media.thumbnail(forClipAt: clip, maximumPixelSize: 384, proxyLookup: { _ in proxy }) { source in
            tried.append(source)
            return nil
        }
        XCTAssertEqual(tried, [.embeddedCover(clip), .proxyFrame(proxy), .lensFrame(clip)])

        // Poster: proxy first; without a proxy the cover, then the lens.
        tried = []
        lookups = 0
        let poster = DJI360Media.thumbnail(forClipAt: clip, maximumPixelSize: 2_400, proxyLookup: { _ in
            lookups += 1
            return nil
        }) { source in
            tried.append(source)
            return source == .lensFrame(clip) ? image : nil
        }
        XCTAssertNotNil(poster)
        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(tried, [.embeddedCover(clip), .lensFrame(clip)])
    }

    func testCoverArtReaderReadsTheEmbeddedJPEG() throws {
        try withTemporaryDirectory { root in
            let jpeg = try XCTUnwrap(makeImage(width: 64, height: 32).flatMap { FaceImageEncoding.jpegData($0) })
            let cover = box("data", uint32Data360(13) + uint32Data360(0) + jpeg)
            let meta = box("meta", uint32Data360(0) + box("hdlr", Data(repeating: 0, count: 24)) + box("ilst", box("covr", cover)))
            let clip = try writeFile(root.appendingPathComponent("CAM_0001_D.OSV"), makeClip(moov: [box("udta", meta)]))

            XCTAssertEqual(QuickTimeCoverArtReader.imageData(from: clip), jpeg)
            let image = try XCTUnwrap(QuickTimeCoverArtReader.image(from: clip, maximumPixelSize: 384))
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 32)

            let plain = try writeFile(root.appendingPathComponent("CAM_0002_D.OSV"), makeClip(moov: [djiSoftwareUserData("Osmo 360")]))
            XCTAssertNil(QuickTimeCoverArtReader.imageData(from: plain))
            XCTAssertNil(QuickTimeCoverArtReader.imageData(from: try writeFile(root.appendingPathComponent("junk.OSV"), "nope")))
        }
    }

    // MARK: - Grouping carries the proxy

    func testOSVAndItsLRFAreOneItemWhateverTheCase() {
        let files = [
            OrganizeFile(path: "/Card/CAM_0001_D.OSV", size: 100, modifiedAt: .distantPast),
            OrganizeFile(path: "/Card/cam_0001_d.lrf", size: 10, modifiedAt: .distantPast),
            OrganizeFile(path: "/Card/CAM_0002_D.OSV", size: 100, modifiedAt: .distantPast),
            OrganizeFile(path: "/Other/CAM_0002_D.LRF", size: 10, modifiedAt: .distantPast),
        ]
        let byPrimary = Dictionary(uniqueKeysWithValues: OrganizeFileClassifier.pair(files).map { ($0.primary.path, $0) })
        XCTAssertEqual(byPrimary["/Card/CAM_0001_D.OSV"]?.kind, .video)
        XCTAssertEqual(byPrimary["/Card/CAM_0001_D.OSV"]?.companions.map(\.name), ["cam_0001_d.lrf"])
        // A proxy never pairs across folders.
        XCTAssertEqual(byPrimary["/Card/CAM_0002_D.OSV"]?.companions, [])
        XCTAssertEqual(byPrimary["/Other/CAM_0002_D.LRF"]?.kind, .other)
    }

    func testTrashingAnOSVItemCarriesItsLRF() throws {
        try withTemporaryDirectory { root in
            let card = root.appendingPathComponent("Card", isDirectory: true)
            let trash = root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
            try writeFile(card.appendingPathComponent("CAM_0001_D.OSV"), makeClip(moov: [djiSoftwareUserData("Osmo 360")]))
            try writeFile(card.appendingPathComponent("CAM_0001_D.LRF"), makeClip(moov: [djiSoftwareUserData("Osmo 360")]))

            let result = try OrganizeScanner(concurrency: 1).scan(root: card)
            XCTAssertEqual(result.items.count, 1)
            let item = try XCTUnwrap(result.items.first)
            XCTAssertEqual(item.primary.name, "CAM_0001_D.OSV")
            XCTAssertEqual(item.companions.map(\.name), ["CAM_0001_D.LRF"])

            let batch = try MediaTrashService(removedFilesRoot: trash, volumeRoot: { _ in nil }).trash(
                files: item.files,
                originRoot: card,
                context: TrashContext()
            )
            XCTAssertEqual(batch.entries.count, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: card.appendingPathComponent("CAM_0001_D.OSV").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: card.appendingPathComponent("CAM_0001_D.LRF").path))
            let folder = trash.appendingPathComponent(batch.name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("CAM_0001_D.OSV").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("CAM_0001_D.LRF").path))
        }
    }

    func testSortingAndMovingAnOSVItemCarriesItsLRF() throws {
        try withTemporaryDirectory { root in
            let card = root.appendingPathComponent("Card", isDirectory: true)
            let event = root.appendingPathComponent("Events/Beach", isDirectory: true)
            let osvBytes = makeClip(moov: [djiSoftwareUserData("Osmo 360")])
            let lrfBytes = Data("proxy".utf8)
            try writeFile(card.appendingPathComponent("CAM_0001_D.OSV"), osvBytes)
            try writeFile(card.appendingPathComponent("CAM_0001_D.LRF"), lrfBytes)

            let result = try OrganizeScanner(concurrency: 1).scan(root: card)
            let item = try XCTUnwrap(result.items.first)
            // Sorting assigns every file of the item — the LRF included.
            let assignments = OrganizeAssignmentBuilder.assignments(
                for: item.files,
                scanRootPath: card.path,
                duplicateNames: [],
                existingEventAssignments: [],
                eventID: UUID(),
                deviceID: "osmo-360"
            )
            XCTAssertEqual(Set(assignments.map(\.relativePath)), ["CAM_0001_D.OSV", "CAM_0001_D.LRF"])

            // Apply plans one move per assigned file; the pair lands together.
            let moves = item.files.map { file in
                DriveMove(
                    sourcePath: file.path,
                    destinationPath: event.appendingPathComponent(file.name).path,
                    byteCount: file.size
                )
            }
            try FileManager.default.createDirectory(at: event, withIntermediateDirectories: true)
            let report = try DriveMoveService().apply(moves, title: "Apply", journalFolder: nil)
            XCTAssertEqual(report.moved.count, 2)
            XCTAssertTrue(report.skipped.isEmpty)
            XCTAssertEqual(try Data(contentsOf: event.appendingPathComponent("CAM_0001_D.OSV")), osvBytes)
            XCTAssertEqual(try Data(contentsOf: event.appendingPathComponent("CAM_0001_D.LRF")), lrfBytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: card.appendingPathComponent("CAM_0001_D.LRF").path))
        }
    }

    // MARK: - Helpers

    private func makeImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

private func uint32Data360(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
}
