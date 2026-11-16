import Foundation

/// Creative looks designed into the app. Each takes a Rec.709 picture and
/// returns one (stage c, on top of the conversion), works per pixel, and
/// leaves skin hues near where they were: hue shifts are weighted away
/// from the orange skin band, and saturation pushes are vibrance (more on
/// muted colours than on already-strong ones).
public enum BuiltInLook: String, CaseIterable, Codable, Sendable {
    case softFilm = "soft-film"
    case brightAiry = "bright-airy"
    case tealOrange = "teal-orange"
    case moodyMatte = "moody-matte"
    case richVivid = "rich-vivid"
    case blackWhite = "black-white"

    public var displayName: String {
        switch self {
        case .softFilm: "Soft Film"
        case .brightAiry: "Bright & Airy"
        case .tealOrange: "Teal & Orange"
        case .moodyMatte: "Moody Matte"
        case .richVivid: "Rich & Vivid"
        case .blackWhite: "Black & White"
        }
    }

    public var defaultIntensity: Double {
        switch self {
        case .blackWhite: 1
        case .richVivid, .tealOrange: 0.7
        default: 0.75
        }
    }

    /// Rec.709-encoded in, Rec.709-encoded out, 0…1.
    public func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        var v = rgb
        switch self {
        case .softFilm:
            // Lifted, soft blacks; a gentle S; warm mids and highlights;
            // slightly restrained colour; highlights rolled, never clipped.
            v = LookMath.contrast(v, amount: 0.14, pivot: 0.42)
            v = LookMath.liftGain(v, lift: 0.04, gain: 0.955)
            v = LookMath.warm(v, amount: 0.045, protectSkin: false)
            v = LookMath.splitTone(v, shadows: SIMD3(-0.010, 0.010, 0.018), highlights: SIMD3(0.024, 0.010, -0.026))
            v = LookMath.vibrance(v, amount: -0.14)
        case .brightAiry:
            // Open mids, soft contrast, clean slightly cool whites, colours
            // light rather than strong.
            v = LookMath.gamma(v, 0.80)
            v = LookMath.contrast(v, amount: -0.14, pivot: 0.5)
            v = LookMath.liftGain(v, lift: 0.03, gain: 1.0)
            v = LookMath.splitTone(v, shadows: SIMD3(0, 0.006, 0.014), highlights: SIMD3(0.004, 0.002, 0.004))
            v = LookMath.vibrance(v, amount: -0.10)
        case .tealOrange:
            // Shadows and blues lean teal, warm tones lean orange; skin kept
            // by weighting the push away from the skin band.
            v = LookMath.contrast(v, amount: 0.12, pivot: 0.42)
            v = LookMath.splitTone(v, shadows: SIMD3(-0.028, 0.006, 0.026), highlights: SIMD3(0.030, 0.010, -0.026))
            v = LookMath.tealOrangeHues(v, amount: 0.55)
            v = LookMath.vibrance(v, amount: 0.12)
        case .moodyMatte:
            // Darker mids, matte (raised, slightly cool) blacks, capped
            // highlights, muted colour.
            v = LookMath.gamma(v, 1.12)
            v = LookMath.liftGain(v, lift: 0.07, gain: 0.92)
            v = LookMath.splitTone(v, shadows: SIMD3(-0.010, 0.006, 0.016), highlights: SIMD3(0.010, 0.004, -0.008))
            v = LookMath.vibrance(v, amount: -0.32)
        case .richVivid:
            // Deeper contrast and colour, by vibrance so skin and already
            // strong colours do not run.
            v = LookMath.contrast(v, amount: 0.20, pivot: 0.42)
            v = LookMath.vibrance(v, amount: 0.50)
            v = LookMath.liftGain(v, lift: 0.0, gain: 0.985)
        case .blackWhite:
            // A slightly red-filtered mono (kind to skin, darker skies),
            // with a classic S and a faint warm tone.
            let y = 0.34 * v.x + 0.56 * v.y + 0.10 * v.z
            v = SIMD3(repeating: y)
            v = LookMath.contrast(v, amount: 0.18, pivot: 0.42)
            v = LookMath.liftGain(v, lift: 0.02, gain: 0.98)
            v = LookMath.splitTone(v, shadows: SIMD3(0.002, 0.0, -0.004), highlights: SIMD3(0.008, 0.003, -0.008))
        }
        return SIMD3(min(max(v.x, 0), 1), min(max(v.y, 0), 1), min(max(v.z, 0), 1))
    }
}

/// Small colour operations on Rec.709-encoded values.
enum LookMath {
    static func luma(_ v: SIMD3<Double>) -> Double { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }

