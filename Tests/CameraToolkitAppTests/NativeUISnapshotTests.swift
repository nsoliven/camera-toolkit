import AppKit
import CameraToolkitCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
@testable import CameraToolkitApp
import XCTest

/// Renders the real windows off-screen against generated sample media and
/// writes PNGs, so UI changes can be reviewed without launching the app
/// against the owner's live state. Runs only when `CT_SNAPSHOT_OUT` names
/// an output folder; run it under a write-denying `sandbox-exec` profile
/// with `CFFIXED_USER_HOME` pointing at a scratch home.
@MainActor
final class NativeUISnapshotTests: XCTestCase {
    private var outputFolder: URL!
    private var root: URL!
    private var model: DashboardModel!
    private var workspace: EventsWorkspace!
    private var unsorted: ConfiguredLocation!
    private var beachID: UUID!

    func testRenderWindows() async throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else {
            throw XCTSkip("Snapshot harness runs only with CT_SNAPSHOT_OUT set.")
        }
        outputFolder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        try await makeSampleLibrary()

        let window = SnapshotWindows.main(model: model, workspace: workspace)
        defer { window.orderOut(nil) }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            window.appearance = NSAppearance(named: appearance)

            workspace.selection = .event(beachID)
            try await waitUntil { self.workspace.eventStacks[self.beachID] != nil && self.workspace.presence[self.beachID] != nil }
            try await snapshot(window, size: NSSize(width: 1320, height: 840), name: "main-event-board-\(suffix)")
            try await snapshot(window, size: NSSize(width: 1040, height: 720), name: "main-event-board-narrow-\(suffix)")

            workspace.selection = .unsorted(unsorted.id)
            try await waitUntil { self.workspace.sources[self.unsorted.id]?.result != nil }
            try await snapshot(window, size: NSSize(width: 1320, height: 840), name: "main-unsorted-board-\(suffix)")
            try await snapshot(window, size: NSSize(width: 1040, height: 720), name: "main-unsorted-board-narrow-\(suffix)")

            workspace.selection = nil
            try await snapshot(window, size: NSSize(width: 1320, height: 840), name: "main-welcome-\(suffix)")

