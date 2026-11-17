import Foundation

/// How hard the stabilizer smooths the camera's motion. Three steps, so a
/// person picks a feel rather than a number.
public enum StabilizationSmoothing: String, Codable, CaseIterable, Sendable, Identifiable {
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// Gyroflow's "Default" smoothing algorithm: its `smoothness` (0.001–1,
    /// Gyroflow's own default is 0.5) and `max_smoothness` (seconds).
    public var gyroflowSmoothness: Double {
        switch self {
        case .low: 0.25
        case .medium: 0.5
        case .high: 0.8
        }
    }

    public var gyroflowMaxSmoothness: Double {
        switch self {
        case .low, .medium: 1.0
        case .high: 1.5
        }
    }
}

/// A clip's stabilization: whether it is on and how smooth. Stored per clip
/// in the catalog (`StabilizationStore`), like a grade — data only, the
/// original is never changed.
public struct StabilizationSettings: Codable, Hashable, Sendable {
    public var smoothing: StabilizationSmoothing
    /// Keeps the horizon level. Off by default: it crops more and rolls
    /// the picture on purpose-tilted shots.
    public var horizonLock: Bool

    public init(smoothing: StabilizationSmoothing = .medium, horizonLock: Bool = false) {
        self.smoothing = smoothing
        self.horizonLock = horizonLock
    }

    private enum CodingKeys: String, CodingKey { case smoothing, horizonLock }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        smoothing = (try? values.decode(StabilizationSmoothing.self, forKey: .smoothing)) ?? .medium
        horizonLock = (try? values.decode(Bool.self, forKey: .horizonLock)) ?? false
    }

    /// Bump when the preset sent to Gyroflow changes what a setting looks
    /// like, so a copy made with the old preset is not taken for this one.
    public static let presetVersion = 1

    /// Names this stabilization in a rendered copy's tags; any change gives
    /// a new name.
    public var fingerprint: String {
        "stab\(Self.presetVersion)|\(smoothing.rawValue)|h\(horizonLock ? 1 : 0)"
    }

    public func catalogJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "{}"
    }

    public static func fromCatalogJSON(_ text: String) -> StabilizationSettings? {
        try? JSONDecoder().decode(StabilizationSettings.self, from: Data(text.utf8))
    }
}
