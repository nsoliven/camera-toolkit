import CameraToolkitCore
import Foundation
import XCTest

final class OrganizeCameraTests: XCTestCase {
    // MARK: - Make/Model mapping

    func testKnownBodiesMapToDeviceIDsAndFriendlyNames() {
        XCTAssertEqual(CameraCatalog.camera(make: "SONY", model: "ILCE-7M5"), OrganizeCamera(id: "sony-a7v", name: "Sony A7V"))
        XCTAssertEqual(CameraCatalog.camera(make: "DJI", model: "Osmo 360"), OrganizeCamera(id: "osmo-360", name: "Osmo 360"))
        XCTAssertEqual(CameraCatalog.camera(make: nil, model: "Osmo 360")?.id, "osmo-360")
        // DJI's Nano clips name the camera only in the software tag.
        XCTAssertEqual(CameraCatalog.camera(make: nil, model: "DJI Osmo Nano"), OrganizeCamera(id: "dji-nano", name: "Osmo Nano"))
        XCTAssertEqual(CameraCatalog.camera(make: "DJI", model: "Osmo Nano")?.id, "dji-nano")
        XCTAssertEqual(CameraCatalog.camera(make: "DJI", model: "FC7303")?.name, "DJI Mini 2")
        XCTAssertEqual(CameraCatalog.camera(make: "DJI", model: "Osmo Action 6")?.id, "action-6")
        // EXIF writers pad with NULs and spaces.
        XCTAssertEqual(CameraCatalog.camera(make: "SONY\0\0", model: " ILCE-7M5 \0")?.id, "sony-a7v")
    }

    func testUnknownModelsGroupUnderTheirRawModelString() {
        let phone = CameraCatalog.camera(make: "Apple", model: "iPhone 16 Pro")
        XCTAssertEqual(phone, OrganizeCamera(id: "model:iPhone 16 Pro", name: "iPhone 16 Pro"))
        let other = CameraCatalog.camera(make: "SONY", model: "ILCE-7M4")
        XCTAssertEqual(other?.name, "ILCE-7M4")
        XCTAssertNotEqual(other?.id, "sony-a7v")
        // Two files of the same unknown model share one value.
        XCTAssertEqual(CameraCatalog.camera(make: "Canon", model: "Canon EOS R5"), CameraCatalog.camera(make: "Canon", model: "Canon EOS R5"))
        // A make alone cannot tell bodies apart.
        XCTAssertNil(CameraCatalog.camera(make: "SONY", model: nil))
        XCTAssertNil(CameraCatalog.camera(make: nil, model: "  "))
        // Ids a filter row holds turn back into names for its labels.
        XCTAssertEqual(CameraCatalog.camera(id: "model:iPhone 16 Pro").name, "iPhone 16 Pro")
        XCTAssertEqual(CameraCatalog.camera(id: "sony-a7v").name, "Sony A7V")
        XCTAssertEqual(CameraCatalog.camera(id: OrganizeCamera.unknownID), .unknown)
    }

    func testDeviceIDsMapToCamerasAndGenericFallsThrough() {
        XCTAssertEqual(CameraCatalog.camera(deviceID: "dji-nano")?.name, "Osmo Nano")
        XCTAssertEqual(CameraCatalog.camera(deviceID: "iphone")?.name, "iPhone")
        XCTAssertEqual(CameraCatalog.camera(deviceID: "Hand Named Body"), OrganizeCamera(id: "Hand Named Body", name: "Hand Named Body"))
        XCTAssertNil(CameraCatalog.camera(deviceID: "generic-camera"))
        XCTAssertNil(CameraCatalog.camera(deviceID: nil))
        XCTAssertNil(CameraCatalog.camera(deviceID: ""))
    }

    // MARK: - Precedence

