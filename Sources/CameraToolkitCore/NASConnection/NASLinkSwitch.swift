import Foundation

// The NAS link switch, as pure values: which link the route to the NAS
// takes, which link the live SMB session actually rides, whether moving the
// session is worth a reconnect, and whether the job queue is at a point
// where it may happen. No system calls here, so every rule has a test.

/// The route to the NAS against the SMB session behind the share.
///
/// macOS moves the route the moment a better link comes up (plugging in
/// Ethernet), but an SMB session without multichannel keeps its TCP
/// connection on the link it was opened on until the share reconnects.
/// The two can disagree for as long as the share stays mounted.
public struct NASLinkAssessment: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        /// The session's link is not pinned down (hidden sockets before a
        /// speed test, several look-alike connections) or there is no route.
        case unknown
        /// The session rides the link the route picks (or one as fast).
        case matched
        /// The route uses a faster link than the session: a reconnect would
        /// move the share onto it.
        case fasterLinkAvailable
        /// The route fell back to a slower link while the session is still
        /// on the faster one (a cable just pulled). The SMB client reconnects
        /// on its own; nothing to do but show it.
        case sessionOnFasterLink
    }

    /// The interface the routing table picks for the NAS right now.
    public var route: NASNetworkInterface?
    /// The interface(s) the session's connection(s) use.
    public var sessionInterfaces: [NASNetworkInterface]
    public var state: State

    public init(route: NASNetworkInterface?, sessionInterfaces: [NASNetworkInterface]) {
        self.route = route
        self.sessionInterfaces = sessionInterfaces
        self.state = Self.state(route: route, sessionInterfaces: sessionInterfaces)
    }

    /// The session interface to name: a wired channel first.
    public var session: NASNetworkInterface? {
        sessionInterfaces.first(where: { $0.kind.isWired }) ?? sessionInterfaces.first
    }

    static func state(route: NASNetworkInterface?, sessionInterfaces: [NASNetworkInterface]) -> State {
        guard let route, !sessionInterfaces.isEmpty else { return .unknown }
        // A multichannel session with a channel on the routed link already
        // uses it.
        if sessionInterfaces.contains(where: { $0.bsdName == route.bsdName }) { return .matched }
        let best = sessionInterfaces.max { isFaster($1, than: $0) == true } ?? sessionInterfaces[0]
        if isFaster(route, than: best) == true { return .fasterLinkAvailable }
        if isFaster(best, than: route) == true { return .sessionOnFasterLink }
        // Same tier, no speed to tell them apart, or a link of unknown kind
        // (a VPN tunnel): never reconnect on a guess.
        return route.kind == .other || best.kind == .other ? .unknown : .matched
    }

    /// True when `a` is clearly faster than `b`; nil when they cannot be
    /// compared (an interface of unknown kind). Wired beats Wi-Fi; between
    /// two wired links the higher negotiated speed wins when both are known.
    public static func isFaster(_ a: NASNetworkInterface, than b: NASNetworkInterface) -> Bool? {
        if a.kind == .other || b.kind == .other { return nil }
        if a.kind.isWired != b.kind.isWired { return a.kind.isWired }
        guard a.kind.isWired, let left = a.linkSpeedMbps, let right = b.linkSpeedMbps else { return false }
        return left > right
    }

    /// "Ethernet available · share still on Wi-Fi" when the two disagree.
    public var summary: String? {
        guard let route, let session else { return nil }
        switch state {
        case .fasterLinkAvailable:
            return "\(Self.name(route, against: session)) available · share still on \(Self.name(session, against: route))"
        case .sessionOnFasterLink:
            return "Route moved to \(Self.name(route, against: session)) · share still on \(Self.name(session, against: route))"
        case .matched, .unknown:
            return nil
        }
    }

    /// The link kind, with the speed when both sides share the kind
    /// ("Ethernet 10 GbE" against "Ethernet 1 GbE").
    static func name(_ interface: NASNetworkInterface, against other: NASNetworkInterface) -> String {
        let kind = interface.kind == .other ? (interface.displayName ?? interface.bsdName) : interface.kind.displayName
        if interface.kind == other.kind, let speed = interface.linkSpeedMbps, speed > 0 {
            return "\(kind) \(NASInterfaceClassifier.linkSpeedLabel(mbps: speed))"
        }
        return kind
    }
}

