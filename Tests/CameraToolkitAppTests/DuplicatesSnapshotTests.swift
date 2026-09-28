import AppKit
import CameraToolkitCore
import SwiftUI
@testable import CameraToolkitApp
import XCTest

/// Renders the Duplicates window off-screen from generated photos in a
/// temporary folder — a shared event and a private one holding the same
/// pictures, plus a reused file number — after a real scan, and writes
/// PNGs in light and dark. Runs only when `CT_SNAPSHOT_OUT` names an
/// output folder.
@MainActor
final class DuplicatesSnapshotTests: XCTestCase {
    func testRenderDuplicatesWindow() async throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else {
            throw XCTSkip("Snapshot harness runs only with CT_SNAPSHOT_OUT set.")
        }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitSnapshots-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = DashboardModel(
            jobs: [],
            configuration: AppConfiguration(
                demoRootPath: root.appendingPathComponent("Safety Test").path,
                importSourcePath: root.appendingPathComponent("Card").path,
                archivePath: root.appendingPathComponent("Library/Originals").path,
                bufferPath: root.appendingPathComponent("Drive/Camera Buffer").path,
                cameraLibraryRootPath: root.appendingPathComponent("Library").path,
                catalogDatabasePath: root.appendingPathComponent("catalog.sqlite").path,
                activityLogPath: root.appendingPathComponent("activity.jsonl").path,
                selectedDeviceID: "sony-a7v"
            ),
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )
        let workspace = EventsWorkspace(model: model, supportFolder: root.appendingPathComponent("Support", isDirectory: true))
        let day = Date(timeIntervalSince1970: 1_787_750_000)
        let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: day, policy: .buffer))
        let hotel = try XCTUnwrap(workspace.createEvent(name: "Hotel Night", date: day, policy: .archiveOnly))
        let colors: [NSColor] = [.systemTeal, .systemOrange, .systemPurple, .systemGreen, .systemPink]
        for (index, color) in colors.enumerated() {
            let name = String(format: "DSC0%04d.JPG", 6_001 + index)
            let data = try Self.jpeg(color)
            try place(data, name: name, in: beach, model: model, workspace: workspace, root: root)
            try place(data, name: name, in: hotel, model: model, workspace: workspace, root: root)
        }
        try place(try Self.jpeg(.systemBlue), name: "DSC06987.JPG", in: beach, model: model, workspace: workspace, root: root)
        try place(try Self.jpeg(.systemRed, width: 300), name: "DSC06987.JPG", in: hotel, model: model, workspace: workspace, root: root)

        let review = workspace.duplicateReview
        review.scan()
        let deadline = Date().addingTimeInterval(20)
        while review.isScanning || review.report == nil {
            guard Date() < deadline else { return XCTFail("scan did not finish") }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let first = review.summary(for: DuplicateOwnerPair(.event(beach), .event(hotel)))?.groups.first {
            review.checkedGroupIDs = [first.id]
        }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            review.selection = .identical(DuplicateOwnerPair(.event(beach), .event(hotel)))
            try await render(DuplicatesView(model: model, workspace: workspace, review: review), appearance: appearance,
                             to: folder.appendingPathComponent("duplicates-identical-\(suffix).png"))
            review.selection = .sameName(DuplicateOwnerPair(.event(beach), .event(hotel)))
            try await render(DuplicatesView(model: model, workspace: workspace, review: review), appearance: appearance,
                             to: folder.appendingPathComponent("duplicates-same-name-\(suffix).png"))
        }
        workspace.selection = .event(hotel)
        await workspace.refreshEvent(hotel)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            try await render(
                EventBoardView(model: model, workspace: workspace, eventID: hotel).frame(width: 1_080, height: 360, alignment: .top),
                appearance: appearance,
                to: folder.appendingPathComponent("duplicates-board-notice-\(suffix).png")
            )
        }
    }

    private func place(_ data: Data, name: String, in eventID: UUID, model: DashboardModel, workspace: EventsWorkspace, root: URL) throws {
        let event = try XCTUnwrap(workspace.event(eventID))
        let url = workspace.locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: workspace.resolvedPolicy(for: event))
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        model.updateConfiguration {
            $0.photoEventAssignments.append(PhotoEventAssignment(
                sourceRootPath: root.appendingPathComponent("Drive/Unsorted A7V").path,
                relativePath: name,
                fileSize: Int64(data.count),
                modifiedAt: Date(),
                eventID: eventID,
                deviceID: "sony-a7v"
            ))
        }
    }

    private static func jpeg(_ color: NSColor, width: Int = 320) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: 213), flipped: false) { rect in
            color.setFill()
            rect.fill()
            NSColor.white.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.25)).fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]))
    }

    private func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) async throws {
        let size = NSSize(width: 1_080, height: 640)
        let host = NSHostingView(rootView: view.background(.background))
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
        try await Task.sleep(for: .seconds(1.5))
        host.layoutSubtreeIfNeeded()
        host.display()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.orderOut(nil)
    }
}
