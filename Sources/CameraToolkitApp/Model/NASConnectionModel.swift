import AppKit
import CameraToolkitCore
import Foundation
import NetFS
import Network
import Observation

/// Mounts with NetFS (no UI, keychain credential), falls back to Finder,
/// and unmounts through NSWorkspace — a normal unmount, which refuses
/// while any file on the share is open. Never sees or stores a password.
struct SystemNASVolumeMounter: NASVolumeMounting {
    func mountWithoutUI(_ url: URL) async -> (outcome: NASMountOutcome, mountPoints: [String]) {
        await withCheckedContinuation { continuation in
            let openOptions = NSMutableDictionary()
            // kNAUIOptionKey / kNAUIOptionNoUI: fail instead of showing a
            // dialog; NetFS still uses the password saved in the keychain.
            openOptions["UIOption"] = "NoUI"
            let mountOptions = NSMutableDictionary()
            var requestID: AsyncRequestID?
            let box = ContinuationBox(continuation)
            let status = NetFSMountURLAsync(
                url as CFURL,
                nil,
                nil,
                nil,
                openOptions as CFMutableDictionary,
                mountOptions as CFMutableDictionary,
                &requestID,
                DispatchQueue.global(qos: .utility)
            ) { status, _, mountPoints in
                let points = (mountPoints as? [String]) ?? []
                box.resume((NASMountOutcome.classify(status: status), points))
            }
            if status != 0 {
                box.resume((NASMountOutcome.classify(status: status), []))
            }
        }
    }

    func openInFinder(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }

    func unmount(mountPoint: String) async throws {
        let url = URL(fileURLWithPath: mountPoint, isDirectory: true)
        try await Task.detached(priority: .userInitiated) {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        }.value
    }

    /// Resumes once even if NetFS both returns an error and calls back.
    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(outcome: NASMountOutcome, mountPoints: [String]), Never>?

        init(_ continuation: CheckedContinuation<(outcome: NASMountOutcome, mountPoints: [String]), Never>) {
            self.continuation = continuation
        }

        func resume(_ value: (outcome: NASMountOutcome, mountPoints: [String])) {
            let pending: CheckedContinuation<(outcome: NASMountOutcome, mountPoints: [String]), Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }
}

/// The main-actor face of `NASConnectionController` for the sidebar: holds
/// the last published status and forwards actions. Every check, mount, and
/// speed test runs in the controller, off the main actor; views read
/// `status` only.
@MainActor
@Observable
final class NASConnectionModel {
    private(set) var status = NASConnectionStatus()

    @ObservationIgnored private var controller: NASConnectionController?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var pathDebounce: Task<Void, Never>?
    @ObservationIgnored private var lastPathSignature: String?
    @ObservationIgnored private var interfacePoll: Task<Void, Never>?
    @ObservationIgnored private var pendingWatcher: Task<Void, Never>?
    /// A switch the app started at a job boundary or after the jobs
    /// ended, set on the main actor before the controller is asked, so
    /// the job queue and `prepareForNASJob` see it at once.
    @ObservationIgnored private(set) var switchInFlight = false
    /// When the job queue began holding its next job for a switch.
    @ObservationIgnored private var queueHeldSince: Date?
    @ObservationIgnored private var lastSwitchEndedAt: Date?
    /// Starts the job queue again after a switch held it.
    @ObservationIgnored var resumeJobQueue: @MainActor () -> Void = {}
    @ObservationIgnored private let mounterFactory: () -> any NASVolumeMounting
    @ObservationIgnored private let inspector: NASConnectionInspector
    @ObservationIgnored private let speedTester: any NASSpeedTesting
    /// True while a NAS job runs or the app has NAS files open.
    @ObservationIgnored var isNASInUse: @MainActor () -> Bool = { false }

    init(
        mounter: @escaping () -> any NASVolumeMounting = { SystemNASVolumeMounter() },
        inspector: NASConnectionInspector = NASConnectionInspector(),
        speedTester: any NASSpeedTesting = NASSpeedTester()
    ) {
        self.mounterFactory = mounter
        self.inspector = inspector
        self.speedTester = speedTester
    }

