import CoreGraphics
import Foundation

/// Display-time rotation for organize tiles and the burst preview, persisted
/// in `AppConfiguration.displayOrientations` as quarter-turns clockwise keyed
/// by file identity. Nothing here ever writes to a media file — the turn is
/// remembered in the map and applied while decoding, so RAW sensor data and
/// archive checksums stay untouched.
///
/// A RAW preview comes out of the file unrotated; the camera's rotation is
/// only in the RAW's orientation tag. A saved entry is an absolute override
/// of that: the turns from the unrotated preview, with no entry meaning "as
/// the camera recorded it". So an entry made before the camera's rotation was
/// honoured keeps looking the way it always did, with nothing rewritten.
public enum DisplayRotation {
    /// Folds any quarter-turn count into 0...3.
    public static func normalized(_ turns: Int) -> Int {
        ((turns % 4) + 4) % 4
    }

    /// File identity that survives a move between card, Buffer, and NAS:
    /// name + byte count + modification second, the same key `FaceIndexStore`
    /// uses to attribute photos to events.
    public static func fileKey(for file: OrganizeFile) -> String {
        FaceIndexStore.fileKey(fileName: file.name, byteCount: file.size, modifiedAt: file.modifiedAt)
    }

    /// The saved override for a file, or nil to show it as the camera
    /// recorded it. Normalized on lookup so a stale or hand-edited value
    /// still decodes sensibly.
    public static func savedTurns(for file: OrganizeFile, in map: [String: Int]) -> Int? {
        map[fileKey(for: file)].map(normalized)
    }

    /// Quarter-turns clockwise for a TIFF orientation tag (0x0112): 6 is
    /// 90°, 3 is 180°, 8 is 270°. A missing tag, 1, and the mirrored values
    /// no camera writes all mean no turn.
    public static func cameraTurns(forTIFFOrientation value: Int?) -> Int {
        switch value {
        case 6: 1
        case 3: 2
        case 8: 3
        default: 0
        }
    }

    /// The turns a file is drawn at: its saved entry when it has one, else
    /// the camera's.
    public static func effectiveTurns(saved: Int?, camera: Int) -> Int {
        normalized(saved ?? camera)
    }

    /// Names a decode request in a cache key: `auto` for no saved entry, so
    /// the bitmap's rotation comes from the camera, else the saved turns.
    public static func requestToken(_ saved: Int?) -> String {
        saved.map { String(normalized($0)) } ?? "auto"
    }

    /// Whether this file's picture can come back unrotated with the turn
    /// left to the display: only RAW files, whose previews are extracted.
    /// Every other kind is rotated by ImageIO or AVFoundation as it decodes.
    public static func hasCameraTurns(_ url: URL) -> Bool {
        OrganizeFileClassifier.rawExtensions.contains(url.pathExtension.lowercased())
    }

    /// Stills (RAW and ordinary photos) and video posters rotate; XMP
    /// sidecars and other companions never do.
    public static func isRotatable(_ file: OrganizeFile) -> Bool {
        let ext = file.fileExtension
        return OrganizeFileClassifier.rawExtensions.contains(ext)
            || OrganizeFileClassifier.photoExtensions.contains(ext)
            || OrganizeFileClassifier.videoExtensions.contains(ext)
    }

    /// Every rotatable file in the stack — primaries plus JPEG companions —
    /// so one Rotate Burst action turns the whole stack together.
    public static func rotatableFiles(in stack: OrganizeStack) -> [OrganizeFile] {
        stack.files.filter(isRotatable)
    }

    /// Returns the map with every rotatable file in the stack one `delta`
    /// away from what is on screen. A file that lands back on the camera's
    /// turns has its entry removed; any other result is kept, including 0 on
    /// a file the camera turned, which is how "show it unrotated" is said.
    public static func rotatedMap(
        _ map: [String: Int],
        applying delta: Int,
        to stack: OrganizeStack,
        cameraTurns: (OrganizeFile) -> Int = { _ in 0 }
    ) -> [String: Int] {
        var map = map
        for file in rotatableFiles(in: stack) {
            let camera = normalized(cameraTurns(file))
            let next = normalized(effectiveTurns(saved: savedTurns(for: file, in: map), camera: camera) + delta)
            map[fileKey(for: file)] = next == camera ? nil : next
        }
        return map
    }

    /// Rotates a decoded image by whole quarter-turns. Orientation 0 (and
    /// full turns) returns the source unchanged.
    public static func rotate(_ image: CGImage, quarterTurnsCW delta: Int) -> CGImage {
        let turns = normalized(delta)
        guard turns != 0 else { return image }
        let width = image.width
        let height = image.height
        let outputWidth = turns.isMultiple(of: 2) ? width : height
        let outputHeight = turns.isMultiple(of: 2) ? height : width
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: outputWidth,
                  height: outputHeight,
                  bitsPerComponent: image.bitsPerComponent,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: image.bitmapInfo.rawValue
              )
        else { return image }
        // Bitmap contexts are bottom-left origin; these transforms land the
        // source's top edge where a quarter-turned photo expects it.
        switch turns {
        case 1:
            context.translateBy(x: 0, y: CGFloat(outputHeight))
            context.rotate(by: -.pi / 2)
        case 2:
            context.translateBy(x: CGFloat(outputWidth), y: CGFloat(outputHeight))
            context.rotate(by: .pi)
        case 3:
            context.translateBy(x: CGFloat(outputWidth), y: 0)
            context.rotate(by: .pi / 2)
        default:
            return image
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
