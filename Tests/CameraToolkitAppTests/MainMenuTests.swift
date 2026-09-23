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
            (#selector(NSWindow.toggleToolbarShown(_:)), "⌥⌘T"),
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
}
