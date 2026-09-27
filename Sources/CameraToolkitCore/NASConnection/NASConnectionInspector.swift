import Darwin
import Foundation
import SystemConfiguration

/// One row of the mount table, read without touching the filesystem.
public struct NASMountTableEntry: Sendable, Equatable {
    public var mountedOn: String
    public var mountedFrom: String
    public var fileSystemType: String

    public init(mountedOn: String, mountedFrom: String, fileSystemType: String) {
        self.mountedOn = mountedOn
        self.mountedFrom = mountedFrom
        self.fileSystemType = fileSystemType
    }

    public var isSMB: Bool { fileSystemType.lowercased() == "smbfs" }
}

/// The system reads the connection check needs, behind a protocol so the
/// inspector and the guard run against fixtures in tests.
public protocol NASNetworkProbing: Sendable {
    /// The mount table entry for exactly `mountPoint`, or nil when nothing
    /// is mounted there. Must not stat the share (a hung share blocks).
    func mountEntry(at mountPoint: String) -> NASMountTableEntry?
    func smbSession(mountPoint: String) -> NASSMBSessionStats?
    func tcpConnections() -> [NASTCPConnection]
    func interfaces() -> [NASNetworkInterface]
    /// The interface `route get` picks for `address`, optionally scoped to
    /// one interface (nil when that interface has no route there).
    func routeInterface(to address: String, scopedTo interface: String?) -> String?
    /// Numeric addresses for a host name (a literal comes back as itself).
    func resolve(host: String) -> [String]
    /// Each interface's outbound byte counter (32-bit, wrapping).
    func interfaceSentByteCounters() -> [String: UInt32]
}

/// Everything known about how the NAS share is connected, at one moment.
public struct NASConnectionSnapshot: Sendable, Equatable {
    public enum Mount: Sendable, Equatable {
        case notMounted
        /// Something that is not an SMB share is mounted there — never
        /// unmounted or reconnected by the guard.
        case notSMB(fileSystemType: String)
        case mounted(NASMountSource)
    }

    public var mountPoint: String
    public var mount: Mount
    public var serverAddresses: [String]
    public var session: NASSessionMatch?
    /// The interfaces the session's connection(s) use.
    public var sessionInterfaces: [NASNetworkInterface]
    /// Up wired interfaces that reach the server (on-link or routed).
    public var wiredRoutes: [NASNetworkInterface]
    /// The interface the routing table picks for the server right now.
    public var primaryRouteInterface: String?
    /// smbutil's setup time + reconnect count: changes when the session is
    /// re-established, which can move it to another link.
    public var sessionIdentity: String?
    /// True when netstat listed no TCP connection at all — the socket list
    /// is hidden from this process (seen for processes macOS has not given
    /// network visibility), not a machine with no connections.
    public var socketListHidden = false

    public init(
        mountPoint: String,
        mount: Mount,
        serverAddresses: [String] = [],
        session: NASSessionMatch? = nil,
        sessionInterfaces: [NASNetworkInterface] = [],
        wiredRoutes: [NASNetworkInterface] = [],
        primaryRouteInterface: String? = nil,
        sessionIdentity: String? = nil,
        socketListHidden: Bool = false
    ) {
        self.mountPoint = mountPoint
        self.mount = mount
        self.serverAddresses = serverAddresses
        self.session = session
        self.sessionInterfaces = sessionInterfaces
        self.wiredRoutes = wiredRoutes
        self.primaryRouteInterface = primaryRouteInterface
        self.sessionIdentity = sessionIdentity
        self.socketListHidden = socketListHidden
    }

    /// Names one mount's one SMB session: a remount or an SMB-level
    /// reconnect is a new key.
    public var mountKey: String? {
        guard case .mounted(let source) = mount else { return nil }
        return "\(mountPoint)|\(source.host)|\(source.share)|\(sessionIdentity ?? "")"
    }

    public var isMounted: Bool {
        if case .mounted = mount { return true }
        return false
    }

    /// The session's link kind: wired when any channel is wired (a
    /// multichannel session spreads over all of them), Wi-Fi when every
    /// channel is, nil when the session's connection could not be pinned.
    public var sessionKind: NASInterfaceKind? {
        guard !sessionInterfaces.isEmpty else { return nil }
        if let wired = sessionInterfaces.first(where: { $0.kind.isWired }) { return wired.kind }
        if sessionInterfaces.allSatisfy({ $0.kind == .wifi }) { return .wifi }
        return .other
    }

