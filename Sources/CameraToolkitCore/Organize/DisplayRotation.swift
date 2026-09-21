import CoreGraphics
import Foundation

/// Display-time rotation for organize tiles and the burst preview, persisted
/// in `AppConfiguration.displayOrientations` as quarter-turns clockwise keyed
/// by file identity. Nothing here ever writes to a media file — the turn is
/// remembered in the map and applied while decoding, so RAW sensor data and
/// archive checksums stay untouched.
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

    /// Quarter-turns recorded for a file, normalized on lookup so a stale or
    /// hand-edited value still decodes sensibly.
    public static func turns(for file: OrganizeFile, in map: [String: Int]) -> Int {
        normalized(map[fileKey(for: file)] ?? 0)
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

    /// Returns the map with `delta` quarter-turns added to every rotatable
    /// file in the stack. Keys that land back on 0 are removed so the map
    /// stays small.
    public static func rotatedMap(
        _ map: [String: Int],
        applying delta: Int,
        to stack: OrganizeStack
    ) -> [String: Int] {
        var map = map
        for file in rotatableFiles(in: stack) {
            let next = normalized(turns(for: file, in: map) + delta)
            map[fileKey(for: file)] = next == 0 ? nil : next
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
