import Foundation

/// What one listing of the NAS mirror found: every regular file under the
/// folders it covered, with its size and modification time — and nothing
/// read from any file. The presence index compares drive files against it
/// instead of stat-ing each file over SMB.
///
/// Coverage is per folder: a path under a covered folder that has no entry
/// is *missing* on the NAS; a path under no covered folder is *unknown*.
public struct NASTreeListing: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Hashable, Sendable {
        public var size: Int64
        /// `timeIntervalSinceReferenceDate`.
        public var modifiedAt: Double

        public init(size: Int64, modifiedAt: Double) {
            self.size = size
            self.modifiedAt = modifiedAt
        }
    }

    public enum Method: String, Codable, Sendable {
        /// One `find` run on the NAS over SSH.
        case ssh
        /// Folder-by-folder bulk listings over the SMB mount.
        case smb
    }

    /// The standardized local path of the NAS mirror root the relative
    /// paths are under.
    public var root: String
    /// Covered folder key (`key(_:)` of a path under the root; "" for the
    /// whole root) → when it was listed.
    public private(set) var coverage: [String: Date]
    /// `key(relativePath)` → size and modification time.
    public private(set) var entries: [String: Entry]
    public var method: Method

    public init(root: String, coverage: [String: Date] = [:], entries: [String: Entry] = [:], method: Method) {
        self.root = NASSyncStore.standardizedRoot(root)
        self.coverage = coverage
        self.entries = entries
        self.method = method
    }

    /// Case-folded and NFC-composed: a case-insensitive share and a drive
    /// that stores decomposed names (APFS keeps what it was given) agree on
    /// one key.
    public static func key(_ relativePath: String) -> String {
        relativePath.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The covered folder `relativePath` sits under, if any — the deepest
    /// one. Walks up the path's own folders, so it costs the path's depth,
    /// not the number of covered folders.
    public func coveringFolder(_ relativePath: String) -> String? {
        Self.enclosingFolder(of: Self.key(relativePath)) { coverage[$0] != nil }
    }

    /// The deepest folder of `key` (a `key(_:)` path; "" is the root) for
    /// which `matches` holds.
    static func enclosingFolder(of key: String, where matches: (String) -> Bool) -> String? {
        var folder = Substring(key)
        while let slash = folder.lastIndex(of: "/") {
            folder = folder[..<slash]
            if matches(String(folder)) { return String(folder) }
        }
        return matches("") ? "" : nil
    }

    public func covers(_ relativePath: String) -> Bool { coveringFolder(relativePath) != nil }

    /// When the folder covering `relativePath` was listed.
    public func listedAt(_ relativePath: String) -> Date? {
        coveringFolder(relativePath).flatMap { coverage[$0] }
    }

    public func entry(_ relativePath: String) -> Entry? { entries[Self.key(relativePath)] }

    public var oldestListing: Date? { coverage.values.min() }
    public var newestListing: Date? { coverage.values.max() }

    /// Adds a file the listing found. `relativePath` must be under a folder
    /// the same listing covers.
    public mutating func insert(_ relativePath: String, size: Int64, modifiedAt: Double) {
        entries[Self.key(relativePath)] = Entry(size: size, modifiedAt: modifiedAt)
    }

    public mutating func cover(_ folder: String, at date: Date) {
        coverage[Self.key(Self.trimmed(folder))] = date
    }

    /// A newer listing of some folders replaces what this one knew about
    /// them: their old entries go, the new ones and their times come in.
    /// Everything else is kept.
    public mutating func merge(_ newer: NASTreeListing) {
        guard newer.root == root else {
            self = newer
            return
        }
        let replaced = Set(newer.coverage.keys)
        if replaced.contains("") {
            entries = [:]
            coverage = [:]
        } else {
            entries = entries.filter { key, _ in
                Self.enclosingFolder(of: key, where: replaced.contains) == nil
            }
            // A folder nested in a relisted one is covered by it now.
            coverage = coverage.filter { folder, _ in
                !replaced.contains(folder) && Self.enclosingFolder(of: folder, where: replaced.contains) == nil
            }
        }
        entries.merge(newer.entries) { _, new in new }
        coverage.merge(newer.coverage) { _, new in new }
        method = newer.method
    }

    /// The same listing, trusting only folders listed at or after `date`:
    /// paths under an older listing become unknown (not covered), so a
    /// caller probes them instead of believing a stale answer.
    public func trusting(listedSince date: Date) -> NASTreeListing {
        var copy = self
        copy.coverage = coverage.filter { $0.value >= date }
        return copy
    }

    /// Sync to NAS just proved these files on the NAS (copied, matched, or
    /// verified before), so the listing learns them without asking the NAS
    /// again. Only paths the listing covers are touched.
    public mutating func recordSynced(_ items: [NASSyncItem]) {
        for item in items where covers(item.relativePath) {
            insert(item.relativePath, size: item.byteCount, modifiedAt: item.modifiedAt)
        }
    }

    /// The NAS renamed `from` to `to` (a file): the listing follows, so
    /// counts stay right without listing the NAS again. The entry keeps its
    /// size and time; it is only placed at `to` when the listing covers
    /// that folder (else the path is unknown, not missing).
    public mutating func recordRenamed(from: String, to: String) {
        guard let entry = entries.removeValue(forKey: Self.key(from)) else { return }
        if covers(to) { entries[Self.key(to)] = entry }
    }

    /// The NAS renamed the folder `from` to `to`: entries and coverage
    /// under it are re-keyed.
    public mutating func recordFolderRenamed(from: String, to: String) {
        let old = Self.key(Self.trimmed(from))
        let new = Self.key(Self.trimmed(to))
        func rekeyed(_ key: String) -> String? {
            key == old ? new : (key.hasPrefix(old + "/") ? new + key.dropFirst(old.count) : nil)
        }
        for (key, entry) in entries {
            guard let moved = rekeyed(key) else { continue }
            entries[key] = nil
            entries[moved] = entry
        }
        for (key, date) in coverage {
            guard let moved = rekeyed(key) else { continue }
            coverage[key] = nil
            coverage[moved] = date
        }
    }

    /// The NAS trashed a stale copy: it is no longer at `path`.
    public mutating func recordRemoved(_ path: String) {
        entries[Self.key(path)] = nil
    }

    static func trimmed(_ folder: String) -> String {
        var value = folder
        while value.hasPrefix("./") { value.removeFirst(2) }
        if value == "." { return "" }
        while value.hasSuffix("/") { value.removeLast() }
        while value.hasPrefix("/") { value.removeFirst() }
        return value
    }
}