            for (name, title, open) in secondaryWindows {
                let secondary = try XCTUnwrap(SnapshotWindows.capture(title: title, open), "\(name) window")
                secondary.appearance = NSAppearance(named: appearance)
                try await settle(1.5)
                try render(secondary, name: "\(name)-\(suffix)")
                secondary.orderOut(nil)
            }
        }
    }

    /// (file name, window title, opener) — the title finds the window
    /// again on the second appearance pass, when the controller reuses it.
    private var secondaryWindows: [(String, String, () -> Void)] {
        [
            ("jobs", "Jobs", { TransferQueueWindowController.shared.show(model: self.model) }),
            ("trash", "Trash", { TrashWindowController.shared.show(model: self.model) }),
            ("settings", "Camera Toolkit Settings", { CameraToolkitConfigWindow.shared.show(model: self.model) }),
            ("people", "People", { PeopleWindowController.shared.show(model: self.model, workspace: self.workspace) }),
            ("event-library", "Event Library", { EventLibraryWindowController.shared.show(model: self.model) }),
        ]
    }

    // MARK: - Rendering

    private func snapshot(_ window: NSWindow, size: NSSize, name: String) async throws {
        window.setContentSize(size)
        try await settle(1.2)
        try render(window, name: name)
    }

    /// Draws the whole window — title bar and toolbar included — through
    /// the theme frame, then writes it as a PNG.
    private func render(_ window: NSWindow, name: String) throws {
        let frameView = try XCTUnwrap(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bounds = frameView.bounds
        let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: bounds))
        frameView.cacheDisplay(in: bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: outputFolder.appendingPathComponent("\(name).png"))
    }

    private func settle(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }

    private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the sample library")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Sample library

    private func makeSampleLibrary() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitSnapshots-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        model = DashboardModel(
            jobs: [],
            configuration: configuration,
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )
        workspace = EventsWorkspace(model: model, supportFolder: root.appendingPathComponent("Support", isDirectory: true))

        let folder = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.95, 0.62, 0.30), (0.25, 0.55, 0.85), (0.35, 0.72, 0.45), (0.80, 0.35, 0.50),
            (0.55, 0.45, 0.85), (0.90, 0.80, 0.35), (0.30, 0.70, 0.75), (0.65, 0.40, 0.30),
        ]
        var index = 1
        for (day, hour) in [("2026:08:26", 10), ("2026:08:26", 17), ("2026:08:27", 9), ("2026:08:28", 14)] {
            for shot in 0..<9 {
                let burst = shot < 4
                let seconds = burst ? shot : shot * 40
                let time = String(format: "%@ %02d:%02d:%02d", day, hour, seconds / 60, seconds % 60)
                let prefix = burst ? String(format: "B%04d_", index / 10 + 1) : ""
                try writeJPEG(
                    folder.appendingPathComponent(String(format: "Transfer 1/%@DSC%05d.JPG", prefix, index)),
                    captured: time,
                    color: palette[(index + shot) % palette.count],
                    portrait: shot % 5 == 3
                )
                index += 1
            }
        }
        unsorted = ConfiguredLocation(role: .importSource, name: "Unsorted A7V", path: folder.path, deviceID: "sony-a7v")
        model.updateConfiguration { $0.configuredLocations.append(self.unsorted) }

        workspace.scan(unsorted)
        try await waitUntil { self.workspace.sources[self.unsorted.id]?.result != nil }
        let result = try XCTUnwrap(workspace.sources[unsorted.id]?.result)

        beachID = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: day("2026-08-26"), policy: .buffer))
        let sunset = try XCTUnwrap(workspace.createEvent(name: "Sunset", date: day("2026-08-26"), policy: nil, parentEventID: beachID))
        let birthday = try XCTUnwrap(workspace.createEvent(name: "Birthday", date: day("2026-08-27"), policy: .buffer))
        _ = workspace.createEvent(name: "Client Shoot", date: day("2026-08-28"), policy: .archiveOnly)

        let stacks = result.stacks.sorted { $0.captureDate < $1.captureDate }
        let calendar = Calendar.current
        let first = stacks.filter { calendar.component(.day, from: $0.captureDate) == 26 }
        workspace.assign(stackIDs: Set(first.prefix(4).map(\.id)), from: unsorted.id, to: beachID)
        workspace.assign(stackIDs: Set(first.dropFirst(4).prefix(3).map(\.id)), from: unsorted.id, to: sunset)
        let second = stacks.filter { calendar.component(.day, from: $0.captureDate) == 27 }
        workspace.assign(stackIDs: Set(second.prefix(2).map(\.id)), from: unsorted.id, to: birthday)
    }

    private func day(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }

    /// A small gradient JPEG with an EXIF capture time, so the board has
    /// real thumbnails, days, and bursts to lay out.
    private func writeJPEG(_ url: URL, captured: String, color: (CGFloat, CGFloat, CGFloat), portrait: Bool) throws {
        let width = portrait ? 400 : 600
        let height = portrait ? 600 : 400
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let top = CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        let bottom = CGColor(red: color.0 * 0.35, green: color.1 * 0.35, blue: color.2 * 0.45, alpha: 1)
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
        context.fillEllipse(in: CGRect(x: width / 3, y: height / 3, width: width / 3, height: width / 3))
        let image = try XCTUnwrap(context.makeImage())

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: captured],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "ILCE-7M5"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

/// Windows for the harness, built invisibly: alpha 0 and no mouse events,
/// so nothing flashes on the owner's screen.
@MainActor
enum SnapshotWindows {
    static func main(model: DashboardModel, workspace: EventsWorkspace) -> NSWindow {
        let hostingController = NSHostingController(
            rootView: AppShell(model: model, workspace: workspace)
                .frame(minWidth: 1040, minHeight: 720)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Camera Toolkit"
        window.isRestorable = false
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        hide(window)
        window.orderFrontRegardless()
        return window
    }

    /// Opens a secondary window through its real controller and hides it
    /// before the run loop gets a chance to draw it on screen.
    static func capture(title: String, _ open: () -> Void) -> NSWindow? {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        open()
        let window = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) }
            ?? NSApp.windows.first { $0.title == title }
        window.map(hide)
        return window
    }

    private static func hide(_ window: NSWindow) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    }
}
