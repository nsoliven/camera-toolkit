import Darwin
import Foundation

/// The hidden `--migrate-layout` command line of the app binary:
///
/// ```
/// CameraToolkit --migrate-layout --dry-run [--json <plan.json>]
/// CameraToolkit --migrate-layout --execute --plan <plan.json>
/// CameraToolkit --migrate-layout --resume <journal.json>
/// CameraToolkit --migrate-layout --undo <journal.json>
///     [--support-dir <folder>]    (or CAMERA_TOOLKIT_SUPPORT_DIR)
/// ```
///
/// Without an override it reads the app's normal `config.json` and the
/// catalog that configuration names. With `--support-dir` it reads
/// `<folder>/config.json` and `<folder>/catalog.sqlite` — and only those,
/// whatever catalog path the copied configuration names — so a dry run can
/// work from scratch copies.
public enum LayoutMigrationCommand {
    public static let flag = "--migrate-layout"
    public static let supportDirectoryEnvironmentKey = "CAMERA_TOOLKIT_SUPPORT_DIR"

    public enum Mode: Equatable, Sendable {
        case dryRun(jsonPath: String?)
        case execute(planPath: String)
        case resume(journalPath: String)
        case undo(journalPath: String)
    }

    public struct Arguments: Equatable, Sendable {
        public var mode: Mode
        public var supportDirectory: String?
    }

    public struct Context {
        public var supportFolder: URL
        public var configurationURL: URL
        public var catalogURL: URL
        public var configuration: AppConfiguration
        public var supportOverridden: Bool
    }

    public static let usage = """
    usage: CameraToolkit --migrate-layout --dry-run [--json <plan.json>]
           CameraToolkit --migrate-layout --execute --plan <plan.json>
           CameraToolkit --migrate-layout --resume <journal.json>
           CameraToolkit --migrate-layout --undo <journal.json>
           options: --support-dir <folder>  (default: the app's Application Support folder;
                                             env CAMERA_TOOLKIT_SUPPORT_DIR also works)
    """

