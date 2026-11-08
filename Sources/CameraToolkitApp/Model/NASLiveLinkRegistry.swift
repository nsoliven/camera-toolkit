import CameraToolkitCore
import Foundation

extension Notification.Name {
    /// The NAS share's route or SMB session moved to another link.
    static let cameraToolkitNASLinkChanged = Notification.Name("CameraToolkitNASLinkChanged")
}

/// The NAS connection's latest view of the share's links, for the code
/// that describes a network volume's link off the main actor (the storage
/// link inspector, the bottleneck analysis, a job's link ceiling). It
/// answers with the link the SMB session really uses — not the one the
/// route picks, which moves the moment a cable is plugged in while the
/// session stays where it was.
final class NASLiveLinkRegistry: @unchecked Sendable {
    static let shared = NASLiveLinkRegistry()

    struct Entry: Equatable, Sendable {
        var source: NASMountSource
        var mountPoint: String
        var assessment: NASLinkAssessment
        var multichannel: Bool
    }

    private let lock = NSLock()
    private var entry: Entry?
    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    /// Records the latest snapshot; posts `cameraToolkitNASLinkChanged`
    /// when the route's or the session's link changed.
    func update(_ snapshot: NASConnectionSnapshot?) {
        var next: Entry?
        if let snapshot, case .mounted(let source) = snapshot.mount {
            next = Entry(source: source, mountPoint: snapshot.mountPoint, assessment: snapshot.linkAssessment, multichannel: snapshot.multichannel)
        }
        let changed: Bool = lock.withLock {
            defer { entry = next }
            return Self.linkKey(entry) != Self.linkKey(next)
        }
        if changed {
            notificationCenter.post(name: .cameraToolkitNASLinkChanged, object: nil)
        }
    }

    /// The entry for a mount source (`//user@host/share`), when it is the
    /// share the NAS connection watches.
    func entry(forMountSource mountSource: String) -> Entry? {
        guard let source = NASMountSource.parse(mountSource) else { return nil }
        return lock.withLock {
            guard let entry,
                  entry.source.host.caseInsensitiveCompare(source.host) == .orderedSame,
                  entry.source.share.caseInsensitiveCompare(source.share) == .orderedSame else { return nil }
            return entry
        }
    }

    private static func linkKey(_ entry: Entry?) -> String {
        guard let entry else { return "" }
        let route = entry.assessment.route.map { "\($0.bsdName):\($0.linkSpeedMbps ?? 0)" } ?? "-"
        let session = entry.assessment.sessionInterfaces.map(\.bsdName).joined(separator: ",")
        return "\(entry.mountPoint)|\(route)|\(session)|\(entry.assessment.state.rawValue)"
    }
}
