import Foundation

/// The camera tags a file carries itself — EXIF/TIFF Make and Model for
/// stills, the QuickTime make/model (or the camera-naming software tag DJI
/// writes) for clips. Raw strings, trimmed; `CameraCatalog` maps them to a
/// friendly camera.
public struct CameraMetadata: Codable, Hashable, Sendable {
    public var make: String?
    public var model: String?

    public init(make: String? = nil, model: String? = nil) {
        self.make = CameraCatalog.clean(make)
        self.model = CameraCatalog.clean(model)
    }

    public var isEmpty: Bool { make == nil && model == nil }
}

/// One camera as the boards show it: a stable id the filter matches on and
/// the name a chip prints. Known bodies use the configuration's device ids
/// (`sony-a7v`, `osmo-360`, …) whether the camera came from a catalog
/// assignment, a configured source, or the file's own tags — so every
/// Sony A7V file lands under one value. Unrecognized bodies group by their
/// raw model string (`model:<Model>`).
public struct OrganizeCamera: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// The pseudo-camera of a file whose camera is not known (yet): no
    /// device on its assignment or source, and no tags read — or none
    /// written. A board shows it until the background metadata pass
    /// catches up.
    public static let unknownID = "_unknown"
    public static let unknown = OrganizeCamera(id: unknownID, name: "Unknown camera")
}

/// Device ids, raw camera tags, and the names the boards print for them.
public enum CameraCatalog {
    /// "Other Camera" — the configuration's no-camera-chosen device. It
    /// says nothing about which camera shot a file, so resolution falls
    /// through it to the next rule.
    public static let genericDeviceID = "generic-camera"

    static let modelPrefix = "model:"

    /// Friendly names for the configuration's device ids.
    static let deviceNames: [String: String] = [
        "sony-a7v": "Sony A7V",
        "osmo-360": "Osmo 360",
        "dji-nano": "Osmo Nano",
        "dji-mini-2": "DJI Mini 2",
        "action-6": "Osmo Action 6",
        "iphone": "iPhone",
    ]

    /// The camera a device id names — nil for no id or the generic one.
    /// A custom id (a hand-named device folder) is its own camera.
    public static func camera(deviceID: String?) -> OrganizeCamera? {
        guard let id = clean(deviceID), id != genericDeviceID else { return nil }
        return OrganizeCamera(id: id, name: deviceNames[id] ?? id)
    }

    public static func camera(metadata: CameraMetadata?) -> OrganizeCamera? {
        camera(make: metadata?.make, model: metadata?.model)
    }

    /// Maps raw tags to a camera: known bodies to their device id and
    /// friendly name ("ILCE-7M5" → Sony A7V, "DJI Osmo Nano" → Osmo Nano),
    /// anything else to its raw model string. No model means no camera —
    /// a make alone does not tell two bodies apart.
    public static func camera(make: String?, model: String?) -> OrganizeCamera? {
        guard let model = clean(model) else { return nil }
        if let deviceID = knownDeviceID(make: clean(make), model: model) {
            return camera(deviceID: deviceID)
        }
        return OrganizeCamera(id: modelPrefix + model, name: model)
    }

    /// The camera behind an id a filter row holds — for labels when the
    /// board no longer carries a file from that camera.
    public static func camera(id: String) -> OrganizeCamera {
        if id == OrganizeCamera.unknownID { return .unknown }
        if id.hasPrefix(modelPrefix) {
            return OrganizeCamera(id: id, name: String(id.dropFirst(modelPrefix.count)))
        }
        return OrganizeCamera(id: id, name: deviceNames[id] ?? id)
    }

    /// Whether a software tag names a camera this catalog knows — DJI
    /// clips carry no make/model, only "DJI Osmo Nano" / "Osmo 360" as the
    /// encoder, while an iPhone's software tag is just an iOS version.
    static func namesKnownCamera(_ software: String?) -> Bool {
        guard let software = clean(software) else { return false }
        return knownDeviceID(make: nil, model: software) != nil
    }

