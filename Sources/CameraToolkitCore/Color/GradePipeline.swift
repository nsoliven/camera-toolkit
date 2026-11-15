import Foundation

/// The colour math of one grade, as a per-pixel function from a clip's
/// decoded values (0…1, as the decoder hands them over, no colour
/// management) to Rec.709-encoded output. Every step is per pixel, so the
/// whole grade bakes into one 3D cube that the GPU applies in one pass —
/// for tiles, live playback and rendered copies alike.
///
/// Order: basic exposure and white balance in scene-linear light (through
/// the clip's own log curve when it has one) → the look (built-in Rec.709
/// conversion or an imported LUT), mixed by intensity → contrast and
/// saturation on the result.
public struct GradePipeline: Sendable {
    public let recipe: GradeRecipe
    /// The imported LUT for a `.lut` look; nil when it is missing.
    public let lut: CubeLUT?

    private let toRec709: ColorMatrix3?
    private let gains: SIMD3<Double>

    public init(recipe: GradeRecipe, lut: CubeLUT? = nil) {
        self.recipe = recipe
        self.lut = lut
        toRec709 = recipe.profile?.primaries?.conversion(to: .rec709)
        let g = recipe.grade
        let exposure = pow(2.0, g.exposure)
        // White balance as channel gains in linear light: temperature
        // trades red against blue, tint trades green against red+blue.
        // Gains are normalized to keep luminance where it was.
        let t = g.temperature / 100, m = g.tint / 100
        var wb = SIMD3<Double>(pow(2, 0.30 * t), pow(2, -0.22 * m), pow(2, -0.30 * t))
        wb /= 0.2126 * wb.x + 0.7152 * wb.y + 0.0722 * wb.z
        gains = wb * exposure
    }

    /// Whether the look can be drawn for this clip — the built-in
    /// conversion needs a profile it knows, an imported LUT needs its file.
    public var isLookAvailable: Bool {
        switch recipe.grade.look {
        case .none: true
        case .rec709: recipe.profile?.hasBuiltInConversion == true
        case .lut: lut != nil
        }
    }

    public func apply(_ input: SIMD3<Double>) -> SIMD3<Double> {
        let g = recipe.grade
        let adjusted = adjustInput(input)
        var out: SIMD3<Double>
        if g.intensity > 0, let looked = look(adjusted) {
            out = g.intensity >= 1 ? looked : adjusted + (looked - adjusted) * g.intensity
        } else {
            out = adjusted
        }
        if g.contrast != 0 { out = Self.contrast(out, amount: g.contrast / 100) }
        if g.saturation != 0 {
            let luma = 0.2126 * out.x + 0.7152 * out.y + 0.0722 * out.z
            out = SIMD3(repeating: luma) + (out - SIMD3(repeating: luma)) * (1 + g.saturation / 100)
        }
        return simd_clamp01(out)
    }

    // MARK: Steps

    /// Exposure and white balance on the clip's own encoding.
    func adjustInput(_ v: SIMD3<Double>) -> SIMD3<Double> {
        guard gains != SIMD3(repeating: 1) else { return v }
        let range = recipe.range
        switch recipe.profile {
        case .sLog3SGamut3Cine?, .sLog3SGamut3?:
            var out = SIMD3<Double>()
            for c in 0..<3 {
                let linear = SLog3.decode(codeValue: range.codeValue(fromDecoded: v[c])) * gains[c]
                out[c] = range.decoded(fromCodeValue: SLog3.encode(reflection: linear))
            }
            return out
        case .djiDLogM?:
            // No published curve: a log encoding moves by a near-constant
            // step per stop, so gains become offsets of a typical log slope.
            let stop = 0.077
            return v + SIMD3(log2(gains.x), log2(gains.y), log2(gains.z)) * stop
        case nil:
            // Display-referred video: undo a 2.4 display gamma, scale, redo.
            var out = SIMD3<Double>()
            for c in 0..<3 {
                out[c] = pow(pow(max(0, v[c]), 2.4) * gains[c], 1 / 2.4)
            }
            return out
        }
    }

