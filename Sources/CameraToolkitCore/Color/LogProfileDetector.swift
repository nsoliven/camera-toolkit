import Foundation

/// Finds a clip's log profile from the metadata the camera wrote beside it.
///
/// Sony bodies write a `…M01.XML` sidecar per clip whose
/// `CameraUnitMetadataSet` names the capture gamma and primaries, e.g.
/// `CaptureGammaEquation = s-log3-cine` and
/// `CaptureColorPrimaries = s-gamut3-cine`. DJI files carry no reliable
/// marker for D-Log M, so DJI clips are only log when the user marks them.
public enum LogProfileDetector {
    /// Sidecars are a few kilobytes; anything bigger is not one.
    static let maximumSidecarBytes = 256 * 1_024

    /// The profile from a Sony sidecar's text, or nil for anything else
    /// (Rec.709, HLG, S-Cinetone, S-Log2, an unrelated XML).
    public static func profile(sonySidecarXML text: String) -> LogProfile? {
        guard let gamma = itemValue("CaptureGammaEquation", in: text)?.lowercased() else { return nil }
        guard gamma.hasPrefix("s-log3") else { return nil }
        let primaries = itemValue("CaptureColorPrimaries", in: text)?.lowercased() ?? ""
        switch primaries {
        case "s-gamut3": return .sLog3SGamut3
        // `s-log3-cine` with no primaries is how some bodies say Cine.
        default: return .sLog3SGamut3Cine
        }
    }

    /// Reads the sidecar among `companions` (the clip's side files) and
    /// returns its profile. Reads one small file; call it off the main actor.
    public static func profile(clip: URL, companions: [URL]) -> LogProfile? {
        guard OrganizeFileClassifier.videoExtensions.contains(clip.pathExtension.lowercased()) else { return nil }
        for url in companions where url.pathExtension.lowercased() == "xml" {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumSidecarBytes,
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            if let profile = profile(sonySidecarXML: text) { return profile }
        }
        return nil
    }

    /// The profile of a clip from the Sony sidecar beside it
    /// (`C0001.MP4` → `C0001M01.XML`), for callers without a board item.
    public static func profile(clipBesideSidecar clip: URL) -> LogProfile? {
        let stem = clip.deletingPathExtension().lastPathComponent
        let folder = clip.deletingLastPathComponent()
        return profile(clip: clip, companions: ["\(stem)M01.XML", "\(stem)M01.xml"].map { folder.appendingPathComponent($0) })
    }

    /// The camera's make and model from a Sony sidecar's `<Device …>`.
    public static func sonyDevice(sidecarXML text: String) -> (make: String?, model: String?)? {
        guard let open = text.range(of: "<Device", options: .caseInsensitive),
              let close = text.range(of: ">", range: open.upperBound..<text.endIndex) else { return nil }
        let tag = text[open.upperBound..<close.lowerBound]
        let make = attribute("manufacturer", in: tag)
        let model = attribute("modelName", in: tag)
        return make == nil && model == nil ? nil : (make, model)
    }

    /// `C0001.MP4` → reads `C0001M01.XML` beside it, if there is one.
    public static func sonySidecarDevice(forClip clip: URL) -> (make: String?, model: String?)? {
        let stem = clip.deletingPathExtension().lastPathComponent
        let folder = clip.deletingLastPathComponent()
        for name in ["\(stem)M01.XML", "\(stem)M01.xml"] {
            let url = folder.appendingPathComponent(name)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumSidecarBytes,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return sonyDevice(sidecarXML: text)
        }
        return nil
    }

    /// `<Item name="NAME" value="VALUE"/>` → VALUE. Attribute order and
    /// quoting vary between firmware versions, so this reads attributes
    /// rather than matching one fixed spelling.
    static func itemValue(_ name: String, in text: String) -> String? {
        var searchStart = text.startIndex
        while let open = text.range(of: "<Item", options: .caseInsensitive, range: searchStart..<text.endIndex) {
            guard let close = text.range(of: ">", range: open.upperBound..<text.endIndex) else { return nil }
            let tag = text[open.upperBound..<close.lowerBound]
            searchStart = close.upperBound
            guard attribute("name", in: tag)?.caseInsensitiveCompare(name) == .orderedSame else { continue }
            return attribute("value", in: tag)
        }
        return nil
    }

    private static func attribute(_ key: String, in tag: Substring) -> String? {
        var index = tag.startIndex
        while let range = tag.range(of: key, options: .caseInsensitive, range: index..<tag.endIndex) {
            index = range.upperBound
            // Must be a whole attribute name.
            if range.lowerBound > tag.startIndex, !tag[tag.index(before: range.lowerBound)].isWhitespace { continue }
            var cursor = range.upperBound
            while cursor < tag.endIndex, tag[cursor].isWhitespace { cursor = tag.index(after: cursor) }
            guard cursor < tag.endIndex, tag[cursor] == "=" else { continue }
            cursor = tag.index(after: cursor)
            while cursor < tag.endIndex, tag[cursor].isWhitespace { cursor = tag.index(after: cursor) }
            guard cursor < tag.endIndex, tag[cursor] == "\"" || tag[cursor] == "'" else { continue }
            let quote = tag[cursor]
            let valueStart = tag.index(after: cursor)
            guard let end = tag[valueStart...].firstIndex(of: quote) else { return nil }
            return String(tag[valueStart..<end])
        }
        return nil
    }
}
