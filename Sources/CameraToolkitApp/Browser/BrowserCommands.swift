import AppKit
import SwiftUI

enum BrowserCommand: String, Sendable, CaseIterable {
    case moveSelectionToTrash
    case selectAll
    case openSelection
    case previewSelection
    case revealSelection
    case reload
    /// Focus the search field of whichever board supports it (the organize
    /// board today). Boards without a search field ignore it.
    case find

    /// Commands that may still run while a text field owns typing. Menu and
    /// monitor posts are gated before they reach a board; `.reload` is
    /// posted by the app itself after a job finishes and is never a
    /// keyboard shortcut.
    var isAllowedWhileTyping: Bool { self == .reload }

    static let notification = Notification.Name("CameraToolkit.BrowserCommand")

    @MainActor
    static func post(_ command: BrowserCommand) {
        NotificationCenter.default.post(name: notification, object: command.rawValue)
    }

    static let mainWindowIdentifier = "CameraToolkitMainWindow"

    /// Commands are a global notification, so a board must check that its
    /// window is the key one — otherwise ⌘⌫ with Trash or People in front
    /// would act on the main board's selection behind it.
    static func targetsMainWindow(keyWindowIdentifier: String?) -> Bool {
        keyWindowIdentifier == mainWindowIdentifier
    }

    @MainActor
    static func targetsMainWindow() -> Bool {
        targetsMainWindow(keyWindowIdentifier: NSApp.keyWindow?.identifier?.rawValue)
    }
}

struct KeyboardShortcutReference: Identifiable, Equatable, Sendable {
    var id: String { action }
    var action: String
    var keys: String
    var detail: String
}

struct KeyboardShortcutSection: Identifiable, Equatable, Sendable {
    var id: String { title }
    var title: String
    var symbol: String
    var shortcuts: [KeyboardShortcutReference]
}

enum CameraToolkitShortcutCatalog {
    static let sections: [KeyboardShortcutSection] = [
        KeyboardShortcutSection(
            title: "Organize",
            symbol: "rectangle.3.group",
            shortcuts: [
                .init(action: "Select all", keys: "⌘A", detail: "Selects every stack on the current board."),
                .init(action: "Search the board", keys: "⌘F", detail: "Focuses the board's search field; the popover filters by people, date, event, and media kind."),
                .init(action: "Sort into a recent event", keys: "1  2  3", detail: "Assigns selected stacks to one of the three most recently used events."),
                .init(action: "New event", keys: "N", detail: "Creates an event and assigns the selected stacks to it."),
                .init(action: "Rotate selected frames", keys: "[  ]", detail: "Rotates the selection 90° left or right; R and ⇧R also work."),
                .init(action: "Undo a sort", keys: "⌘Z", detail: "Reverts the last sort or move before it was applied."),
                .init(action: "Open in Photomator", keys: "⌘O", detail: "Opens the selected files in Photomator, or the default app when it is not installed. Osmo 360 clips open in DJI Studio when it is installed."),
                .init(action: "Reveal in Finder", keys: "⇧⌘R", detail: "Shows the selected files in Finder."),
                .init(action: "Move to Trash", keys: "⌘Delete", detail: "Confirms, then moves the selected files to macOS Trash. Camera originals and configured locations stay protected."),
                .init(action: "Refresh", keys: "⌘R", detail: "Reloads the configuration and re-checks connectivity."),
            ]
        ),
        KeyboardShortcutSection(
            title: "Preview",
            symbol: "photo",
            shortcuts: [
                .init(action: "Open preview", keys: "Space  /  ⌘Y", detail: "Opens the large preview for the focused stack."),
                .init(action: "Previous or next frame", keys: "←  →", detail: "Steps through a burst's frames; ⇧ extends the selected range."),
                .init(action: "Previous or next stack", keys: "↑  ↓", detail: "Moves the preview to the neighboring stack."),
                .init(action: "Zoom to fit or actual size", keys: "⌘0  ⌘1", detail: "Fits the whole photo, or shows one image pixel per display point."),
                .init(action: "Play or pause a video", keys: "Space", detail: "While a video preview is open, Space toggles playback instead of closing."),
                .init(action: "Close preview", keys: "Space  /  Esc", detail: "Returns to the board."),
            ]
        ),
        KeyboardShortcutSection(
            title: "Windows",
            symbol: "macwindow",
            shortcuts: [
                .init(action: "Show or hide the sidebar", keys: "⌃⌘S", detail: "Toggles the Organize sidebar; ⌘B also still works."),
                .init(action: "Show or hide the inspector", keys: "⌥⌘I", detail: "Toggles the event's storage and info inspector."),
                .init(action: "Bigger or smaller tiles", keys: "⌘+  ⌘−", detail: "Steps the tile size on the board."),
                .init(action: "Main window", keys: "⌘0", detail: "Brings the organizer forward."),
                .init(action: "Event Library", keys: "⌥⌘E", detail: "Shows event photos across their camera, buffer, library, and Immich locations."),
                .init(action: "People", keys: "⌥⌘P", detail: "Shows the people the face index found and their events."),
                .init(action: "Photo List SQL Inspector", keys: "⇧⌘I", detail: "Browses the SQLite photo list, schema, and read-only SQL queries."),
                .init(action: "Jobs", keys: "⌥⌘T", detail: "Shows transfers, face scans, and other background jobs with progress and any problem."),
                .init(action: "Settings", keys: "⌘,", detail: "Opens storage locations, cameras, and service settings."),
                .init(action: "Keyboard shortcuts", keys: "⇧⌘K", detail: "Opens this shortcut reference window."),
            ]
        ),
        KeyboardShortcutSection(
            title: "Safety",
            symbol: "lock.shield",
            shortcuts: [
                .init(action: "Move files to Trash", keys: "Always confirms", detail: "Camera Toolkit uses macOS Trash and refuses configured locations and drive roots."),
                .init(action: "Free Up Source / Take Off Drive", keys: "Separate buttons", detail: "Permanent cleanup only runs from the event storage strip after its own confirmation — never from a stray click or shortcut."),
            ]
        ),
    ]
}

