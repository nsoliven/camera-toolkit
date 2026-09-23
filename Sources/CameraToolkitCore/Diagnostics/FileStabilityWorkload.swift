import Darwin
import Foundation

/// The production workload: one hidden temp file inside the allowed write
/// folder, written sequentially in bounded chunks and *cycled* — the write
/// offset wraps at the area cap instead of growing — so a 30-minute soak
/// never owns more than `areaBytes` on disk. Reads are uncached
/// (`F_NOCACHE`) and exFAT/FAT drives get the same gentle treatment as the
/// speed test: no fsync, no preallocation. Read-only drives sample
/// existing media and never open a write descriptor.
public final class FileStabilityWorkload: StabilityWorkload, @unchecked Sendable {
    private let request: StabilityTestRequest
    private let areaBytes: Int64
    private let fileManager: FileManager
    private let gentle: Bool
    private var writeBuffer: [UInt8]

    /// Run-lifetime state: the temp file and how much of it ever held
    /// written data (the read phases never read past this).
    private var tempURL: URL?
    private var highWater: Int64 = 0

    // Per-phase state, opened by `begin` and released by `end`.
    private var writeFD: Int32 = -1
    private var writeOffset: Int64 = 0
    private var readFD: Int32 = -1
    private var readOffset: Int64 = 0
    private var readBuffer: [UInt8] = []
    private var mediaFiles: [(url: URL, size: Int64)] = []
    private var mediaIndex = 0
    private var burst: BurstRunner?

    public init(request: StabilityTestRequest, areaBytes: Int64, fileManager: FileManager = .default) {
        self.request = request
        self.areaBytes = areaBytes
        self.fileManager = fileManager
        self.gentle = request.writeDirectory
            .map(StorageBenchmarkService.needsGentleWrites(in:)) ?? false
        let bufferBytes = Int(min(
            StabilityTestService.writeChunkByteCount,
            max(areaBytes, 1)
        ))
        writeBuffer = [UInt8](repeating: 0, count: bufferBytes)
        writeBuffer.withUnsafeMutableBytes { raw in
            if let address = raw.baseAddress {
                arc4random_buf(address, raw.count)
            }
        }
        readBuffer = [UInt8](repeating: 0, count: StabilityTestService.readChunkByteCount)
    }

    public func begin(phase: StabilityPhaseKind) throws {
        switch phase {
        case .sustainedWrite:
            try beginWrite()
        case .sustainedRead:
            try beginRead()
        case .mixedBurst:
            try beginBurst()
        case .idleWatch:
            break
        }
    }

    public func step(phase: StabilityPhaseKind, shouldStop: @Sendable () -> Bool) throws -> Int64 {
        switch phase {
        case .sustainedWrite:
            return try writeStep()
        case .sustainedRead:
            return try readStep()
        case .mixedBurst:
            guard let burst else { return 0 }
            // A burst worker that hit EIO or EINVAL surfaces its error here
            // so the run fails plainly instead of quietly idling.
            if let error = burst.error { throw error }
            if shouldStop() { return 0 }
            Thread.sleep(forTimeInterval: 0.1)
            return burst.poll()
        case .idleWatch:
            Thread.sleep(forTimeInterval: 0.2)
            return 0
        }
    }

    public func end(phase: StabilityPhaseKind) {
        switch phase {
        case .sustainedWrite:
            closeDescriptor(&writeFD)
        case .sustainedRead:
            closeDescriptor(&readFD)
        case .mixedBurst:
            burst?.stop()
            burst = nil
        case .idleWatch:
            break
        }
    }

    /// Unlinks the temp file and its `._` twin. Descriptors the worker
    /// still owns stay owned — unlinking the path is safe while a parked
    /// syscall holds one open.
    public func cleanup() {
        guard let url = tempURL else { return }
        for candidate in [url, url.deletingLastPathComponent()
            .appendingPathComponent("._\(url.lastPathComponent)")] {
            if fileManager.fileExists(atPath: candidate.path) {
                try? fileManager.removeItem(at: candidate)
            }
        }
        tempURL = nil
    }

    // MARK: - Sustained write

