import AppKit
@testable import CameraToolkitApp
import XCTest

@MainActor
final class MainMenuTests: XCTestCase {
    private var items: [NSMenuItem] {
        MainMenu.make(target: nil).items.flatMap { $0.submenu?.items ?? [] }
    }

    private func chord(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let flags = item.keyEquivalentModifierMask
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + item.keyEquivalent.uppercased()
    }

    func testNoTwoItemsShareAShortcut() {
        let chords = items.compactMap(chord)
        let duplicates = Dictionary(grouping: chords, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertTrue(duplicates.isEmpty, "Shared shortcuts: \(duplicates.sorted())")
    }

    /// Text fields rely on nil-targeted Edit items for ⌘X/⌘C/⌘V, and every
    /// window on File ▸ Close for ⌘W.
    func testStandardItemsReachTheResponderChain() {
        let standard: [(Selector, String?)] = [
            (#selector(NSText.cut(_:)), "⌘X"),
            (#selector(NSText.copy(_:)), "⌘C"),
            (#selector(NSText.paste(_:)), "⌘V"),
            (Selector(("redo:")), "⇧⌘Z"),
            (#selector(NSWindow.performClose(_:)), "⌘W"),
            (#selector(NSApplication.hide(_:)), "⌘H"),
            (#selector(NSApplication.hideOtherApplications(_:)), "⌥⌘H"),
            (#selector(NSWindow.toggleToolbarShown(_:)), nil),
            (#selector(NSApplication.arrangeInFront(_:)), nil),
        ]
        for (action, expected) in standard {
            let item = items.first { $0.action == action }
            XCTAssertNotNil(item, "\(action) missing")
            XCTAssertNil(item?.target, "\(action) must be nil-targeted")
            if let expected { XCTAssertEqual(item.flatMap(chord), expected, "\(action)") }
        }
    }

    /// The Keyboard Shortcuts window promises these chords; the menu must
    /// actually bind them.
    func testShortcutCatalogWindowChordsExistInTheMenu() {
        let chords = Set(items.compactMap(chord))
        let windows = CameraToolkitShortcutCatalog.sections.first { $0.title == "Windows" }?.shortcuts ?? []
        XCTAssertFalse(windows.isEmpty)
        for shortcut in windows {
            for key in shortcut.keys.split(separator: " ") where key.hasPrefix("⌃") || key.hasPrefix("⌥") || key.hasPrefix("⇧") || key.hasPrefix("⌘") {
                let normalized = String(key).replacingOccurrences(of: "−", with: "-")
                XCTAssertTrue(chords.contains(normalized), "\(shortcut.action) promises \(key)")
            }
        }
    }

    func testTheLegacySidebarShortcutStaysHiddenButActive() {
        let legacy = items.first { chord($0) == "⌘B" }
        XCTAssertEqual(legacy?.isHidden, true)
        XCTAssertEqual(legacy?.allowsKeyEquivalentWhenHidden, true)
        XCTAssertEqual(legacy?.action, #selector(MainMenuActions.toggleSidebar(_:)))
    }

    func testTileZoomStepsStayInRange() {
        XCTAssertEqual(MainMenu.steppedTileWidth(220, by: 1), 264)
        XCTAssertEqual(MainMenu.steppedTileWidth(450, by: 1), 460)
        XCTAssertEqual(MainMenu.steppedTileWidth(100, by: -1), 88)
    }

    /// ⌥⌘T has opened Jobs since before the menu was rebuilt; ⌥⌘J is only
    /// a hidden alternate.
    func testJobsKeepsItsOriginalShortcut() {
        let jobs = items.filter { $0.action == #selector(MainMenuActions.openTransferQueue(_:)) }
        XCTAssertEqual(jobs.first { !$0.isHidden }.flatMap(chord), "⌥⌘T")
        XCTAssertEqual(jobs.first { $0.isHidden }.flatMap(chord), "⌥⌘J")
        XCTAssertNil(items.first { $0.action == #selector(NSWindow.toggleToolbarShown(_:)) }.flatMap(chord))
    }

    /// The View menu writes the same defaults the boards read through
    /// @AppStorage; a renamed key would make those items silently inert.
    func testViewMenuKeysMatchTheBoards() {
        XCTAssertEqual(MainMenu.DefaultsKey.showInspector, EventInfoInspector.visibilityDefaultsKey)
        let sources = ["Events/UnsortedBoardView.swift", "Events/EventBoardView.swift", "App/BoardChrome.swift"]
            .compactMap { try? String(contentsOf: Self.sourceRoot.appendingPathComponent($0), encoding: .utf8) }
            .joined()
        XCTAssertFalse(sources.isEmpty)
        for key in [MainMenu.DefaultsKey.boardMode, MainMenu.DefaultsKey.hideSorted, MainMenu.DefaultsKey.tileWidth] {
            XCTAssertTrue(sources.contains("\"\(key)\""), "\(key) is not read by any board")
        }
    }

    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/CameraToolkitApp")
}
