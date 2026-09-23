import Foundation

/// One row in the published speed guide — a link or media class, what the
/// label means, and the realistic large-file range.
struct SpeedReferenceRow: Identifiable, Equatable, Sendable {
    var id: String { title }
    var title: String
    var detail: String
    var result: String
}

/// Published ceilings and typical large-file ranges, shared by the Transfer
/// Speed Guide and the Storage Speed Tests window so both quote the same
/// numbers. Typical ranges are approximations for big sequential transfers.
enum TransferSpeedReference {
    static let connectionRows = [
        SpeedReferenceRow(title: "USB 2.0", detail: "480 Mb/s · 60 MB/s wire ceiling", result: "30–45 MB/s typical"),
        SpeedReferenceRow(title: "USB 3.2 Gen 1", detail: "5 Gb/s · formerly USB 3.0", result: "350–500 MB/s"),
        SpeedReferenceRow(title: "USB 3.2 Gen 2", detail: "10 Gb/s · USB NVMe enclosure", result: "700–1,050 MB/s"),
        SpeedReferenceRow(title: "USB 3.2 Gen 2x2", detail: "20 Gb/s · host must support 2x2", result: "1,500–2,100 MB/s"),
        SpeedReferenceRow(title: "Thunderbolt 3 / 4", detail: "40 Gb/s · NVMe enclosure", result: "2,000–3,200 MB/s")
    ]

    static let mediaRows = [
        SpeedReferenceRow(title: "DJI Osmo 360 internal", detail: "USB 3.1 direct to Mac", result: "up to 600 MB/s"),
        SpeedReferenceRow(title: "UHS-I SD / microSD", detail: "standard bus ceiling", result: "up to 104 MB/s"),
        SpeedReferenceRow(title: "UHS-II SD", detail: "extra contact row required", result: "up to 312 MB/s"),
        SpeedReferenceRow(title: "Samsung EVO Plus (light blue)", detail: "U3 · A2 · V30 · compatible reader", result: "up to 160 MB/s read"),
        SpeedReferenceRow(title: "Samsung PRO Plus", detail: "U3 · A2 · V30 · compatible reader", result: "up to 180 / 130 MB/s")
    ]

    /// Realistic sequential range for a negotiated USB link rate.
    static func usbTypical(bitsPerSecond: Int64) -> ClosedRange<Double> {
        switch bitsPerSecond {
        case ..<600_000_000: 30...45          // USB 2.0, 480 Mb/s
        case ..<7_500_000_000: 350...500      // 5 Gb/s, USB 3.2 Gen 1
        case ..<15_000_000_000: 700...1_050   // 10 Gb/s, USB 3.2 Gen 2
        case ..<30_000_000_000: 1_500...2_100 // 20 Gb/s, USB 3.2 Gen 2x2
        default: 2_000...3_200                // 40 Gb/s, USB4 / Thunderbolt
        }
    }

    /// Practical SMB ceiling per negotiated Ethernet rate (Mb/s).
    static func smbTypical(megabitsPerSecond: Double) -> ClosedRange<Double> {
        switch megabitsPerSecond {
        case ..<150: 40...95        // 100 MbE and partial links
        case ..<1_500: 95...115     // 1 GbE tops out near 110 MB/s
        case ..<3_000: 230...290    // 2.5 GbE near 280 MB/s
        case ..<7_000: 400...560    // 5 GbE
        default: 800...1_150        // 10 GbE — the NAS pool becomes the limit
        }
    }

    /// Wi-Fi goodput is a fraction of the negotiated rate and varies with
    /// signal; use roughly half of the Tx rate as the working figure.
    static func wifiTypical(megabitsPerSecond: Double) -> ClosedRange<Double> {
        let mid = max(megabitsPerSecond / 8 * 0.55, 4)
        return (mid * 0.6)...(mid * 1.2)
    }

    static let internalNVMe: ClosedRange<Double> = 1_500...3_500
    static let sataSSD: ClosedRange<Double> = 400...550
    static let thunderboltTypical: ClosedRange<Double> = 2_000...3_200
    /// Removable camera media spans UHS-I (~90 MB/s) to UHS-II (~300 MB/s).
    static let cameraCardTypical: ClosedRange<Double> = 80...300
    static let osmoInternalTypical: ClosedRange<Double> = 300...600
    /// External solid-state storage where the bus was not identified.
    static let usbSSDUndetected: ClosedRange<Double> = 100...1_000
    /// A mirrored spinning-disk pool writing sequentially.
    static let nasPoolWriteTypical: ClosedRange<Double> = 150...250
    static let nasPoolReadTypical: ClosedRange<Double> = 150...300
    /// A network share whose route could not be measured.
    static let genericNetworkTypical: ClosedRange<Double> = 50...280

    static func midpoint(of range: ClosedRange<Double>) -> Double {
        (range.lowerBound + range.upperBound) / 2
    }

    static func formattedRange(_ range: ClosedRange<Double>) -> String {
        let low = Int(range.lowerBound.rounded())
        let high = Int(range.upperBound.rounded())
        return "\(low)–\(high) MB/s"
    }
}
