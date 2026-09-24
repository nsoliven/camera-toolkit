import AppKit
import CameraToolkitCore

/// App-side wiring for `CrashReporter`: start capture before AppKit runs,
/// check the previous run after launch, and say so when it crashed. The
/// file work and the show-or-not decision live in `CameraToolkitCore`.
@MainActor
enum CrashReporting {
    static let alertTitle = "Camera Toolkit quit unexpectedly last time"

    /// Built on first use — only `CameraToolkitApplication.main` starts
    /// it, so tests never touch the real Logs folder.
    private static let reporter = CrashReporter(app: CrashAppInfo.from(bundle: .main))

    /// First thing in `main`: exceptions AppKit would otherwise log and
    /// swallow now reach the uncaught-exception handler and end the
    /// process with a crash log, instead of leaving the app running in
    /// an unknown state.
    static func start() {
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        reporter.start()
    }

    /// Off the main thread, a few seconds after launch — the system's
    /// crash report can land a moment after the crash, and nothing
    /// launch-critical waits on this.
    static func checkPreviousRunSoon() {
        let reporter = reporter
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(3))
            guard let notice = reporter.checkPreviousRun() else { return }
            await MainActor.run { present(notice) }
        }
    }

    /// A normal quit: the next launch will not look for a crash.
    static func markCleanExit() {
        reporter.markCleanExit()
    }

    static func present(_ notice: CrashNotice) {
        let alert = makeAlert(for: notice)
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertSecondButtonReturn:
                NSWorkspace.shared.activateFileViewerSelecting(notice.files)
            case .alertThirdButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(notice.details, forType: .string)
            default:
                break
            }
        }
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.attachedSheet == nil }) {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// OK first so Return dismisses it; then Show Log in Finder and Copy
    /// Details.
    static func makeAlert(for notice: CrashNotice) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = alertTitle
        let reason = notice.reason.count > 300 ? String(notice.reason.prefix(300)) + "…" : notice.reason
        alert.informativeText = "\(reason)\n\nA crash log was saved automatically."
        alert.addButton(withTitle: "OK")
        let show = alert.addButton(withTitle: "Show Log in Finder")
        show.isEnabled = !notice.files.isEmpty
        alert.addButton(withTitle: "Copy Details")
        return alert
    }
}