    static func knownDeviceID(make: String?, model: String) -> String? {
        let make = make?.lowercased() ?? ""
        let model = model.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let isDJI = make.contains("dji") || model.contains("dji") || model.contains("osmo")
        if model == "ilce 7m5" || (make.contains("sony") && model.contains("a7 v")) { return "sony-a7v" }
        if model.contains("osmo 360") || model.contains("osmo360") { return "osmo-360" }
        if isDJI, model.contains("nano") { return "dji-nano" }
        if model == "fc7303" || (isDJI && model.contains("mini 2")) { return "dji-mini-2" }
        if isDJI, model.contains("action 6") { return "action-6" }
        return nil
    }

    /// The device a source's name or path suggests ("DJI Osmo 360 Card",
    /// "Nano Clips"). Nil when neither names a camera.
    public static func inferredDeviceID(name: String, path: String) -> String? {
        let fingerprint = "\(name) \(path)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if fingerprint.contains("nano") { return "dji-nano" }
        if fingerprint.contains("osmo") { return "osmo-360" }
        if fingerprint.contains("sony") || fingerprint.contains("a7v") { return "sony-a7v" }
        if fingerprint.contains("mini 2") || fingerprint.contains("mini-2") || fingerprint.contains("mini_2") {
            return "dji-mini-2"
        }
        if fingerprint.contains("action 6") || fingerprint.contains("action-6") || fingerprint.contains("action_6") {
            return "action-6"
        }
        if fingerprint.contains("iphone") { return "iphone" }
        return nil
    }

    /// Trimmed of whitespace and the NUL padding EXIF writers leave; empty
    /// becomes nil.
    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Resolves which camera shot a file, in precedence order:
///
/// 1. the catalog assignment's `device_id` (set from the source it was
///    imported from),
/// 2. the configured import source whose root contains the file — its
///    chosen device, or the one its name implies,
/// 3. the file's own camera tags, read by the capture-date pass.
///
/// Pure string work over paths the scan already standardized — no
/// filesystem access — so boards can resolve every stack per filter pass.
public struct OrganizeCameraResolver: Sendable {
    private struct Root: Sendable {
        var prefix: String
        var camera: OrganizeCamera
    }

    /// Longest root first, so a nested source wins over its parent.
    private let roots: [Root]

    public init(locations: [ConfiguredLocation]) {
        roots = locations.compactMap { location -> Root? in
            guard location.role == .importSource,
                  let camera = CameraCatalog.camera(
                      deviceID: location.deviceID ?? CameraCatalog.inferredDeviceID(name: location.name, path: location.path)
                  ) else { return nil }
            let expanded = NSString(string: location.path).expandingTildeInPath
            guard !expanded.isEmpty else { return nil }
            // `standardized` is lexical — no stat, no symlink walk.
            var key = URL(filePath: expanded, directoryHint: .isDirectory).standardized.path.lowercased()
            while key.count > 1, key.hasSuffix("/") { key.removeLast() }
            guard key != "/" else { return nil }
            return Root(prefix: key + "/", camera: camera)
        }
        .sorted { $0.prefix.count > $1.prefix.count }
    }

    /// The camera of one file, or nil when no rule knows it.
    public func camera(assignmentDeviceID: String?, file: OrganizeFile, metadataCamera: OrganizeCamera?) -> OrganizeCamera? {
        if let camera = CameraCatalog.camera(deviceID: assignmentDeviceID) { return camera }
        if let camera = locationCamera(forPathKey: file.pathKey) { return camera }
        return metadataCamera
    }

