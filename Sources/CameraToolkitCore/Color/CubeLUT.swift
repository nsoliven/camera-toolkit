import Foundation

/// A colour lookup table read from an Adobe/IRIDAS `.cube` file (the
/// format Sony, DJI, Resolve and most creative-LUT vendors ship).
///
/// Supported: `TITLE`, `LUT_1D_SIZE`, `LUT_3D_SIZE`, `DOMAIN_MIN`,
/// `DOMAIN_MAX`, Resolve's `LUT_1D_INPUT_RANGE` / `LUT_3D_INPUT_RANGE`, a
/// 1D shaper followed by a 3D table in one file (Resolve's layout),
/// comments (`#`, whole-line or trailing), blank lines and CRLF endings.
/// In a 3D table red changes fastest, then green, then blue.
public struct CubeLUT: Equatable, Sendable {
    public struct Table1D: Equatable, Sendable {
        public var size: Int
        public var domainMin: SIMD3<Double>
        public var domainMax: SIMD3<Double>
        /// `size` entries.
        public var values: [SIMD3<Double>]
    }

    public struct Table3D: Equatable, Sendable {
        public var size: Int
        public var domainMin: SIMD3<Double>
        public var domainMax: SIMD3<Double>
        /// `size³` entries, red fastest.
        public var values: [SIMD3<Double>]

        public func entry(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> {
            values[r + g * size + b * size * size]
        }
    }

    public var title: String?
    public var shaper: Table1D?
    public var cube: Table3D?

    public var is3D: Bool { cube != nil }

    public init(title: String? = nil, shaper: Table1D? = nil, cube: Table3D? = nil) {
        self.title = title
        self.shaper = shaper
        self.cube = cube
    }

    /// Applies the shaper (if any), then the 3D table (if any). Inputs
    /// outside a table's domain are clamped to it.
    public func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        var value = rgb
        if let shaper { value = Self.sample(shaper, value) }
        if let cube { value = Self.sample(cube, value) }
        return value
    }

    private static func normalized(_ v: SIMD3<Double>, _ lo: SIMD3<Double>, _ hi: SIMD3<Double>) -> SIMD3<Double> {
        var out = SIMD3<Double>()
        for i in 0..<3 {
            let span = hi[i] - lo[i]
            let t = span == 0 ? 0 : (v[i] - lo[i]) / span
            out[i] = min(max(t.isFinite ? t : 0, 0), 1)
        }
        return out
    }

    static func sample(_ table: Table1D, _ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let t = normalized(rgb, table.domainMin, table.domainMax) * Double(table.size - 1)
        var out = SIMD3<Double>()
        for c in 0..<3 {
            let i0 = min(Int(t[c].rounded(.down)), table.size - 2)
            let f = t[c] - Double(i0)
            out[c] = table.values[i0][c] * (1 - f) + table.values[i0 + 1][c] * f
        }
        return out
    }

