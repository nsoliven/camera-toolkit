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
                .init(action: "Open in Photomator", keys: "⌘O", detail: "Opens the selected files in Photomator, or the default app when it is not installed."),
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
                .init(action: "Show or hide the sidebar", keys: "⌘B", detail: "Toggles the Organize sidebar."),
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
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Camera Toolkit Keyboard Shortcuts"
        window.identifier = NSUserInterfaceItemIdentifier("CameraToolkitKeyboardShortcutsWindow")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: KeyboardShortcutsReferenceView())
        CameraToolkitWindowSizing.configure(window, as: .keyboardShortcuts)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

private struct KeyboardShortcutsReferenceView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Keyboard Shortcuts")
                        .font(.largeTitle.bold())
                    Text("Sorting bursts into events, moving files between locations, and previewing without leaving the board.")
                        .foregroundStyle(.secondary)
                }

                ForEach(CameraToolkitShortcutCatalog.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(section.title, systemImage: section.symbol)
                            .font(.headline)
                        VStack(spacing: 0) {
                            ForEach(Array(section.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                                HStack(alignment: .firstTextBaseline, spacing: 14) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(shortcut.action)
                                            .fontWeight(.medium)
                                        Text(shortcut.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 16)
                                    Text(shortcut.keys)
                                        .font(.system(.body, design: .rounded).weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                                }
                                .padding(11)
                                if index + 1 < section.shortcuts.count {
                                    Divider().padding(.leading, 11)
                                }
                            }
                        }
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