    private func beginWrite() throws {
        guard let directory = request.writeDirectory else {
            throw ToolkitError.commandFailed(
                "This drive is read-only — the stability test never writes to it."
            )
        }
        let url = directory.appendingPathComponent(
            "\(StabilityTestService.temporaryFilePrefix)\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let fd = try openDescriptor(url, flags: O_CREAT | O_WRONLY, permissions: S_IRUSR | S_IWUSR)
        do {
            guard Darwin.fcntl(fd, F_NOCACHE, 1) == 0 else {
                throw posixError(operation: "disable the file cache for", url: url)
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
        tempURL = url
        writeFD = fd
        writeOffset = 0
        // No preallocation: on fskit exFAT an ftruncate zero-fills the whole
        // file up front, and neither it nor fsync is safe there.
    }

    /// Writes one chunk at `writeOffset`, wrapping to 0 at the area cap —
    /// the temp file cycles through a bounded footprint instead of filling
    /// the drive.
    private func writeStep() throws -> Int64 {
        guard writeFD >= 0, let url = tempURL else {
            throw ToolkitError.commandFailed("The stability-test write phase was not opened.")
        }
        let chunk = Int(min(Int64(writeBuffer.count), areaBytes - writeOffset))
        var total = 0
        try writeBuffer.withUnsafeBytes { raw in
            while total < chunk {
                guard let base = raw.baseAddress else { return }
                let written = Darwin.pwrite(writeFD, base + total, chunk - total, off_t(writeOffset + Int64(total)))
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw posixError(operation: "write stability-test data to", url: url)
                }
                total += written
            }
        }
        writeOffset += Int64(total)
        highWater = max(highWater, writeOffset)
        if writeOffset >= areaBytes { writeOffset = 0 }
        if !gentle {
            guard Darwin.fsync(writeFD) == 0 else {
                throw posixError(operation: "flush stability-test data on", url: url)
            }
        }
        return Int64(total)
    }

    // MARK: - Sustained read

    /// Writable drives read back what the write phase laid down; read-only
    /// drives sample existing media — never the other way around.
    private func beginRead() throws {
        if let url = tempURL, highWater > 0 {
            let fd = try openDescriptor(url, flags: O_RDONLY | O_NOFOLLOW)
            do {
                guard Darwin.fcntl(fd, F_NOCACHE, 1) == 0 else {
                    throw posixError(operation: "disable the file cache for", url: url)
                }
            } catch {
                Darwin.close(fd)
                throw error
            }
            readFD = fd
            readOffset = 0
            return
        }
        mediaFiles = discoverMediaFiles()
        guard !mediaFiles.isEmpty else {
            throw ToolkitError.commandFailed(
                "No readable media found on this drive — the stability test samples existing files and writes nothing."
            )
        }
        mediaIndex = 0
    }

    private func readStep() throws -> Int64 {
        // The source is chosen the same way `beginRead` chose: a written
        // temp area means read-back; otherwise media sampling. `readFD`
        // alone cannot decide — media reads hold a descriptor too.
        if tempURL != nil, highWater > 0 {
            return try readStepFromTempFile()
        }
        return try readStepFromMedia()
    }

    /// Sequential uncached read of the temp area, wrapping at the
    /// high-water mark so the phase keeps measuring device reads for its
    /// whole duration.
    private func readStepFromTempFile() throws -> Int64 {
        guard let url = tempURL else {
            throw ToolkitError.commandFailed("The stability-test read phase lost its file.")
        }
        if readOffset >= highWater { readOffset = 0 }
        let wanted = min(Int64(readBuffer.count), highWater - readOffset)
        guard wanted > 0 else {
            throw ToolkitError.commandFailed("The stability-test file has no written data to read.")
        }
        let count = readBuffer.withUnsafeMutableBytes { raw in
            Darwin.pread(readFD, raw.baseAddress, Int(wanted), off_t(readOffset))
        }
        if count < 0, errno == EINTR { return 0 }
        guard count >= 0 else {
            throw posixError(operation: "read stability-test data from", url: url)
        }
        guard count > 0 else { return 0 }
        readOffset += Int64(count)
        return Int64(count)
    }

    /// Sequential reads through the discovered media list, moving to the
    /// next file at EOF and wrapping to the first after the last.
    private func readStepFromMedia() throws -> Int64 {
        guard !mediaFiles.isEmpty else {
            throw ToolkitError.commandFailed(
                "No readable media found on this drive — the stability test samples existing files and writes nothing."
            )
        }
        if readFD < 0 {
            let file = mediaFiles[mediaIndex]
            let fd = try openDescriptor(file.url, flags: O_RDONLY | O_NOFOLLOW)
            do {
                guard Darwin.fcntl(fd, F_NOCACHE, 1) == 0 else {
                    throw posixError(operation: "disable the file cache for", url: file.url)
                }
            } catch {
                Darwin.close(fd)
                throw error
            }
            readFD = fd
        }
        let count = readBuffer.withUnsafeMutableBytes { raw in
            Darwin.read(readFD, raw.baseAddress, raw.count)
        }
        if count < 0, errno == EINTR { return 0 }
        guard count >= 0 else {
            throw posixError(operation: "read media from", url: mediaFiles[mediaIndex].url)
        }
        if count == 0 {
            closeDescriptor(&readFD)
            mediaIndex = (mediaIndex + 1) % mediaFiles.count
            return 0
        }
        return Int64(count)
    }

    // MARK: - Mixed burst

    /// Several parallel readers plus — on writable drives — one writer,
    /// with a mix of small header-sized and large sequential requests.
    /// This mimics the app's own launch burst: a drive walk, stats, header
    /// reads, and thumbnail decodes at once.
    private func beginBurst() throws {
        let runner = BurstRunner()
        let readerCount = request.writeDirectory == nil ? 4 : 3
        if highWater > 0, let url = tempURL {
            for _ in 0..<readerCount {
                runner.add { self.tempFileReaderLoop(runner: $0, url: url) }
            }
            if request.writeDirectory != nil {
                runner.add { self.tempFileWriterLoop(runner: $0) }
            }
        } else {
            let media = mediaFiles.isEmpty ? discoverMediaFiles() : mediaFiles
            guard !media.isEmpty else {
                throw ToolkitError.commandFailed(
                    "No readable media found on this drive — the stability test samples existing files and writes nothing."
                )
            }
            mediaFiles = media
            for index in 0..<readerCount {
                runner.add { self.mediaReaderLoop(runner: $0, startIndex: index) }
            }
        }
        runner.start()
        burst = runner
    }

    /// Random small (64 KB) and large (4 MB) uncached reads over the
    /// written region of the temp file.
    private func tempFileReaderLoop(runner: BurstRunner, url: URL) {
        guard let fd = try? openDescriptor(url, flags: O_RDONLY | O_NOFOLLOW) else { return }
        defer { Darwin.close(fd) }
        guard Darwin.fcntl(fd, F_NOCACHE, 1) == 0 else { return }

        var buffer = [UInt8](repeating: 0, count: StabilityTestService.readChunkByteCount)
        while !runner.shouldStop {
            let span = highWater
            guard span > 0 else { return }
            let bounded = min(
                Int64.random(in: 0..<5) == 0
                    ? Int64(64 * 1024)
                    : Int64(StabilityTestService.readChunkByteCount),
                span
            )
            let offset = Int64.random(in: 0...(span - bounded))
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.pread(fd, raw.baseAddress, Int(bounded), off_t(offset))
            }
            if count < 0 {
                if errno == EINTR { continue }
                runner.noteError(posixError(operation: "read stability-test data from", url: url))
                return
            }
            runner.noteBytes(Int64(max(count, 0)))
        }
    }

    /// The burst writer keeps cycling the bounded temp area in 8 MB
    /// chunks — same discipline as the sustained write.
    private func tempFileWriterLoop(runner: BurstRunner) {
        guard let url = tempURL else { return }
        guard let fd = try? openDescriptor(url, flags: O_WRONLY) else { return }
        defer { Darwin.close(fd) }
        guard Darwin.fcntl(fd, F_NOCACHE, 1) == 0 else { return }

        var offset: Int64 = 0
        while !runner.shouldStop {
            let chunk = Int(min(Int64(writeBuffer.count), areaBytes - offset))
            var total = 0
            var failed: Error?
            writeBuffer.withUnsafeBytes { raw in
                while total < chunk, !runner.shouldStop {
                    guard let base = raw.baseAddress else { return }
                    let written = Darwin.pwrite(fd, base + total, chunk - total, off_t(offset + Int64(total)))
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else {
                        failed = posixError(operation: "write stability-test data to", url: url)
                        return
                    }
                    total += written
                }
            }
            if let failed {
                runner.noteError(failed)
                return
            }
            offset += Int64(total)
            if offset >= areaBytes { offset = 0 }
            runner.noteBytes(Int64(total))
            if !gentle {
                guard Darwin.fsync(fd) == 0 else {
                    runner.noteError(posixError(operation: "flush stability-test data on", url: url))
                    return
                }
            }
        }
    }

    /// Read-only burst: each reader walks the media list at its own pace —
    /// a small header read, then a few larger reads, then the next file —
    /// the shape of a drive walk plus thumbnail decodes.
    private func mediaReaderLoop(runner: BurstRunner, startIndex: Int) {
        var index = startIndex % max(mediaFiles.count, 1)
        var buffer = [UInt8](repeating: 0, count: StabilityTestService.readChunkByteCount)
        while !runner.shouldStop {
            let file = mediaFiles[index]
            guard let fd = try? openDescriptor(file.url, flags: O_RDONLY | O_NOFOLLOW) else {
                index = (index + 1) % mediaFiles.count
                continue
            }
            guard Darwin.fcntl(fd, F_NOCACHE, 1) == 0 else {
                Darwin.close(fd)
                return
            }
            var failed = false
            // Header read first — the cheap stat-plus-thumbnail pattern.
            for readIndex in 0..<4 where !runner.shouldStop {
                let wanted = readIndex == 0
                    ? min(Int64(64 * 1024), file.size)
                    : min(Int64(StabilityTestService.readChunkByteCount), file.size)
                guard wanted > 0 else { break }
                let offset = Int64.random(in: 0...(file.size - wanted))
                let count = buffer.withUnsafeMutableBytes { raw in
                    Darwin.pread(fd, raw.baseAddress, Int(wanted), off_t(offset))
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    runner.noteError(posixError(operation: "read media from", url: file.url))
                    failed = true
                    break
                }
                runner.noteBytes(Int64(max(count, 0)))
            }
            Darwin.close(fd)
            if failed { return }
            index = (index + 1) % mediaFiles.count
        }
    }

    // MARK: - Helpers

    /// Bounded discovery of readable media under the search roots: regular
    /// files only, hidden entries and our own temp files skipped, capped at
    /// `mediaSampleFileLimit` so a huge tree cannot stall the phase start.
    /// The enumerator stays lazy — `break` stops the walk.
    private func discoverMediaFiles() -> [(url: URL, size: Int64)] {
        var files: [(url: URL, size: Int64)] = []
        var seen: Set<String> = []

        func consider(_ url: URL) {
            guard files.count < StabilityTestService.mediaSampleFileLimit else { return }
            let name = url.lastPathComponent
            if name.hasPrefix(StabilityTestService.temporaryFilePrefix)
                || name.hasPrefix(StorageBenchmarkService.temporaryFilePrefix) {
                return
            }
            let fileValues = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            guard fileValues?.isRegularFile == true,
                  fileValues?.isSymbolicLink != true else { return }
            let size = Int64(fileValues?.fileSize ?? 0)
            guard size > 0,
                  seen.insert(url.standardizedFileURL.path).inserted else { return }
            files.append((url, size))
        }

        for root in request.searchRoots.map(\.standardizedFileURL) {
            guard files.count < StabilityTestService.mediaSampleFileLimit else { break }
            let values = try? root.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isRegularFile == true {
                consider(root)
                continue
            }
            guard values?.isDirectory == true,
                  let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: nil
                  ) else { continue }
            for case let url as URL in enumerator {
                consider(url)
            }
        }
        return files
    }

