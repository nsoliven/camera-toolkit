import CameraToolkitCore
import Foundation
import XCTest

final class EventHierarchyTests: XCTestCase {
    private func event(_ name: String, _ date: String, policy: EventStoragePolicy? = nil, parent: SavedCameraEvent? = nil) -> SavedCameraEvent {
        SavedCameraEvent(
            name: name,
            eventDate: DateFormatter.yyyyMMdd.date(from: date)!,
            storagePolicy: policy,
            parentEventID: parent?.id
        )
    }

    func testOlderConfigurationsDecodeWithoutParentEventID() throws {
        let json = #"{"bufferPath":"/tmp/Buffer","savedEvents":[{"id":"8987780B-3749-43BC-8801-D7DF3B7FFAD7","name":"Trip","eventDate":0,"createdAt":0,"lastUsedAt":0}]}"#
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        XCTAssertNil(configuration.savedEvents.first?.parentEventID)

        var updated = configuration
        let parent = event("Parent", "2026-08-21")
        updated.savedEvents.append(parent)
        updated.savedEvents[0].parentEventID = parent.id
        let roundTrip = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(roundTrip.savedEvents.first?.parentEventID, parent.id)
    }

    func testAncestorsChainAndDisplayName() throws {
        let parent = event("TRIP2026", "2026-08-21")
        let child = event("Matcha", "2026-08-23", parent: parent)
        let grandchild = event("Latte Art", "2026-08-24", parent: child)
        let events = [grandchild, child, parent]

        XCTAssertEqual(EventHierarchy.ancestors(of: grandchild, in: events).map(\.name), ["TRIP2026", "Matcha"])
        XCTAssertEqual(EventHierarchy.chain(of: grandchild, in: events).map(\.name), ["TRIP2026", "Matcha", "Latte Art"])
        XCTAssertEqual(EventHierarchy.displayName(of: child, in: events), "TRIP2026 / Matcha")
        XCTAssertEqual(EventHierarchy.displayName(of: parent, in: events), "TRIP2026")
        XCTAssertEqual(EventHierarchy.descendants(of: parent.id, in: events).map(\.name).sorted(), ["Latte Art", "Matcha"])
        XCTAssertTrue(EventHierarchy.descendants(of: grandchild.id, in: events).isEmpty)
    }

    func testMissingParentAndCyclesResolveAsTopLevel() throws {
        var orphan = event("Orphan", "2026-08-23")
        orphan.parentEventID = UUID()
        var a = event("A", "2026-08-21")
        var b = event("B", "2026-08-22")
        a.parentEventID = b.id
        b.parentEventID = a.id
        let events = [a, b, orphan]

        XCTAssertTrue(EventHierarchy.ancestors(of: orphan, in: events).isEmpty)
        XCTAssertEqual(EventHierarchy.resolvedPolicy(of: orphan, in: events), .buffer)
        XCTAssertEqual(EventHierarchy.ancestors(of: a, in: events).map(\.name), ["B"])
        XCTAssertEqual(EventHierarchy.resolvedPolicy(of: a, in: events), .buffer)
        // Every event still appears exactly once in the flattened list.
        let rows = EventHierarchy.flattened(events)
        XCTAssertEqual(rows.map(\.event.id).sorted { $0.uuidString < $1.uuidString },
                       events.map(\.id).sorted { $0.uuidString < $1.uuidString })
        XCTAssertTrue(rows.contains { $0.depth == 0 })
    }

    func testStoragePolicyInheritsRecursively() throws {
        let parent = event("Parent", "2026-08-21", policy: .archiveOnly)
        let child = event("Child", "2026-08-22", parent: parent)
        let grandchild = event("Grandchild", "2026-08-23", parent: child)
        let explicit = event("Explicit", "2026-08-24", policy: .buffer, parent: child)
        let events = [parent, child, grandchild, explicit]

        XCTAssertEqual(EventHierarchy.resolvedPolicy(of: parent, in: events), .archiveOnly)
        XCTAssertEqual(EventHierarchy.resolvedPolicy(of: child, in: events), .archiveOnly)
        XCTAssertEqual(EventHierarchy.resolvedPolicy(of: grandchild, in: events), .archiveOnly)
        XCTAssertEqual(EventHierarchy.resolvedPolicy(of: explicit, in: events), .buffer)
    }

