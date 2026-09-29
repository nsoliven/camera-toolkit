import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import CameraToolkitApp

/// A tile's drag payload names every selected stack, so it is built when a
/// drag starts (`NSItemProvider` from `.onDrag`) instead of in each tile's
/// body (`.draggable(_:)` evaluates its argument on every render — once per
/// tile, ~1,200 times a pass on a family board). The sidebar rows still take
/// the drop with `.dropDestination(for: String.self)`, so what the provider
/// carries must load as that String.
@MainActor
final class TileDragPayloadTests: XCTestCase {
    private func load(_ provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: String.self) { continuation.resume(with: $0) }
        }
    }

    func testTheLazyProviderLoadsAsTheStringTheSidebarDropDestinationReads() async throws {
        let containerID = UUID()
        let payload = OrganizeDragPayload(origin: .event, containerID: containerID, stackIDs: ["a", "b", "c"]).encoded
        let received = try await load(NSItemProvider(object: payload as NSString))
        let decoded = try XCTUnwrap(OrganizeDragPayload.decode(received))
        XCTAssertEqual(decoded.origin, .event)
        XCTAssertEqual(decoded.containerID, containerID)
        XCTAssertEqual(Set(decoded.stackIDs), ["a", "b", "c"])
    }

    /// Drawing a board builds no payload: the count of payloads built stays
    /// at zero until a drag actually starts.
    func testRenderingABoardBuildsNoDragPayloads() async throws {
        let library = try MoveLibrary.make(.small)
        defer { library.tearDown() }
        let workspace = library.workspace
        let before = workspace.dragPayloadBuildCount
        for id in [library.parentID, library.sourceSubeventID] { await workspace.refreshEvent(id) }
        let window = SnapshotWindows.main(model: library.model, workspace: workspace)
        defer { window.orderOut(nil); window.close() }
        workspace.selection = .event(library.parentID)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertGreaterThan(BoardRenderCounter.count(.gridTile), 0, "the board drew tiles")
        XCTAssertEqual(workspace.dragPayloadBuildCount, before, "no tile encoded a payload while drawing")
        let stack = try XCTUnwrap(workspace.eventStacks[library.parentID]?.first)
        _ = workspace.dragPayload(for: stack.id, origin: .event, containerID: library.parentID)
        XCTAssertEqual(workspace.dragPayloadBuildCount, before + 1)
    }
}
