import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// Views read the events, the locations and the display orientations through
/// facets of the configuration that move only when what is drawn from them
/// does. A Move to Event stamps the target event's last-used time, rewrites
/// the assignments and used to redraw every view that had read any part of
/// the configuration; none of that changes an event's name, so none of it
/// may move `eventsRevision`.
@MainActor
final class ConfigurationFacetsTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeModel() -> DashboardModel {
        let a = SavedCameraEvent(name: "Trip 2026", eventDate: day)
        let b = SavedCameraEvent(name: "Beach Day", eventDate: day, parentEventID: a.id)
        var configuration = AppConfiguration.defaults(applicationSupport: FileManager.default.temporaryDirectory.appendingPathComponent("ct-facets-\(UUID().uuidString)"))
        configuration.savedEvents = [a, b]
        var assignments: [PhotoEventAssignment] = []
        for index in 0..<4 {
            let owner: UUID = index % 2 == 0 ? a.id : b.id
            let modified = day.addingTimeInterval(Double(index))
            assignments.append(PhotoEventAssignment(
                sourceRootPath: "/cards/one",
                relativePath: "DSC0000\(index).ARW",
                fileSize: Int64(index + 1),
                modifiedAt: modified,
                eventID: owner,
                deviceID: "sony-a7v"
            ))
        }
        configuration.photoEventAssignments = assignments
        return DashboardModel(
            jobs: [],
            configuration: configuration,
            configurationStore: ConfigurationStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ct-facets-\(UUID().uuidString).json"))
        )
    }

    func testAnEventsLastUsedStampMovesNoFacet() {
        let model = makeModel()
        let before = (model.eventsRevision, model.pathsRevision)
        let stamp = Date().addingTimeInterval(900)
        model.updateConfiguration { $0.savedEvents[1].lastUsedAt = stamp }
        XCTAssertEqual(model.eventsRevision, before.0)
        XCTAssertEqual(model.pathsRevision, before.1)
        XCTAssertEqual(model.eventsForDisplay[1].lastUsedAt, stamp, "the snapshot is still current")
    }

    func testARenameMovesTheEventsFacetAndThePaths() {
        let model = makeModel()
        let before = (model.eventsRevision, model.pathsRevision)
        model.updateConfiguration { $0.savedEvents[1].name = "Beach Morning" }
        XCTAssertEqual(model.eventsRevision, before.0 + 1)
        XCTAssertEqual(model.pathsRevision, before.1 + 1, "a folder is named after the event")
        XCTAssertEqual(model.eventsForDisplay[1].name, "Beach Morning")
    }

    func testAnImmichSettingMovesTheEventsFacetButNotThePaths() {
        let model = makeModel()
        let before = (model.eventsRevision, model.pathsRevision)
        model.updateConfiguration { $0.savedEvents[1].immichUploadEnabled = true }
        XCTAssertEqual(model.eventsRevision, before.0 + 1, "the strip draws the Immich setting")
        XCTAssertEqual(model.pathsRevision, before.1 + 1, "the events are part of what the path resolver holds")
    }

    func testAssignmentsAloneMoveNeitherTheEventsNorTheLocationsFacets() {
        let model = makeModel()
        let before = (model.eventsRevision, model.locationsRevision, model.pathsRevision, model.orientationsRevision)
        let old = model.configuration.photoEventAssignments[0]
        var moved = old
        moved.eventID = model.configuration.savedEvents[1].id
        model.replaceAssignments(removing: [old], adding: [moved], touching: moved.eventID)
        XCTAssertEqual(model.eventsRevision, before.0)
        XCTAssertEqual(model.locationsRevision, before.1)
        XCTAssertEqual(model.pathsRevision, before.2)
        XCTAssertEqual(model.orientationsRevision, before.3)
        XCTAssertEqual(model.assignmentCountSnapshot, 4)
    }

    func testTheAssignmentCountFollowsTheConfiguration() {
        let model = makeModel()
        XCTAssertEqual(model.assignmentCountSnapshot, 4)
        model.updateConfiguration { $0.photoEventAssignments.removeLast() }
        XCTAssertEqual(model.assignmentCountSnapshot, 3)
    }

    func testAnOrientationMovesItsFacetAlone() {
        let model = makeModel()
        let before = (model.eventsRevision, model.orientationsRevision)
        model.updateConfiguration { $0.displayOrientations["/x/DSC1.ARW"] = 1 }
        XCTAssertEqual(model.orientationsRevision, before.1 + 1)
        XCTAssertEqual(model.eventsRevision, before.0)
        XCTAssertEqual(model.orientationsForDisplay["/x/DSC1.ARW"], 1)
    }

    func testAConfiguredLocationMovesTheLocationsFacetAndThePaths() {
        let model = makeModel()
        let before = (model.locationsRevision, model.pathsRevision)
        model.updateConfiguration {
            $0.configuredLocations.append(ConfiguredLocation(role: .importSource, name: "Card", path: "/Volumes/Card"))
        }
        XCTAssertEqual(model.locationsRevision, before.0 + 1)
        XCTAssertEqual(model.pathsRevision, before.1 + 1)
        XCTAssertTrue(model.locationsForDisplay.contains { $0.name == "Card" })
    }

    func testTheStagingPathMovesThePathsAndNotTheEvents() {
        let model = makeModel()
        let before = (model.eventsRevision, model.pathsRevision)
        model.updateConfiguration { $0.privateStagingPath = "/Volumes/Staging" }
        XCTAssertGreaterThan(model.pathsRevision, before.1)
        XCTAssertEqual(model.eventsRevision, before.0)
    }

    func testTheNASAddressMovesItsFacetAlone() {
        let model = makeModel()
        let before = (model.nasSettingsRevision, model.eventsRevision)
        model.updateConfiguration { $0.nasSMBURL = "smb://nas.example/nas_share" }
        XCTAssertEqual(model.nasSettingsRevision, before.0 + 1)
        XCTAssertEqual(model.nasSMBURLForDisplay, "smb://nas.example/nas_share")
        XCTAssertEqual(model.eventsRevision, before.1)
        model.updateConfiguration { $0.savedEvents[0].lastUsedAt = Date().addingTimeInterval(5) }
        XCTAssertEqual(model.nasSettingsRevision, before.0 + 1, "an unrelated change leaves it")
    }

    // MARK: What a view that read a facet is told

    func testAViewThatReadTheEventsIsNotToldOfALastUsedStamp() {
        let model = makeModel()
        XCTAssertFalse(observationFires(reading: { model.eventsForDisplay }) {
            model.updateConfiguration { $0.savedEvents[0].lastUsedAt = Date().addingTimeInterval(60) }
        })
    }

    func testAViewThatReadTheEventsIsToldOfARename() {
        let model = makeModel()
        XCTAssertTrue(observationFires(reading: { model.eventsForDisplay }) {
            model.updateConfiguration { $0.savedEvents[0].name = "Trip 2027" }
        })
    }

    func testAViewThatReadTheEventsIsNotToldOfAnAssignmentMove() {
        let model = makeModel()
        XCTAssertFalse(observationFires(reading: { model.eventsForDisplay }) {
            let old = model.configuration.photoEventAssignments[0]
            var moved = old
            moved.eventID = model.configuration.savedEvents[1].id
            model.replaceAssignments(removing: [old], adding: [moved], touching: moved.eventID)
        })
    }
}
