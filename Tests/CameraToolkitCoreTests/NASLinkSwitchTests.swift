import CameraToolkitCore
import Foundation
import XCTest

// Fixtures use documentation addresses (RFC 5737) and made-up names only.
final class NASLinkSwitchTests: XCTestCase {
    private let wifi = NASNetworkInterface(bsdName: "en0", kind: .wifi, displayName: "Wi-Fi", addresses: [.init(address: "192.0.2.20", netmask: "255.255.255.0")], linkSpeedMbps: 866)
    private let ethernet = NASNetworkInterface(bsdName: "en7", kind: .ethernet, displayName: "USB LAN", addresses: [.init(address: "192.0.2.30", netmask: "255.255.255.0")], linkSpeedMbps: 1000)
    private let tenGig = NASNetworkInterface(bsdName: "en9", kind: .thunderbolt, displayName: "TB Ethernet", addresses: [.init(address: "192.0.2.40", netmask: "255.255.255.0")], linkSpeedMbps: 10_000)
    private let tunnel = NASNetworkInterface(bsdName: "utun3", kind: .other, addresses: [.init(address: "198.51.100.2")])

    // MARK: route against session

    func testEthernetPluggedInWhileTheSessionStaysOnWiFi() {
        let assessment = NASLinkAssessment(route: ethernet, sessionInterfaces: [wifi])
        XCTAssertEqual(assessment.state, .fasterLinkAvailable)
        XCTAssertEqual(assessment.summary, "Ethernet available · share still on Wi-Fi")
        XCTAssertEqual(assessment.session?.bsdName, "en0")
    }

    func testRouteAndSessionOnTheSameLink() {
        XCTAssertEqual(NASLinkAssessment(route: ethernet, sessionInterfaces: [ethernet]).state, .matched)
        XCTAssertEqual(NASLinkAssessment(route: wifi, sessionInterfaces: [wifi]).state, .matched)
        XCTAssertNil(NASLinkAssessment(route: wifi, sessionInterfaces: [wifi]).summary)
    }

    func testCablePulledWhileTheSessionIsStillOnIt() {
        let assessment = NASLinkAssessment(route: wifi, sessionInterfaces: [ethernet])
        XCTAssertEqual(assessment.state, .sessionOnFasterLink)
        XCTAssertEqual(assessment.summary, "Route moved to Wi-Fi · share still on Ethernet")
    }

    func testFasterWiredLinkBeatsASlowerOne() {
        let assessment = NASLinkAssessment(route: tenGig, sessionInterfaces: [ethernet])
        XCTAssertEqual(assessment.state, .fasterLinkAvailable)
        XCTAssertEqual(assessment.summary, "Thunderbolt available · share still on Ethernet")
        let sameKind = NASNetworkInterface(bsdName: "en8", kind: .ethernet, linkSpeedMbps: 2500)
        XCTAssertEqual(NASLinkAssessment(route: sameKind, sessionInterfaces: [ethernet]).summary, "Ethernet 2.5 GbE available · share still on Ethernet 1 GbE")
    }

    func testTwoWiredLinksWithoutSpeedsAreNotWorthAReconnect() {
        var a = ethernet
        a.linkSpeedMbps = nil
        var b = tenGig
        b.linkSpeedMbps = nil
        XCTAssertEqual(NASLinkAssessment(route: b, sessionInterfaces: [a]).state, .matched)
    }

    func testUnknownKindsAndMissingFactsNeverTriggerASwitch() {
        XCTAssertEqual(NASLinkAssessment(route: tunnel, sessionInterfaces: [wifi]).state, .unknown)
        XCTAssertEqual(NASLinkAssessment(route: ethernet, sessionInterfaces: [tunnel]).state, .unknown)
        XCTAssertEqual(NASLinkAssessment(route: nil, sessionInterfaces: [wifi]).state, .unknown)
        XCTAssertEqual(NASLinkAssessment(route: ethernet, sessionInterfaces: []).state, .unknown, "hidden sockets before a speed test")
        XCTAssertNil(NASLinkAssessment.isFaster(tunnel, than: wifi))
    }

    func testAMultichannelSessionWithAChannelOnTheRouteIsMatched() {
        XCTAssertEqual(NASLinkAssessment(route: ethernet, sessionInterfaces: [wifi, ethernet]).state, .matched)
    }