    func testFlattenedIndentsSubeventsUnderParents() throws {
        let older = event("Older", "2026-08-01")
        let parent = event("TRIP2026", "2026-08-21")
        let childB = event("Matcha", "2026-08-23", parent: parent)
        let childA = event("Awards", "2026-08-22", parent: parent)
        let newer = event("Newer", "2026-08-30")
        let rows = EventHierarchy.flattened([childB, parent, older, newer, childA])

        // Roots and children alike sort newest-first, then by name.
        XCTAssertEqual(rows.map(\.event.name), ["Newer", "TRIP2026", "Matcha", "Awards", "Older"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 1, 0])
    }

    func testSubeventPathsNestInsideParentUnderRootYear() throws {
        try withTemporaryDirectory { root in
            var configuration = testConfiguration(root: root)
            let parent = event("TRIP2026", "2026-08-21", policy: .buffer)
            let child = event("Matcha", "2026-08-23", parent: parent)
            let grandchild = event("Latte Art", "2026-08-24", parent: child)
            configuration.savedEvents = [parent, child, grandchild]
            let locations = EventStorageLocations(configuration: configuration)
            let assignment = PhotoEventAssignment(
                sourceRootPath: "/Volumes/Card",
                relativePath: "DSC00001.ARW",
                fileSize: 1,
                modifiedAt: Date(),
                eventID: child.id,
                deviceID: "sony-a7v"
            )

            XCTAssertEqual(
                locations.driveURL(for: assignment, event: child, policy: .buffer)?.path,
                root.appendingPathComponent("Buffer/2026/2026-08-21 TRIP2026/2026-08-23 Matcha/Originals/Sony A7V/DSC00001.ARW").standardizedFileURL.path
            )
            XCTAssertEqual(
                locations.driveURL(for: assignment, event: child, policy: .archiveOnly)?.path,
                root.appendingPathComponent(".Camera Toolkit/Private/2026/2026-08-21 TRIP2026/2026-08-23 Matcha/Originals/Sony A7V/DSC00001.ARW").standardizedFileURL.path
            )
            XCTAssertEqual(
                locations.archiveURL(for: assignment, event: grandchild)?.path,
                root.appendingPathComponent("Library/2026/2026-08-21 TRIP2026/2026-08-23 Matcha/2026-08-24 Latte Art/Originals/Sony A7V/DSC00001.ARW").standardizedFileURL.path
            )
            XCTAssertEqual(
                locations.legacyArchiveURL(for: assignment, event: grandchild)?.path,
                root.appendingPathComponent("Library/Originals/2026/2026-08-21 TRIP2026/2026-08-23 Matcha/2026-08-24 Latte Art/Sony A7V/RAW/DSC00001.ARW").standardizedFileURL.path
            )
        }
    }

    func testDepthCapStopsAtTwoLevels() throws {
        let parent = event("TRIP2026", "2026-08-21")
        let child = event("Matcha", "2026-08-23", parent: parent)
        let grandchild = event("Latte Art", "2026-08-24", parent: child)
        let events = [parent, child, grandchild]

        XCTAssertEqual(EventHierarchy.depth(of: parent, in: events), 0)
        XCTAssertEqual(EventHierarchy.depth(of: child, in: events), 1)
        XCTAssertEqual(EventHierarchy.depth(of: grandchild, in: events), 2)
        XCTAssertTrue(EventHierarchy.canParent(parent, in: events))
        XCTAssertTrue(EventHierarchy.canParent(child, in: events))
        XCTAssertFalse(EventHierarchy.canParent(grandchild, in: events))
        XCTAssertEqual(EventHierarchy.children(of: parent.id, in: events).map(\.id), [child.id])
        XCTAssertEqual(EventHierarchy.children(of: child.id, in: events).map(\.id), [grandchild.id])
        XCTAssertTrue(EventHierarchy.children(of: grandchild.id, in: events).isEmpty)
    }

