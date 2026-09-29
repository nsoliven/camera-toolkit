import AppKit
import CameraToolkitCore
import SwiftUI

@main
@MainActor
final class CameraToolkitApplication: NSObject, NSApplicationDelegate, NSMenuItemValidation, MainMenuActions {
    private static var retainedDelegate: CameraToolkitApplication?

    private let model = CameraToolkitRuntime.model

    static func main() {
        // Packaging check: report where each bundled resource resolves and
        // exit before any app state, crash reporting, or window is touched.
        if CommandLine.arguments.contains("--print-resource-paths") {
            exit(printResourcePaths())
        }
        // Drive layout migration (Card Copy → Originals/<Camera>): runs and
        // exits before any app state, catalog connection, or window exists.
        if CommandLine.arguments.contains(LayoutMigrationCommand.flag) {
            let status = LayoutMigrationCommand.run(
                arguments: CommandLine.arguments,
                defaultSupportFolder: DashboardModel.defaultApplicationSupportURL
                    .appendingPathComponent("CameraToolkit", isDirectory: true),
                isAppRunning: { anotherAppInstanceIsRunning() }
            )
            DebugLog.shared.flush()
            exit(status)
        }
        // NAS layout migration (legacy RAW/JPEG/Video archive → mirror
        // layout): server-side renames from a reviewed mapping; same rules.
        if CommandLine.arguments.contains(NASLayoutMigrationCommand.flag) {
            let status = NASLayoutMigrationCommand.run(
                arguments: CommandLine.arguments,
                defaultSupportFolder: DashboardModel.defaultApplicationSupportURL
                    .appendingPathComponent("CameraToolkit", isDirectory: true),
                isAppRunning: { anotherAppInstanceIsRunning() }
            )
            DebugLog.shared.flush()
            exit(status)
        }
        CrashReporting.start()
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        let application = NSApplication.shared
        let delegate = CameraToolkitApplication()
        retainedDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        MainMenu.install(target: delegate)
        application.run()
    }

