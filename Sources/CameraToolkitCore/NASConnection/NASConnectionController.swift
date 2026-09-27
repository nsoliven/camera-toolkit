import Foundation

/// Mounting and unmounting the share, behind a protocol so tests never
/// touch a real volume.
public protocol NASVolumeMounting: Sendable {
    /// Mounts `url` with no UI, using the credential saved in the keychain.
    /// Returns the outcome and the mount points NetFS reports.
    func mountWithoutUI(_ url: URL) async -> (outcome: NASMountOutcome, mountPoints: [String])
    /// Opens `url` so Finder mounts it and asks for a password itself.
    func openInFinder(_ url: URL) async -> Bool
    /// A normal (not forced) unmount: it fails while files are open.
    func unmount(mountPoint: String) async throws
}

public protocol NASSpeedTesting: Sendable {
    func run(root: URL) throws -> NASSpeedTestResult
    func removeStaleTestFiles(in root: URL) -> [String]
}

extension NASSpeedTester: NASSpeedTesting {
    public func run(root: URL) throws -> NASSpeedTestResult {
        try run(root: root, now: Date.init)
    }

    public func removeStaleTestFiles(in root: URL) -> [String] {
        Self.removeStaleTestFiles(in: root)
    }
}

public struct NASConnectionSettings: Sendable, Equatable {
    /// The NAS mirror root (`EventStorageLocations.nasRoot`).
    public var nasRoot: URL
    /// The configured `smb://` share, nil when none is set.
    public var shareURL: URL?
    /// "Connect to the NAS automatically" — auto-connect at launch and
    /// automatic Wi-Fi → Ethernet reconnects.
    public var automatic: Bool

    public init(nasRoot: URL, shareURL: URL?, automatic: Bool) {
        self.nasRoot = nasRoot
        self.shareURL = shareURL
        self.automatic = automatic
    }

    /// `/Volumes/<share>` holding the NAS root; nil for a local folder.
    public var mountPoint: String? {
        VolumeInfo.volumeRoot(for: nasRoot)?.standardizedFileURL.path
    }

    /// A share address that is really `smb://host/share`.
    public static func shareURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "smb", url.host != nil else { return nil }
        return url
    }
}

