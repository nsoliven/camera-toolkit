@testable import CameraToolkitCore
import CoreMedia
import XCTest

/// The colour math against Sony's published S-Log3 / S-Gamut3 figures
/// ("Technical Summary for S-Gamut3.Cine/S-Log3 and S-Gamut3/S-Log3").
final class ColorGradingMathTests: XCTestCase {
    // MARK: S-Log3

    func testSLog3MatchesSonyReferenceCodeValues() {
        // Sony's table: 0% → 95, 18% grey → 420, 90% white → 598 (10-bit).
        XCTAssertEqual(SLog3.encode(reflection: 0) * 1023, 95, accuracy: 1e-9)
        XCTAssertEqual(SLog3.encode(reflection: 0.18) * 1023, 420, accuracy: 1e-9)
        XCTAssertEqual(SLog3.encode(reflection: 0.90) * 1023, 598, accuracy: 0.5)
        // The linear toe meets the log segment at 171.2102946929.
        XCTAssertEqual(SLog3.encode(reflection: 0.01125) * 1023, 171.2102946929, accuracy: 1e-6)
    }

    func testSLog3DecodeInvertsEncodeAcrossTheRange() {
        for x in stride(from: -0.01, through: 38.0, by: 0.037) {
            let y = SLog3.encode(reflection: x)
            XCTAssertEqual(SLog3.decode(codeValue: y), x, accuracy: 1e-9 + abs(x) * 1e-12)
        }
        XCTAssertEqual(SLog3.decode(codeValue: 420.0 / 1023), 0.18, accuracy: 1e-12)
        XCTAssertEqual(SLog3.decode(codeValue: 95.0 / 1023), 0, accuracy: 1e-12)
    }

    func testSLog3IsContinuousAndMonotonicAtTheBreakPoint() {
        let cut = 171.2102946929 / 1023
        XCTAssertEqual(SLog3.decode(codeValue: cut - 1e-9), SLog3.decode(codeValue: cut + 1e-9), accuracy: 1e-7)
        var last = -Double.infinity
        for cv in stride(from: 0.0, through: 1.0, by: 1.0 / 1023) {
            let x = SLog3.decode(codeValue: cv)
            XCTAssertGreaterThan(x, last)
            last = x
        }
    }

    // MARK: Gamuts

    func testSGamut3CineNormalizedPrimaryMatrixMatchesSony() {
        let sony: [[Double]] = [
            [0.5990839208, 0.2489255161, 0.1024464902],
            [0.2150758201, 0.8850685017, -0.1001443219],
            [-0.0320658495, -0.0276583907, 1.1487819910],
        ]
        assertMatrix(RGBPrimaries.sGamut3Cine.toXYZ, sony, accuracy: 1e-7)
    }

    func testSGamut3NormalizedPrimaryMatrixMatchesSony() {
        let sony: [[Double]] = [
            [0.7064827132, 0.1288010498, 0.1151721641],
            [0.2709796708, 0.7866064112, -0.0575860820],
            [-0.0096778454, 0.0046000375, 1.0941355587],
        ]
        assertMatrix(RGBPrimaries.sGamut3.toXYZ, sony, accuracy: 1e-7)
    }

    func testRec709MatrixMatchesTheStandard() {
        let bt709: [[Double]] = [
            [0.4123908, 0.3575843, 0.1804808],
            [0.2126390, 0.7151687, 0.0721923],
            [0.0193308, 0.1191948, 0.9505322],
        ]
        assertMatrix(RGBPrimaries.rec709.toXYZ, bt709, accuracy: 1e-6)
    }

    func testCineToRec709KeepsWhiteAndExpandsSaturation() {
        let m = RGBPrimaries.sGamut3Cine.conversion(to: .rec709)
        // Same D65 white: each row sums to one.
        for row in m.rows { XCTAssertEqual(row.sum(), 1, accuracy: 1e-9) }
        // Published S-Gamut3.Cine → Rec.709 (derived from the matrices above).
        assertMatrix(m, [
            [1.6269474, -0.5401385, -0.0868088],
            [-0.1785155, 1.4179409, -0.2394254],
            [-0.0444361, -0.1959200, 1.2403561],
        ], accuracy: 2e-5)
        let grey = m.apply(SIMD3(repeating: 0.18))
        XCTAssertEqual(grey.x, 0.18, accuracy: 1e-9)
        XCTAssertEqual(grey.z, 0.18, accuracy: 1e-9)
    }

