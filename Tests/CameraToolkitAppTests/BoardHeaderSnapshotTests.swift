import AppKit
import CameraToolkitCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
@testable import CameraToolkitApp
import XCTest

/// The top chrome of a scrolled board: the event board's storage strip and
/// the current day's header must stack as bars and never overlap, however
/// far the board scrolls. Renders the real main window off-screen against
/// generated sample media, scrolls the board's scroll view directly, reads
/// the strip's and the header's window frames from `BoardChromeProbe`, and
/// writes PNGs. Runs only when `CT_SNAPSHOT_OUT` names an output folder
/// (same `sandbox-exec` + `CFFIXED_USER_HOME` setup as the main harness).
@MainActor
final class BoardHeaderSnapshotTests: XCTestCase {
    private var outputFolder: URL!
    private var root: URL!
    private var model: DashboardModel!
    private var workspace: EventsWorkspace!
    private var unsorted: ConfiguredLocation!
    private var eventID: UUID!

    private static let dayTitles = ["Wednesday, August 26, 2026", "Thursday, August 27, 2026", "Friday, August 28, 2026"]

    func testScrolledBoardHeaderNeverOverlapsTheStrip() async throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else {
            throw XCTSkip("Snapshot harness runs only with CT_SNAPSHOT_OUT set.")
        }
        outputFolder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        // Default view settings: tiles, by day, oldest first.
        for key in ["CameraToolkit.organize.mode", "CameraToolkit.organize.tileWidth", "CameraToolkit.organize.showInspector",
                    "CameraToolkit.organize.hideSorted", "CameraToolkit.organize.grouping", "CameraToolkit.eventboard.grouping",
                    OrganizeBoardSortDefaults.unsortedKey, OrganizeBoardSortDefaults.unsortedAscending,
                    OrganizeBoardSortDefaults.eventKey, OrganizeBoardSortDefaults.eventAscending,
                    OrganizeBoardSortDefaults.legacyOrderKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        BoardChromeProbe.isEnabled = true
        defer { BoardChromeProbe.isEnabled = false; BoardChromeProbe.entries = [:] }
        try await makeSampleLibrary()

        let window = SnapshotWindows.main(model: model, workspace: workspace)
        defer { window.orderOut(nil) }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 1320, height: 840), NSSize(width: 1040, height: 720)] {
                let width = size.width < 1200 ? "-narrow" : ""
                window.setContentSize(size)
                workspace.selection = .event(eventID)
                try await waitUntil { self.workspace.eventStacks[self.eventID] != nil && self.workspace.presence[self.eventID] != nil }
                try await settle(1.2)
                try await checkScrolledBoard(window, name: "board-header-event\(width)-\(suffix)", hasStrip: true)

                workspace.selection = .unsorted(unsorted.id)
                try await waitUntil { self.workspace.sources[self.unsorted.id]?.result != nil }
                try await settle(1.2)
                try await checkScrolledBoard(window, name: "board-header-unsorted\(width)-\(suffix)", hasStrip: false)
            }
            // List mode keeps the same bar.
            UserDefaults.standard.set(OrganizeBoardMode.list.rawValue, forKey: "CameraToolkit.organize.mode")
            window.setContentSize(NSSize(width: 1320, height: 840))
            workspace.selection = .event(eventID)
            try await settle(1.2)
            try await checkScrolledBoard(window, name: "board-header-event-list-\(suffix)", hasStrip: true)
            UserDefaults.standard.removeObject(forKey: "CameraToolkit.organize.mode")
        }
    }

    /// Scrolls from the top, into the first day, to just past the second
    /// day's header, and deep into the last day, checking the chrome at
    /// each stop.
    private func checkScrolledBoard(_ window: NSWindow, name: String, hasStrip: Bool) async throws {
        let scrollView = try XCTUnwrap(boardScrollView(in: window), "board scroll view")
        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        XCTAssertGreaterThan(maxY, 600, "\(name): the sample board must be tall enough to scroll")

        var stops: [(String, CGFloat)] = [("top", 0), ("day1", min(420, maxY))]
        // Walk down until the bar switches to the second day, then take the
        // stop a little further so its in-content header has gone under.
        var y: CGFloat = 0
        var switched: CGFloat?
        while y < maxY {
            y = min(maxY, y + 60)
            try await scroll(scrollView, to: y)
            if stickyTitle() == Self.dayTitles[1] { switched = y; break }
        }
        let switchY = try XCTUnwrap(switched, "\(name): the bar never switched to the second day")
        stops.append(("day2", min(maxY, switchY + 40)))
        stops.append(("deep", maxY))

        var headerFrame: CGRect?
        for (stop, offset) in stops {
            try await scroll(scrollView, to: offset)
            try await settle(0.4)
            let header = try XCTUnwrap(frame(identifier: "boardStickyHeader"), "\(name)/\(stop): sticky header")
            let title = stickyTitle() ?? "none"
            if hasStrip {
                let strip = try XCTUnwrap(frame(identifier: "eventStorageStrip"), "\(name)/\(stop): storage strip")
                XCTAssertFalse(strip.intersects(header), "\(name)/\(stop): strip \(strip) overlaps header \(header)")
                // Window coordinates, y down: the header sits below the strip.
                XCTAssertGreaterThanOrEqual(header.minY, strip.maxY - 0.5, "\(name)/\(stop): header is not below the strip")
            }
            switch stop {
            case "top", "day1": XCTAssertEqual(title, Self.dayTitles[0], "\(name)/\(stop)")
            case "day2": XCTAssertEqual(title, Self.dayTitles[1], "\(name)/\(stop)")
            default: XCTAssertEqual(title, Self.dayTitles[2], "\(name)/\(stop)")
            }
            // The bar never moves with the content: same frame at every stop.
            if let first = headerFrame {
                XCTAssertEqual(header, first, "\(name)/\(stop): the header moved while scrolling")
            } else {
                headerFrame = header
            }
            try await render(window, name: "\(name)-\(stop)")
            print("BoardHeader \(name)/\(stop) y=\(offset) header=\(header) title=\(title)")
        }
        try await scroll(scrollView, to: 0)
    }

    // MARK: - Probes

    /// The board's scroll view: the tallest document in the window.
    private func boardScrollView(in window: NSWindow) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        window.contentView.map(walk)
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private func scroll(_ scrollView: NSScrollView, to y: CGFloat) async throws {
        let clip = scrollView.contentView
        let inset = scrollView.contentInsets.top
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y - inset))
        scrollView.reflectScrolledClipView(clip)
        try await settle(0.25)
    }

    private func frame(identifier: String) -> CGRect? {
        BoardChromeProbe.entries[identifier]?.frame
    }

    /// The title of the section whose header sits in the bar.
    private func stickyTitle() -> String? {
        BoardChromeProbe.entries["boardStickyHeader"]?.label
    }

    // MARK: - Rendering

    private func render(_ window: NSWindow, name: String) async throws {
        let frameView = try XCTUnwrap(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bounds = frameView.bounds
        let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: bounds))
        frameView.cacheDisplay(in: bounds, to: bitmap)
        let url = outputFolder.appendingPathComponent("\(name).png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func settle(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }

    private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the harness")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Sample library: three days, enough tiles to scroll

    private func makeSampleLibrary() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitBoardHeader-\(UUID().uuidString)", isDirectory: true)
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
        for day in ["2026:08:26", "2026:08:27", "2026:08:28"] {
            for shot in 0..<24 {
                // Minutes apart, so every shot is its own tile.
                let time = String(format: "%@ %02d:%02d:00", day, 9 + shot / 12, (shot % 12) * 5)
                try writeJPEG(
                    folder.appendingPathComponent(String(format: "Transfer 1/DSC%05d.JPG", index)),
                    captured: time,
                    color: palette[(index + shot) % palette.count]
                )
                index += 1
            }
        }
        unsorted = ConfiguredLocation(role: .importSource, name: "Unsorted A7V", path: folder.path, deviceID: "sony-a7v")
        model.updateConfiguration { $0.configuredLocations.append(self.unsorted) }

        workspace.scan(unsorted)
        try await waitUntil { self.workspace.sources[self.unsorted.id]?.result != nil }
        let result = try XCTUnwrap(workspace.sources[unsorted.id]?.result)
        XCTAssertGreaterThanOrEqual(result.stacks.count, 60, "sample shots should be separate tiles")

        eventID = try XCTUnwrap(workspace.createEvent(name: "Long Weekend", date: day("2026-08-26"), policy: .buffer))
        // Most of every day on the event; a few left unsorted per day so
        // the unsorted board also has three day sections.
        let calendar = Calendar.current
        var assigned: Set<String> = []
        for dayNumber in [26, 27, 28] {
            let stacks = result.stacks
                .filter { calendar.component(.day, from: $0.captureDate) == dayNumber }
                .sorted { $0.captureDate < $1.captureDate }
            assigned.formUnion(stacks.prefix(20).map(\.id))
        }
        workspace.assign(stackIDs: assigned, from: unsorted.id, to: eventID)
    }

    private func day(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }

    private func writeJPEG(_ url: URL, captured: String, color: (CGFloat, CGFloat, CGFloat)) throws {
        let width = 600
        let height = 400
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
