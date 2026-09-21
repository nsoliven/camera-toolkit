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

    func testMatchesPersonNameOnTheStacksFiles() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        XCTAssertTrue(OrganizeSearch.matches(
            stack: stack,
            needle: "eileen",
            rootPath: "/Card",
            eventTitle: nil,
            personNames: ["Eileen", "Person 1"]
        ))
        // Unnamed group labels hit too — "person" finds the Person 1 burst.
        XCTAssertTrue(OrganizeSearch.matches(
            stack: stack,
            needle: "person",
            rootPath: "/Card",
            eventTitle: nil,
            personNames: ["Eileen", "Person 1"]
        ))
        XCTAssertFalse(OrganizeSearch.matches(
            stack: stack,
            needle: "dad",
            rootPath: "/Card",
            eventTitle: nil,
            personNames: ["Eileen", "Person 1"]
        ))
        XCTAssertFalse(OrganizeSearch.matches(
            stack: stack,
            needle: "eileen",
            rootPath: "/Card",
            eventTitle: nil,
            personNames: []
        ))
    }

    // MARK: - Structured filter

    /// Builds a search whose groups each hold the given condition rows.
    private func filter(_ groups: [[OrganizeFilterRow]], text: String = "") -> OrganizeSearchFilter {
        var search = OrganizeSearchFilter()
        search.text = text
        search.groups = groups.map { OrganizeFilterGroup(rows: $0) }
        return search
    }

    func testEmptyFilterMatchesEverything() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        let search = OrganizeSearchFilter()
        XCTAssertTrue(search.isEmpty)
        XCTAssertTrue(search.isUntouched)
        XCTAssertFalse(search.hasActiveConditions)
        XCTAssertEqual(search.activeRowCount, 0)
        XCTAssertTrue(matches(stack, search: search))
    }

    func testPeopleRowIncludesAnyPickedPerson() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        let dad = UUID()
        let mom = UUID()
        let stranger = UUID()

        var search = filter([[.people([dad])]])
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [dad])))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [stranger])))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts()))

        // Any of two people: either picked person qualifies the stack.
        search = filter([[.people([dad, mom])]])
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [mom])))
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [dad])))
    }

    func testPeopleRowExcludesPickedPerson() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        let dad = UUID()
        let nuisance = UUID()

        // "is none of" drops a stack when a picked person is on its files.
        let search = filter([[.people([nuisance], exclude: true)]])
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [nuisance])))
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [dad])))
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts()))

        // A stack carrying the excluded person beside another still drops.
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [dad, nuisance])))
    }

    func testEventRowMatchesAssignedEventsAndUnsorted() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        let eventA = UUID()
        let eventB = UUID()

        var search = filter([[.events([eventA])]])
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [eventA])))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [eventB])))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts()))

        // "Not Sorted Yet" ORs with the named events inside the same row.
        search = filter([[.events([eventA], unsorted: true)]])
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [eventA])))
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts()))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [eventB])))

        // Unsorted alone hides everything assigned.
        search = filter([[.events([], unsorted: true)]])
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts()))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [eventA])))

        // "is none of" drops stacks assigned to a picked event.
        search = filter([[.events([eventA], exclude: true)]])
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [eventA])))
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [eventB])))
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts()))
    }

    func testMediaRowMatchesAnyItemKind() {
        let raw = OrganizeStack(items: [item("/Card/DSC00001.ARW", kind: .raw)])
        let video = OrganizeStack(items: [item("/Card/C0001.MP4", kind: .video)])
        let mixed = OrganizeStack(items: [
            item("/Card/DSC00002.ARW", kind: .raw),
            item("/Card/C0002.MP4", kind: .video),
        ])

        var search = filter([[.media([.raw])]])
        XCTAssertTrue(matches(raw, search: search))
        XCTAssertFalse(matches(video, search: search))
        XCTAssertTrue(matches(mixed, search: search))

        search = filter([[.media([.video, .photo])]])
        XCTAssertFalse(matches(raw, search: search))
        XCTAssertTrue(matches(video, search: search))

        // "is none of" drops a stack when any item in it is a picked kind.
        search = filter([[.media([.video], exclude: true)]])
        XCTAssertTrue(matches(raw, search: search))
        XCTAssertFalse(matches(video, search: search))
        XCTAssertFalse(matches(mixed, search: search))
    }

    func testDateRowOverlapsStackCaptureInterval() {
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

        var search = filter([[.days(from: day(8, 26), to: day(8, 26))]])
        XCTAssertTrue(matches(burst, search: search))   // starts inside Aug 26
        XCTAssertFalse(matches(single, search: search))

        search = filter([[.days(from: day(8, 27), to: day(8, 27))]])
        XCTAssertTrue(matches(burst, search: search))   // ends inside Aug 27
        XCTAssertTrue(matches(single, search: search))

        // Open-ended ranges.
        search = filter([[.days(from: nil, to: day(8, 26))]])
        XCTAssertTrue(matches(burst, search: search))
        XCTAssertFalse(matches(single, search: search))

        search = filter([[.days(from: day(8, 28), to: nil)]])
        XCTAssertFalse(matches(burst, search: search))
        XCTAssertFalse(matches(single, search: search))
    }

    func testRowsInAGroupAndTogether() {
        let stack = OrganizeStack(items: [item("/Card/DCIM/DSC00001.ARW", kind: .raw)])
        let eileen = UUID()
        let search = filter([[.people([eileen]), .media([.raw])]])

        // The "Eileen, stills only" shape: both rows must hold.
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [eileen])))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts()))

        let video = OrganizeStack(items: [item("/Card/DCIM/C0001.MP4", kind: .video)])
        XCTAssertFalse(matches(video, search: search, facts: OrganizeStackFacts(personIDs: [eileen])))
    }

    func testGroupsOrTogether() {
        let calendar = Calendar.current
        func day(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
        }
        let eileen = UUID()
        // "(Eileen and stills) or (a date range)".
        let search = filter([
            [.people([eileen]), .media([.photo])],
            [.days(from: day(8, 26), to: day(8, 27))],
        ])

        let eileenStill = OrganizeStack(items: [item("/Card/DSC00001.HEIC", kind: .photo, capturedAt: day(9, 1))])
        let inRange = OrganizeStack(items: [item("/Card/DSC00002.ARW", kind: .raw, capturedAt: day(8, 26))])
        let eileenVideo = OrganizeStack(items: [item("/Card/C0001.MP4", kind: .video, capturedAt: day(9, 2))])
        let outsider = OrganizeStack(items: [item("/Card/DSC00003.ARW", kind: .raw, capturedAt: day(9, 3))])

        XCTAssertTrue(matches(eileenStill, search: search, facts: OrganizeStackFacts(personIDs: [eileen])))
        XCTAssertTrue(matches(inRange, search: search))                          // group 2 alone
        // Eileen on a video stack fails group 1's media row and lands
        // outside group 2's range — neither group keeps it.
        XCTAssertFalse(matches(eileenVideo, search: search, facts: OrganizeStackFacts(personIDs: [eileen])))
        XCTAssertFalse(matches(outsider, search: search, facts: OrganizeStackFacts(personIDs: [eileen])))
    }

    func testRowsWithNoValuesDoNotFilter() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        let person = UUID()

        // A valueless row passes; a group of them never widens an OR.
        var search = filter([[.people([])]])
        XCTAssertTrue(search.isEmpty)
        XCTAssertFalse(search.isUntouched)
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [person])))

        // An unfinished second group must not unfilter the board — a stack
        // failing group 1 stays out even though group 2 has no values yet.
        search = filter([[.media([.video])], [.people([])]])
        let video = OrganizeStack(items: [item("/Card/C0001.MP4", kind: .video)])
        XCTAssertTrue(matches(video, search: search, facts: OrganizeStackFacts(personIDs: [person])))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [person])))
    }

    func testGroupsAndTextComposeAsAnd() {
        let stack = OrganizeStack(items: [item("/Card/DCIM/DSC00001.ARW", kind: .raw)])
        let person = UUID()

        var search = filter([[.media([.video])]], text: "dsc00001")
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [person])))

        search = filter([[.people([person]), .media([.raw])]], text: "dsc00001")
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [person])))

        // Text still gates the result when every row passes.
        search = filter([[.people([person]), .media([.raw])]], text: "zzz")
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [person])))
    }
}
