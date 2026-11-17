import CoreServices
import Foundation
import Security

/// An installed Gyroflow, the free (GPL) stabilizer this app drives from
/// the command line. Gyroflow is never bundled or downloaded by the app: it
/// is found where the person installed it.
public struct GyroflowInstallation: Equatable, Sendable {
    public var appURL: URL
    public var executableURL: URL
    public var version: String?
    /// The Mac App Store build is sandboxed: its command line cannot open
    /// a file it was not handed through the GUI, so it cannot render in the
    /// background. The download from gyroflow.xyz can.
    public var isAppStoreBuild: Bool

    public init(appURL: URL, executableURL: URL, version: String?, isAppStoreBuild: Bool) {
        self.appURL = appURL
        self.executableURL = executableURL
        self.version = version
        self.isAppStoreBuild = isAppStoreBuild
    }

    public var canRunHeadless: Bool { !isAppStoreBuild }

    public static let downloadPage = URL(string: "https://gyroflow.xyz/download")!

    /// Where Gyroflow is looked for: the standard application folders.
    public static func defaultSearchRoots(fileManager: FileManager = .default) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// Gyroflow's bundle identifier, the same for the App Store build and
    /// the download.
    public static let bundleIdentifier = "xyz.gyroflow"

    /// Every copy LaunchServices knows under Gyroflow's bundle identifier
    /// (wherever it was installed). Read-only: nothing is opened.
    public static func registeredAppURLs() -> [URL] {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?.takeRetainedValue() as? [URL] else {
            return []
        }
        return urls
    }

    /// The oldest Gyroflow whose command line this app speaks (the
    /// preset-file output and `--stdout-progress` lines of 1.6).
    public static let minimumVersion = [1, 6]

    /// Places a copy is never run from, even when LaunchServices knows it:
    /// the Trash, mounted disk images and other volumes, translocated
    /// quarantine copies, Downloads, and build folders.
    public static func isExcludedLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix("/Volumes/") { return true }
        for part in ["/.Trash/", "/.Trashes/", "/AppTranslocation/", "/Downloads/", "/DerivedData/", "/private/var/folders/", "/private/tmp/"] where path.contains(part) {
            return true
        }
        return false
    }

    /// True when `version` ("1.6.3") is at least `minimumVersion`.
    public static func isSupportedVersion(_ version: String?) -> Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for (index, minimum) in minimumVersion.enumerated() {
            let part = index < parts.count ? parts[index] : 0
            if part != minimum { return part > minimum }
        }
        return true
    }

    /// The Gyroflow to drive: among the copies in `roots` and `registered`
    /// (LaunchServices), one that can run headless — not the App Store
    /// build, not in an excluded place, version 1.6 or later, and signed by
    /// Gyroflow's own Developer ID (`isTrusted`) — is preferred, the first
    /// found wins. With only an App Store copy, that one (so the app can say
    /// why it can't render); else nil. Reads signatures: run it off the
    /// main actor.
    public static func locate(
        roots: [URL] = defaultSearchRoots(),
        registered: [URL] = registeredAppURLs(),
        fileManager: FileManager = .default,
        isTrusted: (URL) -> Bool = { GyroflowSignature.isGenuineDownload($0) }
    ) -> GyroflowInstallation? {
        var candidates: [URL] = []
        for root in roots {
            candidates.append(root.appendingPathComponent("Gyroflow.app", isDirectory: true))
            candidates.append(root.appendingPathComponent("Gyroflow/Gyroflow.app", isDirectory: true))
        }
        candidates.append(contentsOf: registered.filter { !isExcludedLocation($0) })
        var seen: Set<String> = []
        var headless: GyroflowInstallation?
        var appStore: GyroflowInstallation?
        for url in candidates where seen.insert(url.standardizedFileURL.resolvingSymlinksInPath().path).inserted {
            guard let installation = inspect(appURL: url, fileManager: fileManager) else { continue }
            if installation.isAppStoreBuild {
                if appStore == nil { appStore = installation }
            } else if headless == nil, isSupportedVersion(installation.version), isTrusted(url) {
                headless = installation
            }
        }
        return headless ?? appStore
    }

    /// What the bundle at `appURL` is, or nil when it is not a Gyroflow app.
    public static func inspect(appURL: URL, fileManager: FileManager = .default) -> GyroflowInstallation? {
        let executable = appURL.appendingPathComponent("Contents/MacOS/gyroflow", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: executable.path) else { return nil }
        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        guard (info?["CFBundleIdentifier"] as? String) == bundleIdentifier else { return nil }
        let version = info?["CFBundleShortVersionString"] as? String
        let receipt = appURL.appendingPathComponent("Contents/_MASReceipt", isDirectory: true)
        return GyroflowInstallation(
            appURL: appURL,
            executableURL: executable,
            version: version,
            isAppStoreBuild: fileManager.fileExists(atPath: receipt.path)
        )
    }
}

