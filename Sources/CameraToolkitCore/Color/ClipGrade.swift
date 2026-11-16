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

    public var vendorName: String {
        switch self {
        case .sLog3SGamut3Cine, .sLog3SGamut3: "Sony"
        case .djiDLogM: "DJI"
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

/// Stage (b): how log footage becomes Rec.709. Chosen per profile in
/// Settings and, rarely, per clip.
public enum GradeConversion: Codable, Hashable, Sendable {
    /// The profile's default: an imported Sony (or DJI) conversion LUT set
    /// in Settings, else the built-in conversion.
    case auto
    /// The built-in conversion computed from Sony's published S-Log3 curve
    /// and S-Gamut3(.Cine) primaries.
    case builtIn
    /// An imported conversion LUT (log in → Rec.709 out), by id.
    case lut(String)
    /// Leave the footage as recorded (flat).
    case off

    private enum CodingKeys: String, CodingKey { case kind, id }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "builtIn": self = .builtIn
        case "lut": self = .lut(try values.decode(String.self, forKey: .id))
        case "off": self = .off
        default: self = .auto
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto: try values.encode("auto", forKey: .kind)
        case .builtIn: try values.encode("builtIn", forKey: .kind)
        case .off: try values.encode("off", forKey: .kind)
        case .lut(let id):
            try values.encode("lut", forKey: .kind)
            try values.encode(id, forKey: .id)
        }
    }
}

/// The conversion a picture is actually drawn with, after defaults and
/// availability are resolved — what the fingerprint names.
public enum ResolvedConversion: Hashable, Sendable {
    /// Not log footage, or conversion off or unavailable: drawn as recorded.
    case none
    case builtIn
    case lut(String)

    var token: String {
        switch self {
        case .none: "none"
        case .builtIn: "builtin"
        case .lut(let id): "lut:\(id)"
        }
    }

    public var converts: Bool { self != .none }
}

/// Stage (c): a creative look applied on top of the Rec.709 picture.
public enum GradeLook: Codable, Hashable, Sendable {
    /// No look: the converted picture as it is.
    case none
    /// One of the looks designed into the app (`BuiltInLook`).
    case builtIn(BuiltInLook)
    /// An imported look LUT (Rec.709 in → Rec.709 out), by id.
    case lut(String)

