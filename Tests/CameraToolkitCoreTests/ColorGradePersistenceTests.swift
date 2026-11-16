@testable import CameraToolkitCore
import Foundation
import GRDB
import XCTest

/// Grades are data in the catalog (like display rotations), the schema
/// change only adds a table, and the other pieces — detection, LUT
/// library, render naming, the sync planner — behave.
final class ColorGradePersistenceTests: XCTestCase {
    // MARK: Model

    func testGradeJSONRoundTripsExactlyAndToleratesMissingFields() throws {
        var grade = ClipGrade(conversion: .lut("fedcba9876543210"), look: .lut("0123456789abcdef"), intensity: 0.65, exposure: 0.333333, temperature: -12.5, tint: 3, contrast: 20, saturation: -7, profileMark: .marked(.djiDLogM))
        grade.clamp()
        XCTAssertEqual(ClipGrade.fromCatalogJSON(grade.catalogJSON()), grade)
        let looked = ClipGrade(look: .builtIn(.softFilm), intensity: 0.75)
        XCTAssertEqual(ClipGrade.fromCatalogJSON(looked.catalogJSON()), looked)
        // A first-build grade ("rec709" look) reads as: default conversion, no look.
        XCTAssertEqual(ClipGrade.fromCatalogJSON(#"{"look":{"kind":"rec709"}}"#), ClipGrade.converted)
        XCTAssertFalse(ClipGrade.converted.catalogJSON().contains("conversion"), "the default conversion is not written")
        XCTAssertEqual(ClipGrade.fromCatalogJSON(#"{"look":{"kind":"from-the-future"},"exposure":99}"#)?.exposure, 4, "clamped")
        XCTAssertNil(ClipGrade.fromCatalogJSON("not json"))
        XCTAssertTrue(ClipGrade().isDefault)
        XCTAssertFalse(looked.isDefault)
        XCTAssertTrue(ClipGrade(look: .builtIn(.moodyMatte), intensity: 0).isDefault)
        XCTAssertFalse(ClipGrade(conversion: .off).isDefault)
        // Defaults: a first-build "rec709" default look is dropped.
        let legacy = try JSONDecoder().decode(GradeDefaults.self, from: Data(#"{"lookByProfile":{"s-log3/s-gamut3-cine":{"kind":"rec709"}}}"#.utf8))
        XCTAssertTrue(legacy.isEmpty)
    }

    func testConfigurationKeepsGradesWithTheCatalogOwnedStateAndDefaultsWithSettings() throws {
        try withTemporaryDirectory { root in
            var configuration = AppConfiguration.testConfiguration(root: root, catalog: root.appendingPathComponent("catalog.sqlite"))
            let plain = try JSONEncoder().encode(configuration)
            XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("colorGrades"), "nothing written while there are none")
            configuration.colorGrades["clip|1|2"] = ClipGrade(look: .builtIn(.softFilm))
            configuration.gradeDefaults.setLook(.builtIn(.brightAiry), for: .sLog3SGamut3Cine)
            configuration.gradeDefaults.setConversion(.lut("0123456789abcdef"), for: .sLog3SGamut3Cine)
            configuration.renderGradedCopiesBeforeSync = true

            let full = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
            XCTAssertEqual(full.colorGrades, configuration.colorGrades)
            XCTAssertEqual(full.gradeDefaults, configuration.gradeDefaults)
            XCTAssertTrue(full.renderGradedCopiesBeforeSync)

            let encoder = JSONEncoder()
            encoder.userInfo[AppConfiguration.settingsOnlyUserInfoKey] = true
            let settings = try JSONDecoder().decode(AppConfiguration.self, from: encoder.encode(configuration))
            XCTAssertTrue(settings.colorGrades.isEmpty, "grades live in the catalog, not config.json")
            XCTAssertEqual(settings.gradeDefaults, configuration.gradeDefaults, "defaults are settings")

            XCTAssertEqual(CatalogOwnedState(configuration: configuration).colorGrades, configuration.colorGrades)
            var applied = AppConfiguration.testConfiguration(root: root, catalog: root.appendingPathComponent("catalog.sqlite"))
            CatalogOwnedState(configuration: configuration).apply(to: &applied)
            XCTAssertEqual(applied.colorGrades, configuration.colorGrades)
        }
    }

    // MARK: Catalog

    private func freshCatalog(_ root: URL) throws -> (URL, CatalogOwnedState) {
        let catalog = root.appendingPathComponent("CameraToolkit/catalog.sqlite")
        let outcome = CatalogStateStartup.resolve(
            configurationURL: root.appendingPathComponent("CameraToolkit/config.json"),
            defaults: .testConfiguration(root: root, catalog: catalog),
            backups: { url in
                CatalogBackupService(catalogURL: url, configurationURL: nil, localFolder: root.appendingPathComponent("Backups"), remoteFolder: nil)
            }
        )
        guard case .catalog(let baseline) = outcome.mode else {
            XCTFail("expected catalog mode")
            return (catalog, CatalogOwnedState())
        }
        return (catalog, baseline)
    }

    func testGradesWriteOnlyChangedRowsAndReadBack() throws {
        try withTemporaryDirectory { root in
            let (catalog, baseline) = try freshCatalog(root)
            let store = CatalogStateStore(url: catalog)
            var next = baseline
            next.colorGrades["a|1|1"] = ClipGrade(look: .builtIn(.tealOrange))
            next.colorGrades["b|2|2"] = ClipGrade(look: .none, exposure: -0.5, profileMark: .notLog)
            var summary = try store.apply(from: baseline, to: next)
            XCTAssertEqual(summary.colorGradesWritten, 2)
            XCTAssertEqual(try store.load().colorGrades, next.colorGrades)

            var edited = next
            edited.colorGrades["a|1|1"]?.intensity = 0.4
            edited.colorGrades["b|2|2"] = nil
            summary = try store.apply(from: next, to: edited)
            XCTAssertEqual(summary.colorGradesWritten, 1)
            XCTAssertEqual(summary.colorGradesDeleted, 1)
            XCTAssertEqual(summary.orientationsWritten + summary.assignmentsWritten + summary.eventsWritten, 0, "nothing else touched")
            XCTAssertEqual(try store.load().colorGrades, edited.colorGrades)
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testUnreadableGradeRowIsSkippedNotFatal() throws {
        try withTemporaryDirectory { root in
            let (catalog, baseline) = try freshCatalog(root)
            try CatalogDatabase.writer(for: catalog).write { db in
                try db.execute(sql: "INSERT INTO color_grades(file_key, grade, updated_at) VALUES ('x|1|1', 'garbage', 'now')")
            }
            let loaded = try CatalogStateStore(url: catalog).load()
            XCTAssertEqual(loaded.colorGrades, [:])
            XCTAssertEqual(loaded.savedEvents, baseline.savedEvents)
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    /// An existing catalog from before grades: preparing the schema adds the
    /// table and changes nothing else.
    func testSchemaMigrationOnlyAddsTheGradesTable() throws {
        try withTemporaryDirectory { root in
            let (catalog, _) = try freshCatalog(root)
            var next = CatalogOwnedState()
            next.displayOrientations["r|1|1"] = 1
            try CatalogStateStore(url: catalog).apply(from: CatalogOwnedState(), to: next)
            // Make it look like an older catalog.
            try CatalogDatabase.writer(for: catalog).write { db in
                try db.execute(sql: "DROP TABLE color_grades")
            }
            func schema() throws -> [String: String] {
                try CatalogDatabase.writer(for: catalog).read { db in
                    Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL").map {
                        ($0["name"] as String, $0["sql"] as String)
                    })
                }
            }
            let before = try schema()
            XCTAssertNil(before["color_grades"])
            CatalogDatabase.checkpointAndClose(url: catalog)

            try CatalogStore(url: catalog).prepareSchema()
            let after = try schema()
            XCTAssertNotNil(after["color_grades"])
            var withoutNew = after
            withoutNew["color_grades"] = nil
            withoutNew = withoutNew.filter { !$0.key.hasPrefix("sqlite_autoindex_color_grades") }
            XCTAssertEqual(withoutNew, before, "every other table and index is exactly as it was")
            XCTAssertEqual(try CatalogStateStore(url: catalog).load().displayOrientations, next.displayOrientations)
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    // MARK: Detection

    private let sonySidecar = """
    <?xml version="1.0" encoding="UTF-8"?>
    <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20">
        <Device manufacturer="Sony" modelName="ILCE-7M5" serialNo="0"/>
        <AcquisitionRecord>
            <Group name="CameraUnitMetadataSet">
                <Item name="CaptureGammaEquation" value="s-log3-cine"/>
                <Item name="CaptureColorPrimaries" value="s-gamut3-cine"/>
                <Item name="CodingEquations" value="rec709"/>
            </Group>
        </AcquisitionRecord>
    </NonRealTimeMeta>
    """

    func testDetectsSonyLogProfilesFromTheSidecar() {
        XCTAssertEqual(LogProfileDetector.profile(sonySidecarXML: sonySidecar), .sLog3SGamut3Cine)
        let sGamut3 = sonySidecar.replacingOccurrences(of: "value=\"s-gamut3-cine\"", with: "value=\"s-gamut3\"")
            .replacingOccurrences(of: "s-log3-cine", with: "s-log3")
        XCTAssertEqual(LogProfileDetector.profile(sonySidecarXML: sGamut3), .sLog3SGamut3)
        // Attribute order and quotes vary by firmware.
        XCTAssertEqual(LogProfileDetector.profile(sonySidecarXML: "<Item value='S-Log3-Cine'  name = 'CaptureGammaEquation'/>"), .sLog3SGamut3Cine)
        let rec709 = sonySidecar.replacingOccurrences(of: "s-log3-cine", with: "rec709")
        XCTAssertNil(LogProfileDetector.profile(sonySidecarXML: rec709))
        XCTAssertNil(LogProfileDetector.profile(sonySidecarXML: sonySidecar.replacingOccurrences(of: "s-log3-cine", with: "rec2100-hlg")))
        XCTAssertNil(LogProfileDetector.profile(sonySidecarXML: sonySidecar.replacingOccurrences(of: "s-log3-cine", with: "s-log2")))
        XCTAssertNil(LogProfileDetector.profile(sonySidecarXML: "<xml/>"))
        let device = LogProfileDetector.sonyDevice(sidecarXML: sonySidecar)
        XCTAssertEqual(device?.make, "Sony")
        XCTAssertEqual(device?.model, "ILCE-7M5")
    }

    func testDetectionReadsTheClipsCompanionFile() throws {
        try withTemporaryDirectory { root in
            let clip = root.appendingPathComponent("C0001.MP4")
            let xml = root.appendingPathComponent("C0001M01.XML")
            try Data("x".utf8).write(to: clip)
            try Data(sonySidecar.utf8).write(to: xml)
            XCTAssertEqual(LogProfileDetector.profile(clip: clip, companions: [xml]), .sLog3SGamut3Cine)
            XCTAssertEqual(LogProfileDetector.profile(clipBesideSidecar: clip), .sLog3SGamut3Cine)
            XCTAssertNil(LogProfileDetector.profile(clip: clip, companions: []))
            XCTAssertNil(LogProfileDetector.profile(clip: root.appendingPathComponent("DSC00001.JPG"), companions: [xml]), "only clips")
        }
    }

    func testProfileMarksOverrideDetection() {
        XCTAssertEqual(ClipProfileMark.detected.resolve(detected: .sLog3SGamut3Cine), .sLog3SGamut3Cine)
        XCTAssertEqual(ClipProfileMark.marked(.djiDLogM).resolve(detected: nil), .djiDLogM)
        XCTAssertNil(ClipProfileMark.notLog.resolve(detected: .sLog3SGamut3Cine))
    }

    // MARK: Roles and resolution

    func testLUTRolesAreInferredFromSonyAndDJINames() {
        XCTAssertEqual(LUTRole.inferred(fromName: "Slog3-S-Gamut3.Cine_To_s709_V200.cube"), .conversion(.sLog3SGamut3Cine))
        XCTAssertEqual(LUTRole.inferred(fromName: "SLog3SGamut3.CineToLC-709.cube"), .conversion(.sLog3SGamut3Cine))
        XCTAssertEqual(LUTRole.inferred(fromName: "SL3SG3CtoTealOR_709.cube"), .conversion(.sLog3SGamut3Cine), "a creative log-in LUT is a conversion")
        XCTAssertEqual(LUTRole.inferred(fromName: "SLog3SGamut3To709.cube"), .conversion(.sLog3SGamut3))
        XCTAssertEqual(LUTRole.inferred(fromName: "DJI OSMO D-Log M to Rec.709 V1.cube"), .conversion(.djiDLogM))
        XCTAssertEqual(LUTRole.inferred(fromName: "Warm Film.cube"), .look)
        XCTAssertEqual(LUTRole.inferred(fromName: "sv2_look_1_r709_g24.cube"), .look)
    }

    func testResolverPicksTheConversionAndRefusesWrongStacks() {
        var defaults = GradeDefaults()
        let roles: [String: LUTRole] = ["sony": .conversion(.sLog3SGamut3Cine), "film": .look, "dji": .conversion(.djiDLogM)]
        var resolver = GradeResolver(defaults: defaults, lutRoles: roles)
        XCTAssertEqual(resolver.conversion(for: ClipGrade(), profile: .sLog3SGamut3Cine), .builtIn, "built-in until Sony's LUT is the default")
        defaults.setConversion(.lut("sony"), for: .sLog3SGamut3Cine)
        resolver.defaults = defaults
        XCTAssertEqual(resolver.conversion(for: ClipGrade(), profile: .sLog3SGamut3Cine), .lut("sony"))
        XCTAssertEqual(resolver.conversion(for: ClipGrade(conversion: .builtIn), profile: .sLog3SGamut3Cine), .builtIn, "a clip can choose")
        XCTAssertEqual(resolver.conversion(for: ClipGrade(conversion: .lut("dji")), profile: .sLog3SGamut3Cine), .builtIn, "a D-Log M LUT never converts S-Log3")
        XCTAssertEqual(resolver.conversion(for: ClipGrade(conversion: .lut("film")), profile: .sLog3SGamut3Cine), .builtIn, "a look LUT never converts")
        XCTAssertEqual(resolver.conversion(for: ClipGrade(), profile: .djiDLogM), ResolvedConversion.none)
        XCTAssertNil(resolver.recipe(explicit: nil, detected: nil, range: .video), "plain video, nothing set: nothing to draw")
        // A conversion LUT chosen as a look is dropped, never stacked.
        let wrong = resolver.recipe(explicit: ClipGrade(look: .lut("sony")), detected: .sLog3SGamut3Cine, range: .full)
        XCTAssertEqual(wrong?.grade.look, GradeLook.none)
        XCTAssertEqual(resolver.recipe(explicit: ClipGrade(look: .lut("film")), detected: .sLog3SGamut3Cine, range: .full)?.grade.look, .lut("film"))
        // The default look starts at its own intensity.
        defaults.setLook(.builtIn(.softFilm), for: .sLog3SGamut3Cine)
        resolver.defaults = defaults
        let defaulted = resolver.recipe(explicit: nil, detected: .sLog3SGamut3Cine, range: .full)
        XCTAssertEqual(defaulted?.grade.look, .builtIn(.softFilm))
        XCTAssertEqual(defaulted?.grade.intensity, BuiltInLook.softFilm.defaultIntensity)
    }

    func testSonyArchiveImportsAsTheS709Conversion() throws {
        try withTemporaryDirectory { root in
            let content = root.appendingPathComponent("pack/Slog3-S-Gamut3.Cine_To_s709_V200", isDirectory: true)
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
            try Data("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8)
                .write(to: content.appendingPathComponent("Slog3-S-Gamut3.Cine_To_s709_V200.cube"))
            try Data("x".utf8).write(to: content.appendingPathComponent("._Slog3-S-Gamut3.Cine_To_s709_V200.cube"))
            let zip = root.appendingPathComponent("sony.zip")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--sequesterRsrc", root.appendingPathComponent("pack").path, zip.path]
            try ditto.run()
            ditto.waitUntilExit()
            let library = LUTLibrary(folder: root.appendingPathComponent("LUTs"))
            let result = try SonyConversionLUTs.importArchive(at: zip, into: library, scratch: root)
            XCTAssertEqual(result.imported.count, 1, "the AppleDouble twin is skipped")
            XCTAssertEqual(result.s709?.role, .conversion(.sLog3SGamut3Cine))

            let notZip = root.appendingPathComponent("page.zip")
            try Data("<html>".utf8).write(to: notZip)
            XCTAssertThrowsError(try SonyConversionLUTs.importArchive(at: notZip, into: library, scratch: root)) {
                XCTAssertEqual($0 as? SonyConversionLUTs.Failure, .notAZip)
            }
            XCTAssertEqual(SonyConversionLUTs.s709Archive.scheme, "https")
        }
    }

    // MARK: LUT library

    func testLUTLibraryImportsChecksDeduplicatesAndRemoves() throws {
        try withTemporaryDirectory { root in
            let library = LUTLibrary(folder: root.appendingPathComponent("Support/LUTs"))
            let source = root.appendingPathComponent("My Look.cube")
            try Data("TITLE \"Warm Film\"\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n".utf8).write(to: source)
            let entry = try library.importLUT(from: source)
            XCTAssertEqual(entry.name, "Warm Film")
            XCTAssertEqual(entry.id.count, 16)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the original stays")
            XCTAssertEqual(try library.importLUT(from: source), entry, "same file, same entry")
            XCTAssertEqual(library.list().count, 1)
            XCTAssertNotNil(library.lut(id: entry.id))
            XCTAssertNotNil(LUTLibrary(folder: library.folder).lut(id: entry.id), "survives a relaunch")

            let broken = root.appendingPathComponent("broken.cube")
            try Data("LUT_3D_SIZE 2\n0 0 0\n".utf8).write(to: broken)
            XCTAssertThrowsError(try library.importLUT(from: broken))
            XCTAssertEqual(library.list().count, 1, "a broken file is not added")

            try library.rename(id: entry.id, to: "Film")
            XCTAssertEqual(library.entry(id: entry.id)?.name, "Film")
            try library.remove(id: entry.id)
            XCTAssertTrue(library.list().isEmpty)
            XCTAssertNil(library.lut(id: entry.id))
        }
    }

    // MARK: Render naming

    func testRenderNamesNeverReplaceAFile() {
        let source = URL(fileURLWithPath: "/Volumes/Buffer/2026/Trip/Originals/A7V/C0001.MP4")
        let folder = URL(fileURLWithPath: "/Volumes/Buffer/2026/Trip/Edited/Rec709")
        XCTAssertEqual(GradedRenderNaming.candidateName(forSource: source, attempt: 1), "C0001_709.mov")
        XCTAssertEqual(GradedRenderNaming.candidateName(forSource: source, attempt: 3), "C0001_709 (3).mov")

        var taken: Set<String> = []
        func resolve(same: Set<String> = [], older: Set<String> = [], mirror: URL? = nil) -> GradedRenderNaming.Resolution {
            GradedRenderNaming.resolve(
                source: source, folder: folder, mirror: mirror,
                exists: { taken.contains($0.path) },
                identity: { same.contains($0.path) ? .same : older.contains($0.path) ? .olderGrade : .other }
            )
        }
        func at(_ name: String, _ base: URL = folder) -> URL { base.appendingPathComponent(name) }
        XCTAssertEqual(resolve(), .free(at("C0001_709.mov"), beside: []))
        taken = [at("C0001_709.mov").path]
        XCTAssertEqual(resolve(), .free(at("C0001_709 (2).mov"), beside: []), "a different file there: next free name")
        XCTAssertEqual(resolve(older: taken), .free(at("C0001_709 (2).mov"), beside: [at("C0001_709.mov")]), "an older grade is reported and kept")
        XCTAssertEqual(resolve(same: taken), .alreadyRendered(at("C0001_709.mov")), "the same render there: skip")
        taken = [at("C0001_709.mov").path, at("C0001_709 (2).mov").path]
        XCTAssertEqual(resolve(same: [at("C0001_709 (2).mov").path]), .alreadyRendered(at("C0001_709 (2).mov")))
        XCTAssertEqual(GradedRenderNaming.resolve(source: source, folder: folder, exists: { _ in true }, identity: { _ in .other }, maximumAttempts: 5), .exhausted)

        // The NAS mirror: its names are taken too, and its copy counts.
        let nas = URL(fileURLWithPath: "/Volumes/nas_share/2026/Trip/Edited/Rec709")
        taken = [at("C0001_709.mov", nas).path]
        XCTAssertEqual(resolve(mirror: nas), .free(at("C0001_709 (2).mov"), beside: []), "never a name the NAS already holds")
        XCTAssertEqual(resolve(same: taken, mirror: nas), .alreadyRendered(at("C0001_709.mov", nas)))

        XCTAssertTrue(GradedRenderNaming.isGradedCopy(folder.appendingPathComponent("C0001_709.mov")))
        XCTAssertTrue(GradedRenderNaming.isGradedCopy(folder.appendingPathComponent("C0001_709 (2).mov")))
        XCTAssertFalse(GradedRenderNaming.isGradedCopy(source))
        XCTAssertFalse(GradedRenderNaming.isGradedCopy(folder.appendingPathComponent("IMG_0709.MOV")))
        XCTAssertEqual(GradedRenderNaming.outputFolder(editedRoot: URL(fileURLWithPath: "/E")).path, "/E/Rec709")
    }

    func testGradedCopiesLinkToTheirOriginalAsAnEdit() {
        XCTAssertEqual(EditTagLinker.stem(of: "C0001_709.mov"), "c0001")
        XCTAssertEqual(EditTagLinker.stem(of: "C0001_709 (2).mov"), "c0001")
        XCTAssertEqual(EditTagLinker.stem(of: "IMG_0709.MOV"), "img_0709", "a camera number is not a suffix")
    }

    func testOneUnreadableGradeInConfigKeepsTheRest() throws {
        try withTemporaryDirectory { root in
            var configuration = AppConfiguration.testConfiguration(root: root, catalog: root.appendingPathComponent("catalog.sqlite"))
            configuration.colorGrades = ["good|1|1": ClipGrade(look: .builtIn(.richVivid)), "also|2|2": ClipGrade(exposure: 1)]
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as! [String: Any]
            var grades = json["colorGrades"] as! [String: Any]
            grades["broken|3|3"] = 42
            json["colorGrades"] = grades
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.colorGrades, configuration.colorGrades)
        }
    }

    // MARK: Sync and partials

    /// A partial a crashed render left must never reach the NAS, nor be
    /// taken for an edit.
    func testSyncAndTheEditScanIgnoreALeftoverPartial() throws {
        try withTemporaryDirectory { root in
            var configuration = AppConfiguration.testConfiguration(root: root, catalog: root.appendingPathComponent("catalog.sqlite"))
            let event = SavedCameraEvent(name: "Beach Day", eventDate: Date(timeIntervalSince1970: 1_780_000_000))
            configuration.savedEvents = [event]
            let locations = EventStorageLocations(configuration: configuration)
            let eventFolder = locations.eventFolder(for: event, policy: .buffer)
            let output = GradedRenderNaming.outputFolder(editedRoot: locations.editedRoot(for: event, policy: .buffer))
            let temporary = output.appendingPathComponent(GradedRenderNaming.temporaryFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 64).write(to: temporary.appendingPathComponent(GradedRenderNaming.partialName()))
            try Data(repeating: 0, count: 64).write(to: output.appendingPathComponent("C0001_709.mov"))

            let plan = NASSyncPlanner.plan(events: [event], locations: locations, checkLegacyLayout: false)
            XCTAssertEqual(plan.items.map { ($0.relativePath as NSString).lastPathComponent }, ["C0001_709.mov"], "only the finished copy is synced")
            XCTAssertTrue(plan.refused.isEmpty)

            let edits = EditTagLinker.editedFiles(eventFolders: [eventFolder])
            XCTAssertEqual(edits.map(\.name), ["C0001_709.mov"])
            XCTAssertEqual(edits.first?.tag, "Rec709")
        }
    }

    // MARK: Sync planner

    func testSyncPlannerRendersOnlyGradedLogClipsOnTheDrive() throws {
        try withTemporaryDirectory { root in
            var configuration = AppConfiguration.testConfiguration(root: root, catalog: root.appendingPathComponent("catalog.sqlite"))
            let event = SavedCameraEvent(name: "Beach Day", eventDate: Date(timeIntervalSince1970: 1_780_000_000))
            configuration.savedEvents = [event]
            let locations = EventStorageLocations(configuration: configuration)
            let date = Date(timeIntervalSince1970: 1_780_000_100)
            func assignment(_ name: String) -> PhotoEventAssignment {
                PhotoEventAssignment(sourceRootPath: root.appendingPathComponent("Card").path, relativePath: name, fileSize: 10, modifiedAt: date, eventID: event.id, deviceID: "sony-a7v")
            }
            let names = ["C0001.MP4", "C0002.MP4", "C0003.MP4", "DSC00001.ARW", "C0004.MP4"]
            let assignments = names.map(assignment)
            let key: (String) -> String = { FaceIndexStore.fileKey(fileName: $0, byteCount: 10, modifiedAt: date) }
            var grades: [String: ClipGrade] = [:]
            grades[key("C0002.MP4")] = ClipGrade(look: .none, exposure: 0.5) // its own grade
            grades[key("C0003.MP4")] = ClipGrade(profileMark: .notLog)     // marked not log
            var defaults = GradeDefaults()
            defaults.setLook(.builtIn(.softFilm), for: .sLog3SGamut3Cine)
            let inputs = GradedSyncPlanner.Inputs(
                events: [event], assignments: assignments, locations: locations, policy: { _ in .buffer },
                grades: grades, resolver: GradeResolver(defaults: defaults, lutRoles: [:])
            )
            let requests = GradedSyncPlanner.requests(
                inputs,
                fileExists: { $0.lastPathComponent != "C0004.MP4" }, // not on the drive
                detect: { _ in .sLog3SGamut3Cine },
                range: { _ in .full }
            )
            XCTAssertEqual(requests.map(\.source.lastPathComponent), ["C0001.MP4", "C0002.MP4"])
            XCTAssertEqual(requests[0].recipe.grade.look, .builtIn(.softFilm), "the default look, on the conversion")
            XCTAssertEqual(requests[0].recipe.conversion, .builtIn)
            XCTAssertEqual(requests[1].recipe.grade.exposure, 0.5, "its own grade")
            XCTAssertTrue(requests.allSatisfy { $0.outputFolder.path.hasSuffix("/Edited/Rec709") })
            XCTAssertTrue(requests.allSatisfy { $0.outputFolder.path.hasPrefix(locations.eventFolder(for: event, policy: .buffer).path) })
            XCTAssertTrue(requests.allSatisfy { $0.mirrorFolder?.path.hasSuffix("/Edited/Rec709") == true }, "the NAS copy of the folder is checked too")

            // Conversion turned off and no look: nothing to render.
            var flat = GradeDefaults()
            flat.setConversion(.off, for: .sLog3SGamut3Cine)
            var bare = inputs
            bare.resolver = GradeResolver(defaults: flat, lutRoles: [:])
            bare.grades = [:]
            XCTAssertTrue(GradedSyncPlanner.requests(bare, fileExists: { _ in true }, detect: { _ in .sLog3SGamut3Cine }, range: { _ in .full }).isEmpty)
        }
    }
}
