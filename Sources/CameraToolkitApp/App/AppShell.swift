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
            // Watched from a view of its own: the shell would otherwise be
            // asked to build the whole window again for every settings write.
            .background { NASSettingsWatcher(model: model, workspace: workspace) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshAllIfStale()
                workspace.refreshConnectivityIfStale()
            }
    }
}

/// Tells the workspace when a setting changed that the NAS connection reads.
private struct NASSettingsWatcher: View {
    let model: DashboardModel
    let workspace: EventsWorkspace

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: model.configurationRevision) { _, _ in
                workspace.nasSettingsChanged()
            }
    }
}