    private enum CodingKeys: String, CodingKey { case kind, id }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "builtIn":
            self = BuiltInLook(rawValue: try values.decode(String.self, forKey: .id)).map(GradeLook.builtIn) ?? .none
        case "lut": self = .lut(try values.decode(String.self, forKey: .id))
        // "rec709" is how the first builds said "converted, no look".
        default: self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: try values.encode("none", forKey: .kind)
        case .builtIn(let look):
            try values.encode("builtIn", forKey: .kind)
            try values.encode(look.rawValue, forKey: .id)
        case .lut(let id):
            try values.encode("lut", forKey: .kind)
            try values.encode(id, forKey: .id)
        }
    }

    var token: String {
        switch self {
        case .none: "none"
        case .builtIn(let look): "look:\(look.rawValue)"
        case .lut(let id): "lut:\(id)"
        }
    }

    /// The intensity a look starts at when it is chosen.
    public var defaultIntensity: Double {
        switch self {
        case .none: 1
        case .builtIn(let look): look.defaultIntensity
        case .lut: 0.8
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
    /// Stage (b): log → Rec.709. `.auto` follows the profile's default.
    public var conversion: GradeConversion
    /// Stage (c): the look on top of the Rec.709 picture.
    public var look: GradeLook
    /// How much of the look is mixed over the converted picture, 0…1.
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
        conversion: GradeConversion = .auto,
        look: GradeLook = .none,
        intensity: Double = 1,
        exposure: Double = 0,
        temperature: Double = 0,
        tint: Double = 0,
        contrast: Double = 0,
        saturation: Double = 0,
        profileMark: ClipProfileMark = .detected
    ) {
        self.conversion = conversion
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

    /// Converted (the profile's default conversion), no look.
    public static let converted = ClipGrade()

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

    /// True when the user has set nothing: default conversion, no look,
    /// sliders at rest. (A log clip is still converted.)
    public var isDefault: Bool {
        conversion == .auto && (look == .none || intensity == 0) && hasNeutralControls
    }

    /// The same look and controls with a different profile label kept —
    /// what Paste Grade uses so a clip keeps its own encoding label.
    public func withProfileMark(_ mark: ClipProfileMark) -> ClipGrade {
        var copy = self
        copy.profileMark = mark
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case conversion, look, intensity, exposure, temperature, tint, contrast, saturation, profileMark
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        conversion = try values.decodeIfPresent(GradeConversion.self, forKey: .conversion) ?? .auto
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
        if conversion != .auto { try values.encode(conversion, forKey: .conversion) }
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
/// read as, the conversion it is drawn with and the signal range. Its
/// `fingerprint` names a rendered picture in caches and in a rendered
/// copy's metadata, so any change to a part of it gives a new name.
public struct GradeRecipe: Hashable, Sendable {
    public var grade: ClipGrade
    public var profile: LogProfile?
    public var conversion: ResolvedConversion
    public var range: VideoSignalRange

    public init(grade: ClipGrade, profile: LogProfile?, conversion: ResolvedConversion? = nil, range: VideoSignalRange = .full) {
        self.grade = grade
        self.profile = profile
        // Without a resolver: log footage the app can convert gets the
        // built-in conversion unless the grade says otherwise.
        self.conversion = conversion ?? {
            guard let profile else { return .none }
            switch grade.conversion {
            case .off: return .none
            case .lut(let id): return .lut(id)
            case .auto, .builtIn: return profile.hasBuiltInConversion ? .builtIn : .none
            }
        }()
        self.range = range
    }

    /// Bump when the math in `GradePipeline` changes what a recipe looks
    /// like, so stale cached pictures and renders are not reused.
    public static let pipelineVersion = 2

    /// True when drawing it changes nothing.
    public var isIdentity: Bool {
        !conversion.converts && (grade.look == .none || grade.intensity == 0) && grade.hasNeutralControls
    }

    /// A look goes on a Rec.709 picture only: never on log footage that is
    /// not converted, so a look can never sit on top of a log image.
    public var lookApplies: Bool {
        grade.look != .none && grade.intensity > 0 && (profile == nil || conversion.converts)
    }

    public var fingerprint: String {
        let g = grade
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        return [
            "v\(Self.pipelineVersion)",
            "c:" + conversion.token,
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

/// Per log profile: the conversion (stage b) and the look on top (stage c)
/// a clip gets when it has no grade of its own.
public struct GradeDefaults: Codable, Equatable, Sendable {
    public var lookByProfile: [String: GradeLook]
    /// Missing means `.auto`.
    public var conversionByProfile: [String: GradeConversion]

    public init(lookByProfile: [String: GradeLook] = [:], conversionByProfile: [String: GradeConversion] = [:]) {
        self.lookByProfile = lookByProfile
        self.conversionByProfile = conversionByProfile
    }

    private enum CodingKeys: String, CodingKey { case lookByProfile, conversionByProfile }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A first-build "rec709" default decodes as no look: converting is
        // now the conversion stage's job.
        lookByProfile = (try values.decodeIfPresent([String: GradeLook].self, forKey: .lookByProfile) ?? [:]).filter { $0.value != .none }
        conversionByProfile = try values.decodeIfPresent([String: GradeConversion].self, forKey: .conversionByProfile) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if !lookByProfile.isEmpty { try values.encode(lookByProfile, forKey: .lookByProfile) }
        if !conversionByProfile.isEmpty { try values.encode(conversionByProfile, forKey: .conversionByProfile) }
    }

    public func look(for profile: LogProfile) -> GradeLook? {
        lookByProfile[profile.rawValue]
    }

    public mutating func setLook(_ look: GradeLook?, for profile: LogProfile) {
        lookByProfile[profile.rawValue] = look == GradeLook.none ? nil : look
    }

    public func conversion(for profile: LogProfile) -> GradeConversion {
        conversionByProfile[profile.rawValue] ?? .auto
    }

    public mutating func setConversion(_ conversion: GradeConversion, for profile: LogProfile) {
        conversionByProfile[profile.rawValue] = conversion == .auto ? nil : conversion
    }

    public var isEmpty: Bool { lookByProfile.isEmpty && conversionByProfile.isEmpty }
}

/// What an imported LUT expects, so a log-in LUT can never be stacked on
/// footage that is already converted.
public enum LUTRole: Codable, Hashable, Sendable {
    /// Log in → Rec.709 out (Sony's s709, DJI's D-Log M to Rec.709, or a
    /// creative "S-Log3 to film" LUT): replaces the conversion stage.
    case conversion(LogProfile)
    /// Rec.709 in → Rec.709 out: a look on top of the converted picture.
    case look

    private enum CodingKeys: String, CodingKey { case kind, profile }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if try values.decode(String.self, forKey: .kind) == "conversion",
           let profile = LogProfile(rawValue: try values.decode(String.self, forKey: .profile)) {
            self = .conversion(profile)
        } else {
            self = .look
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .look: try values.encode("look", forKey: .kind)
        case .conversion(let profile):
            try values.encode("conversion", forKey: .kind)
            try values.encode(profile.rawValue, forKey: .profile)
        }
    }

    /// A guess from the file and title names: Sony's and DJI's conversion
    /// LUTs name their log input (`SLog3SGamut3.CineTo…`, `…D-Log M to
    /// Rec.709…`). Anything else is taken for a look.
    public static func inferred(fromName name: String) -> LUTRole {
        let n = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        if n.contains("dlogm") || n.contains("dlog") { return .conversion(.djiDLogM) }
        let sony = n.contains("slog3") || n.contains("sl3") || n.contains("sgamut3")
        guard sony else { return .look }
        let cine = n.contains("cine") || n.contains("sg3c")
        if !cine, n.contains("sgamut3") { return .conversion(.sLog3SGamut3) }
        return .conversion(.sLog3SGamut3Cine)
    }

    public var displayName: String {
        switch self {
        case .look: "Look (Rec.709 in)"
        case .conversion(let profile): "Conversion from \(profile.displayName)"
        }
    }
}
