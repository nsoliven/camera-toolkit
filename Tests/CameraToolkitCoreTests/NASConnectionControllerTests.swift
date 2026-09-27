import CameraToolkitCore
import Foundation
import XCTest

/// The controller against fakes: no real mount, unmount, network read, or
/// file under /Volumes is ever touched.
final class NASConnectionControllerTests: XCTestCase {
    private let settings = NASConnectionSettings(
        nasRoot: URL(fileURLWithPath: "/Volumes/CTTestNAS/Library", isDirectory: true),
        shareURL: URL(string: "smb://someone@nas.example/CTTestNAS"),
        automatic: true
    )

    private func makeController(
        network: FakeNetwork,
        mounter: FakeMounter,
        tester: FakeSpeedTester = FakeSpeedTester(),
        inUse: Flag = Flag(),
        limiter: NASReconnectRateLimiter = NASReconnectRateLimiter(minimumInterval: 0, maximumFailures: 2)
    ) -> NASConnectionController {
        NASConnectionController(
            inspector: NASConnectionInspector(probe: network),
            mounter: mounter,
            speedTester: tester,
            limiter: limiter,
            isNASInUse: { inUse.value },
            onChange: { _ in }
        )
    }

    func testInspectorReportsWiFiSessionAndWiredRoute() {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        let snapshot = NASConnectionInspector(probe: network).inspect(mountPoint: "/Volumes/CTTestNAS")
        XCTAssertEqual(snapshot.sessionKind, .wifi)
        XCTAssertEqual(snapshot.primarySessionInterface?.bsdName, "en0")
        XCTAssertEqual(snapshot.wiredRoutes.map(\.bsdName), ["en7"])
        XCTAssertEqual(snapshot.serverAddresses, ["192.0.2.2"])
    }