    func testSnapshotAssessmentNeedsAMountedShare() {
        var snapshot = NASConnectionSnapshot(
            mountPoint: "/Volumes/nas_share",
            mount: .mounted(NASMountSource(host: "nas.example", share: "nas_share")),
            sessionInterfaces: [wifi],
            routeInterface: ethernet
        )
        XCTAssertEqual(snapshot.linkAssessment.state, .fasterLinkAvailable)
        snapshot.mount = .notMounted
        XCTAssertEqual(snapshot.linkAssessment.state, .unknown)
    }

    // MARK: the session's local address, from raw tool output

    static let smbutilSingleChannel = """
    Session: /Volumes/nas_share
    Info: Setup Time: 2026-01-01 10:00:00, Multichannel ON: no, Reconnect Count: 0
    \tTotal RX Bytes: 1986993 (Packets: 7212)
    \tTotal TX Bytes: 1075958462 (Packets: 7130)
           id         client IF             server IF   state                     server ip                 port   speed
    ========================================================================================================================
    M     217     N/A                          N/A      [session active       ]   192.0.2.10              445    N/A
    """

    /// After Ethernet came up: the share's connection still has the Wi-Fi
    /// address, while a new connection (another app) already uses Ethernet
    /// to some other server.
    static let netstatAfterPlug = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
    tcp4       0      0  192.0.2.30.61781     192.0.2.50.443       ESTABLISHED         6502         2563  131072  131328     Some App:1910   00102 00000008 0000000000540e24 00000081 04000900      2      0 000000
    tcp4       0 892928  192.0.2.20.51314     192.0.2.10.445       ESTABLISHED  13319807076   1075986227 2096560  892928      kernel_task:0      00082 00000008 00000000004fcf65 00000082 04104900      4      0 000000
    tcp4       0      0  192.0.2.30.61043     192.0.2.10.445       TIME_WAIT              0            0  131072  131072      kernel_task:0      00000 00000006 0000000000000001 00000000 00000800      1      0 000000
    tcp4       0      0  *.445                  *.*                    LISTEN                 0            0  131072  131072      smbd:99         00000 00000006 0000000000000001 00000000 00000800      1      0 000000
    """

    func testTheSessionStaysOnWiFiAfterEthernetComesUp() {
        let (match, interfaces) = NASSessionLocator.resolveSession(
            netstatOutput: Self.netstatAfterPlug,
            smbutilOutput: Self.smbutilSingleChannel,
            serverAddresses: [],
            interfaces: [wifi, ethernet]
        )
        XCTAssertEqual(match?.localAddresses, ["192.0.2.20"])
        XCTAssertEqual(match?.confidence, .onlyConnection, "the TIME_WAIT and the other server do not count")
        XCTAssertEqual(interfaces.map(\.bsdName), ["en0"])
        XCTAssertEqual(NASLinkAssessment(route: ethernet, sessionInterfaces: interfaces).state, .fasterLinkAvailable)
    }

    func testAfterTheRemountTheSessionIsOnEthernet() {
        let netstat = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  192.0.2.30.61099     192.0.2.10.445       ESTABLISHED
        """
        let (match, interfaces) = NASSessionLocator.resolveSession(
            netstatOutput: netstat,
            smbutilOutput: nil,
            serverAddresses: ["192.0.2.10"],
            interfaces: [wifi, ethernet]
        )
        XCTAssertEqual(match?.localAddresses, ["192.0.2.30"])
        XCTAssertEqual(interfaces.map(\.bsdName), ["en7"])
        XCTAssertEqual(NASLinkAssessment(route: ethernet, sessionInterfaces: interfaces).state, .matched)
    }

    func testTwoConnectionsToTheServerAreToldApartByTheirSentBytes() {
        // Another share on the same server rides Ethernet; this session's
        // sent bytes match the Wi-Fi connection.
        let netstat = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes
        tcp4       0      0  192.0.2.30.61042     192.0.2.10.445       ESTABLISHED      4403218        52000000
        tcp4       0      0  192.0.2.20.51314     192.0.2.10.445       ESTABLISHED     13319807      1075986227
        """
        let (match, interfaces) = NASSessionLocator.resolveSession(
            netstatOutput: netstat,
            smbutilOutput: Self.smbutilSingleChannel,
            serverAddresses: [],
            interfaces: [wifi, ethernet]
        )
        XCTAssertEqual(match?.confidence, .matchedByTraffic)
        XCTAssertEqual(interfaces.map(\.bsdName), ["en0"])
    }

    func testNoConnectionToTheServerMeansUnknownNotAGuess() {
        let netstat = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  192.0.2.30.61781     192.0.2.50.443       ESTABLISHED
        """
        let (match, interfaces) = NASSessionLocator.resolveSession(
            netstatOutput: netstat,
            smbutilOutput: Self.smbutilSingleChannel,
            serverAddresses: [],
            interfaces: [wifi, ethernet]
        )
        XCTAssertNil(match)
        XCTAssertEqual(interfaces, [])
    }

    func testInterfacesForAMatchUseNamesThenAddresses() {
        let byName = NASSessionMatch(localAddresses: [], interfaceNames: ["en7", "en0"], confidence: .reportedBySMB)
        XCTAssertEqual(NASSessionLocator.interfaces(for: byName, in: [wifi, ethernet]).map(\.bsdName), ["en7", "en0"])
        let byAddress = NASSessionMatch(localAddresses: ["192.0.2.30", "192.0.2.99"], confidence: .onlyConnection)
        XCTAssertEqual(NASSessionLocator.interfaces(for: byAddress, in: [wifi, ethernet]).map(\.bsdName), ["en7"], "an address no interface owns any more is dropped")
        XCTAssertEqual(NASSessionLocator.interfaces(for: nil, in: [wifi]), [])
    }

    // MARK: job boundaries

    func testGateWaitsForAnyRunningWork() {
        XCTAssertEqual(NASLinkSwitchGate.verdict(NASJobActivity()), .clear)
        XCTAssertEqual(NASLinkSwitchGate.verdict(NASJobActivity(jobRunning: true)), .wait)
        XCTAssertEqual(NASLinkSwitchGate.verdict(NASJobActivity(jobRunning: true, queuedJobs: 3)), .wait, "mid-file: never")
        XCTAssertEqual(NASLinkSwitchGate.verdict(NASJobActivity(transferRunning: true)), .wait)
        XCTAssertEqual(NASLinkSwitchGate.verdict(NASJobActivity(benchmarkRunning: true)), .wait)
        XCTAssertEqual(NASLinkSwitchGate.verdict(NASJobActivity(queuedJobs: 2)), .atJobBoundary)
    }

    func testQueueHoldOnlyWhileASwitchIsWantedOrRunning() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(NASLinkSwitchGate.shouldHoldQueue(switchWanted: false, switchRunning: false, heldSince: nil, now: start))
        XCTAssertTrue(NASLinkSwitchGate.shouldHoldQueue(switchWanted: true, switchRunning: false, heldSince: nil, now: start))
        XCTAssertTrue(NASLinkSwitchGate.shouldHoldQueue(switchWanted: true, switchRunning: false, heldSince: start, now: start.addingTimeInterval(30)))
        XCTAssertFalse(
            NASLinkSwitchGate.shouldHoldQueue(switchWanted: true, switchRunning: false, heldSince: start, now: start.addingTimeInterval(NASLinkSwitchGate.maximumQueueHold)),
            "a switch that never starts does not hold the queue forever"
        )
        XCTAssertTrue(
            NASLinkSwitchGate.shouldHoldQueue(switchWanted: false, switchRunning: true, heldSince: start, now: start.addingTimeInterval(600)),
            "never start a job on a share that is being remounted"
        )
    }

    // MARK: interface fingerprint

    func testSignatureChangesWithAddressesAndUpStateOnly() {
        let wifiOnly = NASInterfaceSignature.make([
            ("lo0", true, ["127.0.0.1"]),
            ("en0", true, ["192.0.2.20", "fe80::1%en0"]),
            ("en7", false, []),
        ])
        let reordered = NASInterfaceSignature.make([
            ("en7", false, []),
            ("en0", true, ["fe80::2%en0", "192.0.2.20"]),
        ])
        XCTAssertEqual(wifiOnly, reordered, "loopback, link-local and order do not matter")
        let linkUp = NASInterfaceSignature.make([("en0", true, ["192.0.2.20"]), ("en7", true, [])])
        XCTAssertNotEqual(wifiOnly, linkUp)
        let leased = NASInterfaceSignature.make([("en0", true, ["192.0.2.20"]), ("en7", true, ["192.0.2.30"])])
        XCTAssertNotEqual(linkUp, leased, "a DHCP lease after the link came up is a change")
    }
}

