import CameraToolkitCore
import Darwin
import Foundation

// Sync to NAS benchmark: runs the real `NASSyncService` engine from a
// read-only source folder into a scratch folder on the NAS, once per run
// and configuration, and prints per-run timings.
//
// Safety:
// - the source is only read;
// - every run writes into `<target>/<run-id>/`, where `<target>` must be a
//   folder named `_SyncBenchmark`; after each run that run's folder (and only
//   it) is removed and its absence checked; `--remove-target-at-end` removes
//   the then-empty `_SyncBenchmark` folder itself;
// - nothing about the machine (hosts, paths) is built in: all of it comes
//   from the arguments.
//
//   CameraToolkitSyncBenchmark --source <folder> --target <…/_SyncBenchmark>
//       [--configs old,serial,p4,p4ssh,p8ssh] [--runs 3]
//       [--host <ssh alias>] [--ssh-config <file>] [--ssh-user <user>]
//       [--local-prefix /Volumes/<share>] [--server-prefix /mnt/<pool>/<dataset>]
//       [--zil] [--json <out.jsonl>] [--remove-target-at-end]

struct Arguments {
    var source = ""
    var target = ""
    var configs = ["old", "serial", "p4", "p4ssh", "p8ssh"]
    var runs = 3
    var host: String?
    var sshConfig: String?
    var sshUser: String?
    var localPrefix: String?
    var serverPrefix: String?
    var zil = false
    var zilDataset: String?
    var json: String?
    var removeTargetAtEnd = false
    var interleave = true

    static func parse(_ raw: [String]) throws -> Arguments {
        var parsed = Arguments()
        var iterator = raw.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next() else { throw Failure("\(flag) needs a value") }
            return next
        }
        while let flag = iterator.next() {
            switch flag {
            case "--source": parsed.source = try value(flag)
            case "--target": parsed.target = try value(flag)
            case "--configs": parsed.configs = try value(flag).split(separator: ",").map(String.init)
            case "--runs": parsed.runs = Int(try value(flag)) ?? 3
            case "--host": parsed.host = try value(flag)
            case "--ssh-config": parsed.sshConfig = try value(flag)
            case "--ssh-user": parsed.sshUser = try value(flag)
            case "--local-prefix": parsed.localPrefix = try value(flag)
            case "--server-prefix": parsed.serverPrefix = try value(flag)
            case "--zil": parsed.zil = true
            case "--zil-dataset": parsed.zilDataset = try value(flag)
            case "--json": parsed.json = try value(flag)
            case "--remove-target-at-end": parsed.removeTargetAtEnd = true
            case "--grouped": parsed.interleave = false
            default: throw Failure("Unknown argument \(flag)")
            }
        }
        guard !parsed.source.isEmpty, !parsed.target.isEmpty else { throw Failure("--source and --target are required") }
        return parsed
    }
}

struct Entry {
    var isDirectory: Bool
    var isFile: Bool
    var size: Int64
}

func lstatEntry(_ path: String) -> Entry? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    let kind = info.st_mode & S_IFMT
    return Entry(isDirectory: kind == S_IFDIR, isFile: kind == S_IFREG, size: Int64(info.st_size))
}

struct Failure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct RunResult: Codable {
    var config: String
    var run: Int
    var runID: String
    var files: Int
    var bytes: Int64
    var wallSeconds: Double
    var megabytesPerSecond: Double
    var copied: Int
    var verified: Int
    var failed: Int
    var conflicts: Int
    var hashMismatches: [String]
    var failures: [String]
    var timings: NASSyncTimings
    var zilBefore: [String: Int64]?
    var zilAfter: [String: Int64]?
    var zilDelta: [String: Int64]?
    var cleanedUp: Bool
}

func ssh(_ arguments: Arguments, _ command: String) throws -> String {
    guard let host = arguments.host else { throw Failure("--host is required for SSH") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
    if let config = arguments.sshConfig { args += ["-F", config] }
    if let user = arguments.sshUser { args += ["-l", user] }
    process.arguments = args + ["--", host, command]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.standardError
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Failure("ssh exited \(process.terminationStatus) for: \(command)") }
    return String(decoding: data, as: UTF8.self)
}

