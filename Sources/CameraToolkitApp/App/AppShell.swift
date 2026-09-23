import AppKit
import SwiftUI

struct AppShell: View {
    @Bindable var model: DashboardModel
    @Bindable var workspace: EventsWorkspace

    var body: some View {
        EventsRootView(model: model, workspace: workspace)
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