    /// The interface to name in the status line.
    public var primarySessionInterface: NASNetworkInterface? {
        sessionInterfaces.first(where: { $0.kind.isWired }) ?? sessionInterfaces.first
    }

    public var hasWiredRoute: Bool { !wiredRoutes.isEmpty }
}

/// Works out which local interface the NAS share's SMB session uses:
/// the mount table gives the server; `smbutil multichannel` gives the
/// session's server address and byte counters (and its client interfaces
/// when multichannel is on); `netstat` lists the established connections to
/// that server's port 445 with their local address and counters; the local
/// address maps to an interface through `getifaddrs`, classified with
/// SystemConfiguration. No root, no packets sent.
public struct NASConnectionInspector: Sendable {
    public let probe: any NASNetworkProbing

    public init(probe: any NASNetworkProbing = SystemNASNetworkProbe()) {
        self.probe = probe
    }

    /// `measured` is the interface the last speed test on this same session
    /// (`mountKey`) saw carry its writes; used only when the socket list
    /// cannot pin the session down.
    public func inspect(mountPoint: String, measured: (mountKey: String, interface: String)? = nil) -> NASConnectionSnapshot {
        guard let entry = probe.mountEntry(at: mountPoint) else {
            return NASConnectionSnapshot(mountPoint: mountPoint, mount: .notMounted)
        }
        guard entry.isSMB, let source = NASMountSource.parse(entry.mountedFrom) else {
            return NASConnectionSnapshot(mountPoint: mountPoint, mount: .notSMB(fileSystemType: entry.fileSystemType))
        }
        let session = probe.smbSession(mountPoint: mountPoint)
        var servers = session?.serverAddresses ?? []
        if servers.isEmpty { servers = probe.resolve(host: source.host) }
        let interfaces = probe.interfaces()
        let connections = probe.tcpConnections()
        var match = NASSessionLocator.locate(
            connections: connections,
            serverAddresses: servers,
            session: session
        )
        let key = NASConnectionSnapshot(mountPoint: mountPoint, mount: .mounted(source), sessionIdentity: session?.sessionIdentity).mountKey
        if match == nil, let measured, measured.mountKey == key {
            match = NASSessionMatch(localAddresses: [], interfaceNames: [measured.interface], confidence: .measuredBySpeedTest)
        }
        var sessionInterfaces: [NASNetworkInterface] = []
        if let match {
            for name in match.interfaceNames {
                if let interface = interfaces.first(where: { $0.bsdName == name }) { sessionInterfaces.append(interface) }
            }
            for address in match.localAddresses {
                if let interface = interfaces.first(where: { $0.has(address: address) }),
                   !sessionInterfaces.contains(where: { $0.bsdName == interface.bsdName }) {
                    sessionInterfaces.append(interface)
                }
            }
        }
        let wired = wiredRoutes(to: servers, interfaces: interfaces)
        return NASConnectionSnapshot(
            mountPoint: mountPoint,
            mount: .mounted(source),
            serverAddresses: servers,
            session: match,
            sessionInterfaces: sessionInterfaces,
            wiredRoutes: wired,
            primaryRouteInterface: servers.first.flatMap { probe.routeInterface(to: $0, scopedTo: nil) },
            sessionIdentity: session?.sessionIdentity,
            socketListHidden: connections.isEmpty
        )
    }

    /// Up wired interfaces with an address that reach one of `servers`:
    /// on the same subnet, or with a scoped route there.
    public func wiredRoutes(to servers: [String], interfaces: [NASNetworkInterface]) -> [NASNetworkInterface] {
        interfaces.filter { interface in
            guard interface.kind.isWired, interface.isUp, !interface.addresses.isEmpty else { return false }
            return servers.contains { server in
                interface.isOnLink(server) || probe.routeInterface(to: server, scopedTo: interface.bsdName) == interface.bsdName
            }
        }
    }
}

/// Runs a system tool and returns its standard output, or nil when it
/// failed or timed out.
public protocol NASCommandRunning: Sendable {
    func output(of executable: String, arguments: [String], timeout: TimeInterval) -> String?
}

public struct SystemNASCommandRunner: NASCommandRunning {
    public init() {}

