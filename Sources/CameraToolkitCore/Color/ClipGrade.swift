import Foundation

/// The log encoding a clip was shot in.
public enum LogProfile: String, Codable, CaseIterable, Sendable {
    /// Sony S-Log3 with S-Gamut3.Cine primaries.
    case sLog3SGamut3Cine = "s-log3/s-gamut3-cine"
    /// Sony S-Log3 with S-Gamut3 primaries.
    case sLog3SGamut3 = "s-log3/s-gamut3"
    /// DJI D-Log M. DJI publishes no formula for it, so it has no built-in
    /// conversion: import DJI's own D-Log M LUT and set it as the default.
    case djiDLogM = "dji-d-log-m"

    public var displayName: String {
        switch self {
        case .sLog3SGamut3Cine: "S-Log3 · S-Gamut3.Cine"
        case .sLog3SGamut3: "S-Log3 · S-Gamut3"
        case .djiDLogM: "D-Log M"
        }
    }

    public var shortName: String {
        switch self {
        case .sLog3SGamut3Cine, .sLog3SGamut3: "S-Log3"
        case .djiDLogM: "D-Log M"
        }
    }

    /// Whether the app can convert this profile to Rec.709 by itself.
    public var hasBuiltInConversion: Bool {
        switch self {
        case .sLog3SGamut3Cine, .sLog3SGamut3: true
        case .djiDLogM: false
        }
    }

    /// Camera gamut, when the profile has a published one.
    public var primaries: RGBPrimaries? {
        switch self {
        case .sLog3SGamut3Cine: .sGamut3Cine
        case .sLog3SGamut3: .sGamut3
        case .djiDLogM: nil
        }
    }
}

/// What a grade's look is.
public enum GradeLook: Codable, Hashable, Sendable {
    /// No look — only the basic controls.
    case none
    /// The built-in Rec.709 conversion for the clip's log profile.
    case rec709
    /// An imported `.cube` LUT, by `LUTLibrary` id.
    case lut(String)

    private enum CodingKeys: String, CodingKey { case kind, id }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "rec709": self = .rec709
        case "lut": self = .lut(try values.decode(String.self, forKey: .id))
        default: self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: try values.encode("none", forKey: .kind)
        case .rec709: try values.encode("rec709", forKey: .kind)
        case .lut(let id):
            try values.encode("lut", forKey: .kind)
            try values.encode(id, forKey: .id)
        }
    }

    var token: String {
        switch self {
        case .none: "none"
        case .rec709: "709"
        case .lut(let id): "lut:\(id)"
        }
    }
}

/// How the user has labelled a clip's encoding, over what was detected.
public enum ClipProfileMark: Codable, Hashable, Sendable {
    /// Whatever the camera metadata says.
    case detected
    /// The user said it is this log profile (e.g. D-Log M, which DJI
    /// files do not reliably announce).
    case marked(LogProfile)
    /// The user said it is not log footage.
    case notLog

    private enum CodingKeys: String, CodingKey { case kind, profile }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "marked":
            if let profile = LogProfile(rawValue: try values.decode(String.self, forKey: .profile)) {
                self = .marked(profile)
            } else {
                self = .detected
            }
        case "notLog": self = .notLog
        default: self = .detected
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .detected: try values.encode("detected", forKey: .kind)
        case .marked(let profile):
            try values.encode("marked", forKey: .kind)
            try values.encode(profile.rawValue, forKey: .profile)
        case .notLog: try values.encode("notLog", forKey: .kind)
        }
    }

    /// The profile in effect, given what the metadata said.
    public func resolve(detected: LogProfile?) -> LogProfile? {
        switch self {
        case .detected: detected
        case .marked(let profile): profile
        case .notLog: nil
        }
    }
}

/// A clip's colour grade. Data only: it is applied while decoding,
/// playing and rendering copies — the original is never rewritten.
public struct ClipGrade: Codable, Hashable, Sendable {
    public var look: GradeLook
    /// How much of the look is mixed in, 0…1.
    public var intensity: Double
    /// Stops, −4…+4, applied in scene-linear light before the look.
    public var exposure: Double
    /// −100 (cooler) … +100 (warmer).
    public var temperature: Double
    /// −100 (greener) … +100 (more magenta).
    public var tint: Double
    /// −100 … +100, around mid grey after the look.
    public var contrast: Double
    /// −100 (black and white) … +100.
    public var saturation: Double
    public var profileMark: ClipProfileMark

    public init(
        look: GradeLook = .none,
        intensity: Double = 1,
        exposure: Double = 0,
        temperature: Double = 0,
        tint: Double = 0,
        contrast: Double = 0,
        saturation: Double = 0,
        profileMark: ClipProfileMark = .detected
    ) {
        self.look = look
        self.intensity = intensity
        self.exposure = exposure
        self.temperature = temperature
        self.tint = tint
        self.contrast = contrast
        self.saturation = saturation
        self.profileMark = profileMark
        clamp()
    }