    var isStarted: Bool { controller != nil }

    /// Launch: the first check, auto-connect, and the network watcher.
    /// Nothing runs until this is called, so tests and previews stay inert.
    func start(settings: NASConnectionSettings) {
        guard controller == nil else { return }
        // One ordered stream, so a later status can never be overwritten
        // by an earlier one that hopped to the main actor late.
        let (updates, continuation) = AsyncStream<NASConnectionStatus>.makeStream(bufferingPolicy: .bufferingNewest(8))
        statusTask = Task { @MainActor [weak self] in
            for await status in updates {
                self?.apply(status)
            }
        }
        let controller = NASConnectionController(
            inspector: inspector,
            mounter: mounterFactory(),
            speedTester: speedTester,
            isNASInUse: { [weak self] in
                await MainActor.run { self?.isNASInUse() ?? true }
            },
            onChange: { status in
                continuation.yield(status)
            }
        )
        self.controller = controller
        Task { await controller.start(settings: settings) }
        startPathMonitor()
        startInterfacePoll()
    }

    func settingsChanged(_ settings: NASConnectionSettings) {
        guard let controller else { return }
        Task { await controller.update(settings: settings) }
    }

    /// "Connect to NAS…".
    func connect() {
        guard let controller else { return }
        Task { await controller.connect(userInitiated: true) }
    }

    /// A volume mounted or unmounted somewhere.
    func volumesChanged() {
        guard let controller else { return }
        Task { await controller.refresh(trigger: .mounted) }
    }

    /// Clicking the status: Connect when offline, otherwise rerun the
    /// speed test (at most every 30 minutes).
    func statusClicked() {
        guard let controller else { return }
        if status.phase == .offline {
            connect()
            return
        }
        Task { await controller.runSpeedTest(onDemand: true) }
    }

    /// The banner's "Switch to Ethernet now": waits for a running job to
    /// finish (never interrupts one), then reconnects.
    func reconnectOverEthernet() {
        guard let controller else { return }
        Task { await controller.reconnectWhenIdle() }
    }

    func cancelReconnect() {
        guard let controller else { return }
        Task { await controller.cancelWaitingToReconnect() }
    }

