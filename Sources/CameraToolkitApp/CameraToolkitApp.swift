import AppKit
import SwiftUI

@main
@MainActor
final class CameraToolkitApplication: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: CameraToolkitApplication?

    private let model = CameraToolkitRuntime.model

    static func main() {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        let application = NSApplication.shared
        let delegate = CameraToolkitApplication()
        retainedDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        delegate.installMenu()
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CameraToolkitMainWindow.shared.show(model: model)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        CameraToolkitMainWindow.shared.show(model: model)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    private func installMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Camera Toolkit")
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(
            title: "About Camera Toolkit",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)

        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Camera Toolkit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        let sidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar),
            keyEquivalent: "b"
        )
        sidebarItem.keyEquivalentModifierMask = [.command]
        sidebarItem.target = self
        viewMenu.addItem(sidebarItem)

        let refreshItem = NSMenuItem(
            title: "Refresh All",
            action: #selector(refreshAll),
            keyEquivalent: "r"
        )
        refreshItem.keyEquivalentModifierMask = [.command]
        refreshItem.target = self
        viewMenu.addItem(refreshItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        CameraToolkitConfigWindow.shared.show(model: model)
    }

    @objc private func toggleSidebar() {
        model.toggleSidebar()
    }

    @objc private func refreshAll() {
        model.refreshAll()
    }
}

@MainActor
private enum CameraToolkitRuntime {
    static let model = DashboardModel.live()
}

@MainActor
private final class CameraToolkitMainWindow: NSObject, NSWindowDelegate {
    static let shared = CameraToolkitMainWindow()

    private var window: NSWindow?

    func show(model: DashboardModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: AppShell(model: model)
                .frame(minWidth: 900, minHeight: 660)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Camera Toolkit"
        window.identifier = NSUserInterfaceItemIdentifier("CameraToolkitMainWindow")
        window.isRestorable = false
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class CameraToolkitConfigWindow: NSObject, NSWindowDelegate {
    static let shared = CameraToolkitConfigWindow()

    private var window: NSWindow?

    func show(model: DashboardModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: ConfigView(model: model)
                .frame(width: 760, height: 620)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Camera Toolkit Settings"
        window.identifier = NSUserInterfaceItemIdentifier("CameraToolkitConfigWindow")
        window.isRestorable = false
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
