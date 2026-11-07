import Foundation
@testable import CameraToolkitApp
import XCTest

/// The event picker's rows and keyboard highlight, decided outside SwiftUI.
final class EventPickerListTests: XCTestCase {
    private let trip = UUID()
    private let tripDay1 = UUID()
    private let tripDay2 = UUID()
    private let beach = UUID()
    private let party = UUID()

    /// Sidebar order: a parent with two indented subevents, then two
    /// top-level events.
    private var sidebar: [(id: UUID, depth: Int)] {
        [(trip, 0), (tripDay1, 1), (tripDay2, 1), (beach, 0), (party, 0)]
    }

    func testRecentsLeadThenTheWholeTreeInSidebarOrder() {
        let entries = EventPickerList.entries(
            recentIDs: [party, tripDay1],
            sidebarRows: sidebar,
            allowedIDs: nil,
            excludedID: nil,
            searching: false
        )
        XCTAssertEqual(entries.map(\.section), [.recent, .recent, .all, .all, .all, .all, .all])
        XCTAssertEqual(entries.map(\.eventID), [party, tripDay1, trip, tripDay1, tripDay2, beach, party])
        // The tree keeps its indent; recents are flat.
        XCTAssertEqual(entries.map(\.depth), [0, 0, 0, 1, 1, 0, 0])
        // Ids stay unique although recents repeat in the tree.
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
    }

    func testSearchPinsMatchingRecentsAndListsOtherMatchesOnce() {
        // The caller passes the sidebar already filtered by the query.
        let matching: [(id: UUID, depth: Int)] = [(trip, 0), (tripDay1, 1), (tripDay2, 1)]
        let entries = EventPickerList.entries(
            recentIDs: [party, tripDay2],
            sidebarRows: matching,
            allowedIDs: nil,
            excludedID: nil,
            searching: true
        )
        XCTAssertEqual(entries.map(\.section), [.recent, .matches, .matches])
        XCTAssertEqual(entries.map(\.eventID), [tripDay2, trip, tripDay1])
    }

    func testOnlyAllowedEventsAreOfferedAndTheExcludedOneIsDropped() {
        let entries = EventPickerList.entries(
            recentIDs: [beach, party],
            sidebarRows: sidebar,
            allowedIDs: [trip, tripDay1, beach, party],
            excludedID: party,
            searching: false
        )
        XCTAssertEqual(entries.map(\.eventID), [beach, trip, tripDay1, beach])
        XCTAssertFalse(entries.contains { $0.eventID == tripDay2 || $0.eventID == party })
    }

    func testNoEventsMeansNoRowsAndNoHighlight() {
        let entries = EventPickerList.entries(recentIDs: [], sidebarRows: [], allowedIDs: nil, excludedID: nil, searching: false)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertNil(EventPickerList.highlight(nil, in: entries))
        XCTAssertNil(EventPickerList.move(nil, by: 1, in: entries))
    }

    func testHighlightDefaultsToTheFirstRowAndArrowsClampAtTheEnds() {
        let entries = EventPickerList.entries(
            recentIDs: [beach],
            sidebarRows: sidebar,
            allowedIDs: nil,
            excludedID: nil,
            searching: false
        )
        let ids = entries.map(\.id)
        XCTAssertEqual(EventPickerList.highlight(nil, in: entries), ids[0])
        // A highlight that a new search filtered away falls back to the top.
        XCTAssertEqual(EventPickerList.highlight("all:\(UUID().uuidString)", in: entries), ids[0])
        XCTAssertEqual(EventPickerList.highlight(ids[3], in: entries), ids[3])

        XCTAssertEqual(EventPickerList.move(nil, by: 1, in: entries), ids[1])
        XCTAssertEqual(EventPickerList.move(ids[1], by: 1, in: entries), ids[2])
        XCTAssertEqual(EventPickerList.move(ids[0], by: -1, in: entries), ids[0])
        XCTAssertEqual(EventPickerList.move(ids.last, by: 1, in: entries), ids.last)
        XCTAssertEqual(EventPickerList.move(ids[2], by: -2, in: entries), ids[0])
    }
}