    func testAssignmentDeviceBeatsSourceLocationWhichBeatsFileTags() {
        let resolver = OrganizeCameraResolver(locations: [
            ConfiguredLocation(role: .importSource, name: "Card A", path: "/Volumes/CardA", deviceID: "osmo-360"),
            // Nested source: the longer root wins inside it.
            ConfiguredLocation(role: .importSource, name: "Inner", path: "/Volumes/CardA/Inner/", deviceID: "dji-mini-2"),
            // No explicit device: its name implies one.
            ConfiguredLocation(role: .importSource, name: "Nano Clips", path: "/Volumes/Drive/Nano Clips"),
            // Neither chosen nor implied — no location camera.
            ConfiguredLocation(role: .importSource, name: "Card B", path: "/Volumes/CardB"),
            // Only import sources say which camera shot a file.
            ConfiguredLocation(role: .buffer, name: "Buffer", path: "/Volumes/Drive/Buffer", deviceID: "sony-a7v"),
        ])
        let tags = CameraCatalog.camera(make: "Apple", model: "iPhone 16 Pro")
        func file(_ path: String) -> OrganizeFile { OrganizeFile(path: path, size: 1, modifiedAt: Date(timeIntervalSince1970: 0)) }

        let onCard = file("/Volumes/CardA/DCIM/CAM_0001.JPG")
        XCTAssertEqual(resolver.camera(assignmentDeviceID: "sony-a7v", file: onCard, metadataCamera: tags)?.id, "sony-a7v")
        XCTAssertEqual(resolver.camera(assignmentDeviceID: nil, file: onCard, metadataCamera: tags)?.id, "osmo-360")
        // "Other Camera" on the assignment says nothing — the location decides.
        XCTAssertEqual(resolver.camera(assignmentDeviceID: "generic-camera", file: onCard, metadataCamera: tags)?.id, "osmo-360")
        XCTAssertEqual(resolver.camera(assignmentDeviceID: nil, file: file("/Volumes/CardA/Inner/a.JPG"), metadataCamera: nil)?.id, "dji-mini-2")
        XCTAssertEqual(resolver.camera(assignmentDeviceID: nil, file: file("/Volumes/Drive/Nano Clips/x.MP4"), metadataCamera: nil)?.id, "dji-nano")
        // A sibling folder sharing the prefix is not inside the source.
        XCTAssertEqual(resolver.camera(assignmentDeviceID: nil, file: file("/Volumes/CardAB/a.JPG"), metadataCamera: tags), tags)
        XCTAssertEqual(resolver.camera(assignmentDeviceID: nil, file: file("/Volumes/CardB/a.JPG"), metadataCamera: tags), tags)
        XCTAssertEqual(resolver.camera(assignmentDeviceID: nil, file: file("/Volumes/Drive/Buffer/a.JPG"), metadataCamera: tags), tags)
        XCTAssertNil(resolver.camera(assignmentDeviceID: nil, file: file("/Volumes/CardB/b.JPG"), metadataCamera: nil))
    }

    // MARK: - Reading tags in the capture-date pass

    func testTIFFHeaderYieldsCaptureTimeAndCameraInOneRead() throws {
        try withTemporaryDirectory { root in
            let url = try writeFile(
                root.appendingPathComponent("DSC00001.ARW"),
                makeCameraTIFFHeader(make: "SONY", model: "ILCE-7M5", captureTime: "2026:08:27 05:27:53") + Data(repeating: 0xAB, count: 256)
            )
            let metadata = CaptureDateReader.metadata(of: url)
            XCTAssertEqual(metadata.timestamp?.original, "2026:08:27 05:27:53")
            XCTAssertEqual(metadata.camera, CameraMetadata(make: "SONY", model: "ILCE-7M5"))

            // Tags without a capture time still name the camera.
            let undated = try writeFile(
                root.appendingPathComponent("DSC00002.ARW"),
                makeCameraTIFFHeader(make: "SONY", model: "ILCE-7M5", captureTime: nil) + Data(repeating: 0xAB, count: 256)
            )
            XCTAssertNil(CaptureDateReader.metadata(of: undated).timestamp)
            XCTAssertEqual(CaptureDateReader.metadata(of: undated).camera?.model, "ILCE-7M5")

            // The existing timestamp-only header still reads, camera-less.
            let plain = try writeFakeARW(root.appendingPathComponent("DSC00003.ARW"), captureTime: "2026:08:27 05:27:53")
            XCTAssertNil(CaptureDateReader.metadata(of: plain).camera)
            XCTAssertNotNil(CaptureDateReader.metadata(of: plain).timestamp)
        }
    }