    /// S-curve keeping 0 and 1, slope at the pivot `2^(1.2·amount)`.
    static func contrast(_ v: SIMD3<Double>, amount: Double, pivot: Double) -> SIMD3<Double> {
        let k = pow(2.0, 1.2 * amount)
        var out = SIMD3<Double>()
        for c in 0..<3 {
            let x = min(max(v[c], 0), 1)
            out[c] = x < pivot ? pivot * pow(x / pivot, k) : 1 - (1 - pivot) * pow((1 - x) / (1 - pivot), k)
        }
        return out
    }

    static func liftGain(_ v: SIMD3<Double>, lift: Double, gain: Double) -> SIMD3<Double> {
        SIMD3(repeating: lift) + v * (gain - lift)
    }

    static func gamma(_ v: SIMD3<Double>, _ g: Double) -> SIMD3<Double> {
        SIMD3(pow(max(v.x, 0), g), pow(max(v.y, 0), g), pow(max(v.z, 0), g))
    }

    /// Adds `shadows` weighted toward dark values and `highlights` toward
    /// bright ones.
    static func splitTone(_ v: SIMD3<Double>, shadows: SIMD3<Double>, highlights: SIMD3<Double>) -> SIMD3<Double> {
        let y = min(max(luma(v), 0), 1)
        let shadowWeight = pow(1 - y, 2)
        let highlightWeight = y * y
        return v + shadows * shadowWeight + highlights * highlightWeight
    }

    /// Warms by trading blue for red, more in the brighter tones.
    static func warm(_ v: SIMD3<Double>, amount: Double, protectSkin: Bool) -> SIMD3<Double> {
        let y = min(max(luma(v), 0), 1)
        let w = amount * (0.4 + 0.6 * y) * (protectSkin ? 1 - skinWeight(v) : 1)
        return v + SIMD3(w, w * 0.25, -w)
    }

    /// Saturation that moves muted colours more than strong ones and skin
    /// tones least. Negative mutes.
    static func vibrance(_ v: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        let y = luma(v)
        let maxC = max(v.x, v.y, v.z), minC = min(v.x, v.y, v.z)
        let sat = maxC > 0 ? (maxC - minC) / maxC : 0
        let skin = skinWeight(v)
        let push = amount > 0 ? amount * (1 - sat) * (1 - 0.6 * skin) : amount
        return SIMD3(repeating: y) + (v - SIMD3(repeating: y)) * (1 + push)
    }

    /// Hue in degrees (0…360) and chroma of a colour.
    static func hueChroma(_ v: SIMD3<Double>) -> (hue: Double, chroma: Double) {
        let maxC = max(v.x, v.y, v.z), minC = min(v.x, v.y, v.z)
        let chroma = maxC - minC
        guard chroma > 1e-6 else { return (0, 0) }
        var hue: Double
        if maxC == v.x { hue = ((v.y - v.z) / chroma).truncatingRemainder(dividingBy: 6) }
        else if maxC == v.y { hue = (v.z - v.x) / chroma + 2 }
        else { hue = (v.x - v.y) / chroma + 4 }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, chroma)
    }

    /// 1 on the skin hue band (about 10°–50°), fading to 0 by 0° and 75°.
    static func skinWeight(_ v: SIMD3<Double>) -> Double {
        let (hue, chroma) = hueChroma(v)
        guard chroma > 0.02 else { return 0 }
        let h = hue > 300 ? hue - 360 : hue
        if h < 0 || h > 75 { return 0 }
        if h < 10 { return h / 10 }
        if h <= 50 { return 1 }
        return (75 - h) / 25
    }

    /// Pulls greens and blues toward teal and reds/yellows toward orange,
    /// leaving the skin band alone.
    static func tealOrangeHues(_ v: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        let (hue, chroma) = hueChroma(v)
        guard chroma > 0.03 else { return v }
        let skin = skinWeight(v)
        let y = luma(v)
        var target = v
        if hue > 90, hue < 260 {
            // Greens → teal, blues → teal-blue: drop red, keep green/blue.
            target = SIMD3(v.x * 0.8, v.y * 0.98 + v.z * 0.04, v.z * 1.02 + v.y * 0.02)
        } else if hue >= 50, hue <= 90 {
            // Yellows toward amber.
            target = SIMD3(v.x * 1.02, v.y * 0.95, v.z * 0.9)
        }
        let mixed = v + (target - v) * amount * (1 - skin)
        // Keep the brightness where it was.
        let dy = y - luma(mixed)
        return mixed + SIMD3(repeating: dy)
    }
}
