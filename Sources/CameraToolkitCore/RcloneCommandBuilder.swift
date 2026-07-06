import Foundation

public struct RcloneCommandBuilder: Sendable {
    public let binary: String
    public let excludes: [String]
    public let transfers: Int
    public let extraArguments: [String]

    public init(
        binary: String = "rclone",
        excludes: [String] = DefaultExcludes.all,
        transfers: Int = 4,
        extraArguments: [String] = []
    ) {
        self.binary = binary
        self.excludes = excludes
        self.transfers = transfers
        self.extraArguments = extraArguments
    }

    public func baseCommand(_ subcommand: String) throws -> [String] {
        guard Self.allowedSubcommands.contains(subcommand) else {
            throw ToolkitError.rcloneSubcommandNotAllowed(subcommand)
        }
        return [binary, subcommand]
    }

    public func copyCommand(source: URL, destination: URL, immutable: Bool = true) throws -> [String] {
        var command = try baseCommand("copy")
        command += [source.path, destination.path]
        command += ["--checksum", "--transfers", "\(transfers)", "-v", "--stats", "5s", "--stats-one-line"]
        if immutable {
            command.append("--immutable")
        }
        command += excludeArguments()
        command += extraArguments
        return command
    }

    public func checkCommand(source: URL, destination: URL) throws -> [String] {
        var command = try baseCommand("check")
        command += [source.path, destination.path, "--checksum", "--combined", "-"]
        command += excludeArguments()
        return command
    }

    public func lsjsonCommand(root: URL) throws -> [String] {
        var command = try baseCommand("lsjson")
        command += ["-R", "--files-only", root.path]
        command += excludeArguments()
        return command
    }

    private func excludeArguments() -> [String] {
        excludes.flatMap { ["--exclude", $0] }
    }

    private static let allowedSubcommands: Set<String> = [
        "copy",
        "check",
        "lsjson",
        "size",
        "version"
    ]
}
