import AppKit
import CameraToolkitCore
import ImageIO
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
                AnyView(ApplyPlanSheet(plan: plan, onCancel: {}, onApply: { _ in })),
                size: NSSize(width: 680, height: 600), appearance: appearance, to: folder.appendingPathComponent("routes-\(suffix).png")
            )
            // The whole flow, unclipped by the sheet's scroll view.
            try render(
                AnyView(ApplyPlanFlowView(overview: ApplyPlanOverview(plan: plan)).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(.background)),
                size: NSSize(width: 680, height: 560), appearance: appearance, to: folder.appendingPathComponent("routes-flow-\(suffix).png")
            )
        }
    }

    /// The taken-name decision: one conflict (side-by-side comparison) and
    /// a mixed plan with several (compact list). Synthetic JPEGs with EXIF
    /// capture dates are written under the output folder, so thumbnails and
    /// the verdict come from the real loaders.
    func testRenderApplySheetConflicts() throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else {
            throw XCTSkip("Snapshot harness runs only with CT_SNAPSHOT_OUT set.")
        }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        let fixtures = folder.appendingPathComponent("conflict-fixtures", isDirectory: true)
        try? FileManager.default.removeItem(at: fixtures)
        let found = fixtures.appendingPathComponent("Sample Drive/Unsorted/Found Folder", isDirectory: true)
        let event = fixtures.appendingPathComponent("Sample Drive/Buffer/2026/2026-08-29 Sample Trip/Camera", isDirectory: true)

        func pair(_ name: String, mine: (String, Double), theirs: (String, Double), identical: Bool = false) throws -> ApplyCollision {
            let source = found.appendingPathComponent(name)
            let destination = event.appendingPathComponent(name)
            try Self.writeJPEG(source, date: mine.0, hue: mine.1)
            if identical {
                try FileManager.default.createDirectory(at: event, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: destination)
            } else {
                try Self.writeJPEG(destination, date: theirs.0, hue: theirs.1)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
            return ApplyCollision(
                kind: identical ? .identicalCopy : .nameConflict,
                move: DriveMove(sourcePath: source.path, destinationPath: destination.path, byteCount: size),
                assignment: nil,
                existingByteCount: size
            )
        }
        let single = try pair("DSC00001.JPG", mine: ("2026:08:19 14:05:00", 0.58), theirs: ("2026:08:29 09:12:00", 0.08))
        let second = try pair("DSC00002.JPG", mine: ("2026:08:19 14:07:00", 0.35), theirs: ("2026:08:29 09:20:00", 0.8))
        let third = try pair("DSC00003.JPG", mine: ("2026:08:20 11:00:00", 0.15), theirs: ("", 0), identical: true)

        func plan(_ moves: Int, _ conflicts: [ApplyCollision], _ duplicates: [ApplyCollision]) -> OrganizeApplyPlan {
            let moved = (0..<moves).map {
                DriveMove(sourcePath: found.appendingPathComponent("A\($0).ARW").path, destinationPath: event.appendingPathComponent("A\($0).ARW").path, byteCount: 40_000_000)
            }
            return OrganizeApplyPlan(
                title: "Apply sorting from Found Folder",
                groups: [OrganizeApplyPlan.EventGroup(
                    event: SavedCameraEvent(name: "Sample Trip", eventDate: Date(timeIntervalSince1970: 1_787_961_600), storagePolicy: .buffer),
                    moves: moved,
                    copies: [],
                    alreadyThere: 0,
                    unavailable: 0,
                    destinationFolder: event.deletingLastPathComponent().path,
                    isPrivate: false,
                    byteCount: moved.reduce(Int64(0)) { $0 + $1.byteCount },
                    duplicates: duplicates,
                    conflicts: conflicts
                )],
                pruneBoundaries: []
            )
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            try render(
                AnyView(ApplyPlanSheet(plan: plan(0, [single], []), onCancel: {}, onApply: { _ in }).background(Color(nsColor: .windowBackgroundColor))),
                size: NSSize(width: 680, height: 600), appearance: appearance, to: folder.appendingPathComponent("conflict-single-\(suffix).png"),
                settle: 2.5
            )
            try render(
                AnyView(ApplyPlanSheet(plan: plan(40, [single, second], [third]), onCancel: {}, onApply: { _ in }).background(Color(nsColor: .windowBackgroundColor))),
                size: NSSize(width: 680, height: 600), appearance: appearance, to: folder.appendingPathComponent("conflict-many-\(suffix).png"),
                settle: 2.5
            )
        }
    }

    /// A synthetic 600×400 photo: a gradient in `hue` with a few shapes, and
    /// an EXIF capture date when `date` is not empty.
    private static func writeJPEG(_ url: URL, date: String, hue: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let width = 600, height = 400
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(hue: hue, saturation: 0.8, brightness: 0.45, alpha: 1).cgColor
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
        context.setFillColor(NSColor(white: 1, alpha: 0.85).cgColor)
        context.fillEllipse(in: CGRect(x: 420 - hue * 200, y: 250, width: 90, height: 90))
        context.setFillColor(NSColor(hue: hue + 0.3, saturation: 0.4, brightness: 0.3, alpha: 1).cgColor)
        context.move(to: CGPoint(x: 0, y: 0))
        context.addLine(to: CGPoint(x: 220 + hue * 200, y: 210))
        context.addLine(to: CGPoint(x: 600, y: 0))
        context.fillPath()
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        if !date.isEmpty {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func render(_ view: AnyView, size: NSSize, appearance: NSAppearance.Name, to url: URL, settle: TimeInterval = 0.5) throws {
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
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
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
