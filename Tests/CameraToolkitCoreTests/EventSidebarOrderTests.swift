import CameraToolkitCore
import Foundation
import XCTest

/// Manual sidebar order and the re-parent rules: an older config lists
/// exactly as before, the first placement freezes the order a group shows,
/// and a re-parent never makes a cycle or nests past the layout's depth.
final class EventSidebarOrderTests: XCTestCase {
    private func event(_ name: String, _ date: String, parent: SavedCameraEvent? = nil, order: Int? = nil) -> SavedCameraEvent {
        SavedCameraEvent(
            name: name,
            eventDate: DateFormatter.yyyyMMdd.date(from: date)!,
            parentEventID: parent?.id,
            sidebarOrder: order
        )
    }

    private func names(_ rows: [(event: SavedCameraEvent, depth: Int)]) -> [String] {
        rows.map { String(repeating: "  ", count: $0.depth) + $0.event.name }
    }

    // MARK: Persistence and migration

    func testOlderConfigurationsDecodeWithoutSidebarOrderAndKeepTheirOrder() throws {
        let json = #"""
        {"bufferPath":"/tmp/Buffer","savedEvents":[
          {"id":"8987780B-3749-43BC-8801-D7DF3B7FFAD7","name":"Beach Day","eventDate":100,"createdAt":0,"lastUsedAt":0},
          {"id":"1D7B1B2C-6A0E-4D57-9E7B-3C1A0F1D2E3F","name":"Trip 2026","eventDate":300,"createdAt":0,"lastUsedAt":0},
          {"id":"5C8A2F3E-1B4D-4E6F-8A9B-0C1D2E3F4A5B","name":"Day One","eventDate":200,"createdAt":0,"lastUsedAt":0,
           "parentEventID":"1D7B1B2C-6A0E-4D57-9E7B-3C1A0F1D2E3F"},
          {"id":"6D9B3A4F-2C5E-4F70-9BAC-1D2E3F4A5B6C","name":"Day Two","eventDate":250,"createdAt":0,"lastUsedAt":0,
           "parentEventID":"1D7B1B2C-6A0E-4D57-9E7B-3C1A0F1D2E3F"},
          {"id":"7EAC4B5A-3D6F-4081-ACBD-2E3F4A5B6C7D","name":"Hike","eventDate":100,"createdAt":0,"lastUsedAt":0}
        ]}
        """#
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        XCTAssertTrue(configuration.savedEvents.allSatisfy { $0.sidebarOrder == nil })
        // Exactly the old order: newest first, then by name, children under
        // their parent the same way.
        XCTAssertEqual(names(EventHierarchy.flattened(configuration.savedEvents)), [
            "Trip 2026", "  Day Two", "  Day One", "Beach Day", "Hike",
        ])

        var placed = configuration
        placed.savedEvents[0].sidebarOrder = 4
        let roundTrip = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(placed))
        XCTAssertEqual(roundTrip.savedEvents[0].sidebarOrder, 4)
        XCTAssertNil(roundTrip.savedEvents[1].sidebarOrder)
    }

    func testTheConfigurationFileKeepsTheOrderAcrossASave() throws {
        try withTemporaryDirectory { root in
            let store = ConfigurationStore(url: root.appendingPathComponent("config.json"))
            var configuration = AppConfiguration.testConfiguration(root: root, catalog: root.appendingPathComponent("catalog.sqlite"))
            configuration.savedEvents = [event("Beach Day", "2026-05-02", order: 1), event("Hike", "2026-05-03")]
            try store.save(configuration)
            let loaded = try store.load(defaults: configuration)
            XCTAssertEqual(loaded.savedEvents.map(\.sidebarOrder), [1, nil])
        }
    }

    func testTheCatalogKeepsTheOrderAndAReorderRewritesOnlyThePlacedEvents() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("CameraToolkit/catalog.sqlite")
            let outcome = CatalogStateStartup.resolve(
                configurationURL: root.appendingPathComponent("CameraToolkit/config.json"),
                defaults: .testConfiguration(root: root, catalog: catalog),
                backups: { url in
                    CatalogBackupService(catalogURL: url, configurationURL: nil, localFolder: root.appendingPathComponent("Backups"), remoteFolder: nil)
                }
            )
            guard case .catalog(let baseline) = outcome.mode else { return XCTFail("expected catalog mode") }
            let store = CatalogStateStore(url: catalog)
            var first = baseline
            let trip = event("Trip 2026", "2026-05-01")
            first.savedEvents = [
                trip,
                event("Beach Day", "2026-05-02"),
                event("Hike", "2026-05-03"),
                event("Day One", "2026-05-01", parent: trip),
            ]
            try store.apply(from: baseline, to: first)

            var reordered = first
            reordered.savedEvents = EventHierarchy.placing(trip.id, under: nil, before: first.savedEvents[2].id, in: first.savedEvents)
            let summary = try store.apply(from: first, to: reordered)
            XCTAssertEqual(summary.eventsWritten, 3, "the three top-level events froze; the subevent was not rewritten")
            XCTAssertEqual(summary.assignmentsWritten, 0)

            let loaded = try store.load()
            XCTAssertEqual(loaded.savedEvents.map(\.sidebarOrder), reordered.savedEvents.map(\.sidebarOrder))
            XCTAssertEqual(names(EventHierarchy.flattened(loaded.savedEvents)), ["Trip 2026", "  Day One", "Hike", "Beach Day"])
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    // MARK: Ordering

    func testTheFirstPlacementFreezesTheShownOrderThenMoves() {
        let hike = event("Hike", "2026-05-03")
        let beach = event("Beach Day", "2026-05-02")
        let trip = event("Trip 2026", "2026-05-01")
        let events = [trip, beach, hike]
        XCTAssertEqual(names(EventHierarchy.flattened(events)), ["Hike", "Beach Day", "Trip 2026"])

        let placed = EventHierarchy.placing(trip.id, under: nil, before: hike.id, in: events)
        XCTAssertEqual(names(EventHierarchy.flattened(placed)), ["Trip 2026", "Hike", "Beach Day"])
        XCTAssertEqual(Set(placed.map(\.sidebarOrder)), [0, 1, 2], "the whole group froze")

        // To the end, then before a sibling — still only order changes.
        let last = EventHierarchy.placing(trip.id, under: nil, before: nil, in: placed)
        XCTAssertEqual(names(EventHierarchy.flattened(last)), ["Hike", "Beach Day", "Trip 2026"])
        for (old, new) in zip(events, last) {
            var aligned = new
            aligned.sidebarOrder = old.sidebarOrder
            XCTAssertEqual(aligned, old, "a placement changes nothing but the order")
        }
    }

    func testANewEventListsFirstInAPlacedGroupAndAnUnplacedGroupKeepsDateOrder() {
        let trip = event("Trip 2026", "2026-05-01")
        let dayOne = event("Day One", "2026-05-01", parent: trip)
        let dayTwo = event("Day Two", "2026-05-02", parent: trip)
        let hike = event("Hike", "2026-05-03")
        var events = EventHierarchy.placing(trip.id, under: nil, before: nil, in: [trip, dayOne, dayTwo, hike])
        XCTAssertEqual(names(EventHierarchy.flattened(events)), ["Hike", "Trip 2026", "  Day Two", "  Day One"])
        XCTAssertNil(events.first { $0.id == dayOne.id }?.sidebarOrder, "the subevents' group was not touched")
        events.append(event("Beach Day", "2020-01-01"))
        XCTAssertEqual(
            names(EventHierarchy.flattened(events)),
            ["Beach Day", "Hike", "Trip 2026", "  Day Two", "  Day One"],
            "an event never placed lists first, so a new one is easy to find"
        )
        XCTAssertEqual(EventHierarchy.children(of: trip.id, in: events).map(\.name), ["Day Two", "Day One"])
    }

    func testPlacingAmongSubeventsLeavesOtherGroupsAlone() {
        let trip = event("Trip 2026", "2026-05-01")
        let dayOne = event("Day One", "2026-05-01", parent: trip)
        let dayTwo = event("Day Two", "2026-05-02", parent: trip)
        let hike = event("Hike", "2026-05-03")
        let placed = EventHierarchy.placing(dayOne.id, under: trip.id, before: dayTwo.id, in: [trip, dayOne, dayTwo, hike])
        XCTAssertEqual(names(EventHierarchy.flattened(placed)), ["Hike", "Trip 2026", "  Day One", "  Day Two"])
        XCTAssertNil(placed.first { $0.id == trip.id }?.sidebarOrder)
        XCTAssertNil(placed.first { $0.id == hike.id }?.sidebarOrder)
        // Asking to place it in a group it is not listed in changes nothing.
        XCTAssertEqual(EventHierarchy.placing(dayOne.id, under: nil, before: nil, in: placed), placed)
    }

    // MARK: Re-parent rules

    func testReparentRefusesCyclesSelfAndNoOps() {
        let trip = event("Trip 2026", "2026-05-01")
        let day = event("Day One", "2026-05-01", parent: trip)
        let hour = event("Golden Hour", "2026-05-01", parent: day)
        let beach = event("Beach Day", "2026-05-02")
        let events = [trip, day, hour, beach]
        XCTAssertEqual(EventHierarchy.reparentProblem(moving: trip.id, to: trip.id, in: events), .ontoItself)
        XCTAssertEqual(EventHierarchy.reparentProblem(moving: trip.id, to: day.id, in: events), .intoOwnSubevent)
        XCTAssertEqual(EventHierarchy.reparentProblem(moving: trip.id, to: hour.id, in: events), .intoOwnSubevent)
        XCTAssertEqual(EventHierarchy.reparentProblem(moving: day.id, to: trip.id, in: events), .alreadyThere)
        XCTAssertEqual(EventHierarchy.reparentProblem(moving: trip.id, to: nil, in: events), .alreadyThere)
        XCTAssertEqual(EventHierarchy.reparentProblem(moving: UUID(), to: nil, in: events), .missingEvent)
        XCTAssertNil(EventHierarchy.reparentProblem(moving: day.id, to: nil, in: events))
        XCTAssertNil(EventHierarchy.reparentProblem(moving: beach.id, to: trip.id, in: events))
        XCTAssertNil(EventHierarchy.reparentProblem(moving: beach.id, to: day.id, in: events), "depth 2 is the deepest allowed")
    }

    func testReparentRefusesNestingPastTheDepthTheLayoutAllows() {
        let trip = event("Trip 2026", "2026-05-01")
        let day = event("Day One", "2026-05-01", parent: trip)
        let hour = event("Golden Hour", "2026-05-01", parent: day)
        let beach = event("Beach Day", "2026-05-02")
        let swim = event("Swim", "2026-05-02", parent: beach)
        let events = [trip, day, hour, beach, swim]
        XCTAssertEqual(EventHierarchy.maxDepth, 2)
        XCTAssertEqual(EventHierarchy.reparentProblem(moving: beach.id, to: hour.id, in: events), .tooDeep)
        XCTAssertEqual(
            EventHierarchy.reparentProblem(moving: beach.id, to: day.id, in: events), .tooDeep,
            "Beach Day would sit at depth 2 and carry Swim to depth 3"
        )
        XCTAssertNil(EventHierarchy.reparentProblem(moving: beach.id, to: trip.id, in: events))
        // The one-pass target list agrees with the rule, event by event.
        for moving in events {
            let expected = Set(events.map(\.id).filter {
                EventHierarchy.reparentProblem(moving: moving.id, to: $0, in: events) == nil
            })
            XCTAssertEqual(EventHierarchy.reparentTargets(for: moving.id, in: events), expected, moving.name)
        }
        XCTAssertEqual(EventHierarchy.subtreeHeight(of: trip.id, in: events), 2)
        XCTAssertEqual(EventHierarchy.subtreeHeight(of: beach.id, in: events), 1)
        XCTAssertEqual(EventHierarchy.subtreeHeight(of: hour.id, in: events), 0)
    }
}
