import AppKit
import SwiftUI

/// Builds the main window — the one place its AppKit setup lives, shared by
/// the app and the snapshot harness so screenshots show what users see.
///
/// The window stays AppKit-owned (menus, termination, and the singleton
/// window controllers all are), and the hosting controller bridges the
/// SwiftUI scene pieces into it: `.toolbar`, `.navigationTitle`, and
/// `.searchable` land in a real `NSToolbar` with Liquid Glass items.
@MainActor
enum MainWindowFactory {
    static let frameAutosaveName = "CameraToolkitMainWindow"
    static let minimumSize = NSSize(width: 1040, height: 720)
    static let defaultContentSize = NSSize(width: 1320, height: 840)
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    /// - Parameters:
    ///   - restoresFrame: Reads and autosaves the frame under
    ///     `frameAutosaveName`. The harness turns it off so test runs never
    ///     write window frames into defaults.
    ///   - makeWindow: Creates the bare `NSWindow` from a content rect and
    ///     style mask — the harness passes its off-screen subclass here.
    static func make(
        model: DashboardModel,
        workspace: EventsWorkspace,
        restoresFrame: Bool = true,
        makeWindow: (NSRect, NSWindow.StyleMask) -> NSWindow = { rect, style in
            NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        }
    ) -> NSWindow {
        let hostingController = NSHostingController(
            rootView: AppShell(model: model, workspace: workspace)
                .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
        )
        // Publishes the SwiftUI toolbar, title, and search field into this
        // window. Requires the controller to be the contentViewController.
        hostingController.sceneBridgingOptions = .all

        let window = makeWindow(NSRect(origin: .zero, size: defaultContentSize), styleMask)
        // SwiftUI's navigationTitle replaces this once the root renders;
        // it is the fallback for the Window menu until then.
        window.title = "Camera Toolkit"
        window.identifier = NSUserInterfaceItemIdentifier(BrowserCommand.mainWindowIdentifier)
        window.isRestorable = false
        window.contentViewController = hostingController
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.minSize = minimumSize
        window.setContentSize(defaultContentSize)
        window.isReleasedWhenClosed = false
        if restoresFrame {
            if !window.setFrameUsingName(frameAutosaveName) {
                window.center()
            }
            window.setFrameAutosaveName(frameAutosaveName)
        }
        return window
    }
}