    /// Before a NAS job: move a Wi-Fi session to Ethernet first when that
    /// is safe, then start the job. Starts it right away when there is
    /// nothing to fix, and after at most `timeout` either way.
    func prepareForNASJob(timeout: Duration = .seconds(45), then start: @escaping @MainActor () -> Void) {
        // Also while a reconnect or speed test runs: the job waits for it.
        guard let controller,
              status.fasterLinkAvailable || status.phase == .reconnecting || status.isTestingSpeed || switchInFlight else {
            start()
            return
        }
        var started = false
        let startOnce: @MainActor () -> Void = {
            guard !started else { return }
            started = true
            start()
        }
        Task { @MainActor in
            await controller.prepareForNASJob()
            startOnce()
        }
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            startOnce()
        }
    }

    /// Takes a status the controller published (tests hand one in).
    func apply(_ status: NASConnectionStatus) {
        self.status = status
        NASLiveLinkRegistry.shared.update(status.snapshot)
        watchPendingSwitch()
    }

    // MARK: - Job boundaries

    /// Asked by the job queue before it starts its next job. True holds
    /// the job back: an automatic switch is waiting for exactly this
    /// moment (the gate free, nothing mid-file) or is already running. The
    /// switch starts here and lets the queue go when it ends; the hold
    /// never outlasts `NASLinkSwitchGate.maximumQueueHold`.
    func claimJobBoundary(now: Date = Date()) -> Bool {
        // Right after a switch the published status can trail by a turn:
        // do not hold the queue again for the switch that just ran.
        let settled = lastSwitchEndedAt.map { now.timeIntervalSince($0) >= 10 } ?? true
        let wanted = settled && (status.linkSwitchPending || status.isWaitingToReconnect) && !isNASInUse()
        let hold = NASLinkSwitchGate.shouldHoldQueue(
            switchWanted: wanted,
            switchRunning: switchInFlight || status.phase == .reconnecting,
            heldSince: queueHeldSince,
            now: now
        )
        guard hold else {
            queueHeldSince = nil
            return false
        }
        if queueHeldSince == nil {
            queueHeldSince = now
            // A backstop: the queue goes on even if the switch never ends.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(NASLinkSwitchGate.maximumQueueHold))
                self?.resumeJobQueue()
            }
        }
        if !switchInFlight { switchAtBoundary() }
        return true
    }

    /// While the automatic switch waits only for jobs, look every couple
    /// of seconds whether they ended; the queue's own boundary is caught
    /// by `claimJobBoundary`.
    private func watchPendingSwitch() {
        guard status.linkSwitchPending else {
            pendingWatcher?.cancel()
            pendingWatcher = nil
            return
        }
        guard pendingWatcher == nil else { return }
        pendingWatcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                guard self.status.linkSwitchPending else { break }
                let settled = self.lastSwitchEndedAt.map { Date().timeIntervalSince($0) >= 10 } ?? true
                if settled, !self.switchInFlight, !self.isNASInUse() {
                    self.switchAtBoundary()
                }
            }
            self?.pendingWatcher = nil
        }
    }

    /// Runs the controller's check at a safe point; it reconnects only
    /// when its own policy still says so (and looks again at the jobs
    /// right before the unmount).
    private func switchAtBoundary() {
        guard let controller, !switchInFlight else { return }
        switchInFlight = true
        Task { @MainActor [weak self] in
            await controller.switchAtSafePoint()
            guard let self else { return }
            self.switchInFlight = false
            self.lastSwitchEndedAt = Date()
            if self.queueHeldSince != nil {
                self.queueHeldSince = nil
                self.resumeJobQueue()
            }
        }
    }

    // MARK: - Network changes

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            // Interfaces and status only: an update that changes neither
            // (a DNS or cost flag) is not worth a check.
            let signature = "\(path.status)|" + path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
            Task { @MainActor in self?.pathChanged(signature: "path:" + signature) }
        }
        monitor.start(queue: DispatchQueue(label: "org.cameratoolkit.nas-path", qos: .utility))
        pathMonitor = monitor
    }

    /// Between path updates, the interfaces' addresses: a DHCP lease that
    /// lands after the link came up, or a route that follows it, is not
    /// always a path update of its own. `getifaddrs` only — no tools run.
    private func startInterfacePoll() {
        interfacePoll = Task { @MainActor [weak self] in
            var last: String?
            while !Task.isCancelled {
                let signature = await Task.detached(priority: .utility) {
                    SystemNASNetworkProbe.interfaceSignature()
                }.value
                if let last, last != signature {
                    self?.networkChanged()
                }
                last = signature
                try? await Task.sleep(for: Self.interfacePollInterval)
            }
        }
    }

    static let interfacePollInterval: Duration = .seconds(3)
    /// After a change: the first look once DHCP and routes settle, then
    /// two more while the SMB client may still be reconnecting by itself
    /// (a pulled cable) or the route catches up.
    static let followUpDelays: [Duration] = [.seconds(2), .seconds(8), .seconds(20)]

    private func pathChanged(signature: String) {
        defer { lastPathSignature = signature }
        guard lastPathSignature != nil, signature != lastPathSignature else { return }
        networkChanged()
    }

    private func networkChanged() {
        pathDebounce?.cancel()
        pathDebounce = Task { @MainActor [weak self] in
            var elapsed: Duration = .zero
            for delay in Self.followUpDelays {
                try? await Task.sleep(for: delay - elapsed)
                elapsed = delay
                guard !Task.isCancelled, let controller = self?.controller else { return }
                await controller.refresh(trigger: .networkChange)
            }
        }
    }
}