    private func openDescriptor(
        _ url: URL,
        flags: Int32,
        permissions: mode_t = 0
    ) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            if flags & O_CREAT != 0 {
                return Darwin.open(path, flags, permissions)
            }
            return Darwin.open(path, flags)
        }
        guard descriptor >= 0 else {
            throw posixError(operation: "open", url: url)
        }
        return descriptor
    }

    private func closeDescriptor(_ fd: inout Int32) {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    private func posixError(operation: String, url: URL) -> ToolkitError {
        let code = errno
        return .commandFailed(
            "Could not \(operation) \(url.path): \(String(cString: strerror(code))) (errno \(code))"
        )
    }
}

/// The burst phase's workers: a fixed set of threads each running a bounded
/// read or write loop against its own descriptor. Bytes moved are counted
/// so `step` can report progress; the first I/O error is captured so the
/// run can fail plainly. A worker parked inside a dead mount's syscall is
/// abandoned at `stop`'s join bound — it owns its descriptor and exits
/// when the kernel returns, the same containment the supervisor uses.
private final class BurstRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var movedBytes: Int64 = 0
    private var stopRequested = false
    private var firstError: Error?
    private var threads: [Thread] = []

    var shouldStop: Bool {
        lock.withLock { stopRequested }
    }

    var error: Error? {
        lock.withLock { firstError }
    }

    func add(_ body: @escaping @Sendable (BurstRunner) -> Void) {
        threads.append(Thread { [self] in body(self) })
    }

    func start() {
        threads.forEach { $0.start() }
    }

    func noteBytes(_ count: Int64) {
        lock.withLock { movedBytes += count }
    }

    func noteError(_ error: Error) {
        lock.withLock { firstError = firstError ?? error }
    }

    /// Bytes moved since the last call — the per-step progress figure.
    func poll() -> Int64 {
        lock.withLock {
            let bytes = movedBytes
            movedBytes = 0
            return bytes
        }
    }

    /// Signals every worker and waits up to `joinTimeout` for them to
    /// finish. Threads still parked when the bound expires are abandoned —
    /// their descriptors close when the kernel lets the syscall return.
    func stop(joinTimeout: TimeInterval = 3) {
        lock.withLock { stopRequested = true }
        let deadline = Date().addingTimeInterval(joinTimeout)
        for thread in threads {
            while !thread.isFinished, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        threads = []
    }
}
