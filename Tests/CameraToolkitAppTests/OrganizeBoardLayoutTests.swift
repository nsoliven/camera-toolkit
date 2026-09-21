import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

final class OrganizeBoardLayoutTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date ?? .distantPast
    }

    private func item(_ path: String, kind: OrganizeMediaKind = .raw, at date: Date) -> OrganizeItem {
        OrganizeItem(
            primary: OrganizeFile(path: path, size: 100, modifiedAt: date),
            kind: kind,
            captureDate: date,
            hasCameraDate: true
        )
    }

    func testDayGroupingOrdersGroupsAndHonoursOrder() {
        let stacks = [
            OrganizeStack(items: [item("/Card/DCIM/DSC00002.ARW", at: date(2026, 8, 27))]),
            OrganizeStack(items: [item("/Card/DCIM/DSC00001.ARW", at: date(2026, 8, 26))]),
        ]

        let ascending = OrganizeBoardPlan.groups(for: stacks, grouping: .day, order: .oldestFirst)
        XCTAssertEqual(ascending.map(\.id), ["day|2026-08-26", "day|2026-08-27"])
        XCTAssertFalse(ascending[0].title.isEmpty)
        XCTAssertEqual(ascending[0].symbol, "calendar")

        let descending = OrganizeBoardPlan.groups(for: stacks, grouping: .day, order: .newestFirst)
        XCTAssertEqual(descending.map(\.id), ["day|2026-08-27", "day|2026-08-26"])
        XCTAssertEqual(descending[0].stacks.map(\.id), [stacks[0].id])
    }

    func testFolderGroupingUsesRootRelativeLabels() {
        let stacks = [
            OrganizeStack(items: [item("/Card/DCIM/Transfer 1/A0001.ARW", at: date(2026, 8, 26))]),
            OrganizeStack(items: [item("/Card/DCIM/Transfer 2/B0001.ARW", at: date(2026, 8, 26, hour: 13))]),
            OrganizeStack(items: [item("/Card/C0001.ARW", at: date(2026, 8, 26, hour: 14))]),
        ]

        let groups = OrganizeBoardPlan.groups(for: stacks, grouping: .folder, order: .oldestFirst, rootPath: "/Card")
        XCTAssertEqual(groups.map(\.title), ["Card", "Card/DCIM/Transfer 1", "Card/DCIM/Transfer 2"])
        XCTAssertEqual(groups.map(\.id), ["folder|Card", "folder|Card/DCIM/Transfer 1", "folder|Card/DCIM/Transfer 2"])
    }

    func testKindGroupingBucketsBurstsVideosAndStills() {
        let burst = OrganizeStack(items: [
            item("/Card/B0001_DSC00001.ARW", at: date(2026, 8, 26)),
            item("/Card/B0001_DSC00002.ARW", at: date(2026, 8, 26, minute: 1)),
        ])
        let video = OrganizeStack(items: [item("/Card/C0001.MP4", kind: .video, at: date(2026, 8, 26))])
        let photo = OrganizeStack(items: [item("/Card/DSC00001.ARW", at: date(2026, 8, 26))])

        let groups = OrganizeBoardPlan.groups(for: [photo, video, burst], grouping: .kind, order: .oldestFirst)
        XCTAssertEqual(groups.map(\.id), ["kind|burst", "kind|video", "kind|photo"])
        XCTAssertEqual(groups.map(\.title), ["Bursts", "Videos", "Photos"])
        XCTAssertEqual(groups[0].stacks.first?.items.count, 2)
    }

    func testKindGroupingSkipsEmptyBuckets() {
        let photo = OrganizeStack(items: [item("/Card/DSC00001.ARW", at: date(2026, 8, 26))])
        let groups = OrganizeBoardPlan.groups(for: [photo], grouping: .kind, order: .oldestFirst)
        XCTAssertEqual(groups.map(\.id), ["kind|photo"])
    }

    func testEventGroupingOrdersUnsortedMixedThenEventsByDate() {
        let beach = OrganizeEventBucket(key: "beach", title: "Beach Day", date: date(2026, 8, 26))
        let hike = OrganizeEventBucket(key: "hike", title: "Hike", date: date(2026, 8, 25))
        let unsorted = OrganizeStack(items: [item("/Card/DSC00001.ARW", at: date(2026, 8, 26))])
        let mixed = OrganizeStack(items: [item("/Card/DSC00002.ARW", at: date(2026, 8, 26))])
        let beachStack = OrganizeStack(items: [item("/Card/DSC00003.ARW", at: date(2026, 8, 26))])
        let hikeStack = OrganizeStack(items: [item("/Card/DSC00004.ARW", at: date(2026, 8, 26))])
        let buckets: [String: OrganizeEventBucket?] = [
            mixed.id: .mixed,
            beachStack.id: beach,
            hikeStack.id: hike,
        ]

        let groups = OrganizeBoardPlan.groups(
            for: [beachStack, hikeStack, mixed, unsorted],
            grouping: .event,
            order: .oldestFirst
        ) { buckets[$0.id] ?? nil }

        XCTAssertEqual(groups.map(\.id), ["event|unsorted", "event|mixed", "event|hike", "event|beach"])
        XCTAssertEqual(groups[0].title, "Not Sorted Yet")
        XCTAssertEqual(groups[1].title, "Mixed Events")
    }

    func testStackOrderingInsideAGroup() {
        let stacks = [
            OrganizeStack(items: [item("/Card/DSC00002.ARW", at: date(2026, 8, 26, hour: 15))]),
            OrganizeStack(items: [item("/Card/DSC00001.ARW", at: date(2026, 8, 26, hour: 9))]),
        ]
        let ascending = OrganizeBoardPlan.groups(for: stacks, grouping: .kind, order: .oldestFirst)
        XCTAssertEqual(ascending.first?.stacks.map(\.id), [stacks[1].id, stacks[0].id])
        let descending = OrganizeBoardPlan.groups(for: stacks, grouping: .kind, order: .newestFirst)
        XCTAssertEqual(descending.first?.stacks.map(\.id), [stacks[0].id, stacks[1].id])
    }

    func testGroupSubtitleCountsStacksFramesAndBytes() {
        let burst = OrganizeStack(items: [
            item("/Card/B0001_A.ARW", at: date(2026, 8, 26)),
            item("/Card/B0001_B.ARW", at: date(2026, 8, 26, minute: 1)),
        ])
        let group = OrganizeBoardGroup(id: "g", title: "G", symbol: nil, stacks: [burst])
        XCTAssertEqual(group.frameCount, 2)
        XCTAssertEqual(group.byteCount, 200)
        XCTAssertTrue(group.subtitle.contains("1 item"))
        XCTAssertTrue(group.subtitle.contains("2 frames"))
    }

    // MARK: - Collapsed sections

    /// The old board blanked a collapsed group's stacks and fed the empty
    /// copy to the header, so every collapsed day read "0 items · 0 frames
    /// · Zero KB" and Select had nothing to act on. A section's rows hide;
    /// its group must keep telling the truth.
    func testCollapsedSectionHidesRowsButKeepsTrueCounts() {
        let stacks = [
            OrganizeStack(items: [
                item("/Card/B0001_DSC00001.ARW", at: date(2026, 8, 26, hour: 9)),
                item("/Card/B0001_DSC00002.ARW", at: date(2026, 8, 26, hour: 9, minute: 1)),
            ]),
            OrganizeStack(items: [item("/Card/DSC00003.ARW", at: date(2026, 8, 26, hour: 12))]),
        ]
        let groups = OrganizeBoardPlan.groups(for: stacks, grouping: .day, order: .oldestFirst)
        let sections = OrganizeBoardPlan.sections(for: groups, collapsedIDs: [groups[0].id])

        let collapsed = sections[0]
        XCTAssertTrue(collapsed.isCollapsed)
        XCTAssertTrue(collapsed.visibleStacks.isEmpty)
        // Same stacks, same counts, same subtitle as the expanded group —
        // Select on the collapsed day selects these.
        XCTAssertEqual(collapsed.group.stacks.map(\.id), groups[0].stacks.map(\.id))
        XCTAssertEqual(collapsed.group.subtitle, groups[0].subtitle)
        XCTAssertEqual(collapsed.group.stacks.count, 2)
        XCTAssertEqual(collapsed.group.frameCount, 3)
        XCTAssertEqual(collapsed.group.byteCount, 300)
        XCTAssertFalse(collapsed.group.subtitle.hasPrefix("0 items"))
    }

    func testCollapseLeavesOtherSectionsUntouched() {
        let stacks = [
            OrganizeStack(items: [item("/Card/DSC00001.ARW", at: date(2026, 8, 26))]),
            OrganizeStack(items: [item("/Card/DSC00002.ARW", at: date(2026, 8, 27))]),
        ]
        let groups = OrganizeBoardPlan.groups(for: stacks, grouping: .day, order: .oldestFirst)
        let sections = OrganizeBoardPlan.sections(for: groups, collapsedIDs: [groups[0].id])

        XCTAssertEqual(sections.map(\.id), groups.map(\.id))
        XCTAssertTrue(sections[0].visibleStacks.isEmpty)
        XCTAssertFalse(sections[1].isCollapsed)
        XCTAssertEqual(sections[1].visibleStacks.map(\.id), groups[1].stacks.map(\.id))
        // The board's stack order only contains rows that are on screen.
        XCTAssertEqual(sections.flatMap(\.visibleStacks).map(\.id), [stacks[1].id])
    }

    /// A group exists because stacks landed in it — for every grouping the
    /// plan must never emit a zero-stack section, and a day with stacks
    /// must never format as 0 items.
    func testBoardPlanNeverProducesAZeroStackGroup() {
        let stacks = [
            OrganizeStack(items: [
                item("/Card/DCIM/B0001_DSC00001.ARW", at: date(2026, 8, 26)),
                item("/Card/DCIM/B0001_DSC00002.ARW", at: date(2026, 8, 26, minute: 1)),
            ]),
            OrganizeStack(items: [item("/Card/DCIM/C0001.MP4", kind: .video, at: date(2026, 8, 27))]),
            OrganizeStack(items: [item("/Card/DSC00003.ARW", kind: .photo, at: date(2026, 8, 28))]),
        ]
        for grouping in OrganizeBoardGrouping.allCases {
            let groups = OrganizeBoardPlan.groups(
                for: stacks,
                grouping: grouping,
                order: .oldestFirst,
                rootPath: "/Card"
            )
            XCTAssertFalse(groups.isEmpty, "\(grouping) dropped every group")
            for group in groups {
                XCTAssertFalse(group.stacks.isEmpty, "\(grouping) produced a zero-stack group: \(group.id)")
                XCTAssertFalse(group.subtitle.hasPrefix("0 items"), "\(group.id) formats as 0 items")
            }
        }
        XCTAssertTrue(OrganizeBoardPlan.groups(for: [], grouping: .day, order: .oldestFirst).isEmpty)
    }

    func testRouteLabelBreadcrumbDropsVolumesPrefix() {
        XCTAssertEqual(
            OrganizeRouteLabel.breadcrumb(for: "/Volumes/A7V/DCIM/Transfer 1"),
            "A7V ▸ DCIM ▸ Transfer 1"
        )
    }

    func testRouteLabelSubpath() {
        XCTAssertEqual(
            OrganizeRouteLabel.subpath(of: "/Event/Sony A7V/Card Copy", under: "/Event"),
            "Sony A7V ▸ Card Copy"
        )
        XCTAssertEqual(OrganizeRouteLabel.subpath(of: "/Event", under: "/Event"), "")
        // A path outside the root falls back to a full breadcrumb, never a lie.
        XCTAssertEqual(
            OrganizeRouteLabel.subpath(of: "/Elsewhere/X", under: "/Event"),
            OrganizeRouteLabel.breadcrumb(for: "/Elsewhere/X")
        )
    }
}
