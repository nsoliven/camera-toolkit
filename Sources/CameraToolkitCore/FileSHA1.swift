import CryptoKit
import Foundation

public enum FileSHA1 {
    /// Streams the file in bounded chunks so checking large RAW/video files does
    /// not load them into RAM. Immich accepts a hex-encoded SHA-1 checksum.
    public static func hexDigest(
        of url: URL,
        chunkSize: Int = 4 * 1_024 * 1_024
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = Insecure.SHA1()
        while true {
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
