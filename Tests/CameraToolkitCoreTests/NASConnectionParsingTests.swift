import CameraToolkitCore
import Foundation
import XCTest

// Fixtures use documentation addresses (RFC 5737 / RFC 3849) and made-up
// names only.
final class NASConnectionParsingTests: XCTestCase {
    static let netstatVerbose = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
    tcp4       0      0  198.51.100.20.61781    203.0.113.4.443        ESTABLISHED         6502         2563  131072  131328     Some App:1910   00102 00000008 0000000000540e24 00000081 04000900      2      0 000000
    tcp4       0      0  192.0.2.30.61042       192.0.2.2.445          ESTABLISHED      4403218   1075986227  131072 2344632      kernel_task:0      00082 00000008 000000000053f6f0 00000082 04104900      3      0 000000
    tcp4       0 892928  192.0.2.58.51314       192.0.2.2.445          ESTABLISHED  13319807076  51417255966 2096560  892928      kernel_task:0      00082 00000008 00000000004fcf65 00000082 04104900      4      0 000000
    tcp6       0      0  2001:db8::5%en7.50000  2001:db8::2.445        ESTABLISHED          100          200  131072  131328      kernel_task:0      00082 00000008 00000000004fcf65 00000082 04104900      4      0 000000
    tcp4       0      0  *.445                  *.*                    LISTEN                 0            0  131072  131072      smbd:99         00000 00000006 0000000000000001 00000000 00000800      1      0 000000
    tcp4       0      0  192.0.2.30.61043       192.0.2.2.445          TIME_WAIT              0            0  131072  131072      kernel_task:0      00000 00000006 0000000000000001 00000000 00000800      1      0 000000
    """

    static let netstatPlain = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
    tcp4       0      0  192.0.2.30.61042       192.0.2.2.445          ESTABLISHED
    tcp4       0      0  *.22                   *.*                    LISTEN
    """

    static let multichannelOff = """
    Session: /Volumes/share
    Info: Setup Time: 2026-01-01 10:00:00, Multichannel ON: no, Reconnect Count: 0
    \tTotal RX Bytes: 1986993 (Packets: 7212)
    \tTotal TX Bytes: 1075958462 (Packets: 7130)
           id         client IF             server IF   state                     server ip                 port   speed
    ========================================================================================================================
    M     217     N/A                          N/A      [session active       ]   192.0.2.2                 445    N/A
    """

    static let multichannelOn = """
    Session: /Volumes/share
    Info: Setup Time: 2026-01-01 10:00:00, Multichannel ON: yes, Reconnect Count: 0
    \tTotal RX Bytes: 10 (Packets: 1)
    \tTotal TX Bytes: 20 (Packets: 1)
           id         client IF             server IF   state                     server ip                 port   speed
    ========================================================================================================================
    M     300     en7(1Gb)                     eth0      [session active       ]   192.0.2.2                 445    1 Gb
    A     301     en0                          eth0      [session active       ]   192.0.2.2                 445    433 Mb
    """

    // MARK: netstat

    func testNetstatVerboseParsesEndpointsStatesAndCounters() {
        let connections = NetstatParser.parse(Self.netstatVerbose)
        XCTAssertEqual(connections.count, 5, "the LISTEN row has no remote address and is skipped")
        let smb = connections.filter { $0.remotePort == 445 && $0.isEstablished }
        XCTAssertEqual(smb.map(\.localAddress), ["192.0.2.30", "192.0.2.58", "2001:db8::5%en7"])
        XCTAssertEqual(smb[0].localPort, 61042)
        XCTAssertEqual(smb[0].rxBytes, 4_403_218)
        XCTAssertEqual(smb[0].txBytes, 1_075_986_227)
        XCTAssertEqual(smb[2].remoteAddress, "2001:db8::2")
        XCTAssertTrue(connections.contains { $0.state == "TIME_WAIT" && !$0.isEstablished })
    }

    func testNetstatPlainHasNoCounters() {
        let connections = NetstatParser.parse(Self.netstatPlain)
        XCTAssertEqual(connections.count, 1)
        XCTAssertNil(connections[0].txBytes)
        XCTAssertEqual(connections[0].remoteAddress, "192.0.2.2")
    }

