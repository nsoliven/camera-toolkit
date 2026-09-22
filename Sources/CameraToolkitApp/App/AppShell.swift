import AppKit
import SwiftUI

enum AppShellMode: String {
    case events
    case files

    static let defaultsKey = "CameraToolkit.mainMode"

    static func show(_ mode: AppShellMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }
}

struct AppShell: View {
    @Bindable var model: DashboardModel
    @Bindable var workspace: EventsWorkspace
    @AppStorage(AppShellMode.defaultsKey) private var mode = AppShellMode.events.rawValue

    var body: some View {
        Group {
            if mode == AppShellMode.files.rawValue {
                PhotoBrowserView(model: model)
            } else {
                EventsRootView(model: model, workspace: workspace)
            }
        }
        .onAppear {
            model.refreshAllIfStale(maxAge: 0)
            workspace.observeVolumeChanges()
            workspace.refreshConnectivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAllIfStale()
            workspace.refreshConnectivityIfStale()
        }
    }
}
