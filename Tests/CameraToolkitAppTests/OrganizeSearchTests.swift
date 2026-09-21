import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

final class OrganizeSearchTests: XCTestCase {
    private func item(
        _ path: String,
        kind: OrganizeMediaKind = .raw,
        capturedAt: Date = Date(timeIntervalSince1970: 1_756_000_000)
    ) -> OrganizeItem {
        OrganizeItem(
            primary: OrganizeFile(path: path, size: 1, modifiedAt: Date()),
            kind: kind,
            captureDate: capturedAt,
            hasCameraDate: true
        )
    }

    private func matches(
        _ stack: OrganizeStack,
        search: OrganizeSearchFilter,
        facts: OrganizeStackFacts = OrganizeStackFacts()
    ) -> Bool {
        OrganizeSearch.matches(stack: stack, search: search, rootPath: "/Card", facts: facts)
    }

    func testNeedleTrimsAndLowercases() {
        XCTAssertEqual(OrganizeSearch.needle("  PHIL \n"), "phil")
        XCTAssertEqual(OrganizeSearch.needle("   "), "")
        XCTAssertEqual(OrganizeSearch.needle(""), "")
    }

    func testEmptyNeedleMatchesEveryStack() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "", rootPath: "/Card", eventTitle: nil))
    }

    func testMatchesAnyFileNameInAStack() {
        let stack = OrganizeStack(items: [
            item("/Card/DCIM/B0001_DSC00001.ARW"),
            item("/Card/DCIM/B0001_DSC00002.ARW"),
        ])
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "dsc00002", rootPath: "/Card", eventTitle: nil))
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: ".arw", rootPath: "/Card", eventTitle: nil))
        XCTAssertFalse(OrganizeSearch.matches(stack: stack, needle: "dsc00999", rootPath: "/Card", eventTitle: nil))
    }

    func testMatchesCompanionFileName() {
        var pair = item("/Card/DSC00001.ARW")
        pair.companions = [OrganizeFile(path: "/Card/DSC00001.xmp", size: 1, modifiedAt: Date())]
        let stack = OrganizeStack(items: [pair])
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: ".xmp", rootPath: "/Card", eventTitle: nil))
    }

    func testMatchesBurstLabel() {
        let stack = OrganizeStack(items: [item("/Card/B0007_DSC00001.ARW")])
        XCTAssertEqual(stack.burstLabel, "B0007")
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "b0007", rootPath: "/Card", eventTitle: nil))
    }

    func testMatchesOriginSubfolderRelativeToScanRoot() {
        let stack = OrganizeStack(items: [item("/Card/Transfer 1/100MSDCF/DSC00001.ARW")])
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "transfer 1/100", rootPath: "/Card", eventTitle: nil))
        // The same folder outside the scanned root is not an origin subfolder.
        XCTAssertFalse(OrganizeSearch.matches(stack: stack, needle: "transfer", rootPath: "/Other", eventTitle: nil))
        XCTAssertFalse(OrganizeSearch.matches(stack: stack, needle: "transfer", rootPath: nil, eventTitle: nil))
    }

    func testMatchesAssignedEventBreadcrumbTitle() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "phil", rootPath: "/Card", eventTitle: "PHIL2026 / Matcha"))
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "matcha", rootPath: "/Card", eventTitle: "PHIL2026 / Matcha"))
        XCTAssertFalse(OrganizeSearch.matches(stack: stack, needle: "phil", rootPath: "/Card", eventTitle: nil))
    }

    // MARK: - Structured filter

    func testEmptyFilterMatchesEverything() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        let search = OrganizeSearchFilter()
        XCTAssertTrue(search.isEmpty)
        XCTAssertEqual(search.activeFacetCount, 0)
        XCTAssertTrue(matches(stack, search: search))
    }

    func testPeopleFilterMatchesAnySelectedPersonOnTheStack() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        let dad = UUID()
        let mom = UUID()
        let stranger = UUID()

        var search = OrganizeSearchFilter()
        search.peopleIDs = [dad]
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [dad])))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [stranger])))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts()))

        // OR within the facet: any selected person qualifies the stack.
        search.peopleIDs = [dad, mom]
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [mom])))
    }

    func testEventFilterMatchesAssignedEventsAndUnsorted() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        let eventA = UUID()
        let eventB = UUID()

        var search = OrganizeSearchFilter()
        search.eventIDs = [eventA]
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [eventA])))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [eventB])))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts()))

        // "Not Sorted Yet" ORs with the named events.
        search.includeUnsorted = true
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [eventA])))
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts()))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [eventB])))

        // Unsorted alone hides everything assigned.
        search.eventIDs = []
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts()))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [eventA])))
    }

    func testMediaKindFilterMatchesAnyItemKind() {
        let raw = OrganizeStack(items: [item("/Card/DSC00001.ARW", kind: .raw)])
        let video = OrganizeStack(items: [item("/Card/C0001.MP4", kind: .video)])
        let mixed = OrganizeStack(items: [
            item("/Card/DSC00002.ARW", kind: .raw),
            item("/Card/C0002.MP4", kind: .video),
        ])

        var search = OrganizeSearchFilter()
        search.mediaKinds = [.raw]
        XCTAssertTrue(matches(raw, search: search))
        XCTAssertFalse(matches(video, search: search))
        XCTAssertTrue(matches(mixed, search: search))

        search.mediaKinds = [.video, .photo]
        XCTAssertFalse(matches(raw, search: search))
        XCTAssertTrue(matches(video, search: search))
    }

    func testDayRangeOverlapsStackCaptureInterval() {
        let calendar = Calendar.current
        func day(_ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        // A burst straddling midnight, and a single the next afternoon.
        let burst = OrganizeStack(items: [
            item("/Card/B0001_A.ARW", capturedAt: day(8, 26, hour: 23, minute: 59)),
            item("/Card/B0001_B.ARW", capturedAt: day(8, 27, hour: 0, minute: 1)),
        ])
        let single = OrganizeStack(items: [item("/Card/DSC00009.ARW", capturedAt: day(8, 27, hour: 15))])

        var search = OrganizeSearchFilter()
        search.dayStart = day(8, 26)
        search.dayEnd = day(8, 26)
        XCTAssertTrue(matches(burst, search: search))   // starts inside Aug 26
        XCTAssertFalse(matches(single, search: search))

        search.dayStart = day(8, 27)
        search.dayEnd = day(8, 27)
        XCTAssertTrue(matches(burst, search: search))   // ends inside Aug 27
        XCTAssertTrue(matches(single, search: search))

        // Open-ended ranges.
        search.dayStart = nil
        search.dayEnd = day(8, 26)
        XCTAssertTrue(matches(burst, search: search))
        XCTAssertFalse(matches(single, search: search))

        search.dayStart = day(8, 28)
        search.dayEnd = nil
        XCTAssertFalse(matches(burst, search: search))
        XCTAssertFalse(matches(single, search: search))
    }

    func testFacetsAndTextComposeAsAnd() {
        let stack = OrganizeStack(items: [item("/Card/DCIM/DSC00001.ARW", kind: .raw)])
        let person = UUID()

        var search = OrganizeSearchFilter()
        search.text = "dsc00001"
        search.mediaKinds = [.video]
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [person])))

        search.mediaKinds = [.raw]
        search.peopleIDs = [person]
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [person])))

        // Text still gates the result when every facet passes.
        search.text = "zzz"
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [person])))
    }
}
