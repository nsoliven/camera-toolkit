import Foundation

/// What kind of link an interface is, as far as NAS speed goes.
public enum NASInterfaceKind: String, Sendable, Equatable, Codable {
    case wifi
    case ethernet
    case thunderbolt
    case other

    public var isWired: Bool { self == .ethernet || self == .thunderbolt }

    public var displayName: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .thunderbolt: "Thunderbolt"
        case .other: "Network"
        }
    }
}

/// One local network interface with its IPv4/IPv6 addresses.
public struct NASNetworkInterface: Sendable, Equatable {
    public struct Address: Sendable, Equatable {
        public var address: String
        /// IPv4 netmask (dotted), nil for IPv6.
        public var netmask: String?

        public init(address: String, netmask: String? = nil) {
            self.address = address
            self.netmask = netmask
        }
    }

    public var bsdName: String
    public var kind: NASInterfaceKind
    /// SystemConfiguration's localized name ("USB 10/100/1000 LAN").
    public var displayName: String?
    public var isUp: Bool
    public var addresses: [Address]
    /// Negotiated link speed in Mb/s, when known.
    public var linkSpeedMbps: Int?

    public init(bsdName: String, kind: NASInterfaceKind, displayName: String? = nil, isUp: Bool = true, addresses: [Address] = [], linkSpeedMbps: Int? = nil) {
        self.bsdName = bsdName
        self.kind = kind
        self.displayName = displayName
        self.isUp = isUp
        self.addresses = addresses
        self.linkSpeedMbps = linkSpeedMbps
    }

    public func has(address: String) -> Bool {
        let wanted = NASAddress.normalized(address)
        return addresses.contains { NASAddress.normalized($0.address) == wanted }
    }

    /// True when `address` is on one of this interface's IPv4 subnets —
    /// directly reachable without a router.
    public func isOnLink(_ address: String) -> Bool {
        guard let target = NASAddress.ipv4(address) else { return false }
        return addresses.contains { entry in
            guard let mine = NASAddress.ipv4(entry.address), let mask = entry.netmask.flatMap(NASAddress.ipv4) else { return false }
            return mask != 0 && (mine & mask) == (target & mask)
        }
    }
}

public enum NASAddress {
    /// Drops a `%scope` suffix and lowercases, so IPv6 compares cleanly.
    public static func normalized(_ address: String) -> String {
        let bare = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        return bare.lowercased()
    }

    public static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        return value
    }
}

/// Classifies an interface from its SystemConfiguration type and name.
/// `scType` is the `kSCNetworkInterfaceType*` string ("IEEE80211",
/// "Ethernet", "Bridge", "Bond", …); nil when SystemConfiguration does not
/// know the interface.
public enum NASInterfaceClassifier {
    public static func kind(bsdName: String, scType: String?, displayName: String?) -> NASInterfaceKind {
        let name = displayName?.lowercased() ?? ""
        switch scType {
        case "IEEE80211":
            return .wifi
        case "Bridge":
            return name.contains("thunderbolt") || bsdName.hasPrefix("bridge") ? .thunderbolt : .other
        case "Ethernet", "Bond", "VLAN":
            if name.contains("thunderbolt") { return .thunderbolt }
            if name.contains("wi-fi") || name.contains("airport") { return .wifi }
            return .ethernet
        default:
            if name.contains("wi-fi") { return .wifi }
            if name.contains("thunderbolt") { return .thunderbolt }
            return .other
        }
    }

    /// "1 GbE", "2.5 GbE", "10 GbE", "100 Mb/s".
    public static func linkSpeedLabel(mbps: Int) -> String {
        if mbps >= 1000 {
            let gigabits = Double(mbps) / 1000
            let text = gigabits == gigabits.rounded() ? String(Int(gigabits)) : String(format: "%.1f", gigabits)
            return "\(text) GbE"
        }
        return "\(mbps) Mb/s"
    }
}