    /// Tetrahedral interpolation — what Resolve and most hardware use; it
    /// keeps the neutral axis exact.
    static func sample(_ table: Table3D, _ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let n = table.size
        let t = normalized(rgb, table.domainMin, table.domainMax) * Double(n - 1)
        let r0 = min(Int(t.x.rounded(.down)), n - 2)
        let g0 = min(Int(t.y.rounded(.down)), n - 2)
        let b0 = min(Int(t.z.rounded(.down)), n - 2)
        let fr = t.x - Double(r0), fg = t.y - Double(g0), fb = t.z - Double(b0)
        let c000 = table.entry(r0, g0, b0)
        let c111 = table.entry(r0 + 1, g0 + 1, b0 + 1)
        if fr >= fg {
            if fg >= fb {
                let c100 = table.entry(r0 + 1, g0, b0), c110 = table.entry(r0 + 1, g0 + 1, b0)
                return c000 + (c100 - c000) * fr + (c110 - c100) * fg + (c111 - c110) * fb
            } else if fr >= fb {
                let c100 = table.entry(r0 + 1, g0, b0), c101 = table.entry(r0 + 1, g0, b0 + 1)
                return c000 + (c100 - c000) * fr + (c111 - c101) * fg + (c101 - c100) * fb
            } else {
                let c001 = table.entry(r0, g0, b0 + 1), c101 = table.entry(r0 + 1, g0, b0 + 1)
                return c000 + (c101 - c001) * fr + (c111 - c101) * fg + (c001 - c000) * fb
            }
        } else {
            if fb >= fg {
                let c001 = table.entry(r0, g0, b0 + 1), c011 = table.entry(r0, g0 + 1, b0 + 1)
                return c000 + (c111 - c011) * fr + (c011 - c001) * fg + (c001 - c000) * fb
            } else if fb >= fr {
                let c010 = table.entry(r0, g0 + 1, b0), c011 = table.entry(r0, g0 + 1, b0 + 1)
                return c000 + (c111 - c011) * fr + (c010 - c000) * fg + (c011 - c010) * fb
            } else {
                let c010 = table.entry(r0, g0 + 1, b0), c110 = table.entry(r0 + 1, g0 + 1, b0)
                return c000 + (c110 - c010) * fr + (c010 - c000) * fg + (c111 - c110) * fb
            }
        }
    }
}

public enum CubeLUTError: Error, Equatable, LocalizedError {
    case notText
    case noSize
    case badSize(line: Int, String)
    case badKeyword(line: Int, String)
    case badNumber(line: Int, String)
    case wrongCount(expected: Int, found: Int)
    case badDomain(String)
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .notText: "The file is not a text .cube LUT."
        case .noSize: "The LUT has no LUT_1D_SIZE or LUT_3D_SIZE line."
        case .badSize(let line, let text): "Line \(line): \(text) is not a supported LUT size."
        case .badKeyword(let line, let text): "Line \(line): \(text) is not understood."
        case .badNumber(let line, let text): "Line \(line): \(text) is not three numbers."
        case .wrongCount(let expected, let found): "The LUT should have \(expected) entries but has \(found)."
        case .badDomain(let text): "The LUT's domain is invalid: \(text)."
        case .tooLarge: "The file is too large to be a .cube LUT."
        }
    }
}

extension CubeLUT {
    /// Biggest file accepted (a 65³ float LUT is about 8 MB of text).
    public static let maximumFileBytes = 64 * 1_024 * 1_024

