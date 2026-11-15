@testable import CameraToolkitApp
import CameraToolkitCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// The app side of grading: blanket apply and its Undo, copy/paste, the
/// default look for new log clips, and the graded thumbnail cache key.
@MainActor
final class ClipGradingTests: XCTestCase {
    private let sidecar = """
    <NonRealTimeMeta><Group name="CameraUnitMetadataSet">
    <Item name="CaptureGammaEquation" value="s-log3-cine"/>
    <Item name="CaptureColorPrimaries" value="s-gamut3-cine"/>
    </Group></NonRealTimeMeta>
    """

    private func withSandbox(_ body: (URL, DashboardModel, EventsWorkspace) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitGrading-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Safety Test").path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: root.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: root.appendingPathComponent("Library").path,
            catalogDatabasePath: root.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path,
            selectedDeviceID: "sony-a7v"
        )
        let model = DashboardModel(jobs: [], configuration: configuration, configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json")))
        let workspace = EventsWorkspace(model: model, supportFolder: root.appendingPathComponent("Support", isDirectory: true))
        workspace.grading = ClipGrading(workspace: workspace, library: LUTLibrary(folder: root.appendingPathComponent("LUTs")))
        try await body(root, model, workspace)
    }

    /// Clips on a card: `log` of them with an S-Log3 sidecar, then `flat`
    /// without one, then a photo.
    private func makeItems(in root: URL, log: Int, flat: Int) throws -> [OrganizeItem] {
        let folder = root.appendingPathComponent("Card/M4ROOT/CLIP", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var items: [OrganizeItem] = []
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        for index in 0..<(log + flat) {
            let name = String(format: "C%04d", index + 1)
            let clip = folder.appendingPathComponent("\(name).MP4")
            try Data(repeating: UInt8(index), count: 64 + index).write(to: clip)
            var companions: [OrganizeFile] = []
            if index < log {
                let xml = folder.appendingPathComponent("\(name)M01.XML")
                try Data(sidecar.utf8).write(to: xml)
                companions.append(OrganizeFile(path: xml.path, size: Int64(sidecar.utf8.count), modifiedAt: date))
            }
            let file = OrganizeFile(path: clip.path, size: Int64(64 + index), modifiedAt: date)
            items.append(OrganizeItem(primary: file, companions: companions, kind: .video, captureDate: date, hasCameraDate: true))
        }
        let photo = folder.appendingPathComponent("DSC00001.JPG")
        try Data([0xFF]).write(to: photo)
        items.append(OrganizeItem(primary: OrganizeFile(path: photo.path, size: 1, modifiedAt: date), kind: .photo, captureDate: date, hasCameraDate: true))
        return items
    }

    func testBlanketApplyGradesOnlyLogClipsAndUndoesInOneStep() async throws {
        try await withSandbox { root, model, workspace in
            let grading = workspace.grading
            let items = try makeItems(in: root, log: 3, flat: 2)
            await grading.ensureDetected(items)
            XCTAssertEqual(items.filter { grading.profile(for: $0) != nil }.count, 3)
            XCTAssertEqual(grading.tileMark(for: OrganizeStack(items: [items[0]])), .flatLog(.sLog3SGamut3Cine), "log and flat: the quiet marker")
            XCTAssertNil(grading.tileMark(for: OrganizeStack(items: [items[3]])), "not log: no marker")

            // One clip already has its own exposure; it keeps it.
            grading.setGrade(ClipGrade(look: .none, exposure: 0.5), for: [items[1]], undoTitle: "Adjust Grade")
            let applied = grading.applyLook(.rec709, intensity: 0.8, toLogClipsIn: items)
            XCTAssertEqual(applied, 3)
            let grades = model.configuration.colorGrades
            XCTAssertEqual(grades.count, 3, "the flat clips and the photo are left alone")
            XCTAssertEqual(grades[ClipGrading.fileKey(items[0].primary)], ClipGrade(look: .rec709, intensity: 0.8))
            XCTAssertEqual(grades[ClipGrading.fileKey(items[1].primary)]?.exposure, 0.5)
            XCTAssertEqual(grades[ClipGrading.fileKey(items[1].primary)]?.look, .rec709)
            guard case .graded(let recipe) = grading.tileMark(for: OrganizeStack(items: [items[0]])) else {
                return XCTFail("a graded tile draws the graded picture")
            }
            XCTAssertEqual(recipe.profile, .sLog3SGamut3Cine)
            XCTAssertEqual(recipe.range, .full)
            XCTAssertTrue(workspace.undoMenuTitle?.contains("Apply Rec.709") == true, workspace.undoMenuTitle ?? "nil")

            // ⌘Z takes the whole blanket back; the earlier own grade remains.
            workspace.undo()
            XCTAssertEqual(model.configuration.colorGrades, [ClipGrading.fileKey(items[1].primary): ClipGrade(look: .none, exposure: 0.5)])
            workspace.redo()
            XCTAssertEqual(model.configuration.colorGrades.count, 3)
            // No file was touched.
            for item in items { XCTAssertTrue(FileManager.default.fileExists(atPath: item.primary.path)) }
        }
    }

    func testCopyPasteAndRemoveGrade() async throws {
        try await withSandbox { root, model, workspace in
            let grading = workspace.grading
            let items = try makeItems(in: root, log: 2, flat: 1)
            await grading.ensureDetected(items)
            var warm = ClipGrade.rec709
            warm.temperature = 25
            grading.setGrade(warm, for: [items[0]], undoTitle: "Adjust Grade")
            grading.copyGrade(from: items[0])
            grading.markProfile(.marked(.djiDLogM), for: [items[2]])
            grading.pasteGrade(to: [items[1], items[2]])
            XCTAssertEqual(model.configuration.colorGrades[ClipGrading.fileKey(items[1].primary)], warm)
            XCTAssertEqual(model.configuration.colorGrades[ClipGrading.fileKey(items[2].primary)]?.profileMark, .marked(.djiDLogM), "a pasted grade keeps the clip's own profile label")
            XCTAssertEqual(model.configuration.colorGrades[ClipGrading.fileKey(items[2].primary)]?.temperature, 25)
            grading.removeGrade(from: [items[1]])
            XCTAssertNil(model.configuration.colorGrades[ClipGrading.fileKey(items[1].primary)])
            workspace.undo()
            XCTAssertEqual(model.configuration.colorGrades[ClipGrading.fileKey(items[1].primary)], warm)
        }
    }

    func testDefaultLookAppliesToLogClipsWithoutTheirOwnGrade() async throws {
        try await withSandbox { root, model, workspace in
            let grading = workspace.grading
            let items = try makeItems(in: root, log: 1, flat: 1)
            await grading.ensureDetected(items)
            XCTAssertNil(grading.effectiveGrade(for: items[0]))
            grading.setDefaultLook(.rec709, for: .sLog3SGamut3Cine)
            XCTAssertEqual(grading.effectiveGrade(for: items[0])?.look, .rec709, "new log clips get the default")
            XCTAssertNil(grading.effectiveGrade(for: items[1]), "not log: no default")
            XCTAssertTrue(model.configuration.colorGrades.isEmpty, "nothing is written per clip")
            // A clip's own choice of no look wins over the default.
            grading.setGrade(ClipGrade(look: .none, exposure: 0.3), for: [items[0]], undoTitle: "Adjust Grade")
            XCTAssertEqual(grading.effectiveGrade(for: items[0])?.look, GradeLook.none)
        }
    }

    func testGradedThumbnailsAreCachedUnderTheirOwnKey() async throws {
        try await withSandbox { root, _, _ in
            let url = root.appendingPathComponent("frame.png")
            try writeGradient(to: url)
            let loader = TileImageLoader(purgesOnMemoryPressure: false)
            let warm = GradeRecipe(grade: ClipGrade(temperature: 60), profile: nil, range: .full)
            var cool = warm
            cool.grade.temperature = -60

            XCTAssertNotEqual(TileImageLoader.gradedKeySuffix(warm), TileImageLoader.gradedKeySuffix(cool))
            XCTAssertEqual(TileImageLoader.gradedKeySuffix(warm), TileImageLoader.gradedKeySuffix(GradeRecipe(grade: ClipGrade(temperature: 60), profile: nil, range: .full)))

            let graded = try await XCTUnwrapAsync(await loader.image(for: url, maximumPixelSize: 384, orientation: nil, grade: warm))
            XCTAssertNotNil(loader.cachedImage(for: url, maximumPixelSize: 384, orientation: nil, grade: warm))
            XCTAssertNil(loader.cachedImage(for: url, maximumPixelSize: 384, orientation: nil, grade: cool), "a changed grade is a different picture")
            let plain = try XCTUnwrap(loader.cachedImage(for: url, maximumPixelSize: 384, orientation: nil, grade: nil), "the plain decode is shared and kept")
            XCTAssertTrue(loader.cachedImage(for: url, maximumPixelSize: 384, orientation: nil, grade: GradeRecipe(grade: ClipGrade(), profile: nil)) === plain, "an identity grade is the plain picture")
            XCTAssertNotEqual(redBlueBalance(graded), redBlueBalance(plain), accuracy: 0.02, "the graded tile really is graded")
            XCTAssertGreaterThan(redBlueBalance(graded), redBlueBalance(plain), "warmer")
        }
    }

    private func writeGradient(to url: URL) throws {
        let w = 64, h = 36
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for x in 0..<w {
            let v = CGFloat(x) / CGFloat(w)
            context.setFillColor(red: 0.3 + v * 0.4, green: 0.4, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: h))
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func redBlueBalance(_ image: CGImage) -> Double {
        let w = 16, h = 9
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var red = 0.0, blue = 0.0
        for i in stride(from: 0, to: data.count, by: 4) {
            red += Double(data[i])
            blue += Double(data[i + 2])
        }
        return (red - blue) / Double(w * h * 255)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}