    func testMatrixInverseRoundTrips() {
        let m = RGBPrimaries.sGamut3Cine.toXYZ
        let product = m * m.inverse
        assertMatrix(product, [[1, 0, 0], [0, 1, 0], [0, 0, 1]], accuracy: 1e-12)
    }

    func testRec2020MatrixMatchesTheStandard() {
        assertMatrix(RGBPrimaries.rec2020.toXYZ, [
            [0.6369580, 0.1446169, 0.1688810],
            [0.2627002, 0.6779981, 0.0593017],
            [0.0000000, 0.0280727, 1.0609851],
        ], accuracy: 1e-6)
    }

    /// A synthetic S-Log3 grey ramp through the built-in conversion, against
    /// Sony's published curve and the Rec.709 OETF computed by hand: every
    /// step lands where the formulas put it and stays neutral, in both
    /// signal ranges.
    func testSLog3GreyRampMatchesThePublishedFormulasAndStaysNeutral() {
        for range in [VideoSignalRange.full, .video] {
            let pipeline = GradePipeline(recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine, range: range))
            var last = -1.0
            for reflection in [0.0, 0.01, 0.02, 0.045, 0.09, 0.18, 0.36, 0.72, 0.9, 1.5, 2.5, 5.0] {
                // Sony: CV = 420 + 261.5·log10((x + 0.01) / 0.19) above the toe.
                let cv = reflection >= 0.01125
                    ? (420 + log10((reflection + 0.01) / 0.19) * 261.5) / 1023
                    : (reflection * (171.2102946929 - 95) / 0.01125 + 95) / 1023
                let out = pipeline.apply(SIMD3(repeating: range.decoded(fromCodeValue: cv)))
                let expected = Rec709Transfer.encode(DisplayRendering.toneCurve(reflection))
                XCTAssertEqual(out.x, expected, accuracy: 1e-6, "\(range) \(reflection)")
                XCTAssertEqual(out.x, out.y, accuracy: 1e-9, "neutral \(range) \(reflection)")
                XCTAssertEqual(out.y, out.z, accuracy: 1e-9, "neutral \(range) \(reflection)")
                XCTAssertGreaterThanOrEqual(out.x, last)
                last = out.x
            }
        }
    }

    /// AVFoundation draws a BT.2020-tagged track into a Rec.709
    /// composition by a gamut conversion in linear light; the undo cube
    /// takes that rendition back to the track's code values.
    func testSourceGamutUndoInvertsTheRec2020ToRec709Rendition() throws {
        let bt2020 = kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
        XCTAssertNil(GradeRenderer.sourceGamutUndo(primaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String, transfer: nil))
        XCTAssertNil(GradeRenderer.sourceGamutUndo(primaries: nil, transfer: nil))
        // HLG and PQ reach the handler unconverted: nothing to undo.
        XCTAssertNil(GradeRenderer.sourceGamutUndo(primaries: bt2020, transfer: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String))
        XCTAssertNil(GradeRenderer.sourceGamutUndo(primaries: bt2020, transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String))
        XCTAssertNotNil(GradeRenderer.sourceGamutUndo(primaries: bt2020, transfer: kCMFormatDescriptionTransferFunction_ITU_R_2020 as String))
        XCTAssertNotNil(GradeRenderer.sourceGamutUndo(primaries: bt2020, transfer: nil))
        let data = try XCTUnwrap(GradeRenderer.sourceGamutUndo(primaries: bt2020, transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String))
        let size = GradeRenderer.previewCubeSize
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(floats.count, size * size * size * 4)
        let to709 = RGBPrimaries.rec2020.conversion(to: .rec709)
        func rendition(_ v: SIMD3<Double>) -> SIMD3<Double> {
            let l = to709.apply(SIMD3(Rec709Transfer.decode(v.x), Rec709Transfer.decode(v.y), Rec709Transfer.decode(v.z)))
            return SIMD3(Rec709Transfer.encode(l.x), Rec709Transfer.encode(l.y), Rec709Transfer.encode(l.z))
        }
        // Log code values: low saturation, the rendition stays in range.
        for code in [SIMD3(0.41, 0.41, 0.41), SIMD3(0.49, 0.36, 0.37), SIMD3(0.43, 0.51, 0.50), SIMD3(0.38, 0.42, 0.46)] {
            let shown = rendition(code)
            // Nearest texel is enough to show the cube points the right way.
            let idx = SIMD3<Int>(Int((shown.x * Double(size - 1)).rounded()), Int((shown.y * Double(size - 1)).rounded()), Int((shown.z * Double(size - 1)).rounded()))
            let i = ((idx.z * size + idx.y) * size + idx.x) * 4
            let back = SIMD3(Double(floats[i]), Double(floats[i + 1]), Double(floats[i + 2]))
            XCTAssertEqual(back.x, code.x, accuracy: 0.03)
            XCTAssertEqual(back.y, code.y, accuracy: 0.03)
            XCTAssertEqual(back.z, code.z, accuracy: 0.03)
        }
    }

    // MARK: Display rendering

    func testRec709TransferMatchesBT709() {
        XCTAssertEqual(Rec709Transfer.encode(0.018), 0.081, accuracy: 1e-3)
        XCTAssertEqual(Rec709Transfer.encode(1), 1, accuracy: 1e-12)
        XCTAssertEqual(Rec709Transfer.encode(0.18), 0.409, accuracy: 1e-3)
        for v in stride(from: 0.0, through: 1.0, by: 0.01) {
            XCTAssertEqual(Rec709Transfer.encode(Rec709Transfer.decode(v)), v, accuracy: 1e-9)
        }
    }

    func testToneCurveKeepsMidGreyAndRollsHighlightsOffWithoutClipping() {
        XCTAssertEqual(DisplayRendering.toneCurve(0.18), 0.18, accuracy: 1e-9)
        var last = 0.0
        for x in stride(from: 0.001, through: 40.0, by: 0.01) {
            let y = DisplayRendering.toneCurve(x)
            XCTAssertGreaterThan(y, last, "monotonic at \(x)")
            XCTAssertLessThan(y, 1, "never reaches a hard clip at \(x)")
            last = y
        }
        // 90% white keeps detail below 100%, S-Log3's top still separates.
        XCTAssertLessThan(DisplayRendering.toneCurve(0.9), 0.95)
        XCTAssertGreaterThan(DisplayRendering.toneCurve(8), DisplayRendering.toneCurve(4))
        // Slope is continuous through the knee.
        let kneeInput = 0.18 * pow(DisplayRendering.knee / 0.18, 1 / DisplayRendering.gamma)
        let below = DisplayRendering.toneCurve(kneeInput - 1e-6), at = DisplayRendering.toneCurve(kneeInput), above = DisplayRendering.toneCurve(kneeInput + 1e-6)
        XCTAssertEqual((at - below) / 1e-6, (above - at) / 1e-6, accuracy: 1e-3)
    }

    // MARK: Pipeline

    func testRec709LookMapsSLog3GreyToRec709GreyAndStaysNeutral() {
        let pipeline = GradePipeline(recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine, range: .full))
        let grey = pipeline.apply(SIMD3(repeating: 420.0 / 1023))
        XCTAssertEqual(grey.x, DisplayRendering.midGreyEncoded, accuracy: 1e-6)
        XCTAssertEqual(grey.x, grey.y, accuracy: 1e-9)
        XCTAssertEqual(grey.y, grey.z, accuracy: 1e-9)
        // Black stays black, the top of the curve stays under white.
        let black = pipeline.apply(SIMD3(repeating: 95.0 / 1023))
        XCTAssertEqual(black.x, 0, accuracy: 1e-6)
        let top = pipeline.apply(SIMD3(repeating: 1))
        XCTAssertLessThanOrEqual(top.x, 1)
        XCTAssertGreaterThan(top.x, 0.95)
    }

    func testVideoRangeInputReadsTheSameCodeValues() {
        let full = GradePipeline(recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine, range: .full))
        let video = GradePipeline(recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine, range: .video))
        let cv = 420.0 / 1023
        let decodedVideo = VideoSignalRange.video.decoded(fromCodeValue: cv)
        XCTAssertEqual(full.apply(SIMD3(repeating: cv)).x, video.apply(SIMD3(repeating: decodedVideo)).x, accuracy: 1e-9)
    }

    func testExposureIsOneStopInSceneLinear() {
        var grade = ClipGrade.converted
        grade.exposure = 1
        let brighter = GradePipeline(recipe: GradeRecipe(grade: grade, profile: .sLog3SGamut3Cine))
        // 9% grey pushed one stop reads as 18% grey.
        let nine = SLog3.encode(reflection: 0.09)
        XCTAssertEqual(brighter.apply(SIMD3(repeating: nine)).x, DisplayRendering.midGreyEncoded, accuracy: 1e-6)
    }

    func testWhiteBalanceWarmsAndKeepsLuminance() {
        var grade = ClipGrade.converted
        grade.temperature = 50
        let warm = GradePipeline(recipe: GradeRecipe(grade: grade, profile: .sLog3SGamut3Cine)).apply(SIMD3(repeating: 420.0 / 1023))
        XCTAssertGreaterThan(warm.x, warm.z)
        grade.temperature = 0
        grade.tint = 60
        let magenta = GradePipeline(recipe: GradeRecipe(grade: grade, profile: .sLog3SGamut3Cine)).apply(SIMD3(repeating: 420.0 / 1023))
        XCTAssertLessThan(magenta.y, magenta.x)
    }

    func testLookIntensityBlendsOverTheConvertedPicture() {
        let input = SIMD3<Double>(0.45, 0.40, 0.35)
        func out(_ intensity: Double) -> SIMD3<Double> {
            var grade = ClipGrade.converted
            grade.look = .builtIn(.blackWhite)
            grade.intensity = intensity
            return GradePipeline(recipe: GradeRecipe(grade: grade, profile: .sLog3SGamut3Cine)).apply(input)
        }
        let converted = GradePipeline(recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine)).apply(input)
        XCTAssertEqual(out(0), converted, "no look: the conversion alone")
        let half = out(0.5), full = out(1)
        for c in 0..<3 { XCTAssertEqual(half[c], (converted[c] + full[c]) / 2, accuracy: 1e-9) }
        XCTAssertEqual(full.x, full.z, accuracy: 0.012, "black and white: neutral but for a faint warm tone")
    }

    func testALookNeverGoesOnUnconvertedLog() {
        let input = SIMD3<Double>(0.45, 0.40, 0.35)
        var grade = ClipGrade(conversion: .off, look: .builtIn(.richVivid))
        let off = GradeRecipe(grade: grade, profile: .sLog3SGamut3Cine)
        XCTAssertEqual(off.conversion, ResolvedConversion.none)
        XCTAssertFalse(off.lookApplies)
        XCTAssertEqual(GradePipeline(recipe: off).apply(input), input, "flat log stays flat — no look on top of log")
        grade.conversion = .auto
        XCTAssertTrue(GradeRecipe(grade: grade, profile: .sLog3SGamut3Cine).lookApplies)
        XCTAssertTrue(GradeRecipe(grade: grade, profile: nil).lookApplies, "plain Rec.709 video takes a look directly")
        XCTAssertFalse(GradeRecipe(grade: grade, profile: .djiDLogM).lookApplies, "D-Log M has no conversion until its LUT is imported")
    }

    func testContrastAndSaturationAreNeutralAtZeroAndPivotOnGrey() {
        let pivot = SIMD3(repeating: DisplayRendering.midGreyEncoded)
        let contrasty = GradePipeline.contrast(pivot, amount: 0.8)
        XCTAssertEqual(contrasty.x, pivot.x, accuracy: 1e-12)
        XCTAssertEqual(GradePipeline.contrast(SIMD3(0, 1, 0.5), amount: 1).x, 0, accuracy: 1e-12)
        XCTAssertEqual(GradePipeline.contrast(SIMD3(0, 1, 0.5), amount: 1).y, 1, accuracy: 1e-12)
        var grade = ClipGrade()
        grade.saturation = -100
        let mono = GradePipeline(recipe: GradeRecipe(grade: grade, profile: nil)).apply(SIMD3(0.8, 0.2, 0.4))
        XCTAssertEqual(mono.x, mono.y, accuracy: 1e-9)
        XCTAssertEqual(mono.y, mono.z, accuracy: 1e-9)
    }

    func testConversionResolvesFromTheProfile() {
        XCTAssertEqual(GradeRecipe(grade: .converted, profile: nil).conversion, ResolvedConversion.none)
        XCTAssertEqual(GradeRecipe(grade: .converted, profile: .djiDLogM).conversion, ResolvedConversion.none)
        XCTAssertEqual(GradeRecipe(grade: .converted, profile: .sLog3SGamut3).conversion, .builtIn)
        XCTAssertTrue(GradeRecipe(grade: .converted, profile: nil).isIdentity)
        XCTAssertFalse(GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine).isIdentity, "log footage is converted")
        let missing = GradePipeline(recipe: GradeRecipe(grade: ClipGrade(look: .lut("abc")), profile: nil), lookLUT: nil)
        XCTAssertFalse(missing.isLookAvailable)
        let conversionMissing = GradePipeline(recipe: GradeRecipe(grade: ClipGrade(conversion: .lut("abc")), profile: .sLog3SGamut3Cine), conversionLUT: nil)
        XCTAssertFalse(conversionMissing.isConversionAvailable)
    }

    func testBuiltInLooksStayInRangeKeepGreyNeutralAndSkinNatural() {
        let skin = SIMD3<Double>(0.78, 0.58, 0.47)   // a typical Rec.709 skin tone
        for look in BuiltInLook.allCases {
            for v in [SIMD3<Double>(0, 0, 0), SIMD3(1, 1, 1), SIMD3(0.2, 0.7, 0.9), skin] {
                let out = look.apply(v)
                for c in 0..<3 { XCTAssertTrue((0...1).contains(out[c]), "\(look) out of range") }
            }
            let grey = look.apply(SIMD3(repeating: 0.42))
            XCTAssertLessThan(abs(grey.x - grey.z), 0.06, "\(look) keeps mid grey near neutral")
            if look != .blackWhite {
                let (inHue, _) = LookMath.hueChroma(skin)
                let (outHue, _) = LookMath.hueChroma(look.apply(skin))
                XCTAssertLessThan(abs(outHue - inHue), 8, "\(look) keeps skin hue")
            }
            XCTAssertTrue((0.6...1.0).contains(look.defaultIntensity))
        }
    }

    func testImportedLUTLookUsesTheTable() throws {
        // A LUT that inverts: output = 1 - input.
        let lut = try CubeLUT.parse("""
        LUT_3D_SIZE 2
        1 1 1
        0 1 1
        1 0 1
        0 0 1
        1 1 0
        0 1 0
        1 0 0
        0 0 0
        """)
        let pipeline = GradePipeline(recipe: GradeRecipe(grade: ClipGrade(look: .lut("x")), profile: nil), lookLUT: lut)
        let out = pipeline.apply(SIMD3(0.2, 0.5, 0.9))
        XCTAssertEqual(out.x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(out.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(out.z, 0.1, accuracy: 1e-9)
    }

    func testCubeDataLayoutIsRedFastestWithOpaqueAlpha() {
        let pipeline = GradePipeline(recipe: GradeRecipe(grade: ClipGrade(saturation: 0.0001), profile: nil))
        let size = 3
        let data = pipeline.cubeData(size: size)
        XCTAssertEqual(data.count, size * size * size * 4)
        // Entry (r=2, g=0, b=1) holds input (1, 0, 0.5) unchanged.
        let index = ((1 * size + 0) * size + 2) * 4
        XCTAssertEqual(data[index], 1, accuracy: 1e-4)
        XCTAssertEqual(data[index + 1], 0, accuracy: 1e-4)
        XCTAssertEqual(data[index + 2], 0.5, accuracy: 1e-4)
        XCTAssertEqual(data[index + 3], 1)
    }

    func testFingerprintChangesWithEveryPart() {
        let base = GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine, range: .full)
        var variants: [GradeRecipe] = []
        for change in 0..<11 {
            var recipe = base
            switch change {
            case 0: recipe.grade.intensity = 0.5
            case 1: recipe.grade.exposure = 0.25
            case 2: recipe.grade.temperature = 10
            case 3: recipe.grade.tint = -10
            case 4: recipe.grade.contrast = 5
            case 5: recipe.grade.saturation = 5
            case 6: recipe.profile = .sLog3SGamut3
            case 7: recipe.range = .video
            case 8: recipe.grade.look = .lut("abc")
            case 9: recipe.grade.look = .builtIn(.softFilm)
            default: recipe.conversion = .lut("sony")
            }
            variants.append(recipe)
        }
        let prints = Set(([base] + variants).map(\.fingerprint))
        XCTAssertEqual(prints.count, 12)
        XCTAssertEqual(base.fingerprint, GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine, range: .full).fingerprint)
        XCTAssertEqual(base.shortFingerprint.count, 16)
    }

    // MARK: Helpers

    private func assertMatrix(_ m: ColorMatrix3, _ expected: [[Double]], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
        for r in 0..<3 {
            for c in 0..<3 {
                XCTAssertEqual(m[r, c], expected[r][c], accuracy: accuracy, "[\(r)][\(c)]", file: file, line: line)
            }
        }
    }
}