    /// Another Camera Toolkit app (any bundle with this bundle identifier)
    /// is running — the layout migration refuses to touch files or the
    /// catalog under it.
    private static func anotherAppInstanceIsRunning() -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? "org.cameratoolkit.CameraToolkit"
        let own = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != own && !$0.isTerminated }
    }

    /// One `<name> <location> <path>` line per resource; 1 if any is missing.
    private static func printResourcePaths() -> Int32 {
        var status: Int32 = 0
        for (name, resolution) in CoreResources.all {
            print("\(name) \(resolution.location.rawValue) \(resolution.url?.path ?? "-")")
            if resolution.url == nil { status = 1 }
        }
        DebugLog.shared.flush()
        return status
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTransferQueueRequest(_:)),
            name: .cameraToolkitShowTransferQueue,
            object: nil
        )
        TrashWindowController.shared.onRestored = { report in
            CameraToolkitRuntime.workspace.reinstateTrashedAssignments(report)
        }
        CameraToolkitMainWindow.shared.show(model: model)
        if model.transferQueue != nil || !model.pendingTransferBatches.isEmpty {
            TransferQueueWindowController.shared.show(model: model)
        }
        CrashReporting.checkPreviousRunSoon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        model.flushConfigurationSave()
        model.flushJobHistory()
        CameraToolkitRuntime.workspace.flushUndoHistory()
        // Fold the catalog's WAL back into the main file so the database
        // on disk is complete on its own after quit.
        CatalogDatabase.checkpointAndCloseAll()
        CrashReporting.markCleanExit()
    }

    /// A file job keeps its progress in memory — quitting mid-copy or
    /// mid-scan abandons it. Original camera files are never touched by a
    /// job, so warn rather than block: the user can still quit anyway.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let job = model.activeJob else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "A job is still running."
        alert.informativeText = "“\(job.note)” is \(job.progress.formatted(.percent.precision(.fractionLength(0)))) done. Quitting abandons it — no original files are at risk, but the job will have to be run again."
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.hasDestructiveAction = true
        let stay = alert.addButton(withTitle: "Don't Quit")
        stay.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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

    /// Board-selection commands stay off while a text field owns typing —
    /// ⌘⌫ in the search field deletes text, it does not trash the board's
    /// selection — and act only when a window that answers them is key.
    /// Undo and Select All belong to the field while typing and to the
    /// board otherwise. Everything else (Settings, windows, sidebar) works
    /// regardless of focus.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let typing = KeyboardTextFocus.isTypingInTextField()
        let keyWindow = NSApp.keyWindow?.identifier?.rawValue
        let boardIsKey = BrowserCommand.targetsMainWindow(keyWindowIdentifier: keyWindow)
        let defaults = UserDefaults.standard
        switch menuItem.action {
        case #selector(performBrowserCommand(_:)):
            return !typing && (boardIsKey || keyWindow == TrashWindowController.windowIdentifier)
        case #selector(undoOrText(_:)):
            let workspace = CameraToolkitRuntime.workspace
            menuItem.title = MainMenu.undoTitle(typing: typing, next: workspace.undoMenuTitle)
            return typing || (historyWindowIsKey(keyWindow) && workspace.canUndo)
        case #selector(redoOrText(_:)):
            let workspace = CameraToolkitRuntime.workspace
            menuItem.title = MainMenu.redoTitle(typing: typing, next: workspace.redoMenuTitle)
            return typing || (historyWindowIsKey(keyWindow) && workspace.canRedo)
        case #selector(selectAllOnBoardOrText(_:)):
            return typing || boardIsKey || keyWindow == TrashWindowController.windowIdentifier
        case #selector(toggleSidebar(_:)):
            menuItem.title = model.isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(toggleInspector(_:)):
            menuItem.title = defaults.bool(forKey: MainMenu.DefaultsKey.showInspector) ? "Hide Inspector" : "Show Inspector"
            return true
        case #selector(showTiles(_:)):
            menuItem.state = boardMode == .tiles ? .on : .off
            return true
        case #selector(showList(_:)):
            menuItem.state = boardMode == .list ? .on : .off
            return true
        case #selector(toggleHideSorted(_:)):
            menuItem.state = defaults.bool(forKey: MainMenu.DefaultsKey.hideSorted) ? .on : .off
            return true
        case #selector(zoomTilesIn(_:)), #selector(zoomTilesOut(_:)):
            return !typing && boardMode == .tiles
        default:
            return true
        }
    }

    /// The one history answers ⌘Z from the board and from the windows whose
    /// changes are in it: People (face changes), Duplicates and Trash.
    private func historyWindowIsKey(_ identifier: String?) -> Bool {
        BrowserCommand.targetsMainWindow(keyWindowIdentifier: identifier)
            || ["CameraToolkitPeopleWindow", "CameraToolkitDuplicatesWindow", TrashWindowController.windowIdentifier].contains(identifier)
    }

    private var boardMode: OrganizeBoardMode {
        UserDefaults.standard.string(forKey: MainMenu.DefaultsKey.boardMode).flatMap(OrganizeBoardMode.init(rawValue:)) ?? .tiles
    }

    @objc func openSettings(_ sender: Any?) {
        CameraToolkitConfigWindow.shared.show(model: model)
    }

    @objc func newEvent(_ sender: Any?) {
        CameraToolkitMainWindow.shared.show(model: model)
        CameraToolkitRuntime.workspace.requestNewEvent(from: nil)
    }

    @objc func addFolderOrCard(_ sender: Any?) {
        CameraToolkitMainWindow.shared.show(model: model)
        CameraToolkitRuntime.workspace.addUnsortedFolder()
    }

    @objc func syncAllToNAS(_ sender: Any?) {
        CameraToolkitMainWindow.shared.show(model: model)
        CameraToolkitRuntime.workspace.requestSyncAllToNAS()
    }

    @objc func toggleSidebar(_ sender: Any?) {
        model.toggleSidebar()
    }

    @objc func toggleInspector(_ sender: Any?) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: MainMenu.DefaultsKey.showInspector), forKey: MainMenu.DefaultsKey.showInspector)
    }

    @objc func showTiles(_ sender: Any?) {
        UserDefaults.standard.set(OrganizeBoardMode.tiles.rawValue, forKey: MainMenu.DefaultsKey.boardMode)
    }

    @objc func showList(_ sender: Any?) {
        UserDefaults.standard.set(OrganizeBoardMode.list.rawValue, forKey: MainMenu.DefaultsKey.boardMode)
    }

    @objc func toggleHideSorted(_ sender: Any?) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: MainMenu.DefaultsKey.hideSorted), forKey: MainMenu.DefaultsKey.hideSorted)
    }

    @objc func zoomTilesIn(_ sender: Any?) {
        stepTileWidth(by: 1)
    }

    @objc func zoomTilesOut(_ sender: Any?) {
        stepTileWidth(by: -1)
    }

    private func stepTileWidth(by direction: Double) {
        let defaults = UserDefaults.standard
        let current = defaults.object(forKey: MainMenu.DefaultsKey.tileWidth) as? Double ?? 220
        defaults.set(MainMenu.steppedTileWidth(current, by: direction), forKey: MainMenu.DefaultsKey.tileWidth)
    }

    @objc func performBrowserCommand(_ sender: NSMenuItem) {
        guard !KeyboardTextFocus.isTypingInTextField(),
              let rawValue = sender.representedObject as? String,
              let command = BrowserCommand(rawValue: rawValue) else {
            return
        }
        BrowserCommand.post(command)
    }

    /// ⌘Z undoes typing in a field and the newest action everywhere else.
    @objc func undoOrText(_ sender: Any?) {
        if KeyboardTextFocus.isTypingInTextField() {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: sender)
        } else {
            NotificationCenter.default.post(name: .cameraToolkitUndo, object: nil)
        }
    }

    /// ⌘⇧Z redoes typing in a field and the action that was just undone
    /// everywhere else.
    @objc func redoOrText(_ sender: Any?) {
        if KeyboardTextFocus.isTypingInTextField() {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: sender)
        } else {
            NotificationCenter.default.post(name: .cameraToolkitRedo, object: nil)
        }
    }

    /// ⌘A selects a field's text while typing and the board's stacks
    /// everywhere else.
    @objc func selectAllOnBoardOrText(_ sender: Any?) {
        if KeyboardTextFocus.isTypingInTextField() {
            NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: sender)
        } else {
            BrowserCommand.post(.selectAll)
        }
    }

    @objc func openKeyboardShortcuts(_ sender: Any?) {
        KeyboardShortcutsWindowController.shared.show()
    }

    @objc func startSetupGuide(_ sender: Any?) {
        CameraToolkitMainWindow.shared.show(model: model)
        CameraToolkitRuntime.workspace.startGuide()
    }

    @objc func openEventLibrary(_ sender: Any?) {
        EventLibraryWindowController.shared.show(model: model)
    }

    @objc func openPeople(_ sender: Any?) {
        PeopleWindowController.shared.show(model: model, workspace: CameraToolkitRuntime.workspace)
    }

    @objc func openTrash(_ sender: Any?) {
        TrashWindowController.shared.show(model: model)
    }

    @objc func openDuplicates(_ sender: Any?) {
        DuplicatesWindowController.shared.show(model: model, workspace: CameraToolkitRuntime.workspace)
    }

    @objc func openCatalogInspector(_ sender: Any?) {
        CatalogInspectorWindowController.shared.show(model: model)
    }

    @objc func openMainWindow(_ sender: Any?) {
        CameraToolkitMainWindow.shared.show(model: model)
    }

    @objc func openTransferQueue(_ sender: Any?) {
        TransferQueueWindowController.shared.show(model: model)
    }

    @objc func openStorageSpeedTests(_ sender: Any?) {
        StorageBenchmarkWindowController.shared.show(model: model)
    }

    @objc private func handleTransferQueueRequest(_ notification: Notification) {
        openTransferQueue(nil)
    }

    @objc func refreshAll(_ sender: Any?) {
        model.refreshAll()
    }
}

@MainActor
private enum CameraToolkitRuntime {
    static let model = DashboardModel.live()
    static let workspace = EventsWorkspace(model: model)
}

@MainActor
private final class CameraToolkitMainWindow: NSObject, NSWindowDelegate {
    static let shared = CameraToolkitMainWindow()

    private var window: NSWindow?

    func show(model: DashboardModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = MainWindowFactory.make(model: model, workspace: CameraToolkitRuntime.workspace)
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
