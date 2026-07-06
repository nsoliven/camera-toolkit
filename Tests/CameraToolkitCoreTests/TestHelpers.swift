import Foundation
import XCTest

@discardableResult
func writeFile(_ url: URL, _ data: Data) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
}

@discardableResult
func writeFile(_ url: URL, _ string: String) throws -> URL {
    try writeFile(url, Data(string.utf8))
}

func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CameraToolkitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(root)
}

func treeBytes(_ root: URL) throws -> [String: Data] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [], errorHandler: nil) else {
        return [:]
    }

    var result: [String: Data] = [:]
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        result[relative] = try Data(contentsOf: url)
    }
    return result
}

extension Data {
    static func repeated(_ string: String, count: Int) -> Data {
        Data(String(repeating: string, count: count).utf8)
    }
}
