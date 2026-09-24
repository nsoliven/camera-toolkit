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

    /// "is exactly A, B" — photos of just those two together. Both must
    /// be there and nobody else: another approved person, an unnamed
    /// group, or any face outside the approved people disqualifies it.
    func testPeopleRowIsExactlyKeepsOnlyThePickedPeopleAndNobodyElse() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        let personA = UUID()
        let personB = UUID()
        let personC = UUID()
        let unnamedGroup = UUID()
        func facts(_ ids: UUID..., others: Bool = false) -> OrganizeStackFacts {
            OrganizeStackFacts(personIDs: Set(ids), hasOtherFaces: others)
        }
        let search = filter([[.people([personA, personB], operator: .exactly)]])

        // A and B alone together: kept.
        XCTAssertTrue(matches(stack, search: search, facts: facts(personA, personB)))
        // Only one of them: dropped.
        XCTAssertFalse(matches(stack, search: search, facts: facts(personA)))
        XCTAssertFalse(matches(stack, search: search, facts: facts(personB)))
        // A third approved person: dropped.
        XCTAssertFalse(matches(stack, search: search, facts: facts(personA, personB, personC)))
        // An unnamed group listed among the subject's people: dropped.
        XCTAssertFalse(matches(stack, search: search, facts: facts(personA, personB, unnamedGroup)))
        // A face outside the approved people (unnamed group, suggestion,
        // or never grouped) flagged by the board index: dropped.
        XCTAssertFalse(matches(stack, search: search, facts: facts(personA, personB, others: true)))
        // No faces at all: dropped.
        XCTAssertFalse(matches(stack, search: search, facts: facts()))
        XCTAssertFalse(matches(stack, search: search, facts: facts(others: true)))

        // "is not exactly" is the negation, row for row.
        let negated = filter([[.people([personA, personB], operator: .notExactly)]])
        XCTAssertFalse(matches(stack, search: negated, facts: facts(personA, personB)))
        XCTAssertTrue(matches(stack, search: negated, facts: facts(personA)))
        XCTAssertTrue(matches(stack, search: negated, facts: facts(personA, personB, personC)))
        XCTAssertTrue(matches(stack, search: negated, facts: facts(personA, personB, others: true)))
        XCTAssertTrue(matches(stack, search: negated, facts: facts()))

        // "is all of" still ignores the extras — only "exactly" reads them.
        let allOf = filter([[.people([personA, personB], operator: .allOf)]])
        XCTAssertTrue(matches(stack, search: allOf, facts: facts(personA, personB, others: true)))
    }

    /// A burst is judged on the union of its frames, like every other
    /// operator: one frame of A alone and one of B alone make an
    /// "exactly A, B" burst. The board index folds frames the same way,
    /// so a stranger in any frame disqualifies the whole burst.
    func testPeopleRowIsExactlyUsesTheUnionOfABurstsFrames() {
        let burst = OrganizeStack(items: [
            item("/Card/B0001_DSC00001.ARW"),
            item("/Card/B0001_DSC00002.ARW"),
        ])
        XCTAssertTrue(burst.isBurst)
        let personA = UUID()
        let personB = UUID()
        let search = filter([[.people([personA, personB], operator: .exactly)]])
        // Frame 1 carries A, frame 2 carries B — the stack's facts are the
        // union {A, B}.
        XCTAssertTrue(matches(burst, search: search, facts: OrganizeStackFacts(personIDs: [personA, personB])))
        XCTAssertFalse(matches(
            burst,
            search: search,
            facts: OrganizeStackFacts(personIDs: [personA, personB], hasOtherFaces: true)
        ))
    }

    /// "is exactly" composes like any row: ANDed with the group's other
    /// rows and under the board-level chip exclusions.
    func testPeopleRowIsExactlyCombinesWithOtherRowsAndExclusions() {
        let parent = UUID()
        let subevent = UUID()
        let personA = UUID()
        let personB = UUID()
        let raw = OrganizeStack(items: [item("/Card/DSC00001.ARW", kind: .raw)])
        let clip = OrganizeStack(items: [item("/Card/C0001.MP4", kind: .video)])
        func facts(_ people: Set<UUID>, others: Bool = false, inSubevent: Bool = false) -> OrganizeStackFacts {
            OrganizeStackFacts(
                eventIDs: inSubevent ? [subevent, parent] : [parent],
                personIDs: people,
                hasOtherFaces: others
            )
        }

        var search = OrganizeSearchFilter()
        search.toggleEventExclusion(subevent)
        search.addCondition(.people([personA, personB], operator: .exactly))
        search.addCondition(.media([.raw]))
        search.addCondition(.events([parent]))
        XCTAssertEqual(search.groups.count, 1)
        XCTAssertTrue(search.needsPeople)

        // Just A and B, RAW, in the parent: kept.
        XCTAssertTrue(matches(raw, search: search, facts: facts([personA, personB])))
        // Same people but a video: the Media row drops it.
        XCTAssertFalse(matches(clip, search: search, facts: facts([personA, personB])))
        // Same people inside the struck subevent: the chip hides it.
        XCTAssertFalse(matches(raw, search: search, facts: facts([personA, personB], inSubevent: true)))
        // Someone else in the shot: dropped whatever the other rows say.
        XCTAssertFalse(matches(raw, search: search, facts: facts([personA, personB], others: true)))
        // Not in the parent event: the Event row drops it.
        XCTAssertFalse(matches(raw, search: search, facts: OrganizeStackFacts(personIDs: [personA, personB])))
    }

    /// The exact pair is People-only in the picker, with wording that says
    /// nobody else may be in the shot; chips keep the short form.
    func testIsExactlyOperatorIsOfferedOnlyForPeople() {
        typealias Operator = OrganizeFilterRow.Operator
        XCTAssertEqual(Operator.options(for: .people), Operator.allCases)
        XCTAssertTrue(Operator.options(for: .people).contains(.exactly))
        XCTAssertTrue(Operator.options(for: .people).contains(.notExactly))
        for property in [OrganizeFilterRow.Property.event, .media, .date] {
            XCTAssertFalse(Operator.options(for: property).contains(.exactly), "\(property)")
            XCTAssertFalse(Operator.options(for: property).contains(.notExactly), "\(property)")
        }
        XCTAssertEqual(Operator.exactly.menuTitle, "is exactly (only these people)")
        XCTAssertEqual(Operator.exactly.title, "is exactly")
        XCTAssertEqual(Operator.anyOf.menuTitle, Operator.anyOf.title)

        // Switching an exact People row to another property starts over
        // on "is any of", so the hidden operator never lingers.
        var row = OrganizeFilterRow.people([UUID()], operator: .exactly)
        row.setProperty(.media)
        XCTAssertEqual(row.operator, .anyOf)
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

    // MARK: - Pausing rows

    func testPausedRowStopsMatchingWithoutDeletingIt() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        let dad = UUID()
        let stranger = UUID()

        var search = filter([[.people([dad])]])
        let rowID = search.groups[0].rows[0].id
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [dad])))
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [stranger])))

        // Off: the row keeps its picks and its seat but stops filtering —
        // the board and the "N of M" count read the search as unfiltered.
        search.toggleRow(rowID)
        XCTAssertFalse(search.groups[0].rows[0].isEnabled)
        XCTAssertEqual(search.groups[0].rows.count, 1)
        XCTAssertEqual(search.groups[0].rows[0].peopleIDs, [dad])
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [stranger])))
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts()))
        XCTAssertTrue(search.isEmpty)
        XCTAssertFalse(search.hasActiveConditions)
        XCTAssertEqual(search.activeRowCount, 0)
        XCTAssertFalse(search.needsPeople)
        // The row still exists, so Clear All still has something to clear.
        XCTAssertFalse(search.isUntouched)
        // A paused row stays a hot link — only valueless rows drop out.
        XCTAssertEqual(search.rowsWithValues.count, 1)

        // Back on: the same row filters again.
        search.toggleRow(rowID)
        XCTAssertTrue(search.groups[0].rows[0].isEnabled)
        XCTAssertEqual(search.groups[0].rows.count, 1)
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [stranger])))
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [dad])))
        XCTAssertTrue(search.hasActiveConditions)
        XCTAssertEqual(search.activeRowCount, 1)
        XCTAssertTrue(search.needsPeople)
    }

    func testPausedRowLeavesItsSiblingsFiltering() {
        let sam = UUID()
        let raw = OrganizeStack(items: [item("/Card/DSC00001.ARW", kind: .raw)])
        let video = OrganizeStack(items: [item("/Card/C0001.MP4", kind: .video)])

        // AND inside a group: pausing the media row leaves the people
        // row deciding on its own.
        var search = filter([[.people([sam]), .media([.video])]])
        search.toggleRow(search.groups[0].rows[1].id)
        XCTAssertTrue(matches(raw, search: search, facts: OrganizeStackFacts(personIDs: [sam])))
        XCTAssertFalse(matches(raw, search: search, facts: OrganizeStackFacts()))
        XCTAssertFalse(matches(video, search: search, facts: OrganizeStackFacts()))
        XCTAssertTrue(search.hasActiveConditions)

        // OR across groups: a group whose only row is paused drops out of
        // the OR instead of widening the match.
        search = filter([[.media([.video])], [.people([sam])]])
        search.toggleRow(search.groups[1].rows[0].id)
        XCTAssertEqual(search.groups.count, 2)
        XCTAssertTrue(matches(video, search: search))
        XCTAssertFalse(matches(raw, search: search, facts: OrganizeStackFacts(personIDs: [sam])))
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

    // MARK: - Board-level exclusions

    func testToggleEventExclusionWritesTheBoardLevelSetNotRows() {
        let child = UUID()
        let sibling = UUID()

        // From an empty filter: the chip lands in the exclusion set and
        // creates no condition rows.
        var search = OrganizeSearchFilter()
        search.toggleEventExclusion(child)
        XCTAssertEqual(search.excludedEventIDs, [child])
        XCTAssertTrue(search.groups.isEmpty)
        XCTAssertTrue(search.rowsWithValues.isEmpty)
        XCTAssertTrue(search.hasActiveConditions)
        XCTAssertFalse(search.isEmpty)
        XCTAssertFalse(search.isUntouched)
        XCTAssertEqual(search.activeRowCount, 1)

        // A second exclusion joins; removing one keeps the other, and
        // removing the last leaves nothing behind.
        search.toggleEventExclusion(sibling)
        XCTAssertEqual(search.excludedEventIDs, [child, sibling])
        XCTAssertEqual(search.activeRowCount, 2)
        search.toggleEventExclusion(child)
        XCTAssertEqual(search.excludedEventIDs, [sibling])
        search.toggleEventExclusion(sibling)
        XCTAssertTrue(search.isUntouched)
        XCTAssertTrue(search.isEmpty)
    }

    func testChipStateRoundTripsAndLeavesHandBuiltRowsAlone() {
        let child = UUID()
        let person = UUID()

        // A hand-built "Event is none of" row is the user's own condition:
        // it does not strike the chip, and toggling the chip never edits
        // or removes it.
        var search = filter([[.events([child], operator: .noneOf), .people([person])]])
        let before = search.groups
        XCTAssertTrue(search.excludedEventIDs.isEmpty)
        search.toggleEventExclusion(child)
        XCTAssertEqual(search.excludedEventIDs, [child])
        XCTAssertEqual(search.groups, before)
        search.toggleEventExclusion(child)
        XCTAssertTrue(search.excludedEventIDs.isEmpty)
        XCTAssertEqual(search.groups, before)

        // Clearing conditions drops rows and exclusions, keeps the text.
        search.text = "dsc"
        search.toggleEventExclusion(child)
        search.clearConditions()
        XCTAssertTrue(search.groups.isEmpty)
        XCTAssertTrue(search.excludedEventIDs.isEmpty)
        XCTAssertEqual(search.text, "dsc")
    }

    /// The reported case: a subevent chip struck through, then a People
    /// group built afterwards ("any of A, B" and "none of C, D"). The
    /// exclusion must still hide the subevent's photos, and C's photos
    /// must drop — everything the user added narrows.
    func testChipExclusionThenPeopleConditionsAllNarrow() {
        let parent = UUID()
        let subevent = UUID()
        let personA = UUID()
        let personB = UUID()
        let personC = UUID()
        let personD = UUID()
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        func facts(_ people: Set<UUID>, inSubevent: Bool) -> OrganizeStackFacts {
            OrganizeStackFacts(eventIDs: inSubevent ? [subevent, parent] : [parent], personIDs: people)
        }

        var search = OrganizeSearchFilter()
        search.toggleEventExclusion(subevent)
        // The panel's default "Add Condition" path, twice.
        search.addCondition(.people([personA, personB], operator: .anyOf))
        search.addCondition(.people([personC, personD], operator: .noneOf))
        XCTAssertEqual(search.groups.count, 1, "the default add path must never open an OR group")
        XCTAssertEqual(search.groups[0].rows.count, 2)

        // A alone, outside the subevent: kept.
        XCTAssertTrue(matches(stack, search: search, facts: facts([personA], inSubevent: false)))
        // A with C: C is excluded.
        XCTAssertFalse(matches(stack, search: search, facts: facts([personA, personC], inSubevent: false)))
        // C alone: neither A nor B, and C is excluded.
        XCTAssertFalse(matches(stack, search: search, facts: facts([personC], inSubevent: false)))
        // Nobody: fails "any of A, B".
        XCTAssertFalse(matches(stack, search: search, facts: facts([], inSubevent: false)))
        // A inside the struck subevent: hidden by the chip.
        XCTAssertFalse(matches(stack, search: search, facts: facts([personA], inSubevent: true)))

        // Even a deliberate "or" group cannot bring the subevent back.
        search.addOrGroup(.media([.raw]))
        XCTAssertEqual(search.groups.count, 2)
        XCTAssertFalse(matches(stack, search: search, facts: facts([personA], inSubevent: true)))
        XCTAssertFalse(matches(stack, search: search, facts: facts([], inSubevent: true)))
        // Outside the subevent, the "or" group widens as asked.
        XCTAssertTrue(matches(stack, search: search, facts: facts([personC], inSubevent: false)))
    }

    /// The old chip behaviour stuffed "none of" rows into each group; a
    /// filter still holding such rows (the reported shape: the chip's row
    /// alone in group 1, People rows in group 2) keeps its literal OR
    /// meaning. Nothing rewrites hand-visible rows behind the user's back.
    func testLegacyChipRowInItsOwnGroupKeepsItsOrMeaning() {
        let subevent = UUID()
        let personA = UUID()
        let personC = UUID()
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        let search = filter([
            [.events([subevent], operator: .noneOf)],
            [.people([personA]), .people([personC], operator: .noneOf)],
        ])
        XCTAssertTrue(search.excludedEventIDs.isEmpty)
        // C's photo outside the subevent passes group 1 — the OR the
        // panel draws between the groups.
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(personIDs: [personC])))
    }

    func testExclusionAndOrGroupsTruthTable() {
        let excluded = UUID()
        let other = UUID()
        let personA = UUID()
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        let groupA = [OrganizeFilterRow.people([personA])]
        let groupVideo = [OrganizeFilterRow.media([.video])]

        // (excluded?, groups, subject in excluded?, has A?) → kept?
        let cases: [(Bool, [[OrganizeFilterRow]], Bool, Bool, Bool)] = [
            // No exclusion, no groups: everything.
            (false, [], false, false, true),
            (false, [], true, true, true),
            // Exclusion only: drops exactly the excluded event's stacks.
            (true, [], false, false, true),
            (true, [], true, false, false),
            // One group: exclusion ∧ group.
            (true, [groupA], false, true, true),
            (true, [groupA], false, false, false),
            (true, [groupA], true, true, false),
            // Two OR-groups: exclusion ∧ (A ∨ video) — RAW here, so A decides.
            (true, [groupA, groupVideo], false, true, true),
            (true, [groupA, groupVideo], false, false, false),
            (true, [groupA, groupVideo], true, true, false),
            (false, [groupA, groupVideo], true, true, true),
            // An empty group applies nothing; the exclusion still does.
            (true, [[OrganizeFilterRow(property: .people)]], true, true, false),
            (true, [[OrganizeFilterRow(property: .people)]], false, false, true),
        ]
        for (index, (hasExclusion, groups, inExcluded, hasA, expected)) in cases.enumerated() {
            var search = filter(groups)
            if hasExclusion { search.toggleEventExclusion(excluded) }
            let facts = OrganizeStackFacts(
                eventIDs: inExcluded ? [excluded] : [other],
                personIDs: hasA ? [personA] : []
            )
            XCTAssertEqual(matches(stack, search: search, facts: facts), expected, "case \(index)")
        }
    }

    func testExclusionHidesDescendantsAndScopesToTheFamily() {
        let parent = UUID()
        let child = UUID()
        let outside = UUID()
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        var search = OrganizeSearchFilter()
        search.toggleEventExclusion(child)
        search.toggleEventExclusion(outside)

        // A grandchild's stack carries its ancestors, so it drops too.
        XCTAssertFalse(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [UUID(), child, parent])))
        XCTAssertTrue(matches(stack, search: search, facts: OrganizeStackFacts(eventIDs: [parent])))

        // A family board keeps only in-family exclusions.
        let scoped = search.scopingEventRows(to: [parent, child])
        XCTAssertEqual(scoped.excludedEventIDs, [child])
        XCTAssertFalse(search.scopingEventRows(to: [parent]).hasActiveConditions)
    }

    func testDefaultAddNarrowsAndOrIsExplicit() {
        var search = OrganizeSearchFilter()
        search.addCondition(.media([.raw]))
        search.addCondition(.media([.video]))
        search.addCondition(.people([UUID()]))
        XCTAssertEqual(search.groups.count, 1)
        XCTAssertEqual(search.groups[0].rows.count, 3)

        // After a deliberate "or", the default add goes to that last group.
        search.addOrGroup(.media([.photo]))
        search.addCondition(.people([UUID()]))
        XCTAssertEqual(search.groups.map(\.rows.count), [3, 2])
    }
}