    func testEndpointSplitsAtTheLastDot() {
        XCTAssertEqual(NetstatParser.splitEndpoint("192.0.2.2.445")?.address, "192.0.2.2")
        XCTAssertEqual(NetstatParser.splitEndpoint("fe80::1%en0.52341")?.port, 52341)
        XCTAssertNil(NetstatParser.splitEndpoint("*.*"))
        XCTAssertNil(NetstatParser.splitEndpoint("*.445"))
        XCTAssertNil(NetstatParser.splitEndpoint("garbage"))
    }

    // MARK: smbutil

    func testMultichannelOffGivesCountersAndServerButNoInterfaces() throws {
        let stats = try XCTUnwrap(SMBMultichannelParser.parse(Self.multichannelOff))
        XCTAssertFalse(stats.multichannel)
        XCTAssertEqual(stats.totalRxBytes, 1_986_993)
        XCTAssertEqual(stats.totalTxBytes, 1_075_958_462)
        XCTAssertEqual(stats.serverAddresses, ["192.0.2.2"])
        XCTAssertEqual(stats.clientInterfaces, [])
        XCTAssertEqual(stats.setupTime, "2026-01-01 10:00:00")
        XCTAssertEqual(stats.reconnectCount, 0)
        XCTAssertEqual(stats.sessionIdentity, "2026-01-01 10:00:00#0")
    }

    func testTrafficAttributionPicksTheLinkThatCarriedTheWrites() {
        let written: Int64 = 64 * 1024 * 1024
        // en7 carried the test; en0 wrapped its 32-bit counter meanwhile.
        XCTAssertEqual(NASTrafficAttribution.sendingInterface(
            before: ["en0": 4_294_967_000, "en7": 10],
            after: ["en0": 2_000, "en7": 10 + UInt32(written) + 50_000],
            bytesWritten: written
        ), "en7")
        // Nothing carried most of it.
        XCTAssertNil(NASTrafficAttribution.sendingInterface(
            before: ["en0": 0, "en7": 0], after: ["en0": 1_000, "en7": 2_000], bytesWritten: written
        ))
        // Two links about as busy: another upload on Wi-Fi at the same time.
        XCTAssertNil(NASTrafficAttribution.sendingInterface(
            before: ["en0": 0, "en7": 0], after: ["en0": UInt32(written), "en7": UInt32(written) + 10], bytesWritten: written
        ))
        XCTAssertNil(NASTrafficAttribution.sendingInterface(before: [:], after: ["en7": 5], bytesWritten: written))
    }

    func testMultichannelOnListsClientInterfaces() throws {
        let stats = try XCTUnwrap(SMBMultichannelParser.parse(Self.multichannelOn))
        XCTAssertTrue(stats.multichannel)
        XCTAssertEqual(stats.clientInterfaces, ["en7", "en0"])
        XCTAssertEqual(stats.serverAddresses, ["192.0.2.2"])
    }

    func testMultichannelWithoutASessionIsNil() {
        XCTAssertNil(SMBMultichannelParser.parse("smbutil: no mounted shares"))
    }

    // MARK: route / ifconfig / mount source

    func testRouteGetInterface() {
        let output = """
           route to: 192.0.2.2
        destination: 192.0.2.2
          interface: en7
              flags: <UP,HOST,DONE,LLINFO,WASCLONED,IFSCOPE,IFREF>
        """
        XCTAssertEqual(RouteGetParser.interface(in: output), "en7")
        XCTAssertNil(RouteGetParser.interface(in: "route: writing to routing socket: not in table"))
    }

