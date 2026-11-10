import CryptoKit
import Foundation

public enum FileHasher {
    private static let bufferSize = 1_048_576

    /// `onProgress` is called after every chunk with the running byte count, so a caller can show
    /// movement while a very large file is read back.
    public static func sha256(at url: URL, onProgress: ((Int64) -> Void)? = nil) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var bytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: bufferSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            bytes += Int64(data.count)
            onProgress?(bytes)
        }
        return hasher.finalize().map { String(format: "%02X", $0) }.joined()
    }
}
