import AppKit

/// The app's own menu commands. The delegate implements them; the menu is
/// built against this protocol so tests can build it without the delegate,
/// whose model loads the live configuration.
@MainActor
@objc protocol MainMenuActions: AnyObject {
    func openSettings(_ sender: Any?)
    func newEvent(_ sender: Any?)
    func addFolderOrCard(_ sender: Any?)
    func performBrowserCommand(_ sender: NSMenuItem)
    func undoSortOrText(_ sender: Any?)
    func selectAllOnBoardOrText(_ sender: Any?)
    func toggleSidebar(_ sender: Any?)
    func toggleInspector(_ sender: Any?)
    func showTiles(_ sender: Any?)
    func showList(_ sender: Any?)
    func toggleHideSorted(_ sender: Any?)
    func zoomTilesIn(_ sender: Any?)
    func zoomTilesOut(_ sender: Any?)
    func refreshAll(_ sender: Any?)
    func openMainWindow(_ sender: Any?)
    func openTransferQueue(_ sender: Any?)
    func openEventLibrary(_ sender: Any?)
    func openPeople(_ sender: Any?)
    func openTrash(_ sender: Any?)
    func openStorageSpeedTests(_ sender: Any?)
    func openCatalogInspector(_ sender: Any?)
    func startSetupGuide(_ sender: Any?)
    func openKeyboardShortcuts(_ sender: Any?)
}

/// The standard macOS menu bar with Camera Toolkit's commands in their HIG
/// homes. Standard items (Cut, Copy, Paste, Close, Hide, Toolbar, Bring All
/// to Front) use nil-targeted AppKit selectors so the responder chain —
/// text fields included — answers them.
@MainActor
enum MainMenu {
    /// Board view settings the View menu writes. The boards read the same
    /// keys through `@AppStorage`, so a menu change redraws the open board.
    enum DefaultsKey {
        static let boardMode = "CameraToolkit.organize.mode"
        static let hideSorted = "CameraToolkit.organize.hideSorted"
        static let tileWidth = "CameraToolkit.organize.tileWidth"
        static let showInspector = "CameraToolkit.organize.showInspector"
    }

    static let tileWidthRange: ClosedRange<Double> = 88...460
    static let tileWidthStep = 44.0

    static func install(target: MainMenuActions) {
        let menu = make(target: target)
        NSApp.mainMenu = menu
        NSApp.servicesMenu = menu.item(withTitle: appName)?.submenu?.item(withTitle: "Services")?.submenu
        NSApp.windowsMenu = menu.item(withTitle: "Window")?.submenu
        NSApp.helpMenu = menu.item(withTitle: "Help")?.submenu
    }

    static let appName = "Camera Toolkit"