/// What the sidebar shows about the NAS.
public struct NASConnectionStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// No NAS folder on a network volume, or nothing checked yet.
        case notConfigured
        case offline
        case connecting
        case connected
        case reconnecting
        /// The NAS folder's volume is mounted but is not an SMB share.
        case notSMB
    }

    public var phase: Phase = .notConfigured
    public var snapshot: NASConnectionSnapshot?
    public var speed: NASSpeedTestResult?
    public var isTestingSpeed = false
    public var speedTestError: String?
    public var banner: NASGuardBannerReason?
    /// Waiting for NAS jobs to finish before reconnecting (banner button).
    public var isWaitingToReconnect = false
    /// The last connect/reconnect note ("Moved the NAS connection to Ethernet.").
    public var message: String?
    public var hasShareURL = false

    public init() {}

    /// "Ethernet 1 GbE", "Wi-Fi ⚠︎", "Thunderbolt", "Connected".
    public var linkLabel: String {
        guard let interface = snapshot?.primarySessionInterface, let kind = snapshot?.sessionKind else {
            return "Connected"
        }
        switch kind {
        case .wifi:
            return "Wi-Fi ⚠︎"
        case .ethernet, .thunderbolt:
            if let speed = interface.linkSpeedMbps, speed > 0 {
                return "\(kind.displayName) \(NASInterfaceClassifier.linkSpeedLabel(mbps: speed))"
            }
            return kind.displayName
        case .other:
            return interface.displayName ?? interface.bsdName
        }
    }

    /// "NAS · Ethernet 1 GbE · 75 MB/s", "NAS · Wi-Fi ⚠︎", "NAS · Offline".
    public var title: String {
        switch phase {
        case .notConfigured: return "NAS · Not Set Up"
        case .offline: return "NAS · Offline"
        case .connecting: return "NAS · Connecting…"
        case .reconnecting: return "NAS · Reconnecting…"
        case .notSMB: return "NAS · Local Volume"
        case .connected:
            var parts = ["NAS", linkLabel]
            if isTestingSpeed {
                parts.append("Testing…")
            } else if let rate = speed?.writeMegabytesPerSecond {
                parts.append(NASSpeedTestMath.rateLabel(rate))
            }
            return parts.joined(separator: " · ")
        }
    }

    public var isOnSlowWiFi: Bool {
        phase == .connected && snapshot?.sessionKind == .wifi && snapshot?.hasWiredRoute == true
    }

    /// The tooltip: interface, route, and the speed test with its age.
    public func detail(now: Date) -> String {
        var lines: [String] = []
        if let snapshot, snapshot.isMounted {
            if let interface = snapshot.primarySessionInterface {
                let name = interface.displayName.map { "\($0) (\(interface.bsdName))" } ?? interface.bsdName
                lines.append("Session over \(name)")
                if snapshot.session?.confidence == .measuredBySpeedTest {
                    lines.append("Link measured by the speed test (macOS does not show Camera Toolkit its network connections)")
                }
            } else if snapshot.socketListHidden {
                lines.append("macOS does not show Camera Toolkit its network connections; the next speed test will tell which link the NAS uses")
            } else {
                lines.append("Could not tell which interface the SMB session uses")
            }
            if let wired = snapshot.wiredRoutes.first, snapshot.sessionKind == .wifi {
                lines.append("A wired route is up on \(wired.displayName ?? wired.bsdName) (\(wired.bsdName))")
            }
        } else if phase == .offline {
            lines.append(hasShareURL ? "The NAS share is not mounted. Click Connect." : "The NAS share is not mounted. Set its smb:// address in Settings → Locations.")
        }
        if let speed {
            var line = "Speed test \(NASSpeedTestMath.ageLabel(since: speed.finishedAt, now: now))"
            if let write = speed.writeMegabytesPerSecond { line += ": write \(NASSpeedTestMath.rateLabel(write))" }
            if let read = speed.readMegabytesPerSecond { line += ", read \(NASSpeedTestMath.rateLabel(read))" }
            line += ", small file \(NASSpeedTestMath.latencyLabel(milliseconds: speed.smallWriteMilliseconds)) write / \(NASSpeedTestMath.latencyLabel(milliseconds: speed.smallReadMilliseconds)) read"
            lines.append(line)
        }
        if let speedTestError { lines.append(speedTestError) }
        if let message { lines.append(message) }
        return lines.joined(separator: "\n")
    }
}

