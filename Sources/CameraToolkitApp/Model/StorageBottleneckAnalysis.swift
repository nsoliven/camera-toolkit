import CameraToolkitCore
import Foundation

/// One hop in a transfer path: a device endpoint (a measured or typical rate)
/// or the transport that carries it (a negotiated USB link, Ethernet, Wi-Fi).
struct StoragePathLink: Identifiable, Equatable, Sendable {
    enum Cause: String, Equatable, Sendable {
        case media
        case link
        case network
        case wifi
    }

    var id: String { name }
    var name: String
    var megabytesPerSecond: Double
    var isMeasured: Bool
    /// Short provenance for the chip: "measured", "typical", "negotiated 10 Gb/s".
    var detail: String
    var cause: Cause
    /// The device whose link this element describes (for "X negotiated …").
    var owner: String?
}

struct StoragePathVerdict: Identifiable, Equatable, Sendable {
    var id: String { title }
    var title: String
    var links: [StoragePathLink]
    var bottleneckIndex: Int
    var headline: String
    var detail: String

    var bottleneck: StoragePathLink { links[bottleneckIndex] }
}

/// Turns per-target measurements and detected link facts into a plain-words
/// verdict for each path the app actually uses: card → Buffer, Buffer → NAS,
/// and NAS → Mac. Pure function over its inputs so it can be tested with
/// fabricated measurements.
enum StorageBottleneckAnalysis {
    @MainActor
    static func verdicts(
        targets: [StorageBenchmarkTarget],
        results: [String: StorageBenchmarkResult],
        contexts: [String: StorageLinkContext],
        transferQueue: TransferQueueSnapshot?
    ) -> [StoragePathVerdict] {
        let card = StorageBenchmarkTargetDiscovery.currentSourceTarget(
            in: targets,
            transferQueue: transferQueue
        ) ?? targets.first { $0.roleNames.contains("Camera Source") && $0.isAvailable }
        let buffer = targets.first { $0.roleNames.contains("Buffer") && $0.isAvailable }
        let library = targets.first { $0.roleNames.contains("Photo Library") && $0.isAvailable }

        var verdicts: [StoragePathVerdict] = []

        if let card, let buffer {
            var links = [deviceLink(card, kind: .read, results: results, contexts: contexts)]
            if let transport = transportLink(card, contexts: contexts) { links.append(transport) }
            links.append(deviceLink(buffer, kind: .write, results: results, contexts: contexts))
            if let transport = transportLink(buffer, contexts: contexts) { links.append(transport) }
            verdicts.append(makeVerdict(title: "Card → Buffer", links: links))
        }

        if let buffer, let library {
            var links = [deviceLink(buffer, kind: .read, results: results, contexts: contexts)]
            if let transport = transportLink(buffer, contexts: contexts) { links.append(transport) }
            links.append(transportLink(library, contexts: contexts) ?? genericNetworkLink())
            links.append(deviceLink(library, kind: .write, results: results, contexts: contexts))
            verdicts.append(makeVerdict(title: "Buffer → NAS", links: links, nasName: library.name))
        }

        if let library {
            var links = [deviceLink(library, kind: .read, results: results, contexts: contexts)]
            links.append(transportLink(library, contexts: contexts) ?? genericNetworkLink())
            links.append(StoragePathLink(
                name: "This Mac",
                megabytesPerSecond: TransferSpeedReference.midpoint(of: TransferSpeedReference.internalNVMe),
                isMeasured: false,
                detail: "typical internal SSD",
                cause: .media
            ))
            verdicts.append(makeVerdict(title: "NAS → Mac", links: links, nasName: library.name))
        }

        return verdicts
    }

    // MARK: Chain elements

    private enum Direction {
        case read
        case write
    }

    private static func deviceLink(
        _ target: StorageBenchmarkTarget,
        kind: Direction,
        results: [String: StorageBenchmarkResult],
        contexts: [String: StorageLinkContext]
    ) -> StoragePathLink {
        let measured = results[target.id].flatMap { result -> Double? in
            switch kind {
            case .read: result.read.bytesPerSecond
            case .write: result.write?.bytesPerSecond
            }
        }
        let label = kind == .read ? "read" : "write"
        if let measured {
            return StoragePathLink(
                name: "\(target.name) \(label)",
                megabytesPerSecond: measured / 1_000_000,
                isMeasured: true,
                detail: "measured",
                cause: .media
            )
        }
        let context = contexts[target.id]
        let range = kind == .read
            ? context?.mediaTypicalReadMBps ?? context?.typicalRead
            : context?.mediaTypicalWriteMBps ?? context?.mediaTypicalReadMBps ?? context?.typicalWrite
        let rate = range.map(TransferSpeedReference.midpoint) ?? fallbackTypical(for: target)
        return StoragePathLink(
            name: "\(target.name) \(label)",
            megabytesPerSecond: rate,
            isMeasured: false,
            detail: "typical",
            cause: .media
        )
    }

