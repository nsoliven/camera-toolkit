import Foundation

/// Why a check ran — logged with the decision; the decision itself does
/// not depend on it except through `userRequested`.
public enum NASGuardTrigger: String, Sendable, Equatable {
    case launch
    case networkChange
    case mounted
    case jobStart
    case userRequested
}

/// Why the guard shows the banner instead of reconnecting by itself.
public enum NASGuardBannerReason: String, Sendable, Equatable {
    /// A job is using the NAS, or the app has NAS files open.
    case nasInUse
    /// Two reconnects in a row did not move the session to a wired link.
    case gaveUp
    /// A reconnect ran moments ago; the next automatic one waits.
    case rateLimited
    /// "Connect to the NAS automatically" is off.
    case automaticOff
    /// No SMB address is configured, so an unmounted share could not be
    /// mounted again.
    case noShareAddress
}

public enum NASGuardDecision: Sendable, Equatable {
    /// Nothing to fix (wired, unknown, or Wi-Fi is the only way there).
    case nothing
    /// Unmount and remount now.
    case reconnect
    /// Show "NAS is connected over Wi-Fi (slow). Reconnect over Ethernet".
    case banner(NASGuardBannerReason)
}

/// Bounds automatic reconnects: at least `minimumInterval` apart, and none
/// after `maximumFailures` consecutive failures until one succeeds or the
/// user asks. A user request skips the interval and clears the give-up.
public struct NASReconnectRateLimiter: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case allowed
        case tooSoon(until: Date)
        case gaveUp
    }

    public var minimumInterval: TimeInterval
    public var maximumFailures: Int
    public private(set) var consecutiveFailures = 0
    public private(set) var lastAttemptAt: Date?

    public init(minimumInterval: TimeInterval = 120, maximumFailures: Int = 2) {
        self.minimumInterval = minimumInterval
        self.maximumFailures = maximumFailures
    }

    public func verdict(now: Date, userRequested: Bool) -> Verdict {
        if userRequested { return .allowed }
        if consecutiveFailures >= maximumFailures { return .gaveUp }
        if let last = lastAttemptAt, now.timeIntervalSince(last) < minimumInterval {
            return .tooSoon(until: last.addingTimeInterval(minimumInterval))
        }
        return .allowed
    }

    public mutating func recordAttempt(at date: Date, userRequested: Bool) {
        if userRequested { consecutiveFailures = 0 }
        lastAttemptAt = date
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    public mutating func recordFailure() {
        consecutiveFailures += 1
    }
}

public enum NASWiFiGuard {
    public struct Input: Sendable, Equatable {
        /// The session's link, nil when not mounted or not pinned down.
        public var sessionKind: NASInterfaceKind?
        public var hasWiredRoute: Bool
        /// A NAS job is running or the app has NAS files open.
        public var nasInUse: Bool
        public var automaticEnabled: Bool
        public var hasShareAddress: Bool
        public var userRequested: Bool
        public var limiter: NASReconnectRateLimiter.Verdict

        public init(
            sessionKind: NASInterfaceKind?,
            hasWiredRoute: Bool,
            nasInUse: Bool,
            automaticEnabled: Bool,
            hasShareAddress: Bool,
            userRequested: Bool,
            limiter: NASReconnectRateLimiter.Verdict
        ) {
            self.sessionKind = sessionKind
            self.hasWiredRoute = hasWiredRoute
            self.nasInUse = nasInUse
            self.automaticEnabled = automaticEnabled
            self.hasShareAddress = hasShareAddress
            self.userRequested = userRequested
            self.limiter = limiter
        }
    }

    /// The whole policy, as a table:
    ///
    /// | session             | wired route | → |
    /// |---------------------|-------------|---|
    /// | wired / other / nil | any         | nothing |
    /// | Wi-Fi               | no          | nothing (Wi-Fi is the only way) |
    /// | Wi-Fi               | yes         | the first match below |
    ///
    /// 1. no SMB address → banner(noShareAddress) — could not remount
    /// 2. NAS in use → banner(nasInUse) — even when the user asked; the
    ///    banner's button waits for the jobs, then asks again
    /// 3. user asked → reconnect
    /// 4. automatic off → banner(automaticOff)
    /// 5. limiter gave up → banner(gaveUp)
    /// 6. limiter too soon → banner(rateLimited)
    /// 7. otherwise → reconnect
    public static func decide(_ input: Input) -> NASGuardDecision {
        guard input.sessionKind == .wifi, input.hasWiredRoute else { return .nothing }
        guard input.hasShareAddress else { return .banner(.noShareAddress) }
        if input.nasInUse { return .banner(.nasInUse) }
        if input.userRequested { return .reconnect }
        guard input.automaticEnabled else { return .banner(.automaticOff) }
        switch input.limiter {
        case .gaveUp: return .banner(.gaveUp)
        case .tooSoon: return .banner(.rateLimited)
        case .allowed: return .reconnect
        }
    }
}

/// How a mount attempt ended, from NetFS's status code.
public enum NASMountOutcome: Sendable, Equatable {
    case mounted
    case alreadyMounted
    /// The server did not answer — off the home network, NAS asleep.
    case unreachable
    case cancelled
    /// Anything else, above all no saved credential: Finder should ask.
    case needsUserInteraction(code: Int32)

    public static func classify(status: Int32) -> NASMountOutcome {
        switch status {
        case 0: return .mounted
        case EEXIST: return .alreadyMounted
        case ENETUNREACH, EHOSTUNREACH, EHOSTDOWN, ETIMEDOUT, ECONNREFUSED, ENETDOWN, ECONNRESET:
            return .unreachable
        case ECANCELED, -128: // userCanceledErr
            return .cancelled
        default:
            return .needsUserInteraction(code: status)
        }
    }
}