    func testInspectorUsesAScopedRouteWhenTheServerIsOffLink() {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true, serverAddress: "198.51.100.2")
        XCTAssertEqual(NASConnectionInspector(probe: network).inspect(mountPoint: "/Volumes/CTTestNAS").wiredRoutes, [])
        network.scopedRoutes = ["en7"]
        XCTAssertEqual(NASConnectionInspector(probe: network).inspect(mountPoint: "/Volumes/CTTestNAS").wiredRoutes.map(\.bsdName), ["en7"])
    }

    func testInspectorNotMountedAndNotSMB() {
        let network = FakeNetwork(mounted: false, sessionOnWiFi: false)
        XCTAssertEqual(NASConnectionInspector(probe: network).inspect(mountPoint: "/Volumes/CTTestNAS").mount, .notMounted)
        network.fileSystemType = "apfs"
        network.mounted = true
        XCTAssertEqual(NASConnectionInspector(probe: network).inspect(mountPoint: "/Volumes/CTTestNAS").mount, .notSMB(fileSystemType: "apfs"))
    }

    func testLaunchOnWiFiReconnectsOverEthernetAndTestsSpeed() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        let mounter = FakeMounter(network: network)
        let tester = FakeSpeedTester()
        let controller = makeController(network: network, mounter: mounter, tester: tester)

        await controller.start(settings: settings)

        XCTAssertEqual(mounter.calls, ["unmount /Volumes/CTTestNAS", "mount smb://someone@nas.example/CTTestNAS"])
        let status = await controller.status
        XCTAssertEqual(status.phase, .connected)
        XCTAssertEqual(status.snapshot?.sessionKind, .ethernet)
        XCTAssertNil(status.banner)
        XCTAssertEqual(tester.runs, 1)
        XCTAssertGreaterThanOrEqual(tester.cleanups, 1, "stale test files are cleaned after the remount")
        XCTAssertEqual(status.title, "NAS · Ethernet 1 GbE · 75 MB/s")
    }

    func testBusyNASShowsTheBannerAndNeverUnmounts() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        let mounter = FakeMounter(network: network)
        let inUse = Flag(true)
        let tester = FakeSpeedTester()
        let controller = makeController(network: network, mounter: mounter, tester: tester, inUse: inUse)

        await controller.start(settings: settings)

        XCTAssertEqual(mounter.calls, [])
        let banner = await controller.status.banner
        XCTAssertEqual(banner, .nasInUse)
        XCTAssertEqual(tester.runs, 0, "no speed test while a NAS job runs")
    }

    func testWiredSessionDoesNothing() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: false)
        let mounter = FakeMounter(network: network)
        let controller = makeController(network: network, mounter: mounter)
        await controller.start(settings: settings)
        let decision = await controller.refresh(trigger: .networkChange)
        XCTAssertEqual(decision, .nothing)
        XCTAssertEqual(mounter.calls, [])
    }

    func testGivesUpAfterTwoReconnectsThatStayOnWiFi() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        let mounter = FakeMounter(network: network)
        mounter.remountOnWiFi = true
        let controller = makeController(network: network, mounter: mounter)

        await controller.start(settings: settings)
        await controller.refresh(trigger: .networkChange)
        await controller.refresh(trigger: .networkChange)
        await controller.refresh(trigger: .jobStart)

        XCTAssertEqual(mounter.calls.filter { $0.hasPrefix("unmount") }.count, 2, "never loops past two failures")
        let status = await controller.status
        XCTAssertEqual(status.banner, .gaveUp)
        XCTAssertEqual(status.phase, .connected)

        // The banner's button still tries once more.
        let moved = await controller.reconnect(userRequested: true)
        XCTAssertFalse(moved)
        XCTAssertEqual(mounter.calls.filter { $0.hasPrefix("unmount") }.count, 3)
    }

    func testRateLimitWaitsBetweenAutomaticAttempts() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        let mounter = FakeMounter(network: network)
        mounter.remountOnWiFi = true
        let controller = makeController(
            network: network,
            mounter: mounter,
            limiter: NASReconnectRateLimiter(minimumInterval: 3600, maximumFailures: 2)
        )
        await controller.start(settings: settings)
        await controller.refresh(trigger: .networkChange)
        XCTAssertEqual(mounter.calls.filter { $0.hasPrefix("unmount") }.count, 1)
        let banner = await controller.status.banner
        XCTAssertEqual(banner, .rateLimited)
    }

    func testFailedUnmountCountsAsAFailureAndKeepsTheShare() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        let mounter = FakeMounter(network: network)
        mounter.unmountFails = true
        let controller = makeController(network: network, mounter: mounter)
        await controller.start(settings: settings)
        XCTAssertEqual(mounter.calls, ["unmount /Volumes/CTTestNAS"])
        XCTAssertTrue(network.mounted)
        let limiter = await controller.limiter
        XCTAssertEqual(limiter.consecutiveFailures, 1)
    }

    func testAShareFromAnotherServerIsNeverReconnected() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        network.mountedFrom = "//someone@other.example/CTTestNAS"
        let mounter = FakeMounter(network: network)
        let controller = makeController(network: network, mounter: mounter)
        await controller.start(settings: settings)
        XCTAssertEqual(mounter.calls, [])
        let banner = await controller.status.banner
        XCTAssertEqual(banner, .noShareAddress)
    }

    func testAutomaticOffOnlyShowsTheBanner() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        let mounter = FakeMounter(network: network)
        let controller = makeController(network: network, mounter: mounter)
        var manual = settings
        manual.automatic = false
        await controller.start(settings: manual)
        XCTAssertEqual(mounter.calls, [])
        let banner = await controller.status.banner
        XCTAssertEqual(banner, .automaticOff)
    }

    func testLaunchAutoConnectMountsWithoutUI() async {
        let network = FakeNetwork(mounted: false, sessionOnWiFi: false)
        let mounter = FakeMounter(network: network)
        let tester = FakeSpeedTester()
        let controller = makeController(network: network, mounter: mounter, tester: tester)
        await controller.start(settings: settings)
        XCTAssertEqual(mounter.calls, ["mount smb://someone@nas.example/CTTestNAS"])
        let phase = await controller.status.phase
        XCTAssertEqual(phase, .connected)
        XCTAssertEqual(tester.runs, 1, "a speed test right after connecting")
        XCTAssertGreaterThanOrEqual(tester.cleanups, 1)
    }

    func testMissingCredentialFallsBackToFinderAndUnreachableDoesNot() async {
        let network = FakeNetwork(mounted: false, sessionOnWiFi: false)
        let mounter = FakeMounter(network: network)
        mounter.mountOutcome = .needsUserInteraction(code: EAUTH)
        let controller = makeController(network: network, mounter: mounter)
        await controller.start(settings: settings)
        XCTAssertEqual(mounter.calls, ["mount smb://someone@nas.example/CTTestNAS", "finder smb://someone@nas.example/CTTestNAS"])

        let offline = FakeNetwork(mounted: false, sessionOnWiFi: false)
        let offlineMounter = FakeMounter(network: offline)
        offlineMounter.mountOutcome = .unreachable
        let offlineController = makeController(network: offline, mounter: offlineMounter)
        await offlineController.start(settings: settings)
        XCTAssertEqual(offlineMounter.calls, ["mount smb://someone@nas.example/CTTestNAS"])
        let status = await offlineController.status
        XCTAssertEqual(status.phase, .offline)
        XCTAssertEqual(status.title, "NAS · Offline")
        // Launch auto-connect happens once, not on every check.
        await offlineController.update(settings: NASConnectionSettings(nasRoot: settings.nasRoot, shareURL: settings.shareURL, automatic: true))
        await offlineController.refresh(trigger: .networkChange)
        XCTAssertEqual(offlineMounter.calls.count, 1)
    }

    func testAutomaticOffNeverMountsAtLaunch() async {
        let network = FakeNetwork(mounted: false, sessionOnWiFi: false)
        let mounter = FakeMounter(network: network)
        let controller = makeController(network: network, mounter: mounter)
        var manual = settings
        manual.automatic = false
        await controller.start(settings: manual)
        XCTAssertEqual(mounter.calls, [])
        await controller.connect(userInitiated: true)
        XCTAssertEqual(mounter.calls, ["mount smb://someone@nas.example/CTTestNAS"])
    }

    func testHiddenSocketsUseTheSpeedTestToFindWiFiThenReconnect() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        network.socketsHidden = true
        let mounter = FakeMounter(network: network)
        let tester = FakeSpeedTester()
        tester.network = network
        let controller = makeController(network: network, mounter: mounter, tester: tester)

        await controller.start(settings: settings)

        XCTAssertEqual(tester.runs, 2, "one to find the link, one right after the reconnect")
        XCTAssertEqual(mounter.calls, ["unmount /Volumes/CTTestNAS", "mount smb://someone@nas.example/CTTestNAS"])
        let status = await controller.status
        XCTAssertEqual(status.snapshot?.sessionKind, .ethernet)
        XCTAssertEqual(status.snapshot?.session?.confidence, .measuredBySpeedTest)
        let failures = await controller.limiter.consecutiveFailures
        XCTAssertEqual(failures, 0)
    }

    func testHiddenSocketsOnEthernetDoNothing() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: false)
        network.socketsHidden = true
        let mounter = FakeMounter(network: network)
        let tester = FakeSpeedTester()
        tester.network = network
        let controller = makeController(network: network, mounter: mounter, tester: tester)
        await controller.start(settings: settings)
        XCTAssertEqual(mounter.calls, [])
        let title = await controller.status.title
        XCTAssertEqual(title, "NAS · Ethernet 1 GbE · 75 MB/s")
    }

    func testOnDemandSpeedTestRunsAtMostEveryThirtyMinutes() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: false)
        let mounter = FakeMounter(network: network)
        let tester = FakeSpeedTester()
        let controller = makeController(network: network, mounter: mounter, tester: tester)
        await controller.start(settings: settings)
        XCTAssertEqual(tester.runs, 1)
        let rerun = await controller.runSpeedTest(onDemand: true)
        XCTAssertFalse(rerun)
        XCTAssertEqual(tester.runs, 1)
        tester.finishedAt = Date().addingTimeInterval(-31 * 60)
        _ = await controller.runSpeedTest(onDemand: false)
        XCTAssertEqual(tester.runs, 2)
        let later = await controller.runSpeedTest(onDemand: true)
        XCTAssertTrue(later)
        XCTAssertEqual(tester.runs, 3)
    }
}

