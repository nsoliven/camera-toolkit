import Foundation

/// The hidden `--adopt-nas` command line of the app binary — the sidebar's
/// "Found on the NAS → Add to Events", from a script:
///
/// ```
/// CameraToolkit --adopt-nas --dry-run [--folder <mirror-relative event folder>]... [--json <plan.json>]
/// CameraToolkit --adopt-nas --execute --plan <plan.json>
///     [--support-dir <folder>]    (or CAMERA_TOOLKIT_SUPPORT_DIR)
/// ```
///
/// The dry run lists the NAS and reads the catalog read-only; it writes
/// nothing but the `--json` plan. `--support-dir` works as for
/// `--migrate-layout`: `<folder>/config.json` and `<folder>/catalog.sqlite`.
public enum NASAdoptCommand {
    public static let flag = "--adopt-nas"

    public enum Mode: Equatable, Sendable {
        case dryRun(folders: [String], jsonPath: String?)
        case execute(planPath: String)
    }

    public struct Arguments: Equatable, Sendable {
        public var mode: Mode
        public var supportDirectory: String?
    }

    public static let usage = """
    usage: CameraToolkit --adopt-nas --dry-run [--folder <mirror-relative event folder>]... [--json <plan.json>]
           CameraToolkit --adopt-nas --execute --plan <plan.json>
           options: --support-dir <folder>  (default: the app's Application Support folder;
                                             env CAMERA_TOOLKIT_SUPPORT_DIR also works)
                    --folder <path>         only this NAS event folder, e.g. "2026/2026-08-21 Trip/2026-08-22 Full Card"
    """

    public static func parse(_ arguments: [String], environment: [String: String] = [:]) throws -> Arguments {
        var args = Array(arguments.drop { $0 != flag }.dropFirst())
        var support = environment[LayoutMigrationCommand.supportDirectoryEnvironmentKey]
        func value(after option: String) throws -> String {
            guard let index = args.firstIndex(of: option), index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                throw ToolkitError.commandFailed("\(option) needs a value.\n\(usage)")
            }
            let found = args[index + 1]
            args.removeSubrange(index...(index + 1))
            return found
        }
        if args.contains("--support-dir") { support = try value(after: "--support-dir") }
        let json = args.contains("--json") ? try value(after: "--json") : nil
        let plan = args.contains("--plan") ? try value(after: "--plan") : nil
        var folders: [String] = []
        while args.contains("--folder") { folders.append(try value(after: "--folder")) }
        let dryRun = args.firstIndex(of: "--dry-run").map { args.remove(at: $0) } != nil
        let execute = args.firstIndex(of: "--execute").map { args.remove(at: $0) } != nil
        guard args.isEmpty else { throw ToolkitError.commandFailed("Unknown argument(s): \(args.joined(separator: " ")).\n\(usage)") }
        let mode: Mode
        switch (dryRun, execute) {
        case (true, false):
            guard plan == nil else { throw ToolkitError.commandFailed("--plan only goes with --execute.\n\(usage)") }
            mode = .dryRun(folders: folders, jsonPath: json)
        case (false, true):
            guard let plan else { throw ToolkitError.commandFailed("--execute needs --plan <plan.json>.\n\(usage)") }
            guard folders.isEmpty, json == nil else {
                throw ToolkitError.commandFailed("--folder and --json only go with --dry-run; --execute runs exactly the plan.\n\(usage)")
            }
            mode = .execute(planPath: plan)
        default:
            throw ToolkitError.commandFailed("Pick exactly one of --dry-run, --execute.\n\(usage)")
        }
        return Arguments(mode: mode, supportDirectory: support.map { NSString(string: $0).expandingTildeInPath })
    }

    public static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultSupportFolder: URL,
        isAppRunning: @escaping () -> Bool = { false },
        output: @escaping (String) -> Void = { print($0) }
    ) -> Int32 {
        let running = { isAppRunning() || LayoutMigrationAppGuard.otherInstanceIsRunning() }
        do {
            let parsed = try parse(arguments, environment: environment)
            let context = try LayoutMigrationCommand.context(supportDirectory: parsed.supportDirectory, defaultSupportFolder: defaultSupportFolder)
            output("Support folder: \(context.supportFolder.path)\(context.supportOverridden ? " (override)" : "")")
            output("Catalog:        \(context.catalogURL.path)")
            let executor = NASAdoptExecutor(
                supportFolder: context.supportFolder,
                configurationURL: context.configurationURL,
                catalogURL: context.catalogURL,
                configuration: context.configuration,
                isAppRunning: running
            )
            switch parsed.mode {
            case .dryRun(let folders, let jsonPath):
                if running() {
                    output("Note: Camera Toolkit is running. The plan is read-only, but it can go stale; quit the app before executing.")
                }
                let started = Date()
                let plan = try executor.plan(folders: folders)
                output(plan.summaryText())
                output(String(format: "Planned in %.1f s.", Date().timeIntervalSince(started)))
                if let jsonPath {
                    let url = URL(fileURLWithPath: NSString(string: jsonPath).expandingTildeInPath)
                    guard !FileManager.default.fileExists(atPath: url.path) else {
                        throw ToolkitError.commandFailed("\(url.path) already exists; the plan was not written. Pick a new path.")
                    }
                    try plan.jsonData().write(to: url, options: .withoutOverwriting)
                    output("Plan written to \(url.path)")
                }
                return plan.isExecutable ? 0 : 2
            case .execute(let planPath):
                let plan = try NASAdoptPlan.read(URL(fileURLWithPath: NSString(string: planPath).expandingTildeInPath))
                let report = try executor.execute(plan)
                output(report.text)
                return 0
            }
        } catch {
            output("error: \(error.localizedDescription)")
            return 1
        }
    }
}