    func testClipTagsReadFromMovieBoxesAndSonyXML() throws {
        try withTemporaryDirectory { root in
            let nano = try writeFile(root.appendingPathComponent("DJI_0001_D.MP4"), makeClip(moov: [djiSoftwareUserData("DJI Osmo Nano")]))
            XCTAssertEqual(CaptureDateReader.metadata(of: nano).camera, CameraMetadata(model: "DJI Osmo Nano"))
            XCTAssertEqual(CameraCatalog.camera(metadata: CaptureDateReader.metadata(of: nano).camera)?.id, "dji-nano")

            let osmo = try writeFile(root.appendingPathComponent("CAM_0001_D.OSV"), makeClip(moov: [djiSoftwareUserData("Osmo 360")]))
            XCTAssertEqual(CameraCatalog.camera(metadata: CaptureDateReader.metadata(of: osmo).camera)?.id, "osmo-360")

            // An iPhone's software tag is an OS version, never a camera.
            let phone = try writeFile(root.appendingPathComponent("IMG_0001.MOV"), makeClip(moov: [appleKeysMeta([
                ("com.apple.quicktime.make", "Apple"),
                ("com.apple.quicktime.model", "iPhone 16 Pro"),
                ("com.apple.quicktime.software", "18.1"),
            ])]))
            XCTAssertEqual(CaptureDateReader.metadata(of: phone).camera, CameraMetadata(make: "Apple", model: "iPhone 16 Pro"))

            let classic = try writeFile(root.appendingPathComponent("MVI_0001.MOV"), makeClip(moov: [
                box("udta", textAtom("\u{A9}mak", "Canon") + textAtom("\u{A9}mod", "Canon EOS R5")),
            ]))
            XCTAssertEqual(CaptureDateReader.metadata(of: classic).camera, CameraMetadata(make: "Canon", model: "Canon EOS R5"))

            let sonyXML = #"<?xml version="1.0"?><NonRealTimeMeta><Device manufacturer="Sony" modelName="ILCE-7M5" serialNo="0"/></NonRealTimeMeta>"#
            let sony = try writeFile(root.appendingPathComponent("C0001.MP4"), makeClip(moov: [], trailing: box("meta", Data(sonyXML.utf8))))
            XCTAssertEqual(CameraCatalog.camera(metadata: CaptureDateReader.metadata(of: sony).camera)?.id, "sony-a7v")

            let untagged = try writeFile(root.appendingPathComponent("C0002.MP4"), makeClip(moov: []))
            XCTAssertNil(CaptureDateReader.metadata(of: untagged).camera)
            XCTAssertNil(CaptureDateReader.metadata(of: try writeFile(root.appendingPathComponent("junk.MP4"), Data("nope".utf8))).camera)
        }
    }

