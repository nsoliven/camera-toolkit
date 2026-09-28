import Foundation

// Pure parsers for the read-only system tools the NAS connection check uses
// (`netstat`, `smbutil multichannel`, `route get`, `ifconfig`). None of them
// needs root. Everything here is string in, value out, so fixtures cover it.

/// One TCP socket from `netstat -anvp tcp`.
public struct NASTCPConnection: Sendable, Equatable {
    public var localAddress: String
    public var localPort: Int
    public var remoteAddress: String
    public var remotePort: Int
    public var state: String
    /// Bytes received / sent on the socket (`-v` only).
    public var rxBytes: Int64?
    public var txBytes: Int64?

    public init(localAddress: String, localPort: Int, remoteAddress: String, remotePort: Int, state: String, rxBytes: Int64? = nil, txBytes: Int64? = nil) {
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.state = state
        self.rxBytes = rxBytes
        self.txBytes = txBytes
    }

    public var isEstablished: Bool { state.uppercased() == "ESTABLISHED" }
}

public enum NetstatParser {
    /// Parses `netstat -anp tcp` or `netstat -anvp tcp`. Header lines,
    /// listening sockets (`*.*`), and anything unreadable are skipped.
    public static func parse(_ output: String) -> [NASTCPConnection] {
        var connections: [NASTCPConnection] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 6, tokens[0].lowercased().hasPrefix("tcp") else { continue }
            guard let local = splitEndpoint(tokens[3]), let remote = splitEndpoint(tokens[4]) else { continue }
            var connection = NASTCPConnection(
                localAddress: local.address,
                localPort: local.port,
                remoteAddress: remote.address,
                remotePort: remote.port,
                state: tokens[5]
            )
            if tokens.count >= 8, let rx = Int64(tokens[6]), let tx = Int64(tokens[7]) {
                connection.rxBytes = rx
                connection.txBytes = tx
            }
            connections.append(connection)
        }
        return connections
    }

    /// `192.0.2.10.445` → (`192.0.2.10`, 445); `fe80::1%en0.445` →
    /// (`fe80::1%en0`, 445). netstat puts the port after the last dot for
    /// both families. `*.*` and `*.445` have no usable address.
    public static func splitEndpoint(_ text: String) -> (address: String, port: Int)? {
        guard let dot = text.lastIndex(of: ".") else { return nil }
        let address = String(text[..<dot])
        guard let port = Int(text[text.index(after: dot)...]), !address.isEmpty, address != "*" else { return nil }
        return (address, port)
    }
}

/// The SMB session behind one mount point, from `smbutil multichannel -m`.
public struct NASSMBSessionStats: Sendable, Equatable {
    public var totalRxBytes: Int64?
    public var totalTxBytes: Int64?
    public var multichannel: Bool
    /// The server address the session's channels connect to.
    public var serverAddresses: [String]
    /// Client interfaces the channels use — BSD names, only when
    /// multichannel reports them (it prints `N/A` otherwise).
    public var clientInterfaces: [String]
    /// "Setup Time" and "Reconnect Count": together they name one session,
    /// so a session that reconnected (maybe over another link) is new.
    public var setupTime: String?
    public var reconnectCount: Int?

    public init(
        totalRxBytes: Int64? = nil,
        totalTxBytes: Int64? = nil,
        multichannel: Bool = false,
        serverAddresses: [String] = [],
        clientInterfaces: [String] = [],
        setupTime: String? = nil,
        reconnectCount: Int? = nil
    ) {
        self.totalRxBytes = totalRxBytes
        self.totalTxBytes = totalTxBytes
        self.multichannel = multichannel
        self.serverAddresses = serverAddresses
        self.clientInterfaces = clientInterfaces
        self.setupTime = setupTime
        self.reconnectCount = reconnectCount
    }

    public var sessionIdentity: String? {
        guard setupTime != nil || reconnectCount != nil else { return nil }
        return "\(setupTime ?? "?")#\(reconnectCount.map(String.init) ?? "?")"
    }
}