    /// Rule 2 alone: the configured source containing `pathKey`
    /// (`OrganizeFile.pathKey` — standardized and lower-cased).
    public func locationCamera(forPathKey pathKey: String) -> OrganizeCamera? {
        roots.first { pathKey.hasPrefix($0.prefix) }?.camera
    }
}

extension ConfiguredLocation {
    /// The device this source's name or path implies — see
    /// `CameraCatalog.inferredDeviceID(name:path:)`.
    public var inferredDeviceID: String? {
        CameraCatalog.inferredDeviceID(name: name, path: path)
    }
}

/// Reads the camera tags a QuickTime-family clip (MP4, MOV, DJI OSV)
/// carries in its `moov` box: the classic `udta` `©mak`/`©mod` atoms, the
/// iTunes-style `udta/meta/ilst` items DJI writes (`©too` "DJI Osmo Nano"),
/// Apple's `mdta` keys (`com.apple.quicktime.make`/`.model`), and the
/// device line of the XML Sony writes in a top-level `meta` box. Walks
/// top-level box headers with seeks and reads only those payloads,
/// bounded — never the media data.
public enum QuickTimeCameraReader {
    public static let extensions: Set<String> = ["mp4", "mov", "m4v", "osv", "insv"]
    static let maximumMovieBoxBytes = 16 * 1_024 * 1_024
    static let maximumXMLBoxBytes = 1_024 * 1_024
    static let maximumTopLevelBoxes = 512

    public static func canRead(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    public static func camera(of url: URL) -> CameraMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        var offset: UInt64 = 0
        for _ in 0..<maximumTopLevelBoxes {
            guard offset + 8 <= fileSize,
                  (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 16), header.count >= 8 else { return nil }
            let bytes = [UInt8](header)
            let size32 = UInt64(uint32(bytes, 0))
            var headerLength: UInt64 = 8
            var size = size32
            if size32 == 1 {
                guard bytes.count >= 16 else { return nil }
                size = UInt64(uint32(bytes, 8)) << 32 | UInt64(uint32(bytes, 12))
                headerLength = 16
            } else if size32 == 0 {
                size = fileSize - offset
            }
            guard size >= headerLength else { return nil }
            let type = fourCC(bytes, 4)
            let payloadLength = size - headerLength
            if type == "moov" || type == "meta" {
                let limit = type == "moov" ? maximumMovieBoxBytes : maximumXMLBoxBytes
                guard payloadLength <= UInt64(limit),
                      (try? handle.seek(toOffset: offset + headerLength)) != nil,
                      let payload = try? handle.read(upToCount: Int(payloadLength)) else { return nil }
                if type == "moov" {
                    if let camera = camera(movieBox: payload) { return camera }
                } else if let camera = camera(xmlMeta: payload) {
                    return camera
                }
            }
            offset += size
        }
        return nil
    }