    func testIfconfigMediaSpeeds() {
        func media(_ line: String) -> Int? { IfconfigMediaParser.linkSpeedMbps(in: "en9: flags=8863<UP>\n\t\(line)\n\tstatus: active") }
        XCTAssertEqual(media("media: autoselect (1000baseT <full-duplex>)"), 1000)
        XCTAssertEqual(media("media: autoselect (10GbaseT <full-duplex,flow-control>)"), 10_000)
        XCTAssertEqual(media("media: autoselect (2500Base-T <full-duplex>)"), 2500)
        XCTAssertEqual(media("media: autoselect (100baseTX <full-duplex>)"), 100)
        XCTAssertEqual(media("media: 1000baseT <full-duplex>"), 1000)
        XCTAssertNil(media("media: autoselect (none)"))
        XCTAssertNil(media("media: autoselect"))
        XCTAssertNil(IfconfigMediaParser.linkSpeedMbps(in: "no media line"))
    }

    func testMountSourceParsesUserPortAndEncodedShare() throws {
        let plain = try XCTUnwrap(NASMountSource.parse("//someone@nas.example/photos"))
        XCTAssertEqual(plain, NASMountSource(host: "nas.example", share: "photos"))
        let port = try XCTUnwrap(NASMountSource.parse("//192.0.2.2:445/My%20Share"))
        XCTAssertEqual(port, NASMountSource(host: "192.0.2.2", share: "My Share"))
        XCTAssertNil(NASMountSource.parse("/dev/disk4s1"))
        XCTAssertTrue(plain.matches(URL(string: "smb://someone@NAS.example/photos")!))
        XCTAssertFalse(plain.matches(URL(string: "smb://nas.example/other")!))
        XCTAssertFalse(plain.matches(URL(string: "smb://other.example/photos")!))
    }

    // MARK: classification

    func testInterfaceClassification() {
        XCTAssertEqual(NASInterfaceClassifier.kind(bsdName: "en0", scType: "IEEE80211", displayName: "Wi-Fi"), .wifi)
        XCTAssertEqual(NASInterfaceClassifier.kind(bsdName: "en7", scType: "Ethernet", displayName: "USB 10/100/1000 LAN"), .ethernet)
        XCTAssertEqual(NASInterfaceClassifier.kind(bsdName: "en4", scType: "Ethernet", displayName: "Ethernet Adapter (en4)"), .ethernet)
        XCTAssertEqual(NASInterfaceClassifier.kind(bsdName: "en1", scType: "Ethernet", displayName: "Thunderbolt 1"), .thunderbolt)
        XCTAssertEqual(NASInterfaceClassifier.kind(bsdName: "bridge0", scType: "Bridge", displayName: "Thunderbolt Bridge"), .thunderbolt)
        XCTAssertEqual(NASInterfaceClassifier.kind(bsdName: "bond0", scType: "Bond", displayName: "Bond"), .ethernet)
        XCTAssertEqual(NASInterfaceClassifier.kind(bsdName: "utun3", scType: nil, displayName: nil), .other)
        XCTAssertTrue(NASInterfaceKind.ethernet.isWired)
        XCTAssertTrue(NASInterfaceKind.thunderbolt.isWired)
        XCTAssertFalse(NASInterfaceKind.wifi.isWired)
        XCTAssertFalse(NASInterfaceKind.other.isWired)
    }

    func testLinkSpeedLabels() {
        XCTAssertEqual(NASInterfaceClassifier.linkSpeedLabel(mbps: 1000), "1 GbE")
        XCTAssertEqual(NASInterfaceClassifier.linkSpeedLabel(mbps: 2500), "2.5 GbE")
        XCTAssertEqual(NASInterfaceClassifier.linkSpeedLabel(mbps: 10_000), "10 GbE")
        XCTAssertEqual(NASInterfaceClassifier.linkSpeedLabel(mbps: 100), "100 Mb/s")
    }

    func testOnLinkUsesTheNetmask() {
        let wired = NASNetworkInterface(bsdName: "en7", kind: .ethernet, addresses: [.init(address: "192.0.2.30", netmask: "255.255.254.0")])
        XCTAssertTrue(wired.isOnLink("192.0.3.2"))
        XCTAssertFalse(wired.isOnLink("198.51.100.2"))
        XCTAssertFalse(wired.isOnLink("not an address"))
        XCTAssertTrue(wired.has(address: "192.0.2.30"))
    }

    // MARK: session locator

