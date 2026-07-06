import Foundation

public enum MediaFileMatcher {
    public static let supportedPhotoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
        "dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "srw"
    ]

    public static func isSupportedPhotoPath(_ path: String) -> Bool {
        supportedPhotoExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}

public struct EditorWorkingCopyService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func makeWorkingCopy(source: URL, workingRoot: URL) throws -> URL {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ToolkitError.pathNotFound(source.path)
        }

        try fileManager.createDirectory(at: workingRoot, withIntermediateDirectories: true)
        let destination = uniqueDestination(for: source.lastPathComponent, in: workingRoot)
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    private func uniqueDestination(for filename: String, in folder: URL) -> URL {
        let original = folder.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: original.path) else {
            return original
        }

        let baseURL = URL(fileURLWithPath: filename)
        let baseName = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension

        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(baseName)-\(index)" : "\(baseName)-\(index).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}
