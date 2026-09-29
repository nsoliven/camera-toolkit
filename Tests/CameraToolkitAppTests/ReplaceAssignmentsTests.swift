import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// `DashboardModel.replaceAssignments` is `updateConfiguration`'s
/// remove-then-append for a move or sort, without the whole-library copy
/// and comparisons. It must change exactly what the old closure changed.
@MainActor
final class ReplaceAssignmentsTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeModel() -> (DashboardModel, [SavedCameraEvent]) {
        let a = SavedCameraEvent(name: "A", eventDate: day)
        let b = SavedCameraEvent(name: "B", eventDate: day)
        let c = SavedCameraEvent(name: "C", eventDate: day)
        var configuration = AppConfiguration.defaults(applicationSupport: FileManager.default.temporaryDirectory.appendingPathComponent("ct-replace-\(UUID().uuidString)"))
        configuration.savedEvents = [a, b, c]
        configuration.photoEventAssignments = (0..<30).map { index in
            PhotoEventAssignment(
                sourceRootPath: "/cards/one",
                relativePath: "DSC\(index).ARW",
                fileSize: Int64(index + 1),
                modifiedAt: day.addingTimeInterval(Double(index)),
                eventID: [a, b, c][index % 3].id,
                deviceID: "sony-a7v"
            )
        }
        let model = DashboardModel(
            jobs: [],
            configuration: configuration,
            configurationStore: ConfigurationStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ct-replace-\(UUID().uuidString).json"))
        )
        return (model, [a, b, c])
    }

    private func viaUpdateConfiguration(
        _ model: DashboardModel,
        removing removed: [PhotoEventAssignment],
        adding added: [PhotoEventAssignment]
    ) -> [PhotoEventAssignment] {
        var expected = model.configuration.photoEventAssignments
        let removedIDs = Set(removed.map(CatalogStore.eventAssetID))
        expected.removeAll { removedIDs.contains(CatalogStore.eventAssetID($0)) }
        let existing = Set(expected.map(CatalogStore.eventAssetID))
        expected.append(contentsOf: added.filter { !existing.contains(CatalogStore.eventAssetID($0)) })
        return expected
    }

    func testAMoveSwapsRowsExactlyLikeTheOldClosure() {
        let (model, events) = makeModel()
        let moving = model.configuration.photoEventAssignments.filter { $0.eventID == events[0].id }.prefix(4)
        let moved = moving.map { assignment -> PhotoEventAssignment in
            var copy = assignment
            copy.eventID = events[1].id
            return copy
        }
        let expected = viaUpdateConfiguration(model, removing: Array(moving), adding: moved)
        let revisions = (model.configurationRevision, model.catalogStateRevision)

        let applied = model.replaceAssignments(removing: Array(moving), adding: moved, touching: events[1].id)

        XCTAssertEqual(model.configuration.photoEventAssignments, expected)
        XCTAssertEqual(applied.removed, Array(moving))
        XCTAssertEqual(applied.added, moved)
        XCTAssertEqual(model.configurationRevision, revisions.0 + 1)
        XCTAssertEqual(model.catalogStateRevision, revisions.1 + 1)
        XCTAssertGreaterThan(model.configuration.savedEvents[1].lastUsedAt, events[1].lastUsedAt.addingTimeInterval(-1))
    }

    func testRowsTheLibraryAlreadyHasAreNotAddedAgainAndMissingRowsAreNotCountedAsRemoved() {
        let (model, events) = makeModel()
        let existing = model.configuration.photoEventAssignments.first { $0.eventID == events[1].id }!
        var ghost = existing
        ghost.relativePath = "never-there.ARW"
        let expected = viaUpdateConfiguration(model, removing: [ghost], adding: [existing])

        let applied = model.replaceAssignments(removing: [ghost], adding: [existing])

        XCTAssertEqual(model.configuration.photoEventAssignments, expected)
        XCTAssertTrue(applied.removed.isEmpty, "nothing was there to remove")
        XCTAssertTrue(applied.added.isEmpty, "the row was already in the library")
    }

    func testNothingToChangeTouchesNoRevision() {
        let (model, _) = makeModel()
        let revisions = (model.configurationRevision, model.catalogStateRevision)
        let applied = model.replaceAssignments(removing: [], adding: [])
        XCTAssertTrue(applied.removed.isEmpty && applied.added.isEmpty)
        XCTAssertEqual(model.configurationRevision, revisions.0)
        XCTAssertEqual(model.catalogStateRevision, revisions.1)
    }

    func testAnUndoIsTheSameSwapBackwards() {
        let (model, events) = makeModel()
        let original = model.configuration.photoEventAssignments
        let moving = Array(original.filter { $0.eventID == events[2].id }.prefix(3))
        let moved = moving.map { assignment -> PhotoEventAssignment in
            var copy = assignment
            copy.eventID = events[0].id
            return copy
        }
        model.replaceAssignments(removing: moving, adding: moved)
        model.replaceAssignments(removing: moved, adding: moving)
        XCTAssertEqual(Set(model.configuration.photoEventAssignments), Set(original))
        XCTAssertEqual(model.configuration.photoEventAssignments.count, original.count)
    }
}