// MARK: - Fakes

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool = false) { _value = value }
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// A Mac with Wi-Fi (en0) and USB Ethernet (en7) on the NAS's subnet.
final class FakeNetwork: NASNetworkProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _mounted: Bool
    private var _sessionOnWiFi: Bool
    private var _fileSystemType = "smbfs"
    private var _mountedFrom = "//someone@nas.example/CTTestNAS"
    private var _scopedRoutes: Set<String> = []
    private var _socketsHidden = false
    private var _sent: [String: UInt32] = ["en0": 4_294_000_000, "en7": 1_000]
    private var _mounts = 0
    let serverAddress: String

    init(mounted: Bool, sessionOnWiFi: Bool, serverAddress: String = "192.0.2.2") {
        _mounted = mounted
        _sessionOnWiFi = sessionOnWiFi
        self.serverAddress = serverAddress
    }

    var mounted: Bool { get { lock.withLock { _mounted } } set { lock.withLock { _mounted = newValue } } }
    var sessionOnWiFi: Bool { get { lock.withLock { _sessionOnWiFi } } set { lock.withLock { _sessionOnWiFi = newValue } } }
    var fileSystemType: String { get { lock.withLock { _fileSystemType } } set { lock.withLock { _fileSystemType = newValue } } }
    var mountedFrom: String { get { lock.withLock { _mountedFrom } } set { lock.withLock { _mountedFrom = newValue } } }
    var scopedRoutes: Set<String> { get { lock.withLock { _scopedRoutes } } set { lock.withLock { _scopedRoutes = newValue } } }
    /// netstat lists nothing, as for a process macOS hides sockets from.
    var socketsHidden: Bool { get { lock.withLock { _socketsHidden } } set { lock.withLock { _socketsHidden = newValue } } }

    func noteMounted() { lock.withLock { _mounts += 1 } }

    /// Bytes leaving on the session's interface (the counters wrap).
    func send(_ bytes: Int64) {
        let name = sessionOnWiFi ? "en0" : "en7"
        lock.withLock { _sent[name, default: 0] &+= UInt32(truncatingIfNeeded: bytes) }
    }

    func interfaceSentByteCounters() -> [String: UInt32] { lock.withLock { _sent } }

    func mountEntry(at mountPoint: String) -> NASMountTableEntry? {
        guard mounted, mountPoint == "/Volumes/CTTestNAS" else { return nil }
        return NASMountTableEntry(mountedOn: mountPoint, mountedFrom: mountedFrom, fileSystemType: fileSystemType)
    }

    func smbSession(mountPoint: String) -> NASSMBSessionStats? {
        mounted ? NASSMBSessionStats(serverAddresses: [serverAddress], setupTime: "mount \(lock.withLock { _mounts })", reconnectCount: 0) : nil
    }

    func tcpConnections() -> [NASTCPConnection] {
        guard mounted, !socketsHidden else { return [] }
        return [NASTCPConnection(
            localAddress: sessionOnWiFi ? "192.0.2.58" : "192.0.2.30",
            localPort: 50_000,
            remoteAddress: serverAddress,
            remotePort: 445,
            state: "ESTABLISHED"
        )]
    }

    func interfaces() -> [NASNetworkInterface] {
        [
            NASNetworkInterface(bsdName: "en0", kind: .wifi, displayName: "Wi-Fi", addresses: [.init(address: "192.0.2.58", netmask: "255.255.254.0")], linkSpeedMbps: 866),
            NASNetworkInterface(bsdName: "en7", kind: .ethernet, displayName: "USB LAN", addresses: [.init(address: "192.0.2.30", netmask: "255.255.254.0")], linkSpeedMbps: 1000),
            NASNetworkInterface(bsdName: "en8", kind: .ethernet, displayName: "Unplugged", isUp: false, addresses: [.init(address: "192.0.2.99", netmask: "255.255.254.0")]),
        ]
    }

    func routeInterface(to address: String, scopedTo interface: String?) -> String? {
        guard let interface else { return "en7" }
        return scopedRoutes.contains(interface) ? interface : nil
    }

    func resolve(host: String) -> [String] { [serverAddress] }
}