/// Connects the NAS share, watches which link its SMB session uses, moves
/// it off Wi-Fi when a wired link is up, and runs the quick speed test.
/// An actor: every check and file operation runs off the main actor; the
/// app observes `onChange`.
public actor NASConnectionController {
    public static let onDemandSpeedTestInterval: TimeInterval = 30 * 60

    private let inspector: NASConnectionInspector
    private let mounter: any NASVolumeMounting
    private let speedTester: any NASSpeedTesting
    private let now: @Sendable () -> Date
    private let isNASInUse: @Sendable () async -> Bool
    private let onChange: @Sendable (NASConnectionStatus) -> Void

    public private(set) var settings: NASConnectionSettings?
    public private(set) var status = NASConnectionStatus()
    public private(set) var limiter: NASReconnectRateLimiter
    /// True while a connect, reconnect, or speed test owns the share —
    /// checks that arrive meanwhile only refresh the status.
    private var isBusy = false
    /// The mount the last speed test ran against (mount point + source),
    /// so a fresh mount always gets a test and the same one does not.
    private var testedMount: String?
    private var didAutoConnect = false
    /// The interface the last speed test's writes went out on, for the
    /// session it ran against (see `NASTrafficAttribution`).
    private var measured: (mountKey: String, interface: String)?
    private var waitTask: Task<Void, Never>?

    public init(
        inspector: NASConnectionInspector = NASConnectionInspector(),
        mounter: any NASVolumeMounting,
        speedTester: any NASSpeedTesting = NASSpeedTester(),
        limiter: NASReconnectRateLimiter = NASReconnectRateLimiter(),
        now: @escaping @Sendable () -> Date = Date.init,
        isNASInUse: @escaping @Sendable () async -> Bool,
        onChange: @escaping @Sendable (NASConnectionStatus) -> Void
    ) {
        self.inspector = inspector
        self.mounter = mounter
        self.speedTester = speedTester
        self.limiter = limiter
        self.now = now
        self.isNASInUse = isNASInUse
        self.onChange = onChange
    }

    // MARK: - Entry points

    /// Launch: check, auto-connect when allowed, guard, first speed test.
    public func start(settings: NASConnectionSettings) async {
        self.settings = settings
        await refresh(trigger: .launch)
        await autoConnectIfNeeded()
    }

    public func update(settings: NASConnectionSettings) async {
        guard settings != self.settings else { return }
        let rootChanged = settings.nasRoot != self.settings?.nasRoot
        self.settings = settings
        if rootChanged { testedMount = nil }
        await refresh(trigger: .networkChange)
        // The configuration can load after launch: auto-connect then.
        await autoConnectIfNeeded()
    }

    /// Once per launch: mount the share when it is configured, allowed,
    /// and not mounted. Never retried in a loop — the user has Connect.
    private func autoConnectIfNeeded() async {
        guard let settings, !didAutoConnect, settings.automatic, settings.shareURL != nil,
              settings.mountPoint != nil, status.phase == .offline else { return }
        didAutoConnect = true
        await connect(userInitiated: false)
    }

    /// Re-inspects, then lets the guard act on `trigger`.
    @discardableResult
    public func refresh(trigger: NASGuardTrigger) async -> NASGuardDecision {
        // A connect, reconnect, or speed test in flight owns the status; the
        // mount notifications it causes must not flip it to Offline midway.
        guard !isBusy else { return .nothing }
        await inspectNow()
        guard !isBusy else { return .nothing }
        let decision = await evaluateGuard(userRequested: trigger == .userRequested)
        if decision == .reconnect {
            await reconnect(userRequested: trigger == .userRequested)
        } else if status.phase == .connected, needsSpeedTest, !(await isNASInUse()) {
            await runSpeedTest(onDemand: false)
            // The test may just have shown the session is on Wi-Fi (when
            // the socket list is hidden, it is the only way to tell).
            if await evaluateGuard(userRequested: false) == .reconnect {
                await reconnect(userRequested: false)
                return .reconnect
            }
        }
        return decision
    }

    /// Before a NAS job: move a Wi-Fi session to Ethernet first when that
    /// is safe. Returns once the share is as good as it will get.
    public func prepareForNASJob() async {
        guard !isBusy else { return }
        await inspectNow()
        guard !isBusy else { return }
        if await evaluateGuard(userRequested: false) == .reconnect {
            await reconnect(userRequested: false)
        }
    }

    /// "Connect to NAS…" (user) or the launch auto-connect: NetFS with no
    /// UI first, Finder's dialog when a password is needed.
    public func connect(userInitiated: Bool) async {
        guard let settings, let mountPoint = settings.mountPoint, !isBusy else { return }
        await inspectNow()
        if status.snapshotIsMounted {
            await refresh(trigger: userInitiated ? .userRequested : .mounted)
            return
        }
        guard let url = settings.shareURL, !isBusy else { return }
        isBusy = true
        status.phase = .connecting
        status.message = nil
        publish()
        let (outcome, _) = await mounter.mountWithoutUI(url)
        isBusy = false
        switch outcome {
        case .mounted, .alreadyMounted:
            await inspectNow()
            if status.snapshotIsMounted {
                status.message = nil
                await cleanStaleTestFiles()
                testedMount = nil
                measured = nil
                await refresh(trigger: .mounted)
            } else {
                status.message = "The share mounted, but not at \(mountPoint). Check the NAS folder in Settings → Locations."
                publish()
            }
        case .unreachable:
            await inspectNow()
            status.message = "The NAS did not answer at \(url.host(percentEncoded: false) ?? "its address")."
            publish()
        case .cancelled:
            await inspectNow()
        case .needsUserInteraction:
            // No saved password (or NetFS wants to ask): Finder asks. The
            // volume observer refreshes once it mounts.
            _ = await mounter.openInFinder(url)
            await inspectNow()
            status.message = "Finder is asking for the NAS password. Check “Remember this password” to connect automatically next time."
            publish()
        }
    }

    /// The banner's button: waits until nothing uses the NAS, then
    /// reconnects over the wired link.
    public func reconnectWhenIdle() {
        guard waitTask == nil else { return }
        status.isWaitingToReconnect = true
        publish()
        waitTask = Task { [weak self] in
            await self?.waitAndReconnect()
        }
    }

    public func cancelWaitingToReconnect() {
        waitTask?.cancel()
        waitTask = nil
        status.isWaitingToReconnect = false
        publish()
    }

    /// Clicking the status: rerun the speed test, at most every 30 min.
    /// Returns false when it was skipped (too recent, busy, or a job runs).
    @discardableResult
    public func runSpeedTest(onDemand: Bool) async -> Bool {
        await runSpeedTest(onDemand: onDemand, heldByCaller: false)
    }

    /// `heldByCaller`: a reconnect already owns `isBusy` and keeps it.
    private func runSpeedTest(onDemand: Bool, heldByCaller: Bool) async -> Bool {
        guard let settings, status.phase == .connected, heldByCaller || !isBusy else { return false }
        if onDemand, let last = status.speed?.finishedAt,
           now().timeIntervalSince(last) < Self.onDemandSpeedTestInterval {
            return false
        }
        guard !(await isNASInUse()) else {
            status.speedTestError = "Speed test skipped while a NAS job runs."
            publish()
            return false
        }
        isBusy = true
        status.isTestingSpeed = true
        status.speedTestError = nil
        publish()
        let tester = speedTester
        let probe = inspector.probe
        let root = settings.mountPoint.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? settings.nasRoot
        let testedKey = currentMountKey
        let (result, sender) = await Task.detached(priority: .utility) { () -> (Result<NASSpeedTestResult, Error>, String?) in
            // Leftovers of an earlier test that a crash or a dropped share
            // left behind — exact name pattern only.
            _ = tester.removeStaleTestFiles(in: root)
            let before = probe.interfaceSentByteCounters()
            let result = Result { try tester.run(root: root) }
            let after = probe.interfaceSentByteCounters()
            let sender = (try? result.get()).flatMap {
                NASTrafficAttribution.sendingInterface(before: before, after: after, bytesWritten: $0.bytes)
            }
            return (result, sender)
        }.value
        if !heldByCaller { isBusy = false }
        status.isTestingSpeed = false
        testedMount = testedKey
        switch result {
        case .success(let speed):
            status.speed = speed
        case .failure(let error):
            status.speedTestError = "Speed test failed: \(error.localizedDescription)"
        }
        if let sender, let testedKey {
            measured = (testedKey, sender)
            if status.snapshot?.session == nil || status.snapshot?.session?.confidence == .measuredBySpeedTest {
                await inspectNow()
            }
        }
        publish()
        return true
    }

    // MARK: - Guard

    public func evaluateGuard(userRequested: Bool) async -> NASGuardDecision {
        let snapshot = status.snapshot
        guard let snapshot, snapshot.isMounted else {
            if status.banner != nil { status.banner = nil; publish() }
            return .nothing
        }
        let input = NASWiFiGuard.Input(
            sessionKind: snapshot.sessionKind,
            hasWiredRoute: snapshot.hasWiredRoute,
            nasInUse: await isNASInUse(),
            automaticEnabled: settings?.automatic ?? false,
            hasShareAddress: canRemount(snapshot),
            userRequested: userRequested,
            limiter: limiter.verdict(now: now(), userRequested: userRequested)
        )
        let decision = NASWiFiGuard.decide(input)
        let banner: NASGuardBannerReason? = if case .banner(let reason) = decision { reason } else { nil }
        if banner != status.banner {
            status.banner = banner
            publish()
        }
        return decision
    }

    /// Unmount, remount, and verify the new session is wired. Counts as a
    /// failure when any step fails or the session is still on Wi-Fi.
    @discardableResult
    public func reconnect(userRequested: Bool) async -> Bool {
        guard let settings, let url = settings.shareURL, let mountPoint = settings.mountPoint,
              let snapshot = status.snapshot, canRemount(snapshot), !isBusy else { return false }
        guard !(await isNASInUse()) else {
            status.banner = .nasInUse
            publish()
            return false
        }
        guard !isBusy else { return false }
        isBusy = true
        limiter.recordAttempt(at: now(), userRequested: userRequested)
        status.phase = .reconnecting
        status.message = nil
        publish()
        defer { isBusy = false }

        do {
            try await mounter.unmount(mountPoint: mountPoint)
        } catch {
            limiter.recordFailure()
            await inspectNow()
            status.message = "Could not disconnect the NAS to reconnect it over Ethernet (a file on it may be open): \(error.localizedDescription)"
            _ = await evaluateGuardBanner()
            publish()
            return false
        }
        let (outcome, _) = await mounter.mountWithoutUI(url)
        if case .needsUserInteraction = outcome {
            _ = await mounter.openInFinder(url)
        }
        await inspectNow()
        guard status.snapshotIsMounted else {
            limiter.recordFailure()
            status.message = "The NAS was disconnected but did not mount again\(outcome == .unreachable ? " (it did not answer)" : ""). Use Connect to NAS…"
            publish()
            return false
        }
        testedMount = nil
        measured = nil
        await cleanStaleTestFiles()
        // Right after each reconnect; it also tells the link apart when the
        // socket list is hidden.
        if !(await isNASInUse()) { await runSpeedTest(onDemand: false, heldByCaller: true) }
        guard let kind = status.snapshot?.sessionKind else {
            // Mounted again, link not verifiable (the test was skipped or
            // inconclusive): neither a success nor a failure.
            status.message = "Reconnected the NAS; could not confirm which link it uses."
            status.banner = nil
            publish()
            return false
        }
        if kind.isWired {
            limiter.recordSuccess()
            status.banner = nil
            status.message = "Reconnected the NAS over \(status.linkLabel)."
            publish()
            return true
        }
        limiter.recordFailure()
        status.message = "Reconnected, but the NAS session is still not on the wired link."
        _ = await evaluateGuardBanner()
        publish()
        return false
    }

    // MARK: - Internals

    private func waitAndReconnect() async {
        while !Task.isCancelled, await isNASInUse() {
            try? await Task.sleep(for: .seconds(3))
        }
        waitTask = nil
        status.isWaitingToReconnect = false
        guard !Task.isCancelled else { publish(); return }
        await inspectNow()
        if await evaluateGuard(userRequested: true) == .reconnect {
            await reconnect(userRequested: true)
        } else {
            publish()
        }
    }

    /// Recomputes the banner after a failed reconnect (the limiter moved).
    private func evaluateGuardBanner() async -> NASGuardDecision {
        let decision = await evaluateGuard(userRequested: false)
        if decision == .reconnect {
            // Allowed again later, but never loop from inside a reconnect:
            // show the banner until the next trigger.
            status.banner = .rateLimited
        }
        return decision
    }

    /// The share can only be put back when the mounted volume is the SMB
    /// share the configured address names.
    private func canRemount(_ snapshot: NASConnectionSnapshot) -> Bool {
        guard case .mounted(let source) = snapshot.mount, let url = settings?.shareURL else { return false }
        return source.matches(url)
    }

    private var needsSpeedTest: Bool {
        status.phase == .connected && testedMount != currentMountKey
    }

    private var currentMountKey: String? {
        status.snapshot?.mountKey
    }

    private func cleanStaleTestFiles() async {
        guard let mountPoint = settings?.mountPoint else { return }
        let tester = speedTester
        _ = await Task.detached(priority: .utility) {
            tester.removeStaleTestFiles(in: URL(fileURLWithPath: mountPoint, isDirectory: true))
        }.value
    }

    private func inspectNow() async {
        guard let settings else { return }
        status.hasShareURL = settings.shareURL != nil
        guard let mountPoint = settings.mountPoint else {
            status.phase = .notConfigured
            status.snapshot = nil
            publish()
            return
        }
        // The probe runs system tools; keep it off the actor's executor.
        let inspector = self.inspector
        let measured = self.measured
        let snapshot = await Task.detached(priority: .utility) {
            inspector.inspect(mountPoint: mountPoint, measured: measured)
        }.value
        status.snapshot = snapshot
        switch snapshot.mount {
        case .notMounted:
            status.phase = .offline
            status.banner = nil
        case .notSMB:
            status.phase = .notSMB
            status.banner = nil
        case .mounted:
            status.phase = .connected
        }
        publish()
    }

    private func publish() {
        onChange(status)
    }
}

extension NASConnectionStatus {
    var snapshotIsMounted: Bool { snapshot?.isMounted == true }
}
