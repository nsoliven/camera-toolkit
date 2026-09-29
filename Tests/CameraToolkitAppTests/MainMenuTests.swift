import AppKit
import CameraToolkitCore
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

    /// ⌘Z and ⇧⌘Z reach the one undo history; a text field keeps its own.
    func testUndoAndRedoAreTheAppsOwnAndNameTheirAction() {
        let undo = items.first { $0.action == #selector(MainMenuActions.undoOrText(_:)) }
        let redo = items.first { $0.action == #selector(MainMenuActions.redoOrText(_:)) }
        XCTAssertEqual(undo.flatMap(chord), "⌘Z")
        XCTAssertEqual(redo.flatMap(chord), "⇧⌘Z")
        XCTAssertEqual(undo?.title, "Undo")
        XCTAssertEqual(redo?.title, "Redo")
        XCTAssertNil(items.first { $0.action == Selector(("redo:")) }, "Redo is no longer a bare responder-chain item that only text fields answer")

        XCTAssertEqual(MainMenu.undoTitle(typing: false, next: "Undo Move to Lakeside (12 files)"), "Undo Move to Lakeside (12 files)")
        XCTAssertEqual(MainMenu.redoTitle(typing: false, next: "Redo Rename Beach Day"), "Redo Rename Beach Day")
        XCTAssertEqual(MainMenu.undoTitle(typing: false, next: nil), "Undo", "nothing to undo")
        XCTAssertEqual(MainMenu.redoTitle(typing: false, next: nil), "Redo")
        XCTAssertEqual(MainMenu.undoTitle(typing: true, next: "Undo Move to Lakeside (12 files)"), "Undo", "typing: the field's own Undo")
        XCTAssertEqual(MainMenu.redoTitle(typing: true, next: "Redo Rename Beach Day"), "Redo")
    }

    /// The titles come from the history: newest Undo, newest Redo, the file count.
    func testTheWorkspaceNamesTheNextUndoAndRedoForTheMenu() throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        let workspace = library.workspace
        XCTAssertNil(workspace.undoMenuTitle)
        workspace.recordUndo("Sort into Beach Day", detail: UndoEntry.fileCount(3), .files(UndoFilesAction()))
        workspace.recordUndo("Move to Lakeside", detail: UndoEntry.fileCount(12), .files(UndoFilesAction()))
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Move to Lakeside (12 files)")
        XCTAssertNil(workspace.redoMenuTitle)
        workspace.undoHistory.completeUndo(try XCTUnwrap(workspace.undoHistory.nextUndo))
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Sort into Beach Day (3 files)")
        XCTAssertEqual(workspace.redoMenuTitle, "Redo Move to Lakeside (12 files)")
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
