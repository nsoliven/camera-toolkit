import AppKit
import AVFoundation
@testable import CameraToolkitApp
import CameraToolkitCore
import SwiftUI
import UniformTypeIdentifiers
import XCTest

/// Opt-in: draws the grading screens offscreen with frames from real clips
/// and saves PNGs, so the UI can be judged without opening the app.
///
///     CT_GRADE_SCREENSHOT_FOLDER=/path/to/CLIP CT_GRADE_SCREENSHOT_OUT=/tmp/shots \
///         swift test --filter GradeScreenshotTests
///
/// The folder holds Sony clips with their `M01.XML` sidecars. Clips are only
/// read; nothing is written beside them.
@MainActor
final class GradeScreenshotTests: XCTestCase {
    private struct Clip {
        let url: URL
        let item: OrganizeItem
        let profile: LogProfile?
        let range: VideoSignalRange
    }

    private var output: URL!
    private var clips: [Clip] = []

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["CT_GRADE_SCREENSHOT_FOLDER"], let out = env["CT_GRADE_SCREENSHOT_OUT"] else {
            throw XCTSkip("Set CT_GRADE_SCREENSHOT_FOLDER and CT_GRADE_SCREENSHOT_OUT to draw the grading screens.")
        }
        output = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder)
            .filter { $0.uppercased().hasSuffix(".MP4") && !$0.hasPrefix("._") }
            .sorted()
        let skip = Int(env["CT_GRADE_SCREENSHOT_SKIP"] ?? "") ?? 0
        for name in names.dropFirst(skip).prefix(9) {
            let url = folderURL.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let file = OrganizeFile(path: url.path, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? Date())
            let xml = url.deletingPathExtension().path + "M01.XML"
            let companions = FileManager.default.fileExists(atPath: xml)
                ? [OrganizeFile(path: xml, size: 2_000, modifiedAt: file.modifiedAt)] : []
            let item = OrganizeItem(primary: file, companions: companions, kind: .video, captureDate: file.modifiedAt, hasCameraDate: true)
            let profile = LogProfileDetector.profile(clip: url, companions: companions.map(\.url))
            let range = await GradeRenderer.shared.signalRange(of: url) ?? .full
            clips.append(Clip(url: url, item: item, profile: profile, range: range))
        }
        guard !clips.isEmpty else { throw XCTSkip("No clips in the folder.") }
    }

    // MARK: Screens

    func testDrawGradingScreens() async throws {
        let env = ProcessInfo.processInfo.environment
        let hero = clips[min(clips.count - 1, Int(env["CT_GRADE_SCREENSHOT_HERO"] ?? "") ?? 0)]
        let frame = try await self.frame(of: hero.url, at: Double(env["CT_GRADE_SCREENSHOT_AT"] ?? "") ?? 4, width: 1_600)
        let looks: [GradeLook] = [.none] + BuiltInLook.allCases.map { .builtIn($0) }
        let name: (GradeLook) -> String = { look in
            switch look {
            case .none: "No Look"
            case .builtIn(let look): look.displayName
            case .lut: "LUT"
            }
        }
        let conversionName: (GradeConversion) -> String = { choice in
            switch choice {
            case .auto: "Default (Built-in, Sony math)"
            case .builtIn: "Built-in (Sony math)"
            case .lut: "LUT"
            case .off: "Don’t convert"
            }
        }
        let title: (GradeRecipe) -> String = { recipe in
            recipe.conversion.converts ? "Sony S-Log3 → Rec.709 · Built-in (Sony math)" : "Off — shown as recorded (S-Log3)"
        }
        let lookName = env["CT_GRADE_SCREENSHOT_LOOK"].flatMap(BuiltInLook.init(rawValue:)) ?? .softFilm
        var grade = ClipGrade(look: .builtIn(lookName), intensity: lookName.defaultIntensity)
        grade.exposure = 0.1
        let session = GradeSession(
            itemID: hero.item.id, clipName: hero.item.primary.name, grade: grade,
            profile: hero.profile, detectedProfile: hero.profile, range: hero.range,
            looks: looks, lookName: name,
            conversionChoices: [.auto, .builtIn, .off], conversionName: conversionName, conversionTitle: title
        )
        session.setFrame(try XCTUnwrap(GradeSession.downscaled(frame, maxWidth: 960)))
        try await waitUntil { session.histogram != nil && session.lookThumbnails.count == looks.count }

        let graded = try XCTUnwrap(GradeRenderer.shared.grade(frame, recipe: session.recipe))
        try save(GradeScreenMock(session: session, picture: graded, clipName: hero.item.primary.name, showWipe: false), size: CGSize(width: 1_560, height: 960), name: "1-grade-panel", appearance: .darkAqua)

        session.viewMode = .split
        session.wipe = 0.46
        let split = try XCTUnwrap(Self.split(before: frame, after: graded, at: session.wipe))
        try save(GradeScreenMock(session: session, picture: split, clipName: hero.item.primary.name, showWipe: true), size: CGSize(width: 1_560, height: 960), name: "2-before-after-wipe", appearance: .darkAqua)

        try save(
            GradeLookStrip(looks: looks, selected: session.draft.look, thumbnails: session.lookThumbnails, name: name, onChoose: { _ in })
                .padding(8)
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16))
                .padding(16)
                .background(Color.black)
                .environment(\.colorScheme, .dark),
            size: CGSize(width: 1_060, height: 170), name: "3-look-strip", appearance: .darkAqua
        )

        // Blanket preview over several real clips.
        let blanket = BlanketGradeModel(scopeTitle: "Trip 2026", lookName: name)
        blanket.conversionTitle = "Sony S-Log3 → Rec.709 · Built-in (Sony math)"
        var rows: [BlanketGradeModel.Row] = []
        for clip in clips.prefix(6) {
            rows.append(.init(id: clip.item.id, name: clip.item.primary.name, profile: clip.profile ?? .sLog3SGamut3Cine, conversion: .builtIn, range: clip.range, existing: nil))
        }
        blanket.load(rows: rows, notLogCount: 2, looks: looks)
        for clip in clips.prefix(6) {
            blanket.setBefore(try await self.frame(of: clip.url, at: 3, width: 480), for: clip.item.id)
        }
        blanket.alsoMakeDefault = true
        try await waitUntil { blanket.rows.allSatisfy { $0.after != nil } && blanket.lookThumbnails.count == looks.count }
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            try save(BlanketGradeSheet(model: blanket, onCancel: {}, onApply: {}).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 760, height: 640), name: "4-blanket-preview-\(suffix)", appearance: appearance)
        }

        // Tiles: converted clips (some with a look) draw graded; clips with
        // the conversion turned off stay flat and wear the marker.
        let loader = TileImageLoader.shared
        var tiles: [(OrganizeStack, TileGradeMark)] = []
        let tileLooks: [GradeLook] = [.none, .builtIn(.softFilm), .none, .builtIn(.brightAiry), .none, .builtIn(.tealOrange), .none, .none]
        for (index, clip) in clips.prefix(8).enumerated() {
            let profile = clip.profile ?? .sLog3SGamut3Cine
            let look = tileLooks[index % tileLooks.count]
            let mark: TileGradeMark = index % 4 == 2
                ? .flatLog(profile)
                : .graded(GradeRecipe(grade: ClipGrade(look: look, intensity: look.defaultIntensity), profile: profile, conversion: .builtIn, range: clip.range))
            for size in [384, 512, 768] {
                _ = await loader.image(for: clip.url, maximumPixelSize: size, orientation: nil, grade: mark.recipe)
            }
            tiles.append((OrganizeStack(items: [clip.item]), mark))
        }
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            try save(TileGridMock(tiles: tiles), size: CGSize(width: 980, height: 430), name: "5-tiles-\(suffix)", appearance: appearance)
        }

        // Settings › Color with a conversion LUT and a look LUT imported.
        let lutFolder = FileManager.default.temporaryDirectory.appendingPathComponent("GradeShots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: lutFolder) }
        try FileManager.default.createDirectory(at: lutFolder, withIntermediateDirectories: true)
        let library = LUTLibrary(folder: lutFolder.appendingPathComponent("LUTs"))
        let identity = (0..<8).map { i in SIMD3(Double(i & 1), Double((i >> 1) & 1), Double((i >> 2) & 1)) }
        for name in ["D-Log M to Rec.709", "Film Print Look"] {
            let file = lutFolder.appendingPathComponent("\(name).cube")
            try Data(CubeLUT.write3D(title: name, size: 2, values: identity).utf8).write(to: file)
            try library.importLUT(from: file)
        }
        let root = lutFolder
        let configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Demo").path, importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path, bufferPath: root.appendingPathComponent("Buffer").path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path
        )
        let model = DashboardModel(jobs: [], configuration: configuration, configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json")))
        model.updateConfiguration { $0.gradeDefaults.setLook(.builtIn(.softFilm), for: .sLog3SGamut3Cine) }
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            try save(
                ColorSettingsPane(model: model, library: library).formStyle(.grouped),
                size: SettingsPane.color.contentSize, name: "6-settings-color-\(suffix)", appearance: appearance
            )
        }
    }

    // MARK: Helpers

    private func frame(of url: URL, at seconds: Double, width: CGFloat) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        return try await generator.image(at: CMTime(seconds: min(seconds, duration / 2), preferredTimescale: 600)).image
    }

    private static func split(before: CGImage, after: CGImage, at fraction: Double) -> CGImage? {
        let a = CIImage(cgImage: before, options: [.colorSpace: NSNull()])
        let b = CIImage(cgImage: after, options: [.colorSpace: NSNull()])
        let x = a.extent.width * fraction
        let left = a.cropped(to: CGRect(x: 0, y: 0, width: x, height: a.extent.height))
        let right = b.cropped(to: CGRect(x: x, y: 0, width: a.extent.width - x, height: a.extent.height))
        return GradeRenderer.shared.render(right.composited(over: left), extent: a.extent)
    }

    private func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Draws `view` in an offscreen window (so AppKit-backed controls draw
    /// too) and writes a PNG at 2×.
    private func save<V: View>(_ view: V, size: CGSize, name: String, appearance: NSAppearance.Name) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        // Grouped forms lay their rows out over a few passes.
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            host.display()
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("\(name).png"))
        window.contentView = nil
    }
}

