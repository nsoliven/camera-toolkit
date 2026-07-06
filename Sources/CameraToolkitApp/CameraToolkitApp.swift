import SwiftUI

@main
struct CameraToolkitApp: App {
    @State private var model = DashboardModel.preview

    var body: some Scene {
        WindowGroup {
            AppShell(model: model)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .commands {
            SidebarCommands()
        }

        Settings {
            SettingsView(model: model)
                .frame(width: 680, height: 520)
        }
    }
}
