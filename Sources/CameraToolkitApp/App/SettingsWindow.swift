import AppKit
import SwiftUI

/// The Settings window: the standard Mac settings layout — a preference
/// toolbar of panes, the window titled after the selected pane and sized
/// to it, not resizable or minimizable. Each pane is a grouped SwiftUI
/// Form in its own hosting controller.
@MainActor
final class CameraToolkitConfigWindow: NSObject, NSWindowDelegate {
    static let shared = CameraToolkitConfigWindow()
    static let windowIdentifier = "CameraToolkitConfigWindow"
    static let selectedPaneDefaultsKey = "CameraToolkit.settings.selectedPane"

    private var window: NSWindow?
    private var tabs: SettingsTabViewController?

    func show(model: DashboardModel) {
        if let window {
            CameraToolkitWindowFactory.present(window)
            return
        }

        let initialPane = SettingsPane(rawValue: UserDefaults.standard.integer(forKey: Self.selectedPaneDefaultsKey)) ?? .locations
        let tabs = SettingsTabViewController(model: model, initialPane: initialPane)
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.delegate = self
        SettingsTabViewController.fit(window, to: initialPane.contentSize, animate: false)
        // Only the position is remembered; the size always follows the pane.
        if window.setFrameUsingName(Self.windowIdentifier) {
            SettingsTabViewController.fit(window, to: initialPane.contentSize, animate: false)
        } else {
            window.center()
        }
        window.setFrameAutosaveName(Self.windowIdentifier)
        self.window = window
        self.tabs = tabs
        CameraToolkitWindowFactory.present(window)
    }

    /// Switches the open Settings window to a pane.
    func select(_ pane: SettingsPane) {
        tabs?.selectedTabViewItemIndex = pane.rawValue
    }
}

/// Toolbar-style tab controller that resizes the window to each pane,
/// keeping the title bar where it is, and remembers the last pane.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    init(model: DashboardModel, initialPane: SettingsPane) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: pane.view(model: model))
            // The window follows the pane's fixed size; SwiftUI must not
            // push its own minimum or maximum onto the window.
            host.sizingOptions = []
            host.preferredContentSize = pane.contentSize
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            // The toolbar uses this as its item identifier, so it must be a string.
            item.identifier = pane.toolbarIdentifier
            addTabViewItem(item)
        }
        selectedTabViewItemIndex = initialPane.rawValue
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let identifier = tabViewItem?.identifier as? String,
              let pane = SettingsPane.allCases.first(where: { $0.toolbarIdentifier == identifier }) else { return }
        UserDefaults.standard.set(pane.rawValue, forKey: CameraToolkitConfigWindow.selectedPaneDefaultsKey)
        if let window = view.window {
            window.title = pane.title
            Self.fit(window, to: pane.contentSize, animate: window.isVisible)
        }
    }

    /// Sizes the window's content to `size`, growing or shrinking downward
    /// so the title bar stays put.
    static func fit(_ window: NSWindow, to size: NSSize, animate: Bool) {
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        guard frame != old else { return }
        window.setFrame(frame, display: true, animate: animate)
    }
}