    func testScannerCarriesTagCamerasOnItemsForStillsAndClips() throws {
        try withTemporaryDirectory { root in
            let card = root.appendingPathComponent("Card", isDirectory: true)
            try writeFile(card.appendingPathComponent("DSC00001.ARW"), makeCameraTIFFHeader(make: "SONY", model: "ILCE-7M5", captureTime: "2026:08:27 05:27:53"))
            try writeFile(card.appendingPathComponent("DJI_0001_D.MP4"), makeClip(moov: [djiSoftwareUserData("DJI Osmo Nano")]))
            try writeFakeARW(card.appendingPathComponent("DSC00009.ARW"), captureTime: "2026:08:27 06:00:00")

            let cache = CaptureDateCache(url: root.appendingPathComponent("cache.json"))
            let result = try OrganizeScanner(concurrency: 2).scan(root: card, cache: cache)
            let byName = Dictionary(uniqueKeysWithValues: result.items.map { ($0.primary.name, $0) })
            XCTAssertEqual(byName["DSC00001.ARW"]?.metadataCamera?.id, "sony-a7v")
            XCTAssertTrue(byName["DSC00001.ARW"]?.hasCameraDate == true)
            XCTAssertEqual(byName["DJI_0001_D.MP4"]?.metadataCamera?.id, "dji-nano")
            // Clips still take the folder's clock offset, not a read date.
            XCTAssertEqual(byName["DJI_0001_D.MP4"]?.hasCameraDate, false)
            XCTAssertNil(byName["DSC00009.ARW"]?.metadataCamera)

            // A second pass answers from the cache without reading.
            let files = result.items.flatMap(\.files)
            let again = OrganizeScanner.items(for: files, cache: cache, readMissingCaptureDates: false)
            XCTAssertEqual(again.missingCaptureDates, 0)
            XCTAssertEqual(again.items.first { $0.primary.name == "DJI_0001_D.MP4" }?.metadataCamera?.id, "dji-nano")
        }
    }

    // MARK: - Cache format migration

    func testVersionOneCacheLoadsAndFillsCameraLazily() throws {
        try withTemporaryDirectory { root in
            let card = root.appendingPathComponent("Card", isDirectory: true)
            let modified = Date(timeIntervalSince1970: 1_800_000_000)
            let url = try writeFile(
                card.appendingPathComponent("DSC00001.ARW"),
                makeCameraTIFFHeader(make: "SONY", model: "ILCE-7M5", captureTime: "2026:08:27 05:27:53")
            )
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            let file = OrganizeFile(path: url.standardizedFileURL.path, size: Int64(try Data(contentsOf: url).count), modifiedAt: modified)

            // A cache file exactly as the timestamp-only version wrote it.
            let cacheURL = root.appendingPathComponent("capture-dates.json")
            let legacy: [String: Any] = [
                "version": 1,
                "entries": [
                    file.path: [
                        "size": file.size,
                        "modified": modified.timeIntervalSinceReferenceDate,
                        "timestamp": ["original": "2026:08:27 05:27:53"],
                    ],
                ],
            ]
            try JSONSerialization.data(withJSONObject: legacy).write(to: cacheURL)

            let cache = CaptureDateCache(url: cacheURL)
            let cached = try XCTUnwrap(cache.lookupMetadata(path: file.path, size: file.size, modifiedAt: modified))
            XCTAssertEqual(cached.timestamp?.original, "2026:08:27 05:27:53")
            XCTAssertFalse(cached.cameraRead)
            XCTAssertEqual(cache.lookup(path: file.path, size: file.size, modifiedAt: modified).flatMap { $0 }?.original, "2026:08:27 05:27:53")

            // A no-read pass paints from the cached date; the camera
            // stays unknown and no date counts as missing.
            let provisional = OrganizeScanner.items(for: [file], cache: cache, readMissingCaptureDates: false)
            XCTAssertEqual(provisional.missingCaptureDates, 0)
            XCTAssertTrue(provisional.items.first?.hasCameraDate == true)
            XCTAssertNil(provisional.items.first?.metadataCamera)

            // The next reading pass fills the camera in and upgrades the file.
            let filled = OrganizeScanner.items(for: [file], cache: cache)
            XCTAssertEqual(filled.missingCaptureDates, 0)
            XCTAssertEqual(filled.items.first?.metadataCamera?.id, "sony-a7v")
            let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
            XCTAssertEqual(stored?["version"] as? Int, CaptureDateCache.currentVersion)

            let reloaded = CaptureDateCache(url: cacheURL)
            let upgraded = try XCTUnwrap(reloaded.lookupMetadata(path: file.path, size: file.size, modifiedAt: modified))
            XCTAssertTrue(upgraded.cameraRead)
            XCTAssertEqual(upgraded.camera?.model, "ILCE-7M5")
            XCTAssertEqual(upgraded.timestamp?.original, "2026:08:27 05:27:53")
        }
    }

