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
        XCTAssertEqual(OrganizeSearch.needle("  TRIP \n"), "trip")
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
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "trip", rootPath: "/Card", eventTitle: "TRIP2026 / Matcha"))
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "matcha", rootPath: "/Card", eventTitle: "TRIP2026 / Matcha"))
        XCTAssertFalse(OrganizeSearch.matches(stack: stack, needle: "trip", rootPath: "/Card", eventTitle: nil))
    }

    func testMatchesPersonNameOnTheStacksFiles() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        XCTAssertTrue(OrganizeSearch.matches(
            stack: stack,
            needle: "sam",
            rootPath: "/Card",
            eventTitle: nil,
            personNames: ["Sam", "Person 1"]
        ))
        // Unnamed group labels hit too — "person" finds the Person 1 burst.
        XCTAssertTrue(OrganizeSearch.matches(
            stack: stack,
            needle: "person",
            rootPath: "/Card",
            eventTitle: nil,
            personNames: ["Sam", "Person 1"]
        ))
        XCTAssertFalse(OrganizeSearch.matches(
            stack: stack,
            needle: "dad",
            rootPath: "/Card",
            eventTitle: nil,
            personNames: ["Sam", "Person 1"]
        ))
        XCTAssertFalse(OrganizeSearch.matches(
            stack: stack,
            needle: "sam",
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

    func testPeopleRowCoversTheOperatorTruthTable() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        let dad = UUID()
        let mom = UUID()
        let stranger = UUID()
        func facts(_ ids: UUID...) -> OrganizeStackFacts {
            OrganizeStackFacts(personIDs: Set(ids))
        }

        // "is any of" — sharing one pick is enough.
        var search = filter([[.people([dad, mom], operator: .anyOf)]])
        XCTAssertFalse(matches(stack, search: search, facts: facts()))
        XCTAssertTrue(matches(stack, search: search, facts: facts(dad)))
        XCTAssertTrue(matches(stack, search: search, facts: facts(mom)))
        XCTAssertTrue(matches(stack, search: search, facts: facts(dad, mom)))

        // "is all of" — the AND inside a row: only a stack carrying both
        // picked people stays.
        search = filter([[.people([dad, mom], operator: .allOf)]])
        XCTAssertFalse(matches(stack, search: search, facts: facts()))
        XCTAssertFalse(matches(stack, search: search, facts: facts(dad)))
        XCTAssertFalse(matches(stack, search: search, facts: facts(mom)))
        XCTAssertTrue(matches(stack, search: search, facts: facts(dad, mom)))
        // A superset still satisfies "all of" — extras don't count against.
        XCTAssertTrue(matches(stack, search: search, facts: facts(dad, mom, stranger)))

        // "is none of" — a shared pick drops the stack.
        search = filter([[.people([dad, mom], operator: .noneOf)]])
        XCTAssertTrue(matches(stack, search: search, facts: facts()))
        XCTAssertFalse(matches(stack, search: search, facts: facts(dad)))
        XCTAssertFalse(matches(stack, search: search, facts: facts(mom)))
        XCTAssertFalse(matches(stack, search: search, facts: facts(dad, mom)))

        // "is not all of" — the stack stays while any pick is missing.
        search = filter([[.people([dad, mom], operator: .notAllOf)]])
        XCTAssertTrue(matches(stack, search: search, facts: facts()))
        XCTAssertTrue(matches(stack, search: search, facts: facts(dad)))
        XCTAssertTrue(matches(stack, search: search, facts: facts(mom)))
        XCTAssertFalse(matches(stack, search: search, facts: facts(dad, mom)))
    }

    func testMediaRowAllOfRequiresEveryPickedKind() {
        let stillOnly = OrganizeStack(items: [item("/Card/DSC00001.HEIC", kind: .photo)])
        let stillAndVideo = OrganizeStack(items: [
            item("/Card/DSC00002.HEIC", kind: .photo),
            item("/Card/C0002.MP4", kind: .video),
        ])
        let search = filter([[.media([.photo, .video], operator: .allOf)]])

        // A burst needs both halves of the AND — a lone still fails.
        XCTAssertFalse(matches(stillOnly, search: search))
        XCTAssertTrue(matches(stillAndVideo, search: search))
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
        let sam = UUID()
        let search = filter([[.people([sam]), .media([.raw])]])

        // The "Sam, stills only" shape: both rows must hold.
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [sam])))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts()))

        let video = OrganizeStack(items: [item("/Card/DCIM/C0001.MP4", kind: .video)])
        XCTAssertFalse(matches(video, search: search, facts: OrganizeStackFacts(personIDs: [sam])))
    }

    func testGroupsOrTogether() {
        let calendar = Calendar.current
        func day(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
        }
        let sam = UUID()
        // "(Sam and stills) or (a date range)".
        let search = filter([
            [.people([sam]), .media([.photo])],
            [.days(from: day(8, 26), to: day(8, 27))],
        ])

        let samStill = OrganizeStack(items: [item("/Card/DSC00001.HEIC", kind: .photo, capturedAt: day(9, 1))])
        let inRange = OrganizeStack(items: [item("/Card/DSC00002.ARW", kind: .raw, capturedAt: day(8, 26))])
        let samVideo = OrganizeStack(items: [item("/Card/C0001.MP4", kind: .video, capturedAt: day(9, 2))])
        let outsider = OrganizeStack(items: [item("/Card/DSC00003.ARW", kind: .raw, capturedAt: day(9, 3))])

        XCTAssertTrue(matches(samStill, search: search, facts: OrganizeStackFacts(personIDs: [sam])))
        XCTAssertTrue(matches(inRange, search: search))                          // group 2 alone
        // Sam on a video stack fails group 1's media row and lands
        // outside group 2's range — neither group keeps it.
        XCTAssertFalse(matches(samVideo, search: search, facts: OrganizeStackFacts(personIDs: [sam])))
        XCTAssertFalse(matches(outsider, search: search, facts: OrganizeStackFacts(personIDs: [sam])))
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

    // MARK: - Family scoping

    func testScopingEventRowsToAFamilyDropsOutsidePicks() {
        let parent = UUID()
        let child = UUID()
        let outside = UUID()
        let family: Set<UUID> = [parent, child]

        // An outside pick drops out of the row; an in-family pick stays,
        // and "Not Sorted Yet" clears — a family board's stacks all belong.
        var search = filter([[.events([child, outside], unsorted: true)]])
        var scoped = search.scopingEventRows(to: family)
        XCTAssertEqual(scoped.groups[0].rows[0].eventIDs, [child])
        XCTAssertFalse(scoped.groups[0].rows[0].includesUnsorted)

        // A fully-outside row goes empty and stops filtering instead of
        // blanking the board.
        search = filter([[.events([outside])]])
        scoped = search.scopingEventRows(to: family)
        XCTAssertTrue(scoped.groups[0].rows[0].isEmpty)
        XCTAssertFalse(scoped.hasActiveConditions)
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        XCTAssertTrue(matches(stack, search: scoped, facts: OrganizeStackFacts(eventIDs: [outside])))

        // "Not Sorted Yet" alone never applies on a family board.
        search = filter([[.events([], unsorted: true)]])
        XCTAssertFalse(search.scopingEventRows(to: family).hasActiveConditions)

        // Rows for other properties pass through untouched.
        let person = UUID()
        search = filter([[.people([person]), .events([outside])]])
        scoped = search.scopingEventRows(to: family)
        XCTAssertEqual(scoped.groups[0].rows[0].peopleIDs, [person])
        XCTAssertTrue(scoped.hasActiveConditions)
        XCTAssertTrue(matches(stack, search: scoped, facts: OrganizeStackFacts(personIDs: [person])))
        XCTAssertFalse(matches(stack, search: scoped, facts: OrganizeStackFacts()))
    }

    func testToggleEventExclusionWritesNoneOfRows() {
        let child = UUID()
        let sibling = UUID()

        // From an empty filter: one group holding an "is none of" row.
        var search = OrganizeSearchFilter()
        search.toggleEventExclusion(child)
        XCTAssertEqual(search.excludedEventIDs, [child])
        XCTAssertEqual(search.groups.count, 1)
        XCTAssertEqual(search.groups[0].rows.count, 1)
        XCTAssertEqual(search.groups[0].rows[0].property, .event)
        XCTAssertEqual(search.groups[0].rows[0].operator, .noneOf)
        XCTAssertEqual(search.groups[0].rows[0].eventIDs, [child])

        // A second exclusion joins the same row; removing one keeps the
        // other, and removing the last cleans the husk away entirely.
        search.toggleEventExclusion(sibling)
        XCTAssertEqual(search.excludedEventIDs, [child, sibling])
        search.toggleEventExclusion(child)
        XCTAssertEqual(search.excludedEventIDs, [sibling])
        search.toggleEventExclusion(sibling)
        XCTAssertTrue(search.groups.isEmpty)
        XCTAssertTrue(search.isUntouched)
    }

    func testToggleEventExclusionAppliesAcrossEveryGroup() {
        let child = UUID()
        let person = UUID()

        // Groups OR together, so the exclusion lands in each — a stack
        // matching any group still drops the excluded event.
        var search = OrganizeSearchFilter()
        search.groups = [
            OrganizeFilterGroup(rows: [.people([person])]),
            OrganizeFilterGroup(rows: [.media([.video])]),
        ]
        search.toggleEventExclusion(child)
        for group in search.groups {
            XCTAssertTrue(group.rows.contains {
                $0.property == .event && $0.operator == .noneOf && $0.eventIDs.contains(child)
            })
        }

        // Toggling back off removes just that row; the groups' own rows
        // survive untouched.
        search.toggleEventExclusion(child)
        XCTAssertEqual(search.groups.count, 2)
        for group in search.groups {
            XCTAssertEqual(group.rows.count, 1)
            XCTAssertFalse(group.rows.contains { $0.property == .event })
        }
    }
}