    private static func transportLink(
        _ target: StorageBenchmarkTarget,
        contexts: [String: StorageLinkContext]
    ) -> StoragePathLink? {
        guard let context = contexts[target.id] else { return nil }
        let rate = context.linkTypicalMBps.map(TransferSpeedReference.midpoint)
        switch context.medium {
        case .usb:
            guard let rate else { return nil }
            return StoragePathLink(
                name: "USB link",
                megabytesPerSecond: rate,
                isMeasured: false,
                detail: context.negotiatedBitsPerSecond.map {
                    "negotiated \(StorageLinkInspector.formattedBitsPerSecond($0))"
                } ?? "typical",
                cause: .link,
                owner: target.name
            )
        case .thunderbolt:
            guard let rate else { return nil }
            return StoragePathLink(name: "Thunderbolt link", megabytesPerSecond: rate, isMeasured: false, detail: "typical", cause: .link, owner: target.name)
        case .ethernet:
            guard let rate else { return nil }
            return StoragePathLink(
                name: "Network",
                megabytesPerSecond: rate,
                isMeasured: false,
                detail: context.negotiatedBitsPerSecond.map {
                    StorageLinkInspector.formattedBitsPerSecond($0)
                } ?? "typical",
                cause: .network,
                owner: target.name
            )
        case .wifi:
            guard let rate else { return nil }
            return StoragePathLink(
                name: "Wi-Fi",
                megabytesPerSecond: rate,
                isMeasured: false,
                detail: context.negotiatedBitsPerSecond.map {
                    "negotiated \(StorageLinkInspector.formattedBitsPerSecond($0))"
                } ?? "typical",
                cause: .wifi,
                owner: target.name
            )
        case .networkShare:
            return genericNetworkLink(owner: target.name)
        case .internalStorage, .unknown:
            return nil
        }
    }

    private static func genericNetworkLink(owner: String? = nil) -> StoragePathLink {
        StoragePathLink(
            name: "Network",
            megabytesPerSecond: TransferSpeedReference.midpoint(of: TransferSpeedReference.genericNetworkTypical),
            isMeasured: false,
            detail: "typical",
            cause: .network,
            owner: owner
        )
    }

    private static func fallbackTypical(for target: StorageBenchmarkTarget) -> Double {
        if target.roleNames.contains("Camera Source") {
            return TransferSpeedReference.midpoint(of: TransferSpeedReference.cameraCardTypical)
        }
        if target.roleNames.contains("Photo Library") {
            return TransferSpeedReference.midpoint(of: TransferSpeedReference.nasPoolWriteTypical)
        }
        return TransferSpeedReference.midpoint(of: TransferSpeedReference.usbSSDUndetected)
    }

    // MARK: Verdict text

    private static func makeVerdict(title: String, links: [StoragePathLink], nasName: String? = nil) -> StoragePathVerdict {
        let bottleneckIndex = links.indices.min { links[$0].megabytesPerSecond < links[$1].megabytesPerSecond } ?? 0
        let bottleneck = links[bottleneckIndex]
        let rate = Int(bottleneck.megabytesPerSecond.rounded())
        let nasElement = nasName.flatMap { name in
            links.first { $0.cause == .media && $0.name.hasPrefix(name) }
        }

        let headline: String
        let detail: String
        switch bottleneck.cause {
        case .wifi:
            headline = "\(title) is limited by Wi-Fi"
            let nasNote = nasElement.map {
                ", while \(stripDirection(from: $0.name)) can take ~\(Int($0.megabytesPerSecond.rounded())) MB/s"
            } ?? ""
            detail = "This Mac is on Wi-Fi at ~\(rate) MB/s\(nasNote). Plug in Ethernet and the archive gets faster."
        case .network:
            headline = "\(title) is limited by the network"
            let nasNote = nasElement.map {
                " \(stripDirection(from: $0.name)) can take ~\(Int($0.megabytesPerSecond.rounded())) MB/s, so the wire is the limit."
            } ?? ""
            let negotiated = bottleneck.detail == "typical" ? "is undetected" : "negotiates \(bottleneck.detail)"
            detail = "The link to the NAS \(negotiated), which tops out near \(rate) MB/s.\(nasNote) A faster Ethernet link would help."
        case .link:
            headline = "\(title) is limited by the USB link"
            let owner = bottleneck.owner ?? bottleneck.name
            let linkFact = bottleneck.detail == "typical"
                ? "link speed is undetected"
                : bottleneck.detail
            detail = "\(owner) \(linkFact) — the wire tops out near \(rate) MB/s. A faster port or cable would raise it."
        case .media:
            if let network = links.first(where: { $0.cause == .network || $0.cause == .wifi }),
               network.megabytesPerSecond > bottleneck.megabytesPerSecond * 1.3 {
                headline = "\(title) is limited by the NAS, not the wire"
                detail = "\(bottleneck.name) runs at ~\(rate) MB/s while the network can carry ~\(Int(network.megabytesPerSecond.rounded())) MB/s — the NAS disks or the SMB service are the limit, not the network."
            } else {
                headline = "\(title) is limited by \(bottleneck.name)"
                detail = bottleneck.isMeasured
                    ? "Measured ~\(rate) MB/s — the slowest link in this path."
                    : "Typical for this media is ~\(rate) MB/s; run its test to confirm."
            }
        }

        return StoragePathVerdict(
            title: title,
            links: links,
            bottleneckIndex: bottleneckIndex,
            headline: headline,
            detail: detail
        )
    }

    private static func stripDirection(from name: String) -> String {
        for suffix in [" read", " write"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}
