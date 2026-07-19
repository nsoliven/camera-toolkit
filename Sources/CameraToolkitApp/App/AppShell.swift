import AppKit
import SwiftUI

struct AppShell: View {
    @Bindable var model: DashboardModel

    var body: some View {
        PhotoBrowserView(model: model)
        .onAppear {
            model.refreshAllIfStale(maxAge: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAllIfStale()
        }
    }

}