    public static func parse(contentsOf url: URL) throws -> CubeLUT {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumFileBytes else { throw CubeLUTError.tooLarge }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> CubeLUT {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !text.contains("\u{0}") else {
            throw CubeLUTError.notText
        }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> CubeLUT {
        var title: String?
        var size1D: Int?
        var size3D: Int?
        var domainMin = SIMD3<Double>(0, 0, 0)
        var domainMax = SIMD3<Double>(1, 1, 1)
        var range1D: (Double, Double)?
        var range3D: (Double, Double)?
        var rows: [SIMD3<Double>] = []
        rows.reserveCapacity(36_000)

        var lineNumber = 0
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            lineNumber += 1
            var line = Substring(rawLine)
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            line = line.drop(while: { $0 == " " || $0 == "\t" })
            guard !line.isEmpty else { continue }
            let first = line.first!
            if first.isLetter {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                let keyword = parts[0].uppercased()
                let args = parts.dropFirst()
                switch keyword {
                case "TITLE":
                    var rest = line.dropFirst(parts[0].count).trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 { rest = String(rest.dropFirst().dropLast()) }
                    title = rest
                case "LUT_1D_SIZE":
                    guard args.count == 1, let n = Int(args.first!), (2...65_536).contains(n) else {
                        throw CubeLUTError.badSize(line: lineNumber, String(line))
                    }
                    size1D = n
                case "LUT_3D_SIZE":
                    guard args.count == 1, let n = Int(args.first!), (2...256).contains(n) else {
                        throw CubeLUTError.badSize(line: lineNumber, String(line))
                    }
                    size3D = n
                case "DOMAIN_MIN", "DOMAIN_MAX":
                    guard let v = triple(args) else { throw CubeLUTError.badNumber(line: lineNumber, String(line)) }
                    if keyword == "DOMAIN_MIN" { domainMin = v } else { domainMax = v }
                case "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                    let values = args.compactMap { Double($0) }
                    guard values.count == 2, args.count == 2 else { throw CubeLUTError.badNumber(line: lineNumber, String(line)) }
                    if keyword == "LUT_1D_INPUT_RANGE" { range1D = (values[0], values[1]) } else { range3D = (values[0], values[1]) }
                default:
                    // Vendor keywords some tools write (LUT_IN_VIDEO_RANGE…)
                    // carry no table data; anything else is not a .cube.
                    if keyword.hasPrefix("LUT_") || keyword.hasPrefix("DOMAIN_") { continue }
                    throw CubeLUTError.badKeyword(line: lineNumber, String(line))
                }
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let v = triple(parts[...]) else {
                throw CubeLUTError.badNumber(line: lineNumber, String(line))
            }
            rows.append(v)
        }

        guard size1D != nil || size3D != nil else { throw CubeLUTError.noSize }
        let count1D = size1D ?? 0
        let count3D = size3D.map { $0 * $0 * $0 } ?? 0
        guard rows.count == count1D + count3D else {
            throw CubeLUTError.wrongCount(expected: count1D + count3D, found: rows.count)
        }
        for i in 0..<3 where !(domainMax[i] > domainMin[i]) {
            throw CubeLUTError.badDomain("DOMAIN_MAX must be above DOMAIN_MIN")
        }

        var lut = CubeLUT(title: title)
        if let size1D {
            let lo = range1D.map { SIMD3(repeating: $0.0) } ?? domainMin
            let hi = range1D.map { SIMD3(repeating: $0.1) } ?? domainMax
            lut.shaper = Table1D(size: size1D, domainMin: lo, domainMax: hi, values: Array(rows[0..<count1D]))
        }
        if let size3D {
            // With a shaper in front, the 3D table reads the shaper's output.
            let lo = range3D.map { SIMD3(repeating: $0.0) } ?? (size1D == nil ? domainMin : SIMD3(0, 0, 0))
            let hi = range3D.map { SIMD3(repeating: $0.1) } ?? (size1D == nil ? domainMax : SIMD3(1, 1, 1))
            lut.cube = Table3D(size: size3D, domainMin: lo, domainMax: hi, values: Array(rows[count1D...]))
        }
        for table in [lut.shaper.map { ($0.domainMin, $0.domainMax) }, lut.cube.map { ($0.domainMin, $0.domainMax) }].compactMap({ $0 }) {
            for i in 0..<3 where !(table.1[i] > table.0[i]) {
                throw CubeLUTError.badDomain("input range must increase")
            }
        }
        return lut
    }

    private static func triple(_ parts: ArraySlice<Substring>) -> SIMD3<Double>? {
        guard parts.count == 3 else { return nil }
        var v = SIMD3<Double>()
        for (i, part) in parts.enumerated() {
            guard let d = Double(part), d.isFinite else { return nil }
            v[i] = d
        }
        return v
    }

    /// Writes a 3D table as `.cube` text (used for tests and for exporting
    /// the built-in conversion so it can be checked in another app).
    public static func write3D(title: String?, size: Int, values: [SIMD3<Double>]) -> String {
        precondition(values.count == size * size * size)
        var text = ""
        text.reserveCapacity(values.count * 28)
        if let title { text += "TITLE \"\(title)\"\n" }
        text += "LUT_3D_SIZE \(size)\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n"
        for v in values {
            text += String(format: "%.6f %.6f %.6f\n", v.x, v.y, v.z)
        }
        return text
    }
}
