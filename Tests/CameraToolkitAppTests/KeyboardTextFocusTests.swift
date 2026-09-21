import AppKit
@testable import CameraToolkitApp
import XCTest

@MainActor
final class KeyboardTextFocusTests: XCTestCase {
    func testTextEditingResponderClassification() {
        XCTAssertTrue(KeyboardTextFocus.isTextEditingResponder(NSTextView()))
        XCTAssertTrue(KeyboardTextFocus.isTextEditingResponder(NSTextField()))
        XCTAssertTrue(KeyboardTextFocus.isTextEditingResponder(NSSearchField()))
        XCTAssertTrue(KeyboardTextFocus.isTextEditingResponder(NSSecureTextField()))
        XCTAssertFalse(KeyboardTextFocus.isTextEditingResponder(NSButton()))
        XCTAssertFalse(KeyboardTextFocus.isTextEditingResponder(NSView()))
        XCTAssertFalse(KeyboardTextFocus.isTextEditingResponder(nil))
    }

    /// The field editor, not the field itself, is first responder while an
    /// `NSTextField` is being edited — the check has to catch that.
    func testFocusedTextFieldMakesWindowResponderAFieldEditor() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let field = NSTextField(string: "Beach day")
        field.frame = NSRect(x: 0, y: 40, width: 320, height: 24)
        container.addSubview(field)
        let button = NSButton(title: "OK", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 80, height: 30)
        container.addSubview(button)
        window.contentView = container

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(
            window.firstResponder is NSTextView,
            "expected the field editor (NSTextView) as first responder, got \(String(describing: window.firstResponder))"
        )
        XCTAssertTrue(KeyboardTextFocus.isTextEditingResponder(window.firstResponder))
        XCTAssertTrue(KeyboardTextFocus.isTypingInTextField(windows: [window]))

        XCTAssertTrue(window.makeFirstResponder(button))
        XCTAssertFalse(KeyboardTextFocus.isTypingInTextField(windows: [window]))

        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(KeyboardTextFocus.isTypingInTextField(windows: [window]))
    }

    /// The regression: typing Delete in a field must not reach the trash,
    /// unsort, move, or selection commands. Programmatic `.reload` (posted
    /// after a finished job, never a keyboard shortcut) stays live.
    func testBoardCommandsAreBlockedWhileTypingButReloadStillRuns() {
        for command in BrowserCommand.allCases where command != .reload {
            XCTAssertFalse(command.isAllowedWhileTyping, "\(command) must not run while typing")
        }
        XCTAssertTrue(BrowserCommand.reload.isAllowedWhileTyping)
    }

    func testTypingFalseWhenNoWindowHasTextFocus() {
        _ = NSApplication.shared
        XCTAssertFalse(KeyboardTextFocus.isTextEditingResponder(NSApp.keyWindow?.firstResponder))
        XCTAssertFalse(KeyboardTextFocus.isTypingInTextField())
    }
}
