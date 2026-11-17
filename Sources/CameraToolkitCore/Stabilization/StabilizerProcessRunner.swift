import Foundation

/// How a run of an external tool ended.
public struct StabilizerProcessOutcome: Equatable, Sendable {
    public var exitCode: Int32
    /// True when the run was ended from here (Stop, or a stuck error).
    public var terminated: Bool

    public init(exitCode: Int32, terminated: Bool) {
        self.exitCode = exitCode
        self.terminated = terminated
    }
}

/// Runs a command and hands back its output line by line. A seam: tests
/// replace it with a fake that plays back recorded output.
public protocol StabilizerProcessRunning: Sendable {
    /// Runs `executable` with `arguments`, calling `onLine` with each line
    /// of standard output and standard error, and polling `keepRunning`
    /// a few times a second; when it answers false the process is ended.
    func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void,
        keepRunning: @escaping @Sendable () -> Bool
    ) throws -> StabilizerProcessOutcome
}

/// The real runner: `Process` with both pipes read as they fill. The
/// tool runs under a small `/bin/sh` guard that ends it when this app goes
/// away — a crash, a force quit, Quit Anyway — so a render never outlives
/// the app writing a multi-GB partial. Ending a run sends SIGTERM (the
/// guard passes it on), then SIGKILL to both if they have not gone. Every
/// live run is in `StabilizerProcesses`, which quitting ends. No window is
/// opened: Gyroflow's command line mode is a console application.
public struct FoundationProcessRunner: StabilizerProcessRunning {
    public var pollInterval: TimeInterval = 0.2
    /// Run under the parent-watching guard (off only in tests of the bare
    /// runner).
    public var guardsParent = true

    public init() {}

    /// `sh -c guardScript ctk-guard <parent pid> <tool> <args…>`: starts the
    /// tool, prints its pid, ends it on TERM/INT/HUP and when the parent
    /// pid is gone, and exits with the tool's status.
    static let guardScript = """
    parent=$1; shift
    "$@" &
    child=$!
    echo "CTK_CHILD_PID=$child"
    stop() {
      kill -TERM $child 2>/dev/null
      for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 $child 2>/dev/null || break; sleep 0.2; done
      kill -KILL $child 2>/dev/null
    }
    trap 'stop; exit 143' TERM INT HUP
    while kill -0 $child 2>/dev/null; do
      if ! kill -0 $parent 2>/dev/null; then stop; exit 1; fi
      sleep 1
    done
    wait $child
    """

    public static let childPIDPrefix = "CTK_CHILD_PID="

    public func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void,
        keepRunning: @escaping @Sendable () -> Bool
    ) throws -> StabilizerProcessOutcome {
        let process = Process()
        if guardsParent {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", Self.guardScript, "ctk-guard", String(getpid()), executable.path] + arguments
        } else {
            process.executableURL = executable
            process.arguments = arguments
        }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        final class Child: @unchecked Sendable { let lock = NSLock(); var pid: pid_t? }
        let child = Child()
        let forward: @Sendable (String) -> Void = { line in
            if line.hasPrefix(Self.childPIDPrefix), let pid = pid_t(line.dropFirst(Self.childPIDPrefix.count)) {
                child.lock.withLock { child.pid = pid }
                StabilizerProcesses.register(pid)
                return
            }
            onLine(line)
        }
        let splitters = [LineSplitter(forward), LineSplitter(forward)]
        output.fileHandleForReading.readabilityHandler = { handle in splitters[0].feed(handle.availableData) }
        errors.fileHandleForReading.readabilityHandler = { handle in splitters[1].feed(handle.availableData) }
        try process.run()
        let pid = process.processIdentifier
        StabilizerProcesses.register(pid)
        defer {
            StabilizerProcesses.unregister(pid)
            if let childPID = child.lock.withLock({ child.pid }) { StabilizerProcesses.unregister(childPID) }
        }

        var terminated = false
        while process.isRunning {
            if !keepRunning() {
                terminated = true
                process.terminate()
                let deadline = Date().addingTimeInterval(4)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(pid, SIGKILL) }
                if let childPID = child.lock.withLock({ child.pid }) { StabilizerProcesses.end([childPID], grace: 1) }
                break
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        splitters[0].feed(output.fileHandleForReading.readDataToEndOfFile())
        splitters[1].feed(errors.fileHandleForReading.readDataToEndOfFile())
        splitters.forEach { $0.flush() }
        return StabilizerProcessOutcome(exitCode: process.terminationStatus, terminated: terminated)
    }
}

/// Every stabilizer process this app has running (guards and Gyroflow
/// itself), so quitting can end them, and a sweep for ones a crashed run
/// left behind.
public enum StabilizerProcesses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live: Set<pid_t> = []

    public static func register(_ pid: pid_t) { _ = lock.withLock { live.insert(pid) } }
    public static func unregister(_ pid: pid_t) { _ = lock.withLock { live.remove(pid) } }
    public static var running: Set<pid_t> { lock.withLock { live } }

    /// SIGTERM, then SIGKILL after `grace` for any still there.
    public static func end(_ pids: [pid_t], grace: TimeInterval = 2) {
        let alive = pids.filter { kill($0, 0) == 0 }
        guard !alive.isEmpty else { return }
        for pid in alive { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, alive.contains(where: { kill($0, 0) == 0 }) { Thread.sleep(forTimeInterval: 0.05) }
        for pid in alive where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Ends every run this app has going. Called on quit (also Quit
    /// Anyway) before the app goes.
    public static func terminateAll(grace: TimeInterval = 2) {
        let pids = Array(running)
        end(pids, grace: grace)
        lock.withLock { live.subtract(pids) }
    }

    /// Process ids, from a `ps -axo pid=,command=` listing, of runs this
    /// app started: a Gyroflow executable (`…/Contents/MacOS/gyroflow`)
    /// given this app's scratch suffix (`-t _ctk-stabilizing`), which
    /// nothing else uses. The person's own Gyroflow, a shell that merely
    /// mentions the suffix, and this process are never matched. (A guard
    /// shell ends by itself once its Gyroflow is gone.)
    public static func leftoverPIDs(inListing listing: String, own: pid_t = getpid()) -> [pid_t] {
        listing.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let pid = pid_t(trimmed.prefix { $0.isNumber }), pid != own else { return nil }
            let command = trimmed.drop { $0.isNumber }.trimmingCharacters(in: .whitespaces)
            guard let marker = command.range(of: "/Contents/MacOS/gyroflow ") else { return nil }
            guard command[marker.upperBound...].contains("-t \(GyroflowCommand.scratchSuffix) ") || command.hasSuffix("-t \(GyroflowCommand.scratchSuffix)") else { return nil }
            return pid
        }
    }

    /// Ends stabilizer runs a crashed or force-quit session left behind,
    /// before anything sweeps their partials. Returns how many there were.
    @discardableResult
    public static func killLeftovers(grace: TimeInterval = 2) -> Int {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let mine = running
        let pids = leftoverPIDs(inListing: String(decoding: data, as: UTF8.self)).filter { !mine.contains($0) }
        end(pids, grace: grace)
        return pids.count
    }
}

/// Bytes in, whole lines out. Gyroflow also draws progress bars with
/// carriage returns; those split lines too.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(_ onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            buffer.append(data)
            var lines: [String] = []
            while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            }
            return lines
        }
        lines.forEach(onLine)
    }

    func flush() {
        let rest: Data = lock.withLock {
            defer { buffer.removeAll() }
            return buffer
        }
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }
}
