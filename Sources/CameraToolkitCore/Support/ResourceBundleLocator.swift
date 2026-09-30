import Foundation

/// Finds a file shipped in the Core SwiftPM resource bundle without letting
/// SwiftPM's generated `Bundle.module` accessor decide on its own.
///
/// That accessor looks next to the executable's `Bundle.main.bundleURL` (the
/// `.app` root for a packaged app, which is not where `package-app.sh` puts
/// the bundle), then falls back to the absolute `.build` path compiled into
/// the binary — so an installed app silently ran the developer's build-folder
/// copy of the script, and calls `fatalError` once that folder is gone.
///
/// The locator checks, in order:
/// 1. `resourceURL/<bundle>/<file>` — `Contents/Resources` of a packaged app;
/// 2. `bundleURL/<bundle>/<file>` — next to a bare executable (`swift run`);
/// 3. `moduleBundle()` — SwiftPM's accessor, touched only when both of the
///    app's own locations miss.
///
/// Every check is a plain file-exists test, and a miss everywhere returns
/// `nil` so callers can say "not installed" instead of crashing.
public struct ResourceBundleLocator: Sendable {
    public enum Location: String, Sendable, Equatable {
        case packaged
        case appRoot
        case module
        case missing
    }

    public struct Resolution: Sendable, Equatable {
        public var url: URL?
        public var location: Location

        public init(url: URL?, location: Location) {
            self.url = url
            self.location = location
        }
    }

    /// The SwiftPM resource bundle for the `CameraToolkitCore` target.
    public static let coreBundleName = "CameraToolkit_CameraToolkitCore.bundle"

    public var resourceURL: URL?
    public var bundleURL: URL?
    public var bundleName: String
    public var moduleBundle: @Sendable () -> Bundle?
    public var fileExists: @Sendable (URL) -> Bool

    public init(
        resourceURL: URL?,
        bundleURL: URL?,
        bundleName: String = ResourceBundleLocator.coreBundleName,
        moduleBundle: @escaping @Sendable () -> Bundle?,
        fileExists: @escaping @Sendable (URL) -> Bool = { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    ) {
        self.resourceURL = resourceURL
        self.bundleURL = bundleURL
        self.bundleName = bundleName
        self.moduleBundle = moduleBundle
        self.fileExists = fileExists
    }

    /// The running process. Inside a `.app` the SwiftPM accessor is never
    /// consulted: its only remaining candidate is the build folder the
    /// binary was compiled in, which a shipped app must not depend on.
    public static var main: ResourceBundleLocator {
        let main = Bundle.main
        let insideApp = main.bundleURL.pathExtension == "app"
        // A bare executable's `resourceURL` is its own folder, the same as
        // `bundleURL`; leave it out so the log says `appRoot`, not
        // `packaged`, for `swift run`.
        return ResourceBundleLocator(
            resourceURL: insideApp ? main.resourceURL : nil,
            bundleURL: main.bundleURL,
            moduleBundle: { insideApp ? nil : Bundle.module }
        )
    }

    /// `fileName` is the resource's name inside the bundle, e.g.
    /// `face_sidecar.py`.
    public func locate(_ fileName: String) -> Resolution {
        let candidates: [(URL?, Location)] = [(resourceURL, .packaged), (bundleURL, .appRoot)]
        for (base, location) in candidates {
            guard let base else { continue }
            let url = base.appendingPathComponent(bundleName, isDirectory: true).appendingPathComponent(fileName)
            if fileExists(url) { return Resolution(url: url, location: location) }
        }
        if let bundle = moduleBundle() {
            let name = fileName as NSString
            let candidates = [
                bundle.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension),
                bundle.bundleURL.appendingPathComponent(fileName),
            ]
            if let url = candidates.compactMap({ $0 }).first(where: fileExists) {
                return Resolution(url: url, location: .module)
            }
        }
        return Resolution(url: nil, location: .missing)
    }
}

/// Resources the Core target ships, each resolved once per process.
public enum CoreResources {
    public static let faceSidecarScriptName = "face_sidecar.py"

    /// Resolved on first use and logged as `resource.resolve` with the
    /// location only (never the path).
    public static let faceSidecarScript: ResourceBundleLocator.Resolution =
        resolve(faceSidecarScriptName, with: .main)

    /// Every shipped resource, for `--print-resource-paths`.
    public static var all: [(name: String, resolution: ResourceBundleLocator.Resolution)] {
        [(faceSidecarScriptName, faceSidecarScript)]
    }

    static func resolve(_ name: String, with locator: ResourceBundleLocator) -> ResourceBundleLocator.Resolution {
        let resolution = locator.locate(name)
        DebugLog.shared.log(
            "resource.resolve",
            subsystem: .resource,
            level: resolution.url == nil ? .error : .info,
            outcome: resolution.url == nil ? .error : .ok,
            detail: "name=\(name) location=\(resolution.location.rawValue)"
        )
        return resolution
    }
}
