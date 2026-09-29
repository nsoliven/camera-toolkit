import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// The workspace's assignment lookups (path key → assignment, counts, bytes)
/// are rebuilt from every assignment — ~750 ms on the main actor at 17,000 —
/// whenever `assignmentIndexRevision` moves. It must move for anything that
/// changes what those lookups hold, and only for that: an event's last-used
/// stamp or Immich setting used to invalidate them like everything else.
@MainActor
final class AssignmentIndexRevisionTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeModel() -> (DashboardModel, SavedCameraEvent, SavedCameraEvent) {
        let a = SavedCameraEvent(name: "A", eventDate: day)
        let b = SavedCameraEvent(name: "B", eventDate: day, parentEventID: a.id)
        var configuration = AppConfiguration.defaults(applicationSupport: FileManager.default.temporaryDirectory.appendingPathComponent("ct-index-\(UUID().uuidString)"))
        configuration.savedEvents = [a, b]
        var assignments: [PhotoEventAssignment] = []
        for index in 0..<6 {
            let owner: UUID = index % 2 == 0 ? a.id : b.id
            assignments.append(PhotoEventAssignment(
                sourceRootPath: "/cards/one",
                relativePath: "DSC\(index).ARW",
                fileSize: Int64(index + 1),
                modifiedAt: day.addingTimeInterval(Double(index)),
                eventID: owner,
                deviceID: "sony-a7v"
            ))
        }
        configuration.photoEventAssignments = assignments
        let model = DashboardModel(
            jobs: [],
            configuration: configuration,
            configurationStore: ConfigurationStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ct-index-\(UUID().uuidString).json"))
        )
        return (model, a, b)
    }

    private func revisions(_ model: DashboardModel) -> (catalog: Int, index: Int) {
        (model.catalogStateRevision, model.assignmentIndexRevision)
    }

    func testAnEventsLastUsedStampMovesTheCatalogRevisionButNotTheIndex() {
        let (model, _, _) = makeModel()
        let before = revisions(model)
        model.updateConfiguration { $0.savedEvents[0].lastUsedAt = Date().addingTimeInterval(500) }
        XCTAssertEqual(model.catalogStateRevision, before.catalog + 1)
        XCTAssertEqual(model.assignmentIndexRevision, before.index, "a stamp changes no path")
    }

    func testAnEventsImmichSettingsLeaveTheIndexAlone() {
        let (model, _, _) = makeModel()
        let before = revisions(model)
        model.updateConfiguration {
            $0.savedEvents[1].immichUploadEnabled = true
            $0.savedEvents[1].immichAlbumName = "Trip"
        }
        XCTAssertEqual(model.assignmentIndexRevision, before.index)
    }

    func testANewEventWithNoFilesLeavesTheIndexAlone() {
        let (model, _, _) = makeModel()
        let before = revisions(model)
        model.updateConfiguration { $0.savedEvents.append(SavedCameraEvent(name: "New", eventDate: day)) }
        XCTAssertEqual(model.catalogStateRevision, before.catalog + 1)
        XCTAssertEqual(model.assignmentIndexRevision, before.index)
    }

    func testANewEventThatOrphanedRowsAlreadyNameMovesTheIndex() {
        let (model, _, _) = makeModel()
        let orphan = SavedCameraEvent(name: "Back again", eventDate: day)
        model.updateConfiguration {
            $0.photoEventAssignments.append(PhotoEventAssignment(
                sourceRootPath: "/cards/one", relativePath: "ORPHAN.ARW", fileSize: 1, modifiedAt: day, eventID: orphan.id, deviceID: "sony-a7v"
            ))
        }
        let before = revisions(model)
        model.updateConfiguration { $0.savedEvents.append(orphan) }
        XCTAssertEqual(model.assignmentIndexRevision, before.index + 1, "its rows now have an owner, so they now have keys")
    }

    func testRenamingRedatingRepolicyingOrReparentingAnEventMovesTheIndex() {
        let (model, _, _) = makeModel()
        var before = revisions(model)
        model.updateConfiguration { $0.savedEvents[0].name = "A renamed" }
        XCTAssertEqual(model.assignmentIndexRevision, before.index + 1, "the folder is named after the event")
        before = revisions(model)
        model.updateConfiguration { $0.savedEvents[0].eventDate = day.addingTimeInterval(86_400 * 3) }
        XCTAssertEqual(model.assignmentIndexRevision, before.index + 1)
        before = revisions(model)
        model.updateConfiguration { $0.savedEvents[0].storagePolicy = .archiveOnly }
        XCTAssertEqual(model.assignmentIndexRevision, before.index + 1)
        before = revisions(model)
        model.updateConfiguration { $0.savedEvents[1].parentEventID = nil }
        XCTAssertEqual(model.assignmentIndexRevision, before.index + 1)
    }

    func testAssignmentChangesAndRemovedEventsMoveTheIndex() {
        let (model, a, _) = makeModel()
        var before = revisions(model)
        model.updateConfiguration {
            $0.photoEventAssignments.append(PhotoEventAssignment(
                sourceRootPath: "/cards/one", relativePath: "NEW.ARW", fileSize: 1, modifiedAt: day, eventID: a.id, deviceID: "sony-a7v"
            ))
        }
        XCTAssertEqual(model.assignmentIndexRevision, before.index + 1)
        before = revisions(model)
        let moved = model.configuration.photoEventAssignments[0]
        var copy = moved
        copy.eventID = model.configuration.savedEvents[1].id
        model.replaceAssignments(removing: [moved], adding: [copy])
        XCTAssertEqual(model.assignmentIndexRevision, before.index + 1)
        before = revisions(model)
        model.updateConfiguration { $0.savedEvents.removeAll { $0.id == a.id } }
        XCTAssertEqual(model.assignmentIndexRevision, before.index + 1, "rows of a removed event lose their owner")
    }

    func testAnEventReplacedByAnotherOfTheSameCountMovesTheIndex() {
        let (model, a, _) = makeModel()
        let before = revisions(model)
        model.updateConfiguration {
            $0.savedEvents.removeAll { $0.id == a.id }
            $0.savedEvents.append(SavedCameraEvent(name: "Swapped in", eventDate: day))
        }
        XCTAssertEqual(model.assignmentIndexRevision, before.index + 1, "the removed event's rows lost their owner")
    }

    func testAChangeThatChangesNothingMovesNothing() {
        let (model, _, _) = makeModel()
        let before = revisions(model)
        model.updateConfiguration { $0.savedEvents[0].name = $0.savedEvents[0].name }
        XCTAssertEqual(model.catalogStateRevision, before.catalog)
        XCTAssertEqual(model.assignmentIndexRevision, before.index)
    }

    /// The workspace rebuilds its lookups only when the index revision or the
    /// row count moves — so an event stamp must not rebuild them, and a
    /// rename must.
    func testTheWorkspaceKeepsItsLookupsAcrossAStampAndRebuildsThemAfterARename() throws {
        let (model, a, _) = makeModel()
        let workspace = EventsWorkspace(
            model: model,
            supportFolder: FileManager.default.temporaryDirectory.appendingPathComponent("ct-index-support-\(UUID().uuidString)"),
            driveActivityGate: DriveActivityGate()
        )
        XCTAssertEqual(workspace.assignmentCount(for: a.id), 6, "the first read builds them")
        XCTAssertEqual(workspace.assignmentIndexRebuildCount, 1)

        model.updateConfiguration { $0.savedEvents[0].lastUsedAt = Date().addingTimeInterval(900) }
        XCTAssertEqual(workspace.assignmentCount(for: a.id), 6)
        XCTAssertEqual(workspace.assignmentIndexRebuildCount, 1, "a stamp does not rebuild the lookups")

        model.updateConfiguration { $0.savedEvents.append(SavedCameraEvent(name: "New", eventDate: day)) }
        XCTAssertEqual(workspace.assignmentCount(for: a.id), 6)
        XCTAssertEqual(workspace.assignmentIndexRebuildCount, 1, "nor does an event with no files")

        model.updateConfiguration { $0.savedEvents[0].name = "Renamed" }
        XCTAssertEqual(workspace.assignmentCount(for: a.id), 6, "a rebuild still counts every row")
        XCTAssertEqual(workspace.assignmentIndexRebuildCount, 2, "a rename changes every path key, so it rebuilds")
    }
}
