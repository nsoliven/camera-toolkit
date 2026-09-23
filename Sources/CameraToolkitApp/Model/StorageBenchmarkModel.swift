import CameraToolkitCore
import Foundation
import Observation

enum StorageBenchmarkAccess: Hashable, Sendable {
    case readOnly
    case readWrite
}

struct StorageBenchmarkTarget: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var volumeRoot: URL
    var searchRoots: [URL]
    var writeDirectory: URL?
    var roleNames: [String]
    var access: StorageBenchmarkAccess
    var isAvailable: Bool
    var totalCapacity: Int64?
    var volumeInfo: MountedVolumeInfo?

    var roleSummary: String {
        roleNames.joined(separator: " · ")
    }
}

@MainActor
enum StorageBenchmarkTargetDiscovery {
    private struct Builder {
        var id: String
        var name: String
        var volumeRoot: URL
        var searchRoots: [URL] = []
        var writeDirectory: URL?
        var writePriority = Int.max
        var roleNames: Set<String> = []
        var isAvailable = false
        var isReadOnly = false
        var totalCapacity: Int64?
        var volumeInfo: MountedVolumeInfo?
    }

    static func discover(
        configuration: AppConfiguration,
        transferQueue: TransferQueueSnapshot?,
        mountedVolumes: [MountedVolumeInfo],
        fileManager: FileManager = .default
    ) -> [StorageBenchmarkTarget] {
        let mountedVolumes = mountedVolumes
            .filter {
                $0.url.path != "/"
                    && $0.isStorageLike
                    && !$0.isDiskImage
            }
            .sorted { $0.url.path.count > $1.url.path.count }

        let configuredPaths = configuration.configuredLocations.map {
            URL(fileURLWithPath: DashboardModel.expandedPath($0.path), isDirectory: true)
                .standardizedFileURL
        }
        var builders: [String: Builder] = [:]
        let demoRoot = URL(
            fileURLWithPath: DashboardModel.expandedPath(configuration.demoRootPath),
            isDirectory: true
        ).standardizedFileURL

        for volume in mountedVolumes {
            let isConfigured = configuredPaths.contains { isInside($0, root: volume.url) }
            let isExternal = volume.url.path.hasPrefix("/Volumes/")
                && (volume.isRemovable || volume.isEjectable || volume.isNetwork)
            guard isConfigured || isExternal else { continue }

            builders[volume.url.path] = Builder(
                id: volume.url.path,
                name: volume.name.isEmpty ? volume.url.lastPathComponent : volume.name,
                volumeRoot: volume.url,
                searchRoots: isConfigured ? [] : [volume.url],
                roleNames: isConfigured ? [] : ["Connected Drive"],
                isAvailable: true,
                isReadOnly: volume.isReadOnly,
                totalCapacity: volume.totalCapacity,
                volumeInfo: volume
            )
        }

        for location in configuration.configuredLocations {
            let locationURL = URL(
                fileURLWithPath: DashboardModel.expandedPath(location.path),
                isDirectory: true
            ).standardizedFileURL
            if location.role == .importSource, isInside(locationURL, root: demoRoot) {
                continue
            }
            let matchedVolume = mountedVolumes.first { isInside(locationURL, root: $0.url) }
            let builderID = matchedVolume?.url.path ?? "offline:\(locationURL.path)"
            var builder = builders[builderID] ?? Builder(
                id: builderID,
                name: location.name,
                volumeRoot: matchedVolume?.url ?? locationURL,
                isAvailable: matchedVolume != nil && fileManager.fileExists(atPath: locationURL.path),
                isReadOnly: matchedVolume?.isReadOnly ?? false,
                volumeInfo: matchedVolume
            )

            builder.roleNames.insert(roleName(location.role))
            builder.isAvailable = builder.isAvailable || fileManager.fileExists(atPath: locationURL.path)
            switch location.role {
            case .importSource:
                if !builder.searchRoots.contains(locationURL) {
                    builder.searchRoots.append(locationURL)
                }
            case .buffer:
                if fileManager.fileExists(atPath: locationURL.path), builder.writePriority > 0 {
                    builder.writeDirectory = locationURL
                    builder.writePriority = 0
                }
            case .archive:
                if fileManager.fileExists(atPath: locationURL.path), builder.writePriority > 1 {
                    builder.writeDirectory = locationURL
                    builder.writePriority = 1
                }
            }
            builders[builderID] = builder
        }

        if let transferQueue {
            let source = URL(fileURLWithPath: transferQueue.sourcePath, isDirectory: true).standardizedFileURL
            if let volume = mountedVolumes.first(where: { isInside(source, root: $0.url) }),
               var builder = builders[volume.url.path] {
                builder.roleNames.insert("Camera Source")
                if !builder.searchRoots.contains(source) {
                    builder.searchRoots.insert(source, at: 0)
                }
                builders[volume.url.path] = builder
            }
        }

        return builders.values.map { builder in
            // Writing needs a configured Buffer or Photo Library folder on this
            // volume. A camera-source role never grants one, so cards stay
            // read-only — but a drive that is both the Buffer and a camera
            // source still earns the temp-file write test.
            let canWrite = !builder.isReadOnly
                && builder.writeDirectory != nil
                && builder.writeDirectory.map { fileManager.isWritableFile(atPath: $0.path) } == true
            // The sampler first tries the configured source folders, then the
            // volume itself, so a source path that is empty or missing cannot
            // leave a drive full of media looking untestable.
            var searchRoots = builder.searchRoots
            if !searchRoots.contains(builder.volumeRoot) {
                searchRoots.append(builder.volumeRoot)
            }
            return StorageBenchmarkTarget(
                id: builder.id,
                name: builder.name,
                volumeRoot: builder.volumeRoot,
                searchRoots: searchRoots,
                writeDirectory: canWrite ? builder.writeDirectory : nil,
                roleNames: builder.roleNames.sorted(),
                access: canWrite ? .readWrite : .readOnly,
                isAvailable: builder.isAvailable,
                totalCapacity: builder.totalCapacity,
                volumeInfo: builder.volumeInfo
            )
        }
        .sorted {
            let leftRank = rank($0)
            let rightRank = rank($1)
            if leftRank == rightRank { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return leftRank < rightRank
        }
    }

    static func currentSourceTarget(
        in targets: [StorageBenchmarkTarget],
        transferQueue: TransferQueueSnapshot?
    ) -> StorageBenchmarkTarget? {
        let sourceTargets = targets.filter { $0.roleNames.contains("Camera Source") }
        guard let sourcePath = transferQueue?.sourcePath else {
            return sourceTargets.first
        }
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL.path
        return sourceTargets.first { target in
            let root = target.volumeRoot.standardizedFileURL.path
            return source == root || source.hasPrefix(root + "/")
        }
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func roleName(_ role: ConfiguredLocationRole) -> String {
        switch role {
        case .importSource: "Camera Source"
        case .buffer: "Buffer"
        case .archive: "Photo Library"
        }
    }

    private static func rank(_ target: StorageBenchmarkTarget) -> Int {
        if target.roleNames.contains("Camera Source") { return 0 }
        if target.roleNames.contains("Buffer") { return 1 }
        if target.roleNames.contains("Photo Library") { return 2 }
        return 3
    }
}

enum BenchmarkSampleSize: Int64, CaseIterable, Identifiable {
    case quick = 256
    case standard = 512
    case thorough = 1024
    /// Past a drive's fast cache: sustained speed shows up at several GB.
    case gb2 = 2048
    case gb4 = 4096
    case gb8 = 8192
    case gb16 = 16384

    var id: Int64 { rawValue }
    var bytes: Int64 { rawValue * 1024 * 1024 }
    var label: String { rawValue >= 1024 ? "\(rawValue / 1024) GB" : "\(rawValue) MB" }
}

/// One measurable direction. Reads sample existing media anywhere; writes use
/// the hidden temporary file and only exist where writing is allowed.
enum BenchmarkKind: String, Sendable {
    case read
    case write
}

@MainActor
@Observable
final class StorageBenchmarkViewModel {
    var targets: [StorageBenchmarkTarget] = []
    var results: [String: StorageBenchmarkResult] = [:]
    var errors: [String: String] = [:]
    var connectedLinks: [USBLinkSnapshot] = []
    var linkContexts: [String: StorageLinkContext] = [:]
    var activeTargetID: String?
    var activeKind: BenchmarkKind?
    var phase = ""
    var progress = 0.0
    var liveBytesPerSecond = 0.0
    var sampleSize: BenchmarkSampleSize = .quick

    /// Weak so the window's model never keeps the shell alive.
    @ObservationIgnored weak var dashboardModel: DashboardModel?
    /// Background disk work waits at this gate while a target's volume is
    /// being measured — the same gate EventsWorkspace and TileImageLoader use.
    @ObservationIgnored let driveActivityGate: DriveActivityGate
    /// The cable & enclosure stability test for the sheet — shares the
    /// gate so it pauses the same background work as a speed test.
    let stability: StabilityTestViewModel
    /// The drive the stability sheet is open on; nil closes it.
    var stabilityTarget: StorageBenchmarkTarget?
    /// Test seam — production runs the real `StorageBenchmarkService`.
    @ObservationIgnored private let makeService: () -> StorageBenchmarkService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        driveActivityGate: DriveActivityGate = .shared,
        makeService: @escaping () -> StorageBenchmarkService = { StorageBenchmarkService() },
        stability: StabilityTestViewModel? = nil
    ) {
        self.driveActivityGate = driveActivityGate
        self.makeService = makeService
        self.stability = stability ?? StabilityTestViewModel(driveActivityGate: driveActivityGate)
    }

    /// Opens the stability sheet for a drive.
    func presentStability(for target: StorageBenchmarkTarget) {
        guard let dashboardModel else { return }
        stability.present(
            target: target,
            typicalRange: linkContexts[target.id]?.linkTypicalMBps
                ?? linkContexts[target.id]?.typicalRead,
            dashboardModel: dashboardModel
        )
        stabilityTarget = target
    }

    var isRunning: Bool { activeTargetID != nil }

    var pathVerdicts: [StoragePathVerdict] {
        StorageBottleneckAnalysis.verdicts(
            targets: targets,
            results: results,
            contexts: linkContexts,
            transferQueue: dashboardModel?.transferQueue
        )
    }

    func refresh(from model: DashboardModel) {
        guard !isRunning else { return }
        dashboardModel = model
        let configuration = model.configuration
        let transferQueue = model.transferQueue
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let volumes = await MountedVolumeProbe.mountedVolumes()
            guard !Task.isCancelled else { return }
            let targets = StorageBenchmarkTargetDiscovery.discover(
                configuration: configuration,
                transferQueue: transferQueue,
                mountedVolumes: volumes
            )
            self?.targets = targets
            let contexts = await StorageLinkInspector.contexts(for: targets)
            let links = await USBLinkProbe.connectedStorageLinks()
            guard !Task.isCancelled else { return }
            self?.linkContexts = contexts
            self?.connectedLinks = links
        }
    }