    func testCacheKeepsReadButEmptyCamerasAndIgnoresUnknownVersions() throws {
        try withTemporaryDirectory { root in
            let cacheURL = root.appendingPathComponent("capture-dates.json")
            let modified = Date(timeIntervalSince1970: 1_800_000_000)
            let cache = CaptureDateCache(url: cacheURL)
            cache.store(path: "/a.MP4", size: 5, modifiedAt: modified, metadata: CaptureMetadata())
            cache.store(path: "/b.ARW", size: 5, modifiedAt: modified, timestamp: nil)
            try cache.save()

            let reloaded = CaptureDateCache(url: cacheURL)
            // Read, found nothing: never re-read.
            XCTAssertEqual(reloaded.lookupMetadata(path: "/a.MP4", size: 5, modifiedAt: modified)?.cameraRead, true)
            XCTAssertNil(reloaded.lookupMetadata(path: "/a.MP4", size: 5, modifiedAt: modified)?.camera)
            // Timestamp-only store: the camera is still owed.
            XCTAssertEqual(reloaded.lookupMetadata(path: "/b.ARW", size: 5, modifiedAt: modified)?.cameraRead, false)

            try Data(#"{"version": 99, "entries": {}}"#.utf8).write(to: cacheURL)
            XCTAssertNil(CaptureDateCache(url: cacheURL).lookupMetadata(path: "/a.MP4", size: 5, modifiedAt: modified))
        }
    }

    // MARK: - Sort

    func testCameraSortOrdersByNameWithUnknownLast() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func stack(_ name: String, _ camera: OrganizeCamera?, at offset: TimeInterval) -> OrganizeStack {
            OrganizeStack(items: [OrganizeItem(
                primary: OrganizeFile(path: "/card/\(name)", size: 1, modifiedAt: base),
                kind: .raw,
                captureDate: base.addingTimeInterval(offset),
                hasCameraDate: true,
                metadataCamera: camera
            )])
        }
        let sony = stack("a.ARW", CameraCatalog.camera(deviceID: "sony-a7v"), at: 30)
        let osmo = stack("b.JPG", CameraCatalog.camera(deviceID: "osmo-360"), at: 20)
        let osmoEarlier = stack("c.JPG", CameraCatalog.camera(deviceID: "osmo-360"), at: 10)
        let unknown = stack("d.ARW", nil, at: 0)
        let stacks = [sony, unknown, osmo, osmoEarlier]

        let ascending = OrganizeStackSort(key: .camera)
        XCTAssertTrue(ascending.ascending)
        // Ties fall back to capture time.
        XCTAssertEqual(ascending.sorted(stacks).map(\.id), [osmoEarlier.id, osmo.id, sony.id, unknown.id])
        XCTAssertEqual(ascending.reversed.sorted(stacks).map(\.id), [unknown.id, sony.id, osmoEarlier.id, osmo.id])

        // The board's resolved camera overrides the tags.
        let resolved = ascending.sorted(stacks) { $0.id == unknown.id ? "Aardvark Cam" : $0.items.first?.metadataCamera?.name }
        XCTAssertEqual(resolved.first?.id, unknown.id)
        XCTAssertEqual(OrganizeSortKey.camera.title, "Camera")
    }
}

// MARK: - Synthetic media

