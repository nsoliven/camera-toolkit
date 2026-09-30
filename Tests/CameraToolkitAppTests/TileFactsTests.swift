import CameraToolkitCore
import Foundation
import Observation
import XCTest
@testable import CameraToolkitApp

/// A tile asks the workspace a few things about its own files and stack —
/// whose file it is, whether it is selected — and must be told about those
/// answers changing for its files and stack, not about every change anyone
/// makes: one Move to Event used to redraw every tile the lazy stack had ever
/// built.
@MainActor
final class TileFactsTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    private struct Fixture {
        var model: DashboardModel
        var workspace: EventsWorkspace
        var first: SavedCameraEvent
        var second: SavedCameraEvent
        var files: [OrganizeFile]
    }

    private func makeFixture() -> Fixture {
        let first = SavedCameraEvent(name: "Trip 2026", eventDate: day)
        let second = SavedCameraEvent(name: "Beach Day", eventDate: day, parentEventID: first.id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ct-tilefacts-\(UUID().uuidString)")
        var configuration = AppConfiguration.defaults(applicationSupport: root)
        configuration.savedEvents = [first, second]
        var files: [OrganizeFile] = []
        var assignments: [PhotoEventAssignment] = []
        for index in 0..<6 {
            let modified = day.addingTimeInterval(Double(index))
            let assignment = PhotoEventAssignment(
                sourceRootPath: "/cards/one",
                relativePath: "DSC0000\(index).ARW",
                fileSize: Int64(index + 1),
                modifiedAt: modified,
                eventID: first.id,
                deviceID: "sony-a7v"
            )
            assignments.append(assignment)
            files.append(OrganizeFile(path: "/cards/one/\(assignment.relativePath)", size: assignment.fileSize, modifiedAt: modified))
        }
        configuration.photoEventAssignments = assignments
        let model = DashboardModel(
            jobs: [],
            configuration: configuration,
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )
        let workspace = EventsWorkspace(model: model, supportFolder: root.appendingPathComponent("Support", isDirectory: true))
        return Fixture(model: model, workspace: workspace, first: first, second: second, files: files)
    }

    private func moveAssignment(_ index: Int, in fixture: Fixture) {
        let old = fixture.model.configuration.photoEventAssignments[index]
        var moved = old
        moved.eventID = fixture.second.id
        fixture.workspace.applyAssignmentChange(
            AssignmentChange(title: "Move", removed: [old], added: [moved]),
            touching: fixture.second.id,
            patchBoards: false
        )
    }

    func testATileKnowsWhoseFileItIs() {
        let fixture = makeFixture()
        XCTAssertEqual(fixture.workspace.tileAssignment(for: fixture.files[0])?.eventID, fixture.first.id)
        XCTAssertNil(fixture.workspace.tileAssignment(for: OrganizeFile(path: "/cards/one/NOPE.ARW", size: 1, modifiedAt: day)))
        // The tile's answer is the one everyone else gets.
        XCTAssertEqual(fixture.workspace.tileAssignment(for: fixture.files[3]), fixture.workspace.assignment(for: fixture.files[3]))
    }

    func testAMovedFileIsHeardByItsOwnTileOnly() {
        let fixture = makeFixture()
        _ = fixture.workspace.tileAssignment(for: fixture.files[0])   // builds the lookup indexes
        let heardByTheMoved = ObservationFlag()
        let heardByAnother = ObservationFlag()
        _ = withObservationTracking { fixture.workspace.tileAssignment(for: fixture.files[0]) } onChange: { heardByTheMoved.set() }
        _ = withObservationTracking { fixture.workspace.tileAssignment(for: fixture.files[1]) } onChange: { heardByAnother.set() }

        moveAssignment(0, in: fixture)

        XCTAssertTrue(heardByTheMoved.fired, "the tile of the moved file must redraw")
        XCTAssertFalse(heardByAnother.fired, "no other tile is asked to")
        XCTAssertEqual(fixture.workspace.tileAssignment(for: fixture.files[0])?.eventID, fixture.second.id)
        XCTAssertEqual(fixture.workspace.tileAssignment(for: fixture.files[1])?.eventID, fixture.first.id)
    }

    func testARebuiltIndexIsHeardByEveryTile() {
        let fixture = makeFixture()
        _ = fixture.workspace.tileAssignment(for: fixture.files[0])
        let heard = ObservationFlag()
        _ = withObservationTracking { fixture.workspace.tileAssignment(for: fixture.files[1]) } onChange: { heard.set() }
        // A change the index cannot patch (its revision moved with no patch)
        // makes the next read rebuild every lookup — and tells every tile.
        fixture.model.updateConfiguration {
            $0.photoEventAssignments.append(PhotoEventAssignment(
                sourceRootPath: "/cards/one", relativePath: "NEW.ARW", fileSize: 9, modifiedAt: day, eventID: fixture.first.id, deviceID: "sony-a7v"
            ))
        }
        _ = fixture.workspace.tileAssignment(for: fixture.files[1])
        XCTAssertTrue(heard.fired)
    }

    func testSelectingAStackIsHeardByThatStacksTileOnly() {
        let fixture = makeFixture()
        let heardByA = ObservationFlag()
        let heardByB = ObservationFlag()
        _ = withObservationTracking { fixture.workspace.isStackSelected("a") } onChange: { heardByA.set() }
        _ = withObservationTracking { fixture.workspace.isStackSelected("b") } onChange: { heardByB.set() }
        fixture.workspace.selectStacks(["a"])
        XCTAssertTrue(heardByA.fired)
        XCTAssertFalse(heardByB.fired)
        XCTAssertTrue(fixture.workspace.isStackSelected("a"))
        XCTAssertFalse(fixture.workspace.isStackSelected("b"))
    }

    func testFocusFollowsTheSameRule() {
        let fixture = makeFixture()
        fixture.workspace.selectStacks(["a", "b"])
        XCTAssertTrue(fixture.workspace.isStackFocused("a"))
        let heardByA = ObservationFlag()
        let heardByC = ObservationFlag()
        _ = withObservationTracking { fixture.workspace.isStackFocused("a") } onChange: { heardByA.set() }
        _ = withObservationTracking { fixture.workspace.isStackFocused("c") } onChange: { heardByC.set() }
        fixture.workspace.focusedStackID = "b"
        XCTAssertTrue(heardByA.fired, "the stack that lost focus")
        XCTAssertFalse(heardByC.fired)
        XCTAssertTrue(fixture.workspace.isStackFocused("b"))
    }

    func testClearingTheSelectionIsHeardByTheStacksThatWereSelected() {
        let fixture = makeFixture()
        fixture.workspace.selectStacks(["a", "b"])
        let heard = ObservationFlag()
        _ = withObservationTracking { fixture.workspace.isStackSelected("b") } onChange: { heard.set() }
        fixture.workspace.selectedStackIDs.removeAll()
        XCTAssertTrue(heard.fired)
        XCTAssertFalse(fixture.workspace.isStackSelected("b"))
    }
}