    /// Sony clips keep their camera in a top-level `meta` box after `moov`:
    /// real-time XML with `<Device manufacturer="Sony" modelName="ILCE-7M5"/>`.
    public static func camera(xmlMeta data: Data) -> CameraMetadata? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let device = text.range(of: "<Device ") else { return nil }
        let tail = text[device.upperBound...].prefix(512)
        func attribute(_ name: String) -> String? {
            guard let start = tail.range(of: name + "=\"") else { return nil }
            let rest = tail[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        let camera = CameraMetadata(make: attribute("manufacturer"), model: attribute("modelName"))
        return camera.model == nil ? nil : camera
    }

    /// Parses a `moov` payload (without its own header).
    public static func camera(movieBox data: Data) -> CameraMetadata? {
        let bytes = [UInt8](data)
        var tags = Tags()
        for child in boxes(bytes, 0..<bytes.count) {
            switch child.type {
            case "udta": readUserData(bytes, child.payload, into: &tags)
            case "meta": readMeta(bytes, child.payload, into: &tags)
            default: break
            }
        }
        let model = tags.model ?? (CameraCatalog.namesKnownCamera(tags.software) ? tags.software : nil)
        let camera = CameraMetadata(make: tags.make, model: model)
        return camera.isEmpty ? nil : camera
    }

    private struct Tags {
        var make: String?
        var model: String?
        var software: String?

        mutating func set(_ key: String, _ value: String?) {
            guard let value = CameraCatalog.clean(value) else { return }
            switch key {
            case "\u{A9}mak", "com.apple.quicktime.make": make = make ?? value
            case "\u{A9}mod", "com.apple.quicktime.model": model = model ?? value
            case "\u{A9}too", "\u{A9}swr", "com.apple.quicktime.software": software = software ?? value
            default: break
            }
        }
    }

    private struct Box {
        var type: String
        var payload: Range<Int>
    }

    private static func boxes(_ bytes: [UInt8], _ range: Range<Int>) -> [Box] {
        var result: [Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound, result.count < 4_096 {
            let size = Int(uint32(bytes, offset))
            var header = 8
            var length = size
            if size == 1 {
                guard offset + 16 <= range.upperBound else { break }
                let large = UInt64(uint32(bytes, offset + 8)) << 32 | UInt64(uint32(bytes, offset + 12))
                guard large <= UInt64(Int.max) else { break }
                length = Int(large)
                header = 16
            } else if size == 0 {
                length = range.upperBound - offset
            }
            guard length >= header, offset + length <= range.upperBound else { break }
            result.append(Box(type: fourCC(bytes, offset + 4), payload: (offset + header)..<(offset + length)))
            offset += length
        }
        return result
    }

    private static func readUserData(_ bytes: [UInt8], _ range: Range<Int>, into tags: inout Tags) {
        for child in boxes(bytes, range) {
            if child.type == "meta" {
                readMeta(bytes, child.payload, into: &tags)
            } else if child.type.hasPrefix("\u{A9}") {
                // Classic QuickTime text atom: UInt16 length, UInt16
                // language, then the text.
                let start = child.payload.lowerBound
                guard start + 4 <= child.payload.upperBound else { continue }
                let length = Int(bytes[start]) << 8 | Int(bytes[start + 1])
                let textStart = start + 4
                let end = min(textStart + length, child.payload.upperBound)
                guard end > textStart else { continue }
                tags.set(child.type, text(bytes[textStart..<end]))
            }
        }
    }

    /// `meta` is a full box inside `udta` (ISO) but a plain container at
    /// the movie level (QuickTime) — a zero first word is the version and
    /// flags, never a child box size.
    private static func readMeta(_ bytes: [UInt8], _ range: Range<Int>, into tags: inout Tags) {
        var start = range.lowerBound
        if start + 4 <= range.upperBound, uint32(bytes, start) == 0 { start += 4 }
        let children = boxes(bytes, start..<range.upperBound)
        var keys: [String] = []
        if let keysBox = children.first(where: { $0.type == "keys" }) {
            keys = readKeys(bytes, keysBox.payload)
        }
        guard let list = children.first(where: { $0.type == "ilst" }) else { return }
        for item in boxes(bytes, list.payload) {
            let key: String
            let index = Int(uint32(bytes, item.payload.lowerBound - 4))
            if !keys.isEmpty, index >= 1, index <= keys.count {
                key = keys[index - 1]
            } else {
                key = item.type
            }
            guard let data = boxes(bytes, item.payload).first(where: { $0.type == "data" }),
                  data.payload.count > 8 else { continue }
            let typeIndicator = uint32(bytes, data.payload.lowerBound) & 0x00FF_FFFF
            // 1 = UTF-8, 0 = implicit (DJI writes its text so too).
            guard typeIndicator == 1 || typeIndicator == 0 else { continue }
            tags.set(key, text(bytes[(data.payload.lowerBound + 8)..<data.payload.upperBound]))
        }
    }

    private static func readKeys(_ bytes: [UInt8], _ range: Range<Int>) -> [String] {
        guard range.count >= 8 else { return [] }
        let count = Int(uint32(bytes, range.lowerBound + 4))
        var keys: [String] = []
        var offset = range.lowerBound + 8
        while keys.count < min(count, 1_024), offset + 8 <= range.upperBound {
            let size = Int(uint32(bytes, offset))
            guard size >= 8, offset + size <= range.upperBound else { break }
            keys.append(text(bytes[(offset + 8)..<(offset + size)]) ?? "")
            offset += size
        }
        return keys
    }

    private static func text(_ slice: ArraySlice<UInt8>) -> String? {
        String(bytes: slice.prefix { $0 != 0 }, encoding: .utf8)
            ?? String(bytes: slice.prefix { $0 != 0 }, encoding: .isoLatin1)
    }

    private static func fourCC(_ bytes: [UInt8], _ offset: Int) -> String {
        String(bytes[offset..<(offset + 4)].map { Character(Unicode.Scalar($0)) })
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