    public static let rec709 = ClipGrade(look: .rec709)

    public static let ranges = (
        intensity: 0.0...1.0,
        exposure: -4.0...4.0,
        temperature: -100.0...100.0,
        tint: -100.0...100.0,
        contrast: -100.0...100.0,
        saturation: -100.0...100.0
    )

    public mutating func clamp() {
        func fix(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
            v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : fallback
        }
        intensity = fix(intensity, Self.ranges.intensity, 1)
        exposure = fix(exposure, Self.ranges.exposure, 0)
        temperature = fix(temperature, Self.ranges.temperature, 0)
        tint = fix(tint, Self.ranges.tint, 0)
        contrast = fix(contrast, Self.ranges.contrast, 0)
        saturation = fix(saturation, Self.ranges.saturation, 0)
    }

    /// True when only the look is set (the basic controls are at rest).
    public var hasNeutralControls: Bool {
        exposure == 0 && temperature == 0 && tint == 0 && contrast == 0 && saturation == 0
    }

    /// True when applying this grade leaves the picture as it is.
    public var isIdentity: Bool {
        (look == .none || intensity == 0) && hasNeutralControls
    }

    /// The same look and controls with a different profile label kept —
    /// what Paste Grade uses so a clip keeps its own encoding label.
    public func withProfileMark(_ mark: ClipProfileMark) -> ClipGrade {
        var copy = self
        copy.profileMark = mark
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case look, intensity, exposure, temperature, tint, contrast, saturation, profileMark
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        look = try values.decodeIfPresent(GradeLook.self, forKey: .look) ?? .none
        intensity = try values.decodeIfPresent(Double.self, forKey: .intensity) ?? 1
        exposure = try values.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try values.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        contrast = try values.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        profileMark = try values.decodeIfPresent(ClipProfileMark.self, forKey: .profileMark) ?? .detected
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(look, forKey: .look)
        try values.encode(intensity, forKey: .intensity)
        try values.encode(exposure, forKey: .exposure)
        try values.encode(temperature, forKey: .temperature)
        try values.encode(tint, forKey: .tint)
        try values.encode(contrast, forKey: .contrast)
        try values.encode(saturation, forKey: .saturation)
        if profileMark != .detected { try values.encode(profileMark, forKey: .profileMark) }
    }

    /// Stable JSON for the catalog row.
    public func catalogJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func fromCatalogJSON(_ text: String) -> ClipGrade? {
        try? JSONDecoder().decode(ClipGrade.self, from: Data(text.utf8))
    }
}

/// Everything that decides a graded picture: the grade, the profile it is
/// read as, and the signal range. Its `fingerprint` names a rendered
/// picture in caches and in a rendered copy's metadata, so any change to a
/// part of it gives a new name.
public struct GradeRecipe: Hashable, Sendable {
    public var grade: ClipGrade
    public var profile: LogProfile?
    public var range: VideoSignalRange

    public init(grade: ClipGrade, profile: LogProfile?, range: VideoSignalRange = .full) {
        self.grade = grade
        self.profile = profile
        self.range = range
    }

    /// Bump when the math in `GradePipeline` changes what a recipe looks
    /// like, so stale cached pictures and renders are not reused.
    public static let pipelineVersion = 1

    public var fingerprint: String {
        let g = grade
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        return [
            "v\(Self.pipelineVersion)",
            g.look.token,
            "i" + f(g.intensity), "e" + f(g.exposure), "t" + f(g.temperature), "m" + f(g.tint),
            "c" + f(g.contrast), "s" + f(g.saturation),
            "p" + (profile?.rawValue ?? "none"),
            "r" + range.rawValue,
        ].joined(separator: "|")
    }

    /// A short hash of the fingerprint for file names and cache keys.
    public var shortFingerprint: String {
        LayoutMigrationHash.sha256(fingerprint).prefix(16).lowercased()
    }
}

/// A default look per log profile: clips of that profile without a grade
/// of their own are shown, played and rendered with it.
public struct GradeDefaults: Codable, Equatable, Sendable {
    public var lookByProfile: [String: GradeLook]

    public init(lookByProfile: [String: GradeLook] = [:]) {
        self.lookByProfile = lookByProfile
    }

    public func look(for profile: LogProfile) -> GradeLook? {
        lookByProfile[profile.rawValue]
    }

    public mutating func setLook(_ look: GradeLook?, for profile: LogProfile) {
        lookByProfile[profile.rawValue] = look
    }

    public var isEmpty: Bool { lookByProfile.isEmpty }
}
