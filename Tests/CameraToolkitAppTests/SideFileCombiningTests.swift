import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// A side file shares its photo's tile, and every action still handles it as
/// the separate file it is. Everything runs in temp folders.
@MainActor
final class SideFileCombiningTests: XCTestCase {
    private let clipName = "CAM_0001_D.OSV"
    private let previewName = "CAM_0001_D.SCR"
    private let clipBytes = String(repeating: "clip-bytes-", count: 40)
    private let previewBytes = "screen-preview-bytes"

    private func library() throws -> AuditLibrary {
        let library = try AuditLibrary.make()
        library.addEvent("a", name: "Trip A")
        library.addEvent("b", name: "Trip B", date: AuditLibrary.day.addingTimeInterval(86_400))
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        return library
    }

    private func writeOnCard(_ library: AuditLibrary, _ name: String, _ content: String) throws -> URL {
        let url = library.card.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: library.card, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data(content.utf8), attributes: [.modificationDate: AuditLibrary.day]))
        return url
    }

    private func cardClipAndPreview(_ library: AuditLibrary) throws -> (clip: URL, preview: URL) {
        (try writeOnCard(library, clipName, clipBytes), try writeOnCard(library, previewName, previewBytes))
    }

    private func scanCard(_ library: AuditLibrary) async throws -> (location: ConfiguredLocation, result: OrganizeScanResult) {
        let location = ConfiguredLocation(role: .importSource, name: "Card", path: library.card.path, deviceID: "sony-a7v")
        library.model.updateConfiguration { $0.configuredLocations.append(location) }
        library.workspace.scan(location)
        try await library.waitUntil(timeout: 15, "scan never finished") { library.workspace.sources[location.id]?.result != nil }
        return (location, try XCTUnwrap(library.workspace.sources[location.id]?.result))
    }

    /// A catalog row made before this change, when the file was its own item.
    private func row(_ library: AuditLibrary, _ name: String, _ content: String, event: String) -> PhotoEventAssignment {
        PhotoEventAssignment(
            sourceRootPath: library.card.path,
            relativePath: name,
            fileSize: Int64(content.utf8.count),
            modifiedAt: AuditLibrary.day,
            eventID: library.id(event),
            deviceID: "sony-a7v"
        )
    }

    private func seed(_ library: AuditLibrary, _ rows: [PhotoEventAssignment]) {
        library.model.updateConfiguration { $0.photoEventAssignments.append(contentsOf: rows) }
    }

    private func copyToDrive(_ library: AuditLibrary, _ url: URL, event: String) throws -> URL {
        let copy = library.folder(event).appendingPathComponent(url.lastPathComponent)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    private func syncAndWait(_ library: AuditLibrary, _ event: String) async throws {
        library.workspace.syncToNAS(library.id(event))
        try await library.waitUntil(timeout: 20, "sync never finished") { !library.model.isBusy }
        XCTAssertEqual(library.model.jobs.first?.state, .done, library.model.jobs.first?.note ?? "")
    }

    // MARK: The board

    func testACombinedClipIsOneTileWithItsPrimarysPicture() async throws {
        let library = try library()
        defer { library.tearDown() }
        let files = try cardClipAndPreview(library)
        let (_, result) = try await scanCard(library)
        XCTAssertEqual(result.stacks.count, 1)
        let item = try XCTUnwrap(result.stacks.first?.items.first)
        XCTAssertEqual(item.primary.path, files.clip.path)
        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(item.companions.map(\.name), [previewName])
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertEqual(result.byteCount, Int64(clipBytes.utf8.count + previewBytes.utf8.count))
    }

    func testAnUnmatchedPreviewKeepsItsOwnTile() async throws {
        let library = try library()
        defer { library.tearDown() }
        _ = try writeOnCard(library, previewName, previewBytes)
        let (_, result) = try await scanCard(library)
        XCTAssertEqual(result.stacks.map(\.coverItem.primary.name), [previewName])
        XCTAssertEqual(result.stacks.first?.kind, .other)
    }

    // MARK: Existing catalog rows

    func testPreviewAndClipInDifferentEventsStayTwoTilesAndKeepTheirRows() async throws {
        let library = try library()
        defer { library.tearDown() }
        let files = try cardClipAndPreview(library)
        let rows = [row(library, clipName, clipBytes, event: "a"), row(library, previewName, previewBytes, event: "b")]
        seed(library, rows)

        let (_, result) = try await scanCard(library)
        XCTAssertEqual(result.stacks.count, 2)
        XCTAssertTrue(result.items.allSatisfy(\.companions.isEmpty))
        let preview = try XCTUnwrap(result.items.first { $0.primary.path == files.preview.path })
        XCTAssertEqual(library.workspace.assignment(for: preview.primary)?.eventID, library.id("b"))
        XCTAssertEqual(library.model.configuration.photoEventAssignments, rows, "nothing is rewritten")
    }

    func testAnUnsortedPreviewOfASortedClipStaysVisibleAndUnsorted() async throws {
        let library = try library()
        defer { library.tearDown() }
        _ = try cardClipAndPreview(library)
        seed(library, [row(library, clipName, clipBytes, event: "a")])

        let (_, result) = try await scanCard(library)
        XCTAssertEqual(result.stacks.count, 2)
        let shown = library.workspace.visibleStacks(result, hideSorted: true)
        XCTAssertEqual(shown.map(\.coverItem.primary.name), [previewName], "still there to sort")
    }

    func testRowsMadeWhenThePreviewWasItsOwnItemCombineOnTheEventBoard() async throws {
        let library = try library()
        defer { library.tearDown() }
        let clip = try library.place("a", name: clipName, content: clipBytes)
        let preview = try library.place("a", name: previewName, content: previewBytes)
        let before = library.assignments("a")

        await library.open("a")

        let stacks = try XCTUnwrap(library.workspace.eventStacks[library.id("a")])
        XCTAssertEqual(stacks.count, 1)
        XCTAssertEqual(stacks.first?.items.first?.primary.path, clip.url.path)
        XCTAssertEqual(stacks.first?.items.first?.companions.map(\.path), [preview.url.path])
        XCTAssertEqual(library.assignments("a"), before, "no row was touched")
        XCTAssertEqual(library.workspace.assignmentCount(for: library.id("a")), 2)
        XCTAssertEqual(library.workspace.assignmentBytes(for: library.id("a")), Int64(clipBytes.utf8.count + previewBytes.utf8.count))
    }

    func testABoardKeepsAFamilysDifferentlyOwnedPairApart() {
        let parent = UUID(), child = UUID()
        func row(_ name: String, _ event: UUID) -> PhotoEventAssignment {
            PhotoEventAssignment(sourceRootPath: "/Card", relativePath: name, fileSize: 4, modifiedAt: AuditLibrary.day, eventID: event, deviceID: nil)
        }
        let drawn = EventsWorkspace.drawnFiles(for: [row(clipName, parent), row(previewName, child)]) { "/Card/\($0.relativePath)" }
        XCTAssertEqual(OrganizeScanner.items(for: drawn.files, cache: nil, ownership: drawn.ownership).items.count, 2)
        let together = EventsWorkspace.drawnFiles(for: [row(clipName, parent), row(previewName, parent)]) { "/Card/\($0.relativePath)" }
        XCTAssertEqual(OrganizeScanner.items(for: together.files, cache: nil, ownership: together.ownership).items.count, 1)
    }

    func testUndoingASortPutsBackEveryRowOfACombinedTile() async throws {
        let library = try library()
        defer { library.tearDown() }
        _ = try cardClipAndPreview(library)
        let (location, result) = try await scanCard(library)
        library.workspace.assign(stackIDs: Set(result.stacks.map(\.id)), from: location.id, to: library.id("a"))
        XCTAssertEqual(library.assignments("a").count, 2)
        library.workspace.undoLastSort()
        XCTAssertTrue(library.assignments("a").isEmpty)
    }

    // MARK: Apply

    func testApplyMovesThePreviewWithItsClip() async throws {
        let library = try library()
        defer { library.tearDown() }
        let files = try cardClipAndPreview(library)
        let (location, result) = try await scanCard(library)
        library.workspace.assign(stackIDs: Set(result.stacks.map(\.id)), from: location.id, to: library.id("a"))
        XCTAssertEqual(library.assignments("a").map(\.relativePath).sorted(), [clipName, previewName])

        let plan = EventsWorkspace.buildApplyPlan(
            events: [library.event("a")],
            configuration: library.model.configuration,
            locations: library.locations,
            onlyUnder: library.card.path,
            title: "Apply",
            unsortedRoots: [library.card]
        )
        XCTAssertEqual(plan.moveCount, 2)
        library.workspace.performApply(plan)
        try await library.waitUntil(timeout: 15, "apply never finished") {
            !library.model.isBusy && library.workspace.latestMoveJournalTitle != nil
        }

        let folder = library.folder("a")
        XCTAssertEqual(library.data(folder.appendingPathComponent(previewName)), Data(previewBytes.utf8))
        XCTAssertEqual(library.data(folder.appendingPathComponent(clipName)), Data(clipBytes.utf8))
        XCTAssertFalse(library.exists(files.preview.path))
    }

    // MARK: Clear from Card

    func testClearFromCardWaitsForThePreviewsOwnNASVerification() async throws {
        let library = try library()
        defer { library.tearDown() }
        library.workspace.appliedSameVolumeCheck = { _, _, _ in false }
        let files = try cardClipAndPreview(library)
        let (location, result) = try await scanCard(library)
        library.workspace.assign(stackIDs: Set(result.stacks.map(\.id)), from: location.id, to: library.id("a"))

        // Only the clip reaches the drive before the first sync, so only it
        // has a verified NAS record.
        _ = try copyToDrive(library, files.clip, event: "a")
        try await syncAndWait(library, "a")
        _ = try copyToDrive(library, files.preview, event: "a")

        var plan = await library.workspace.cardClearPlan(for: location.id, result: result)
        XCTAssertTrue(plan.clearable.isEmpty, "the clip cannot leave ahead of its preview")
        XCTAssertEqual(plan.waitingFiles, 2)

        try await syncAndWait(library, "a")
        plan = await library.workspace.cardClearPlan(for: location.id, result: result)
        XCTAssertEqual(plan.clearableFiles, 2)
        let report = try CardClearService().clear(items: plan.clearable, nasReachable: true, confirmation: FreeUpService.confirmationToken)
        XCTAssertEqual(report.cleared.count, 2)
        XCTAssertFalse(library.exists(files.clip.path))
        XCTAssertFalse(library.exists(files.preview.path))
        XCTAssertTrue(library.exists(library.folder("a").appendingPathComponent(previewName).path))
    }

    func testAClipCannotClearWhileItsPreviewIsUnsortedEvenDrawnApart() async throws {
        let library = try library()
        defer { library.tearDown() }
        library.workspace.appliedSameVolumeCheck = { _, _, _ in false }
        let files = try cardClipAndPreview(library)
        seed(library, [row(library, clipName, clipBytes, event: "a")])
        let (location, result) = try await scanCard(library)
        XCTAssertEqual(result.stacks.count, 2)

        _ = try copyToDrive(library, files.clip, event: "a")
        try await syncAndWait(library, "a")

        let plan = await library.workspace.cardClearPlan(for: location.id, result: result)
        XCTAssertTrue(plan.clearable.isEmpty)
        XCTAssertEqual(plan.applied.count, 1, "the clip still counts as in its event")
    }

    func testClearUnitsRejoinWhatTheBoardDrewApart() {
        let clip = OrganizeFile(path: "/Card/\(clipName)", size: 1, modifiedAt: AuditLibrary.day)
        let preview = OrganizeFile(path: "/Card/\(previewName)", size: 1, modifiedAt: AuditLibrary.day)
        let apart = [
            OrganizeItem(primary: clip, kind: .video, captureDate: AuditLibrary.day, hasCameraDate: false),
            OrganizeItem(primary: preview, kind: .other, captureDate: AuditLibrary.day, hasCameraDate: false)
        ]
        XCTAssertEqual(EventsWorkspace.cardClearUnits(apart), [[clip, preview]])
    }

    // MARK: Move and Trash

    func testMoveToEventTakesThePreviewAlong() async throws {
        let library = try library()
        defer { library.tearDown() }
        let clip = try library.place("a", name: clipName, content: clipBytes)
        let preview = try library.place("a", name: previewName, content: previewBytes)
        await library.open("a", "b")
        let ids = Set((library.workspace.eventStacks[library.id("a")] ?? []).map(\.id))
        XCTAssertEqual(ids.count, 1)

        library.workspace.moveStacks(ids, fromEvent: library.id("a"), toEvent: library.id("b"))
        try await library.settle()

        XCTAssertFalse(library.exists(clip.url.path))
        XCTAssertFalse(library.exists(preview.url.path))
        let moved = library.folder("b").appendingPathComponent(previewName)
        XCTAssertEqual(library.data(moved), Data(previewBytes.utf8))
        XCTAssertEqual(library.assignments("b").map(\.relativePath).sorted(), [clipName, previewName])
        XCTAssertTrue(library.assignments("a").isEmpty)
    }

    func testTrashTakesThePreviewAlongAndRestoresIt() async throws {
        let library = try library()
        defer { library.tearDown() }
        let files = try cardClipAndPreview(library)
        let (location, result) = try await scanCard(library)
        library.workspace.assign(stackIDs: Set(result.stacks.map(\.id)), from: location.id, to: library.id("a"))

        library.workspace.trash(stackIDs: Set(result.stacks.map(\.id)), from: location.id)
        library.workspace.confirmTrash(try XCTUnwrap(library.workspace.pendingTrash))
        try await library.waitUntil(timeout: 15, "trash never finished") {
            !library.model.isBusy && library.workspace.sources[location.id]?.result?.items.isEmpty == true
        }

        XCTAssertFalse(library.exists(files.preview.path))
        XCTAssertTrue(library.assignments("a").isEmpty)
        let service = MediaTrashService(removedFilesRoot: library.locations.removedFilesRoot)
        let batch = try XCTUnwrap(service.listBatches(under: [library.locations.removedFilesRoot]).first)
        XCTAssertEqual(batch.entries.map { ($0.originalAbsolutePath as NSString).lastPathComponent }.sorted(), [clipName, previewName])
        let report = service.restore(batch: batch)
        XCTAssertEqual(report.restored.count, 2)
        XCTAssertEqual(library.data(files.preview), Data(previewBytes.utf8))
    }

    // MARK: The marker

    private func file(_ name: String, _ size: Int64) -> OrganizeFile {
        OrganizeFile(path: "/Card/\(name)", size: size, modifiedAt: AuditLibrary.day)
    }

    private func stack(_ primary: OrganizeFile, _ companions: [OrganizeFile]) -> OrganizeStack {
        OrganizeStack(items: [OrganizeItem(primary: primary, companions: companions, kind: .video, captureDate: AuditLibrary.day, hasCameraDate: false)])
    }

    func testNoCompanionMeansNoMarker() {
        XCTAssertNil(CombinedFilesMarker(stack: stack(file("A.OSV", 1), [])))
    }

    func testOneKindOfSideFileIsNamed() throws {
        let marker = try XCTUnwrap(CombinedFilesMarker(stack: stack(file("A.OSV", 1), [file("A.SCR", 43_000)])))
        XCTAssertEqual(marker.title, "+SCR")
        XCTAssertNil(marker.largeSize)
    }

    func testRAWAndJPEGPairsAreMarkedTheSameWay() throws {
        let marker = try XCTUnwrap(CombinedFilesMarker(stack: stack(file("A.ARW", 1), [file("A.JPG", 4_000_000)])))
        XCTAssertEqual(marker.title, "+JPG")
    }

    func testSeveralKindsAreCountedAndEveryFileIsListed() throws {
        let marker = try XCTUnwrap(CombinedFilesMarker(stack: stack(file("A.OSV", 1), [file("A.SCR", 10), file("A.THM", 20), file("A.XMP", 30)])))
        XCTAssertEqual(marker.title, "+3")
        for name in ["A.OSV", "A.SCR", "A.THM", "A.XMP"] { XCTAssertTrue(marker.helpText.contains(name), name) }
        XCTAssertTrue(marker.helpText.contains(Int64(20).formattedBytes))
        XCTAssertTrue(marker.accessibilityText.contains("3 side files"))
    }

    func testALargeCompanionsSizeIsOnTheMarker() throws {
        let threshold = CombinedFilesMarker.largeByteCount
        let large = try XCTUnwrap(CombinedFilesMarker(stack: stack(file("A.OSV", 1), [file("A.LRF", threshold), file("A.SCR", 10)])))
        XCTAssertEqual(large.largeSize, threshold.formattedBytes)
        let small = try XCTUnwrap(CombinedFilesMarker(stack: stack(file("A.OSV", 1), [file("A.MET", threshold - 1)])))
        XCTAssertNil(small.largeSize)
    }

    func testALongBurstSummarizesItsFileList() throws {
        let items = (0..<30).map { index in
            OrganizeItem(
                primary: file("B0001_DSC\(index).ARW", 1),
                companions: [file("B0001_DSC\(index).JPG", 1)],
                kind: .raw,
                captureDate: AuditLibrary.day,
                hasCameraDate: true
            )
        }
        let marker = try XCTUnwrap(CombinedFilesMarker(stack: OrganizeStack(items: items)))
        XCTAssertEqual(marker.title, "+JPG")
        XCTAssertTrue(marker.helpText.contains("and 48 more"))
    }
}