    static func make(target: MainMenuActions?) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appName, appMenu(target)))
        main.addItem(submenu("File", fileMenu(target)))
        main.addItem(submenu("Edit", editMenu(target)))
        main.addItem(submenu("View", viewMenu(target)))
        main.addItem(submenu("Window", windowMenu(target)))
        main.addItem(submenu("Help", helpMenu(target)))
        return main
    }

    // MARK: - Menus

    private static func appMenu(_ target: MainMenuActions?) -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(MainMenuActions.openSettings(_:)), ",", to: target))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu(_ target: MainMenuActions?) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Event…", #selector(MainMenuActions.newEvent(_:)), "n", to: target))
        menu.addItem(item("Add Folder or Card…", #selector(MainMenuActions.addFolderOrCard(_:)), to: target))
        menu.addItem(.separator())
        menu.addItem(browserItem("Open in Photomator", .openSelection, "o", target: target))
        menu.addItem(browserItem("Preview", .previewSelection, "y", target: target))
        menu.addItem(.separator())
        menu.addItem(browserItem("Reveal in Finder", .revealSelection, "r", [.command, .shift], target: target))
        menu.addItem(.separator())
        menu.addItem(browserItem("Move to Trash…", .moveSelectionToTrash, "\u{8}", target: target))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu(_ target: MainMenuActions?) -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", #selector(MainMenuActions.undoSortOrText(_:)), "z", to: target))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(MainMenuActions.selectAllOnBoardOrText(_:)), "a", to: target))
        menu.addItem(.separator())
        menu.addItem(browserItem("Find…", .find, "f", target: target))
        return menu
    }

    private static func viewMenu(_ target: MainMenuActions?) -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Hide Sidebar", #selector(MainMenuActions.toggleSidebar(_:)), "s", [.command, .control], to: target))
        // ⌘B was the sidebar shortcut before ⌃⌘S; it keeps working unseen.
        let legacySidebar = item("Hide Sidebar", #selector(MainMenuActions.toggleSidebar(_:)), "b", to: target)
        legacySidebar.isHidden = true
        legacySidebar.allowsKeyEquivalentWhenHidden = true
        menu.addItem(legacySidebar)
        // No shortcut: ⌥⌘T has long opened Jobs, and the owner relies on it.
        menu.addItem(item("Hide Toolbar", #selector(NSWindow.toggleToolbarShown(_:))))
        menu.addItem(item("Show Inspector", #selector(MainMenuActions.toggleInspector(_:)), "i", [.command, .option], to: target))
        menu.addItem(.separator())
        menu.addItem(item("as Tiles", #selector(MainMenuActions.showTiles(_:)), to: target))
        menu.addItem(item("as List", #selector(MainMenuActions.showList(_:)), to: target))
        menu.addItem(item("Hide Sorted Items", #selector(MainMenuActions.toggleHideSorted(_:)), to: target))
        menu.addItem(.separator())
        menu.addItem(item("Bigger Tiles", #selector(MainMenuActions.zoomTilesIn(_:)), "+", to: target))
        menu.addItem(item("Smaller Tiles", #selector(MainMenuActions.zoomTilesOut(_:)), "-", to: target))
        menu.addItem(.separator())
        menu.addItem(item("Refresh", #selector(MainMenuActions.refreshAll(_:)), "r", to: target))
        return menu
    }

    private static func windowMenu(_ target: MainMenuActions?) -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item(appName, #selector(MainMenuActions.openMainWindow(_:)), "0", to: target))
        menu.addItem(.separator())
        menu.addItem(item("Jobs", #selector(MainMenuActions.openTransferQueue(_:)), "t", [.command, .option], to: target))
        let jobsAlternate = item("Jobs", #selector(MainMenuActions.openTransferQueue(_:)), "j", [.command, .option], to: target)
        jobsAlternate.isHidden = true
        jobsAlternate.allowsKeyEquivalentWhenHidden = true
        menu.addItem(jobsAlternate)
        menu.addItem(item("Event Library", #selector(MainMenuActions.openEventLibrary(_:)), "e", [.command, .option], to: target))
        menu.addItem(item("People", #selector(MainMenuActions.openPeople(_:)), "p", [.command, .option], to: target))
        menu.addItem(item("Trash", #selector(MainMenuActions.openTrash(_:)), to: target))
        menu.addItem(item("Storage Speed Tests", #selector(MainMenuActions.openStorageSpeedTests(_:)), to: target))
        menu.addItem(item("Photo List SQL Inspector", #selector(MainMenuActions.openCatalogInspector(_:)), "i", [.command, .shift], to: target))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu(_ target: MainMenuActions?) -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Setup Guide…", #selector(MainMenuActions.startSetupGuide(_:)), to: target))
        menu.addItem(item("Keyboard Shortcuts", #selector(MainMenuActions.openKeyboardShortcuts(_:)), "k", [.command, .shift], to: target))
        return menu
    }

    // MARK: - Items

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ keyEquivalent: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command],
        to target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private static func browserItem(
        _ title: String,
        _ command: BrowserCommand,
        _ keyEquivalent: String,
        _ modifiers: NSEvent.ModifierFlags = [.command],
        target: MainMenuActions?
    ) -> NSMenuItem {
        let item = item(title, #selector(MainMenuActions.performBrowserCommand(_:)), keyEquivalent, modifiers, to: target)
        item.representedObject = command.rawValue
        return item
    }

    /// The next tile width a View ▸ Bigger/Smaller Tiles step lands on.
    static func steppedTileWidth(_ width: Double, by direction: Double) -> Double {
        min(max(width + direction * tileWidthStep, tileWidthRange.lowerBound), tileWidthRange.upperBound)
    }
}
