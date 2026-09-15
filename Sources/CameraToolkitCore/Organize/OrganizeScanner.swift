import Foundation

public struct OrganizeScanProgress: Sendable {
    public var phase: String
    public var processed: Int
    public var total: Int

    public init(phase: String, processed: Int, total: Int) {
        self.phase = phase
        self.processed = processed
        self.total = total
    }

    public var fraction: Double {
        total > 0 ? min(max(Double(processed) / Double(total), 0), 1) : 0
    }
}

public struct OrganizeScanResult: Sendable {
    public var rootPath: String
    public var items: [OrganizeItem]
    public var stacks: [OrganizeStack]
    public var days: [OrganizeDay]
    /// Lower-cased file names that appear more than once under the root.
    public var duplicateNames: Set<String>
    /// Camera clock minus file modification time, rounded to 15 minutes.
    public var clockOffset: TimeInterval
    public var scannedAt: Date

    public var fileCount: Int { items.reduce(0) { $0 + 1 + $1.companions.count } }
    public var byteCount: Int64 { items.reduce(Int64(0)) { $0 + $1.byteCount } }

    /// Drops files that have moved away, keeping the rest grouped as before.
    public func removingFiles(withPathKeys keys: Set<String>) -> OrganizeScanResult {
        guard !keys.isEmpty else { return self }
        var copy = self
        copy.items = items.compactMap { item in
            if keys.contains(EventStorageLocations.pathKey(item.primary.path)) { return nil }
            var kept = item
            kept.companions.removeAll { keys.contains(EventStorageLocations.pathKey($0.path)) }
            return kept
        }
        copy.stacks = OrganizeStacker.stacks(for: copy.items)
        copy.days = OrganizeStacker.days(for: copy.stacks)
        return copy
    }
}

/// Reads an unsorted folder into bursts, singles, and capture days.
public struct OrganizeScanner: Sendable {
    public var concurrency: Int

    public init(concurrency: Int = 8) {
        self.concurrency = max(1, concurrency)
    }

    public func scan(
        root: URL,
        cache: CaptureDateCache? = nil,
        progress: (@Sendable (OrganizeScanProgress) -> Void)? = nil
    ) throws -> OrganizeScanResult {
        let rootURL = root.standardizedFileURL
        try FileScanner().assertDirectory(rootURL)
        progress?(OrganizeScanProgress(phase: "Listing files", processed: 0, total: 0))

        let files = try Self.listFiles(root: rootURL) { count in
            progress?(OrganizeScanProgress(phase: "Listing files", processed: count, total: 0))
        }
        var nameCounts: [String: Int] = [:]
        for file in files {
            nameCounts[file.name.lowercased(), default: 0] += 1
        }
        let duplicateNames = Set(nameCounts.filter { $0.value > 1 }.keys)

        let built = Self.items(for: files, cache: cache, concurrency: concurrency, progress: progress)
        progress?(OrganizeScanProgress(phase: "Grouping bursts", processed: 1, total: 1))
        let stacks = OrganizeStacker.stacks(for: built.items)
        return OrganizeScanResult(
            rootPath: rootURL.path,
            items: built.items,
            stacks: stacks,
            days: OrganizeStacker.days(for: stacks),
            duplicateNames: duplicateNames,
            clockOffset: built.clockOffset,
            scannedAt: Date()
        )
    }

