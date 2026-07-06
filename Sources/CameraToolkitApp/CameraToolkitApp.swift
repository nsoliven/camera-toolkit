import AppKit
import SwiftUI

@main
struct CameraToolkitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = DashboardModel.live()

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