    func run(_ target: StorageBenchmarkTarget, kind: BenchmarkKind) {
        start(jobs: [(target, kind)])
    }

    func runAll() {
        let jobs = targets.filter(\.isAvailable).flatMap { target -> [(StorageBenchmarkTarget, BenchmarkKind)] in
            var jobs: [(StorageBenchmarkTarget, BenchmarkKind)] = [(target, .read)]
            if target.access == .readWrite {
                jobs.append((target, .write))
            }
            return jobs
        }
        start(jobs: jobs)
    }

    func cancel() {
        task?.cancel()
        phase = "Cancelling…"
    }

    private func start(jobs: [(StorageBenchmarkTarget, BenchmarkKind)]) {
        guard !isRunning, !jobs.isEmpty else { return }
        guard let dashboardModel, !dashboardModel.isBusy else {
            errors["global"] = "Wait for the current copy or checksum job to finish before measuring storage speed."
            return
        }

        errors["global"] = nil
        dashboardModel.isStorageBenchmarkRunning = true
        let byteCount = sampleSize.bytes
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                activeTargetID = nil
                activeKind = nil
                progress = 0
                liveBytesPerSecond = 0
                dashboardModel.isStorageBenchmarkRunning = false
                dashboardModel.startNextPendingTransferIfPossible()
            }

