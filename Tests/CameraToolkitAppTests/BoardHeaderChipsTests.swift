import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

/// The board header's camera chips are decoration: a view draws the answer
/// it already had while the new one is counted on the next turn, so a move's
/// landing never carries the recount — and the answer that arrives is the
/// one a synchronous count gives.
@MainActor
final class BoardHeaderChipsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ path: String, camera: OrganizeCamera?, offset: TimeInterval) -> OrganizeItem {
        OrganizeItem(
            primary: OrganizeFile(path: path, size: 1, modifiedAt: base),
            kind: .photo,
            captureDate: base.addingTimeInterval(offset),
            hasCameraDate: true,
            metadataCamera: camera
        )
    }

    private func makeWorkspace(root: URL) -> (DashboardModel, EventsWorkspace) {
        let configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Safety Test").path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: root.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: root.appendingPathComponent("Library").path,
            catalogDatabasePath: root.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path,
            selectedDeviceID: "sony-a7v"
        )
        let model = DashboardModel(
            jobs: [],
            configuration: configuration,
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )
        return (model, EventsWorkspace(model: model, supportFolder: root.appendingPathComponent("Support", isDirectory: true)))
    }

    func testCameraChipsKeepTheirAnswerUntilTheDeferredCountLands() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitChips-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, workspace) = makeWorkspace(root: root)
        let eventID = try XCTUnwrap(workspace.createEvent(name: "Chip Day", date: base, policy: .buffer))

        let phone = CameraCatalog.camera(make: "Apple", model: "iPhone 16 Pro")
        let sony = CameraCatalog.camera(make: "SONY", model: "ILCE-7M5")
        let first = [
            OrganizeStack(items: [item("/Loose/IMG_0001.HEIC", camera: phone, offset: 0)]),
            OrganizeStack(items: [item("/Loose/DSC00002.ARW", camera: sony, offset: 10)]),
        ]
        workspace.eventStacks[eventID] = first

        // The first answer for a board is counted at once.
        let initial = workspace.boardCamerasForDisplay(for: first, eventID: eventID)
        XCTAssertEqual(Set(initial.map(\.id)), ["model:iPhone 16 Pro", "sony-a7v"])
        XCTAssertEqual(initial, workspace.boardCameras(for: first))

        // The stacks change: the view still gets the old answer this turn …
        let second = first + [OrganizeStack(items: [item("/Loose/DSC00003.ARW", camera: sony, offset: 20)])]
        workspace.eventStacks[eventID] = second
        let revision = workspace.boardChipsRevision
        let stale = workspace.boardCamerasForDisplay(for: second, eventID: eventID)
        XCTAssertEqual(stale, initial, "the answer on screen is not recounted on the render path")

        // … and the recount arrives on its own turn, equal to a fresh count.
        workspace.refreshDeferredChips()
        XCTAssertGreaterThan(workspace.boardChipsRevision, revision, "views are told a new answer landed")
        let fresh = workspace.boardCamerasForDisplay(for: second, eventID: eventID)
        XCTAssertEqual(fresh, workspace.boardCameras(for: second))
        XCTAssertEqual(fresh.first { $0.id == "sony-a7v" }?.stackCount, 2)
    }
}
