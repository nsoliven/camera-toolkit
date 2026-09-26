import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

@MainActor
final class CameraFilterTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ path: String, camera: OrganizeCamera? = nil, kind: OrganizeMediaKind = .raw, offset: TimeInterval = 0) -> OrganizeItem {
        OrganizeItem(
            primary: OrganizeFile(path: path, size: 1, modifiedAt: base),
            kind: kind,
            captureDate: base.addingTimeInterval(offset),
            hasCameraDate: true,
            metadataCamera: camera
        )
    }

    private func search(_ rows: [OrganizeFilterRow]) -> OrganizeSearchFilter {
        var filter = OrganizeSearchFilter()
        filter.groups = [OrganizeFilterGroup(rows: rows)]
        return filter
    }

    // MARK: - Operators

    func testCameraRowOperatorsJudgeABurstOnTheUnionOfItsFrames() {
        let sonyOnly = OrganizeFilterSubject(cameraIDs: ["sony-a7v"])
        let mixedBurst = OrganizeFilterSubject(cameraIDs: ["sony-a7v", "dji-nano"])
        let unknown = OrganizeFilterSubject(cameraIDs: [OrganizeCamera.unknownID])

        let anyNano = OrganizeFilterRow.cameras(["dji-nano"])
        XCTAssertFalse(anyNano.matches(subject: sonyOnly))
        XCTAssertTrue(anyNano.matches(subject: mixedBurst))
        XCTAssertFalse(anyNano.matches(subject: unknown))

        let noNano = OrganizeFilterRow.cameras(["dji-nano"], exclude: true)
        XCTAssertEqual(noNano.operator, .noneOf)
        XCTAssertTrue(noNano.matches(subject: sonyOnly))
        XCTAssertFalse(noNano.matches(subject: mixedBurst))
        XCTAssertTrue(noNano.matches(subject: unknown))

        // Several picks: any of them keeps the subject.
        XCTAssertTrue(OrganizeFilterRow.cameras(["osmo-360", "sony-a7v"]).matches(subject: sonyOnly))
        // "Unknown camera" is a value like any other.
        XCTAssertTrue(OrganizeFilterRow.cameras([OrganizeCamera.unknownID]).matches(subject: unknown))

        // Only any/none are offered; an empty or paused row never filters.
        XCTAssertEqual(OrganizeFilterRow.Operator.options(for: .camera), [.anyOf, .noneOf])
        XCTAssertTrue(OrganizeFilterRow(property: .camera).matches(subject: sonyOnly))
        var paused = anyNano
        paused.isEnabled = false
        XCTAssertTrue(paused.matches(subject: sonyOnly))
        XCTAssertTrue(anyNano.hasValues)
        XCTAssertEqual(OrganizeFilterRow.Property.camera.title, "Camera")
    }

    func testCameraRowANDsWithTheOtherRowsThroughStackFacts() {
        let burst = OrganizeStack(items: [item("/Card/B0001_DSC00001.ARW"), item("/Card/B0001_DSC00002.ARW", offset: 1)])
        let facts = OrganizeStackFacts(cameraIDs: ["sony-a7v", OrganizeCamera.unknownID])
        func keeps(_ rows: [OrganizeFilterRow]) -> Bool {
            OrganizeSearch.matches(stack: burst, search: search(rows), rootPath: "/Card", facts: facts)
        }
        XCTAssertTrue(keeps([.cameras(["sony-a7v"])]))
        XCTAssertTrue(keeps([.cameras(["sony-a7v"]), .media([.raw])]))
        XCTAssertFalse(keeps([.cameras(["sony-a7v"]), .media([.video])]))
        XCTAssertFalse(keeps([.cameras(["osmo-360"]), .media([.raw])]))
        XCTAssertFalse(keeps([.cameras([OrganizeCamera.unknownID], exclude: true)]))
        XCTAssertTrue(search([.cameras(["sony-a7v"])]).needsCameras)
        XCTAssertFalse(search([.media([.raw])]).needsCameras)
    }

    // MARK: - Header chips

    func testCameraChipsAddExtendAndDropTheBoardsCameraRow() {
        var filter = OrganizeSearchFilter()
        filter.addCondition(.media([.raw]))
        XCTAssertFalse(filter.isCameraChipOn("sony-a7v"))

        filter.toggleCameraChip("sony-a7v")
        XCTAssertTrue(filter.isCameraChipOn("sony-a7v"))
        // The chip's row ANDs into the existing group.
        XCTAssertEqual(filter.groups.count, 1)
        XCTAssertEqual(filter.groups[0].rows.map(\.property), [.media, .camera])

        filter.toggleCameraChip("dji-nano")
        XCTAssertEqual(filter.groups[0].rows.last?.cameraIDs, ["sony-a7v", "dji-nano"])

        filter.toggleCameraChip("sony-a7v")
        filter.toggleCameraChip("dji-nano")
        XCTAssertEqual(filter.groups[0].rows.map(\.property), [.media])

        // On an empty filter the last chip off leaves no empty group.
        var fresh = OrganizeSearchFilter()
        fresh.toggleCameraChip("osmo-360")
        fresh.toggleCameraChip("osmo-360")
        XCTAssertTrue(fresh.groups.isEmpty)

        // A hand-built "none of" row is left alone by the chips.
        var manual = search([.cameras(["osmo-360"], exclude: true)])
        manual.toggleCameraChip("osmo-360")
        XCTAssertEqual(manual.groups[0].rows.count, 2)
        XCTAssertEqual(manual.groups[0].rows[0].operator, .noneOf)
        XCTAssertTrue(manual.isCameraChipOn("osmo-360"))
    }

    func testHeaderChipCountsCountStacksPerCameraWithUnknownLast() {
        let stacks = [
            OrganizeStack(items: [item("/a")]),
            OrganizeStack(items: [item("/b")]),
            OrganizeStack(items: [item("/c1"), item("/c2", offset: 1)]),
            OrganizeStack(items: [item("/d")]),
            OrganizeStack(items: [item("/e")]),
        ]
        let ids: [String: Set<String>] = [
            "/a": ["sony-a7v"],
            "/b": ["sony-a7v"],
            "/c1": ["sony-a7v", "dji-nano"],
            "/d": [OrganizeCamera.unknownID],
            "/e": ["model:iPhone 16 Pro"],
        ]
        let cameras = EventsWorkspace.boardCameras(stacks) { ids[$0.id] ?? [] } name: { CameraCatalog.camera(id: $0) }
        XCTAssertEqual(cameras.map(\.camera.name), ["Sony A7V", "iPhone 16 Pro", "Osmo Nano", "Unknown camera"])
        // A mixed burst counts once toward each camera in it.
        XCTAssertEqual(cameras.map(\.stackCount), [3, 1, 1, 1])
        XCTAssertTrue(EventsWorkspace.boardCameras([]) { _ in [] } name: { CameraCatalog.camera(id: $0) }.isEmpty)
    }

    // MARK: - Workspace resolution

    func testWorkspaceResolvesByPrecedenceFiltersAndSortsAnEventBoard() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitCameraFilter-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let workspace = EventsWorkspace(model: model, supportFolder: root.appendingPathComponent("Support", isDirectory: true))

        let card = root.appendingPathComponent("Card A", isDirectory: true)
        let loose = root.appendingPathComponent("Loose", isDirectory: true)
        model.updateConfiguration {
            $0.configuredLocations.append(ConfiguredLocation(role: .importSource, name: "Card A", path: card.path, deviceID: "osmo-360"))
            $0.configuredLocations.append(ConfiguredLocation(role: .importSource, name: "Loose", path: loose.path))
        }
        let eventID = try XCTUnwrap(workspace.createEvent(name: "Test Day", date: base, policy: .buffer))
        model.updateConfiguration {
            $0.photoEventAssignments.append(PhotoEventAssignment(
                sourceRootPath: card.path,
                relativePath: "DSC00002.ARW",
                fileSize: 1,
                modifiedAt: base,
                eventID: eventID,
                deviceID: "sony-a7v"
            ))
        }

        let phone = CameraCatalog.camera(make: "Apple", model: "iPhone 16 Pro")
        let sonyTags = CameraCatalog.camera(make: "SONY", model: "ILCE-7M5")
        // Location beats tags; the assignment beats the location; tags
        // decide only outside every configured camera source.
        let onCard = OrganizeStack(items: [item(card.appendingPathComponent("CAM_0001.JPG").path, camera: phone, kind: .photo, offset: 0)])
        let assigned = OrganizeStack(items: [item(card.appendingPathComponent("DSC00002.ARW").path, camera: phone, offset: 10)])
        let tagged = OrganizeStack(items: [item(loose.appendingPathComponent("IMG_0003.HEIC").path, camera: phone, kind: .photo, offset: 20)])
        let unread = OrganizeStack(items: [item(loose.appendingPathComponent("X_0004.ARW").path, offset: 30)])
        let burst = OrganizeStack(items: [
            item(loose.appendingPathComponent("B0001_DSC00005.ARW").path, camera: sonyTags, offset: 40),
            item(loose.appendingPathComponent("B0001_DSC00006.ARW").path, offset: 41),
        ])
        let stacks = [onCard, assigned, tagged, unread, burst]
        workspace.eventStacks[eventID] = stacks

        XCTAssertEqual(workspace.cameraIDs(for: onCard), ["osmo-360"])
        XCTAssertEqual(workspace.cameraIDs(for: assigned), ["sony-a7v"])
        XCTAssertEqual(workspace.cameraIDs(for: tagged), ["model:iPhone 16 Pro"])
        XCTAssertEqual(workspace.cameraIDs(for: unread), [OrganizeCamera.unknownID])
        XCTAssertEqual(workspace.cameraIDs(for: burst), ["sony-a7v", OrganizeCamera.unknownID])

        let counts = Dictionary(uniqueKeysWithValues: workspace.boardCameras(for: stacks).map { ($0.id, $0.stackCount) })
        XCTAssertEqual(counts, ["sony-a7v": 2, "osmo-360": 1, "model:iPhone 16 Pro": 1, OrganizeCamera.unknownID: 2])
        XCTAssertEqual(workspace.boardCameras(for: stacks).last?.id, OrganizeCamera.unknownID)

        func visible(_ rows: [OrganizeFilterRow]) -> [String] {
            workspace.visibleEventStacks(eventID, search: search(rows)).map(\.id)
        }
        XCTAssertEqual(visible([.cameras(["sony-a7v"])]), [assigned.id, burst.id])
        XCTAssertEqual(visible([.cameras(["sony-a7v"], exclude: true)]), [onCard.id, tagged.id, unread.id])
        XCTAssertEqual(visible([.cameras(["osmo-360", "model:iPhone 16 Pro"])]), [onCard.id, tagged.id])
        XCTAssertEqual(visible([.cameras(["sony-a7v"]), .media([.raw])]), [assigned.id, burst.id])

        // The Camera sort reads the same resolved camera, unknown last.
        let groups = workspace.eventBoardGroups(eventID, stacks: stacks, grouping: .ungrouped, sort: OrganizeStackSort(key: .camera))
        XCTAssertEqual(groups.first?.stacks.map(\.id), [tagged.id, onCard.id, assigned.id, burst.id, unread.id])

        // Changing the source's device re-resolves without a rescan.
        model.updateConfiguration { configuration in
            if let index = configuration.configuredLocations.firstIndex(where: { $0.name == "Card A" }) {
                configuration.configuredLocations[index].deviceID = "dji-nano"
            }
        }
        XCTAssertEqual(workspace.cameraIDs(for: onCard), ["dji-nano"])
        XCTAssertEqual(workspace.cameraIDs(for: assigned), ["sony-a7v"])
    }
}
