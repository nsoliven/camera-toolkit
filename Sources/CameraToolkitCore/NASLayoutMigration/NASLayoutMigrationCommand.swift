import Foundation

/// The hidden `--migrate-nas-layout` command line of the app binary:
///
/// ```
/// CameraToolkit --migrate-nas-layout --dry-run --mapping <mapping.json> [--json <plan.json>]
/// CameraToolkit --migrate-nas-layout --execute --plan <plan.json> [--verify-sample <n>]
/// CameraToolkit --migrate-nas-layout --resume <journal.json> [--verify-sample <n>]
/// CameraToolkit --migrate-nas-layout --undo <journal.json>
///     [--support-dir <folder>]    (or CAMERA_TOOLKIT_SUPPORT_DIR)
/// ```
///
/// The dry run is read-only: it lists the NAS folders the mapping names and
/// reads the catalog through a read-only connection. `--support-dir` works
/// as for `--migrate-layout`: `<folder>/config.json` and
/// `<folder>/catalog.sqlite` only.
public enum NASLayoutMigrationCommand {
    public static let flag = "--migrate-nas-layout"

    public enum Mode: Equatable, Sendable {
        case dryRun(mappingPath: String, jsonPath: String?)
        case execute(planPath: String)
        case resume(journalPath: String)
        case undo(journalPath: String)
    }

    public struct Arguments: Equatable, Sendable {
        public var mode: Mode
        public var supportDirectory: String?
        public var verifySamples: Int
    }

    public static let usage = """
    usage: CameraToolkit --migrate-nas-layout --dry-run --mapping <mapping.json> [--json <plan.json>]
           CameraToolkit --migrate-nas-layout --execute --plan <plan.json> [--verify-sample <n>]
           CameraToolkit --migrate-nas-layout --resume <journal.json> [--verify-sample <n>]
           CameraToolkit --migrate-nas-layout --undo <journal.json>
           options: --support-dir <folder>  (default: the app's Application Support folder;
                                             env CAMERA_TOOLKIT_SUPPORT_DIR also works)
                    --verify-sample <n>     files per event hashed before and after the rename (default 2)
    """

    public static func parse(_ arguments: [String], environment: [String: String] = [:]) throws -> Arguments {
        var args = Array(arguments.drop { $0 != flag }.dropFirst())
        var support = environment[LayoutMigrationCommand.supportDirectoryEnvironmentKey]
        var modes: [Mode] = []
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
        let mapping = args.contains("--mapping") ? try value(after: "--mapping") : nil
        let plan = args.contains("--plan") ? try value(after: "--plan") : nil
        var samples = 2
        if args.contains("--verify-sample") {
            let text = try value(after: "--verify-sample")
            guard let number = Int(text), number >= 0 else {
                throw ToolkitError.commandFailed("--verify-sample needs a number ≥ 0.\n\(usage)")
            }
            samples = number
        }
        if args.contains("--resume") { modes.append(.resume(journalPath: try value(after: "--resume"))) }
        if args.contains("--undo") { modes.append(.undo(journalPath: try value(after: "--undo"))) }
        if let index = args.firstIndex(of: "--dry-run") {
            args.remove(at: index)
            guard let mapping else { throw ToolkitError.commandFailed("--dry-run needs --mapping <mapping.json>.\n\(usage)") }
            modes.append(.dryRun(mappingPath: mapping, jsonPath: json))
        } else if mapping != nil || json != nil {
            throw ToolkitError.commandFailed("--mapping and --json only go with --dry-run.\n\(usage)")
        }
        if let index = args.firstIndex(of: "--execute") {
            args.remove(at: index)
            guard let plan else { throw ToolkitError.commandFailed("--execute needs --plan <plan.json>.\n\(usage)") }
            modes.append(.execute(planPath: plan))
        } else if plan != nil {
            throw ToolkitError.commandFailed("--plan only goes with --execute.\n\(usage)")
        }
        guard args.isEmpty else { throw ToolkitError.commandFailed("Unknown argument(s): \(args.joined(separator: " ")).\n\(usage)") }
        guard modes.count == 1, let mode = modes.first else {
            throw ToolkitError.commandFailed("Pick exactly one of --dry-run, --execute, --resume, --undo.\n\(usage)")
        }
        return Arguments(mode: mode, supportDirectory: support.map { NSString(string: $0).expandingTildeInPath }, verifySamples: samples)
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
            let catalogURL: URL? = FileManager.default.fileExists(atPath: context.catalogURL.path) ? context.catalogURL : nil
            output("Support folder: \(context.supportFolder.path)\(context.supportOverridden ? " (override)" : "")")
            output("Catalog:        \(catalogURL?.path ?? "none found — no catalog rows will be planned")")
            func executor() -> NASLayoutMigrationExecutor {
                NASLayoutMigrationExecutor(
                    supportFolder: context.supportFolder,
                    configurationURL: context.configurationURL,
                    catalogURL: catalogURL,
                    configuration: context.configuration,
                    verifySamples: parsed.verifySamples,
                    isAppRunning: running,
                    log: output
                )
            }
            switch parsed.mode {
            case .dryRun(let mappingPath, let jsonPath):
                if running() {
                    output("Note: Camera Toolkit is running. The plan is read-only, but it can go stale; quit the app before executing.")
                }
                let mapping = try NASLayoutMapping.read(URL(fileURLWithPath: NSString(string: mappingPath).expandingTildeInPath))
                let started = Date()
                let plan = try NASLayoutMigrationPlanner().plan(.init(
                    mapping: mapping,
                    configuration: context.configuration,
                    supportFolder: context.supportFolder,
                    configurationURL: context.configurationURL,
                    catalogURL: catalogURL
                ))
                output(plan.summaryText())
                output(String(format: "Planned in %.1f s.", Date().timeIntervalSince(started)))
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
                let plan = try NASLayoutMigrationPlan.read(URL(fileURLWithPath: NSString(string: planPath).expandingTildeInPath))
                let report = try executor().execute(plan)
                output(report.text)
                return report.succeeded ? 0 : 1
            case .resume(let journalPath):
                let report = try executor().resume(journalURL: URL(fileURLWithPath: NSString(string: journalPath).expandingTildeInPath))
                output(report.text)
                return report.succeeded ? 0 : 1
            case .undo(let journalPath):
                let report = try executor().undo(journalURL: URL(fileURLWithPath: NSString(string: journalPath).expandingTildeInPath))
                output(report.text)
                return report.succeeded ? 0 : 1
            }
        } catch {
            output("error: \(error.localizedDescription)")
            return 1
        }
    }
}