/// Checks that a Gyroflow bundle is the real download: intact, and signed
/// with Gyroflow's own Developer ID (team RR3ZC2L4DF), bundle id
/// `xyz.gyroflow`. A tampered or look-alike bundle is never run.
public enum GyroflowSignature {
    public static let teamIdentifier = "RR3ZC2L4DF"
    /// Developer ID Application, Gyroflow's team, Gyroflow's bundle id.
    public static let requirement = "identifier \"xyz.gyroflow\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    public static func isGenuineDownload(_ appURL: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement_ as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess
    }

    private static var requirement_: String { requirement }
}

/// Whether stabilization can run here, and what to tell the person if not.
public enum StabilizerAvailability: Equatable, Sendable {
    case ready(GyroflowInstallation)
    /// Still looking (the search reads code signatures off the main actor).
    case checking
    case notInstalled
    /// Installed from the Mac App Store, which cannot render headless.
    case appStoreBuild(GyroflowInstallation)

    public init(_ installation: GyroflowInstallation?) {
        switch installation {
        case nil: self = .notInstalled
        case let installation? where installation.canRunHeadless: self = .ready(installation)
        case let installation?: self = .appStoreBuild(installation)
        }
    }

    public var installation: GyroflowInstallation? {
        switch self {
        case .ready(let installation): installation
        case .checking, .notInstalled, .appStoreBuild: nil
        }
    }

    public var isReady: Bool { installation != nil }

    /// One line for the panel when stabilization cannot run.
    public var problem: String? {
        switch self {
        case .ready: nil
        case .checking: "Looking for Gyroflow…"
        case .notInstalled:
            "Needs Gyroflow (free). Install it from gyroflow.xyz, then stabilization works here."
        case .appStoreBuild:
            "The App Store version of Gyroflow can’t render in the background (Apple’s sandbox). Install the free download from gyroflow.xyz instead — Open in Gyroflow keeps working either way."
        }
    }
}

/// The picture format Gyroflow writes.
public enum StabilizedOutputCodec: String, Sendable, Equatable {
    /// ProRes 422 HQ, 10-bit 4:2:2: the log signal goes through untouched
    /// for grading afterwards.
    case proResHQ
    /// ProRes 422 Proxy, still 10-bit: small, for the 3-second preview.
    case proResProxy

    /// Apple's target data rate at 1920×1080, 29.97 fps.
    public var megabitsAt1080p30: Double {
        switch self {
        case .proResHQ: 220
        case .proResProxy: 45
        }
    }

    var gyroflowCodecOptions: String {
        switch self {
        case .proResHQ: "HQ"
        case .proResProxy: "Proxy"
        }
    }
}

/// One Gyroflow run.
public struct GyroflowJob: Sendable, Equatable {
    public var input: URL
    /// Where Gyroflow writes (a partial name; the caller renames it in).
    public var output: URL
    public var settings: StabilizationSettings
    /// Seconds into the clip; nil renders the whole clip.
    public var trim: ClosedRange<Double>?
    public var codec: StabilizedOutputCodec
    /// Written into the file's comment (`StabilizedRenderNaming.tag`).
    public var comment: String

    public init(input: URL, output: URL, settings: StabilizationSettings, trim: ClosedRange<Double>? = nil, codec: StabilizedOutputCodec = .proResHQ, comment: String = "") {
        self.input = input
        self.output = output
        self.settings = settings
        self.trim = trim
        self.codec = codec
        self.comment = comment
    }
}

/// The command line for Gyroflow 1.6's headless mode:
/// `gyroflow <video> -t <suffix> --stdout-progress --preset <file>`.
///
/// Everything that decides the render — stabilization, trim and output —
/// goes in the preset *file*: Gyroflow rewrites `'` to `"` in inline JSON,
/// which would break a path with an apostrophe in it, but reads a preset
/// file as it is.
public enum GyroflowCommand {
    /// A suffix no real file has, so Gyroflow's check for its own default
    /// output name (before the preset moves the output) never trips.
    public static let scratchSuffix = "_ctk-stabilizing"

    /// No `-f`: Gyroflow never overwrites anything. The real output path
    /// (a fresh partial name) comes from the preset; the scratch suffix
    /// only names the default it would have used.
    public static func arguments(input: URL, presetFile: URL) -> [String] {
        [input.path, "-t", scratchSuffix, "--stdout-progress", "--preset", presetFile.path]
    }

