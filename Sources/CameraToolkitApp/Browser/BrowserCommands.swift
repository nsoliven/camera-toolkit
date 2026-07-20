import AppKit
import SwiftUI

enum BrowserCommand: String, Sendable {
    case copySelection
    case selectAll
    case openSelection
    case previewSelection
    case revealSelection
    case createFolder
    case goBack
    case goForward
    case goUp
    case previousSource
    case nextSource
    case increaseThumbnailSize
    case decreaseThumbnailSize
    case reload

    static let notification = Notification.Name("CameraToolkit.BrowserCommand")

    @MainActor
    static func post(_ command: BrowserCommand) {
        NotificationCenter.default.post(name: notification, object: command.rawValue)
    }
}

enum BrowserThumbnailSizing {
    static let defaultHeight = 32.0
    static let presets = [16.0, 24.0, 32.0, 44.0, 60.0, 80.0, 104.0]

    static func larger(than current: Double) -> Double {
        presets.first(where: { $0 > current + 0.5 }) ?? presets.last ?? defaultHeight
    }

    static func smaller(than current: Double) -> Double {
        presets.last(where: { $0 < current - 0.5 }) ?? presets.first ?? defaultHeight
    }

    static func width(for height: Double) -> Double {
        height * 4 / 3
    }

    static func maximumPixelSize(for height: Double) -> Int {
        max(128, Int((height * 2).rounded(.up)))
    }
}

enum BrowserTreeProjection {
    static func flattened<Item>(
        roots: [Item],
        childrenByParentID: [String: [Item]],
        expandedParentIDs: Set<String>,
        id: (Item) -> String
    ) -> [Item] {
        var result: [Item] = []
        var visited: Set<String> = []

        func append(_ items: [Item]) {
            for item in items {
                let itemID = id(item)
                guard visited.insert(itemID).inserted else { continue }
                result.append(item)
                if expandedParentIDs.contains(itemID),
                   let children = childrenByParentID[itemID] {
                    append(children)
                }
            }
        }

        append(roots)
        return result
    }
}

enum BrowserThumbnailShortcut {
    static func command(
        for charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> BrowserCommand? {
        let relevantFlags = modifierFlags.intersection([.command, .control, .option])
        guard relevantFlags == [.command] else { return nil }

        switch charactersIgnoringModifiers {
        case "=", "+":
            return .increaseThumbnailSize
        case "-", "_":
            return .decreaseThumbnailSize
        default:
            return nil
        }
    }
}

enum BrowserItemNamePolicy {
    static func normalizedName(_ rawValue: String) -> String? {
        let name = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains(":"),
              !name.contains("\0") else {
            return nil
        }
        return name
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
            title: "Files and Folders",
            symbol: "folder",
            shortcuts: [
                .init(action: "Previous or next item", keys: "↑  ↓", detail: "Moves the file selection and updates the side preview."),
                .init(action: "Expand or collapse a folder", keys: "→  ←", detail: "Shows or hides a folder’s contents inline without navigating away."),
                .init(action: "Open selected item", keys: "Return  /  ⌘O  /  ⌘↓", detail: "Opens a folder or the selected file in its default app."),
                .init(action: "Preview selected photos", keys: "Space  /  ⌘Y", detail: "Opens Camera Toolkit's large preview without decoding the full RAW."),
                .init(action: "Copy selected files", keys: "⌘C", detail: "Copies Finder-compatible file references to the clipboard."),
                .init(action: "Copy file paths", keys: "Right-click", detail: "Copies each selected file or folder path as plain text, one path per line."),
                .init(action: "Rename selected item", keys: "Right-click", detail: "Renames one item without reading or rewriting its file contents."),
                .init(action: "Delete an empty folder", keys: "Right-click", detail: "Confirms, then removes only a truly empty folder. Hidden files make the operation fail safely."),
                .init(action: "Select all", keys: "⌘A", detail: "Selects every visible row, including contents from expanded folders."),
                .init(action: "Larger or smaller thumbnails", keys: "⌘+  ⌘−", detail: "Resizes browser thumbnails and remembers the chosen size."),
                .init(action: "Select across folders", keys: "+ button", detail: "Starts an event-selection basket that stays with you while browsing folders or camera sources."),
                .init(action: "Open Event Library", keys: "⌥⌘E", detail: "Shows event photos across their camera, buffer, library, and Immich locations."),
                .init(action: "Open Transfer Queue", keys: "⌥⌘T", detail: "Shows what is copying or verifying, current speed, progress, and any problem."),
                .init(action: "Open SQL Inspector", keys: "⇧⌘I", detail: "Browses the SQLite photo list, schema, and read-only SQL queries."),
                .init(action: "New folder", keys: "⇧⌘N", detail: "Creates a folder in the location currently being browsed."),
                .init(action: "Reveal in Finder", keys: "⇧⌘R", detail: "Shows the selected files in Finder."),
            ]
        ),
        KeyboardShortcutSection(
            title: "Navigation",
            symbol: "arrow.triangle.turn.up.right.diamond",
            shortcuts: [
                .init(action: "Back or forward", keys: "⌘[  ⌘]", detail: "Moves through folder history."),
                .init(action: "Enclosing folder", keys: "⌘↑", detail: "Opens the folder containing the current folder."),
                .init(action: "Previous or next camera", keys: "⇧⌃Tab  ⌃Tab", detail: "Moves between configured camera sources."),
                .init(action: "Show or hide sidebar", keys: "⌘B", detail: "Toggles the Locations sidebar."),
                .init(action: "Refresh", keys: "⌘R", detail: "Refreshes locations and the current browser state."),
                .init(action: "Keyboard shortcuts", keys: "⇧⌘K", detail: "Opens this shortcut reference window."),
            ]
        ),
        KeyboardShortcutSection(
            title: "Preview",
            symbol: "photo",
            shortcuts: [
                .init(action: "Previous or next photo", keys: "←  →", detail: "Moves through previewable photos in the current folder."),
                .init(action: "Zoom in or out", keys: "Zoom buttons / pinch", detail: "Zooms the embedded preview without changing thumbnail size."),
                .init(action: "Zoom to fit", keys: "⌘0", detail: "Fits the whole photo inside the preview."),
                .init(action: "Actual size", keys: "⌘1", detail: "Shows one image pixel per display point."),
                .init(action: "Pan a zoomed photo", keys: "Drag", detail: "Click and drag the photo after zooming in."),
                .init(action: "Open in Photomator", keys: "↗ button", detail: "The side preview's expand button opens the RAW in Photomator."),
                .init(action: "Close large preview", keys: "Space  /  Esc", detail: "Returns to the file browser."),
            ]
        ),
        KeyboardShortcutSection(
            title: "Safety",
            symbol: "lock.shield",
            shortcuts: [
                .init(action: "Move, paste, or delete files", keys: "Disabled", detail: "Camera Toolkit never binds destructive Finder shortcuts while browsing a camera card. Empty folders can be removed only from their confirmed right-click action."),
            ]
        ),
    ]
}

@MainActor
enum FileClipboardWriter {
    @discardableResult
    static func copy(_ urls: [URL], to pasteboard: NSPasteboard = .general) -> Bool {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(fileURLs as [NSURL])
    }

    @discardableResult
    static func copyPaths(_ urls: [URL], to pasteboard: NSPasteboard = .general) -> Bool {
        let paths = urls.filter(\.isFileURL).map(\.path)
        guard !paths.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }
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
        window.minSize = NSSize(width: 620, height: 480)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: KeyboardShortcutsReferenceView())
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
                    Text("Finder-style browsing, fast camera switching, and Photomator-style preview controls.")
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
