@testable import CameraToolkitCore
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
        let pipeline = GradePipeline(recipe: GradeRecipe(grade: .rec709, profile: .sLog3SGamut3Cine, range: .full))
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
        let full = GradePipeline(recipe: GradeRecipe(grade: .rec709, profile: .sLog3SGamut3Cine, range: .full))
        let video = GradePipeline(recipe: GradeRecipe(grade: .rec709, profile: .sLog3SGamut3Cine, range: .video))
        let cv = 420.0 / 1023
        let decodedVideo = VideoSignalRange.video.decoded(fromCodeValue: cv)
        XCTAssertEqual(full.apply(SIMD3(repeating: cv)).x, video.apply(SIMD3(repeating: decodedVideo)).x, accuracy: 1e-9)
    }

    func testExposureIsOneStopInSceneLinear() {
        var grade = ClipGrade.rec709
        grade.exposure = 1
        let brighter = GradePipeline(recipe: GradeRecipe(grade: grade, profile: .sLog3SGamut3Cine))
        // 9% grey pushed one stop reads as 18% grey.
        let nine = SLog3.encode(reflection: 0.09)
        XCTAssertEqual(brighter.apply(SIMD3(repeating: nine)).x, DisplayRendering.midGreyEncoded, accuracy: 1e-6)
    }

    func testWhiteBalanceWarmsAndKeepsLuminance() {
        var grade = ClipGrade.rec709
        grade.temperature = 50
        let warm = GradePipeline(recipe: GradeRecipe(grade: grade, profile: .sLog3SGamut3Cine)).apply(SIMD3(repeating: 420.0 / 1023))
        XCTAssertGreaterThan(warm.x, warm.z)
        grade.temperature = 0
        grade.tint = 60
        let magenta = GradePipeline(recipe: GradeRecipe(grade: grade, profile: .sLog3SGamut3Cine)).apply(SIMD3(repeating: 420.0 / 1023))
        XCTAssertLessThan(magenta.y, magenta.x)
    }

    func testIntensityBlendsBetweenFlatAndLook() {
        let input = SIMD3<Double>(0.45, 0.40, 0.35)
        func out(_ intensity: Double) -> SIMD3<Double> {
            var grade = ClipGrade.rec709
            grade.intensity = intensity
            return GradePipeline(recipe: GradeRecipe(grade: grade, profile: .sLog3SGamut3Cine)).apply(input)
        }
        XCTAssertEqual(out(0), input)
        let half = out(0.5), full = out(1)
        for c in 0..<3 { XCTAssertEqual(half[c], (input[c] + full[c]) / 2, accuracy: 1e-9) }
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

    func testBuiltInLookIsUnavailableWithoutAKnownProfile() {
        XCTAssertFalse(GradePipeline(recipe: GradeRecipe(grade: .rec709, profile: nil)).isLookAvailable)
        XCTAssertFalse(GradePipeline(recipe: GradeRecipe(grade: .rec709, profile: .djiDLogM)).isLookAvailable)
        XCTAssertTrue(GradePipeline(recipe: GradeRecipe(grade: .rec709, profile: .sLog3SGamut3)).isLookAvailable)
        XCTAssertFalse(GradePipeline(recipe: GradeRecipe(grade: ClipGrade(look: .lut("abc")), profile: nil), lut: nil).isLookAvailable)
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
        let pipeline = GradePipeline(recipe: GradeRecipe(grade: ClipGrade(look: .lut("x")), profile: nil), lut: lut)
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
        let base = GradeRecipe(grade: .rec709, profile: .sLog3SGamut3Cine, range: .full)
        var variants: [GradeRecipe] = []
        for change in 0..<9 {
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
            default: recipe.grade.look = .lut("abc")
            }
            variants.append(recipe)
        }
        let prints = Set(([base] + variants).map(\.fingerprint))
        XCTAssertEqual(prints.count, 10)
        XCTAssertEqual(base.fingerprint, GradeRecipe(grade: .rec709, profile: .sLog3SGamut3Cine, range: .full).fingerprint)
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