/// The controller's switch, end to end against fakes.
final class NASLinkSwitchControllerTests: XCTestCase {
    private let settings = NASConnectionSettings(
        nasRoot: URL(fileURLWithPath: "/Volumes/CTTestNAS/Library", isDirectory: true),
        shareURL: URL(string: "smb://someone@nas.example/CTTestNAS"),
        automatic: true
    )

    private func makeController(network: FakeNetwork, mounter: FakeMounter, inUse: Flag = Flag(), tester: FakeSpeedTester = FakeSpeedTester()) -> NASConnectionController {
        NASConnectionController(
            inspector: NASConnectionInspector(probe: network),
            mounter: mounter,
            speedTester: tester,
            limiter: NASReconnectRateLimiter(minimumInterval: 0, maximumFailures: 2),
            remountRetryDelay: .milliseconds(10),
            isNASInUse: { inUse.value },
            onChange: { _ in }
        )
    }

    func testAutomaticSwitchIsOnByDefault() {
        XCTAssertTrue(settings.autoSwitchLink)
    }

    func testARunningJobDefersTheSwitchUntilItEnds() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        let mounter = FakeMounter(network: network)
        let inUse = Flag(true)
        let controller = makeController(network: network, mounter: mounter, inUse: inUse)

        await controller.start(settings: settings)
        var status = await controller.status
        XCTAssertEqual(mounter.calls, [], "never unmounted under a running job")
        XCTAssertTrue(status.linkSwitchPending)
        XCTAssertEqual(status.title, "NAS · Ethernet available · share still on Wi-Fi")