/// Incremental parser for `size<TAB>mtime<TAB>path<NUL>` records — what the
/// NAS-side `find` prints. The path is everything after the second tab up
/// to the NUL, so a name with spaces, quotes, tabs, or newlines survives;
/// only NUL cannot appear in a path. Chunks may split a record anywhere.
public struct NASListingParser: Sendable {
    public struct Record: Equatable, Sendable {
        /// Relative to the listed root, without a leading `./`.
        public var path: String
        public var size: Int64
        /// Seconds since 1970, as `find` prints it.
        public var mtime1970: Double
    }

    private var pending: [UInt8] = []
    /// Records that did not parse (a truncated tail, a stray line).
    public private(set) var malformed = 0

    public init() {}

    public mutating func feed(_ chunk: Data) -> [Record] {
        var records: [Record] = []
        pending.reserveCapacity(pending.count + chunk.count)
        for byte in chunk {
            if byte == 0 {
                if let record = Self.parse(pending) { records.append(record) } else if !pending.isEmpty { malformed += 1 }
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(byte)
            }
        }
        return records
    }

    /// Anything left without its NUL is a truncated record.
    public mutating func finish() {
        if !pending.isEmpty { malformed += 1 }
        pending.removeAll()
    }

    static func parse(_ bytes: [UInt8]) -> Record? {
        guard let firstTab = bytes.firstIndex(of: 9) else { return nil }
        guard let secondTab = bytes[(firstTab + 1)...].firstIndex(of: 9) else { return nil }
        guard let size = Int64(String(decoding: bytes[..<firstTab], as: UTF8.self)),
              let mtime = Double(String(decoding: bytes[(firstTab + 1)..<secondTab], as: UTF8.self)) else { return nil }
        var path = String(decoding: bytes[(secondTab + 1)...], as: UTF8.self)
        while path.hasPrefix("./") { path.removeFirst(2) }
        guard !path.isEmpty else { return nil }
        return Record(path: path, size: size, mtime1970: mtime)
    }
}

