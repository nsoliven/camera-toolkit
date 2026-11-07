import CameraToolkitCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
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

    /// Days only exist where stacks exist — `days(for:)` must not fill the
    /// calendar gap between two dated stacks with empty days.
    func testDaysDoNotInventGapDaysBetweenDatedStacks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // Sunday the 23rd and Wednesday the 26th — the empty Monday and
        // Tuesday between them must not appear.
        let stacks = [
            OrganizeStack(items: [organizeItem("/s/DSC00001.ARW", date: exifDate("2026:08:23 10:00:00"))]),
            OrganizeStack(items: [organizeItem("/s/DSC00002.ARW", date: exifDate("2026:08:26 10:00:00"))]),
        ]
        let days = OrganizeStacker.days(for: stacks, calendar: calendar)
        XCTAssertEqual(days.map(\.id), ["2026-08-23", "2026-08-26"])
        XCTAssertTrue(days.allSatisfy { !$0.stacks.isEmpty })
    }

    /// `days(for:)` asks the calendar once per run of stacks on one day. That
    /// must give what asking for every stack gives — across the days the
    /// clocks change, and for stacks in no order at all.
    func testDaysMatchAskingTheCalendarForEveryStack() {
        for zone in ["America/Los_Angeles", "Europe/Berlin", "Australia/Lord_Howe", "UTC"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            var generator = SystemRandomNumberGenerator()
            // Two weeks around a spring and an autumn change, plus scatter.
            let starts: [Double] = [1_773_000_000, 1_793_000_000]
            var stacks: [OrganizeStack] = []
            for start in starts {
                for index in 0..<400 {
                    let date = Date(timeIntervalSince1970: start + Double.random(in: 0..<(14 * 86_400), using: &generator))
                    stacks.append(OrganizeStack(items: [organizeItem("/s/DSC\(index)_\(Int(start)).ARW", date: date)]))
                }
            }
            stacks.shuffle()
            let days = OrganizeStacker.days(for: stacks, calendar: calendar)
            var expected: [String: [String]] = [:]
            for stack in stacks {
                let c = calendar.dateComponents([.year, .month, .day], from: stack.captureDate)
                expected[String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0), default: []].append(stack.id)
            }
            XCTAssertEqual(days.map(\.id), expected.keys.sorted(), zone)
            for day in days {
                XCTAssertEqual(day.stacks.map(\.id), expected[day.id], "\(zone) \(day.id)")
                XCTAssertEqual(day.date, calendar.startOfDay(for: day.stacks[0].captureDate), "\(zone) \(day.id)")
            }
        }
    }

    /// Every stack on a day counts toward that day's frame and byte
    /// totals — a day holding stacks can never total 0.
    func testDayTotalsIncludeEveryStackOnTheDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let burst = OrganizeStack(items: [
            organizeItem("/s/B0001_DSC00001.ARW", date: exifDate("2026:08:26 09:00:00")),
            organizeItem("/s/B0001_DSC00002.ARW", date: exifDate("2026:08:26 09:00:01")),
            organizeItem("/s/B0001_DSC00003.ARW", date: exifDate("2026:08:26 09:00:02")),
        ])
        let single = OrganizeStack(items: [organizeItem("/s/DSC00004.ARW", date: exifDate("2026:08:26 12:00:00"))])
        let days = OrganizeStacker.days(for: [single, burst], calendar: calendar)
        let day = days.first { $0.id == "2026-08-26" }
        XCTAssertEqual(day?.stacks.map(\.id), [single.id, burst.id])
        XCTAssertEqual(day?.frameCount, 4)
        // organizeItem fixtures are 10 bytes each.
        XCTAssertEqual(day?.byteCount, 40)
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

    // MARK: - Hybrid burst grouping

    func testBurstLinkRequirementDecidesAutomaticVisualOrSeparate() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let configuration = BurstGroupingConfiguration()
        func requirement(_ a: OrganizeItem, _ b: OrganizeItem, _ config: BurstGroupingConfiguration = configuration) -> BurstLinkRequirement {
            OrganizeStacker.linkRequirement(from: a, to: b, configuration: config)
        }
        func frame(_ number: Int, at offset: TimeInterval, kind: OrganizeMediaKind = .raw, folder: String = "/s", cameraDate: Bool = true) -> OrganizeItem {
            let name = kind == .video ? String(format: "C%04d.MP4", number) : String(format: "DSC%05d.ARW", number)
            return organizeItem("\(folder)/\(name)", kind: kind, date: t0.addingTimeInterval(offset), hasCameraDate: cameraDate)
        }

        // Automatic band: gap at or below one second.
        XCTAssertEqual(requirement(frame(1, at: 0), frame(2, at: 0.5)), .automatic)
        XCTAssertEqual(requirement(frame(1, at: 0), frame(2, at: 1.0)), .automatic)
        // Recovery band: (1.0, 2.0].
        XCTAssertEqual(requirement(frame(1, at: 0), frame(2, at: 1.29)), .visualCheck)
        XCTAssertEqual(requirement(frame(1, at: 0), frame(2, at: 2.0)), .visualCheck)
        // Beyond the maximum, or with recovery off.
        XCTAssertEqual(requirement(frame(1, at: 0), frame(2, at: 2.01)), .separate)
        var noRecovery = configuration
        noRecovery.useVisualRecovery = false
        XCTAssertEqual(requirement(frame(1, at: 0), frame(2, at: 1.29), noRecovery), .separate)
        XCTAssertEqual(requirement(frame(1, at: 0), frame(2, at: 0.5), noRecovery), .automatic)

        // The frame-number gate applies to the recovery band too.
        XCTAssertEqual(requirement(frame(1, at: 0), frame(9, at: 1.5)), .separate)
        XCTAssertEqual(requirement(frame(2, at: 0), frame(1, at: 1.5)), .separate) // not a forward step
        XCTAssertEqual(requirement(frame(9_995, at: 0), frame(2, at: 1.5)), .visualCheck) // rollover
        // Frames without a usable number can't be disproved, so they pass.
        XCTAssertEqual(
            OrganizeStacker.linkRequirement(
                from: organizeItem("/s/IMG_5108A.ARW", date: t0),
                to: organizeItem("/s/IMG_5109A.ARW", date: t0.addingTimeInterval(1.5)),
                configuration: configuration),
            .visualCheck)

        // Stills only, camera dates only, same folder only, forward in time.
        XCTAssertEqual(requirement(frame(1, at: 0), frame(2, at: 0.5, kind: .video)), .separate)
        XCTAssertEqual(requirement(frame(1, at: 0), frame(2, at: 0.5, cameraDate: false)), .separate)
        XCTAssertEqual(requirement(frame(1, at: 0), frame(2, at: 0.5, folder: "/other")), .separate)
        XCTAssertEqual(requirement(frame(1, at: 1.0), frame(2, at: 0.5)), .separate)
    }

    func testRecoveryBandChainsOnlyWithVisualLink() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            organizeItem("/s/DSC00001.ARW", date: t0),
            organizeItem("/s/DSC00002.ARW", date: t0.addingTimeInterval(1.4)),
            organizeItem("/s/DSC00003.ARW", date: t0.addingTimeInterval(2.8)),
            organizeItem("/s/DSC00004.ARW", date: t0.addingTimeInterval(4.2)),
            organizeItem("/s/DSC00005.ARW", date: t0.addingTimeInterval(6.4)),
        ]
        let linkAB = BurstVisualLink(previous: items[0], next: items[1])
        let linkBC = BurstVisualLink(previous: items[1], next: items[2])
        let linkCD = BurstVisualLink(previous: items[2], next: items[3])
        // D→E is a 2.2 s gap: beyond the maximum, so no link can recover it.
        let linkDE = BurstVisualLink(previous: items[3], next: items[4])

        // Without links every frame stands alone — same as the old 1 s rule.
        XCTAssertEqual(OrganizeStacker.stacks(for: items).map(\.items.count), [1, 1, 1, 1, 1])
        // A cleared link merges just its pair; a missing link keeps them apart.
        XCTAssertEqual(
            OrganizeStacker.stacks(for: items, visualLinks: [linkAB, linkCD]).map(\.items.count),
            [2, 2, 1])
        // Links chain transitively and cannot cross the maximum gap.
        XCTAssertEqual(
            OrganizeStacker.stacks(for: items, visualLinks: [linkAB, linkBC, linkCD, linkDE]).map(\.items.count),
            [4, 1])
    }

    func testDisabledVisualRecoveryIsPureTimeGrouping() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var configuration = BurstGroupingConfiguration()
        configuration.useVisualRecovery = false
        let items = [
            organizeItem("/s/DSC00001.ARW", date: t0),
            organizeItem("/s/DSC00002.ARW", date: t0.addingTimeInterval(1.4)),
        ]
        let links: Set<BurstVisualLink> = [BurstVisualLink(previous: items[0], next: items[1])]
        let stacks = OrganizeStacker.stacks(for: items, configuration: configuration, visualLinks: links)
        XCTAssertEqual(stacks.map(\.items.count), [1, 1])
        XCTAssertTrue(BurstVisualLinker.recoveryPairs(for: items, configuration: configuration).isEmpty)
    }

    func testMinimumGroupSizeSplitsShortChains() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var configuration = BurstGroupingConfiguration()
        configuration.minimumGroupSize = 3
        let items = [
            organizeItem("/s/DSC00001.ARW", date: t0),
            organizeItem("/s/DSC00002.ARW", date: t0.addingTimeInterval(0.3)),
            organizeItem("/s/DSC00003.ARW", date: t0.addingTimeInterval(5)),
            organizeItem("/s/DSC00004.ARW", date: t0.addingTimeInterval(5.3)),
            organizeItem("/s/DSC00005.ARW", date: t0.addingTimeInterval(5.6)),
        ]
        // The two-frame chain falls under the minimum and becomes singles;
        // the three-frame chain stays a burst.
        XCTAssertEqual(
            OrganizeStacker.stacks(for: items, configuration: configuration).map(\.items.count),
            [1, 1, 3])
    }

    func testPrefixedFoldersStayTrustedUnderGroupingConfiguration() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var configuration = BurstGroupingConfiguration()
        configuration.useVisualRecovery = false
        configuration.minimumGroupSize = 3
        let items = [
            organizeItem("/s/B0001_DSC00001.ARW", date: t0),
            organizeItem("/s/B0001_DSC00002.ARW", date: t0.addingTimeInterval(0.2)),
            organizeItem("/s/DSC00003.ARW", date: t0.addingTimeInterval(0.4)),
        ]
        let stacks = OrganizeStacker.stacks(for: items, configuration: configuration)
        XCTAssertEqual(stacks.map(\.items.count), [2, 1])
        XCTAssertEqual(stacks.first?.burstLabel, "B0001")
    }

    func testBurstGroupingConfigurationCodableRoundTripsAndDefaults() throws {
        let decoded = try JSONDecoder().decode(BurstGroupingConfiguration.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, BurstGroupingConfiguration())
        var configuration = BurstGroupingConfiguration()
        configuration.maximumGapSeconds = 3.5
        configuration.useVisualRecovery = false
        configuration.maximumVisionDistance = 0.3
        let reloaded = try JSONDecoder().decode(
            BurstGroupingConfiguration.self,
            from: JSONEncoder().encode(configuration))
        XCTAssertEqual(reloaded, configuration)
        XCTAssertEqual(reloaded.minimumGroupSize, 2)
    }

    /// Vision feature prints work on synthetic images: two near-identical
    /// scenes score far below the 0.48 threshold while a scene change scores
    /// far above it, so the whole recovery path can run end to end.
    func testVisualLinkerLinksSimilarFramesInRecoveryBand() throws {
        try withTemporaryDirectory { root in
            let folder = root.appendingPathComponent("DCIM", isDirectory: true)
            let sceneA = SyntheticImage.scene(seed: 42)
            let sceneB = SyntheticImage.scene(seed: 42, extraMark: true)
            let different = SyntheticImage.solidBlack()
            let a = try SyntheticImage.writeJPEG(sceneA, to: folder.appendingPathComponent("DSC00001.JPG"))
            let b = try SyntheticImage.writeJPEG(sceneB, to: folder.appendingPathComponent("DSC00002.JPG"))
            let c = try SyntheticImage.writeJPEG(different, to: folder.appendingPathComponent("DSC00003.JPG"))
            let d = try SyntheticImage.writeJPEG(sceneA, to: folder.appendingPathComponent("DSC00004.JPG"))

            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            let items = [
                organizeItem(a.path, kind: .photo, date: t0),
                organizeItem(b.path, kind: .photo, date: t0.addingTimeInterval(1.4)),
                organizeItem(c.path, kind: .photo, date: t0.addingTimeInterval(2.8)),
                organizeItem(d.path, kind: .photo, date: t0.addingTimeInterval(5.5)),
            ]

            // Only the two recovery-band pairs are fingerprint candidates.
            let candidates = BurstVisualLinker.recoveryPairs(for: items)
            XCTAssertEqual(
                candidates.map { [$0.previous.primary.name, $0.next.primary.name] },
                [["DSC00001.JPG", "DSC00002.JPG"], ["DSC00002.JPG", "DSC00003.JPG"]])

            let similar = try BurstVisualLinker.featurePrintDistance(from: a, to: b)
            let changed = try BurstVisualLinker.featurePrintDistance(from: b, to: c)
            XCTAssertLessThan(similar, 0.2)
            XCTAssertGreaterThan(changed, BurstGroupingConfiguration().maximumVisionDistance)

            let links = BurstVisualLinker.links(for: items, concurrency: 2)
            XCTAssertEqual(links, [BurstVisualLink(previous: items[0], next: items[1])])

            let stacks = OrganizeStacker.stacks(for: items, visualLinks: links)
            XCTAssertEqual(stacks.map(\.items.count), [2, 1, 1])
            XCTAssertEqual(stacks.first?.items.map(\.primary.name), ["DSC00001.JPG", "DSC00002.JPG"])
        }
    }

    // MARK: - Manual burst splits

    /// The filmstrip's "Move to New Burst" records a `BurstSplit`; these pin
    /// the named frames into their own stack on top of the normal grouping.
    func testManualSplitCarvesFramesOutOfAChainedBurst() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...5).map {
            organizeItem("/s/DSC0000\($0).ARW", date: t0.addingTimeInterval(Double($0 - 1) * 0.3))
        }
        XCTAssertEqual(OrganizeStacker.stacks(for: items).map(\.items.count), [5])

        let split = BurstSplit(memberPathKeys: [items[2].primary.pathKey, items[3].primary.pathKey])
        let stacks = OrganizeStacker.stacks(for: items, splits: [split])
        // The pulled frames form their own stack; the rest stay in the
        // original burst even though they are no longer contiguous.
        XCTAssertEqual(stacks.map { $0.items.map(\.primary.name) }, [
            ["DSC00001.ARW", "DSC00002.ARW", "DSC00005.ARW"],
            ["DSC00003.ARW", "DSC00004.ARW"],
        ])
    }

    func testManualSplitCarvesPrefixedBurstsAndCanSplitASplit() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...4).map {
            organizeItem("/s/B0001_DSC0000\($0).ARW", date: t0.addingTimeInterval(Double($0 - 1) * 0.3))
        }
        // B-prefixed bursts stay trusted when nothing is split.
        XCTAssertEqual(OrganizeStacker.stacks(for: items).map(\.items.count), [4])

        let first = BurstSplit(memberPathKeys: [items[1].primary.pathKey, items[2].primary.pathKey])
        var stacks = OrganizeStacker.stacks(for: items, splits: [first])
        XCTAssertEqual(stacks.map { $0.items.map(\.primary.name) }, [
            ["B0001_DSC00001.ARW", "B0001_DSC00004.ARW"],
            ["B0001_DSC00002.ARW", "B0001_DSC00003.ARW"],
        ])

        // A second split carves a frame back out of the first split's burst.
        let second = BurstSplit(memberPathKeys: [items[2].primary.pathKey])
        stacks = OrganizeStacker.stacks(for: items, splits: [first, second])
        XCTAssertEqual(stacks.map { $0.items.map(\.primary.name) }, [
            ["B0001_DSC00001.ARW", "B0001_DSC00004.ARW"],
            ["B0001_DSC00002.ARW"],
            ["B0001_DSC00003.ARW"],
        ])
    }

    func testManualSplitAcceptsNonContiguousMembersAndIgnoresStaleOnes() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...4).map {
            organizeItem("/s/DSC0000\($0).ARW", date: t0.addingTimeInterval(Double($0 - 1) * 0.3))
        }
        // ⌘-picked frames still form one burst — a split need not be a range.
        let picked = BurstSplit(memberPathKeys: [items[0].primary.pathKey, items[2].primary.pathKey])
        var stacks = OrganizeStacker.stacks(for: items, splits: [picked])
        XCTAssertEqual(stacks.map { $0.items.map(\.primary.name) }, [
            ["DSC00001.ARW", "DSC00003.ARW"],
            ["DSC00002.ARW", "DSC00004.ARW"],
        ])

        // Members that left the scan are ignored; an all-stale split is a
        // no-op rather than an empty stack.
        let stale = BurstSplit(memberPathKeys: ["/gone/DSC00099.ARW"])
        stacks = OrganizeStacker.stacks(for: items, splits: [stale])
        XCTAssertEqual(stacks.map(\.items.count), [4])

        // Splitting every frame leaves no empty remainder behind.
        let all = BurstSplit(memberPathKeys: items.map(\.primary.pathKey))
        stacks = OrganizeStacker.stacks(for: items, splits: [all])
        XCTAssertEqual(stacks.map(\.items.count), [4])
    }

    func testScanAppliesSplitsAndRestackingKeepsThem() throws {
        try withTemporaryDirectory { root in
            // The capture-date cache lives beside the scanned root so the
            // rescan doesn't pick it up as a media file.
            let scanRoot = root.appendingPathComponent("Card", isDirectory: true)
            let folder = scanRoot.appendingPathComponent("DCIM", isDirectory: true)
            let subseconds = ["100", "400", "700", "000"]
            for index in 0..<4 {
                try writeFakeARW(
                    folder.appendingPathComponent(String(format: "DSC%05d.ARW", index + 1)),
                    captureTime: index == 3 ? "2026:08:27 05:27:54" : "2026:08:27 05:27:53",
                    subseconds: subseconds[index]
                )
            }
            let scanner = OrganizeScanner(concurrency: 4)
            let cache = CaptureDateCache(url: root.appendingPathComponent("cache.json"))
            let scanned = try scanner.scan(root: scanRoot, cache: cache)
            XCTAssertEqual(scanned.stacks.map(\.items.count), [4])
            XCTAssertEqual(scanned.burstSplits, [])

            let split = BurstSplit(memberPathKeys: scanned.stacks[0].items.suffix(2).map(\.primary.pathKey))

            // A fresh scan honoring the split keeps the frames apart.
            let rescanned = try scanner.scan(root: scanRoot, cache: cache, burstSplits: [split])
            XCTAssertEqual(rescanned.stacks.map(\.items.count), [2, 2])
            XCTAssertEqual(rescanned.burstSplits, [split])

            // In-memory restack does the same without touching the disk.
            XCTAssertEqual(scanned.restacked(withSplits: [split]).stacks.map(\.items.count), [2, 2])

            // Trashing the remainder leaves the pinned stack intact.
            let removed = Set(scanned.stacks[0].items.prefix(2).map(\.primary.pathKey))
            let afterRemoval = rescanned.removingFiles(withPathKeys: removed)
            XCTAssertEqual(afterRemoval.stacks.map { $0.items.map(\.primary.name) }, [["DSC00003.ARW", "DSC00004.ARW"]])
        }
    }
}

