import Foundation

public struct DiskSpeedTester {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func run(
        folder: URL,
        bytes: Int64 = 128 * 1024 * 1024,
        progress: FileOperationProgressHandler? = nil
    ) throws -> DiskSpeedReport {
        try FileScanner(fileManager: fileManager).assertDirectory(folder)
        let testURL = folder.appendingPathComponent(".camera-toolkit-speed-\(UUID().uuidString).bin")
        defer { try? fileManager.removeItem(at: testURL) }

        let chunkSize = 4 * 1024 * 1024
        let chunk = Data(repeating: 0xA5, count: chunkSize)
        guard fileManager.createFile(atPath: testURL.path, contents: nil) else {
            throw ToolkitError.commandFailed("Could not create speed test file at \(testURL.path)")
        }

        let writeStartedAt = Date()
        var written: Int64 = 0
        let writer = try FileHandle(forWritingTo: testURL)
        do {
            while written < bytes {
                let remaining = Int(bytes - written)
                let count = min(chunkSize, remaining)
                try writer.write(contentsOf: count == chunkSize ? chunk : Data(chunk.prefix(count)))
                written += Int64(count)
                progress?(
                    FileOperationProgress(
                        phase: "Writing test file",
                        currentPath: testURL.lastPathComponent,
                        processedFiles: 0,
                        totalFiles: 1,
                        processedBytes: written,
                        totalBytes: bytes * 2,
                        bytesPerSecond: rate(bytes: written, since: writeStartedAt)
                    )
                )
            }
            try writer.synchronize()
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }

        let writeRate = rate(bytes: written, since: writeStartedAt)
        let readStartedAt = Date()
        var read: Int64 = 0
        var progressLimiter = FileOperationProgressLimiter()
        try StreamingFileIO.readChunks(from: testURL, chunkSize: chunkSize) { chunk in
            read += Int64(chunk.count)
            if progressLimiter.shouldEmit(force: read == bytes) {
                progress?(
                    FileOperationProgress(
                        phase: "Reading test file",
                        currentPath: testURL.lastPathComponent,
                        processedFiles: 1,
                        totalFiles: 1,
                        processedBytes: bytes + read,
                        totalBytes: bytes * 2,
                        bytesPerSecond: rate(bytes: read, since: readStartedAt)
                    )
                )
            }
        }

        return DiskSpeedReport(
            path: folder.path,
            bytes: bytes,
            writeBytesPerSecond: writeRate,
            readBytesPerSecond: rate(bytes: read, since: readStartedAt)
        )
    }

    private func rate(bytes: Int64, since date: Date) -> Double {
        let elapsed = max(Date().timeIntervalSince(date), 0.001)
        return Double(bytes) / elapsed
    }
}
