import Foundation

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

    /// The first Gyroflow in `roots` (a headless-capable one preferred over
    /// an App Store one), or nil.
    public static func locate(roots: [URL] = defaultSearchRoots(), fileManager: FileManager = .default) -> GyroflowInstallation? {
        var found: [GyroflowInstallation] = []
        for root in roots {
            for name in ["Gyroflow.app", "Gyroflow/Gyroflow.app"] {
                if let installation = inspect(appURL: root.appendingPathComponent(name, isDirectory: true), fileManager: fileManager) {
                    found.append(installation)
                }
            }
        }
        return found.first { $0.canRunHeadless } ?? found.first
    }

    /// What the bundle at `appURL` is, or nil when it is not a Gyroflow app.
    public static func inspect(appURL: URL, fileManager: FileManager = .default) -> GyroflowInstallation? {
        let executable = appURL.appendingPathComponent("Contents/MacOS/gyroflow", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: executable.path) else { return nil }
        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
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

/// Whether stabilization can run here, and what to tell the person if not.
public enum StabilizerAvailability: Equatable, Sendable {
    case ready(GyroflowInstallation)
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
        case .notInstalled, .appStoreBuild: nil
        }
    }

    public var isReady: Bool { installation != nil }

    /// One line for the panel when stabilization cannot run.
    public var problem: String? {
        switch self {
        case .ready: nil
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
/// `gyroflow <video> -f -t <suffix> --stdout-progress --preset <file>`.
///
/// Everything that decides the render — stabilization, trim and output —
/// goes in the preset *file*: Gyroflow rewrites `'` to `"` in inline JSON,
/// which would break a path with an apostrophe in it, but reads a preset
/// file as it is.
public enum GyroflowCommand {
    /// A suffix no real file has, so Gyroflow's check for its own default
    /// output name (before the preset moves the output) never trips.
    public static let scratchSuffix = "_ctk-stabilizing"

    public static func arguments(input: URL, presetFile: URL) -> [String] {
        [input.path, "-f", "-t", scratchSuffix, "--stdout-progress", "--preset", presetFile.path]
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
