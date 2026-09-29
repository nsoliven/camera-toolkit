import AppKit
import CameraToolkitCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
@testable import CameraToolkitApp
import XCTest

/// The main window's SwiftUI content must fit the window it is hosted in.
/// When it needs more height than the window has, the hosting view lays it
/// out taller than the window and the overflow pushes the sidebar's rows
/// under the traffic lights and the board's top bar (the storage strip)
/// under the toolbar — tiles then start right below the toolbar.
///
/// The detail column's minimum height used to follow its content: the
/// split view measures the column at its minimum width (0), where the top
/// bar's chips wrap one per line and its notices one word per line, so an
/// event with a notice or a dozen chips out-measured the window. These run
/// the real window from `MainWindowFactory` off-screen against a temp
/// library (never live state) and check, at the minimum and typical sizes,
/// with the inspector and sidebar toggled, that:
/// - the content's fitting height and the window's minimum stay within
///   the window,
/// - every scroll view (sidebar, board, inspector) lies inside the window,
/// - the sidebar's first row starts below the title bar,
/// - the board's top bar starts below the title bar and leaves the tiles
///   most of the board.
///
/// With `CT_SNAPSHOT_OUT` set, each checked state is also written as a PNG
/// (`cacheDisplay`, so glass and edge effects are not drawn; the frame
/// checks are the proof). `CT_SNAPSHOT_PREFIX` prefixes the file names.
@MainActor
final class MainWindowLayoutTests: XCTestCase {
    private var root: URL!
    private var model: DashboardModel!
    private var workspace: EventsWorkspace!
    private var window: NSWindow?
    private var unsorted: ConfiguredLocation!
    private var eventID: UUID!
    private let eventDate = Date(timeIntervalSince1970: 1_787_000_000)

    /// The window sizes checked: the factory default, a typical laptop
    /// window, and the minimum.
    private static let sizes = [
        NSSize(width: 1320, height: 840),
        NSSize(width: 1247, height: 899),
        MainWindowFactory.minimumSize,
    ]

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitLayout-\(UUID().uuidString)", isDirectory: true)
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
        UserDefaults.standard.removeObject(forKey: EventInfoInspector.visibilityDefaultsKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: EventInfoInspector.visibilityDefaultsKey)
        model?.isSidebarCollapsed = false
        window?.orderOut(nil)
        window?.close()
        window = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// An event with a board notice and a row of subevent chips — the top
    /// bar a real event gets — at every size, inspector open and closed.
    func testEventBoardWithNoticeAndChipsFitsTheWindow() async throws {
        try await makeLibrary(subevents: 8)
        let window = try await openEventBoard()
        for size in Self.sizes {
            for inspector in [false, true] {
                UserDefaults.standard.set(inspector, forKey: EventInfoInspector.visibilityDefaultsKey)
                window.setContentSize(size)
                try await settle(window)
                try assertLayout(window, name: "event-notice-\(Int(size.width))x\(Int(size.height))\(inspector ? "-inspector" : "")", board: true)
            }
        }
    }

    /// Far more chips than fit: the top bar scrolls within its share of the
    /// board instead of growing, and nothing outside the board moves.
    func testEventBoardWithManyChipsScrollsItsTopBar() async throws {
        try await makeLibrary(subevents: 60)
        let window = try await openEventBoard()
        for size in [NSSize(width: 1320, height: 840), MainWindowFactory.minimumSize] {
            for inspector in [false, true] {
                UserDefaults.standard.set(inspector, forKey: EventInfoInspector.visibilityDefaultsKey)
                window.setContentSize(size)
                try await settle(window)
                let name = "event-many-chips-\(Int(size.width))x\(Int(size.height))\(inspector ? "-inspector" : "")"
                try assertLayout(window, name: name, board: true)
                let board = try XCTUnwrap(boardScrollView(in: window), name)
                let titlebar = titlebarBottom(window)
                let topBar = board.contentInsets.top - titlebar
                let limit = OrganizeChromeSizing.boardAccessoryHeightLimit(boardHeight: board.frame.height)
                // The strip, the capped chips, and the bar's padding.
                XCTAssertLessThanOrEqual(topBar, limit + 80, "\(name): top bar \(topBar) outgrew its limit \(limit)")
            }
        }
    }

    /// Hiding and showing the sidebar, with and without the inspector,
    /// keeps the content inside the window and the rows below the title bar.
    func testSidebarToggleKeepsContentInsideTheWindow() async throws {
        try await makeLibrary(subevents: 8)
        let window = try await openEventBoard()
        for inspector in [false, true] {
            UserDefaults.standard.set(inspector, forKey: EventInfoInspector.visibilityDefaultsKey)
            try await settle(window)
            model.isSidebarCollapsed = true
            try await settle(window)
            try assertLayout(window, name: "sidebar-collapsed\(inspector ? "-inspector" : "")", board: true, sidebar: false)
            model.isSidebarCollapsed = false
            try await settle(window)
            try assertLayout(window, name: "sidebar-expanded\(inspector ? "-inspector" : "")", board: true)
        }
    }