    func testDeeperExistingEventStillListsAndKeepsItsLink() throws {
        // Depth-3 data (adopted folders, pre-cap configs) keeps its chain —
        // the cap refuses new children under it but never rewrites or
        // hides the existing level.
        let a = event("A", "2026-08-21")
        let b = event("B", "2026-08-22", parent: a)
        let c = event("C", "2026-08-23", parent: b)
        let d = event("D", "2026-08-24", parent: c)
        let events = [a, b, c, d]

        XCTAssertEqual(EventHierarchy.depth(of: d, in: events), 3)
        XCTAssertFalse(EventHierarchy.canParent(d, in: events))
        XCTAssertEqual(EventHierarchy.displayName(of: d, in: events), "A / B / C / D")
        let rows = EventHierarchy.flattened(events)
        XCTAssertEqual(rows.map(\.event.id), [a.id, b.id, c.id, d.id])
        XCTAssertEqual(rows.last?.depth, 3)
    }

    func testSubeventYearComesFromRootAncestor() throws {
        try withTemporaryDirectory { root in
            var configuration = testConfiguration(root: root)
            let parent = event("New Year Trip", "2025-12-30", policy: .buffer)
            let child = event("Fireworks", "2026-01-01", parent: parent)
            configuration.savedEvents = [parent, child]
            let locations = EventStorageLocations(configuration: configuration)

            XCTAssertEqual(
                locations.eventFolder(for: child, policy: .buffer).path,
                root.appendingPathComponent("Buffer/2025/2025-12-30 New Year Trip/2026-01-01 Fireworks").standardizedFileURL.path
            )
        }
    }

    func testDiscoversAndAdoptsNestedSubeventFolders() throws {
        try withTemporaryDirectory { root in
            var configuration = testConfiguration(root: root)
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            let parentFolder = buffer.appendingPathComponent("2026/2026-08-21 TRIP2026")
            try writeFile(parentFolder.appendingPathComponent("Sony A7V/Card Copy/DSC00001.ARW"), "a")
            try writeFile(parentFolder.appendingPathComponent("2026-08-23 Matcha/Sony A7V/Card Copy/DSC00002.ARW"), "b")

            let found = try DriveEventDiscovery.discover(driveRoot: buffer, policy: .buffer, configuration: configuration)
            XCTAssertEqual(found.count, 2)
            let child = try XCTUnwrap(found.first { $0.name == "Matcha" })
            XCTAssertEqual(child.parentEventFolderPath, parentFolder.standardizedFileURL.path)
            XCTAssertEqual(child.files.count, 1)

            let adopted = DriveEventDiscovery.adopt(found, into: &configuration)
            XCTAssertEqual(adopted.createdEvents, 2)
            XCTAssertEqual(adopted.addedAssignments, 2)
            let trip = try XCTUnwrap(configuration.savedEvents.first { $0.name == "TRIP2026" })
            let matcha = try XCTUnwrap(configuration.savedEvents.first { $0.name == "Matcha" })
            XCTAssertEqual(matcha.parentEventID, trip.id)
            XCTAssertNil(trip.parentEventID)

            // Second pass: both folders are now covered by their assignments.
            XCTAssertTrue(try DriveEventDiscovery.discover(driveRoot: buffer, policy: .buffer, configuration: configuration).isEmpty)
        }
    }

    func testAdoptLinksSubeventToAlreadySavedParent() throws {
        try withTemporaryDirectory { root in
            var configuration = testConfiguration(root: root)
            let parent = event("TRIP2026", "2026-08-21", policy: .buffer)
            configuration.savedEvents = [parent]
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            try writeFile(buffer.appendingPathComponent("2026/2026-08-21 TRIP2026/2026-08-23 Matcha/Sony A7V/Card Copy/DSC00002.ARW"), "b")

            let found = try DriveEventDiscovery.discover(driveRoot: buffer, policy: .buffer, configuration: configuration)
            XCTAssertEqual(found.count, 1)
            let adopted = DriveEventDiscovery.adopt(found, into: &configuration)
            XCTAssertEqual(adopted.createdEvents, 1)
            let matcha = try XCTUnwrap(configuration.savedEvents.first { $0.name == "Matcha" })
            XCTAssertEqual(matcha.parentEventID, parent.id)
        }
    }
}
