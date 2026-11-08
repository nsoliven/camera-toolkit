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
    /// "Connect to the NAS automatically" — auto-connect at launch.
    public var automatic: Bool
    /// "Switch the NAS share to the faster link automatically" — reconnect
    /// the share when the route to the NAS moved to a faster link (Ethernet
    /// plugged in) and no job uses the NAS.
    public var autoSwitchLink: Bool

    public init(nasRoot: URL, shareURL: URL?, automatic: Bool, autoSwitchLink: Bool = true) {
        self.nasRoot = nasRoot
        self.shareURL = shareURL
        self.automatic = automatic
        self.autoSwitchLink = autoSwitchLink
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
    /// The automatic switch is wanted and waits only for a running job to
    /// end (or for the job queue's next boundary).
    public var linkSwitchPending = false
    /// The last switch attempt failed (the share kept or fell back to its
    /// old link); the banner offers to try again.
    public var lastSwitchFailed = false
    /// The last connect/reconnect note ("Moved the NAS connection to Ethernet.").
    public var message: String?
    public var hasShareURL = false

    public init() {}

    /// The route to the NAS against the session's link.
    public var linkAssessment: NASLinkAssessment {
        snapshot?.linkAssessment ?? NASLinkAssessment(route: nil, sessionInterfaces: [])
    }

    /// True when the route to the NAS uses a faster link than the share's
    /// SMB session — a reconnect would move the share onto it.
    public var fasterLinkAvailable: Bool {
        phase == .connected && linkAssessment.state == .fasterLinkAvailable
    }

    /// The link a switch would move the share to ("Ethernet").
    public var fasterLinkName: String {
        let assessment = linkAssessment
        guard let route = assessment.route else { return "Ethernet" }
        guard let session = assessment.session else { return route.kind.displayName }
        return NASLinkAssessment.name(route, against: session)
    }

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
        case .reconnecting:
            return linkAssessment.state == .fasterLinkAvailable ? "NAS · Switching to \(fasterLinkName)…" : "NAS · Reconnecting…"
        case .notSMB: return "NAS · Local Volume"
        case .connected:
            // Said plainly when the route and the share disagree: the
            // cable is in, but the share still rides the old link.
            if let summary = linkAssessment.summary {
                return "NAS · \(summary)"
            }
            var parts = ["NAS", linkLabel]
            if isTestingSpeed {
                parts.append("Testing…")
            } else if let rate = speed?.writeMegabytesPerSecond {
                parts.append(NASSpeedTestMath.rateLabel(rate))
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Shown where the link is: SMB multichannel on the NAS lets one
    /// session use every link at once, so plugging in a cable needs no
    /// reconnect. Only a hint — the app never changes NAS settings.
    public static let multichannelHint = "Tip: turning on SMB multichannel on the NAS lets the share use Wi-Fi and Ethernet together, without reconnecting."

    /// Whether the multichannel hint applies: the session is single-channel
    /// and the Mac has a wired link to the NAS (or the route and session
    /// disagree).
    public var showsMultichannelHint: Bool {
        guard phase == .connected || phase == .reconnecting, let snapshot, !snapshot.multichannel else { return false }
        return snapshot.hasWiredRoute || linkAssessment.state == .fasterLinkAvailable || linkAssessment.state == .sessionOnFasterLink
    }

    /// The tooltip: interface, route, and the speed test with its age.
    public func detail(now: Date) -> String {
        var lines: [String] = []
        if let snapshot, snapshot.isMounted {
            if let route = snapshot.routeInterface {
                lines.append("Route to the NAS: \(Self.describe(route))")
            }
            if let interface = snapshot.primarySessionInterface {
                var line = "SMB session: \(Self.describe(interface))"
                if let local = snapshot.session?.localAddresses.first { line += " from \(local)" }
                if snapshot.multichannel { line += " (multichannel)" }
                lines.append(line)
                if snapshot.session?.confidence == .measuredBySpeedTest {
                    lines.append("Link measured by the speed test (macOS does not show Camera Toolkit its network connections)")
                }
            } else if snapshot.socketListHidden {
                lines.append("macOS does not show Camera Toolkit its network connections; the next speed test will tell which link the NAS uses")
            } else {
                lines.append("Could not tell which interface the SMB session uses")
            }
            switch snapshot.linkAssessment.state {
            case .fasterLinkAvailable:
                if linkSwitchPending {
                    lines.append("The share moves to \(fasterLinkName) when no job is using the NAS (a running job is never interrupted).")
                } else {
                    lines.append("The share moves to \(fasterLinkName) only when it reconnects.")
                }
            case .sessionOnFasterLink:
                lines.append("The faster link went away; macOS reconnects the share on its own.")
            case .matched, .unknown:
                if let wired = snapshot.wiredRoutes.first, snapshot.sessionKind == .wifi, snapshot.routeInterface?.kind == .wifi {
                    lines.append("\(Self.describe(wired)) reaches the NAS, but macOS routes it over Wi-Fi (check the service order in Network settings).")
                }
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
        if showsMultichannelHint { lines.append(Self.multichannelHint) }
        return lines.joined(separator: "\n")
    }

    /// "Ethernet 1 GbE — USB LAN (en7)".
    static func describe(_ interface: NASNetworkInterface) -> String {
        var kind = interface.kind == .other ? "Network" : interface.kind.displayName
        if interface.kind.isWired, let speed = interface.linkSpeedMbps, speed > 0 {
            kind += " \(NASInterfaceClassifier.linkSpeedLabel(mbps: speed))"
        }
        let name = interface.displayName.map { "\($0) (\(interface.bsdName))" } ?? interface.bsdName
        return "\(kind) — \(name)"
    }
}

/// Connects the NAS share, watches which link its SMB session uses against
/// the link the route to the NAS takes, moves the share onto the faster one
/// when no job uses the NAS, and runs the quick speed test.
/// An actor: every check and file operation runs off the main actor; the
/// app observes `onChange`.
public actor NASConnectionController {
    public static let onDemandSpeedTestInterval: TimeInterval = 30 * 60
    /// How long `prepareForNASJob` waits for a reconnect or speed test that
    /// is already running.
    static let busyWait: Duration = .seconds(40)

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
    /// The last switch stopped at a refused unmount (files open elsewhere).
    private var unmountRefused = false
    /// Before the one retry of a remount that found no answer.
    private let remountRetryDelay: Duration

    public init(
        inspector: NASConnectionInspector = NASConnectionInspector(),
        mounter: any NASVolumeMounting,
        speedTester: any NASSpeedTesting = NASSpeedTester(),
        limiter: NASReconnectRateLimiter = NASReconnectRateLimiter(),
        now: @escaping @Sendable () -> Date = Date.init,
        remountRetryDelay: Duration = .seconds(3),
        isNASInUse: @escaping @Sendable () async -> Bool,
        onChange: @escaping @Sendable (NASConnectionStatus) -> Void
    ) {
        self.remountRetryDelay = remountRetryDelay
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
        // A reconnect or speed test in flight owns the share: a job that
        // started now would open files on a mount being unmounted, or race
        // the test's own writes. Wait for it (at most `busyWait`).
        var waited: Duration = .zero
        while isBusy, waited < Self.busyWait {
            try? await Task.sleep(for: .milliseconds(250))
            waited += .milliseconds(250)
        }
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

    /// A safe point — nothing uses the NAS, or the job queue is between two
    /// jobs and holds the next one: switch now when the policy says so. A
    /// waiting "Switch now" request counts as the user's own.
    public func switchAtSafePoint() async {
        let userAsked = waitTask != nil
        if userAsked {
            waitTask?.cancel()
            waitTask = nil
            status.isWaitingToReconnect = false
        }
        // A reconnect or speed test already owns the share: return only once
        // it is done, so whoever holds the job queue for this switch does
        // not let the next job start on a share being remounted.
        var waited: Duration = .zero
        while isBusy, waited < Self.busyWait {
            try? await Task.sleep(for: .milliseconds(250))
            waited += .milliseconds(250)
        }
        guard !isBusy else { publish(); return }
        await inspectNow()
        guard !isBusy else { return }
        if await evaluateGuard(userRequested: userAsked) == .reconnect {
            await reconnect(userRequested: userAsked)
        } else {
            publish()
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
        LaunchTrace.mark("nas.speed_test.start", detail: "on_demand=\(onDemand)")
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
        LaunchTrace.mark("nas.speed_test.finish", outcome: (try? result.get()) == nil ? .error : .ok)
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
            if status.banner != nil || status.linkSwitchPending {
                status.banner = nil
                status.linkSwitchPending = false
                publish()
            }
            return .nothing
        }
        let input = NASLinkSwitchPolicy.Input(
            link: snapshot.linkAssessment.state,
            nasInUse: await isNASInUse(),
            automaticEnabled: settings?.autoSwitchLink ?? false,
            hasShareAddress: canRemount(snapshot),
            userRequested: userRequested,
            limiter: limiter.verdict(now: now(), userRequested: userRequested)
        )
        let decision = NASLinkSwitchPolicy.decide(input)
        var banner: NASGuardBannerReason? = if case .banner(let reason) = decision { reason } else { nil }
        // The give-up and the pause after a refused unmount have one cause
        // worth naming: another app holds files open on the share.
        if unmountRefused, banner == .gaveUp || banner == .rateLimited { banner = .shareBusyElsewhere }
        let pending = NASLinkSwitchPolicy.waitsOnlyForJobs(input)
        if snapshot.linkAssessment.state != .fasterLinkAvailable {
            // Nothing to move any more (the cable was pulled, or the share
            // reconnected by itself): forget the last failure.
            status.lastSwitchFailed = false
            unmountRefused = false
        }
        if banner != status.banner || pending != status.linkSwitchPending {
            status.banner = banner
            status.linkSwitchPending = pending
            publish()
        }
        return decision
    }

    /// Unmount, remount, and verify the new session rides the link the
    /// route uses. Counts as a failure when any step fails or the session
    /// is still on the slower link. The unmount is a normal one: when any
    /// app has a file open on the share, macOS refuses and the share stays
    /// exactly as it was.
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
        defer { isBusy = false }
        // Look again now that the share is claimed and right before it is
        // touched: a job may have started while the checks above hopped
        // between actors, and an unmount between two of its files would
        // succeed and pull the share from under it.
        guard !(await isNASInUse()) else {
            status.banner = .nasInUse
            publish()
            return false
        }
        let target = status.fasterLinkName
        limiter.recordAttempt(at: now(), userRequested: userRequested)
        status.phase = .reconnecting
        status.message = nil
        status.linkSwitchPending = false
        publish()

        do {
            try await mounter.unmount(mountPoint: mountPoint)
        } catch {
            limiter.recordFailure()
            unmountRefused = true
            status.lastSwitchFailed = true
            await inspectNow()
            status.message = "The share stays on its current link: macOS would not disconnect it because another app (Finder, Time Machine, …) has files open on it. \(error.localizedDescription)"
            status.banner = .shareBusyElsewhere
            publish()
            return false
        }
        unmountRefused = false
        var (outcome, _) = await mounter.mountWithoutUI(url)
        if case .needsUserInteraction = outcome {
            _ = await mounter.openInFinder(url)
        }
        await inspectNow()
        if !status.snapshotIsMounted, outcome == .unreachable || outcome == .cancelled {
            // The new link may still be settling (DHCP, routes): one more
            // try a moment later, over whatever link the route takes then.
            try? await Task.sleep(for: remountRetryDelay)
            (outcome, _) = await mounter.mountWithoutUI(url)
            await inspectNow()
        }
        guard status.snapshotIsMounted else {
            limiter.recordFailure()
            status.lastSwitchFailed = true
            status.message = "The share was disconnected to move it to \(target) but did not mount again\(outcome == .unreachable ? " (the NAS did not answer)" : ""). Click Connect to mount it again."
            publish()
            return false
        }
        testedMount = nil
        measured = nil
        await cleanStaleTestFiles()
        // Right after each reconnect; it also tells the link apart when the
        // socket list is hidden.
        if !(await isNASInUse()) { await runSpeedTest(onDemand: false, heldByCaller: true) }
        let assessment = status.linkAssessment
        switch assessment.state {
        case .matched, .sessionOnFasterLink:
            limiter.recordSuccess()
            status.lastSwitchFailed = false
            status.banner = nil
            status.message = "Reconnected the NAS over \(status.linkLabel)."
            publish()
            return true
        case .unknown:
            // Mounted again, link not verifiable (the test was skipped or
            // inconclusive): neither a success nor a failure.
            status.message = "Reconnected the NAS; could not confirm which link it uses."
            status.banner = nil
            publish()
            return false
        case .fasterLinkAvailable:
            limiter.recordFailure()
            status.lastSwitchFailed = true
            status.message = "Reconnected, but the share is still on \(assessment.session.map { $0.kind.displayName } ?? "the slower link")."
            _ = await evaluateGuardBanner()
            publish()
            return false
        }
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