final class FakeMounter: NASVolumeMounting, @unchecked Sendable {
    private let lock = NSLock()
    private let network: FakeNetwork
    private var _calls: [String] = []
    private var _remountOnWiFi = false
    private var _unmountFails = false
    private var _mountOutcome: NASMountOutcome = .mounted

    init(network: FakeNetwork) { self.network = network }

    var calls: [String] { lock.withLock { _calls } }
    var remountOnWiFi: Bool { get { lock.withLock { _remountOnWiFi } } set { lock.withLock { _remountOnWiFi = newValue } } }
    var unmountFails: Bool { get { lock.withLock { _unmountFails } } set { lock.withLock { _unmountFails = newValue } } }
    var mountOutcome: NASMountOutcome { get { lock.withLock { _mountOutcome } } set { lock.withLock { _mountOutcome = newValue } } }

    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    func mountWithoutUI(_ url: URL) async -> (outcome: NASMountOutcome, mountPoints: [String]) {
        record("mount \(url.absoluteString)")
        let outcome = mountOutcome
        if outcome == .mounted {
            network.mounted = true
            network.sessionOnWiFi = remountOnWiFi
            network.noteMounted()
            return (outcome, ["/Volumes/CTTestNAS"])
        }
        return (outcome, [])
    }

    func openInFinder(_ url: URL) async -> Bool {
        record("finder \(url.absoluteString)")
        return true
    }

    func unmount(mountPoint: String) async throws {
        record("unmount \(mountPoint)")
        if unmountFails { throw CocoaError(.fileWriteNoPermission) }
        network.mounted = false
    }
}

final class FakeSpeedTester: NASSpeedTesting, @unchecked Sendable {
    private let lock = NSLock()
    private var _runs = 0
    private var _cleanups = 0
    private var _finishedAt: Date?
    /// When set, a run sends its bytes out on the network's session link.
    var network: FakeNetwork?

    var runs: Int { lock.withLock { _runs } }
    var cleanups: Int { lock.withLock { _cleanups } }
    /// Overrides the result's timestamp (to age it past 30 minutes).
    var finishedAt: Date? { get { lock.withLock { _finishedAt } } set { lock.withLock { _finishedAt = newValue } } }

    func run(root: URL) throws -> NASSpeedTestResult {
        lock.withLock { _runs += 1 }
        network?.send(75_000_000)
        return NASSpeedTestResult(bytes: 75_000_000, writeSeconds: 1, readSeconds: 0.8, smallWriteSeconds: 0.004, smallReadSeconds: 0.002, finishedAt: finishedAt ?? Date())
    }

    func removeStaleTestFiles(in root: URL) -> [String] {
        lock.withLock { _cleanups += 1 }
        return []
    }
}
