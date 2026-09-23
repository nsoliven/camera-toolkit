import AppKit
import SwiftUI

enum CameraToolkitPopOutWindow: CaseIterable {
    case settings
    case transferQueue
    case storageSpeedTests
    case eventLibrary
    case photoDatabase
    case keyboardShortcuts
    case trash
    case people

    var minimumContentSize: NSSize {
        switch self {
        case .settings: NSSize(width: 660, height: 520)
        case .transferQueue: NSSize(width: 720, height: 440)
        case .storageSpeedTests: NSSize(width: 720, height: 520)
        case .eventLibrary: NSSize(width: 940, height: 600)
        case .photoDatabase: NSSize(width: 820, height: 540)
        case .keyboardShortcuts: NSSize(width: 620, height: 480)
        case .trash: NSSize(width: 760, height: 520)
        case .people: NSSize(width: 640, height: 440)
        }
    }
}

@MainActor
enum CameraToolkitWindowSizing {
    private static let practicalUnlimitedSize = NSSize(width: 100_000, height: 100_000)

    static func configure(_ window: NSWindow, as kind: CameraToolkitPopOutWindow) {
        let minimumContentSize = kind.minimumContentSize
        window.styleMask.insert(.resizable)
        window.contentMinSize = minimumContentSize
        window.minSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: minimumContentSize)
        ).size
        window.contentMaxSize = practicalUnlimitedSize
        window.maxSize = practicalUnlimitedSize
    }
}

/// Builds every pop-out window the same way, so each one gets the macOS 26
/// chrome for free: the SwiftUI root's `.navigationTitle`,
/// `.navigationSubtitle`, `.toolbar`, and `.searchable` bridge into a real
/// `NSToolbar` (Liquid Glass), content runs under the title bar, the window
/// never opens as a tab, and it remembers where the owner left it.
@MainActor
enum CameraToolkitWindowFactory {
    static func make<Root: View>(
        _ kind: CameraToolkitPopOutWindow,
        identifier: String,
        title: String,
        initialContentSize: NSSize,
        toolbarStyle: NSWindow.ToolbarStyle = .unified,
        rootView: Root
    ) -> NSWindow {
        let host = NSHostingController(rootView: rootView)
        // Must be set before the window installs the controller's view, or
        // the SwiftUI toolbar never reaches the window.
        host.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // An empty toolbar gives the bridged SwiftUI items somewhere to land
        // and keeps the unified title bar height stable while they load.
        window.toolbar = NSToolbar(identifier: identifier)
        window.toolbarStyle = toolbarStyle
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.contentViewController = host
        CameraToolkitWindowSizing.configure(window, as: kind)
        window.setContentSize(initialContentSize)
        if !window.setFrameUsingName(identifier) {
            window.center()
        }
        window.setFrameAutosaveName(identifier)
        return window
    }

    /// Brings a window forward and the app with it.
    static func present(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
