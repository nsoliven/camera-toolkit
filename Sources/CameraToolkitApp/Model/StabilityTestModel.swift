import AppKit
import CameraToolkitCore
import Foundation
import Observation

/// The operation the model runs on a detached task — production wraps
/// `StabilityTestService.run`; tests substitute a fake so the model is
/// exercised without touching real storage.
typealias StabilityRunOperation = @Sendable (
    StabilityTestRequest,
    @escaping @Sendable (StabilityTestUpdate) -> Void
) throws -> StabilityTestRecord

/// View model behind the Stability sheet: owns the cable/port labels and
/// profile pickers, the live run state (phase, countdowns, per-second
/// throughput, counter deltas, mount state), the verdict, and this drive's
/// history.
@MainActor
@Observable
final class StabilityTestViewModel {
    /// Weak so the sheet never keeps the shell alive.
    @ObservationIgnored weak var dashboardModel: DashboardModel?
    @ObservationIgnored private let driveActivityGate: DriveActivityGate
    @ObservationIgnored private let historyStore: StabilityHistoryStore
    @ObservationIgnored private let probe: any USBPortHealthProbing
    @ObservationIgnored private let runner: StabilityRunOperation
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    // MARK: - Setup

    private(set) var target: StorageBenchmarkTarget?
    var selectedProfile: StabilityProfile = .standard
    var cableLabel = ""
    var portLabel = ""
    /// The port derived from the registry location when the probe could
    /// read it — preselected in the picker.
    private(set) var detectedPortLabel: String?
    private(set) var knownCableLabels: [String] = []
    private(set) var enclosure: USBDeviceIdentity?
    private var typicalRangeMBps: ClosedRange<Double>?
    private var volumeUUID: String?

    // MARK: - Live run state

    private(set) var isRunning = false
    private(set) var phaseTitle = ""
    private(set) var phaseIndex = 0
    private(set) var phaseCount = 0
    private(set) var phaseRemaining: TimeInterval = 0
    private(set) var runRemaining: TimeInterval = 0
    private(set) var liveBytesPerSecond: Double = 0
    private(set) var throughputHistory: [Double] = []
    private(set) var counterDelta: [String: Int64] = [:]
    private(set) var usbCountersAvailable = true
    private(set) var mounted = true
    private(set) var linkBitsPerSecond: Int64?

    // MARK: - Outcome

    private(set) var verdict: StabilityVerdict?
    private(set) var record: StabilityTestRecord?
    private(set) var errorMessage: String?
    private(set) var history: [StabilityTestRecord] = []

    /// Roughly the run's history window kept for the live graph.
    static let historyLimit = 240

    init(
        driveActivityGate: DriveActivityGate = .shared,
        historyStore: StabilityHistoryStore = StabilityHistoryStore(
            url: StabilityHistoryStore.defaultFileURL(
                applicationSupport: DashboardModel.defaultApplicationSupportURL
            )
        ),
        probe: any USBPortHealthProbing = USBPortHealthProbe(),
        runner: @escaping StabilityRunOperation = { request, updates in
            try StabilityTestService().run(request, updates: updates)
        }
    ) {
        self.driveActivityGate = driveActivityGate
        self.historyStore = historyStore
        self.probe = probe
        self.runner = runner
    }

    var canWrite: Bool { target?.access == .readWrite }

    /// The test refuses to start while a copy/checksum job is live.
    var isDashboardBusy: Bool { dashboardModel?.isBusy ?? false }

    var portChoices: [String] {
        var choices: [String] = []
        if let detectedPortLabel, !choices.contains(detectedPortLabel) {
            choices.append(detectedPortLabel)
        }
        choices += (1...4).map { "USB-C port \($0)" }
        choices += ["Dock or hub"]
        if !portLabel.isEmpty, !choices.contains(portLabel) {
            choices.append(portLabel)
        }
        return choices
    }

    /// Opens the sheet for a drive: resets the run state, loads this
    /// drive's history, and probes the port once so the picker can offer
    /// the detected label.
    func present(
        target: StorageBenchmarkTarget,
        typicalRange: ClosedRange<Double>?,
        dashboardModel: DashboardModel
    ) {
        self.target = target
        self.dashboardModel = dashboardModel
        typicalRangeMBps = typicalRange
        verdict = nil
        record = nil
        errorMessage = nil
        throughputHistory = []
        counterDelta = [:]
        mounted = true
        usbCountersAvailable = true

        let volumeRoot = target.volumeRoot
        let probe = self.probe
        probeTask?.cancel()
        probeTask = Task.detached(priority: .utility) { [weak self] in
            let sample = probe.sample(volumeRoot: volumeRoot)
            let uuid = try? volumeRoot.resourceValues(
                forKeys: [.volumeUUIDStringKey]
            ).volumeUUIDString
            await MainActor.run {
                guard let self, self.target?.id == target.id else { return }
                self.enclosure = sample?.device
                self.volumeUUID = uuid
                self.usbCountersAvailable = !(sample?.counters.isEmpty ?? true)
                self.detectedPortLabel = USBPortHealthParser.portLabel(
                    forLocation: sample?.deviceLocation
                )
                if self.portLabel.isEmpty, let detected = self.detectedPortLabel {
                    self.portLabel = detected
                }
                self.reloadHistory()
            }
        }
        knownCableLabels = historyStore.load().knownCableLabels
        reloadHistory()
    }

