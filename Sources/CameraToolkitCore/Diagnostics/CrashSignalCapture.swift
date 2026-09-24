import Darwin
import Foundation

/// Fatal-signal capture for SIGTRAP, SIGABRT, SIGSEGV, SIGBUS and SIGILL.
///
/// A signal handler may only call async-signal-safe functions, so all the
/// work that allocates happens up front in `prepare`: the log file is
/// opened (empty) and its descriptor kept, the report preamble and every
/// signal's name are copied into C buffers, and the frame buffer and the
/// alternate signal stack are allocated. The handler then only calls
/// `write`, `backtrace`, `backtrace_symbols_fd`, `fsync`, `sigaction` and
/// `raise` on that memory — no Swift strings, arrays or objects. (`backtrace`
/// is called once in `prepare` so its lazy binding is not resolved inside
/// the handler.)
///
/// After writing, the handler restores the handler that was installed
/// before it (the system default for this app) and re-raises, so the
/// system crash report is still produced.
public enum CrashSignalCapture {
    public static let signals: [Int32] = [SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGILL]

    private static let maxSignal = 32
    private static let maxFrames: Int32 = 128
    private static let altStackSize = 64 * 1_024

    nonisolated(unsafe) private static var fd: Int32 = -1
    nonisolated(unsafe) private static var preamble: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var preambleLength = 0
    /// Set by the uncaught-exception path, which already wrote a full log.
    nonisolated(unsafe) private static var handled: sig_atomic_t = 0
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(maxFrames))
    nonisolated(unsafe) private static let names: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> = {
        let table = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: maxSignal)
        table.initialize(repeating: nil, count: maxSignal)
        return table
    }()
    nonisolated(unsafe) private static let previous = UnsafeMutablePointer<sigaction>.allocate(capacity: maxSignal)

    /// Opens (and empties) the file the handler writes to and builds its
    /// buffers. Safe to call again; the previous descriptor is closed.
    public static func prepare(fileURL: URL, preamble text: String) {
        if fd >= 0 { close(fd) }
        fd = open(fileURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        preamble?.deallocate()
        let bytes = Array(text.utf8CString)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        buffer.initialize(from: bytes, count: bytes.count)
        preamble = buffer
        preambleLength = bytes.count - 1
        handled = 0
        for signal in signals where names[Int(signal)] == nil {
            names[Int(signal)] = strdup(signalName(signal))
        }
        _ = backtrace(frames, 1)
    }

    /// Installs the handlers, once per process, on an alternate stack so
    /// a stack overflow can still be reported.
    public static func install() {
        guard !installed else { return }
        installed = true
        var stack = stack_t()
        stack.ss_sp = UnsafeMutableRawPointer.allocate(byteCount: altStackSize, alignment: 16)
        stack.ss_size = altStackSize
        stack.ss_flags = 0
        sigaltstack(&stack, nil)
        for signal in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { signal in
                CrashSignalCapture.handle(signal)
            }
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_ONSTACK
            sigaction(signal, &action, previous + Int(signal))
        }
    }

    /// The uncaught-exception log is complete; skip the signal log.
    public static func markHandled() {
        handled = 1
    }

    /// A normal quit: close the descriptor and drop the empty file.
    public static func finish(fileURL: URL) {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        unlink(fileURL.path)
    }

    /// The handler's write, callable directly by tests. Async-signal-safe.
    public static func writeReport(signal: Int32) {
        let out = fd
        guard out >= 0, handled == 0 else { return }
        if let preamble { _ = write(out, preamble, preambleLength) }
        if signal > 0, Int(signal) < maxSignal, let name = names[Int(signal)] {
            _ = write(out, name, strlen(name))
        } else {
            writeStatic(out, "unknown signal")
        }
        writeStatic(out, "\n\nBacktrace:\n")
        let count = backtrace(frames, maxFrames)
        backtrace_symbols_fd(frames, count, out)
        fsync(out)
    }

    private static func handle(_ signal: Int32) {
        writeReport(signal: signal)
        // Only one report per crash, even if the restore path re-enters.
        handled = 1
        if signal > 0, Int(signal) < maxSignal {
            sigaction(signal, previous + Int(signal), nil)
        }
        raise(signal)
    }

    private static func writeStatic(_ out: Int32, _ text: StaticString) {
        _ = write(out, text.utf8Start, text.utf8CodeUnitCount)
    }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGTRAP: "SIGTRAP (trace/breakpoint trap — a Swift runtime trap or uncaught exception)"
        case SIGABRT: "SIGABRT (abort)"
        case SIGSEGV: "SIGSEGV (bad memory access)"
        case SIGBUS: "SIGBUS (bus error)"
        case SIGILL: "SIGILL (illegal instruction)"
        default: "signal \(signal)"
        }
    }
}