/// Lists the NAS mirror *on the NAS*: one SSH command runs `find` over the
/// event folders and streams every file's size, modification time, and
/// path back as NUL-separated records — one round trip for the whole
/// library instead of one SMB stat per file.
///
/// GNU `find -printf` when the NAS has it (TrueNAS SCALE, Linux); the BSD
/// `stat -f` equivalent otherwise (TrueNAS CORE, FreeBSD, and the macOS
/// shell the tests run it with). `.zfs` snapshot folders are pruned. It
/// reads directory metadata only, never a file's contents, and writes
/// nothing.
public struct NASRemoteLister: Sendable {
    public struct StreamResult: Sendable {
        public var status: Int32
        public var stderr: Data

        public init(status: Int32, stderr: Data) {
            self.status = status
            self.stderr = stderr
        }
    }

    /// Runs a remote shell command, handing its stdout over in chunks as
    /// they arrive; `onOutput` returns false to stop the command early.
    /// SSH by default; tests run the same command with a local `/bin/sh`.
    public typealias Transport = @Sendable (_ command: String, _ onOutput: (Data) -> Bool) throws -> StreamResult

    public var localPrefix: String
    public var serverPrefix: String
    public var label: String
    private let transport: Transport

    public init(localPrefix: String, serverPrefix: String, label: String, transport: @escaping Transport) {
        self.localPrefix = NASRemoteVerifier.trimmedPrefix(localPrefix)
        self.serverPrefix = NASRemoteVerifier.trimmedPrefix(serverPrefix)
        self.label = label
        self.transport = transport
    }

