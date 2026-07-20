import AppKit
import SwiftUI

@main
@MainActor
final class CameraToolkitApplication: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: CameraToolkitApplication?

    private let model = CameraToolkitRuntime.model
    private var thumbnailShortcutMonitor: Any?

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
        installThumbnailShortcutMonitor()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTransferQueueRequest(_:)),
            name: .cameraToolkitShowTransferQueue,
            object: nil
        )
        CameraToolkitMainWindow.shared.show(model: model)
        if model.transferQueue != nil || !model.pendingTransferBatches.isEmpty {
            TransferQueueWindowController.shared.show(model: model)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        if let thumbnailShortcutMonitor {
            NSEvent.removeMonitor(thumbnailShortcutMonitor)
        }
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

    private func installThumbnailShortcutMonitor() {
        guard thumbnailShortcutMonitor == nil else { return }
        thumbnailShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let command = BrowserThumbnailShortcut.command(
                for: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags
            ) else {
                return event
            }

            BrowserCommand.post(command)
            return nil
        }
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

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        addBrowserCommand(
            to: fileMenu,
            title: "Open Selected Item",
            command: .openSelection,
            keyEquivalent: "o"
        )
        addBrowserCommand(
            to: fileMenu,
            title: "Preview Selected Photos",
            command: .previewSelection,
            keyEquivalent: "y"
        )
        fileMenu.addItem(.separator())
        addBrowserCommand(
            to: fileMenu,
            title: "New Folder…",
            command: .createFolder,
            keyEquivalent: "n",
            modifiers: [.command, .shift]
        )
        addBrowserCommand(
            to: fileMenu,
            title: "Reveal in Finder",
            command: .revealSelection,
            keyEquivalent: "r",
            modifiers: [.command, .shift]
        )
        fileMenu.addItem(.separator())
        addBrowserCommand(
            to: fileMenu,
            title: "Move to Trash…",
            command: .moveSelectionToTrash,
            keyEquivalent: "\u{8}"
        )

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        addBrowserCommand(
            to: editMenu,
            title: "Copy",
            command: .copySelection,
            keyEquivalent: "c"
        )
        addBrowserCommand(
            to: editMenu,
            title: "Select All",
            command: .selectAll,
            keyEquivalent: "a"
        )

        let goMenuItem = NSMenuItem()
        mainMenu.addItem(goMenuItem)
        let goMenu = NSMenu(title: "Go")
        goMenuItem.submenu = goMenu
        addBrowserCommand(
            to: goMenu,
            title: "Back",
            command: .goBack,
            keyEquivalent: "["
        )
        addBrowserCommand(
            to: goMenu,
            title: "Forward",
            command: .goForward,
            keyEquivalent: "]"
        )
        addBrowserCommand(
            to: goMenu,
            title: "Enclosing Folder",
            command: .goUp,
            keyEquivalent: "\u{F700}"
        )
        addBrowserCommand(
            to: goMenu,
            title: "Open Selected Item",
            command: .openSelection,
            keyEquivalent: "\u{F701}"
        )
        goMenu.addItem(.separator())
        addBrowserCommand(
            to: goMenu,
            title: "Previous Camera Source",
            command: .previousSource,
            keyEquivalent: "\t",
            modifiers: [.control, .shift]
        )
        addBrowserCommand(
            to: goMenu,
            title: "Next Camera Source",
            command: .nextSource,
            keyEquivalent: "\t",
            modifiers: [.control]
        )

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

        viewMenu.addItem(.separator())
        addBrowserCommand(
            to: viewMenu,
            title: "Larger Thumbnails",
            command: .increaseThumbnailSize,
            keyEquivalent: "+"
        )
        addBrowserCommand(
            to: viewMenu,
            title: "Smaller Thumbnails",
            command: .decreaseThumbnailSize,
            keyEquivalent: "-"
        )

        viewMenu.addItem(.separator())

        let eventLibraryItem = NSMenuItem(
            title: "Event Library…",
            action: #selector(openEventLibrary),
            keyEquivalent: "e"
        )
        eventLibraryItem.keyEquivalentModifierMask = [.command, .option]
        eventLibraryItem.target = self
        viewMenu.addItem(eventLibraryItem)

        let catalogInspectorItem = NSMenuItem(
            title: "Photo List SQL Inspector…",
            action: #selector(openCatalogInspector),
            keyEquivalent: "i"
        )
        catalogInspectorItem.keyEquivalentModifierMask = [.command, .shift]
        catalogInspectorItem.target = self
        viewMenu.addItem(catalogInspectorItem)

        viewMenu.addItem(.separator())

        let refreshItem = NSMenuItem(
            title: "Refresh All",
            action: #selector(refreshAll),
            keyEquivalent: "r"
        )
        refreshItem.keyEquivalentModifierMask = [.command]
        refreshItem.target = self
        viewMenu.addItem(refreshItem)

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu

        let minimizeItem = NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(minimizeItem)

        let zoomItem = NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(zoomItem)
        windowMenu.addItem(.separator())

        let mainWindowItem = NSMenuItem(
            title: "Camera Toolkit",
            action: #selector(openMainWindow),
            keyEquivalent: "0"
        )
        mainWindowItem.target = self
        windowMenu.addItem(mainWindowItem)

        let transferQueueItem = NSMenuItem(
            title: "Transfer Queue…",
            action: #selector(openTransferQueue),
            keyEquivalent: "t"
        )
        transferQueueItem.keyEquivalentModifierMask = [.command, .option]
        transferQueueItem.target = self
        windowMenu.addItem(transferQueueItem)

        let storageSpeedItem = NSMenuItem(
            title: "Storage Speed Tests…",
            action: #selector(openStorageSpeedTests),
            keyEquivalent: ""
        )
        storageSpeedItem.target = self
        windowMenu.addItem(storageSpeedItem)
        NSApp.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu

        let shortcutsItem = NSMenuItem(
            title: "Keyboard Shortcuts…",
            action: #selector(openKeyboardShortcuts),
            keyEquivalent: "k"
        )
        shortcutsItem.keyEquivalentModifierMask = [.command, .shift]
        shortcutsItem.target = self
        helpMenu.addItem(shortcutsItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func addBrowserCommand(
        to menu: NSMenu,
        title: String,
        command: BrowserCommand,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) {
        let item = NSMenuItem(
            title: title,
            action: #selector(performBrowserCommand(_:)),
            keyEquivalent: keyEquivalent
        )
        item.keyEquivalentModifierMask = modifiers
        item.representedObject = command.rawValue
        item.target = self
        menu.addItem(item)
    }

    @objc private func openSettings() {
        CameraToolkitConfigWindow.shared.show(model: model)
    }

    @objc private func toggleSidebar() {
        model.toggleSidebar()
    }

    @objc private func performBrowserCommand(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let command = BrowserCommand(rawValue: rawValue) else {
            return
        }
        BrowserCommand.post(command)
    }

    @objc private func openKeyboardShortcuts() {
        KeyboardShortcutsWindowController.shared.show()
    }

    @objc private func openEventLibrary() {
        EventLibraryWindowController.shared.show(model: model)
    }

    @objc private func openCatalogInspector() {
        CatalogInspectorWindowController.shared.show(model: model)
    }

    @objc private func openMainWindow() {
        CameraToolkitMainWindow.shared.show(model: model)
    }

    @objc private func openTransferQueue() {
        TransferQueueWindowController.shared.show(model: model)
    }

    @objc private func openStorageSpeedTests() {
        StorageBenchmarkWindowController.shared.show(model: model)
    }

    @objc private func handleTransferQueueRequest(_ notification: Notification) {
        openTransferQueue()
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
                .frame(minWidth: 1040, minHeight: 720)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Camera Toolkit"
        window.identifier = NSUserInterfaceItemIdentifier("CameraToolkitMainWindow")
        window.isRestorable = false
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 1040, height: 720)
        window.setContentSize(NSSize(width: 1320, height: 840))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class CameraToolkitConfigWindow: NSObject, NSWindowDelegate {
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
                .frame(
                    minWidth: CameraToolkitPopOutWindow.settings.minimumContentSize.width,
                    maxWidth: .infinity,
                    minHeight: CameraToolkitPopOutWindow.settings.minimumContentSize.height,
                    maxHeight: .infinity
                )
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
        CameraToolkitWindowSizing.configure(window, as: .settings)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