/// Which TCP connection carries the SMB session behind a mount, and how
/// sure the pick is.
public struct NASSessionMatch: Sendable, Equatable {
    public enum Confidence: String, Sendable, Equatable {
        /// smbutil named the client interface(s) directly (multichannel).
        case reportedBySMB
        /// Exactly one established connection to the server's port 445.
        case onlyConnection
        /// Several connections (another share or Time Machine on the same
        /// server); picked the one whose byte counters match the session's.
        case matchedByTraffic
        /// The socket list was not readable; the last speed test's
        /// outbound bytes showed which interface carried the session.
        case measuredBySpeedTest
    }

    public var localAddresses: [String]
    public var interfaceNames: [String]
    public var confidence: Confidence

    public init(localAddresses: [String], interfaceNames: [String] = [], confidence: Confidence) {
        self.localAddresses = localAddresses
        self.interfaceNames = interfaceNames
        self.confidence = confidence
    }
}

public enum NASSessionLocator {
    public static let smbPort = 445
    /// Below this the sent counters of two quiet sessions are too alike to
    /// tell apart.
    public static let minimumSessionBytes: Int64 = 64 * 1024

    /// Picks the session's connection among the established connections to
    /// `serverAddresses` on port 445. Nil when there is none, or when there
    /// are several and nothing tells them apart — the caller then says
    /// "unknown" instead of guessing.
    public static func locate(
        connections: [NASTCPConnection],
        serverAddresses: [String],
        session: NASSMBSessionStats?
    ) -> NASSessionMatch? {
        if let session, !session.clientInterfaces.isEmpty {
            return NASSessionMatch(localAddresses: [], interfaceNames: session.clientInterfaces, confidence: .reportedBySMB)
        }
        let servers = Set(serverAddresses.map(NASAddress.normalized))
        let candidates = connections.filter {
            $0.isEstablished && $0.remotePort == smbPort && servers.contains(NASAddress.normalized($0.remoteAddress))
        }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 {
            return NASSessionMatch(localAddresses: [candidates[0].localAddress], confidence: .onlyConnection)
        }
        // Sent bytes only. The socket's sent count is the session's SMB
        // messages plus TCP-level framing, so the two track within a
        // fraction of a percent. Received bytes do not: the socket's count
        // can run to twice what smbutil reports, so they would only blur
        // the match.
        guard let tx = session?.totalTxBytes, tx >= minimumSessionBytes else { return nil }
        let scored = candidates.compactMap { connection -> (NASTCPConnection, Double)? in
            guard let sent = connection.txBytes else { return nil }
            return (connection, relativeDistance(Double(sent), Double(tx)))
        }.sorted { $0.1 < $1.1 }
        guard let best = scored.first else { return nil }
        // Refuse a pick that is not close, or that a runner-up matches
        // about as well: "unknown" beats a wrong answer.
        guard best.1 < 0.05 else { return nil }
        if scored.count > 1, scored[1].1 < best.1 * 2 + 0.02 { return nil }
        return NASSessionMatch(localAddresses: [best.0.localAddress], confidence: .matchedByTraffic)
    }

    static func relativeDistance(_ a: Double, _ b: Double) -> Double {
        let scale = max(abs(a), abs(b), 1)
        return abs(a - b) / scale
    }
}

/// Which interface carried a speed test's writes, from the interfaces'
/// outbound byte counters before and after it. Works when the socket list
/// is hidden from the app. The counters are 32-bit and wrap; a few seconds'
/// delta never wraps twice.
public enum NASTrafficAttribution {
    public static func sendingInterface(
        before: [String: UInt32],
        after: [String: UInt32],
        bytesWritten: Int64
    ) -> String? {
        guard bytesWritten > 0 else { return nil }
        let deltas = after.compactMap { name, end -> (String, Int64)? in
            guard let start = before[name] else { return nil }
            return (name, Int64(end &- start))
        }.sorted { $0.1 > $1.1 }
        guard let best = deltas.first else { return nil }
        // Most of the test's bytes, and clearly more than any other link
        // (another backup running over Wi-Fi at the same time, say).
        guard Double(best.1) >= Double(bytesWritten) * 0.6 else { return nil }
        if deltas.count > 1, deltas[1].1 * 2 > best.1 { return nil }
        return best.0
    }
}
