import Foundation

/// Why a check ran — logged with the decision; the decision itself does
/// not depend on it except through `userRequested`.
public enum NASGuardTrigger: String, Sendable, Equatable {
    case launch
    case networkChange
    case mounted
    case jobStart
    /// No job uses the NAS any more, or the job queue is between jobs.
    case jobBoundary
    case userRequested
}

/// Why the guard shows the banner instead of reconnecting by itself.
public enum NASGuardBannerReason: String, Sendable, Equatable {
    /// A job is using the NAS, or the app has NAS files open.
    case nasInUse
    /// Two reconnects in a row did not move the session to the faster link.
    case gaveUp
    /// A reconnect ran moments ago; the next automatic one waits.
    case rateLimited
    /// "Switch the NAS share to the faster link automatically" is off.
    case automaticOff
    /// No SMB address is configured, so an unmounted share could not be
    /// mounted again.
    case noShareAddress
    /// macOS refused the (normal, never forced) unmount: Finder, Time
    /// Machine or another app has files open on the share. It stays where
    /// it is until they let go.
    case shareBusyElsewhere
}

public enum NASGuardDecision: Sendable, Equatable {
    /// Nothing to fix (wired, unknown, or Wi-Fi is the only way there).
    case nothing
    /// Unmount and remount now.
    case reconnect
    /// Show "Ethernet available · share still on Wi-Fi" with its reason.
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

/// Should the share be reconnected now to move its SMB session onto the
/// faster link the route to the NAS already uses? The whole decision, with
/// every input passed in.
public enum NASLinkSwitchPolicy {
    public struct Input: Sendable, Equatable {
        /// The route to the NAS against the session's link.
        public var link: NASLinkAssessment.State
        /// A NAS job is running (mid-file) — never interrupted.
        public var nasInUse: Bool
        /// "Switch the NAS share to the faster link automatically".
        public var automaticEnabled: Bool
        public var hasShareAddress: Bool
        public var userRequested: Bool
        public var limiter: NASReconnectRateLimiter.Verdict

        public init(
            link: NASLinkAssessment.State,
            nasInUse: Bool,
            automaticEnabled: Bool,
            hasShareAddress: Bool,
            userRequested: Bool,
            limiter: NASReconnectRateLimiter.Verdict
        ) {
            self.link = link
            self.nasInUse = nasInUse
            self.automaticEnabled = automaticEnabled
            self.hasShareAddress = hasShareAddress
            self.userRequested = userRequested
            self.limiter = limiter
        }
    }

    /// The whole policy, as a table:
    ///
    /// | route vs session            | → |
    /// |-----------------------------|---|
    /// | matched / unknown           | nothing |
    /// | route moved to slower link  | nothing (the SMB client follows) |
    /// | route on a faster link      | the first match below |
    ///
    /// 1. no SMB address → banner(noShareAddress) — could not remount
    /// 2. NAS in use → banner(nasInUse) — even when the user asked; the
    ///    switch waits for the jobs (or the queue's next job boundary)
    /// 3. user asked → reconnect
    /// 4. automatic off → banner(automaticOff)
    /// 5. limiter gave up → banner(gaveUp)
    /// 6. limiter too soon → banner(rateLimited)
    /// 7. otherwise → reconnect
    public static func decide(_ input: Input) -> NASGuardDecision {
        guard input.link == .fasterLinkAvailable else { return .nothing }
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

    /// True when the only thing holding the switch back is a running job:
    /// the app then waits for the job to end (or for the queue's next job
    /// boundary) and switches by itself.
    public static func waitsOnlyForJobs(_ input: Input) -> Bool {
        guard input.nasInUse else { return false }
        var idle = input
        idle.nasInUse = false
        return decide(idle) == .reconnect
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
