import AppKit
import SwiftUI

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