    /// Files Gyroflow could write beside the source under its default name
    /// (it should not: the preset moves the output). Only these exact
    /// names are ever removed, and only when a run made them.
    public static func strayOutputs(beside input: URL) -> [URL] {
        let stem = input.deletingPathExtension().lastPathComponent + scratchSuffix
        let folder = input.deletingLastPathComponent()
        return ["mov", "mp4", "MOV", "MP4"].map { folder.appendingPathComponent("\(stem).\($0)", isDirectory: false) }
    }

    /// The preset as a JSON object (a `.gyroflow` file without a video):
    /// Gyroflow's "Default" smoothing at the chosen strength, horizon lock
    /// only when asked, dynamic cropping (adaptive zoom, 4 s window), lens
    /// correction from the camera's own data, the clip's size and frame
    /// rate, 10-bit ProRes, audio kept as PCM.
    public static func preset(for job: GyroflowJob) -> [String: Any] {
        let smoothing = job.settings.smoothing
        var preset: [String: Any] = [
            "version": 2,
            "stabilization": [
                "method": "Default",
                "smoothing_params": [
                    ["name": "smoothness", "value": smoothing.gyroflowSmoothness],
                    ["name": "max_smoothness", "value": smoothing.gyroflowMaxSmoothness],
                    ["name": "per_axis", "value": 0],
                ],
                "fov": 1.0,
                "adaptive_zoom_window": 4.0,
                "adaptive_zoom_method": 1,
                "lens_correction_amount": 1.0,
                "horizon_lock_amount": job.settings.horizonLock ? 100.0 : 0.0,
                "horizon_lock_roll": 0.0,
                "use_gravity_vectors": false,
            ] as [String: Any],
            "output": [
                "output_path": job.output.path,
                "codec": "ProRes",
                "codec_options": job.codec.gyroflowCodecOptions,
                "use_gpu": true,
                "audio": true,
                "audio_codec": "PCM (s16le)",
                "pad_with_black": false,
                "preserve_other_tracks": false,
                "export_trims_separately": false,
                "metadata": ["comment": job.comment],
            ] as [String: Any],
        ]
        if let trim = job.trim {
            preset["trim_ranges_ms"] = [[max(0, trim.lowerBound) * 1000, max(trim.lowerBound, trim.upperBound) * 1000]]
        }
        return preset
    }

    public static func presetData(for job: GyroflowJob) throws -> Data {
        try JSONSerialization.data(withJSONObject: preset(for: job), options: [.sortedKeys])
    }
}

/// What a line of Gyroflow's `--stdout-progress` output says.
public enum GyroflowOutputLine: Equatable, Sendable {
    /// Matching gyro to video (only when the file needs it).
    case synchronizing(Double)
    case rendering(frame: Int, total: Int)
    case completed
    case failed
    /// An `[ERROR]` line: the message, without the log prefix.
    case error(String)
    case other

    public static func parse(_ raw: String) -> GyroflowOutputLine {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = line.range(of: "Rendering progress: ") {
            let rest = line[range.upperBound...]
            let numbers = rest.prefix { $0 != " " }.split(separator: "/")
            if numbers.count == 2, let frame = Int(numbers[0]), let total = Int(numbers[1]) {
                return .rendering(frame: frame, total: total)
            }
            return .other
        }
        if let range = line.range(of: "Synchronization progress: ") {
            let value = line[range.upperBound...].prefix { $0.isNumber || $0 == "." }
            return Double(value).map { .synchronizing(min(1, max(0, $0 / 100))) } ?? .other
        }
        if line.contains("Rendering completed:") { return .completed }
        if line.contains("Rendering failed:") { return .failed }
        if line.contains("[ERROR]") {
            var message = String(line[line.range(of: "[ERROR]")!.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let error = message.range(of: "Error: ") { message = String(message[error.upperBound...]) }
            if message.hasPrefix("An error occured: ") { message = String(message.dropFirst("An error occured: ".count)) }
            return .error(message)
        }
        return .other
    }

    /// A Gyroflow error put the way the panel says it.
    public static func explain(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("unable to read the video file") {
            return "Gyroflow could not open the file. The App Store version of Gyroflow can’t read files from the command line — install the download from gyroflow.xyz."
        }
        if lower.contains("no stab data") || lower.contains("no gyro") || lower.contains("doesn't contain") {
            return "Gyroflow found no motion data it can use in this file."
        }
        if lower.contains("unsupported_lens") || lower.contains("lens profile") {
            return "Gyroflow has no lens profile for this camera and lens. Open it in Gyroflow once to pick one."
        }
        return message
    }
}