    /// The unsorted board and the welcome screen at the minimum size.
    func testOtherScreensFitTheMinimumWindow() async throws {
        try await makeLibrary(subevents: 8)
        let window = try await openEventBoard()
        window.setContentSize(MainWindowFactory.minimumSize)
        workspace.selection = .unsorted(unsorted.id)
        try await settle(window)
        try assertLayout(window, name: "unsorted-minimum", board: false)
        workspace.selection = nil
        try await settle(window)
        try assertLayout(window, name: "welcome-minimum", board: false)
    }

    /// The scrolling part of the top bar hugs short content and stops at
    /// its limit for tall content.
    func testBarScrollRegionHugsShortContentAndCapsTallContent() {
        func height(rows: Int, limit: CGFloat) -> CGFloat {
            let view = NSHostingView(rootView: BoardBarScrollRegion(maxHeight: limit) {
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { _ in Color.gray.frame(height: 20) }
                }
            }
            .frame(width: 400))
            return view.fittingSize.height
        }
        XCTAssertEqual(height(rows: 0, limit: 100), 0, accuracy: 0.5)
        XCTAssertEqual(height(rows: 3, limit: 100), 60, accuracy: 0.5)
        XCTAssertEqual(height(rows: 30, limit: 100), 100, accuracy: 0.5)
        XCTAssertEqual(height(rows: 3, limit: .infinity), 60, accuracy: 0.5)
    }

    func testTopBarLimitIsAShareOfTheBoard() {
        XCTAssertEqual(OrganizeChromeSizing.boardAccessoryHeightLimit(boardHeight: nil), .infinity)
        XCTAssertEqual(OrganizeChromeSizing.boardAccessoryHeightLimit(boardHeight: 0), .infinity)
        XCTAssertEqual(OrganizeChromeSizing.boardAccessoryHeightLimit(boardHeight: .nan), .infinity)
        XCTAssertEqual(OrganizeChromeSizing.boardAccessoryHeightLimit(boardHeight: 900), 300)
        XCTAssertEqual(OrganizeChromeSizing.boardAccessoryHeightLimit(boardHeight: 721), 240)
    }

    // MARK: - Checks

    private func assertLayout(_ window: NSWindow, name: String, board: Bool, sidebar: Bool = true) throws {
        let content = try XCTUnwrap(window.contentView, name)
        let height = content.bounds.height
        let titlebar = titlebarBottom(window)
        XCTAssertGreaterThan(titlebar, 20, "\(name): the window has no title bar/toolbar band")
        XCTAssertEqual(content.bounds.size, window.frame.size, "\(name): the full-size content view does not fill the window")

        // The SwiftUI content fits the window, and the window's minimum
        // is the factory's (below the toolbar), whatever the board shows.
        XCTAssertLessThanOrEqual(content.fittingSize.height, height + 0.5, "\(name): the content needs \(content.fittingSize) in a \(content.bounds.size) window")
        XCTAssertLessThanOrEqual(window.contentMinSize.height, MainWindowFactory.minimumSize.height + titlebar + 0.5, "\(name): the window's minimum \(window.contentMinSize) grew with the content")

        // Nothing is laid out above or below the window. Widths are not
        // checked here: after the inspector opens, the split view keeps
        // its width even when the window narrows — a separate, horizontal
        // issue this height fix does not change.
        for scroll in scrollViews(in: content) {
            let frame = scroll.convert(scroll.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(frame.minY, -0.5, "\(name): \(type(of: scroll)) \(frame) runs below the window")
            XCTAssertLessThanOrEqual(frame.maxY, height + 0.5, "\(name): \(type(of: scroll)) \(frame) runs above the window")
        }

        if sidebar {
            let table = try XCTUnwrap(sidebarTable(in: window), "\(name): sidebar table")
            XCTAssertGreaterThan(table.numberOfRows, 0, "\(name): the sidebar has no rows")
            // Window coordinates are y up; measure from the top.
            let top = height - table.convert(table.rect(ofRow: 0), to: nil).maxY
            XCTAssertGreaterThanOrEqual(top, titlebar - 0.5, "\(name): the sidebar's first row (top \(top)) is under the title bar (bottom \(titlebar))")
            XCTAssertLessThan(top, height, "\(name): the sidebar's first row is below the window")
        }

        if board {
            let scroll = try XCTUnwrap(boardScrollView(in: window), "\(name): board scroll view")
            let frame = scroll.convert(scroll.bounds, to: nil)
            // The board's scroll view runs under the toolbar; its top inset
            // is the toolbar plus the board's top bar (the storage strip and
            // what is under it), which must start below the title bar.
            XCTAssertEqual(height - frame.maxY, 0, accuracy: 0.5, "\(name): the board does not start at the window's top")
            XCTAssertGreaterThanOrEqual(scroll.contentInsets.top - titlebar, 24, "\(name): the board's top bar (inset \(scroll.contentInsets.top), title bar \(titlebar)) has no room for the storage strip")
            let tiles = frame.height - scroll.contentInsets.top - scroll.contentInsets.bottom
            XCTAssertGreaterThanOrEqual(tiles, frame.height / 4, "\(name): the bars leave the tiles only \(tiles) of \(frame.height)")
        }

        try writeSnapshot(window, name: name)
    }

    /// The title bar/toolbar band's height: everything above
    /// `contentLayoutRect` is window chrome.
    private func titlebarBottom(_ window: NSWindow) -> CGFloat {
        (window.contentView?.bounds.height ?? window.frame.height) - window.contentLayoutRect.maxY
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHidden, scroll.frame.height > 0 {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// The board's scroll view: the one that runs under the sidebar from
    /// the window's leading edge (the sidebar floats over the detail), and
    /// the largest such.
    private func boardScrollView(in window: NSWindow) -> NSScrollView? {
        guard let content = window.contentView else { return nil }
        return scrollViews(in: content)
            .filter { !($0.documentView is NSTableView) && !($0.documentView is NSOutlineView) }
            .filter { $0.convert($0.bounds, to: nil).minX <= 0.5 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The sidebar is the leftmost table in the window.
    private func sidebarTable(in window: NSWindow) -> NSTableView? {
        var tables: [NSTableView] = []
        func walk(_ view: NSView) {
            if let table = view as? NSTableView { tables.append(table) }
            view.subviews.forEach(walk)
        }
        (window.contentView?.superview ?? window.contentView).map(walk)
        return tables.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private func writeSnapshot(_ window: NSWindow, name: String) throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else { return }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let bounds = frameView.bounds
        let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: bounds))
        frameView.cacheDisplay(in: bounds, to: bitmap)
        let prefix = ProcessInfo.processInfo.environment["CT_SNAPSHOT_PREFIX"] ?? ""
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent("\(prefix)layout-\(name).png"))
    }

    // MARK: - Library

    /// Twelve photos on one event with `subevents` subevents (one chip
    /// each), and twenty other events so the sidebar scrolls.
    private func makeLibrary(subevents: Int) async throws {
        let folder = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
        for index in 0..<12 {
            try writeJPEG(folder.appendingPathComponent(String(format: "DSC%05d.JPG", index)), captured: String(format: "2026:08:26 10:%02d:00", index))
        }
        unsorted = ConfiguredLocation(role: .importSource, name: "Unsorted A7V", path: folder.path, deviceID: "sony-a7v")
        model.updateConfiguration { $0.configuredLocations.append(self.unsorted) }
        workspace.scan(unsorted)
        try await waitUntil { self.workspace.sources[self.unsorted.id]?.result != nil }
        let result = try XCTUnwrap(workspace.sources[unsorted.id]?.result)
        eventID = try XCTUnwrap(workspace.createEvent(name: "Birthday Weekend", date: eventDate, policy: .archiveOnly))
        for index in 0..<subevents {
            XCTAssertNotNil(workspace.createEvent(name: "Part \(index + 1)", date: eventDate, policy: nil, parentEventID: eventID))
        }
        for index in 0..<20 {
            _ = workspace.createEvent(name: "Other Event \(index + 1)", date: eventDate, policy: .buffer)
        }
        workspace.assign(stackIDs: Set(result.stacks.map(\.id)), from: unsorted.id, to: eventID)
    }

    private func openEventBoard() async throws -> NSWindow {
        let window = SnapshotWindows.main(model: model, workspace: workspace)
        self.window = window
        workspace.selection = .event(eventID)
        try await waitUntil { self.workspace.eventStacks[self.eventID] != nil && self.workspace.presence[self.eventID] != nil }
        return window
    }

    /// Lets the board settle, then puts its copies "in the shared Buffer"
    /// so the private event shows its misplaced-files notice — a
    /// multi-line notice in the top bar, as a real event gets one.
    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(600))
        if var summary = workspace.presence[eventID], !summary.assets.contains(where: { $0.otherDrive == .present }) {
            for index in summary.assets.indices {
                summary.assets[index].otherDrive = .present
                if summary.assets[index].drive == .unavailable { summary.assets[index].drive = .missing }
            }
            workspace.presence[eventID] = summary
        }
        try await Task.sleep(for: .milliseconds(600))
        window.contentView?.superview?.layoutSubtreeIfNeeded()
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

    private func writeJPEG(_ url: URL, captured: String) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
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