/// A little-endian TIFF header whose primary IFD carries Make and Model,
/// with an EXIF capture time when `captureTime` is given.
func makeCameraTIFFHeader(make: String, model: String, captureTime: String?) -> Data {
    let makeBytes = Array((make + "\0").utf8)
    let modelBytes = Array((model + "\0").utf8)
    let timeBytes = captureTime.map { Array(($0 + "\0").utf8) } ?? []
    let entryCount = captureTime == nil ? 2 : 3
    let ifd0Size = 2 + entryCount * 12 + 4
    let makeOffset = 8 + ifd0Size
    let modelOffset = makeOffset + makeBytes.count
    let exifOffset = modelOffset + modelBytes.count
    let exifSize = 2 + 12 + 4
    let timeOffset = exifOffset + exifSize

    var bytes: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0]
    func append16(_ value: Int) { bytes += [UInt8(value & 0xff), UInt8(value >> 8 & 0xff)] }
    func append32(_ value: Int) { (0..<4).forEach { bytes.append(UInt8(value >> ($0 * 8) & 0xff)) } }
    append16(entryCount)
    append16(0x010F); append16(2); append32(makeBytes.count); append32(makeOffset)
    append16(0x0110); append16(2); append32(modelBytes.count); append32(modelOffset)
    if captureTime != nil {
        append16(0x8769); append16(4); append32(1); append32(exifOffset)
    }
    append32(0)
    bytes += makeBytes
    bytes += modelBytes
    if captureTime != nil {
        append16(1)
        append16(0x9003); append16(2); append32(timeBytes.count); append32(timeOffset)
        append32(0)
        bytes += timeBytes
    }
    return Data(bytes)
}

func box(_ type: String, _ payload: Data) -> Data {
    var data = Data()
    let size = UInt32(8 + payload.count)
    data.append(contentsOf: [UInt8(size >> 24 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)])
    data.append(contentsOf: type.unicodeScalars.map { UInt8($0.value) })
    data.append(payload)
    return data
}

private func uint32Data(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
}

/// `ftyp`, a little media data, then `moov` with `children` (plus an
/// `mvhd` stand-in), then anything `trailing`.
func makeClip(moov children: [Data], trailing: Data = Data()) -> Data {
    box("ftyp", Data("isom".utf8) + uint32Data(0))
        + box("mdat", Data(repeating: 0x11, count: 64))
        + box("moov", box("mvhd", Data(repeating: 0, count: 20)) + children.reduce(Data(), +))
        + trailing
}

/// `udta/meta/ilst/©too` as DJI writes it.
func djiSoftwareUserData(_ software: String) -> Data {
    let data = box("data", uint32Data(1) + uint32Data(0) + Data(software.utf8))
    let meta = box("meta", uint32Data(0) + box("hdlr", Data(repeating: 0, count: 24)) + box("ilst", box("\u{A9}too", data)))
    return box("udta", meta)
}

/// A movie-level QuickTime `meta` with `mdta` keys, as an iPhone writes it.
func appleKeysMeta(_ pairs: [(String, String)]) -> Data {
    var keys = uint32Data(0) + uint32Data(UInt32(pairs.count))
    var list = Data()
    for (index, pair) in pairs.enumerated() {
        let name = Data(pair.0.utf8)
        keys += uint32Data(UInt32(8 + name.count)) + Data("mdta".utf8) + name
        let value = box("data", uint32Data(1) + uint32Data(0) + Data(pair.1.utf8))
        list += uint32Data(UInt32(8 + value.count)) + uint32Data(UInt32(index + 1)) + value
    }
    return box("meta", box("hdlr", Data(repeating: 0, count: 24)) + box("keys", keys) + box("ilst", list))
}

/// A classic QuickTime `udta` text atom.
func textAtom(_ type: String, _ text: String) -> Data {
    let bytes = Data(text.utf8)
    return box(type, Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff), 0x15, 0xC7]) + bytes)
}
