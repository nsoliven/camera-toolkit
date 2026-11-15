@testable import CameraToolkitCore
import XCTest

final class CubeLUTTests: XCTestCase {
    private func identity3D(size: Int, header: String = "") -> String {
        var text = header + "LUT_3D_SIZE \(size)\n"
        let scale = 1.0 / Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    text += "\(Double(r) * scale) \(Double(g) * scale) \(Double(b) * scale)\n"
                }
            }
        }
        return text
    }

    func testParsesA3DTableRedFastest() throws {
        let lut = try CubeLUT.parse(identity3D(size: 3))
        let cube = try XCTUnwrap(lut.cube)
        XCTAssertEqual(cube.size, 3)
        XCTAssertEqual(cube.values.count, 27)
        XCTAssertEqual(cube.entry(1, 0, 0), SIMD3(0.5, 0, 0))
        XCTAssertEqual(cube.entry(0, 1, 0), SIMD3(0, 0.5, 0))
        XCTAssertEqual(cube.entry(0, 0, 2), SIMD3(0, 0, 1))
        XCTAssertNil(lut.shaper)
    }

    func testIdentityTableIsExactBetweenGridPoints() throws {
        let lut = try CubeLUT.parse(identity3D(size: 5))
        for v in [SIMD3(0.13, 0.77, 0.42), SIMD3(0.99, 0.01, 0.5), SIMD3(0.5, 0.5, 0.5)] {
            let out = lut.apply(v)
            for c in 0..<3 { XCTAssertEqual(out[c], v[c], accuracy: 1e-12) }
        }
    }

    func testTetrahedralInterpolationOfALinearTableIsExact() throws {
        // out = (g, b, r) — a linear map, reproduced exactly by tetrahedra.
        var text = "LUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(g) \(b) \(r)\n" } } }
        let lut = try CubeLUT.parse(text)
        let out = lut.apply(SIMD3(0.2, 0.7, 0.4))
        XCTAssertEqual(out.x, 0.7, accuracy: 1e-12)
        XCTAssertEqual(out.y, 0.4, accuracy: 1e-12)
        XCTAssertEqual(out.z, 0.2, accuracy: 1e-12)
    }

    func testParses1DTableAndInterpolatesPerChannel() throws {
        let lut = try CubeLUT.parse("""
        TITLE "Square-ish"
        LUT_1D_SIZE 3
        0 0 0
        0.25 0.5 0.75
        1 1 1
        """)
        XCTAssertEqual(lut.title, "Square-ish")
        XCTAssertFalse(lut.is3D)
        let out = lut.apply(SIMD3(0.25, 0.5, 0.75))
        XCTAssertEqual(out.x, 0.125, accuracy: 1e-12)
        XCTAssertEqual(out.y, 0.5, accuracy: 1e-12)
        XCTAssertEqual(out.z, 0.875, accuracy: 1e-12)
    }

    func testDomainMinMaxScalesInputAndClampsOutside() throws {
        let lut = try CubeLUT.parse("""
        LUT_1D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 2 4 1
        0 0 0
        1 1 1
        """)
        let out = lut.apply(SIMD3(1, 1, 5))
        XCTAssertEqual(out.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(out.y, 0.25, accuracy: 1e-12)
        XCTAssertEqual(out.z, 1, accuracy: 1e-12, "outside the domain clamps")
        XCTAssertEqual(lut.apply(SIMD3(-1, -1, -1)), SIMD3(0, 0, 0))
    }

    func testCommentsCRLFBlankLinesAndVendorKeywordsAreIgnored() throws {
        let text = "# Made by a camera vendor\r\nTITLE \"Look\"\r\n\r\nLUT_IN_VIDEO_RANGE\r\nLUT_3D_SIZE 2 # trailing note\r\n"
            + (0..<8).map { i in "\(i & 1) \((i >> 1) & 1) \((i >> 2) & 1) # row \(i)" }.joined(separator: "\r\n") + "\r\n"
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.title, "Look")
        XCTAssertEqual(lut.cube?.values.count, 8)
    }

    func testShaperThen3DTableAsResolveWritesThem() throws {
        let text = """
        LUT_1D_SIZE 2
        LUT_1D_INPUT_RANGE 0 2
        LUT_3D_SIZE 2
        0 0 0
        1 1 1
        """ + "\n" + (0..<8).map { i in "\(i & 1) \((i >> 1) & 1) \((i >> 2) & 1)" }.joined(separator: "\n")
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.shaper?.size, 2)
        XCTAssertEqual(lut.shaper?.domainMax, SIMD3(repeating: 2))
        XCTAssertEqual(lut.cube?.size, 2)
        let out = lut.apply(SIMD3(1, 2, 0))
        XCTAssertEqual(out.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(out.y, 1, accuracy: 1e-12)
    }

    func test3DInputRangeKeyword() throws {
        var text = "LUT_3D_SIZE 2\nLUT_3D_INPUT_RANGE 0.0 0.5\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(r) \(g) \(b)\n" } } }
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.apply(SIMD3(0.25, 0.25, 0.25)).x, 0.5, accuracy: 1e-12)
    }

    func testRejectsBrokenFiles() {
        XCTAssertThrowsError(try CubeLUT.parse("0 0 0\n1 1 1\n")) { XCTAssertEqual($0 as? CubeLUTError, .noSize) }
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n")) {
            XCTAssertEqual($0 as? CubeLUTError, .wrongCount(expected: 8, found: 1))
        }
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 1\n0 0 0\n")) {
            guard case .badSize = $0 as? CubeLUTError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 999\n")) {
            guard case .badSize = $0 as? CubeLUTError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 2\n0 0\n1 1 1\n")) {
            guard case .badNumber(let line, _) = $0 as? CubeLUTError else { return XCTFail("\($0)") }
            XCTAssertEqual(line, 2)
        }
        XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 2\n0 0 nan\n1 1 1\n"))
        XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 2\nDOMAIN_MIN 1 1 1\nDOMAIN_MAX 0 0 0\n0 0 0\n1 1 1\n")) {
            guard case .badDomain = $0 as? CubeLUTError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try CubeLUT.parse("HELLO WORLD\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n")) {
            guard case .badKeyword = $0 as? CubeLUTError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try CubeLUT.parse(Data([0x00, 0x01, 0x02])))
    }

    func testWriterRoundTrips() throws {
        let source = try CubeLUT.parse(identity3D(size: 4))
        let text = CubeLUT.write3D(title: "Copy", size: 4, values: source.cube!.values)
        let parsed = try CubeLUT.parse(text)
        XCTAssertEqual(parsed.title, "Copy")
        XCTAssertEqual(parsed.cube?.size, 4)
        for (a, b) in zip(parsed.cube!.values, source.cube!.values) {
            for c in 0..<3 { XCTAssertEqual(a[c], b[c], accuracy: 1e-6) }
        }
    }

    /// The built-in conversion, written out and parsed back, gives the same
    /// answers through the parser's interpolation.
    func testBuiltInConversionSurvivesAsACubeFile() throws {
        let pipeline = GradePipeline(recipe: GradeRecipe(grade: .rec709, profile: .sLog3SGamut3Cine))
        let size = 33
        var values: [SIMD3<Double>] = []
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            values.append(pipeline.apply(SIMD3(Double(r), Double(g), Double(b)) / Double(size - 1)))
        } } }
        let lut = try CubeLUT.parse(CubeLUT.write3D(title: nil, size: size, values: values))
        let grey = SIMD3<Double>(repeating: 420.0 / 1023)
        XCTAssertEqual(lut.apply(grey).x, pipeline.apply(grey).x, accuracy: 0.003)
    }
}