/// `zil_commit_count` and the `zil_itx_*` counts from the NAS's global
/// kstat, and with `--zil-dataset` the same counters for that dataset alone
/// (prefixed `ds_`; the global ones include every other dataset's traffic).
func zilCounters(_ arguments: Arguments) throws -> [String: Int64] {
    var command = "cat /proc/spl/kstat/zfs/zil"
    if let dataset = arguments.zilDataset {
        let quoted = NASRemoteVerifier.quote(dataset)
        command += "; echo DATASET; for f in /proc/spl/kstat/zfs/*/objset-*; do awk -v d=\(quoted) '$1==\"dataset_name\" && $3==d {found=1} END {exit !found}' \"$f\" && cat \"$f\"; done; true"
    }
    var counters: [String: Int64] = [:]
    var prefix = ""
    for line in try ssh(arguments, command).split(separator: "\n") {
        if line == "DATASET" { prefix = "ds_"; continue }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3, fields[0].hasPrefix("zil_") || ["writes", "nwritten", "reads", "nread"].contains(String(fields[0])),
              let value = Int64(fields[2]) else { continue }
        counters[prefix + String(fields[0])] = value
    }
    return counters
}

/// Every regular file under `source`, junk skipped, planned to `<runID>/<path under source>`.
func plan(source: String, runID: String) throws -> NASSyncPlan {
    var items: [NASSyncItem] = []
    func walk(_ folder: String, _ relative: String) throws {
        for entry in try DirectoryListing.list(folder) {
            let path = folder + "/" + entry.name
            let rel = relative.isEmpty ? entry.name : relative + "/" + entry.name
            switch entry.kind {
            case .directory: try walk(path, rel)
            case .file where !NASSyncPlanner.isJunk(entry.name):
                items.append(NASSyncItem(sourcePath: path, relativePath: runID + "/" + rel, byteCount: entry.size, modifiedAt: entry.modifiedAt, eventID: nil))
            default: continue
            }
        }
    }
    try walk(source, "")
    return NASSyncPlan(items: items.sorted { $0.relativePath < $1.relativePath })
}

/// Removes `<target>/<runID>` — only it — and proves it is gone.
func removeRun(target: String, runID: String) throws -> Bool {
    precondition((target as NSString).lastPathComponent == "_SyncBenchmark")
    precondition(!runID.isEmpty && !runID.contains("/") && runID != "." && runID != "..")
    let folder = target + "/" + runID
    guard lstatEntry(folder) != nil else { return true }
    try FileManager.default.removeItem(atPath: folder)
    return lstatEntry(folder) == nil
}

func options(_ name: String, _ arguments: Arguments) throws -> NASSyncOptions {
    func remote() throws -> NASRemoteVerifier {
        guard let host = arguments.host, let local = arguments.localPrefix, let server = arguments.serverPrefix else {
            throw Failure("\(name) needs --host, --local-prefix and --server-prefix")
        }
        return .ssh(host: host, user: arguments.sshUser, configFile: arguments.sshConfig, localPrefix: local, serverPrefix: server)
    }
    switch name {
    case "old": return .legacy
    case "serial": return NASSyncOptions(parallelTransfers: 1)
    case "p4": return NASSyncOptions(parallelTransfers: 4)
    case "p8": return NASSyncOptions(parallelTransfers: 8)
    case "p4nocache":
        // F_NOCACHE on the drive read, as the engine before this one did.
        var copy = NASFileIO.CopyOptions.fast
        copy.uncachedSourceRead = true
        return NASSyncOptions(parallelTransfers: 4, copy: copy)
    case "p2ssh": return NASSyncOptions(parallelTransfers: 2, remoteVerifier: try remote())
    case "p4ssh": return NASSyncOptions(parallelTransfers: 4, remoteVerifier: try remote())
    case "p8ssh": return NASSyncOptions(parallelTransfers: 8, remoteVerifier: try remote())
    case "serialssh": return NASSyncOptions(parallelTransfers: 1, remoteVerifier: try remote())
    default: throw Failure("Unknown configuration \(name)")
    }
}

