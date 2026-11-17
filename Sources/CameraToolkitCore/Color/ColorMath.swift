import Foundation

/// A 3×3 matrix for RGB↔XYZ work, row-major: `m[row][column]`.
public struct ColorMatrix3: Equatable, Sendable {
    public var rows: [SIMD3<Double>]

    public init(_ rows: [SIMD3<Double>]) {
        precondition(rows.count == 3)
        self.rows = rows
    }

    public init(_ values: [[Double]]) {
        self.init(values.map { SIMD3($0[0], $0[1], $0[2]) })
    }

    public static let identity = ColorMatrix3([[1, 0, 0], [0, 1, 0], [0, 0, 1]])

    public subscript(row: Int, column: Int) -> Double { rows[row][column] }

    public func apply(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3((rows[0] * v).sum(), (rows[1] * v).sum(), (rows[2] * v).sum())
    }

    public static func * (lhs: ColorMatrix3, rhs: ColorMatrix3) -> ColorMatrix3 {
        var out: [SIMD3<Double>] = []
        for r in 0..<3 {
            var row = SIMD3<Double>(repeating: 0)
            for c in 0..<3 {
                row[c] = lhs[r, 0] * rhs[0, c] + lhs[r, 1] * rhs[1, c] + lhs[r, 2] * rhs[2, c]
            }
            out.append(row)
        }
        return ColorMatrix3(out)
    }

    public var determinant: Double {
        let a = rows[0], b = rows[1], c = rows[2]
        return a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) + a.z * (b.x * c.y - b.y * c.x)
    }

    public var inverse: ColorMatrix3 {
        let a = rows[0], b = rows[1], c = rows[2]
        let det = determinant
        precondition(abs(det) > 1e-12, "singular colour matrix")
        let inv = 1 / det
        return ColorMatrix3([
            [(b.y * c.z - b.z * c.y) * inv, (a.z * c.y - a.y * c.z) * inv, (a.y * b.z - a.z * b.y) * inv],
            [(b.z * c.x - b.x * c.z) * inv, (a.x * c.z - a.z * c.x) * inv, (a.z * b.x - a.x * b.z) * inv],
            [(b.x * c.y - b.y * c.x) * inv, (a.y * c.x - a.x * c.y) * inv, (a.x * b.y - a.y * b.x) * inv],
        ])
    }
}

/// An RGB colour space's primaries and white point as CIE xy chromaticities.
public struct RGBPrimaries: Equatable, Sendable {
    public var red: SIMD2<Double>
    public var green: SIMD2<Double>
    public var blue: SIMD2<Double>
    public var white: SIMD2<Double>

    public init(red: SIMD2<Double>, green: SIMD2<Double>, blue: SIMD2<Double>, white: SIMD2<Double>) {
        self.red = red
        self.green = green
        self.blue = blue
        self.white = white
    }

    public static let d65 = SIMD2<Double>(0.3127, 0.3290)

    /// ITU-R BT.709.
    public static let rec709 = RGBPrimaries(red: [0.640, 0.330], green: [0.300, 0.600], blue: [0.150, 0.060], white: d65)
    /// Sony S-Gamut3.Cine ("Technical Summary for S-Gamut3.Cine/S-Log3 and
    /// S-Gamut3/S-Log3", Sony, 2016).
    public static let sGamut3Cine = RGBPrimaries(red: [0.766, 0.275], green: [0.225, 0.800], blue: [0.089, -0.087], white: d65)
    /// Sony S-Gamut3 (same document).
    public static let sGamut3 = RGBPrimaries(red: [0.730, 0.280], green: [0.140, 0.855], blue: [0.100, -0.050], white: d65)
    /// ITU-R BT.2020.
    public static let rec2020 = RGBPrimaries(red: [0.708, 0.292], green: [0.170, 0.797], blue: [0.131, 0.046], white: d65)

    private static func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> {
        SIMD3(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y)
    }

    /// The normalized primary matrix (SMPTE RP 177): linear RGB → XYZ with
    /// the white point at Y = 1.
    public var toXYZ: ColorMatrix3 {
        let r = Self.xyz(red), g = Self.xyz(green), b = Self.xyz(blue)
        let p = ColorMatrix3([SIMD3(r.x, g.x, b.x), SIMD3(r.y, g.y, b.y), SIMD3(r.z, g.z, b.z)])
        let s = p.inverse.apply(Self.xyz(white))
        return ColorMatrix3([
            SIMD3(p[0, 0] * s.x, p[0, 1] * s.y, p[0, 2] * s.z),
            SIMD3(p[1, 0] * s.x, p[1, 1] * s.y, p[1, 2] * s.z),
            SIMD3(p[2, 0] * s.x, p[2, 1] * s.y, p[2, 2] * s.z),
        ])
    }

    /// Linear RGB in `self` → linear RGB in `target`. Both share D65 here,
    /// so no chromatic adaptation is needed.
    public func conversion(to target: RGBPrimaries) -> ColorMatrix3 {
        target.toXYZ.inverse * toXYZ
    }
}

/// Sony S-Log3, from Sony's "Technical Summary for S-Gamut3.Cine/S-Log3 and
/// S-Gamut3/S-Log3". `codeValue` is the full-range 10-bit code value
/// divided by 1023; `reflection` is scene-linear reflectance (0.18 = 18%
/// grey).
public enum SLog3 {
    /// 18% grey lands on 10-bit code value 420, 0% on 95 and 90% on 598.
    public static func encode(reflection x: Double) -> Double {
        if x >= 0.01125000 {
            return (420.0 + log10((x + 0.01) / (0.18 + 0.01)) * 261.5) / 1023.0
        }
        return (x * (171.2102946929 - 95.0) / 0.01125000 + 95.0) / 1023.0
    }

    public static func decode(codeValue y: Double) -> Double {
        if y >= 171.2102946929 / 1023.0 {
            return pow(10.0, (y * 1023.0 - 420.0) / 261.5) * (0.18 + 0.01) - 0.01
        }
        return (y * 1023.0 - 95.0) * 0.01125000 / (171.2102946929 - 95.0)
    }
}

/// ITU-R BT.709 opto-electronic transfer function.
public enum Rec709Transfer {
    public static func encode(_ l: Double) -> Double {
        let l = max(0, l)
        return l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099
    }

    public static func decode(_ v: Double) -> Double {
        let v = max(0, v)
        return v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1 / 0.45)
    }
}

/// How a clip's Y′CbCr was quantized. A decoder hands RGB 0…1 either way;
/// for a video-range clip that 0…1 is code values 64…940 (10-bit), so a
/// curve defined on full code values needs the range to read it.
public enum VideoSignalRange: String, Codable, Sendable {
    case full
    case video

    /// The full-range code value (0…1, as CV/1023) for a decoded value.
    public func codeValue(fromDecoded v: Double) -> Double {
        switch self {
        case .full: v
        case .video: (64.0 + 876.0 * v) / 1023.0
        }
    }

    public func decoded(fromCodeValue cv: Double) -> Double {
        switch self {
        case .full: cv
        case .video: (cv * 1023.0 - 64.0) / 876.0
        }
    }
}
