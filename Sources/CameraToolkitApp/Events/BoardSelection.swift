import AppKit
import Foundation

/// One board's selection, remembered by file identity rather than by stack
/// id. A stack id is the path of its first file, so it changes whenever the
/// board is rebuilt from another place (NAS listing, presence check,
/// rescan, regroup); the name|bytes|mtime key of the files does not. The
/// workspace resolves these keys back to the board's current stack ids.
struct BoardSelectionState: Equatable, Sendable {
    /// Identity keys of every file in a selected stack.
    var keys: Set<String> = []
    /// Identity key of the first file of the range-selection anchor.
    var anchorKey: String?
    /// Identity key of the first file of the focused stack.
    var focusKey: String?

    var isEmpty: Bool { keys.isEmpty && anchorKey == nil && focusKey == nil }
}

/// What a click on a tile or row does to the selection, Finder-style. A
/// double-click is a click followed by "open", so neither click may collapse
/// a multi-selection; a plain click inside one waits to see whether a second
/// click follows.
enum BoardClickPolicy {
    enum Decision: Equatable, Sendable {
        /// Leave the selection alone; only focus moves.
        case keepSelection
        /// Selection becomes just this stack.
        case replace
        /// Range from the anchor to this stack.
        case extend
        /// Add or remove this stack.
        case toggle
        /// Selection becomes just this stack unless a second click (or
        /// opening it) arrives within the double-click interval.
        case replaceAfterDoubleClickInterval
    }

    static var doubleClickInterval: TimeInterval { NSEvent.doubleClickInterval }

    static func decide(
        isSelected: Bool,
        selectionCount: Int,
        modifiers: NSEvent.ModifierFlags,
        clickCount: Int
    ) -> Decision {
        if clickCount >= 2 { return .keepSelection }
        if modifiers.contains(.command) { return .toggle }
        if modifiers.contains(.shift) { return .extend }
        if isSelected, selectionCount > 1 { return .replaceAfterDoubleClickInterval }
        return .replace
    }
}
