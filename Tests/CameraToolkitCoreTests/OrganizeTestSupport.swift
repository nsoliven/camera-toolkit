import CameraToolkitCore
import Foundation

/// A minimal little-endian TIFF header: IFD0 points to an EXIF IFD holding
/// DateTimeOriginal (by offset) and SubSecTimeOriginal (inline).
func makeTIFFHeader(captureTime original: String, subseconds: String = "000") -> Data {
    var bytes: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0]
    func append16(_ value: Int) { bytes += [UInt8(value & 0xff), UInt8(value >> 8 & 0xff)] }
    func append32(_ value: Int) { (0..<4).forEach { bytes.append(UInt8(value >> ($0 * 8) & 0xff)) } }
    append16(1)
    append16(0x8769); append16(4); append32(1); append32(26)
    append32(0)
    append16(2)
    append16(0x9003); append16(2); append32(20); append32(56)
    let paddedSubseconds = String((subseconds + "000").prefix(3))
    append16(0x9291); append16(2); append32(4); bytes += Array((paddedSubseconds + "\0").utf8)
    append32(0)
    bytes += Array((original + "\0").utf8)
    return Data(bytes)
}

func exifDate(_ original: String, subseconds: String = "000") -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return formatter.date(from: original)!.addingTimeInterval(Double("0." + subseconds) ?? 0)
}

@discardableResult
func writeFakeARW(_ url: URL, captureTime: String, subseconds: String = "000", modifiedAt: Date? = nil) throws -> URL {
    var data = makeTIFFHeader(captureTime: captureTime, subseconds: subseconds)
    data.append(Data(repeating: 0xAB, count: 512))
    try writeFile(url, data)
    if let modifiedAt {
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }
    return url
}

func organizeItem(
    _ path: String,
    kind: OrganizeMediaKind = .raw,
    date: Date,
    hasCameraDate: Bool = true
) -> OrganizeItem {
    OrganizeItem(
        primary: OrganizeFile(path: path, size: 10, modifiedAt: date),
        kind: kind,
        captureDate: date,
        hasCameraDate: hasCameraDate
    )
}

func testConfiguration(root: URL, bufferPath: String? = nil) -> AppConfiguration {
    AppConfiguration(
        demoRootPath: root.appendingPathComponent("Safety Test").path,
        importSourcePath: root.appendingPathComponent("Card").path,
        archivePath: root.appendingPathComponent("Library/Originals").path,
        bufferPath: bufferPath ?? root.appendingPathComponent("Buffer").path,
        cameraLibraryRootPath: root.appendingPathComponent("Library").path,
        activityLogPath: root.appendingPathComponent("activity.jsonl").path,
        selectedDeviceID: "sony-a7v"
    )
}
