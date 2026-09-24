import AppKit
import CameraToolkitCore
import SwiftUI
@testable import CameraToolkitApp
import XCTest

/// Renders the Apply sheet off-screen for a synthetic many-to-many plan
/// (one folder split across two events, a second folder feeding one, a
/// card copied into both) and writes PNGs. The plan is built in memory, so
/// nothing on disk is read or changed. Runs only when `CT_SNAPSHOT_OUT`
/// names an output folder.
@MainActor
final class ApplySheetRoutesSnapshotTests: XCTestCase {
    func testRenderApplySheetRoutes() throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else {
            throw XCTSkip("Snapshot harness runs only with CT_SNAPSHOT_OUT set.")
        }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let plan = Self.samplePlan()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            try render(
                AnyView(ApplyPlanSheet(plan: plan, onCancel: {}, onApply: {})),
                size: NSSize(width: 680, height: 600), appearance: appearance, to: folder.appendingPathComponent("routes-\(suffix).png")
            )
            // The whole flow, unclipped by the sheet's scroll view.
            try render(
                AnyView(ApplyPlanFlowView(overview: ApplyPlanOverview(plan: plan)).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(.background)),
                size: NSSize(width: 680, height: 560), appearance: appearance, to: folder.appendingPathComponent("routes-flow-\(suffix).png")
            )
        }
    }

    private func render(_ view: AnyView, size: NSSize, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        host.display()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.orderOut(nil)
    }

    private static func samplePlan() -> OrganizeApplyPlan {
        let unsorted = "/Volumes/Sample Drive/Unsorted"
        let eventX = "/Volumes/Sample Drive/Buffer/2026/2026-01-02 Sample Event With A Long Descriptive Folder Name"
        let eventY = "/Volumes/Sample Drive/Buffer/.private/2026-01-02 Private Subevent"
        func moves(_ count: Int, from source: String, into destination: String, prefix: String, ext: String, bytes: Int64) -> [DriveMove] {
            (1...count).map {
                DriveMove(
                    sourcePath: "\(source)/\(prefix)\($0).\(ext)",
                    destinationPath: "\(destination)/Camera/\(prefix)\($0).\(ext)",
                    byteCount: bytes
                )
            }
        }
        func group(_ name: String, _ moves: [DriveMove], _ copies: [OrganizeApplyPlan.CopyBatch], _ destination: String, isPrivate: Bool) -> OrganizeApplyPlan.EventGroup {
            OrganizeApplyPlan.EventGroup(
                event: SavedCameraEvent(name: name, eventDate: Date(timeIntervalSince1970: 1_767_312_000), storagePolicy: isPrivate ? .archiveOnly : .buffer),
                moves: moves,
                copies: copies,
                alreadyThere: 0,
                unavailable: 0,
                destinationFolder: destination,
                isPrivate: isPrivate,
                byteCount: moves.reduce(Int64(0)) { $0 + $1.byteCount }
                    + copies.reduce(Int64(0)) { $0 + $1.files.reduce(Int64(0)) { $0 + $1.size } }
            )
        }
        let folderA = unsorted + "/Folder A"
        let folderB = unsorted + "/Folder B"
        let card = OrganizeApplyPlan.CopyBatch(
            sourceRoot: "/Volumes/Sample Card/DCIM",
            destinationRoot: eventY + "/Camera",
            deviceID: "sample",
            files: [
                FileRecord(path: "DCIM/100/IMG1.JPG", size: 8_000_000, modifiedAt: Date()),
                FileRecord(path: "DCIM/100/IMG2.JPG", size: 8_000_000, modifiedAt: Date()),
            ]
        )
        let x = group(
            "Sample Event",
            moves(1, from: folderA, into: eventX, prefix: "CLIP", ext: "MP4", bytes: 2_080_000_000),
            [],
            eventX,
            isPrivate: false
        )
        let y = group(
            "Private Subevent",
            moves(3, from: folderA, into: eventY, prefix: "A", ext: "ARW", bytes: 180_000_000)
                + moves(1, from: folderA, into: eventY, prefix: "A", ext: "XMP", bytes: 4_000)
                + moves(30, from: folderB, into: eventY, prefix: "B", ext: "ARW", bytes: 40_000_000)
                + moves(3, from: folderB, into: eventY, prefix: "BV", ext: "MP4", bytes: 150_000_000)
                + moves(2, from: folderB, into: eventY, prefix: "B", ext: "XMP", bytes: 4_000),
            [card],
            eventY,
            isPrivate: true
        )
        return OrganizeApplyPlan(title: "Apply Sorting", groups: [x, y], pruneBoundaries: [])
    }
}