    func start() {
        guard !isRunning, let target, target.isAvailable else { return }
        guard let dashboardModel, !dashboardModel.isBusy else {
            errorMessage = "Wait for the current copy or checksum job to finish before running a stability test."
            return
        }
        errorMessage = nil
        verdict = nil
        record = nil
        isRunning = true
        mounted = true
        throughputHistory = []
        counterDelta = [:]
        phaseTitle = "Preparing…"
        dashboardModel.isStorageBenchmarkRunning = true
        driveActivityGate.pause(target.volumeRoot)

        let request = StabilityTestRequest(
            volumeRoot: target.volumeRoot,
            writeDirectory: target.access == .readWrite ? target.writeDirectory : nil,
            searchRoots: target.searchRoots,
            profile: selectedProfile,
            typicalRangeMBps: typicalRangeMBps,
            volumeUUID: volumeUUID,
            cableLabel: cableLabel.trimmingCharacters(in: .whitespacesAndNewlines),
            portLabel: portLabel
        )
        let runner = self.runner
        let gate = driveActivityGate
        let volumeRoot = target.volumeRoot
        task = Task { [weak self] in
            defer {
                gate.resume(volumeRoot)
                dashboardModel.isStorageBenchmarkRunning = false
                dashboardModel.startNextPendingTransferIfPossible()
            }
            guard let self else { return }
            let (updates, continuation) = AsyncStream<StabilityTestUpdate>.makeStream()
            let progressTask = Task { [weak self] in
                for await update in updates {
                    self?.apply(update)
                }
            }
            let worker = Task.detached(priority: .userInitiated) {
                try runner(request) { continuation.yield($0) }
            }
            do {
                let record = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                continuation.finish()
                _ = await progressTask.result
                self.finish(record)
            } catch is CancellationError {
                continuation.finish()
                progressTask.cancel()
                self.phaseTitle = "Cancelled — the temporary file was removed."
                self.isRunning = false
            } catch {
                continuation.finish()
                progressTask.cancel()
                self.errorMessage = error.localizedDescription
                self.isRunning = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        phaseTitle = "Stopping…"
    }

    /// Builds the plain-text report for a record and puts it on the
    /// clipboard.
    func copyReport(for record: StabilityTestRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            StabilityReportFormatter.text(for: record),
            forType: .string
        )
    }

    /// One live tick from the worker.
    private func apply(_ update: StabilityTestUpdate) {
        guard isRunning else { return }
        phaseTitle = update.phase?.title ?? "Preparing…"
        phaseIndex = update.phaseIndex
        phaseCount = update.phaseCount
        phaseRemaining = update.phaseRemaining
        runRemaining = update.runRemaining
        liveBytesPerSecond = update.bytesPerSecond
        mounted = update.mounted
        usbCountersAvailable = update.usbCountersAvailable
        counterDelta = update.counterDelta
        linkBitsPerSecond = update.linkBitsPerSecond
        if let device = update.device { enclosure = device }
        if detectedPortLabel == nil {
            detectedPortLabel = update.detectedPortLabel
        }
        if update.phase?.movesBytes == true {
            throughputHistory.append(update.bytesPerSecond)
            if throughputHistory.count > Self.historyLimit {
                throughputHistory.removeFirst(throughputHistory.count - Self.historyLimit)
            }
        }
    }

    private func finish(_ record: StabilityTestRecord) {
        isRunning = false
        phaseTitle = "Complete"
        liveBytesPerSecond = 0
        self.record = record
        verdict = StabilityVerdict(
            grade: record.grade,
            headline: record.headline,
            reasons: record.reasons,
            advice: record.advice
        )
        do {
            try historyStore.append(record)
        } catch {
            errorMessage = "The run finished, but its result could not be saved: \(error.localizedDescription)"
        }
        knownCableLabels = historyStore.load().knownCableLabels
        reloadHistory()
    }

    private func reloadHistory() {
        history = historyStore.load().records(
            forVolumeUUID: volumeUUID,
            enclosure: enclosure
        )
    }
}
