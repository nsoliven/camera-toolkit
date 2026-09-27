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
                // After the first connectivity pass: the NAS check, the
                // launch auto-connect, and the Wi-Fi guard, all off the
                // main actor.
                workspace.startNASConnection()
            }
            .onChange(of: model.configurationRevision) { _, _ in
                workspace.nasSettingsChanged()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshAllIfStale()
                workspace.refreshConnectivityIfStale()
            }
    }
}
