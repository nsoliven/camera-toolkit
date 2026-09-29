import Foundation

/// Verifies NAS copies by hashing them *on the NAS*, over SSH, instead of
/// re-reading every byte back across the network.
///
/// For a batch of files it runs one command on the server:
///
///     sync -f -- <folders> || sync; sha256sum -z -- <files>
///
/// The `sync` makes the filesystem commit the batch (on ZFS: the pending
/// transaction group) before it is hashed — once per batch, never per
/// file. The hashes are compared with the ones taken while the drive copy
/// was read.
///
/// It uses the system `/usr/bin/ssh` in batch mode with the user's own
/// keys and `~/.ssh/config`; it stores no secrets and never prompts. The
/// SMB path of a file (`<mount>/…`) maps to its server path
/// (`<serverPrefix>/…`) by prefix.
public struct NASRemoteVerifier: Sendable {
    public struct CommandResult: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data

        public init(status: Int32, stdout: Data, stderr: Data) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// Runs a remote shell command and returns its result. The default is
    /// SSH; tests run the same command with a local `/bin/sh`.
    public typealias Transport = @Sendable (_ command: String) throws -> CommandResult

    /// The SMB mount path of the share root on this Mac, e.g. `/Volumes/share`.
    public var localPrefix: String
    /// The same folder's path on the server, e.g. `/mnt/pool/dataset`.
    public var serverPrefix: String
    /// Short text for reports and telemetry, e.g. "ssh nas".
    public var label: String
    private let transport: Transport

    public init(localPrefix: String, serverPrefix: String, label: String, transport: @escaping Transport) {
        self.localPrefix = Self.trimmedPrefix(localPrefix)
        self.serverPrefix = Self.trimmedPrefix(serverPrefix)
        self.label = label
        self.transport = transport
    }

    /// SSH to `host` (an alias from `~/.ssh/config`, or `user@host`).
    public static func ssh(
        host: String,
        user: String? = nil,
        configFile: String? = nil,
        localPrefix: String,
        serverPrefix: String,
        timeout: TimeInterval = 900
    ) -> NASRemoteVerifier {
        var arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15"]
        if let configFile, !configFile.isEmpty { arguments += ["-F", configFile] }
        if let user, !user.isEmpty { arguments += ["-l", user] }
        // `--` so a host that starts with "-" can never be read as an option.
        let hostArguments = arguments + ["--", host]
        return NASRemoteVerifier(localPrefix: localPrefix, serverPrefix: serverPrefix, label: "ssh \(host)") { command in
            try run(executable: "/usr/bin/ssh", arguments: hostArguments + [command], timeout: timeout)
        }
    }

    /// The server path of a local SMB path, or nil when it is not under
    /// `localPrefix`.
    public func serverPath(for localPath: String) -> String? {
        guard !localPrefix.isEmpty, !serverPrefix.isEmpty else { return nil }
        if localPath == localPrefix { return serverPrefix }
        guard localPath.hasPrefix(localPrefix + "/") else { return nil }
        return serverPrefix + localPath.dropFirst(localPrefix.count)
    }

    /// SHA-256 of each local path, hashed on the server. A path the server
    /// could not hash (missing, unreadable, outside the mapping) is absent
    /// from the result — callers fall back to re-reading it over SMB; only
    /// a hash that *differs* is a failed verification. Throws when the
    /// command could not run at all (SSH refused, host unreachable).
    public func hashes(localPaths: [String]) throws -> [String: String] {
        var serverToLocal: [String: String] = [:]
        for local in localPaths {
            if let server = serverPath(for: local) { serverToLocal[server] = local }
        }
        guard !serverToLocal.isEmpty else { return [:] }
        let serverPaths = serverToLocal.keys.sorted()
        let result = try transport(Self.command(serverPaths: serverPaths))
        // sha256sum exits 1 when a file is missing but still hashes the
        // rest; 255 is ssh's own failure.
        guard result.status == 0 || result.status == 1 else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolkitError.commandFailed("NAS-side hashing (\(label)) failed with status \(result.status): \(message.isEmpty ? "no output" : message)")
        }
        var byLocal: [String: String] = [:]
        for (server, hash) in Self.parse(result.stdout) {
            if let local = serverToLocal[server] { byLocal[local] = hash }
        }
        return byLocal
    }

    /// The remote shell command for a batch. Every path is single-quoted.
    public static func command(serverPaths: [String]) -> String {
        let folders = Array(Set(serverPaths.map { ($0 as NSString).deletingLastPathComponent })).sorted()
        return "sync -f -- \(folders.map(quote).joined(separator: " ")) 2>/dev/null || sync; "
            + "sha256sum -z -- \(serverPaths.map(quote).joined(separator: " "))"
    }

    /// POSIX shell single-quoting: `'` becomes `'\''`.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Parses `sha256sum -z` output: NUL-terminated `<64 hex><space><space|*><path>`
    /// records, with no escaping of the path.
    public static func parse(_ output: Data) -> [String: String] {
        var hashes: [String: String] = [:]
        for record in output.split(separator: 0, omittingEmptySubsequences: true) {
            let line = String(decoding: record, as: UTF8.self)
            guard line.utf8.count > 66 else { continue }
            let hash = String(line.prefix(64)).lowercased()
            guard hash.allSatisfy({ $0.isHexDigit }) else { continue }
            let separator = line.dropFirst(64).prefix(2)
            guard separator == "  " || separator == " *" else { continue }
            hashes[String(line.dropFirst(66))] = hash
        }
        return hashes
    }

    static func trimmedPrefix(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// Runs a process to completion, reading both pipes concurrently so a
    /// large output never deadlocks, and killing it after `timeout`.
    static func run(executable: String, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let collected = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            collected.setOut(out.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            collected.setErr(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        // The read ends are closed here, once both readers are done — not
        // whenever an autorelease pool that holds the Pipe next drains, which
        // on a thread that never drains one leaves two descriptors open per
        // process for good.
        defer {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            group.wait()
            process.waitUntilExit()
            throw ToolkitError.commandFailed("\(executable) timed out after \(Int(timeout)) s.")
        }
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: collected.out, stderr: collected.err)
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _out = Data()
        private var _err = Data()
        var out: Data { lock.withLock { _out } }
        var err: Data { lock.withLock { _err } }
        func setOut(_ data: Data) { lock.withLock { _out = data } }
        func setErr(_ data: Data) { lock.withLock { _err = data } }
    }
}
