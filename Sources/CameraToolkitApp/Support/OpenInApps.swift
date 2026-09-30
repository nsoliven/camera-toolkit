import AppKit
import CameraToolkitCore
import SwiftUI
import UniformTypeIdentifiers

/// Looks up an installed application by its bundle name — "Gyroflow",
/// "DaVinci Resolve" — so a menu can offer an app only when it is really
/// installed. Names instead of `urlForApplication(withBundleIdentifier:)`:
/// a guessed bundle id is easy to get wrong (`xyz.gyroflow`,
/// `com.blackmagic-design.DaVinciResolve`) and a wrong guess silently hides
/// a real install.
protocol ApplicationLookup: Sendable {
    /// Installed bundle URL for `name`, or nil when no such app is found.
    func applicationURL(named name: String) -> URL?
}

/// The real lookup: an installed-app index over the standard application
/// folders, keyed by bundle file name and the bundle's own display/bundle
/// names from Info.plist.
///
/// The obvious `NSWorkspace` queries can't answer "is Gyroflow installed":
/// `urlsForApplications(toOpen:)` and its content-type variant only list
/// apps that claim the file's type — Gyroflow registers no document types,
/// so a real install would be hidden — and the bundle-identifier variant is
/// the guessed-id path this type exists to avoid. Scanning the app folders
/// by name covers every install macOS can launch, including nested bundles
/// like `/Applications/DaVinci Resolve/DaVinci Resolve.app`.
///
/// The index is cached briefly so re-rendering a menu never rescans the
/// folders; a newly installed app appears within `ttl` seconds.
final class InstalledApplicationLookup: ApplicationLookup, @unchecked Sendable {
    static let shared = InstalledApplicationLookup()

    /// Folders scanned for `.app` bundles — injectable so tests can point
    /// the lookup at a fixture directory instead of the real /Applications.
    let roots: [URL]
    /// How long the name index is trusted before the next lookup rebuilds
    /// it. Short enough that a freshly installed app shows up quickly.
    let ttl: TimeInterval

    private let fileManager: FileManager
    private let lock = NSLock()
    private var cache: (builtAt: Date, byName: [String: URL])?

    init(fileManager: FileManager = .default, roots: [URL]? = nil, ttl: TimeInterval = 30) {
        self.fileManager = fileManager
        self.ttl = ttl
        self.roots = roots ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    func applicationURL(named name: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let cache, Date().timeIntervalSince(cache.builtAt) < ttl {
            return cache.byName[Self.key(for: name)]
        }
        let rebuilt = (builtAt: Date(), byName: buildIndex())
        cache = rebuilt
        return rebuilt.byName[Self.key(for: name)]
    }

    private static func key(for name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private func buildIndex() -> [String: URL] {
        var byName: [String: URL] = [:]
        for bundleURL in scanForAppBundles() {
            byName[Self.key(for: bundleURL.deletingPathExtension().lastPathComponent)] = bundleURL
            guard let bundle = Bundle(url: bundleURL) else { continue }
            // A versioned file name ("Foo 2.app") still answers to its real
            // bundle and display names.
            for infoKey in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = bundle.object(forInfoDictionaryKey: infoKey) as? String, !name.isEmpty {
                    byName[Self.key(for: name)] = bundleURL
                }
            }
        }
        return byName
    }

    /// Every `.app` at depth ≤ 2 of each root — direct children plus one
    /// level of folders (Utilities, Setapp, the DaVinci Resolve folder).
    private func scanForAppBundles() -> [URL] {
        var bundles: [URL] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in false }
            ) else { continue }
            for case let url as URL in enumerator {
                if enumerator.level > 2 {
                    enumerator.skipDescendants()
                    continue
                }
                if url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
                    bundles.append(url)
                }
            }
        }
        return bundles
    }
}

/// One destination the Open menu can offer. `offered` is the fixed display
/// order; `installedApps(lookup:)` filters it to what is actually installed.
struct OpenInApp: Equatable, Identifiable {
    var id: String { name }
    /// Bundle/display name used for the install lookup and shown as the
    /// menu title.
    let name: String
    /// Menu-item tooltip: what opening here is for.
    let help: String

    static let gyroflow = OpenInApp(
        name: "Gyroflow",
        help: "Open this file in Gyroflow for stabilization."
    )
    static let daVinciResolve = OpenInApp(
        name: "DaVinci Resolve",
        help: "Open this file in DaVinci Resolve for color grading."
    )
    static let finalCutPro = OpenInApp(
        name: "Final Cut Pro",
        help: "Open this file in Final Cut Pro for editing and color."
    )
    static let photomator = OpenInApp(
        name: "Photomator",
        help: "Open this file in Photomator."
    )

    /// Apps the Open menus offer, in display order — the stabilizer first,
    /// then the color apps. Anything not installed is left out entirely:
    /// no disabled rows, no download prompts.
    static let offered: [OpenInApp] = [gyroflow, daVinciResolve, finalCutPro, photomator]

    /// `offered` filtered to installed apps, still in display order.
    static func installedApps(lookup: any ApplicationLookup) -> [OpenInApp] {
        offered.filter { lookup.applicationURL(named: $0.name) != nil }
    }
}

/// The open actions behind the shared menu rows. Everything funnels through
/// `NSWorkspace` — an activating configuration brings the chosen app
/// forward — and nothing here writes to disk.
enum OpenInAppActions {
    /// Opens each file with the system-default handler for its type.
    static func openWithDefaultApplications(_ urls: [URL]) {
        urls.forEach { NSWorkspace.shared.open($0) }
    }