// MARK: - Camera support files

extension OrganizeMediaTests {
    func testCameraSupportFilesMatchOnlySonyPreviewsAndLUTs() {
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("M4ROOT/THMBNL/C0002T01.JPG"))
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("/card/M4ROOT/THMBNL/C0003T01.JPG"))
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("/card/m4root/thmbnl/c0001t01.jpg"))
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("M4ROOT/GENERAL/LUT/LOOK1.cube"))
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("M4ROOT/GENERAL/LOOK2.CUBE"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("M4ROOT/CLIP/C0001.MP4"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("M4ROOT/CLIP/C0001M01.XML"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("M4ROOT/GENERAL/MEDIAPRO.XML"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("DCIM/100MSDCF/DSC00001.JPG"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("DCIM/100MSDCF/DSC00001.ARW"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("DCIM/100MSDCF/DSC00001.photo-edit"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("DCIM/100MSDCF/DSC00001-export.tif"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("Grading/LOOK1.cube"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("THMBNL/C0001T01.JPG"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("M4ROOT/THMBNL"))
        XCTAssertTrue(CameraSupportFiles.isThumbnailFolder("/card/M4ROOT/THMBNL"))
        XCTAssertFalse(CameraSupportFiles.isThumbnailFolder("/card/M4ROOT/CLIP"))
    }

    func testCameraSupportFilesMatchSonyCardManagementFiles() {
        // The clip index and status file directly in M4ROOT, wherever M4ROOT is.
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("M4ROOT/MEDIAPRO.XML"))
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("/card/M4ROOT/STATUS.BIN"))
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("/card/PRIVATE/M4ROOT/MEDIAPRO.XML"))
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("/card/PRIVATE/M4ROOT/THMBNL/C0001T01.JPG"))
        // The still-image database.
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("/card/AVF_INFO/AVIN0001.INT"))
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("AVF_INFO/AVIN0001.INP"))
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("AVF_INFO/AVIN0001.BNP"))
        // The camera database and card files under PRIVATE.
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("/card/PRIVATE/DATABASE/DATABASE.BIN"))
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("PRIVATE/SONY/DATABASE/DATABASE.BIN"))
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("PRIVATE/DATABASE.BIN"))
        XCTAssertTrue(CameraSupportFiles.isCameraGenerated("PRIVATE/SONY/SONYCARD.IND"))
        // Media stays: clips and their XML (also under PRIVATE/M4ROOT), and
        // other PRIVATE media such as AVCHD streams.
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("M4ROOT/CLIP/C0001.MP4"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("M4ROOT/CLIP/C0001M01.XML"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("/card/PRIVATE/M4ROOT/CLIP/C0001.MP4"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("/card/PRIVATE/M4ROOT/CLIP/C0001M01.XML"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("PRIVATE/AVCHD/BDMV/STREAM/00000.MTS"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("DCIM/100MSDCF/DATABASE.JPG"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("Exports/MEDIAPRO.XML"))
        XCTAssertFalse(CameraSupportFiles.isCameraGenerated("DATABASE.BIN"))
        // Folders a scan skips whole.
        XCTAssertTrue(CameraSupportFiles.isSupportFolder("/card/AVF_INFO"))
        XCTAssertTrue(CameraSupportFiles.isSupportFolder("/card/PRIVATE/DATABASE"))
        XCTAssertTrue(CameraSupportFiles.isSupportFolder("/card/PRIVATE/SONY"))
        XCTAssertTrue(CameraSupportFiles.isSupportFolder("/card/M4ROOT/THMBNL"))
        XCTAssertFalse(CameraSupportFiles.isSupportFolder("/card/PRIVATE"))
        XCTAssertFalse(CameraSupportFiles.isSupportFolder("/card/PRIVATE/M4ROOT"))
        XCTAssertFalse(CameraSupportFiles.isSupportFolder("/card/PRIVATE/M4ROOT/CLIP"))
        XCTAssertFalse(CameraSupportFiles.isSupportFolder("/card/M4ROOT"))
        XCTAssertFalse(CameraSupportFiles.isSupportFolder("/card/DCIM/100MSDCF"))
    }

    func testScannerIgnoresSonyPreviewsAndLUTsButKeepsClipsAndPhotos() throws {
        try withTemporaryDirectory { root in
            let card = root.appendingPathComponent("Card", isDirectory: true)
            let dcim = card.appendingPathComponent("DCIM/100MSDCF", isDirectory: true)
            try writeFakeARW(dcim.appendingPathComponent("DSC00001.ARW"), captureTime: "2026:08:27 05:27:53")
            try writeFile(dcim.appendingPathComponent("DSC00001.JPG"), Data(repeating: 3, count: 64))
            try writeFile(dcim.appendingPathComponent("DSC00002.JPG"), Data(repeating: 4, count: 64))
            try writeFile(dcim.appendingPathComponent("DSC00001.photo-edit"), "edit")
            try writeFile(dcim.appendingPathComponent("DSC00002-export.tif"), Data(repeating: 5, count: 64))
            try writeFile(card.appendingPathComponent("M4ROOT/CLIP/C0001.MP4"), Data(repeating: 1, count: 64))
            try writeFile(card.appendingPathComponent("M4ROOT/CLIP/C0001M01.XML"), "<xml/>")
            let preview = try writeFile(card.appendingPathComponent("M4ROOT/THMBNL/C0001T01.JPG"), Data(repeating: 6, count: 64))
            let lut = try writeFile(card.appendingPathComponent("M4ROOT/GENERAL/LUT/LOOK1.cube"), "LUT_3D_SIZE 2")
            try writeFile(card.appendingPathComponent("M4ROOT/MEDIAPRO.XML"), "<MediaProfile/>")
            try writeFile(card.appendingPathComponent("M4ROOT/STATUS.BIN"), Data(repeating: 7, count: 16))
            try writeFile(card.appendingPathComponent("AVF_INFO/AVIN0001.INT"), Data(repeating: 8, count: 16))
            try writeFile(card.appendingPathComponent("AVF_INFO/AVIN0001.INP"), Data(repeating: 8, count: 16))
            try writeFile(card.appendingPathComponent("AVF_INFO/AVIN0001.BNP"), Data(repeating: 8, count: 16))
            try writeFile(card.appendingPathComponent("PRIVATE/DATABASE/DATABASE.BIN"), Data(repeating: 9, count: 16))
            try writeFile(card.appendingPathComponent("PRIVATE/SONY/SONYCARD.IND"), Data(repeating: 9, count: 16))
            try writeFile(card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0002.MP4"), Data(repeating: 2, count: 64))
            try writeFile(card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0002M01.XML"), "<xml/>")
            try writeFile(card.appendingPathComponent("PRIVATE/M4ROOT/MEDIAPRO.XML"), "<MediaProfile/>")
            let before = try treeBytes(card)

            let cache = CaptureDateCache(url: root.appendingPathComponent("cache.json"))
            for scanRoot in [card, card.appendingPathComponent("M4ROOT", isDirectory: true)] {
                let result = try OrganizeScanner(concurrency: 2).scan(root: scanRoot, cache: cache)
                let names = Set(result.items.flatMap(\.files).map(\.name))
                XCTAssertFalse(names.contains("C0001T01.JPG"))
                XCTAssertFalse(names.contains("LOOK1.cube"))
                XCTAssertTrue(names.contains("C0001.MP4"))
                let clip = try XCTUnwrap(result.items.first { $0.primary.name == "C0001.MP4" })
                XCTAssertEqual(clip.companions.map(\.name), ["C0001M01.XML"])
                XCTAssertEqual(clip.kind, .video)
                if scanRoot == card {
                    XCTAssertEqual(names, [
                        "DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG", "DSC00001.photo-edit",
                        "DSC00002-export.tif", "C0001.MP4", "C0001M01.XML", "C0002.MP4", "C0002M01.XML",
                    ])
                    let privateClip = try XCTUnwrap(result.items.first { $0.primary.name == "C0002.MP4" })
                    XCTAssertEqual(privateClip.companions.map(\.name), ["C0002M01.XML"])
                }
            }
            // Ignored means untouched: every file is still there, byte for byte.
            XCTAssertEqual(try treeBytes(card), before)
            XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: lut.path))
            // Ingest's own exclusions are unchanged: the card copy keeps them.
            XCTAssertFalse(ExclusionMatcher.isExcluded("M4ROOT/THMBNL/C0001T01.JPG"))
            XCTAssertFalse(ExclusionMatcher.isExcluded("M4ROOT/GENERAL/LUT/LOOK1.cube"))
        }
    }
}

// MARK: - Event boards stack like the card board

extension OrganizeMediaTests {
    /// The same frames, scanned on the card and drawn from their Buffer
    /// copies (same names, sizes and times), make the same bursts: the Vision
    /// verdicts and the manual splits follow frame identity, not the path.
    func testBufferCopiesStackIntoTheSameBurstsAsTheCardScan() throws {
        try withTemporaryDirectory { root in
            let cardFolder = root.appendingPathComponent("Card/DCIM/100MSDCF", isDirectory: true)
            let bufferFolder = root.appendingPathComponent("Buffer/2026/2026-08-26 Beach Day/Originals/Sony A7V", isDirectory: true)
            let scenes: [(String, CGImage)] = [
                ("DSC00001.JPG", SyntheticImage.scene(seed: 42)),
                ("DSC00002.JPG", SyntheticImage.scene(seed: 42, extraMark: true)),
                ("DSC00003.JPG", SyntheticImage.solidBlack()),
                ("DSC00004.JPG", SyntheticImage.solidBlack()),
                ("DSC00009.JPG", SyntheticImage.scene(seed: 7)),
            ]
            let modified = Date(timeIntervalSince1970: 1_790_000_000)
            for (name, image) in scenes {
                for folder in [cardFolder, bufferFolder] {
                    let url = try SyntheticImage.writeJPEG(image, to: folder.appendingPathComponent(name))
                    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
                }
            }
            // 1.4 s (Vision band), 1.4 s to a different scene, 0.5 s
            // (automatic), then a lone frame half an hour later.
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            let offsets: [TimeInterval] = [0, 1.4, 2.8, 3.3, 1_800]
            func items(in folder: URL) throws -> [OrganizeItem] {
                try zip(scenes, offsets).map { scene, offset in
                    let url = folder.appendingPathComponent(scene.0)
                    let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).int64Value
                    return OrganizeItem(
                        primary: OrganizeFile(literalPath: url.path, size: size, modifiedAt: modified),
                        kind: .photo,
                        captureDate: t0.addingTimeInterval(offset),
                        hasCameraDate: true
                    )
                }
            }
            let cardItems = try items(in: cardFolder)
            let bufferItems = try items(in: bufferFolder)
            func names(_ stacks: [OrganizeStack]) -> [[String]] { stacks.map { $0.items.map(\.primary.name) } }
            let expected = [["DSC00001.JPG", "DSC00002.JPG"], ["DSC00003.JPG", "DSC00004.JPG"], ["DSC00009.JPG"]]

            // The card board: Vision links its recovery pair.
            let configuration = BurstGroupingConfiguration()
            let cardLinks = BurstVisualLinker.links(for: cardItems, configuration: configuration, concurrency: 2)
            XCTAssertEqual(names(OrganizeStacker.stacks(for: cardItems, configuration: configuration, visualLinks: cardLinks)), expected)
            // Stacked without those links (the old event board) the pair fell apart.
            XCTAssertEqual(names(OrganizeStacker.stacks(for: bufferItems)), [["DSC00001.JPG"], ["DSC00002.JPG"], ["DSC00003.JPG", "DSC00004.JPG"], ["DSC00009.JPG"]])

            // Learned from the card scan, answered for the Buffer copies
            // without reading them.
            let learned = BurstLinkMemory()
            learned.record(items: cardItems, links: cardLinks, configuration: configuration)
            XCTAssertEqual(learned.count, 2)
            let fromCard = BurstStackingContext(configuration: configuration, linkMemory: learned)
            XCTAssertEqual(names(fromCard.stacks(for: bufferItems)), expected)
            XCTAssertEqual(names(fromCard.stacks(for: cardItems)), expected)

            // With nothing learned (a relaunch), a pass that may read the
            // Buffer copies reaches the same verdicts and remembers them.
            let fresh = BurstLinkMemory()
            let fromBuffer = BurstStackingContext(configuration: configuration, linkMemory: fresh)
            XCTAssertEqual(names(fromBuffer.stacks(for: bufferItems)), names(OrganizeStacker.stacks(for: bufferItems)))
            XCTAssertEqual(names(fromBuffer.stacks(for: bufferItems, computeMissingLinks: true)), expected)
            XCTAssertEqual(fresh.count, 2)
            XCTAssertEqual(names(fromBuffer.stacks(for: cardItems)), expected)

            // A verdict reached at another Vision threshold is not reused.
            var stricter = configuration
            stricter.maximumVisionDistance = 0.01
            XCTAssertEqual(names(BurstStackingContext(configuration: stricter, linkMemory: learned).stacks(for: bufferItems)).count, 4)

            // A split made on the card (card path keys) holds on the copies.
            let split = BurstSplit(memberPathKeys: [cardItems[1].primary.pathKey])
            let identities = [cardItems[1].primary.pathKey: BurstFrameIdentity.key(for: cardItems[1].primary)]
            let withSplit = BurstStackingContext(configuration: configuration, splits: [split], memberIdentities: identities, linkMemory: learned)
            let splitExpected = [["DSC00001.JPG"], ["DSC00002.JPG"], ["DSC00003.JPG", "DSC00004.JPG"], ["DSC00009.JPG"]]
            XCTAssertEqual(names(OrganizeStacker.stacks(for: cardItems, configuration: configuration, visualLinks: cardLinks, splits: [split])), splitExpected)
            XCTAssertEqual(names(withSplit.stacks(for: bufferItems)), splitExpected)
            // Without the member's identity the board cannot match it.
            XCTAssertEqual(names(BurstStackingContext(configuration: configuration, splits: [split], linkMemory: learned).stacks(for: bufferItems)), expected)
        }
    }
}

/// Deterministic synthetic scenes for Vision feature prints. A seeded
/// gradient-and-blobs scene gives near-zero distance to a re-render of itself
/// and a ~1.0 distance to a solid frame, so both sides of the 0.48 threshold
/// are exercised without real photos.
private enum SyntheticImage {
    static func scene(seed: UInt64, extraMark: Bool = false, width: Int = 640, height: Int = 480) -> CGImage {
        var rng = seed
        func next() -> UInt64 {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return rng >> 33
        }
        let context = makeContext(width: width, height: height)
        for y in 0..<height {
            let t = Double(y) / Double(height)
            context.setFillColor(CGColor(red: t, green: 0.4, blue: 1 - t, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        for _ in 0..<40 {
            let x = Double(next() % UInt64(width))
            let y = Double(next() % UInt64(height))
            let w = 20 + Double(next() % 80)
            let h = 20 + Double(next() % 80)
            context.setFillColor(CGColor(
                red: Double(next() % 255) / 255,
                green: Double(next() % 255) / 255,
                blue: Double(next() % 255) / 255,
                alpha: 0.8))
            context.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
        }
        if extraMark {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fillEllipse(in: CGRect(x: 300, y: 200, width: 12, height: 12))
        }
        return context.makeImage()!
    }

    static func solidBlack(width: Int = 640, height: Int = 480) -> CGImage {
        let context = makeContext(width: width, height: height)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func writeJPEG(_ image: CGImage, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    }
}