extension NASSessionLocator {
    /// The local interfaces behind a session match: the BSD names smbutil
    /// reported, then the interface owning each local address netstat
    /// showed for the connection to the server's port 445.
    public static func interfaces(for match: NASSessionMatch?, in interfaces: [NASNetworkInterface]) -> [NASNetworkInterface] {
        guard let match else { return [] }
        var found: [NASNetworkInterface] = []
        for name in match.interfaceNames {
            if let interface = interfaces.first(where: { $0.bsdName == name }),
               !found.contains(where: { $0.bsdName == interface.bsdName }) {
                found.append(interface)
            }
        }
        for address in match.localAddresses {
            if let interface = interfaces.first(where: { $0.has(address: address) }),
               !found.contains(where: { $0.bsdName == interface.bsdName }) {
                found.append(interface)
            }
        }
        return found
    }

    /// From raw tool output to the session's local address and interface:
    /// `netstat -anvp tcp` and (optionally) `smbutil multichannel -m`
    /// text, the server's addresses, and the local interfaces. Nil match
    /// when the session's connection cannot be told apart.
    public static func resolveSession(
        netstatOutput: String,
        smbutilOutput: String?,
        serverAddresses: [String],
        interfaces: [NASNetworkInterface]
    ) -> (match: NASSessionMatch?, interfaces: [NASNetworkInterface]) {
        let session = smbutilOutput.flatMap(SMBMultichannelParser.parse)
        var servers = serverAddresses
        if servers.isEmpty { servers = session?.serverAddresses ?? [] }
        let match = locate(connections: NetstatParser.parse(netstatOutput), serverAddresses: servers, session: session)
        return (match, Self.interfaces(for: match, in: interfaces))
    }
}

/// What the app's jobs are doing, for the link switch.
public struct NASJobActivity: Sendable, Equatable {
    /// A file job holds the job gate (it may be mid-copy, mid-hash or
    /// mid-delete).
    public var jobRunning: Bool
    /// A card transfer is copying.
    public var transferRunning: Bool
    /// A storage speed test is measuring a volume.
    public var benchmarkRunning: Bool
    /// File jobs waiting for the gate.
    public var queuedJobs: Int

    public init(jobRunning: Bool = false, transferRunning: Bool = false, benchmarkRunning: Bool = false, queuedJobs: Int = 0) {
        self.jobRunning = jobRunning
        self.transferRunning = transferRunning
        self.benchmarkRunning = benchmarkRunning
        self.queuedJobs = queuedJobs
    }
}

/// When the share may be unmounted for a link switch. A running job is
/// never interrupted — not between two of its files either, since a job
/// re-reads and re-checks files as it goes. The safe points are: nothing
/// running, or the job queue between two jobs (the gate is free and the
/// next queued job has not started; the queue holds it for the switch).
public enum NASLinkSwitchGate {
    public enum Verdict: String, Sendable, Equatable {
        /// Nothing uses the NAS: switch now.
        case clear
        /// Between two queued jobs: switch now and hold the queue until done.
        case atJobBoundary
        /// Something is mid-work: wait.
        case wait
    }

    public static func verdict(_ activity: NASJobActivity) -> Verdict {
        if activity.jobRunning || activity.transferRunning || activity.benchmarkRunning { return .wait }
        return activity.queuedJobs > 0 ? .atJobBoundary : .clear
    }

    /// The longest the queue waits for a wanted switch that has not
    /// started, after which the queue goes on.
    public static let maximumQueueHold: TimeInterval = 90

    /// Whether the queue should keep its next job back. Always while a
    /// switch is running: a job must never start on a share that is being
    /// unmounted and mounted again. While a switch is only wanted, until
    /// `maximumHold` has passed since the hold began.
    public static func shouldHoldQueue(
        switchWanted: Bool,
        switchRunning: Bool,
        heldSince: Date?,
        now: Date,
        maximumHold: TimeInterval = maximumQueueHold
    ) -> Bool {
        if switchRunning { return true }
        guard switchWanted else { return false }
        if let heldSince, now.timeIntervalSince(heldSince) >= maximumHold { return false }
        return true
    }
}

/// A cheap fingerprint of the local interfaces — names, up state, and
/// addresses — that changes when a cable is plugged or pulled, DHCP hands
/// out an address, or Wi-Fi joins another network. Polled between path
/// monitor updates; it never runs a system tool.
public enum NASInterfaceSignature {
    public static func make(_ entries: [(name: String, isUp: Bool, addresses: [String])]) -> String {
        entries
            .filter { !$0.name.hasPrefix("lo") }
            .map { entry in
                let addresses = entry.addresses
                    .map(NASAddress.normalized)
                    .filter { !$0.hasPrefix("fe80:") }
                    .sorted()
                return "\(entry.name)\(entry.isUp ? "+" : "-")\(addresses.joined(separator: ","))"
            }
            .sorted()
            .joined(separator: ";")
    }
}