    /// Opens the files in a specific installed app and brings it forward.
    /// The app is re-resolved at click time so a stale row can never open
    /// the wrong destination — an app gone missing simply does nothing.
    static func open(_ urls: [URL], in app: OpenInApp, lookup: any ApplicationLookup) {
        guard !urls.isEmpty, let appURL = lookup.applicationURL(named: app.name) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration)
    }

    /// The pick-any-app panel: choose any .app on disk and open the files
    /// with it, activated.
    @MainActor
    static func chooseApplication(toOpen urls: [URL]) {
        guard !urls.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.title = "Choose an Application"
        panel.message = "Choose an app to open \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) selected items")."
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let applicationURL = panel.url else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration)
    }
}

/// The menu rows shared by the preview header's Open menu and the file
/// browser's Open With menu: every installed destination app first, then
/// the system default and the pick-any-app panel.
struct OpenInAppMenuItems: View {
    let urls: [URL]
    var lookup: any ApplicationLookup = InstalledApplicationLookup.shared
    var bundleResolver: any BundleApplicationResolving = BundleWorkspaceResolver.shared

    var body: some View {
        let apps = OpenInApp.installedApps(lookup: lookup)
        // A 360 clip's own editor leads the list when it is installed.
        if DJIStudio.isOffered(for: urls, resolver: bundleResolver) {
            Button(DJIStudio.name) {
                DJIStudio.open(urls, resolver: bundleResolver)
            }
            .help(DJIStudio.help)
            Divider()
        }
        ForEach(apps) { app in
            Button(app.name) {
                OpenInAppActions.open(urls, in: app, lookup: lookup)
            }
            .help(app.help)
        }
        if !apps.isEmpty {
            Divider()
        }
        Button("Default Application") {
            OpenInAppActions.openWithDefaultApplications(urls)
        }
        Button("Choose Application…") {
            OpenInAppActions.chooseApplication(toOpen: urls)
        }
    }
}

// MARK: - DJI Studio

/// Resolves an installed app by bundle identifier. A protocol so tests can
/// say "installed" or "not installed" without touching LaunchServices.
protocol BundleApplicationResolving: Sendable {
    func applicationURL(bundleIdentifier: String) -> URL?
}

/// The real resolver: `NSWorkspace.urlForApplication(withBundleIdentifier:)`,
/// remembered briefly so a menu re-rendering never re-queries
/// LaunchServices. A newly installed app appears within `ttl` seconds.
final class BundleWorkspaceResolver: BundleApplicationResolving, @unchecked Sendable {
    static let shared = BundleWorkspaceResolver()

    let ttl: TimeInterval
    private let lock = NSLock()
    private var cache: [String: (resolvedAt: Date, url: URL?)] = [:]

    init(ttl: TimeInterval = 30) {
        self.ttl = ttl
    }

    func applicationURL(bundleIdentifier: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[bundleIdentifier], Date().timeIntervalSince(hit.resolvedAt) < ttl {
            return hit.url
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        cache[bundleIdentifier] = (Date(), url)
        return url
    }
}

/// DJI Studio, DJI's desktop editor for Osmo 360 footage — the primary
/// external-open target for `.OSV`/`.LRF`. Offered only when LaunchServices
/// knows the app; resolved by bundle id, never by a hard-coded path.
/// Photos keep going to Photomator.
enum DJIStudio {
    static let bundleIdentifier = "com.light.studio"
    static let name = "DJI Studio"
    static let help = "Open this 360° clip in DJI Studio for full-quality stitching, reframing and export."

    /// The files DJI Studio should receive for `urls`: only the 360 ones.
    static func targets(in urls: [URL]) -> [URL] {
        urls.filter(DJI360Media.isDJI360File)
    }

    /// The primaries of `items` that are 360 clips. An OSV+LRF item hands
    /// over just the OSV — DJI Studio finds its proxy itself.
    static func targets(for items: [OrganizeItem]) -> [URL] {
        targets(in: items.map(\.primary.url))
    }

    static func applicationURL(resolver: any BundleApplicationResolving) -> URL? {
        resolver.applicationURL(bundleIdentifier: bundleIdentifier)
    }

    /// Whether an "Open in DJI Studio" action belongs next to `urls`: at
    /// least one 360 file, and the app resolvable.
    static func isOffered(for urls: [URL], resolver: any BundleApplicationResolving) -> Bool {
        !targets(in: urls).isEmpty && applicationURL(resolver: resolver) != nil
    }

    /// Opens the 360 files among `urls` in DJI Studio, activated. Returns
    /// false — doing nothing — when there are none or the app is gone.
    @discardableResult
    static func open(_ urls: [URL], resolver: any BundleApplicationResolving = BundleWorkspaceResolver.shared) -> Bool {
        let files = targets(in: urls)
        guard !files.isEmpty, let app = applicationURL(resolver: resolver) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: configuration)
        return true
    }
}

/// The default external open (O / ⌘O): 360 clips go to DJI Studio when it
/// is installed, everything else — and the clips when it is not — to
/// Photomator as before.
enum PreferredExternalOpen {
    /// How `urls` split between the two destinations.
    static func route(
        _ urls: [URL],
        resolver: any BundleApplicationResolving
    ) -> (djiStudio: [URL], photomator: [URL]) {
        guard DJIStudio.applicationURL(resolver: resolver) != nil else { return ([], urls) }
        let studio = DJIStudio.targets(in: urls)
        guard !studio.isEmpty else { return ([], urls) }
        return (studio, urls.filter { !DJI360Media.isDJI360File($0) })
    }

    static func open(_ urls: [URL], resolver: any BundleApplicationResolving = BundleWorkspaceResolver.shared) {
        let routed = route(urls, resolver: resolver)
        if !routed.djiStudio.isEmpty {
            DJIStudio.open(routed.djiStudio, resolver: resolver)
        }
        if !routed.photomator.isEmpty {
            PhotomatorLauncher.open(routed.photomator)
        }
    }
}
