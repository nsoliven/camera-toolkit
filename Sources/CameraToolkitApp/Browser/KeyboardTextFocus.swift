import AppKit

/// While the owner is typing, board, overlay, and menu shortcuts must not
/// fire — Delete in a search field edits text, it does not trash or unsort
/// the board's selection. During editing the first responder is usually
/// the shared field editor (an `NSTextView`), so the check treats any text
/// view or text field as "typing." Commands the field handles itself
/// (⌘C, ⌘A, ⌘Z) are claimed by the field editor before menus run, so they
/// stay with the field.
enum KeyboardTextFocus {
    /// True when `responder` is a text editing view: an `NSTextView` —
    /// including the field editor that `NSTextField`, `NSSearchField`,
    /// token, and combo fields install as first responder — or a text
    /// field itself holding focus.
    static func isTextEditingResponder(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField
    }

    /// True while the key or main window's first responder is editing text —
    /// a SwiftUI `TextField`, a `.searchable` field, an alert's accessory
    /// field, `EventNameField`, a `PathAutocompleteField`, or any
    /// `NSTextView`/`TextEditor`.
    @MainActor
    static func isTypingInTextField() -> Bool {
        guard let app = NSApp else { return false }
        return isTypingInTextField(windows: [app.keyWindow, app.mainWindow])
    }

    /// The window scan behind `isTypingInTextField()`, split out so tests can
    /// drive it without a key window (test runners never activate the app).
    @MainActor
    static func isTypingInTextField(windows: [NSWindow?]) -> Bool {
        windows.contains { isTextEditingResponder($0?.firstResponder) }
    }
}