@MainActor
final class KeyboardShortcutsWindowController: NSObject, NSWindowDelegate {
    static let shared = KeyboardShortcutsWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            CameraToolkitWindowFactory.present(window)
            return
        }

        let window = CameraToolkitWindowFactory.make(
            .keyboardShortcuts,
            identifier: "CameraToolkitKeyboardShortcutsWindow",
            title: "Keyboard Shortcuts",
            initialContentSize: NSSize(width: 720, height: 650),
            toolbarStyle: .unifiedCompact,
            rootView: KeyboardShortcutsReferenceView()
        )
        window.delegate = self
        self.window = window
        CameraToolkitWindowFactory.present(window)
    }
}

/// Narrows the shortcut reference to a search: a shortcut matches on its
/// action, keys, or explanation; a section matches as a whole on its title.
enum KeyboardShortcutFilter {
    static func sections(
        _ sections: [KeyboardShortcutSection],
        matching query: String
    ) -> [KeyboardShortcutSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            if section.title.localizedCaseInsensitiveContains(needle) { return section }
            let shortcuts = section.shortcuts.filter {
                $0.action.localizedCaseInsensitiveContains(needle)
                    || $0.keys.localizedCaseInsensitiveContains(needle)
                    || $0.detail.localizedCaseInsensitiveContains(needle)
            }
            guard !shortcuts.isEmpty else { return nil }
            var filtered = section
            filtered.shortcuts = shortcuts
            return filtered
        }
    }
}

private struct KeyboardShortcutsReferenceView: View {
    @State private var query = ""

    private var sections: [KeyboardShortcutSection] {
        KeyboardShortcutFilter.sections(CameraToolkitShortcutCatalog.sections, matching: query)
    }

    var body: some View {
        Form {
            ForEach(sections) { section in
                Section {
                    ForEach(section.shortcuts) { shortcut in
                        LabeledContent {
                            Text(shortcut.keys)
                                .monospaced()
                                .foregroundStyle(.primary)
                        } label: {
                            Text(shortcut.action)
                            Text(shortcut.detail)
                        }
                    }
                } header: {
                    Label(section.title, systemImage: section.symbol)
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .navigationTitle("Keyboard Shortcuts")
        .navigationSubtitle("Sort, move, and preview without leaving the board")
        .searchable(text: $query, placement: .toolbar, prompt: "Search shortcuts")
    }
}
