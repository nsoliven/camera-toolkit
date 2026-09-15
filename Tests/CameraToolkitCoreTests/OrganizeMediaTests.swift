import CameraToolkitCore
import Foundation
import XCTest

final class OrganizeMediaTests: XCTestCase {
    func testReadsCaptureTimeFromRAWHeader() throws {
        try withTemporaryDirectory { root in
            let url = try writeFakeARW(root.appendingPathComponent("DSC00001.ARW"), captureTime: "2026:08:27 05:27:53", subseconds: "121")
            let date = try XCTUnwrap(CaptureDateReader.captureDate(of: url))
            XCTAssertEqual(date.timeIntervalSince(exifDate("2026:08:27 05:27:53", subseconds: "121")), 0, accuracy: 0.0005)
            XCTAssertNil(CaptureDateReader.captureDate(tiffHeader: Data("not a tiff".utf8)))
            XCTAssertNil(CaptureDateReader.captureDate(tiffHeader: makeTIFFHeader(captureTime: "2026:08:27 05:27:53").prefix(40)))
        }
    }

    func testCaptureDateCacheRoundTripsAndInvalidatesChangedFiles() throws {
        try withTemporaryDirectory { root in
            let cacheURL = root.appendingPathComponent("capture-dates.json")
            let modified = Date(timeIntervalSince1970: 1_800_000_000)
            let cache = CaptureDateCache(url: cacheURL)
            cache.store(path: "/a.ARW", size: 10, modifiedAt: modified, timestamp: CaptureTimestamp(original: "2026:01:02 03:04:05"))
            cache.store(path: "/b.ARW", size: 10, modifiedAt: modified, timestamp: nil)
            try cache.save()

            let reloaded = CaptureDateCache(url: cacheURL)
            let hit = reloaded.lookup(path: "/a.ARW", size: 10, modifiedAt: modified)
            XCTAssertEqual(hit.flatMap { $0 }?.original, "2026:01:02 03:04:05")
            guard case .some(.none) = reloaded.lookup(path: "/b.ARW", size: 10, modifiedAt: modified) else {
                return XCTFail("A file without a camera timestamp should be cached as a known miss")
            }
            let changed = reloaded.lookup(path: "/a.ARW", size: 11, modifiedAt: modified)
            XCTAssertTrue(changed == nil)
        }
    }

    func testPairsSidecarsRawJPEGTwinsAndSonyClipXML() {
        let now = Date()
        let names = ["DSC00001.ARW", "DSC00001.JPG", "DSC00001.xmp", "C0001.MP4", "C0001M01.XML", "orphan.XML", "Thumbs.db", "IMG_1.HEIC"]
        let files = names.map { OrganizeFile(path: "/card/100MSDCF/\($0)", size: 1, modifiedAt: now) }
        let pairings = OrganizeFileClassifier.pair(files)
        let byPrimary = Dictionary(uniqueKeysWithValues: pairings.map { ($0.primary.name, $0) })

        XCTAssertEqual(Set(byPrimary.keys), ["DSC00001.ARW", "C0001.MP4", "orphan.XML", "IMG_1.HEIC"])
        XCTAssertEqual(byPrimary["DSC00001.ARW"]?.companions.map(\.name), ["DSC00001.JPG", "DSC00001.xmp"])
        XCTAssertEqual(byPrimary["DSC00001.ARW"]?.kind, .raw)
        XCTAssertEqual(byPrimary["C0001.MP4"]?.companions.map(\.name), ["C0001M01.XML"])
        XCTAssertEqual(byPrimary["C0001.MP4"]?.kind, .video)
        XCTAssertEqual(byPrimary["orphan.XML"]?.kind, .other)
        XCTAssertEqual(byPrimary["IMG_1.HEIC"]?.kind, .photo)
    }

    func testParsesBurstPrefixesAndFrameNumbers() {
        XCTAssertEqual(OrganizeFileClassifier.burstPrefix(in: "B0012_DSC01234.ARW"), "B0012_")
        XCTAssertEqual(OrganizeFileClassifier.burstPrefix(in: "B001_DSC01234.ARW"), "B001_")
        XCTAssertNil(OrganizeFileClassifier.burstPrefix(in: "DSC01234.ARW"))
        XCTAssertNil(OrganizeFileClassifier.burstPrefix(in: "Beach_1.JPG"))
        XCTAssertEqual(OrganizeFileClassifier.frameNumber(in: "B0012_DSC01234.ARW"), 1234)
        XCTAssertEqual(OrganizeFileClassifier.frameNumber(in: "C0001.MP4"), 1)
    }