    func testSingleConnectionIsTheSession() throws {
        let match = try XCTUnwrap(NASSessionLocator.locate(
            connections: NetstatParser.parse(Self.netstatPlain),
            serverAddresses: ["192.0.2.2"],
            session: nil
        ))
        XCTAssertEqual(match.localAddresses, ["192.0.2.30"])
        XCTAssertEqual(match.confidence, .onlyConnection)
    }

    func testTwoConnectionsToTheSameServerAreToldApartByTraffic() throws {
        // A second session (Time Machine, another share) to the same server.
        let match = try XCTUnwrap(NASSessionLocator.locate(
            connections: NetstatParser.parse(Self.netstatVerbose),
            serverAddresses: ["192.0.2.2"],
            session: SMBMultichannelParser.parse(Self.multichannelOff)
        ))
        XCTAssertEqual(match.localAddresses, ["192.0.2.30"])
        XCTAssertEqual(match.confidence, .matchedByTraffic)
    }

    func testAmbiguousConnectionsWithoutCountersAreUnknown() {
        let connections = [
            NASTCPConnection(localAddress: "192.0.2.30", localPort: 1, remoteAddress: "192.0.2.2", remotePort: 445, state: "ESTABLISHED"),
            NASTCPConnection(localAddress: "192.0.2.58", localPort: 2, remoteAddress: "192.0.2.2", remotePort: 445, state: "ESTABLISHED"),
        ]
        XCTAssertNil(NASSessionLocator.locate(connections: connections, serverAddresses: ["192.0.2.2"], session: nil))
    }

    func testCountersThatMatchBothConnectionsAreUnknown() {
        let connections = [
            NASTCPConnection(localAddress: "192.0.2.30", localPort: 1, remoteAddress: "192.0.2.2", remotePort: 445, state: "ESTABLISHED", rxBytes: 1000, txBytes: 100_000),
            NASTCPConnection(localAddress: "192.0.2.58", localPort: 2, remoteAddress: "192.0.2.2", remotePort: 445, state: "ESTABLISHED", rxBytes: 1000, txBytes: 101_000),
        ]
        let session = NASSMBSessionStats(totalRxBytes: 1000, totalTxBytes: 100_500)
        XCTAssertNil(NASSessionLocator.locate(connections: connections, serverAddresses: ["192.0.2.2"], session: session))
    }

    func testCountersFarFromEveryConnectionAreUnknown() {
        let connections = [
            NASTCPConnection(localAddress: "192.0.2.30", localPort: 1, remoteAddress: "192.0.2.2", remotePort: 445, state: "ESTABLISHED", rxBytes: 10, txBytes: 10),
            NASTCPConnection(localAddress: "192.0.2.58", localPort: 2, remoteAddress: "192.0.2.2", remotePort: 445, state: "ESTABLISHED", rxBytes: 5_000_000, txBytes: 9_000_000),
        ]
        let session = NASSMBSessionStats(totalRxBytes: 1_000_000, totalTxBytes: 1_000_000)
        XCTAssertNil(NASSessionLocator.locate(connections: connections, serverAddresses: ["192.0.2.2"], session: session))
    }

    func testMultichannelInterfacesWinOverSockets() throws {
        let match = try XCTUnwrap(NASSessionLocator.locate(
            connections: [],
            serverAddresses: ["192.0.2.2"],
            session: SMBMultichannelParser.parse(Self.multichannelOn)
        ))
        XCTAssertEqual(match.interfaceNames, ["en7", "en0"])
        XCTAssertEqual(match.confidence, .reportedBySMB)
    }

    func testOtherServersAndPortsAreIgnored() {
        let connections = [
            NASTCPConnection(localAddress: "192.0.2.30", localPort: 1, remoteAddress: "192.0.2.9", remotePort: 445, state: "ESTABLISHED"),
            NASTCPConnection(localAddress: "192.0.2.30", localPort: 2, remoteAddress: "192.0.2.2", remotePort: 139, state: "ESTABLISHED"),
        ]
        XCTAssertNil(NASSessionLocator.locate(connections: connections, serverAddresses: ["192.0.2.2"], session: nil))
    }
}