            for (target, kind) in jobs {
                if Task.isCancelled { break }
                activeTargetID = target.id
                activeKind = kind
                phase = kind == .read
                    ? "Preparing a read test"
                    : "Preparing a temporary write test"
                progress = 0
                liveBytesPerSecond = 0
                errors[target.id] = nil

                do {
                    let result = try await execute(target: target, kind: kind, byteCount: byteCount)
                    merge(result, into: target.id, kind: kind)
                    phase = "Complete"
                    progress = 1
                    liveBytesPerSecond = 0
                } catch is CancellationError {
                    errors[target.id] = "Cancelled. Any temporary speed-test file was removed."
                    break
                } catch {
                    errors[target.id] = error.localizedDescription
                }
            }
            activeKind = nil
        }
    }

    /// A read run replaces the read figure; a write run supplies both the write
    /// figure and the uncached read-back of its temporary file.
    private func merge(_ result: StorageBenchmarkResult, into targetID: String, kind: BenchmarkKind) {
        switch kind {
        case .read:
            let existing = results[targetID]
            results[targetID] = StorageBenchmarkResult(
                read: result.read,
                write: result.write ?? existing?.write,
                sampledFileCount: result.sampledFileCount,
                completedAt: result.completedAt
            )
        case .write:
            results[targetID] = result
        }
    }

    private func execute(
        target: StorageBenchmarkTarget,
        kind: BenchmarkKind,
        byteCount: Int64
    ) async throws -> StorageBenchmarkResult {
        let targetID = target.id
        // Park the app's own background disk work on this volume for the
        // whole measurement so scans, sweeps, and decodes never contend —
        // or pile onto a drive the test may be about to call unresponsive.
        driveActivityGate.pause(target.volumeRoot)
        defer { driveActivityGate.resume(target.volumeRoot) }

        let (updates, continuation) = AsyncStream<FileOperationProgress>.makeStream()
        let progressTask = Task { [weak self] in
            for await update in updates {
                guard let self, self.activeTargetID == targetID else { continue }
                self.phase = update.phase
                self.progress = update.fractionComplete
                self.liveBytesPerSecond = update.bytesPerSecond
            }
        }
        let service = makeService()
        let worker = Task.detached(priority: .userInitiated) {
            let progressHandler: FileOperationProgressHandler = { update in
                continuation.yield(update)
            }
            switch kind {
            case .read:
                return try service.benchmarkReadOnly(
                    searchRoots: target.searchRoots,
                    byteLimit: byteCount,
                    progress: progressHandler
                )
            case .write:
                guard target.access == .readWrite, let directory = target.writeDirectory else {
                    throw ToolkitError.commandFailed("No writable benchmark folder is configured for this drive.")
                }
                return try service.benchmarkReadWrite(
                    directory: directory,
                    byteCount: byteCount,
                    progress: progressHandler
                )
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            continuation.finish()
            _ = await progressTask.result
            return result
        } catch {
            continuation.finish()
            progressTask.cancel()
            throw error
        }
    }
}