    /// Pairs sidecars, reads camera capture times in parallel, and shifts
    /// files without a camera timestamp (such as video) by the folder's
    /// camera-clock offset so they land on the same day as the photos.
    public static func items(
        for files: [OrganizeFile],
        cache: CaptureDateCache?,
        concurrency: Int = 8,
        progress: (@Sendable (OrganizeScanProgress) -> Void)? = nil
    ) -> (items: [OrganizeItem], clockOffset: TimeInterval) {
        let pairings = OrganizeFileClassifier.pair(files)
        let readable = pairings.indices.filter {
            let kind = pairings[$0].kind
            return (kind == .raw || kind == .photo) && CaptureDateReader.canRead(pairings[$0].primary.url)
        }
        let total = readable.count
        progress?(OrganizeScanProgress(phase: "Reading capture times", processed: 0, total: total))

        let timestamps: [CaptureTimestamp?] = parallelMap(
            count: total,
            width: concurrency,
            onCompleted: { completed in
                if completed == total || completed % 50 == 0 {
                    progress?(OrganizeScanProgress(phase: "Reading capture times", processed: completed, total: total))
                }
            },
            transform: { index in
                let file = pairings[readable[index]].primary
                if let cached = cache?.lookup(path: file.path, size: file.size, modifiedAt: file.modifiedAt) {
                    return cached
                }
                let timestamp = CaptureDateReader.timestamp(of: file.url)
                cache?.store(path: file.path, size: file.size, modifiedAt: file.modifiedAt, timestamp: timestamp)
                return timestamp
            }
        )
        try? cache?.save()

        var cameraDates: [Int: Date] = [:]
        for (position, pairingIndex) in readable.enumerated() {
            if let date = timestamps[position]?.date {
                cameraDates[pairingIndex] = date
            }
        }

        var folderDeltas: [String: [TimeInterval]] = [:]
        var allDeltas: [TimeInterval] = []
        for (index, date) in cameraDates {
            let primary = pairings[index].primary
            let delta = date.timeIntervalSince(primary.modifiedAt)
            folderDeltas[primary.folderPath, default: []].append(delta)
            allDeltas.append(delta)
        }
        let rootOffset = roundedMedianOffset(allDeltas) ?? 0
        var folderOffsets: [String: TimeInterval] = [:]
        for (folder, deltas) in folderDeltas where deltas.count >= 3 {
            folderOffsets[folder] = roundedMedianOffset(deltas)
        }

        let items = pairings.enumerated().map { index, pairing -> OrganizeItem in
            if let date = cameraDates[index] {
                return OrganizeItem(
                    primary: pairing.primary,
                    companions: pairing.companions,
                    kind: pairing.kind,
                    captureDate: date,
                    hasCameraDate: true
                )
            }
            let offset = folderOffsets[pairing.primary.folderPath] ?? rootOffset
            return OrganizeItem(
                primary: pairing.primary,
                companions: pairing.companions,
                kind: pairing.kind,
                captureDate: pairing.primary.modifiedAt.addingTimeInterval(offset),
                hasCameraDate: false
            )
        }
        return (items, rootOffset)
    }

    static let skippedDirectoryNames: Set<String> = [
        "$recycle.bin", "system volume information", "_trash", ".camera toolkit"
    ]

    static func listFiles(root: URL, progress: ((Int) -> Void)? = nil) throws -> [OrganizeFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var files: [OrganizeFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = url.lastPathComponent
            if values.isDirectory == true {
                if skippedDirectoryNames.contains(name.lowercased()) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, values.isPackage != true else { continue }
            let relative = FileScanner.relativePath(for: url, under: root)
            guard !ExclusionMatcher.isExcluded(relative) else { continue }
            files.append(OrganizeFile(
                path: url.standardizedFileURL.path,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
            if files.count % 500 == 0 {
                progress?(files.count)
            }
        }
        return files
    }

    static func roundedMedianOffset(_ deltas: [TimeInterval]) -> TimeInterval? {
        guard !deltas.isEmpty else { return nil }
        let sorted = deltas.sorted()
        let median = sorted[sorted.count / 2]
        return (median / 900).rounded() * 900
    }

    /// Bounded, order-preserving parallel map.
    public static func parallelMap<T: Sendable>(
        count: Int,
        width: Int,
        onCompleted: (@Sendable (Int) -> Void)? = nil,
        transform: @Sendable (Int) -> T
    ) -> [T] {
        guard count > 0 else { return [] }
        let box = ParallelMapBox<T>(count: count)
        DispatchQueue.concurrentPerform(iterations: min(max(width, 1), count)) { _ in
            while let index = box.nextIndex() {
                let value = transform(index)
                let completed = box.store(value, at: index)
                onCompleted?(completed)
            }
        }
        return box.values()
    }
}

private final class ParallelMapBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [T?]
    private var next = 0
    private var completed = 0

    init(count: Int) {
        results = Array(repeating: nil, count: count)
    }

    func nextIndex() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard next < results.count else { return nil }
        let index = next
        next += 1
        return index
    }

    func store(_ value: T, at index: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        results[index] = value
        completed += 1
        return completed
    }

    func values() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return results.map { $0! }
    }
}