public enum SMBMultichannelParser {
    public static func parse(_ output: String) -> NASSMBSessionStats? {
        var stats = NASSMBSessionStats()
        var sawSession = false
        var inTable = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Session:") {
                sawSession = true
                continue
            }
            if line.hasPrefix("Info:") {
                // "Info: Setup Time: <date>, Multichannel ON: no, Reconnect Count: 0"
                for field in line.dropFirst("Info:".count).split(separator: ",") {
                    let parts = field.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2 else { continue }
                    switch parts[0].lowercased() {
                    case "setup time": stats.setupTime = parts[1]
                    case "multichannel on": stats.multichannel = parts[1].lowercased().hasPrefix("yes")
                    case "reconnect count": stats.reconnectCount = Int(parts[1])
                    default: break
                    }
                }
                continue
            }
            if line.hasPrefix("Total RX Bytes:") {
                stats.totalRxBytes = leadingInteger(after: "Total RX Bytes:", in: line)
                continue
            }
            if line.hasPrefix("Total TX Bytes:") {
                stats.totalTxBytes = leadingInteger(after: "Total TX Bytes:", in: line)
                continue
            }
            if line.hasPrefix("===") {
                inTable = true
                continue
            }
            guard inTable, !line.isEmpty else { continue }
            // Drop the bracketed state ("[session active   ]"), which has spaces.
            var row = line
            if let open = row.firstIndex(of: "["), let close = row[open...].firstIndex(of: "]") {
                row.replaceSubrange(open...close, with: " ")
            }
            let tokens = row.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 3 else { continue }
            if let client = bsdName(in: tokens[2]), !stats.clientInterfaces.contains(client) {
                stats.clientInterfaces.append(client)
            }
            if let portIndex = tokens.lastIndex(of: "445"), portIndex > 0 {
                let server = tokens[portIndex - 1]
                if looksLikeAddress(server), !stats.serverAddresses.contains(server) {
                    stats.serverAddresses.append(server)
                }
            }
        }
        return sawSession ? stats : nil
    }

    private static func leadingInteger(after prefix: String, in line: String) -> Int64? {
        let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return Int64(rest.prefix { $0.isNumber })
    }

    /// `en7`, `en7(1Gb)`, `en0:` → the BSD name; `N/A` → nil.
    static func bsdName(in token: String) -> String? {
        let letters = token.prefix { $0.isLetter }
        guard !letters.isEmpty, letters.allSatisfy({ $0.isLowercase }) else { return nil }
        let digits = token.dropFirst(letters.count).prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return String(letters) + String(digits)
    }

    static func looksLikeAddress(_ token: String) -> Bool {
        token.contains(".") && token.allSatisfy { $0.isNumber || $0 == "." } || token.contains(":")
    }
}

public enum RouteGetParser {
    /// The `interface:` line of `route -n get [-ifscope <if>] <address>`.
    public static func interface(in output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("interface:") else { continue }
            let value = line.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

public enum IfconfigMediaParser {
    /// The negotiated speed in Mb/s from `ifconfig <if>`'s `media:` line —
    /// `autoselect (1000baseT <full-duplex>)` → 1000, `10GbaseT` → 10000,
    /// `2500Base-T` → 2500. Nil when nothing is negotiated.
    public static func linkSpeedMbps(in output: String) -> Int? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("media:") else { continue }
            return speed(inMedia: String(line.dropFirst("media:".count)))
        }
        return nil
    }

    /// Only the active (parenthesized) media when there is one; otherwise
    /// the fixed media named on the line.
    static func speed(inMedia media: String) -> Int? {
        var text = media
        if let open = media.firstIndex(of: "("), let close = media[open...].firstIndex(of: ")") {
            text = String(media[media.index(after: open)..<close])
        }
        let lower = text.lowercased()
        guard let baseRange = lower.range(of: "base") else { return nil }
        let head = lower[..<baseRange.lowerBound]
        var digits = ""
        var multiplier = 1.0
        var index = head.endIndex
        if index > head.startIndex, head[head.index(before: index)] == "g" {
            multiplier = 1000
            index = head.index(before: index)
        }
        while index > head.startIndex {
            let previous = head.index(before: index)
            let character = head[previous]
            guard character.isNumber || character == "." else { break }
            digits.insert(character, at: digits.startIndex)
            index = previous
        }
        guard let value = Double(digits), value > 0 else { return nil }
        return Int((value * multiplier).rounded())
    }
}

/// `f_mntfromname` of an SMB mount: `//user@host/share` (user optional).
public struct NASMountSource: Sendable, Equatable {
    public var host: String
    public var share: String

    public init(host: String, share: String) {
        self.host = host
        self.share = share
    }

    public static func parse(_ mountedFrom: String) -> NASMountSource? {
        guard mountedFrom.hasPrefix("//") else { return nil }
        let rest = mountedFrom.dropFirst(2)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        var authority = String(rest[..<slash])
        if let at = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: at)...])
        }
        // Strip a port (`host:445`) but keep a bracketed IPv6 literal.
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            authority = String(authority[authority.index(after: authority.startIndex)..<close])
        } else if let colon = authority.firstIndex(of: ":"), authority.filter({ $0 == ":" }).count == 1 {
            authority = String(authority[..<colon])
        }
        let share = String(rest[rest.index(after: slash)...])
        guard !authority.isEmpty else { return nil }
        return NASMountSource(
            host: authority.removingPercentEncoding ?? authority,
            share: share.removingPercentEncoding ?? share
        )
    }

    /// True when this mount came from the server and share the SMB URL names.
    public func matches(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false) else { return false }
        let urlShare = url.path(percentEncoded: false).split(separator: "/").first.map(String.init) ?? ""
        return host.caseInsensitiveCompare(self.host) == .orderedSame
            && urlShare.caseInsensitiveCompare(share.split(separator: "/").first.map(String.init) ?? share) == .orderedSame
    }
}
