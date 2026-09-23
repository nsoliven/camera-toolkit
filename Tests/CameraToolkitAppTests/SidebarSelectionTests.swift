import AppKit
import CameraToolkitCore
@testable import CameraToolkitApp
import XCTest

/// Sidebar clicks must reach `workspace.selection` — the split view's
/// AppKit-backed List has dropped writes through `@Bindable` before. Runs
/// the real main window from `MainWindowFactory` off-screen against a temp
/// configuration, never live state.
@MainActor
final class SidebarSelectionTests: XCTestCase {
    private var root: URL!
    private var model: DashboardModel!
    private var workspace: EventsWorkspace!
    private var window: NSWindow?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitSidebar-\(UUID().uuidString)", isDirectory: true)
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
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.close()
        window = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Selecting a row the way AppKit does for a click or an arrow key
    /// writes `workspace.selection`, and a selection made in the model moves
    /// the sidebar highlight.
    ///
    /// Synthesized mouse clicks are not part of this test: the test runner
    /// is never the active app, and without window-server focus AppKit
    /// treats the click as a window-activation click and never lets the
    /// table track it (verified — the table's selection does not change).
    /// The click path shares the selection manager exercised here; the
    /// rows' tap gesture remains as a fallback on top of it.
    func testSidebarRowsWriteThroughToWorkspaceSelection() async throws {
        let folder = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unsorted = ConfiguredLocation(role: .importSource, name: "Unsorted A7V", path: folder.path, deviceID: "sony-a7v")
        model.updateConfiguration { $0.configuredLocations.append(unsorted) }
        let beach = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: Date(timeIntervalSince1970: 1_787_000_000), policy: .buffer))
        let birthday = try XCTUnwrap(workspace.createEvent(name: "Birthday", date: Date(timeIntervalSince1970: 1_787_100_000), policy: .buffer))
        let expected = Set(workspace.unsortedLocations.map { EventsSidebarSelection.unsorted($0.id) })
            .union(workspace.events.map { EventsSidebarSelection.event($0.id) })
        XCTAssertTrue(expected.isSuperset(of: [.unsorted(unsorted.id), .event(beach), .event(birthday)]))

        let window = SnapshotWindows.main(model: model, workspace: workspace)
        self.window = window
        try await spin(1.0)
        let table = try XCTUnwrap(Self.sidebarTable(in: window), "sidebar table view")

        // 1. Row selection → model, for every row. Header and button rows
        //    select nothing.
        var rowForSelection: [EventsSidebarSelection: Int] = [:]
        for row in 0..<table.numberOfRows {
            workspace.selection = nil
            try await spin(0.1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            try await spin(0.2)
            if let selection = workspace.selection, rowForSelection[selection] == nil {
                rowForSelection[selection] = row
            }
        }
        XCTAssertEqual(Set(rowForSelection.keys), expected, "every sidebar row selects its folder or event")

        // 2. Model → highlight: the guide and New Event select in the model.
        for target in [EventsSidebarSelection.event(beach), .unsorted(unsorted.id), .event(birthday)] {
            workspace.selection = target
            try await spin(0.3)
            XCTAssertEqual(table.selectedRow, rowForSelection[target], "the sidebar highlights \(target)")
        }
    }

    // MARK: - Helpers

    /// The List behind the sidebar — the first table view whose rows
    /// mention sidebar content, found by walking the window's views.
    private static func sidebarTable(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView?.superview else { return nil }
        var queue: [NSView] = [root]
        var tables: [NSTableView] = []
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let table = view as? NSTableView {
                tables.append(table)
            }
            queue.append(contentsOf: view.subviews)
        }
        // The sidebar is the leftmost table in the window.
        return tables.min { lhs, rhs in
            lhs.convert(lhs.bounds, to: nil).minX < rhs.convert(rhs.bounds, to: nil).minX
        }
    }

    private func spin(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }
}