    /// SSH to `host`, in batch mode with the user's own keys; compressed,
    /// since the listing is text.
    public static func ssh(host: String, localPrefix: String, serverPrefix: String, timeout: TimeInterval = 300) -> NASRemoteLister {
        let arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "Compression=yes",
            "--", host,
        ]
        return NASRemoteLister(localPrefix: localPrefix, serverPrefix: serverPrefix, label: "ssh \(host)") { command, onOutput in
            try NASRemoteShell.stream(executable: "/usr/bin/ssh", arguments: arguments + [command], timeout: timeout, onOutput: onOutput)
        }
    }

    /// The lister the app's settings describe, or nil when NAS-side work
    /// over SSH is not set up (the same settings NAS-side verification
    /// uses; see `NASSyncOptions.from`).
    public static func from(configuration: AppConfiguration, nasRoot: URL) -> NASRemoteLister? {
        guard let verifier = NASSyncOptions.from(configuration: configuration, nasRoot: nasRoot).remoteVerifier else { return nil }
        let host = configuration.nasSyncSSHHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return .ssh(host: host, localPrefix: verifier.localPrefix, serverPrefix: verifier.serverPrefix)
    }

    public func serverPath(for localPath: String) -> String? {
        guard !localPrefix.isEmpty, !serverPrefix.isEmpty else { return nil }
        if localPath == localPrefix { return serverPrefix }
        guard localPath.hasPrefix(localPrefix + "/") else { return nil }
        return serverPrefix + localPath.dropFirst(localPrefix.count)
    }

    /// Lists `folders` (relative to `root`; "" or "." for all of it). A
    /// folder that does not exist on the NAS is covered and empty — its
    /// files are missing. Throws when the command could not run, or when
    /// `find` reported an error (an unreadable folder), since a listing
    /// with holes would call files missing that are not.
    public func list(
        root: URL,
        folders: [String],
        now: Date = Date(),
        isCancelled: () -> Bool = { Task.isCancelled },
        progress: ((Int) -> Void)? = nil
    ) throws -> NASTreeListing {
        let localRoot = root.standardizedFileURL.path
        guard let serverRoot = serverPath(for: localRoot) else {
            throw ToolkitError.commandFailed("\(localRoot) is not under the SSH mapping \(localPrefix) → \(serverPrefix).")
        }
        let relative = Array(Set(folders.map(NASTreeListing.trimmed))).sorted()
        var listing = NASTreeListing(root: localRoot, method: .ssh)
        guard !relative.isEmpty else { return listing }
        var parser = NASListingParser()
        var count = 0
        var cancelled = false
        let result = try transport(Self.command(serverRoot: serverRoot, folders: relative)) { chunk in
            if isCancelled() {
                cancelled = true
                return false
            }
            for record in parser.feed(chunk) where !NASSyncPlanner.isJunk((record.path as NSString).lastPathComponent) {
                listing.insert(
                    record.path,
                    size: record.size,
                    modifiedAt: Date(timeIntervalSince1970: record.mtime1970).timeIntervalSinceReferenceDate
                )
                count += 1
            }
            progress?(count)
            return true
        }
        parser.finish()
        if cancelled || isCancelled() { throw CancellationError() }
        guard result.status == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolkitError.commandFailed("Listing the NAS (\(label)) failed with status \(result.status): \(message.isEmpty ? "no output" : message)")
        }
        for folder in relative { listing.cover(folder, at: now) }
        return listing
    }

    /// The remote command: a POSIX `sh` script, quoted as one argument so
    /// the login shell (bash, zsh, or csh) only has to run `sh -c`.
    public static func command(serverRoot: String, folders: [String]) -> String {
        let operands = folders.map { $0.isEmpty ? "." : $0 }.map(NASRemoteVerifier.quote).joined(separator: " ")
        let bsdStat = #"for f do stat -n -f "%z%t%Fm%t" "$f" && printf "%s\0" "$f"; done"#
        let script = """
        cd -- \(NASRemoteVerifier.quote(serverRoot)) || exit 3
        set --
        for d in \(operands); do [ -d "$d" ] && set -- "$@" "$d"; done
        [ $# -eq 0 ] && exit 0
        if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
          exec find "$@" -name .zfs -prune -o -type f -printf '%s\\t%T@\\t%p\\0'
        else
          exec find "$@" -name .zfs -prune -o -type f -exec sh -c \(NASRemoteVerifier.quote(bsdStat)) sh {} +
        fi
        """
        return "exec /bin/sh -c " + NASRemoteVerifier.quote(script)
    }
}

/// Lists the NAS mirror over the SMB mount when there is no SSH: each
/// folder is read once with `getattrlistbulk` (`DirectoryListing`), which
/// returns every entry's size and time in the same reply — never a stat
/// per file, never a file opened. At most `concurrency` folders are read
/// at once, so a slow share is not stampeded.
public enum NASSMBLister {
    public static func list(
        root: URL,
        folders: [String],
        concurrency: Int = 2,
        now: Date = Date(),
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: (@Sendable (Int) -> Void)? = nil
    ) throws -> NASTreeListing {
        let rootPath = root.standardizedFileURL.path
        // A missing event folder means "nothing there" only while the NAS
        // root itself answers — never for a share that went away.
        guard !nasIsGone(rootPath) else {
            throw ToolkitError.commandFailed("The NAS folder \(rootPath) is not connected.")
        }
        let relative = Array(Set(folders.map(NASTreeListing.trimmed))).sorted()
        let state = SMBListingState(root: rootPath)
        // Nested requests are listed by their ancestor already.
        let tops = relative.filter { folder in
            !relative.contains { other in other != folder && (other.isEmpty || folder.hasPrefix(other + "/")) }
        }
        let topSet = Set(tops)
        state.push(tops)
        let width = max(1, min(concurrency, 4))
        DispatchQueue.concurrentPerform(iterations: width) { _ in
            while let folder = state.next() {
                if isCancelled() {
                    state.fail(CancellationError())
                    state.done()
                    continue
                }
                let absolute = folder.isEmpty ? rootPath : rootPath + "/" + folder
                // The event folder itself not existing is an answer: every
                // file under it is missing. Anything else unreadable is a
                // hole, and a listing with holes is refused.
                if topSet.contains(folder), LayoutMigrationDisk.lstatEntry(absolute) == nil {
                    state.done()
                    continue
                }
                do {
                    let entries = try DirectoryListing.list(absolute)
                    var children: [String] = []
                    for entry in entries where !NASSyncPlanner.isJunk(entry.name) && entry.name != ".zfs" {
                        let path = folder.isEmpty ? entry.name : folder + "/" + entry.name
                        switch entry.kind {
                        case .file: state.add(path, entry)
                        case .directory: children.append(path)
                        case .symlink, .other: break
                        }
                    }
                    state.push(children)
                    progress?(state.fileCount)
                } catch {
                    state.fail(error)
                }
                state.done()
            }
        }
        if let error = state.error { throw error }
        guard !nasIsGone(rootPath) else {
            throw ToolkitError.commandFailed("The NAS disconnected while it was being listed.")
        }
        var listing = state.listing
        for folder in relative { listing.cover(folder, at: now) }
        return listing
    }

