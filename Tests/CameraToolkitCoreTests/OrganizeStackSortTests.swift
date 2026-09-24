import CameraToolkitCore
import Foundation
import XCTest

final class OrganizeStackSortTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func item(_ name: String, kind: OrganizeMediaKind = .raw, at offset: TimeInterval, size: Int64 = 100, companions: [Int64] = []) -> OrganizeItem {
        OrganizeItem(
            primary: OrganizeFile(path: "/Card/\(name)", size: size, modifiedAt: base),
            companions: companions.enumerated().map { index, bytes in
                OrganizeFile(path: "/Card/\(name).side\(index).XMP", size: bytes, modifiedAt: base)
            },
            kind: kind,
            captureDate: base.addingTimeInterval(offset),
            hasCameraDate: true
        )
    }

    private func stack(_ items: OrganizeItem...) -> OrganizeStack {
        OrganizeStack(items: items)
    }

    private func ids(_ stacks: [OrganizeStack]) -> [String] {
        stacks.map(\.id)
    }

    func testDefaultIsCaptureTimeOldestFirst() {
        let sort = OrganizeStackSort()
        XCTAssertEqual(sort, .oldestFirst)
        let late = stack(item("A.ARW", at: 60))
        let early = stack(item("B.ARW", at: 0))
        XCTAssertEqual(ids(sort.sorted([late, early])), ids([early, late]))
        XCTAssertEqual(ids(OrganizeStackSort.newestFirst.sorted([early, late])), ids([late, early]))
    }

    /// Burst size counts frames, not files: a single RAW with a JPEG and an
    /// XMP beside it is still one frame.
    func testBurstSizeCountsFramesLargestFirstByDefault() {
        let three = stack(item("B1_1.ARW", at: 10), item("B1_2.ARW", at: 11), item("B1_3.ARW", at: 12))
        let two = stack(item("B2_1.ARW", at: 20), item("B2_2.ARW", at: 21))
        let singleWithSidecars = stack(item("S.ARW", at: 0, companions: [50, 50, 50]))

        let sort = OrganizeStackSort(key: .burstSize)
        XCTAssertFalse(sort.ascending)
        XCTAssertEqual(sort.summary, "Largest Bursts")
        XCTAssertEqual(ids(sort.sorted([singleWithSidecars, two, three])), ids([three, two, singleWithSidecars]))
        XCTAssertEqual(ids(sort.reversed.sorted([three, two, singleWithSidecars])), ids([singleWithSidecars, two, three]))
    }

    func testFileSizeSumsPrimariesAndCompanions() {
        let heavyCompanion = stack(item("A.ARW", at: 0, size: 100, companions: [900]))
        let heavyPrimary = stack(item("B.ARW", at: 1, size: 500))
        let light = stack(item("C.ARW", at: 2, size: 10))

        let sort = OrganizeStackSort(key: .fileSize)
        XCTAssertFalse(sort.ascending)
        XCTAssertEqual(ids(sort.sorted([light, heavyPrimary, heavyCompanion])), ids([heavyCompanion, heavyPrimary, light]))
        XCTAssertEqual(ids(sort.reversed.sorted([heavyCompanion, heavyPrimary, light])), ids([light, heavyPrimary, heavyCompanion]))
    }

    func testFileNameIsFinderStyle() {
        let ten = stack(item("DSC10.ARW", at: 0))
        let two = stack(item("dsc2.ARW", at: 1))
        let one = stack(item("DSC1.ARW", at: 2))

        let sort = OrganizeStackSort(key: .fileName)
        XCTAssertTrue(sort.ascending)
        XCTAssertEqual(ids(sort.sorted([ten, two, one])), ids([one, two, ten]))
        XCTAssertEqual(ids(sort.reversed.sorted([one, two, ten])), ids([ten, two, one]))
    }

    func testFileKindOrdersRawPhotoVideoOther() {
        let other = stack(item("X.BIN", kind: .other, at: 0))
        let video = stack(item("C0001.MP4", kind: .video, at: 1))
        let photo = stack(item("IMG.JPG", kind: .photo, at: 2))
        let raw = stack(item("DSC.ARW", kind: .raw, at: 3))

        let sort = OrganizeStackSort(key: .fileKind)
        XCTAssertEqual(ids(sort.sorted([other, video, photo, raw])), ids([raw, photo, video, other]))
        XCTAssertEqual(ids(sort.reversed.sorted([raw, photo, video, other])), ids([other, video, photo, raw]))
    }

    func testBurstDurationLongestFirst() {
        let long = stack(item("L1.ARW", at: 0), item("L2.ARW", at: 30))
        let short = stack(item("S1.ARW", at: 5), item("S2.ARW", at: 6))
        let single = stack(item("P.ARW", at: 10))

        let sort = OrganizeStackSort(key: .burstDuration)
        XCTAssertFalse(sort.ascending)
        XCTAssertEqual(ids(sort.sorted([single, short, long])), ids([long, short, single]))
    }

    /// Equal keys fall back to capture time, then file name — ascending in
    /// either direction — so the board never shuffles between renders.
    func testTiesBreakByCaptureTimeThenName() {
        let lateA = stack(item("A.ARW", at: 20))
        let earlyB = stack(item("B.ARW", at: 10))
        let earlyA = stack(item("A2.ARW", at: 10))
        let input = [lateA, earlyB, earlyA]
        let expected = ids([earlyA, earlyB, lateA])

        for key in [OrganizeSortKey.burstSize, .fileSize, .fileKind, .burstDuration] {
            XCTAssertEqual(ids(OrganizeStackSort(key: key, ascending: true).sorted(input)), expected, "\(key) ascending")
            XCTAssertEqual(ids(OrganizeStackSort(key: key, ascending: false).sorted(input)), expected, "\(key) descending")
        }
        // Same capture time and name in two folders: the stack id settles it.
        let first = OrganizeStack(items: [OrganizeItem(
            primary: OrganizeFile(path: "/Card/A/DSC1.ARW", size: 1, modifiedAt: base),
            kind: .raw, captureDate: base, hasCameraDate: true
        )])
        let second = OrganizeStack(items: [OrganizeItem(
            primary: OrganizeFile(path: "/Card/B/DSC1.ARW", size: 1, modifiedAt: base),
            kind: .raw, captureDate: base, hasCameraDate: true
        )])
        XCTAssertEqual(ids(OrganizeStackSort.newestFirst.sorted([second, first])), ids([first, second]))
    }

    func testEveryKeyHasTitlesAndAStartingDirection() {
        for key in OrganizeSortKey.allCases {
            XCTAssertFalse(key.title.isEmpty)
            XCTAssertNotEqual(key.directionTitle(ascending: true), key.directionTitle(ascending: false))
            let sort = OrganizeStackSort(key: key)
            XCTAssertEqual(sort.ascending, key.defaultAscending)
            XCTAssertNotEqual(sort.summary, sort.reversed.summary)
        }
    }

    /// An 11k-item board must sort in well under a frame budget's worth of
    /// work per change; this guards against a key that re-walks frames in
    /// the comparator.
    func testSortsElevenThousandStacksQuickly() {
        let stacks = (0..<11_000).map { index in
            OrganizeStack(items: (0..<(index % 7 + 1)).map { frame in
                item("B\(index)_DSC\(frame).ARW", at: TimeInterval(index * 10 + frame), size: Int64(index % 97))
            })
        }
        for key in OrganizeSortKey.allCases {
            let start = Date()
            let sorted = OrganizeStackSort(key: key).sorted(stacks)
            XCTAssertEqual(sorted.count, stacks.count)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "\(key) took too long")
        }
    }
}