        // Still running at the next network check: still waiting.
        await controller.refresh(trigger: .networkChange)
        XCTAssertEqual(mounter.calls, [])

        // The job ended (or the queue reached a boundary and holds its next job).
        inUse.value = false
        await controller.switchAtSafePoint()
        status = await controller.status
        XCTAssertEqual(mounter.calls, ["unmount /Volumes/CTTestNAS", "mount smb://someone@nas.example/CTTestNAS"])
        XCTAssertEqual(status.linkAssessment.state, .matched)
        XCTAssertFalse(status.linkSwitchPending)
        XCTAssertNil(status.banner)
        XCTAssertEqual(status.title, "NAS · Ethernet 1 GbE · 75 MB/s")
    }

    func testEthernetUpButRoutedOverWiFiIsLeftAlone() async {
        // The wired link reaches the NAS, but the service order sends the
        // route over Wi-Fi: a remount would land on Wi-Fi again.
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        network.primaryRoute = "en0"
        let mounter = FakeMounter(network: network)
        let controller = makeController(network: network, mounter: mounter)
        await controller.start(settings: settings)
        XCTAssertEqual(mounter.calls, [])
        let status = await controller.status
        XCTAssertEqual(status.linkAssessment.state, .matched)
        XCTAssertTrue(status.detail(now: Date()).contains("macOS routes it over Wi-Fi"))
    }

    func testPluggingInLaterSwitchesOnTheNetworkChange() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        network.primaryRoute = "en0"
        let mounter = FakeMounter(network: network)
        let controller = makeController(network: network, mounter: mounter)
        await controller.start(settings: settings)
        XCTAssertEqual(mounter.calls, [])

        network.primaryRoute = "en7"
        await controller.refresh(trigger: .networkChange)
        XCTAssertEqual(mounter.calls, ["unmount /Volumes/CTTestNAS", "mount smb://someone@nas.example/CTTestNAS"])
        let state = await controller.status.linkAssessment.state
        XCTAssertEqual(state, .matched)
    }

    func testPullingTheCableOnlyUpdatesTheStatus() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: false)
        let mounter = FakeMounter(network: network)
        let controller = makeController(network: network, mounter: mounter)
        await controller.start(settings: settings)
        var title = await controller.status.title
        XCTAssertEqual(title, "NAS · Ethernet 1 GbE · 75 MB/s")

        // Route back on Wi-Fi; the SMB client has not reconnected yet.
        network.primaryRoute = "en0"
        await controller.refresh(trigger: .networkChange)
        title = await controller.status.title
        XCTAssertEqual(title, "NAS · Route moved to Wi-Fi · share still on Ethernet")

        // The SMB client reconnected on its own over Wi-Fi.
        network.sessionOnWiFi = true
        await controller.refresh(trigger: .networkChange)
        XCTAssertEqual(mounter.calls, [], "the app never unmounts for a slower link")
        title = await controller.status.title
        XCTAssertTrue(title.hasPrefix("NAS · Wi-Fi ⚠︎"), title)
    }

    func testFilesOpenElsewhereLeaveTheShareAlone() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        let mounter = FakeMounter(network: network)
        mounter.unmountFails = true
        let controller = makeController(network: network, mounter: mounter)
        await controller.start(settings: settings)
        XCTAssertEqual(mounter.calls, ["unmount /Volumes/CTTestNAS"], "no forced unmount, no remount")
        XCTAssertTrue(network.mounted)
        var status = await controller.status
        XCTAssertEqual(status.banner, .shareBusyElsewhere)
        XCTAssertTrue(status.lastSwitchFailed)
        XCTAssertEqual(status.phase, .connected)

        // The next automatic tries keep naming the real cause.
        await controller.refresh(trigger: .networkChange)
        await controller.refresh(trigger: .networkChange)
        status = await controller.status
        XCTAssertEqual(status.banner, .shareBusyElsewhere)
        XCTAssertEqual(mounter.calls.count, 2, "gave up after two refusals")

        // The other app let go; the user's Try Again works.
        mounter.unmountFails = false
        let moved = await controller.reconnect(userRequested: true)
        XCTAssertTrue(moved)
        status = await controller.status
        XCTAssertFalse(status.lastSwitchFailed)
        XCTAssertNil(status.banner)
    }

    func testARemountThatFindsNoAnswerIsRetriedOnce() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        let mounter = FakeMounter(network: network)
        mounter.unreachableMounts = 1
        let controller = makeController(network: network, mounter: mounter)
        await controller.start(settings: settings)
        XCTAssertEqual(mounter.calls.filter { $0.hasPrefix("mount") }.count, 2)
        let status = await controller.status
        XCTAssertEqual(status.phase, .connected)
        XCTAssertEqual(status.linkAssessment.state, .matched)
    }

    func testARemountThatFailsSaysSoAndOffersConnect() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        network.primaryRoute = "en0"
        let mounter = FakeMounter(network: network)
        let controller = makeController(network: network, mounter: mounter)
        await controller.start(settings: settings)
        mounter.unreachableMounts = 5
        network.primaryRoute = "en7"
        await controller.refresh(trigger: .networkChange)
        XCTAssertEqual(mounter.calls.filter { $0.hasPrefix("mount") }.count, 2, "one retry, no loop")
        let status = await controller.status
        XCTAssertEqual(status.phase, .offline)
        XCTAssertTrue(status.lastSwitchFailed)
        XCTAssertTrue(status.message?.contains("Click Connect") == true, status.message ?? "")
    }

    func testAutoSwitchOffKeepsAutoConnectButOnlyOffersTheButton() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        let mounter = FakeMounter(network: network)
        let controller = makeController(network: network, mounter: mounter)
        var manual = settings
        manual.autoSwitchLink = false
        await controller.start(settings: manual)
        XCTAssertEqual(mounter.calls, [])
        var status = await controller.status
        XCTAssertEqual(status.banner, .automaticOff)
        XCTAssertFalse(status.linkSwitchPending)

        // "Switch to Ethernet Now".
        let moved = await controller.reconnect(userRequested: true)
        XCTAssertTrue(moved)
        status = await controller.status
        XCTAssertEqual(status.linkAssessment.state, .matched)
    }

    func testAWaitingSwitchNowRequestRunsAtTheSafePointEvenWithAutomaticOff() async {
        let network = FakeNetwork(mounted: true, sessionOnWiFi: true)
        let mounter = FakeMounter(network: network)
        let inUse = Flag(true)
        let controller = makeController(network: network, mounter: mounter, inUse: inUse)
        var manual = settings
        manual.autoSwitchLink = false
        await controller.start(settings: manual)
        await controller.reconnectWhenIdle()
        var waiting = await controller.status.isWaitingToReconnect
        XCTAssertTrue(waiting)

        inUse.value = false
        await controller.switchAtSafePoint()
        waiting = await controller.status.isWaitingToReconnect
        XCTAssertFalse(waiting)
        XCTAssertEqual(mounter.calls, ["unmount /Volumes/CTTestNAS", "mount smb://someone@nas.example/CTTestNAS"])
    }
}