    /// The shared work list of one SMB listing. Workers wait while another
    /// worker may still push subfolders.
    private final class SMBListingState: @unchecked Sendable {
        private let condition = NSCondition()
        private var queue: [String] = []
        private var inFlight = 0
        private(set) var listing: NASTreeListing
        private var firstError: Error?

        init(root: String) {
            listing = NASTreeListing(root: root, method: .smb)
        }

        var error: Error? { condition.withLock { firstError } }
        var fileCount: Int { condition.withLock { listing.entries.count } }

        func push(_ folders: [String]) {
            condition.withLock {
                queue.append(contentsOf: folders)
                condition.broadcast()
            }
        }

        /// The next folder, or nil once nothing is queued or in flight.
        func next() -> String? {
            condition.lock()
            defer { condition.unlock() }
            while queue.isEmpty && inFlight > 0 && firstError == nil { condition.wait() }
            guard firstError == nil, let folder = queue.popLast() else { return nil }
            inFlight += 1
            return folder
        }

        func done() {
            condition.withLock {
                inFlight -= 1
                condition.broadcast()
            }
        }

        func add(_ path: String, _ entry: DirectoryListingEntry) {
            condition.withLock { listing.insert(path, size: entry.size, modifiedAt: entry.modifiedAt) }
        }

        func fail(_ error: Error) {
            condition.withLock {
                if firstError == nil { firstError = error }
                queue.removeAll()
                condition.broadcast()
            }
        }
    }
}

/// Runs a process and streams its stdout in chunks, collecting stderr on
/// the side; kills it after `timeout` or when `onOutput` says stop.
public enum NASRemoteShell {
    public static func stream(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        onOutput: (Data) -> Bool
    ) throws -> NASRemoteLister.StreamResult {
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
        // The read ends are closed when this returns (see `NASRemoteVerifier.run`).
        defer {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }
        let errBox = ErrorOutput()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errBox.set(err.fileHandleForReading.readDataToEndOfFile())
            errDone.signal()
        }
        let timedOut = TimedOutFlag()
        let killer = DispatchWorkItem {
            timedOut.set()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let reader = out.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            if !onOutput(chunk) {
                process.terminate()
                break
            }
        }
        // Drain whatever is left so the child never blocks on a full pipe.
        _ = try? reader.readToEnd()
        process.waitUntilExit()
        killer.cancel()
        errDone.wait()
        if timedOut.value {
            throw ToolkitError.commandFailed("\(executable) timed out after \(Int(timeout)) s.")
        }
        return .init(status: process.terminationStatus, stderr: errBox.value)
    }

    private final class ErrorOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var value: Data { lock.withLock { data } }
        func set(_ value: Data) { lock.withLock { data = value } }
    }

    private final class TimedOutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }
}
