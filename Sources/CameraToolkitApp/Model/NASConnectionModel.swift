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
                self?.status = status
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

    /// The banner's "Reconnect over Ethernet": waits for jobs, then goes.
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
        guard let controller, status.isOnSlowWiFi else {
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

    // MARK: - Network changes

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            // Interfaces and status only: an update that changes neither
            // (a DNS or cost flag) is not worth a check.
            let signature = "\(path.status)|" + path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
            Task { @MainActor in self?.pathChanged(signature: signature) }
        }
        monitor.start(queue: DispatchQueue(label: "org.cameratoolkit.nas-path", qos: .utility))
        pathMonitor = monitor
    }

    private func pathChanged(signature: String) {
        defer { lastPathSignature = signature }
        guard lastPathSignature != nil, signature != lastPathSignature else { return }
        pathDebounce?.cancel()
        pathDebounce = Task { @MainActor [weak self] in
            // Let DHCP and routes settle before looking.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let controller = self?.controller else { return }
            await controller.refresh(trigger: .networkChange)
        }
    }
}