    public static func parse(_ arguments: [String], environment: [String: String] = [:]) throws -> Arguments {
        var args = Array(arguments.drop { $0 != flag }.dropFirst())
        var support = environment[supportDirectoryEnvironmentKey]
        var json: String?
        var plan: String?
        var modes: [Mode] = []
        func value(after option: String) throws -> String {
            guard let index = args.firstIndex(of: option), index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                throw ToolkitError.commandFailed("\(option) needs a path.\n\(usage)")
            }
            let found = args[index + 1]
            args.removeSubrange(index...(index + 1))
            return found
        }
        if args.contains("--support-dir") { support = try value(after: "--support-dir") }
        if args.contains("--json") { json = try value(after: "--json") }
        if args.contains("--plan") { plan = try value(after: "--plan") }
        if args.contains("--resume") { modes.append(.resume(journalPath: try value(after: "--resume"))) }
        if args.contains("--undo") { modes.append(.undo(journalPath: try value(after: "--undo"))) }
        if let index = args.firstIndex(of: "--dry-run") {
            args.remove(at: index)
            modes.append(.dryRun(jsonPath: json))
            json = nil
        }
        if let index = args.firstIndex(of: "--execute") {
            args.remove(at: index)
            guard let plan else { throw ToolkitError.commandFailed("--execute needs --plan <plan.json>.\n\(usage)") }
            modes.append(.execute(planPath: plan))
        } else if plan != nil {
            throw ToolkitError.commandFailed("--plan only goes with --execute.\n\(usage)")
        }
        guard json == nil else { throw ToolkitError.commandFailed("--json only goes with --dry-run.\n\(usage)") }
        guard args.isEmpty else { throw ToolkitError.commandFailed("Unknown argument(s): \(args.joined(separator: " ")).\n\(usage)") }
        guard modes.count == 1, let mode = modes.first else {
            throw ToolkitError.commandFailed("Pick exactly one of --dry-run, --execute, --resume, --undo.\n\(usage)")
        }
        return Arguments(mode: mode, supportDirectory: support.map { NSString(string: $0).expandingTildeInPath })
    }

    /// Resolves the folders and reads `config.json`. Never writes.
    public static func context(supportDirectory: String?, defaultSupportFolder: URL) throws -> Context {
        let support = supportDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultSupportFolder
        let configurationURL = support.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            throw ToolkitError.commandFailed("There is no config.json in \(support.path).")
        }
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: configurationURL))
        let catalogURL: URL
        if supportDirectory != nil {
            catalogURL = support.appendingPathComponent("catalog.sqlite")
        } else {
            let path = NSString(string: configuration.catalogDatabasePath).expandingTildeInPath
            catalogURL = path.isEmpty ? support.appendingPathComponent("catalog.sqlite") : URL(fileURLWithPath: path)
        }
        return Context(
            supportFolder: support.standardizedFileURL,
            configurationURL: configurationURL.standardizedFileURL,
            catalogURL: catalogURL.standardizedFileURL,
            configuration: configuration,
            supportOverridden: supportDirectory != nil
        )
    }

    /// Runs the command; returns the process exit status. `isAppRunning`
    /// reports another Camera Toolkit process (the app passes an
    /// `NSRunningApplication` check); the executor also scans the process
    /// table itself.
    public static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultSupportFolder: URL,
        isAppRunning: @escaping () -> Bool = { false },
        output: @escaping (String) -> Void = { print($0) }
    ) -> Int32 {
        // Refuse under a live app: the caller's check (NSRunningApplication
        // in the app binary) or any other CameraToolkit process.
        let running = { isAppRunning() || LayoutMigrationAppGuard.otherInstanceIsRunning() }
        do {
            let parsed = try parse(arguments, environment: environment)
            let context = try context(supportDirectory: parsed.supportDirectory, defaultSupportFolder: defaultSupportFolder)
            output("Support folder: \(context.supportFolder.path)\(context.supportOverridden ? " (override)" : "")")
            output("Configuration:  \(context.configurationURL.path)")
            output("Catalog:        \(context.catalogURL.path)")
            switch parsed.mode {
            case .dryRun(let jsonPath):
                if running() {
                    output("Note: Camera Toolkit is running. The plan is read-only, but it can go stale; quit the app before executing.")
                }
                let plan = try LayoutMigrationPlanner().plan(.init(
                    configuration: context.configuration,
                    supportFolder: context.supportFolder,
                    configurationURL: context.configurationURL,
                    catalogURL: context.catalogURL
                ))
                output(plan.summaryText())
                if let jsonPath {
                    let url = URL(fileURLWithPath: NSString(string: jsonPath).expandingTildeInPath)
                    guard !FileManager.default.fileExists(atPath: url.path) else {
                        throw ToolkitError.commandFailed("\(url.path) already exists; the plan was not written. Pick a new path.")
                    }
                    try plan.jsonData().write(to: url, options: .withoutOverwriting)
                    output("Plan written to \(url.path) (sha256 \(try plan.digest()))")
                }
                return plan.isExecutable ? 0 : 2
            case .execute(let planPath):
                let plan = try LayoutMigrationPlan.read(URL(fileURLWithPath: NSString(string: planPath).expandingTildeInPath))
                let executor = LayoutMigrationExecutor(context: context, isAppRunning: running, log: output)
                let report = try executor.execute(plan)
                output(report.text)
                return report.succeeded ? 0 : 1
            case .resume(let journalPath):
                let executor = LayoutMigrationExecutor(context: context, isAppRunning: running, log: output)
                let report = try executor.resume(journalURL: URL(fileURLWithPath: NSString(string: journalPath).expandingTildeInPath))
                output(report.text)
                return report.succeeded ? 0 : 1
            case .undo(let journalPath):
                let executor = LayoutMigrationExecutor(context: context, isAppRunning: running, log: output)
                let report = try executor.undo(journalURL: URL(fileURLWithPath: NSString(string: journalPath).expandingTildeInPath))
                output(report.text)
                return report.succeeded ? 0 : 1
            }
        } catch {
            output("error: \(error.localizedDescription)")
            return 1
        }
    }
}

/// Finds another running Camera Toolkit process by executable path, so the
/// executor refuses to move files or write the catalog under a live app.
public enum LayoutMigrationAppGuard {
    /// True when a process other than this one runs an executable named
    /// `CameraToolkit` (the app bundle's binary or a `swift run` build).
    public static func otherInstanceIsRunning(executableName: String = "CameraToolkit") -> Bool {
        let own = getpid()
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return false }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != own {
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { continue }
            let executable = String(cString: path)
            if (executable as NSString).lastPathComponent == executableName {
                return true
            }
        }
        return false
    }
}