    func testPrefixedFoldersStackByPrefixOnly() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            organizeItem("/s/B0001_DSC00001.ARW", date: t0),
            organizeItem("/s/B0001_DSC00002.ARW", date: t0.addingTimeInterval(0.2)),
            organizeItem("/s/DSC00003.ARW", date: t0.addingTimeInterval(0.4)),
            organizeItem("/s/B0002_DSC00004.ARW", date: t0.addingTimeInterval(10)),
            organizeItem("/s/B0002_DSC00005.ARW", date: t0.addingTimeInterval(10.1)),
        ]
        let stacks = OrganizeStacker.stacks(for: items)
        XCTAssertEqual(stacks.map(\.items.count), [2, 1, 2])
        XCTAssertEqual(stacks.first?.burstLabel, "B0001")
    }

    func testUnprefixedFoldersChainByTimeAndFrameNumber() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            organizeItem("/s/DSC00001.ARW", date: t0),
            organizeItem("/s/DSC00002.ARW", date: t0.addingTimeInterval(0.3)),
            organizeItem("/s/DSC00003.ARW", date: t0.addingTimeInterval(0.6)),
            organizeItem("/s/DSC00004.ARW", date: t0.addingTimeInterval(2.5)),
            organizeItem("/s/DSC00050.ARW", date: t0.addingTimeInterval(2.8)),
            organizeItem("/s/C0001.MP4", kind: .video, date: t0.addingTimeInterval(2.9)),
            organizeItem("/other/DSC00005.ARW", date: t0.addingTimeInterval(0.1)),
        ]
        let stacks = OrganizeStacker.stacks(for: items)
        XCTAssertEqual(stacks.map(\.items.count), [3, 1, 1, 1, 1])
        XCTAssertEqual(stacks[0].items.map(\.primary.name), ["DSC00001.ARW", "DSC00002.ARW", "DSC00003.ARW"])
        XCTAssertEqual(stacks[1].items.first?.primary.path, "/other/DSC00005.ARW")
    }

    func testDaysFollowCameraWallClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let late = exifDate("2026:08:26 23:59:59")
        let early = exifDate("2026:08:27 00:00:01")
        let stacks = OrganizeStacker.stacks(for: [
            organizeItem("/s/DSC00001.ARW", date: late),
            organizeItem("/s/DSC00009.ARW", date: early),
        ])
        let days = OrganizeStacker.days(for: stacks, calendar: calendar)
        XCTAssertEqual(days.map(\.id), ["2026-08-26", "2026-08-27"])
    }

    func testScannerReadsHeadersGroupsBurstsAndShiftsVideoClock() throws {
        try withTemporaryDirectory { root in
            // The camera clock runs 15 hours ahead of the files' real modification times.
            let offset: TimeInterval = 15 * 3_600
            let transfer = root.appendingPathComponent("Transfer 5/101MSDCF", isDirectory: true)
            let frames = [("DSC00001.ARW", "2026:08:27 05:27:53", "100"), ("DSC00002.ARW", "2026:08:27 05:27:53", "400"),
                          ("DSC00003.ARW", "2026:08:27 05:27:53", "700"), ("DSC00010.ARW", "2026:08:27 05:30:00", "000")]
            for (name, time, subseconds) in frames {
                let date = exifDate(time, subseconds: subseconds)
                try writeFakeARW(transfer.appendingPathComponent(name), captureTime: time, subseconds: subseconds, modifiedAt: date.addingTimeInterval(-offset))
            }
            try writeFile(transfer.appendingPathComponent("DSC00001.xmp"), "<xmp/>")
            let clipDate = exifDate("2026:08:27 06:00:00")
            let clip = try writeFile(root.appendingPathComponent("Transfer 5/CLIP/C0001.MP4"), Data(repeating: 1, count: 64))
            try FileManager.default.setAttributes([.modificationDate: clipDate.addingTimeInterval(-offset)], ofItemAtPath: clip.path)
            try writeFile(root.appendingPathComponent("Transfer 7/DSC00001.ARW"), Data(repeating: 2, count: 32))

            let cache = CaptureDateCache(url: root.appendingPathComponent("cache.json"))
            let result = try OrganizeScanner(concurrency: 4).scan(root: root, cache: cache)

            XCTAssertEqual(result.clockOffset, offset)
            XCTAssertEqual(result.duplicateNames, ["dsc00001.arw"])
            let burst = try XCTUnwrap(result.stacks.first { $0.items.count == 3 })
            XCTAssertEqual(burst.items.first?.companions.map(\.name), ["DSC00001.xmp"])
            let video = try XCTUnwrap(result.items.first { $0.kind == .video })
            XCTAssertFalse(video.hasCameraDate)
            XCTAssertEqual(video.captureDate.timeIntervalSince(clipDate), 0, accuracy: 1)
            XCTAssertEqual(result.days.map(\.id).first, "2026-08-27")
            XCTAssertEqual(result.fileCount, 7)
        }
    }
}