    /// The look's output for already-adjusted input, or nil for no look.
    func look(_ v: SIMD3<Double>) -> SIMD3<Double>? {
        switch recipe.grade.look {
        case .none:
            return nil
        case .lut:
            return lut.map { simd_clamp01($0.apply(v)) }
        case .rec709:
            guard let toRec709, recipe.profile?.hasBuiltInConversion == true else { return nil }
            let range = recipe.range
            let linear = SIMD3(
                SLog3.decode(codeValue: range.codeValue(fromDecoded: v.x)),
                SLog3.decode(codeValue: range.codeValue(fromDecoded: v.y)),
                SLog3.decode(codeValue: range.codeValue(fromDecoded: v.z))
            )
            return DisplayRendering.rec709(sceneLinear709: toRec709.apply(linear))
        }
    }

    /// An S-curve that keeps 0 and 1 where they are and steepens (or
    /// flattens) the slope at the pivot by `2^(1.2·amount)`.
    static func contrast(_ v: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        let pivot = DisplayRendering.midGreyEncoded
        let k = pow(2.0, 1.2 * amount)
        var out = SIMD3<Double>()
        for c in 0..<3 {
            let x = min(max(v[c], 0), 1)
            out[c] = x < pivot
                ? pivot * pow(x / pivot, k)
                : 1 - (1 - pivot) * pow((1 - x) / (1 - pivot), k)
        }
        return out
    }

    // MARK: Cube

    /// The grade baked into an RGBA float cube for Core Image's
    /// `CIColorCube` (`size³` texels, red fastest, alpha 1).
    public func cubeData(size: Int) -> [Float] {
        precondition(size >= 2)
        var data = [Float](repeating: 1, count: size * size * size * 4)
        let scale = 1 / Double(size - 1)
        data.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: size) { b in
                for g in 0..<size {
                    for r in 0..<size {
                        let out = apply(SIMD3(Double(r) * scale, Double(g) * scale, Double(b) * scale))
                        let index = ((b * size + g) * size + r) * 4
                        buffer[index] = Float(out.x)
                        buffer[index + 1] = Float(out.y)
                        buffer[index + 2] = Float(out.z)
                    }
                }
            }
        }
        return data
    }
}

/// Scene-linear Rec.709 → display-ready Rec.709 code values.
///
/// A straight transfer-function encode is flat and clips highlights hard
/// at 100%; S-Log3 holds about eight stops above mid grey. This rendering
/// keeps mid grey where Rec.709 puts it, adds a little display contrast,
/// and rolls highlights off smoothly into white instead of clipping.
public enum DisplayRendering {
    /// Where 18% grey lands (Rec.709 OETF of 0.18).
    public static let midGreyEncoded = Rec709Transfer.encode(0.18)
    /// Contrast around mid grey in linear light (a system gamma).
    static let gamma = 1.12
    /// Where the highlight shoulder starts, in rendered linear light.
    static let knee = 0.6

    public static func toneCurve(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        let y = 0.18 * pow(x / 0.18, gamma)
        guard y > knee else { return y }
        // Rational shoulder: slope 1 at the knee, approaching 1.0 slowly
        // enough that S-Log3's top stops (up to ~38× grey) still separate.
        let headroom = 1 - knee
        let t = (y - knee) / headroom
        return knee + headroom * t / (1 + t)
    }

    public static func rec709(sceneLinear709 rgb: SIMD3<Double>) -> SIMD3<Double> {
        // Out-of-gamut colours come out of the matrix slightly negative;
        // they are pulled to the gamut edge rather than inverted.
        let clipped = SIMD3(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0))
        return SIMD3(
            Rec709Transfer.encode(toneCurve(clipped.x)),
            Rec709Transfer.encode(toneCurve(clipped.y)),
            Rec709Transfer.encode(toneCurve(clipped.z))
        )
    }
}

@inline(__always)
func simd_clamp01(_ v: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(min(max(v.x, 0), 1), min(max(v.y, 0), 1), min(max(v.z, 0), 1))
}