/// The preview overlay's grading layout with a still in place of the
/// player (an `AVPlayerView` cannot be drawn offscreen): the same panel,
/// look strip and wipe the overlay shows.
private struct GradeScreenMock: View {
    let session: GradeSession
    let picture: CGImage
    let clipName: String
    let showWipe: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.95)
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.backward")
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clipName).font(.headline)
                        Text("Nov 7, 2026 at 8:08 PM · item 5 of 12 · Originals/A7V")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        ForEach(["camera.filters", "info", "rotate.right", "arrow.up.forward.app"], id: \.self) { symbol in
                            Image(systemName: symbol)
                                .frame(width: 34, height: 34)
                                .background(symbol == "camera.filters" ? Color.accentColor.opacity(0.85) : .white.opacity(0.12), in: Circle())
                        }
                    }
                }
                .foregroundStyle(.white)
                HStack(spacing: 12) {
                    ZStack {
                        Color.black
                        Image(decorative: picture, scale: 1)
                            .resizable()
                            .scaledToFit()
                        if showWipe {
                            GradeWipeOverlay(wipe: .constant(session.wipe), videoSize: CGSize(width: picture.width, height: picture.height))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    GradePanel(
                        session: session, canPaste: true,
                        onCopy: {}, onPaste: {}, onRemove: {}, onMarkProfile: { _ in }, onRender: {},
                        renderNote: "Writes \(GradedRenderNaming.candidateName(forSource: URL(fileURLWithPath: "/\(clipName)"), attempt: 1)) into the event’s Edited/Rec709. The original is never changed."
                    )
                    .frame(width: 290)
                    .foregroundStyle(.white, .white.opacity(0.65), .white.opacity(0.45))
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 18))
                }
                GradeLookStrip(
                    looks: session.looks, selected: session.draft.look, thumbnails: session.lookThumbnails,
                    name: session.lookName, onChoose: { _ in }
                )
                .frame(maxWidth: CGFloat(session.looks.count) * 142 + 20)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(16)
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct TileGridMock: View {
    let tiles: [(OrganizeStack, TileGradeMark)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trip 2026 · 8 clips")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(220), spacing: 16), count: 4), alignment: .leading, spacing: 16) {
                ForEach(tiles.indices, id: \.self) { index in
                    StackTileView(
                        stack: tiles[index].0, width: 220, isSelected: index == 1, isFocused: false,
                        event: nil, isMixed: false, isDimmed: false, badge: nil,
                        gradeMark: tiles[index].1
                    )
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
