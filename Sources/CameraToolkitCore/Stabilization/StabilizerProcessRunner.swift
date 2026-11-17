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

/// The real runner: `Process` with both pipes read as they fill. Ending a
/// run sends SIGTERM, then SIGKILL if the tool has not gone within two
/// seconds. No window is opened: Gyroflow's command line mode is a console
/// application.
public struct FoundationProcessRunner: StabilizerProcessRunning {
    public var pollInterval: TimeInterval = 0.2

    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void,
        keepRunning: @escaping @Sendable () -> Bool
    ) throws -> StabilizerProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let splitters = [LineSplitter(onLine), LineSplitter(onLine)]
        output.fileHandleForReading.readabilityHandler = { handle in splitters[0].feed(handle.availableData) }
        errors.fileHandleForReading.readabilityHandler = { handle in splitters[1].feed(handle.availableData) }
        try process.run()

        var terminated = false
        while process.isRunning {
            if !keepRunning() {
                terminated = true
                process.terminate()
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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