    public func output(of executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        guard let result = try? NASRemoteVerifier.run(executable: executable, arguments: arguments, timeout: timeout),
              result.status == 0 else { return nil }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}

/// The real reads: `getmntinfo(MNT_NOWAIT)`, `smbutil`, `netstat`,
/// `route`, `ifconfig`, `getifaddrs`, and SystemConfiguration.
public struct SystemNASNetworkProbe: NASNetworkProbing {
    public let runner: any NASCommandRunning
    public let timeout: TimeInterval

    public init(runner: any NASCommandRunning = SystemNASCommandRunner(), timeout: TimeInterval = 5) {
        self.runner = runner
        self.timeout = timeout
    }

    public func mountEntry(at mountPoint: String) -> NASMountTableEntry? {
        Self.mountTable().first { $0.mountedOn == mountPoint }
    }

    public static func mountTable() -> [NASMountTableEntry] {
        var buffer: UnsafeMutablePointer<statfs>?
        // MNT_NOWAIT answers from the kernel's cached table: a hung share
        // cannot block it.
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        return (0..<Int(count)).map { index in
            var entry = buffer[index]
            let on = withUnsafeBytes(of: &entry.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let type = withUnsafeBytes(of: &entry.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return NASMountTableEntry(mountedOn: on, mountedFrom: from, fileSystemType: type)
        }
    }

    public func smbSession(mountPoint: String) -> NASSMBSessionStats? {
        runner.output(of: "/usr/bin/smbutil", arguments: ["multichannel", "-m", mountPoint], timeout: timeout)
            .flatMap(SMBMultichannelParser.parse)
    }

    public func tcpConnections() -> [NASTCPConnection] {
        runner.output(of: "/usr/sbin/netstat", arguments: ["-anvp", "tcp"], timeout: timeout)
            .map(NetstatParser.parse) ?? []
    }

    public func routeInterface(to address: String, scopedTo interface: String?) -> String? {
        var arguments = ["-n", "get"]
        if let interface { arguments += ["-ifscope", interface] }
        arguments.append(address)
        return runner.output(of: "/sbin/route", arguments: arguments, timeout: timeout).flatMap(RouteGetParser.interface)
    }

    public func resolve(host: String) -> [String] {
        if NASAddress.ipv4(host) != nil || host.contains(":") { return [host] }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "445", &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let address = Self.numericHost(info.pointee.ai_addr), !addresses.contains(address) {
                addresses.append(address)
            }
            cursor = info.pointee.ai_next
        }
        return addresses
    }

    public func interfaceSentByteCounters() -> [String: UInt32] {
        var counters: [String: UInt32] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
                  let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            counters[String(cString: entry.pointee.ifa_name)] = data.pointee.ifi_obytes
        }
        return counters
    }

    public func interfaces() -> [NASNetworkInterface] {
        var kinds: [String: (type: String?, name: String?)] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
                kinds[bsd] = (
                    SCNetworkInterfaceGetInterfaceType(interface) as String?,
                    SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
                )
            }
        }
        var byName: [String: NASNetworkInterface] = [:]
        var order: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let name = String(cString: entry.pointee.ifa_name)
            let flags = Int32(entry.pointee.ifa_flags)
            if byName[name] == nil {
                let known = kinds[name]
                byName[name] = NASNetworkInterface(
                    bsdName: name,
                    kind: NASInterfaceClassifier.kind(bsdName: name, scType: known?.type, displayName: known?.name),
                    displayName: known?.name,
                    isUp: (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
                )
                order.append(name)
            }
            guard let address = entry.pointee.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET, AF_INET6:
                guard let host = Self.numericHost(address) else { continue }
                let mask = Int32(address.pointee.sa_family) == AF_INET ? entry.pointee.ifa_netmask.flatMap(Self.numericHost) : nil
                byName[name]?.addresses.append(.init(address: host, netmask: mask))
            case AF_LINK:
                if let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    let baud = Int(data.pointee.ifi_baudrate)
                    if baud > 0 { byName[name]?.linkSpeedMbps = baud / 1_000_000 }
                }
            default:
                break
            }
        }
        return order.compactMap { name in
            guard var interface = byName[name] else { return nil }
            // ifconfig's negotiated media is the exact wired speed (the
            // baud rate field tops out at 4 Gb/s).
            if interface.kind.isWired, interface.isUp, !interface.addresses.isEmpty,
               let media = runner.output(of: "/sbin/ifconfig", arguments: [name], timeout: timeout).flatMap(IfconfigMediaParser.linkSpeedMbps) {
                interface.linkSpeedMbps = media
            }
            return interface
        }
    }

    static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.pointee.sa_len)
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }
}
