import AppKit
import SwiftUI

@main
struct CameraToolkitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: DashboardModel {
        CameraToolkitRuntime.model
    }

    var body: some Scene {
        WindowGroup {
            AppShell(model: model)
                .frame(minWidth: 900, minHeight: 660)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            CommandGroup(after: .sidebar) {
                Button("Toggle Camera Toolkit Sidebar") {
                    model.toggleSidebar()
                }
                .keyboardShortcut("b", modifiers: .command)

                Button(model.isRefreshing ? "Refreshing All" : "Refresh All") {
                    model.refreshAll()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshing)
            }
        }

        Settings {
            ConfigView(model: model)
                .frame(width: 760, height: 620)
        }
    }
}

@MainActor
private enum CameraToolkitRuntime {
    static let model = DashboardModel.live()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            self.openWindowIfNeeded()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openWindowIfNeeded()
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    private func openWindowIfNeeded() {
        guard NSApp.windows.allSatisfy({ !$0.isVisible }) else { return }
        if !NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil) {
            CameraToolkitMainWindow.shared.show(model: CameraToolkitRuntime.model)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if NSApp.windows.allSatisfy({ !$0.isVisible }) {
                CameraToolkitMainWindow.shared.show(model: CameraToolkitRuntime.model)
            }
        }
    }
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
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