func main() throws {
    let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
    let target = URL(fileURLWithPath: arguments.target).standardizedFileURL.path
    guard (target as NSString).lastPathComponent == "_SyncBenchmark" else {
        throw Failure("--target must be a folder named _SyncBenchmark (refusing \(target))")
    }
    let parent = (target as NSString).deletingLastPathComponent
    guard lstatEntry(parent)?.isDirectory == true else { throw Failure("\(parent) is not mounted or not a folder") }
    guard lstatEntry(arguments.source)?.isDirectory == true else { throw Failure("\(arguments.source) is not a folder") }
    if lstatEntry(target) == nil {
        guard mkdir(target, 0o755) == 0 else { throw Failure("Could not create \(target)") }
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"

    var order: [(String, Int)] = []
    if arguments.interleave {
        for run in 1...arguments.runs { for config in arguments.configs { order.append((config, run)) } }
    } else {
        for config in arguments.configs { for run in 1...arguments.runs { order.append((config, run)) } }
    }
    var results: [RunResult] = []
    var jsonHandle: FileHandle?
    if let json = arguments.json {
        FileManager.default.createFile(atPath: json, contents: nil)
        jsonHandle = FileHandle(forWritingAtPath: json)
        jsonHandle?.seekToEndOfFile()
    }
    for (config, run) in order {
        let syncOptions = try options(config, arguments)
        let runID = "\(config)-r\(run)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4))"
        let syncPlan = try plan(source: arguments.source, runID: runID)
        let zilBefore = arguments.zil ? try zilCounters(arguments) : nil
        FileHandle.standardError.write(Data("[\(config) #\(run)] \(syncPlan.items.count) files, \(syncPlan.totalBytes) bytes → \(runID)\n".utf8))
        let start = ProcessInfo.processInfo.systemUptime
        let report = try NASSyncService(store: nil, options: syncOptions, isCancelled: { false }).sync(syncPlan, nasRoot: URL(fileURLWithPath: target))
        let wall = ProcessInfo.processInfo.systemUptime - start
        let zilAfter = arguments.zil ? try zilCounters(arguments) : nil
        // Independent of the report: every planned file is at its final
        // path with its size.
        let present = syncPlan.items.filter { item in
            lstatEntry(target + "/" + item.relativePath).map { $0.isFile && $0.size == item.byteCount } == true
        }.count
        if present != report.copied.count {
            FileHandle.standardError.write(Data("!! \(present) files present but \(report.copied.count) reported copied\n".utf8))
        }
        let cleaned = try removeRun(target: target, runID: runID)
        var delta: [String: Int64]?
        if let zilBefore, let zilAfter {
            delta = zilAfter.reduce(into: [:]) { $0[$1.key] = $1.value - (zilBefore[$1.key] ?? 0) }
        }
        let result = RunResult(
            config: config, run: run, runID: runID,
            files: syncPlan.items.count, bytes: syncPlan.totalBytes,
            wallSeconds: wall, megabytesPerSecond: Double(syncPlan.totalBytes) / 1_000_000 / wall,
            copied: report.copied.count, verified: report.verifiedCount,
            failed: report.failed.count, conflicts: report.conflicts.count,
            hashMismatches: report.hashMismatches.map { "\($0.path): \($0.reason)" },
            failures: report.failed.map { "\($0.path): \($0.reason)" },
            timings: report.timings,
            zilBefore: zilBefore, zilAfter: zilAfter, zilDelta: delta,
            cleanedUp: cleaned
        )
        results.append(result)
        if !report.hashMismatches.isEmpty {
            FileHandle.standardError.write(Data("!!!! SHA-256 MISMATCH on the NAS: \(result.hashMismatches)\n".utf8))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(result) {
            jsonHandle?.write(data)
            jsonHandle?.write(Data("\n".utf8))
        }
        let t = report.timings
        let zilCommits = delta?["ds_zil_commit_count"].map(String.init) ?? "-"
        let zilItx = delta?["ds_zil_itx_count"].map(String.init) ?? "-"
        let globalCommits = delta?["zil_commit_count"].map(String.init) ?? "-"
        var line = config.padding(toLength: 9, withPad: " ", startingAt: 0) + "#\(run)"
        line += String(format: "  %6.1f s  %6.1f MB/s", wall, result.megabytesPerSecond)
        line += String(format: "  copy %6.1f  flush %6.1f  verify %6.1f  rename %5.1f", t.copySeconds, t.flushSeconds, t.verifySeconds, t.renameSeconds)
        line += "  verified \(result.verified)/\(result.files)  failed \(result.failed)"
        line += "  ds zil_commit +\(zilCommits)  ds zil_itx +\(zilItx)  (global commits +\(globalCommits))  batches \(t.remoteBatches)  fallbacks \(t.remoteFallbacks)"
        line += "  cleaned \(cleaned ? "yes" : "NO")"
        print(line)
        fflush(stdout)
        guard cleaned else { throw Failure("Could not remove \(target)/\(runID); stopping.") }
    }
    try? jsonHandle?.close()
    if arguments.removeTargetAtEnd {
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: target)) ?? []
        // Only an empty benchmark folder (at most Finder's .DS_Store) is removed.
        guard leftovers.allSatisfy({ $0 == ".DS_Store" }) else { throw Failure("\(target) is not empty: \(leftovers)") }
        try FileManager.default.removeItem(atPath: target)
        print(lstatEntry(target) == nil ? "Removed \(target)" : "!! \(target) still exists")
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
